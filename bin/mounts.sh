#!/bin/sh

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
	cp "$DIR/bin/mount.sh" "$HOME_PATH/mount.sh" || return 1
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
