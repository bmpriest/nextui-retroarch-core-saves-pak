#!/bin/sh

prune_backups() {
	local keep="${1:-5}"
	local protected="${2:-}"
	local list="$BACKUP_ROOT/.backup-list.$$"
	local count=0 backup

	find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d \
		! -name '*.incomplete' -print 2>/dev/null |
		LC_ALL=C sort -r > "$list" || {
			rm -f "$list"
			return 1
		}
	while IFS= read -r backup; do
		[ -n "$backup" ] || continue
		[ "$backup" = "$protected" ] && continue
		count=$((count + 1))
		if [ -n "$protected" ]; then
			[ "$count" -lt "$keep" ] && continue
		else
			[ "$count" -le "$keep" ] && continue
		fi
		case "$backup" in
			"$BACKUP_ROOT"/*) rm -rf "$backup" || {
				rm -f "$list"
				return 1
			} ;;
			*)
				rm -f "$list"
				return 1
				;;
		esac
	done < "$list"
	rm -f "$list"
}

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
	prune_backups 5 "$backup" || log "Could not prune old save backups."
	echo "$backup"
}
