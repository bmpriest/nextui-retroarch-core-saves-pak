#!/bin/sh

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
			if [ "$stripped" != "$stem" ]; then echo "$stripped.srm"; else echo "$base"; fi
			;;
		2:*.sav) echo "${base%.sav}.srm" ;;
		*) echo "$base" ;;
	esac
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

# Returns a path to write $dst to. With a $source, an existing file that already
# holds those exact bytes is returned instead of a fresh conflict name, so
# repeated migrations reuse the copy they made last time rather than stacking up
# identical core-conflict-N duplicates. Callers distinguish the two outcomes with
# [ -e "$result" ]: an existing path means "already there, nothing to copy".
unique_path() {
	local dst="$1"
	local source="${2:-}"
	local dir base stem ext n candidate
	if [ ! -e "$dst" ]; then echo "$dst"; return; fi
	if [ -n "$source" ] && cmp -s "$source" "$dst"; then echo "$dst"; return; fi
	dir=$(dirname "$dst")
	base=$(basename "$dst")
	stem=${base%.*}
	ext=${base##*.}
	n=1
	while :; do
		if [ "$stem" != "$base" ]; then
			candidate="$dir/$stem.core-conflict-$n.$ext"
		else
			candidate="$dir/$base.core-conflict-$n"
		fi
		if [ ! -e "$candidate" ]; then echo "$candidate"; return; fi
		if [ -n "$source" ] && cmp -s "$source" "$candidate"; then
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
		copy) cp -p "$source" "$destination" && return 0 ;;
		decode)
			command -v save-rzip >/dev/null 2>&1 || {
				log "Missing save converter: save-rzip"
				return 1
			}
			save-rzip decode "$source" "$destination" >> "$LOG_FILE" 2>&1 &&
				return 0
			;;
		*) log "Unknown save copy mode: $mode"; return 1 ;;
	esac
	rm -f "$destination"
	return 1
}

write_file_list() {
	local root="$1"
	local output="$2"
	find "$root" -type f > "$output"
}

