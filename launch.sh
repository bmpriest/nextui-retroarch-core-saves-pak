#!/bin/sh

DIR=${CORE_SAVES_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}
PAK_NAME=$(basename "$DIR")
PAK_NAME=${PAK_NAME%.pak}

cd "$DIR" || exit 1

: "${SDCARD_PATH:=/mnt/SDCARD}"
: "${PLATFORM:=tg5040}"
: "${SYSTEM_PATH:=$SDCARD_PATH/.system/$PLATFORM}"
: "${SHARED_USERDATA_PATH:=$SDCARD_PATH/.userdata/shared}"
: "${USERDATA_PATH:=$SDCARD_PATH/.userdata/$PLATFORM}"
: "${LOGS_PATH:=$USERDATA_PATH/logs}"

HUMAN_READABLE_NAME="RetroArch Core Saves"

SAVES_PATH="$SDCARD_PATH/Saves"
CORES_PATH="$SAVES_PATH/Cores"
ROMS_PATH="$SDCARD_PATH/Roms"
SETTINGS_PATH="$SHARED_USERDATA_PATH/minuisettings.txt"
HOME_PATH="$SHARED_USERDATA_PATH/$PAK_NAME"
HOOK_DIR="$USERDATA_PATH/.hooks/boot.d"
BACKUP_ROOT="$SDCARD_PATH/.core-saves-backups"

MOUNT_TABLE="$HOME_PATH/mounts.conf"
MANIFEST="$HOME_PATH/migration.manifest"
ENABLED_FILE="$HOME_PATH/enabled"
HOOK_FILE="$HOOK_DIR/core-saves.sync.sh"
LOG_FILE="$LOGS_PATH/core-saves.txt"
REPORT_FILE="$HOME_PATH/conversion-report.txt"
OPERATION_JOURNAL="$HOME_PATH/operation.journal"
OPERATION_STATE="$HOME_PATH/operation-state"

ACTION_RESULT=""
REPORT_ISSUES=0

mkdir -p "$LOGS_PATH" "$HOME_PATH" "$BACKUP_ROOT"
: > "$LOG_FILE"

export HOME="$HOME_PATH"
export PATH="$DIR/bin/$PLATFORM:$DIR/bin:$PATH"
export LD_LIBRARY_PATH="$SYSTEM_PATH/lib:/usr/trimui/lib:${LD_LIBRARY_PATH:-}"

for library in report settings mappings mount-manager backup save-format audit enable restore; do
	. "$DIR/bin/$library.sh" || exit 1
done

show_progress() {
	local message="$1"
	local progress="${2:-100}"

	log "$message"

	if command -v show2.elf >/dev/null 2>&1; then
		show2.elf --mode=progress --image "$SDCARD_PATH/.system/res/logo.png" \
			--text="$message" --progress="$progress" --timeout=1 >/dev/null 2>&1
	fi
}

present() {
	local message="$1"

	if command -v minui-presenter >/dev/null 2>&1; then
		minui-presenter --message "$message" --confirm-show --confirm-text "OK"
	else
		show_progress "$message" 100
	fi
}

confirm() {
	local message="$1"

	if command -v minui-presenter >/dev/null 2>&1; then
		minui-presenter --message "$message" \
			--confirm-show --confirm-text "CONTINUE" \
			--cancel-show --cancel-text "CANCEL"
		return $?
	fi

	log "Confirmation UI unavailable: $message"

	return 1
}

save_format_option() {
	case "$1" in
		0) echo 1 ;;
		1) echo 3 ;;
		2) echo 0 ;;
		3) echo 2 ;;
		*) echo 0 ;;
	esac
}

mount_status() {
	local total active tag core

	if [ ! -f "$MOUNT_TABLE" ] || [ ! -f "$ENABLED_FILE" ]; then
		echo "0 mounted"
		return
	fi

	total=0
	active=0

	while IFS='|' read -r tag core; do
		[ -n "$tag" ] && [ -n "$core" ] || continue
		total=$((total + 1))
		mount_matches "$CORES_PATH/$core" "$SAVES_PATH/$tag" &&
			active=$((active + 1))
	done < "$MOUNT_TABLE"

	echo "$active/$total mounted"
}

