#!/bin/sh

: "${SDCARD_PATH:=/mnt/SDCARD}"
: "${PLATFORM:=tg5040}"
: "${SHARED_USERDATA_PATH:=$SDCARD_PATH/.userdata/shared}"
: "${USERDATA_PATH:=$SDCARD_PATH/.userdata/$PLATFORM}"
: "${LOGS_PATH:=$USERDATA_PATH/logs}"

HOME_PATH="$SHARED_USERDATA_PATH/RetroArch Core Saves"
TABLE="$HOME_PATH/mounts.conf"
ENABLED="$HOME_PATH/enabled"
SAVES_PATH="$SDCARD_PATH/Saves"
CORES_PATH="$SAVES_PATH/Cores"
LOG_FILE="$LOGS_PATH/core-saves-mounts.txt"

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
	if awk -v target="$target" '$2 == target { found=1 } END { exit !found }' /proc/mounts 2>/dev/null; then
		echo "Already mounted: $target" >> "$LOG_FILE"
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
