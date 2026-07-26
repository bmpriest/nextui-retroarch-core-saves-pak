#!/bin/sh

DIR=${CORE_SAVES_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}
cd "$DIR" || exit 1

: "${SDCARD_PATH:=/mnt/SDCARD}"
: "${PLATFORM:=tg5040}"
: "${SYSTEM_PATH:=$SDCARD_PATH/.system/$PLATFORM}"
: "${SHARED_USERDATA_PATH:=$SDCARD_PATH/.userdata/shared}"
: "${USERDATA_PATH:=$SDCARD_PATH/.userdata/$PLATFORM}"
: "${LOGS_PATH:=$USERDATA_PATH/logs}"

PAK_NAME="CoreSaves"
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
LIST_BIN="$DIR/bin/$PLATFORM/minui-list"
PRESENTER_BIN="$DIR/bin/$PLATFORM/minui-presenter"
RZIP_BIN="$DIR/bin/$PLATFORM/save-rzip"
UI_DIR="$HOME_PATH/ui"
ACTION_RESULT=""

mkdir -p "$LOGS_PATH" "$HOME_PATH" "$UI_DIR" "$BACKUP_ROOT"
: > "$LOG_FILE"
export HOME="$HOME_PATH"
export PATH="$DIR/bin/$PLATFORM:$PATH"
export LD_LIBRARY_PATH="$SYSTEM_PATH/lib:/usr/trimui/lib:${LD_LIBRARY_PATH:-}"

log() {
	echo "$*" >> "$LOG_FILE"
}

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

save_format_name() {
	case "$1" in
		0) echo "MinUI (.ext.sav)" ;;
		1) echo "RetroArch compressed (.srm)" ;;
		2) echo "Generic (.sav)" ;;
		3) echo "RetroArch uncompressed (.srm)" ;;
		*) echo "Unknown ($1)" ;;
	esac
}

get_save_format() {
	local value=""
	if [ -f "$SETTINGS_PATH" ]; then
		value=$(sed -n 's/^saveFormat=\([0-9][0-9]*\).*/\1/p' "$SETTINGS_PATH" | tail -n 1)
	fi
	echo "${value:-0}"
}

set_save_format() {
	local value="$1"
	local tmp="$SETTINGS_PATH.tmp.$$"
	mkdir -p "$(dirname "$SETTINGS_PATH")" || return 1
	if [ -f "$SETTINGS_PATH" ]; then
		if grep -q '^saveFormat=' "$SETTINGS_PATH"; then
			sed "s/^saveFormat=.*/saveFormat=$value/" "$SETTINGS_PATH" > "$tmp" || return 1
		else
			cp "$SETTINGS_PATH" "$tmp" || return 1
			echo "saveFormat=$value" >> "$tmp"
		fi
	else
		echo "saveFormat=$value" > "$tmp" || return 1
	fi
	mv "$tmp" "$SETTINGS_PATH"
}

retro_core_name_for_emu() {
	case "$1" in
		a5200) echo "a5200" ;;
		bluemsx) echo "blueMSX" ;;
		cap32) echo "Caprice32" ;;
		fake08) echo "FAKE-08" ;;
		fbneo) echo "FinalBurn Neo" ;;
		fceumm) echo "FCEUmm" ;;
		gambatte) echo "Gambatte" ;;
		gearcoleco) echo "Gearcoleco" ;;
		gpsp) echo "gpSP" ;;
		handy) echo "Handy" ;;
		mednafen_pce_fast) echo "Beetle PCE Fast" ;;
		mednafen_supafaust) echo "Supafaust" ;;
		mednafen_vb) echo "Beetle VB" ;;
		mgba) echo "mGBA" ;;
		pcsx_rearmed) echo "PCSX-ReARMed" ;;
		picodrive) echo "PicoDrive" ;;
		pokemini) echo "PokeMini" ;;
		prboom) echo "PrBoom" ;;
		prosystem) echo "ProSystem" ;;
		puae2021) echo "PUAE 2021" ;;
		race) echo "RACE" ;;
		snes9x) echo "Snes9x" ;;
		stella2014) echo "Stella 2014" ;;
		vice_x128) echo "VICE x128" ;;
		vice_x64) echo "VICE x64" ;;
		vice_xpet) echo "VICE xpet" ;;
		vice_xplus4) echo "VICE xplus4" ;;
		vice_xvic) echo "VICE xvic" ;;
		*) echo "$1" ;;
	esac
}

core_for_launch() {
	local tag="$1"
	local launch="$2"
	local override
	local emu
	override=$(awk -F= -v tag="$tag" '$1 == tag { print substr($0, index($0, "=") + 1); exit }' \
		"$DIR/mapping.conf" 2>/dev/null)
	if [ -n "$override" ]; then
		echo "$override"
		return
	fi
	emu=$(sed -n 's/^[	 ]*EMU_EXE=\([^	 #]*\).*/\1/p' "$launch" | tail -n 1)
	[ -n "$emu" ] && retro_core_name_for_emu "$emu"
}