has_active_mounts() {
	local tag core

	[ -f "$MOUNT_TABLE" ] && [ -f "$ENABLED_FILE" ] || return 1

	while IFS='|' read -r tag core; do
		[ -n "$tag" ] && [ -n "$core" ] || continue
		mount_matches "$CORES_PATH/$core" "$SAVES_PATH/$tag" && return 0
	done < "$MOUNT_TABLE"

	return 1
}

current_settings() {
	local minui_list_file="/tmp/${PAK_NAME}-settings.json"
	local mount_rows="/tmp/${PAK_NAME}-mount-rows.tsv"
	local mount_rows_json="/tmp/${PAK_NAME}-mount-rows.json"
	local format location mounts active mounts_selectable

	rm -f "$minui_list_file" "$mount_rows" "$mount_rows_json"

	format=$(save_format_option "$(get_save_format)")
	location=0
	active=false
	mounts_selectable=false

	if [ -f "$ENABLED_FILE" ]; then
		location=1
		active=true
	fi

	mounts=$(mount_status)

	has_active_mounts && mounts_selectable=true
	write_mount_rows "$mount_rows" || return 1

	jq -Rsc '
		split("\n")
		| map(select(length > 0) | split("\t"))
	' "$mount_rows" > "$mount_rows_json" || return 1

	jq -rM \
		--argjson format "$format" \
		--argjson location "$location" \
		--arg mounts "$mounts" \
		--argjson active "$active" \
		--argjson mounts_selectable "$mounts_selectable" \
		--slurpfile mount_rows "$mount_rows_json" \
		'.settings[1].selected = $format
		| .settings[2].selected = $location
		| .settings[3].options = [$mounts]
		| .settings[3].features.unselectable = false
		| .settings[3].features.show_confirm = true
		| if $active then del(.settings[5]) else del(.settings[6]) end
		| .settings[5].features.unselectable = false
		| del(.settings[5].features.disabled)
		| .conversions[1].name = .conversions[$format + 2].name
		| .mounts[1] as $mount_template
		| .mounts = [.mounts[0]] + ($mount_rows[0]
			| map($mount_template * {name: .[0], options: [.[1]]}))' \
		"$DIR/settings.json" > "$minui_list_file"

	rm -f "$mount_rows" "$mount_rows_json"
	cat "$minui_list_file"
}

main_screen() {
	local settings="$1"
	local minui_list_file="/tmp/${PAK_NAME}-minui-list.json"
	local minui_list_write_location="/tmp/${PAK_NAME}-minui-list-write-location.out"
	local failed_menu_file="$HOME_PATH/minui-list-error.json"
	local exit_code

	rm -f "$minui_list_file" "$minui_list_write_location"
	echo "$settings" > "$minui_list_file"

	minui-list --disable-auto-sleep --file "$minui_list_file" --format json \
		--title "$HUMAN_READABLE_NAME" --title-alignment center --confirm-text "SELECT" \
		--action-button "X" --action-text "CONVERT SAVES" \
		--cancel-text "EXIT" --item-key settings --selected 5 \
		--write-location "$minui_list_write_location" >> "$LOG_FILE" 2>&1
	exit_code=$?

	if [ "$exit_code" -ne 0 ] && [ "$exit_code" -ne 2 ] &&
		[ "$exit_code" -ne 3 ] && [ "$exit_code" -ne 4 ]; then
		cp "$minui_list_file" "$failed_menu_file"
		log "Failing menu JSON saved to $failed_menu_file"
	else
		rm -f "$failed_menu_file"
	fi

	[ -f "$minui_list_write_location" ] && cat "$minui_list_write_location"
	return "$exit_code"
}

conversion_screen() {
	local settings="$1"
	local menu="/tmp/${PAK_NAME}-conversions.json"
	local state="/tmp/${PAK_NAME}-conversion-state.json"
	local rc option target

	rm -f "$menu" "$state"

	if [ -f "$ENABLED_FILE" ]; then
		confirm "Converting saves that are synced to other devices might break compatibility on those devices. Continue?" ||
			return 0
	fi

	echo "$settings" > "$menu"

	minui-list --disable-auto-sleep --file "$menu" --format json \
		--title "Convert Saves" --title-alignment center \
		--confirm-text "CONVERT" --cancel-text "CANCEL" \
		--item-key conversions --selected 2 --write-value state \
		--write-location "$state" >> "$LOG_FILE" 2>&1
	rc=$?

	case "$rc" in
		0)
			option=$(jq -r '.selected - 2' "$state") || return 1
			target=$(conversion_format_for_option "$option") || return 1
			ACTION_RESULT=""
			convert_saves_in_place "$target"
			rc=$?
			[ -n "$ACTION_RESULT" ] ||
				ACTION_RESULT="Conversion failed. See logs/core-saves.txt."
			present "$ACTION_RESULT"
			return "$rc"
			;;
		2|3) return 0 ;;
		*) log "Conversion menu failed with exit code $rc."; return "$rc" ;;
	esac
}

