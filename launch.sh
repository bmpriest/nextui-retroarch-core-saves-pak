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
MAPPING_CONF="$DIR/mapping.conf"

MOUNT_TABLE="$HOME_PATH/mounts.conf"
MANIFEST="$HOME_PATH/migration.manifest"
ENABLED_FILE="$HOME_PATH/enabled"
HOOK_FILE="$HOOK_DIR/core-saves.sync.sh"
LOG_FILE="$LOGS_PATH/core-saves.txt"
REPORT_FILE="$HOME_PATH/conversion-report.txt"
OPERATION_JOURNAL="$HOME_PATH/operation.journal"
OPERATION_STATE="$HOME_PATH/operation-state"

PROFILES_ROOT="$SDCARD_PATH/.profiles"
PROFILES_ACTIVE_FILE="$PROFILES_ROOT/active"
PROFILES_CORE_OWNER_FILE="$PROFILES_ROOT/core-saves-profile"
LEGACY_BACKUP_ROOT="$BACKUP_ROOT"

ACTION_RESULT=""
REPORT_ISSUES=0

# Profiles bind-mounts .profiles/<name>/Saves onto /Saves, so /Saves and the
# canonical profile path are the same directory. Everything this pak mounts or
# writes keeps using /Saves -- NextUI and MinArch have that path hardcoded, and
# re-rooting would only add a dependency on Profiles' internals. The canonical
# path is used for display and for anything stored OUTSIDE /Saves, which is not
# covered by the profile mount and would otherwise be shared between profiles.
active_profile_name() {
	local name

	[ -f "$PROFILES_ACTIVE_FILE" ] || return 1
	name=$(sed -n '1p' "$PROFILES_ACTIVE_FILE")
	[ -n "$name" ] || return 1
	[ -d "$PROFILES_ROOT/$name/Saves" ] || return 1

	printf '%s\n' "$name"
}

ACTIVE_PROFILE=$(active_profile_name) || ACTIVE_PROFILE=""

if [ -n "$ACTIVE_PROFILE" ]; then
	PROFILE_SAVES_PATH="$PROFILES_ROOT/$ACTIVE_PROFILE/Saves"
	BACKUP_ROOT="$PROFILES_ROOT/$ACTIVE_PROFILE/.core-saves-backups"
else
	PROFILE_SAVES_PATH="$SAVES_PATH"
fi

# Backups live outside /Saves, so before this they landed in one SD-root folder
# shared by every profile -- where prune_backups kept only the 5 newest overall
# and one profile's conversions could evict another's. Core Saves has a single
# owner profile, so moving the existing folder under that profile is safe.
adopt_legacy_backups() {
	[ -n "$ACTIVE_PROFILE" ] || return 0
	[ -d "$LEGACY_BACKUP_ROOT" ] || return 0
	[ -e "$BACKUP_ROOT" ] && return 0

	mkdir -p "$(dirname "$BACKUP_ROOT")" || return 1
	mv "$LEGACY_BACKUP_ROOT" "$BACKUP_ROOT"
}

# The canonical path for the current state, shown in the Location row and used
# in the Syncthing guidance. Under Profiles, /Saves is a moving alias that
# Profiles itself refuses to let Syncthing watch.
display_location() {
	local suffix=""

	[ -f "$ENABLED_FILE" ] && suffix="/Cores"

	if [ -n "$ACTIVE_PROFILE" ]; then
		printf '.profiles/%s/Saves%s\n' "$ACTIVE_PROFILE" "$suffix"
	else
		printf '/Saves%s\n' "$suffix"
	fi
}

# Surfaces an ownership mismatch in the menu itself; until now it only appeared
# as a dialog on launch, so a user who dismissed it saw no reason the actions
# were refusing to run.
profile_label() {
	local owner=""

	[ -n "$ACTIVE_PROFILE" ] || return 0
	[ -f "$PROFILES_CORE_OWNER_FILE" ] &&
		owner=$(sed -n '1p' "$PROFILES_CORE_OWNER_FILE")

	if [ -n "$owner" ] && [ "$owner" != "$ACTIVE_PROFILE" ]; then
		printf '%s (owner: %s)\n' "$ACTIVE_PROFILE" "$owner"
	else
		printf '%s\n' "$ACTIVE_PROFILE"
	fi
}