discover_mappings() {
	local output="$1"
	local raw="$output.raw.$$"
	local launch tag core
	: > "$raw" || return 1

	for launch in "$SDCARD_PATH/Emus/$PLATFORM"/*.pak/launch.sh "$SYSTEM_PATH/paks/Emus"/*.pak/launch.sh; do
		[ -f "$launch" ] || continue
		tag=$(basename "$(dirname "$launch")" .pak)
		if awk -F'|' -v tag="$tag" '$1 == tag { found=1 } END { exit !found }' "$raw"; then
			continue
		fi
		core=$(core_for_launch "$tag" "$launch")
		[ -n "$core" ] && printf '%s|%s\n' "$tag" "$core" >> "$raw"
	done

	sort -t '|' -k1,1 "$raw" > "$output" || {
		rm -f "$raw"
		return 1
	}
	rm -f "$raw"
	[ -s "$output" ]
}

is_mounted() {
	local target="$1"
	awk -v target="$target" '$2 == target { found=1 } END { exit !found }' /proc/mounts 2>/dev/null
}

unmount_table() {
	local table="$1"
	local tag core target
	[ -f "$table" ] || return 0
	while IFS='|' read -r tag core; do
		[ -n "$tag" ] || continue
		target="$SAVES_PATH/$tag"
		if is_mounted "$target"; then
			umount "$target" >> "$LOG_FILE" 2>&1 || return 1
		fi
	done < "$table"
}

install_boot_hook() {
	mkdir -p "$HOOK_DIR" || return 1
	cp "$DIR/mount.sh" "$HOME_PATH/mount.sh" || return 1
	chmod 0755 "$HOME_PATH/mount.sh" || return 1
	{
		echo '#!/bin/sh'
		printf 'exec "%s"\n' "$HOME_PATH/mount.sh"
	} > "$HOOK_FILE" || return 1
	chmod 0755 "$HOOK_FILE"
}

run_mounts() {
	"$HOME_PATH/mount.sh" >> "$LOG_FILE" 2>&1
}

restore_previous_mounts() {
	[ -f "$ENABLED_FILE" ] || return 0
	[ -x "$HOME_PATH/mount.sh" ] || return 0
	run_mounts || log "Could not restore the previous mounts after an error."
}

create_core_folders() {
	local table="$1"
	local tag core
	mkdir -p "$CORES_PATH" || return 1
	while IFS='|' read -r tag core; do
		[ -n "$tag" ] && [ -n "$core" ] || continue
		mkdir -p "$CORES_PATH/$core" "$SAVES_PATH/$tag" || return 1
	done < "$table"
}

make_backup() {
	local label="$1"
	local ts backup n
	ts=$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now)
	backup="$BACKUP_ROOT/$ts-$label"
	n=0
	while [ -e "$backup" ]; do
		n=$((n + 1))
		backup="$BACKUP_ROOT/$ts-$label-$$-$n"
	done
	mkdir -p "$backup" || return 1
	mkdir -p "$backup/Saves" || return 1
	cp -a "$SAVES_PATH"/. "$backup/Saves"/ || return 1
	if [ -f "$SETTINGS_PATH" ]; then
		cp -p "$SETTINGS_PATH" "$backup/minuisettings.txt" || return 1
		echo 1 > "$backup/settings-existed"
	else
		echo 0 > "$backup/settings-existed"
	fi
	echo "$backup"
}

strip_short_ext() {
	local name="$1"
	local base=${name%.*}
	local ext=${name##*.}
	local len
	if [ "$base" != "$name" ]; then
		len=${#ext}
		if [ "$len" -ge 1 ] && [ "$len" -le 4 ]; then
			echo "$base"
			return
		fi
	fi
	echo "$name"
}

core_target_name() {
	local base="$1"
	local format="$2"
	local stem stripped
	case "$format:$base" in
		0:*.sav)
			stem=${base%.sav}
			stripped=$(strip_short_ext "$stem")
			if [ "$stripped" != "$stem" ]; then
				echo "$stripped.srm"
			else
				echo "$base"
			fi
			;;
		2:*.sav) echo "${base%.sav}.srm" ;;
		*) echo "$base" ;;
	esac
}

unique_path() {
	local dst="$1"
	local dir base stem ext n candidate
	if [ ! -e "$dst" ]; then
		echo "$dst"
		return
	fi
	dir=$(dirname "$dst")
	base=$(basename "$dst")
	stem=${base%.*}
	ext=${base##*.}
	n=1
	while :; do
		if [ "$stem" != "$base" ]; then
			candidate="$dir/$stem.core-saves-conflict-$n.$ext"
		else
			candidate="$dir/$base.core-saves-conflict-$n"
		fi
		if [ ! -e "$candidate" ]; then
			echo "$candidate"
			return
		fi
		n=$((n + 1))
	done
}

copy_save_file() {
	local source="$1"
	local destination="$2"
	local mode="$3"
	case "$mode" in
		copy)
			if cp -p "$source" "$destination"; then
				return 0
			fi
			;;
		decode)
			[ -x "$RZIP_BIN" ] || {
				log "Missing save converter: $RZIP_BIN"
				return 1
			}
			if "$RZIP_BIN" decode "$source" "$destination" \
				>> "$LOG_FILE" 2>&1; then
				return 0
			fi
			;;
		*)
			log "Unknown save copy mode: $mode"
			return 1
			;;
	esac
	rm -f "$destination"
	return 1
}

migrate_tag() {
	local tag="$1"
	local core="$2"
	local format="$3"
	local src="$SAVES_PATH/$tag"
	local dst_root="$CORES_PATH/$core"
	local file rel rel_dir original_base base dst final mode
	[ -d "$src" ] || {
		mkdir -p "$src"
		return
	}

	find "$src" -type f | while IFS= read -r file; do
		rel=${file#"$src"/}
		rel_dir=$(dirname "$rel")
		original_base=$(basename "$file")
		base=$(core_target_name "$original_base" "$format")
		if [ "$rel_dir" = "." ]; then
			dst="$dst_root/$base"
		else
			dst="$dst_root/$rel_dir/$base"
		fi
		mkdir -p "$(dirname "$dst")" || exit 1
		final=$(unique_path "$dst")
		mode=copy
		[ "$base" != "$original_base" ] && mode=decode
		copy_save_file "$file" "$final" "$mode" || exit 1
		printf '%s|%s\n' "${final#"$CORES_PATH"/}" "$tag/$rel" >> "$MANIFEST"
		[ "$final" = "$dst" ] || log "Conflict preserved as: $final"
	done
}

clear_mountpoint() {
	local tag="$1"
	local path="$SAVES_PATH/$tag"
	[ -d "$path" ] || {
		mkdir -p "$path"
		return
	}
	rm -rf "$path" || return 1
	mkdir -p "$path"
}

enable_core_saves() {
	local format tmp was_enabled backup tag core
	format=$(get_save_format)
	case "$format" in 0|1|2|3) ;; *) ACTION_RESULT="Unknown save format: $format"; return 1 ;; esac
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
			ACTION_RESULT="Migration failed. The backup is unchanged."
			return 1
		}
	done < "$tmp"

	while IFS='|' read -r tag core; do
		clear_mountpoint "$tag" || {
			[ "$was_enabled" = 1 ] && restore_previous_mounts
			ACTION_RESULT="Could not prepare /Saves/$tag."
			return 1
		}
	done < "$tmp"

	if [ "$format" = 0 ] || [ "$format" = 2 ]; then
		set_save_format 3 || {
			ACTION_RESULT="Could not set RetroArch uncompressed format."
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
		ACTION_RESULT="Saves migrated, but one or more mounts failed. See the log."
		return 1
	}
	sync
	ACTION_RESULT="Core saves are active.
Sync /Saves/Cores with SyncThing."
}

refresh_folders() {
	local tmp="$HOME_PATH/mounts.new.$$"
	discover_mappings "$tmp" || {
		rm -f "$tmp"
		ACTION_RESULT="No emulator mappings were found."
		return 1
	}
	create_core_folders "$tmp" || return 1
	if [ -f "$ENABLED_FILE" ]; then
		unmount_table "$MOUNT_TABLE" || return 1
		mv "$tmp" "$MOUNT_TABLE" || return 1
		install_boot_hook || return 1
		run_mounts || return 1
	else
		rm -f "$tmp"
	fi
	sync
	ACTION_RESULT="Core folders refreshed from installed emulator paks."
}

legacy_name_for_file() {
	local core_rel="$1"
	local format="$2"
	local base
	base=$(basename "$core_rel")
	case "$format:$base" in
		2:*.srm) echo "${base%.srm}.sav"; return ;;
	esac
	echo "$base"
}

restore_to_legacy() {
	local requested_format="$1"
	local current_format target_format backup stage
	local tag core src dst_root file rel subrel rel_dir original_base base
	local dst final mode
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
	unmount_table "$MOUNT_TABLE" || {
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
		find "$src" -type f | while IFS= read -r file; do
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
			mkdir -p "$(dirname "$dst")" || exit 1
			final=$(unique_path "$dst")
			mode=copy
			if [ "$target_format" = 2 ] &&
				[ "$base" != "$original_base" ]; then
				mode=decode
			fi
			copy_save_file "$file" "$final" "$mode" || exit 1
		done || {
			rm -rf "$stage"
			restore_previous_mounts
			ACTION_RESULT="Could not restore one or more save files."
			return 1
		}
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
		rm -rf "$SAVES_PATH/$tag" || return 1
		mv "$stage/$tag" "$SAVES_PATH/$tag" || {
			ACTION_RESULT="Restore staging failed. Recover from: $backup"
			return 1
		}
	done < "$MOUNT_TABLE"
	rm -rf "$stage"
	sync
	ACTION_RESULT="Saves now point to /Saves using $(save_format_name "$target_format").
Backup: $backup"
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

mount_status() {
	local total active tag core
	if [ ! -f "$MOUNT_TABLE" ] || [ ! -f "$ENABLED_FILE" ]; then
		echo "Inactive"
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

write_menu() {
	local menu="$1"
	local format location mounts
	format=$(save_format_name "$(get_save_format)")
	location=$(location_name)
	mounts=$(mount_status)
	{
		echo '{'
		echo '  "items": ['
		printf '    {"name":"Save format: %s","features":{"is_header":true,"unselectable":true}},\n' "$format"
		printf '    {"name":"Save location: %s","features":{"is_header":true,"unselectable":true}},\n' "$location"
		printf '    {"name":"Mounts: %s","features":{"is_header":true,"unselectable":true}},\n' "$mounts"
		echo '    {"name":"Create or refresh core folders"},'
		if [ -f "$ENABLED_FILE" ]; then
			echo '    {"name":"Import saves into Cores"},'
			echo '    {"name":"Restore to /Saves as .srm"},'
			echo '    {"name":"Restore to /Saves as .sav"},'
		else
			echo '    {"name":"Move saves to /Saves/Cores"},'
			if [ -d "$CORES_PATH" ]; then
				echo '    {"name":"Delete /Saves/Cores"},'
			fi
		fi
		echo '    {"name":"Save compatibility"}'
		echo '  ]'
		echo '}'
	} > "$menu"
}

show_compatibility() {
	present "Raw MinUI, Generic, and uncompressed .srm saves use the same SRAM bytes; changing those filenames is normally sufficient.

Compressed .srm files have a #RZIPv header. CoreSaves decodes them when restoring as Generic .sav. Saves can also differ between emulator cores, and RTC or memory-card files must be kept with the SRAM."
}

run_action() {
	local action="$1"
	local rc
	ACTION_RESULT=""
	case "$action" in
		"Create or refresh core folders")
			refresh_folders
			;;
		"Move saves to /Saves/Cores"|"Import saves into Cores")
			confirm "Back up saves, move mapped systems into /Saves/Cores, and enable boot mounts?" || return
			enable_core_saves
			;;
		"Restore to /Saves as .srm")
			confirm "Copy current core saves back as .srm files and disable boot mounts?" || return
			restore_to_legacy current
			;;
		"Restore to /Saves as .sav")
			confirm "Convert .srm saves to Generic .sav, copy them back, and disable boot mounts?" || return
			restore_to_legacy generic
			;;
		"Delete /Saves/Cores")
			confirm "Back up and permanently delete /Saves/Cores?" || return
			delete_core_tree
			;;
		"Save compatibility")
			show_compatibility
			return
			;;
	esac
	rc=$?
	[ -n "$ACTION_RESULT" ] || ACTION_RESULT="Operation failed. See logs/core-saves.txt."
	present "$ACTION_RESULT"
	return $rc
}

main() {
	local menu selection rc
	case "$PLATFORM" in tg5040|tg5050) ;; *) present "Unsupported platform: $PLATFORM"; return 1 ;; esac
	[ -x "$LIST_BIN" ] || {
		show_progress "Missing CoreSaves UI for $PLATFORM" 100
		return 1
	}
	mkdir -p "$SAVES_PATH"

	while :; do
		menu="$UI_DIR/menu.json"
		selection="$UI_DIR/selection.txt"
		rm -f "$selection"
		write_menu "$menu"
		"$LIST_BIN" --file "$menu" --item-key items --title "Core Saves" \
			--confirm-text "SELECT" --cancel-text "EXIT" \
			--write-location "$selection"
		rc=$?
		case "$rc" in
			0)
				[ -f "$selection" ] || continue
				run_action "$(cat "$selection")"
				;;
			2|3) break ;;
			*) log "minui-list failed with exit code $rc"; break ;;
		esac
	done
}

log "$PAK_NAME started on $PLATFORM"
if [ "${CORE_SAVES_SOURCE_ONLY:-0}" != 1 ]; then
	main "$@"
fi
