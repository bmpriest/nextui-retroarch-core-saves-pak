#!/bin/sh

: "${MOUNTINFO_PATH:=/proc/self/mountinfo}"

is_mounted() {
	local target="$1"
	awk -v target="$target" '
		function decode(path) {
			gsub(/\\040/, " ", path)
			gsub(/\\011/, sprintf("%c", 9), path)
			gsub(/\\012/, sprintf("%c", 10), path)
			gsub(/\\134/, sprintf("%c", 92), path)
			return path
		}
		decode($5) == target { found=1 }
		END { exit !found }
	' "$MOUNTINFO_PATH" 2>/dev/null
}

mount_matches() {
	local source="$1"
	local target="$2"
	awk -v source="$source" -v target="$target" '
		function decode(path) {
			gsub(/\\040/, " ", path)
			gsub(/\\011/, sprintf("%c", 9), path)
			gsub(/\\012/, sprintf("%c", 10), path)
			gsub(/\\134/, sprintf("%c", 92), path)
			return path
		}
		function clean(path) {
			gsub(/\/+/, "/", path)
			if (length(path) > 1) sub(/\/$/, "", path)
			return path
		}
		{
			root=decode($4)
			mountpoint=clean(decode($5))
			if (mountpoint == clean(target)) {
				target_found=1
				target_device=$3
				target_root=clean(root)
			}
			if (mountpoint == "/" || source == mountpoint ||
				substr(source, 1, length(mountpoint) + 1) == mountpoint "/") {
				if (length(mountpoint) > source_mount_length) {
					source_mount_length=length(mountpoint)
					source_device=$3
					source_root=root
					source_mount=mountpoint
				}
			}
		}
		END {
			if (!target_found || source_mount_length == 0 ||
				target_device != source_device) exit 1
			if (source_mount == "/")
				suffix=source
			else
				suffix=substr(source, length(source_mount) + 1)
			expected_root=clean(source_root "/" suffix)
			exit target_root != expected_root
		}
	' "$MOUNTINFO_PATH" 2>/dev/null
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
	cp "$DIR/bin/boot-mount.sh" "$HOME_PATH/boot-mount.sh" || return 1
	chmod 0755 "$HOME_PATH/boot-mount.sh" || return 1
	{
		echo '#!/bin/sh'
		printf 'exec "%s"\n' "$HOME_PATH/boot-mount.sh"
	} > "$HOOK_FILE" || return 1
	chmod 0755 "$HOOK_FILE"
}

run_mounts() {
	"$HOME_PATH/boot-mount.sh" >> "$LOG_FILE" 2>&1
}

restore_previous_mounts() {
	[ -f "$ENABLED_FILE" ] || return 0
	[ -x "$HOME_PATH/boot-mount.sh" ] || {
		log "Could not restore the previous mounts: boot helper is missing."
		return 1
	}
	if ! run_mounts; then
		log "Could not restore the previous mounts after an error."
		return 1
	fi
}

write_mount_rows() {
	local output="$1"
	local tags="$output.tags"
	local cores="$output.cores"
	local shown="$output.shown"
	local path tag core

	: > "$output" || return 1
	: > "$shown" || return 1
	find "$SAVES_PATH" -mindepth 1 -maxdepth 1 -type d 2>/dev/null |
		LC_ALL=C sort > "$tags"
	while IFS= read -r path; do
		[ "$path" = "$CORES_PATH" ] && continue
		tag=$(basename "$path")
		core=$(awk -F'|' -v tag="$tag" '
			$1 == tag && $2 != "" { print $2; exit }
		' "$MOUNT_TABLE" 2>/dev/null)
		if [ -n "$core" ]; then
			printf ' /%s\t /%s\n' "$tag" "$core" >> "$output"
			printf '%s\n' "$core" >> "$shown"
		else
			printf ' /%s\t \n' "$tag" >> "$output"
		fi
	done < "$tags"

	find "$CORES_PATH" -mindepth 1 -maxdepth 1 -type d 2>/dev/null |
		LC_ALL=C sort > "$cores"
	while IFS= read -r path; do
		core=$(basename "$path")
		grep -Fxq -- "$core" "$shown" 2>/dev/null && continue
		printf ' \t /%s\n' "$core" >> "$output"
	done < "$cores"

	rm -f "$tags" "$cores" "$shown"
}
