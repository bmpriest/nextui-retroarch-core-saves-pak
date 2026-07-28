#!/bin/sh

make_backup() {
	local label="$1"
	local ts backup incomplete n
	ts=$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now)
	backup="$BACKUP_ROOT/$ts-$label"
	n=0
	while [ -e "$backup" ]; do
		n=$((n + 1))
		backup="$BACKUP_ROOT/$ts-$label-$$-$n"
	done
	incomplete="$backup.incomplete"
	rm -rf "$incomplete"
	mkdir -p "$incomplete/Saves" || return 1
	cp -a "$SAVES_PATH"/. "$incomplete/Saves"/ || {
		rm -rf "$incomplete"
		return 1
	}
	if [ -f "$SETTINGS_PATH" ]; then
		cp -p "$SETTINGS_PATH" "$incomplete/minuisettings.txt" || {
			rm -rf "$incomplete"
			return 1
		}
		echo 1 > "$incomplete/settings-existed" || {
			rm -rf "$incomplete"
			return 1
		}
	else
		echo 0 > "$incomplete/settings-existed" || {
			rm -rf "$incomplete"
			return 1
		}
	fi
	mv "$incomplete" "$backup" || {
		rm -rf "$incomplete"
		return 1
	}
	echo "$backup"
}
