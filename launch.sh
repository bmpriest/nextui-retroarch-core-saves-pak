#!/bin/sh

DIR=${CORE_SAVES_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}
cd "$DIR" || exit 1
PAK_NAME=$(basename "$DIR")
PAK_NAME=${PAK_NAME%.pak}

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
MOUNT_TABLE="$HOME_PATH/mounts.conf"
MANIFEST="$HOME_PATH/migration.manifest"
ENABLED_FILE="$HOME_PATH/enabled"
HOOK_DIR="$USERDATA_PATH/.hooks/boot.d"
HOOK_FILE="$HOOK_DIR/core-saves.sync.sh"
BACKUP_ROOT="$SDCARD_PATH/.core-saves-backups"
LOG_FILE="$LOGS_PATH/core-saves.txt"
REPORT_FILE="$HOME_PATH/conversion-report.txt"
LIST_BIN="$DIR/bin/$PLATFORM/minui-list"
PRESENTER_BIN="$DIR/bin/$PLATFORM/minui-presenter"
RZIP_BIN="$DIR/bin/$PLATFORM/save-rzip"
JQ_BIN="$DIR/bin/$PLATFORM/jq"
ACTION_RESULT=""
REPORT_ISSUES=0

mkdir -p "$LOGS_PATH" "$HOME_PATH" "$BACKUP_ROOT"
: > "$LOG_FILE"
export HOME="$HOME_PATH"
export PATH="$DIR/bin/$PLATFORM:$PATH"
export LD_LIBRARY_PATH="$SYSTEM_PATH/lib:/usr/trimui/lib:${LD_LIBRARY_PATH:-}"

for library in report settings mappings mounts backup save-format; do
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
	if [ -x "$PRESENTER_BIN" ]; then
		"$PRESENTER_BIN" --message "$message" --confirm-show --confirm-text "OK"
	else
		show_progress "$message" 100
	fi
}

confirm() {
	local message="$1"
	if [ -x "$PRESENTER_BIN" ]; then
		"$PRESENTER_BIN" --message "$message" \
			--confirm-show --confirm-text "CONTINUE" \
			--cancel-show --cancel-text "CANCEL"
		return $?
	fi
	log "Confirmation UI unavailable: $message"
	return 1
}

preflight_migration() {
	local table="$1"
	local files="$HOME_PATH/migration-files.$$"
	local tag core src

	while IFS='|' read -r tag core; do
		[ -n "$tag" ] && [ -n "$core" ] || continue
		src="$SAVES_PATH/$tag"
		[ -d "$src" ] || continue
		write_file_list "$src" "$files" || {
			rm -f "$files"
			ACTION_RESULT="Could not inspect /Saves/$tag."
			report_issue "$ACTION_RESULT"
			return 1
		}
	done < "$table"
	rm -f "$files"
}