clear_mountpoint() {
	local tag="$1"
	local path
	# Without this guard an empty tag would expand to rm -rf "$SAVES_PATH"/*
	# and take the whole save tree, Cores included.
	[ -n "$tag" ] || return 1
	path="$SAVES_PATH/$tag"
	[ -d "$path" ] || {
		mkdir -p "$path"
		return
	}
	rm -rf "$path"/* "$path"/.[!.]* "$path"/..?*
}

conversion_root() {
	if [ -f "$ENABLED_FILE" ]; then
		echo "$CORES_PATH"
	else
		echo "$SAVES_PATH"
	fi
}

conversion_format_for_option() {
	case "$1" in
		0) echo 2 ;;
		1) echo 0 ;;
		2) echo 3 ;;
		3) echo 1 ;;
		*) return 1 ;;
	esac
}

conversion_find_files() {
	local root="$1"
	local pattern="$2"
	local core
	if [ "$root" = "$SAVES_PATH" ]; then
		find "$root" -path "$CORES_PATH" -prune -o -type f -name "$pattern" -print
	elif [ "$root" = "$CORES_PATH" ]; then
		[ -f "$MOUNT_TABLE" ] || return 0
		awk -F'|' 'NF >= 2 && !seen[$2]++ { print $2 }' "$MOUNT_TABLE" |
			while IFS= read -r core; do
				[ -d "$CORES_PATH/$core" ] || continue
				find "$CORES_PATH/$core" -type f -name "$pattern"
			done
	else
		find "$root" -type f -name "$pattern"
	fi
}

# Indexes every ROM once as "<stem>\t<filename>", where <stem> is the awk
# equivalent of strip_short_ext. Building this up front replaces a full ROM-tree
# walk plus a basename fork per ROM for every save file being converted.
build_rom_stem_index() {
	local output="$1"
	find "$ROMS_PATH" -type f 2>/dev/null |
		awk -F/ '
			{
				base = $NF
				n = split(base, parts, ".")
				ext = (n < 2) ? "" : parts[n]
				if (n < 2 || length(ext) < 1 || length(ext) > 4) {
					print base "\t" base
					next
				}
				print substr(base, 1, length(base) - length(ext) - 1) "\t" base
			}
		' | LC_ALL=C sort -u > "$output"
}

conversion_minui_name() {
	local stem="$1"
	local index="$2"
	local matches count
	[ -f "$index" ] || return 1
	matches=$(awk -F'\t' -v stem="$stem" '$1 == stem { print $2 }' "$index")
	[ -n "$matches" ] || return 1
	count=$(printf '%s\n' "$matches" | wc -l | tr -d ' ')
	[ "$count" = 1 ] || return 1
	printf '%s\n' "$matches"
}

build_conversion_plan() {
	local root="$1"
	local source_format="$2"
	local target_format="$3"
	local plan="$4"
	local unresolved="$5"
	local rom_index="$plan.roms"
	local pattern file rel parent base without_save stem stripped
	local destination_name destination mode minui_name
	: > "$plan"
	: > "$unresolved"
	case "$source_format" in
		0|2) pattern='*.sav' ;;
		1|3) pattern='*.srm' ;;
		*) return 1 ;;
	esac

	if [ "$target_format" = 0 ]; then
		build_rom_stem_index "$rom_index" || {
			rm -f "$rom_index"
			return 1
		}
	fi

	conversion_find_files "$root" "$pattern" | while IFS= read -r file; do
		rel=${file#"$root"/}
		parent=$(dirname "$file")
		base=$(basename "$file")
		case "$source_format" in
			0)
				without_save=${base%.sav}
				stripped=$(strip_short_ext "$without_save")
				if [ "$stripped" = "$without_save" ]; then
					printf 'No ROM extension to convert from: %s\n' "$rel" \
						>> "$unresolved"
					continue
				fi
				stem="$stripped"
				;;
			2) stem=${base%.sav} ;;
			1|3) stem=${base%.srm} ;;
		esac

		case "$target_format" in
			0)
				minui_name=$(conversion_minui_name "$stem" "$rom_index")
				if [ -z "$minui_name" ]; then
					printf 'No single matching ROM for: %s\n' "$rel" >> "$unresolved"
					continue
				fi
				destination_name="$minui_name.sav"
				;;
			1|3) destination_name="$stem.srm" ;;
			2) destination_name="$stem.sav" ;;
			*) exit 1 ;;
		esac
		destination="$parent/$destination_name"
		if [ "$destination" != "$file" ] && [ -e "$destination" ]; then
			printf 'Conflict: %s -> %s\n' "$rel" "${destination#"$root"/}" >> "$unresolved"
			continue
		fi
		if [ "$target_format" = 1 ]; then mode=encode; else mode=decode; fi
		printf '%s\t%s\t%s\n' "$file" "$destination" "$mode" >> "$plan"
	done

	rm -f "$rom_index"

	[ ! -s "$unresolved" ] || return 1
	if cut -f2 "$plan" | sort | uniq -d | grep -q .; then
		echo "Multiple saves resolve to the same destination." > "$unresolved"
		return 1
	fi
}

convert_saves_in_place() {
	local target_format="$1"
	local source_format root plan unresolved count backup
	local source destination mode tmp failed
	source_format=$(get_save_format)
	root=$(conversion_root)
	plan="$HOME_PATH/conversion-plan.$$"
	unresolved="$HOME_PATH/conversion-unresolved.$$"

	show_progress "Checking save filenames..." 10
	if ! build_conversion_plan "$root" "$source_format" "$target_format" \
		"$plan" "$unresolved"; then
		count=$(wc -l < "$unresolved" | tr -d ' ')
		cp "$unresolved" "$LOGS_PATH/core-saves-conversion-unresolved.txt"
		rm -f "$plan" "$unresolved"
		ACTION_RESULT="Conversion stopped before changing files.
$count filename conflicts or unresolved ROM extensions were found.
See logs/core-saves-conversion-unresolved.txt."
		return 1
	fi
	count=$(wc -l < "$plan" | tr -d ' ')
	show_progress "Backing up saves..." 25
	backup=$(make_backup "format-$source_format-to-$target_format") || {
		rm -f "$plan" "$unresolved"
		ACTION_RESULT="Could not back up the save tree."
		return 1
	}
	begin_operation conversion || {
		rm -f "$plan" "$unresolved"
		ACTION_RESULT="Could not initialize recoverable conversion state.
Backup: $backup"
		return 1
	}
	prepare_conversion_recovery "$plan" || {
		rm -f "$plan" "$unresolved"
		abort_operation "Could not record the files covered by conversion rollback.
Backup: $backup"
		return 1
	}
	operation_phase converting "$backup" || {
		rm -f "$plan" "$unresolved"
		abort_operation "Could not record the conversion backup in the operation journal.
Backup: $backup"
		return 1
	}

	show_progress "Converting $count save files..." 50
	failed=0
	while IFS="$(printf '\t')" read -r source destination mode; do
		[ -n "$source" ] || continue
		if [ "$mode" = encode ] &&
			save-rzip is-rzip "$source" >> "$LOG_FILE" 2>&1; then
			if [ "$source" != "$destination" ]; then
				tmp="$destination.core-saves-convert.$$"
				rm -f "$tmp"
				cp -p "$source" "$tmp" && mv "$tmp" "$destination" || {
					rm -f "$tmp"
					failed=1
					break
				}
				rm -f "$source" || {
					failed=1
					break
				}
			fi
			continue
		fi
		tmp="$destination.core-saves-convert.$$"
		rm -f "$tmp"
		if ! save-rzip "$mode" "$source" "$tmp" >> "$LOG_FILE" 2>&1 ||
			! mv "$tmp" "$destination"; then
			rm -f "$tmp"
			failed=1
			break
		fi
		if [ "$source" != "$destination" ] && ! rm -f "$source"; then
			failed=1
			break
		fi
	done < "$plan"

	if [ "$failed" = 1 ] || ! set_save_format "$target_format"; then
		show_progress "Restoring backup..." 80
		rm -f "$plan" "$unresolved"
		abort_operation "Conversion failed.
Backup: $backup"
		return 1
	fi
	rm -f "$plan" "$unresolved"
	commit_operation || {
		abort_operation "Conversion completed, but its recovery journal could not be committed.
Backup: $backup"
		return 1
	}
	ACTION_RESULT="$count saves converted to $(save_format_name "$target_format").
Backup: $backup"
}