mounts_screen() {
	local settings="$1"
	local menu="/tmp/${PAK_NAME}-mounts.json"
	local rc

	rm -f "$menu"
	echo "$settings" > "$menu"

	minui-list --disable-auto-sleep --file "$menu" --format json \
		--title "Active Mounts" --title-alignment center \
		--confirm-text "BACK" --cancel-text "BACK" \
		--item-key mounts --selected 1 >> "$LOG_FILE" 2>&1
	rc=$?

	case "$rc" in
		0|2|3) return 0 ;;
		*) log "Mount list failed with exit code $rc."; return "$rc" ;;
	esac
}

cleanup() {
	rm -f "/tmp/${PAK_NAME}-settings.json"
	rm -f "/tmp/${PAK_NAME}-minui-list.json"
	rm -f "/tmp/${PAK_NAME}-minui-list-write-location.out"
	rm -f "/tmp/${PAK_NAME}-conversions.json"
	rm -f "/tmp/${PAK_NAME}-conversion-state.json"
	rm -f "/tmp/${PAK_NAME}-mount-rows.tsv"
	rm -f "/tmp/${PAK_NAME}-mount-rows.json"
	rm -f "/tmp/${PAK_NAME}-mounts.json"
}

run_action() {
	local action="$1"
	local rc

	ACTION_RESULT=""

	case "$action" in
		"Convert to RetroArch Core Saves")
			confirm "Back up saves, move mapped systems into /Saves/Cores, and enable boot mounts?" || return
			enable_core_saves
			;;
		"Revert to NextUI Saves")
			confirm "Disable boot mounts and restore only saves that map safely to installed systems? Shared-core saves need exactly one matching ROM; unmatched files stay in /Saves/Cores." || return
			restore_to_legacy current
			;;
	esac
	rc=$?

	[ -n "$ACTION_RESULT" ] || ACTION_RESULT="Operation failed. See logs/core-saves.txt."
	present "$ACTION_RESULT"
	return $rc
}

main() {
	local settings selection rc
	local executable

	trap cleanup EXIT INT TERM HUP QUIT

	case "$PLATFORM" in tg5040|tg5050) ;; *) present "Unsupported platform: $PLATFORM"; return 1 ;; esac
	mkdir -p "$SAVES_PATH"

	if [ -f "$OPERATION_JOURNAL" ]; then
		audit_operation
		rc=$?
		present "$ACTION_RESULT"
		[ "$rc" -eq 0 ] || return "$rc"
	fi

	for executable in minui-list minui-presenter save-rzip jq; do
		chmod +x "$DIR/bin/$PLATFORM/$executable" 2>/dev/null || true
	done

	command -v minui-list >/dev/null 2>&1 &&
		command -v jq >/dev/null 2>&1 || {
		show_progress "Missing $HUMAN_READABLE_NAME UI for $PLATFORM" 100
		return 1
	}

	while :; do
		settings=$(current_settings) || {
			log "Could not build the current settings menu."
			return 1
		}

		selection=$(main_screen "$settings")
		rc=$?

		case "$rc" in
			0)
				[ -n "$selection" ] || continue
				if [ "$selection" = "> Mounts:" ]; then
					mounts_screen "$settings"
				else
					run_action "$selection"
				fi
				;;
			4)
				conversion_screen "$settings"
				;;
			2|3) break ;;
			*)
				log "minui-list failed with exit code $rc. See $LOG_FILE and $HOME_PATH/minui-list-error.json."
				break
				;;
		esac
	done
}

log "$PAK_NAME started on $PLATFORM"
if [ "${CORE_SAVES_SOURCE_ONLY:-0}" != 1 ]; then
	main "$@"
fi