migrate_tag() {
	local tag="$1"
	local core="$2"
	local format="$3"
	local src="$SAVES_PATH/$tag"
	local dst_root="$CORES_PATH/$core"
	local file rel rel_dir original_base base dst final mode files
	[ -d "$src" ] || {
		mkdir -p "$src"
		return
	}

	files="$HOME_PATH/migrate-$tag-files.$$"
	write_file_list "$src" "$files" || {
		rm -f "$files"
		ACTION_RESULT="Could not inspect /Saves/$tag."
		return 1
	}
	while IFS= read -r file; do
		rel=${file#"$src"/}
		rel_dir=$(dirname "$rel")
		original_base=$(basename "$file")
		base=$(core_target_name "$original_base" "$format")
		if [ "$rel_dir" = "." ]; then
			dst="$dst_root/$base"
		else
			dst="$dst_root/$rel_dir/$base"
		fi
		mkdir -p "$(dirname "$dst")" || {
			rm -f "$files"
			return 1
		}
		mode=copy
		final=$(unique_path "$dst")
		if [ "$final" != "$dst" ]; then
			report_issue "Collision: $file was copied to $final. Review both saves and choose the correct one."
		fi
		copy_save_file "$file" "$final" "$mode" || {
			rm -f "$files"
			report_issue "Could not copy $file to $final."
			return 1
		}
		printf '%s|%s\n' "${final#"$CORES_PATH"/}" "$tag/$rel" >> "$MANIFEST"
	done < "$files"
	rm -f "$files"
}

enable_core_saves() {
	local format tmp was_enabled backup tag core
	format=$(get_save_format)
	case "$format" in 0|1|2|3) ;; *) ACTION_RESULT="Unknown save format: $format"; return 1 ;; esac
	start_report "Move or import saves into /Saves/Cores"
	tmp="$HOME_PATH/mounts.new.$$"
	discover_mappings "$tmp" || {
		rm -f "$tmp"
		ACTION_RESULT="No emulator mappings were found."
		return 1
	}

	was_enabled=0
	[ -f "$ENABLED_FILE" ] && was_enabled=1
	unmount_table "$MOUNT_TABLE" || {
		rm -f "$tmp"
		ACTION_RESULT="Could not unmount an existing save folder."
		return 1
	}
	preflight_migration "$tmp" || {
		rm -f "$tmp"
		[ "$was_enabled" = 1 ] && restore_previous_mounts
		finish_report
		ACTION_RESULT="$ACTION_RESULT
Report: $REPORT_FILE"
		return 1
	}

	show_progress "Backing up saves..." 10
	backup=$(make_backup enable) || {
		rm -f "$tmp"
		[ "$was_enabled" = 1 ] && restore_previous_mounts
		ACTION_RESULT="Could not back up the Saves folder."
		return 1
	}
	create_core_folders "$tmp" || {
		[ "$was_enabled" = 1 ] && restore_previous_mounts
		return 1
	}
	: > "$MANIFEST"

	show_progress "Moving saves into Cores..." 45
	while IFS='|' read -r tag core; do
		migrate_tag "$tag" "$core" "$format" || {
			[ "$was_enabled" = 1 ] && restore_previous_mounts
			report_issue "Migration stopped while processing /Saves/$tag."
			finish_report
			ACTION_RESULT="Migration failed. The backup is unchanged.
Report: $REPORT_FILE"
			return 1
		}
	done < "$tmp"

	while IFS='|' read -r tag core; do
		clear_mountpoint "$tag" || {
			[ "$was_enabled" = 1 ] && restore_previous_mounts
			report_issue "Could not empty /Saves/$tag for its bind mount."
			finish_report
			ACTION_RESULT="Could not prepare /Saves/$tag.
Report: $REPORT_FILE"
			return 1
		}
	done < "$tmp"

	if [ "$format" = 0 ] || [ "$format" = 2 ]; then
		set_save_format 3 || {
			report_issue "Could not set RetroArch uncompressed format."
			finish_report
			ACTION_RESULT="Could not set RetroArch uncompressed format.
Report: $REPORT_FILE"
			return 1
		}
	fi

	mv "$tmp" "$MOUNT_TABLE" || return 1
	{
		echo "backup=$backup"
		echo "old_format=$format"
		echo "enabled_at=$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now)"
	} > "$ENABLED_FILE"
	install_boot_hook || return 1
	show_progress "Mounting core save folders..." 80
	run_mounts || {
		report_issue "Saves were copied, but one or more bind mounts failed."
		finish_report
		ACTION_RESULT="Saves migrated, but one or more mounts failed.
Report: $REPORT_FILE"
		return 1
	}
	sync
	finish_report
	ACTION_RESULT="Core saves are active.
Sync /Saves/Cores with SyncThing.$(report_notice)"
}