profiles_core_saves_allowed() {
	[ -f "$PROFILES_ACTIVE_FILE" ] || return 0
	active_profile=$(sed -n '1p' "$PROFILES_ACTIVE_FILE")
	[ -n "$active_profile" ] || return 0
	[ -f "$PROFILES_CORE_OWNER_FILE" ] || return 0
	owner_profile=$(sed -n '1p' "$PROFILES_CORE_OWNER_FILE")
	[ -z "$owner_profile" ] || [ "$owner_profile" = "$active_profile" ] || {
		ACTION_RESULT="RetroArch Core Saves is assigned to profile $owner_profile. Disable Profiles or switch back to $owner_profile before changing Core Saves."
		return 1
	}
}

claim_profiles_core_saves_owner() {
	[ -f "$PROFILES_ACTIVE_FILE" ] || return 0
	active_profile=$(sed -n '1p' "$PROFILES_ACTIVE_FILE")
	[ -n "$active_profile" ] || return 0
	mkdir -p "$PROFILES_ROOT" || return 1
	if [ -f "$PROFILES_CORE_OWNER_FILE" ]; then
		[ "$(sed -n '1p' "$PROFILES_CORE_OWNER_FILE")" = "$active_profile" ]
		return $?
	fi
	printf '%s\n' "$active_profile" > "$PROFILES_CORE_OWNER_FILE"
}

adopt_legacy_backups || :
mkdir -p "$LOGS_PATH" "$HOME_PATH" "$BACKUP_ROOT"
[ ! -f "$LOG_FILE" ] || mv "$LOG_FILE" "$LOG_FILE.1"
: > "$LOG_FILE"

# minui-list and minui-presenter are dynamically linked, so they need the same
# library directories the platform's own launcher exports. These are taken from
# each platform's MinUI/NextUI.pak launch.sh; only the vendor directories differ,
# and pointing every platform at Trimui's meant the others were resolving purely
# by luck of the default search path.
platform_library_path() {
	case "$PLATFORM" in
		tg5040|tg5050) echo "/usr/trimui/lib" ;;
		h700) echo "/usr/lib:/usr/lib/aarch64-linux-gnu:/lib/aarch64-linux-gnu" ;;
		my285) echo "/config/lib:/customer/lib:/lib" ;;
	esac
}

# Joined by hand rather than by interpolation: an empty vendor list or an unset
# inherited LD_LIBRARY_PATH would otherwise leave an empty element, and an empty
# element in a loader path means the current directory.
compose_library_path() {
	local path="$SYSTEM_PATH/lib"
	local extra

	extra=$(platform_library_path)
	[ -z "$extra" ] || path="$path:$extra"
	[ -z "${LD_LIBRARY_PATH:-}" ] || path="$path:$LD_LIBRARY_PATH"

	printf '%s\n' "$path"
}

export HOME="$HOME_PATH"
export PATH="$DIR/bin/$PLATFORM:$DIR/bin:$PATH"
LD_LIBRARY_PATH=$(compose_library_path)
export LD_LIBRARY_PATH

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

# Sets MAPPING_SUMMARY ("resolved/mappable") and MAPPING_STALE. Stale means
# re-running the migration would actually change something: either an installed
# emulator is still unmapped, or the live mount table no longer matches what
# discovery now produces (a pak was installed or removed, or mapping.conf
# changed). Runs discovery quietly so rendering the menu never writes a report.
compute_mapping_status() {
	local table="/tmp/${PAK_NAME}-mapping-check.conf"

	MAPPING_RESOLVED=0
	MAPPING_MAPPABLE=0
	MAPPING_STALE=false

	rm -f "$table"
	discover_mappings "$table" quiet || :

	if [ "$MAPPING_RESOLVED" != "$MAPPING_MAPPABLE" ]; then
		MAPPING_STALE=true
	elif [ -f "$ENABLED_FILE" ] && ! cmp -s "$table" "$MOUNT_TABLE"; then
		MAPPING_STALE=true
	fi

	MAPPING_SUMMARY="$MAPPING_RESOLVED/$MAPPING_MAPPABLE"
	rm -f "$table"
}

