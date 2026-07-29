#!/bin/sh

: "${SDCARD_PATH:=/mnt/SDCARD}"
: "${PLATFORM:=tg5040}"
: "${SHARED_USERDATA_PATH:=$SDCARD_PATH/.userdata/shared}"
: "${USERDATA_PATH:=$SDCARD_PATH/.userdata/$PLATFORM}"
: "${LOGS_PATH:=$USERDATA_PATH/logs}"
: "${MOUNTINFO_PATH:=/proc/self/mountinfo}"

HOME_PATH="$SHARED_USERDATA_PATH/RetroArch Core Saves"
TABLE="$HOME_PATH/mounts.conf"
ENABLED="$HOME_PATH/enabled"
SAVES_PATH="$SDCARD_PATH/Saves"
CORES_PATH="$SAVES_PATH/Cores"
LOG_FILE="$LOGS_PATH/core-saves-mounts.txt"

mount_matches() {
	source_path="$1"
	target_path="$2"
	awk -v source="$source_path" -v target="$target_path" '
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

target_is_mounted() {
	target_path="$1"
	awk -v target="$target_path" '
		function decode(path) {
			gsub(/\\040/, " ", path)
			return path
		}
		decode($5) == target { found=1 }
		END { exit !found }
	' "$MOUNTINFO_PATH" 2>/dev/null
}

mkdir -p "$LOGS_PATH"
: > "$LOG_FILE"

[ -f "$ENABLED" ] || exit 0
[ -s "$TABLE" ] || {
	echo "Missing mount table: $TABLE" >> "$LOG_FILE"
	exit 1
}

failed=0
while IFS='|' read -r tag core; do
	[ -n "$tag" ] && [ -n "$core" ] || continue
	source="$CORES_PATH/$core"
	target="$SAVES_PATH/$tag"

	if [ ! -d "$source" ]; then
		echo "Missing core save source: $source" >> "$LOG_FILE"
		failed=1
		continue
	fi

	mkdir -p "$target" || {
		echo "Cannot create $target" >> "$LOG_FILE"
		failed=1
		continue
	}

	if target_is_mounted "$target"; then
		if mount_matches "$source" "$target"; then
			echo "Already mounted: $target -> $source" >> "$LOG_FILE"
		else
			echo "Wrong source mounted at $target; expected $source" >> "$LOG_FILE"
			failed=1
		fi
		continue
	fi

	if [ -n "$(ls -A "$target" 2>/dev/null)" ]; then
		echo "Refusing to hide non-empty mountpoint: $target" >> "$LOG_FILE"
		failed=1
		continue
	fi
	
	if mount -o bind "$source" "$target"; then
		echo "$target -> $source" >> "$LOG_FILE"
	else
		echo "Mount failed: $target -> $source" >> "$LOG_FILE"
		failed=1
	fi
done < "$TABLE"

exit "$failed"