restore_to_legacy() {
	local requested_format="$1"
	local current_format target_format backup stage
	local tag core src dst_root file rel subrel rel_dir original_base base
	local dst final mode files
	[ -f "$ENABLED_FILE" ] || {
		ACTION_RESULT="Core saves are not active."
		return 1
	}
	current_format=$(get_save_format)
	case "$current_format" in 0|1|2|3) ;; *) current_format=3 ;; esac
	if [ "$requested_format" = "generic" ]; then
		target_format=2
	else
		target_format="$current_format"
	fi
	start_report "Restore saves to /Saves as $(save_format_name "$target_format")"
	unmount_table "$MOUNT_TABLE" || {
		report_issue "Could not unmount the core save folders."
		finish_report
		ACTION_RESULT="Could not unmount the core save folders."
		return 1
	}
	backup=$(make_backup restore) || {
		restore_previous_mounts
		ACTION_RESULT="Could not back up the current saves."
		return 1
	}

	show_progress "Restoring /Saves folders..." 45
	stage="$HOME_PATH/restore-stage.$$"
	rm -rf "$stage"
	mkdir -p "$stage" || {
		restore_previous_mounts
		ACTION_RESULT="Could not create restore staging."
		return 1
	}
	while IFS='|' read -r tag core; do
		src="$CORES_PATH/$core"
		dst_root="$stage/$tag"
		mkdir -p "$dst_root" || {
			rm -rf "$stage"
			restore_previous_mounts
			return 1
		}
		if [ -d "$SAVES_PATH/$tag" ]; then
			cp -a "$SAVES_PATH/$tag"/. "$dst_root"/ || {
				rm -rf "$stage"
				restore_previous_mounts
				ACTION_RESULT="Could not stage the existing /Saves/$tag folder."
				return 1
			}
		fi
		[ -d "$src" ] || continue
		files="$HOME_PATH/restore-$tag-files.$$"
		write_file_list "$src" "$files" || {
			rm -f "$files" "$stage"
			restore_previous_mounts
			ACTION_RESULT="Could not inspect core saves for $tag."
			return 1
		}
		while IFS= read -r file; do
			rel=${file#"$CORES_PATH"/}
			subrel=${file#"$src"/}
			rel_dir=$(dirname "$subrel")
			original_base=$(basename "$file")
			base=$(legacy_name_for_file "$rel" "$target_format")
			if [ "$rel_dir" = "." ]; then
				dst="$dst_root/$base"
			else
				dst="$dst_root/$rel_dir/$base"
			fi
			mkdir -p "$(dirname "$dst")" || {
				rm -f "$files"
				rm -rf "$stage"
				restore_previous_mounts
				return 1
			}
			final=$(unique_path "$dst")
			if [ "$final" != "$dst" ]; then
				report_issue "Collision: $file was restored to $final. Review both saves and choose the correct one."
			fi
			mode=copy
			if [ "$target_format" = 2 ] &&
				[ "$base" != "$original_base" ]; then
				mode=decode
			fi
			copy_save_file "$file" "$final" "$mode" || {
				rm -f "$files"
				rm -rf "$stage"
				restore_previous_mounts
				report_issue "Could not convert or copy $file to $final."
				finish_report
				ACTION_RESULT="Could not restore one or more save files.
Report: $REPORT_FILE"
				return 1
			}
		done < "$files" || {
			rm -f "$files"
			rm -rf "$stage"
			restore_previous_mounts
			ACTION_RESULT="Could not restore one or more save files."
			return 1
		}
		rm -f "$files"
	done < "$MOUNT_TABLE"

	set_save_format "$target_format" || {
		rm -rf "$stage"
		restore_previous_mounts
		ACTION_RESULT="Could not update the save format."
		return 1
	}

	rm -f "$HOOK_FILE" "$ENABLED_FILE"
	while IFS='|' read -r tag core; do
		[ -n "$tag" ] || continue
		clear_mountpoint "$tag" || return 1
		cp -a "$stage/$tag"/. "$SAVES_PATH/$tag"/ || {
			ACTION_RESULT="Restore staging failed. Recover from: $backup"
			return 1
		}
	done < "$MOUNT_TABLE"
	rm -rf "$stage"
	sync
	finish_report
	ACTION_RESULT="Saves now point to /Saves using $(save_format_name "$target_format").
Backup: $backup$(report_notice)"
}

delete_core_tree() {
	local backup
	[ ! -f "$ENABLED_FILE" ] || {
		ACTION_RESULT="Restore saves to /Saves before deleting Cores."
		return 1
	}
	[ -d "$CORES_PATH" ] || {
		ACTION_RESULT="/Saves/Cores does not exist."
		return 0
	}
	backup=$(make_backup delete) || {
		ACTION_RESULT="Could not back up the current saves."
		return 1
	}
	rm -rf "$CORES_PATH" || return 1
	sync
	ACTION_RESULT="/Saves/Cores deleted.
Backup: $backup"
}

location_name() {
	if [ -f "$ENABLED_FILE" ]; then
		echo "/Saves/Cores"
	else
		echo "/Saves"
	fi
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
		[ -n "$tag" ] || continue
		total=$((total + 1))
		is_mounted "$SAVES_PATH/$tag" && active=$((active + 1))
	done < "$MOUNT_TABLE"
	echo "$active/$total mounted"
}

current_settings() {
	local minui_list_file="/tmp/${PAK_NAME}-settings.json"
	local format location mounts active
	rm -f "$minui_list_file"

	format=$(save_format_option "$(get_save_format)")
	location=0
	active=false
	if [ -f "$ENABLED_FILE" ]; then
		location=1
		active=true
	fi
	mounts=$(mount_status)

	"$JQ_BIN" -rM \
		--argjson format "$format" \
		--argjson location "$location" \
		--arg mounts "$mounts" \
		--argjson active "$active" \
		'.settings[1].selected = $format
		| .settings[2].selected = $location
		| .settings[3].options = [$mounts]
		| if $active then del(.settings[5]) else del(.settings[6]) end
		| .settings[5].features.unselectable = false
		| del(.settings[5].features.disabled)
		| .conversions[1].name = .settings[1].options[$format]' \
		"$DIR/settings.json" > "$minui_list_file"

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

	"$LIST_BIN" --disable-auto-sleep --file "$minui_list_file" --format json \
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
	echo "$settings" > "$menu"
	"$LIST_BIN" --disable-auto-sleep --file "$menu" --format json \
		--title "Convert Saves" --title-alignment center \
		--confirm-text "CONVERT" --cancel-text "CANCEL" \
		--item-key conversions --selected 1 --write-value state \
		--write-location "$state" >> "$LOG_FILE" 2>&1
	rc=$?
	case "$rc" in
		0)
			option=$("$JQ_BIN" -r '.items[1].selected' "$state") || return 1
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

cleanup() {
	rm -f "/tmp/${PAK_NAME}-settings.json"
	rm -f "/tmp/${PAK_NAME}-minui-list.json"
	rm -f "/tmp/${PAK_NAME}-minui-list-write-location.out"
	rm -f "/tmp/${PAK_NAME}-conversions.json"
	rm -f "/tmp/${PAK_NAME}-conversion-state.json"
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
			confirm "Copy current core saves back as .srm files and disable boot mounts?" || return
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
	trap cleanup EXIT INT TERM HUP QUIT
	case "$PLATFORM" in tg5040|tg5050) ;; *) present "Unsupported platform: $PLATFORM"; return 1 ;; esac
	for executable in "$LIST_BIN" "$PRESENTER_BIN" "$RZIP_BIN" "$JQ_BIN"; do
		chmod +x "$executable" 2>/dev/null || true
	done
	[ -x "$LIST_BIN" ] && [ -x "$JQ_BIN" ] || {
		show_progress "Missing $HUMAN_READABLE_NAME UI for $PLATFORM" 100
		return 1
	}
	mkdir -p "$SAVES_PATH"

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
				run_action "$selection"
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