current_settings() {
	local minui_list_file="/tmp/${PAK_NAME}-settings.json"
	local mount_rows="/tmp/${PAK_NAME}-mount-rows.tsv"
	local mount_rows_json="/tmp/${PAK_NAME}-mount-rows.json"
	local format location mounts active mounts_selectable profile

	rm -f "$minui_list_file" "$mount_rows" "$mount_rows_json"

	format=$(save_format_option "$(get_save_format)")
	profile=$(profile_label)
	location=$(display_location)
	active=false
	mounts_selectable=false

	[ -f "$ENABLED_FILE" ] && active=true

	mounts=$(mount_status)

	has_active_mounts && mounts_selectable=true
	compute_mapping_status
	write_mount_rows "$mount_rows" || return 1

	jq -Rsc '
		split("\n")
		| map(select(length > 0) | split("\t"))
	' "$mount_rows" > "$mount_rows_json" || return 1

	# Rows are matched by name rather than by index: the Profile row is dropped
	# when Profiles is not installed and the action rows are dropped depending
	# on state, so every index-based edit here would have to be renumbered
	# against the others. map with `empty` deletes a row in place.
	jq -rM \
		--argjson format "$format" \
		--arg location "$location" \
		--arg profile "$profile" \
		--arg mounts "$mounts" \
		--argjson active "$active" \
		--argjson mounts_selectable "$mounts_selectable" \
		--arg mapping_summary "$MAPPING_SUMMARY" \
		--argjson stale "$MAPPING_STALE" \
		--slurpfile mount_rows "$mount_rows_json" \
		'.settings |= map(
			if .name == "> Profile:" then
				(if $profile == "" then empty else .options = [$profile] end)
			elif .name == "> Format:" then .selected = $format
			elif .name == "> Location:" then .options = [$location]
			elif .name == "> Mappings:" then .options = [$mapping_summary]
			elif .name == "> Mounts:" then
				.options = [$mounts]
				| .features.unselectable = ($mounts_selectable | not)
				| if $mounts_selectable
					then .features.show_confirm = true
					else .features |= del(.show_confirm) end
			elif .name == "Convert to RetroArch Core Saves" then
				(if $active | not then .features.unselectable = false
				elif $stale then
					.name = "Re-apply Core Save Mappings"
					| .features.unselectable = false
				else empty end)
			elif .name == "Revert to NextUI Saves" then
				(if $active then .features.unselectable = false else empty end)
			else . end)
		| .conversions[1].name = .conversions[$format + 2].name
		| .mounts[1] as $mount_template
		| .mounts = [.mounts[0]] + ($mount_rows[0]
			| map($mount_template * {name: .[0], options: [.[1]]}))' \
		"$DIR/settings.json" > "$minui_list_file" || {
		rm -f "$mount_rows" "$mount_rows_json" "$minui_list_file"
		log "Could not render the settings menu."
		return 1
	}

	rm -f "$mount_rows" "$mount_rows_json"
	cat "$minui_list_file"
}

main_screen() {
	local settings="$1"
	local minui_list_file="/tmp/${PAK_NAME}-minui-list.json"
	local minui_list_write_location="/tmp/${PAK_NAME}-minui-list-write-location.out"
	local failed_menu_file="$HOME_PATH/minui-list-error.json"
	local exit_code selected

	rm -f "$minui_list_file" "$minui_list_write_location"
	echo "$settings" > "$minui_list_file"

	# The cursor lands on the action the current state is most likely to want,
	# preferring Re-apply when it is present. Rows are now added and removed
	# conditionally, so this cannot be a fixed index.
	selected=$(jq '[.settings[].name]
		| (index("Re-apply Core Save Mappings")
			// index("Convert to RetroArch Core Saves")
			// index("Revert to NextUI Saves")
			// 0)' "$minui_list_file") || selected=0

	minui-list --disable-auto-sleep --file "$minui_list_file" --format json \
		--title "$HUMAN_READABLE_NAME" --title-alignment center --confirm-text "SELECT" \
		--action-button "X" --action-text "CONVERT SAVES" \
		--cancel-text "EXIT" --item-key settings --selected "$selected" \
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
	profiles_core_saves_allowed || {
		present "$ACTION_RESULT"
		return 1
	}

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
	rm -f "/tmp/${PAK_NAME}-mapping-check.conf"
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
		"Re-apply Core Save Mappings")
			confirm "Re-check installed emulators and mapping.conf, then move any newly mapped systems into /Saves/Cores? Saves already in /Saves/Cores are left where they are." || return
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

	case "$PLATFORM" in tg5040|tg5050|h700|my285) ;; *) present "Unsupported platform: $PLATFORM"; return 1 ;; esac

	# Restore executable bits before anything needs the UI or the converter,
	# including the recovery pass below.
	for executable in minui-list minui-presenter save-rzip jq; do
		chmod +x "$DIR/bin/$PLATFORM/$executable" 2>/dev/null || true
	done

	if ! profiles_core_saves_allowed; then
		present "$ACTION_RESULT\n\nYou can still use Revert to NextUI Saves for this profile."
	fi

	mkdir -p "$SAVES_PATH"

	if [ -f "$OPERATION_JOURNAL" ]; then
		audit_operation
		rc=$?
		present "$ACTION_RESULT"
		[ "$rc" -eq 0 ] || return "$rc"
	fi

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
