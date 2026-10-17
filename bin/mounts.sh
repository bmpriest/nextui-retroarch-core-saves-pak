#!/bin/sh

# This pak never mounts anything itself. mountctl (bin/mounts, shared with
# Profiles.pak) owns the mount table; Core Saves is its layer 20 (see
# bin/mounts/20-core-saves.sh), which mounts each /Saves/<tag> from
# /Saves/Cores/<core> while the pak is enabled. mountctl's boot hook applies it
# at boot, after Profiles has mounted the active profile's /Saves.
#
# The read-only helpers (mc_matches, mc_physical, ...) come from the bundled
# copy so the menu checks resolve paths exactly as mountctl does, including the
# /mnt/SDCARD symlink on h700.
MOUNTCTL_LIB=1
. "$DIR/bin/mounts/mountctl.sh"
unset MOUNTCTL_LIB

MOUNT_LAYER=20-core-saves
MOUNT_LAYER_FILE="$MOUNTS_HOME/layers.d/$MOUNT_LAYER.sh"
# Before mountctl, this pak installed its own boot hook and helper. Only kept
# so they can be removed.
LEGACY_HOOK_FILE="$USERDATA_PATH/.hooks/boot.d/core-saves.sync.sh"
MOUNT_ERROR=""

mountctl() {
	MOUNTCTL_LIB=0 sh "$(mc_newest "$DIR/bin/mounts/mountctl.sh")" "$@"
}

# Installing goes through this pak's copy, so a newer bundled mountctl
# replaces an older installed one.
mountctl_bundled() {
	MOUNTCTL_LIB=0 sh "$DIR/bin/mounts/mountctl.sh" "$@"
}

# mountctl prints its first error; the details are in logs/mounts.txt.
run_mountctl() {
	local result
	result=$(mountctl "$@" 2>> "$LOG_FILE") && return 0
	MOUNT_ERROR=${result:-"Could not update the mounts; see logs/mounts.txt."}
	log "mountctl $1 failed: $MOUNT_ERROR"
	return 1
}

remove_legacy_mount_files() {
	rm -f "$LEGACY_HOOK_FILE" "$HOME_PATH/boot-mount.sh" "$HOME_PATH/mount.sh"
}

# The layer cannot derive the state directory itself: it runs from the boot
# hook, with no way to know the pak folder was renamed. So the installed copy
# has HOME_PATH written into it.
install_mount_layer() {
	local stage="${TMPDIR:-/tmp}/${PAK_NAME}-layer.$$"
	local result rc

	rm -rf "$stage"
	mkdir -p "$stage" || return 1
	PIN="CORE_SAVES_HOME=$(mc_quote "$HOME_PATH")" awk '
		/^: "\$\{CORE_SAVES_HOME:=/ { print ENVIRON["PIN"]; pinned = 1; next }
		{ print }
		END { exit !pinned }' "$DIR/bin/mounts/$MOUNT_LAYER.sh" > "$stage/$MOUNT_LAYER.sh" || {
		rm -rf "$stage"
		MOUNT_ERROR="Could not prepare the mount layer."
		log "Could not pin $HOME_PATH into the mount layer."
		return 1
	}
	result=$(mountctl_bundled install "$stage/$MOUNT_LAYER.sh" 2>> "$LOG_FILE")
	rc=$?
	rm -rf "$stage"
	[ "$rc" -eq 0 ] || {
		MOUNT_ERROR=${result:-"Could not install the mount layer."}
		log "mountctl install failed: $MOUNT_ERROR"
		return 1
	}
	remove_legacy_mount_files
}

# One layer serves every profile, but each profile has its own enabled file:
# it lives in shared data, which Profiles swaps per profile. The layer stays
# while any of them is enabled, and plans nothing for the others.
core_saves_enabled_anywhere() {
	local enabled
	[ -f "$ENABLED_FILE" ] && return 0
	for enabled in "$PROFILES_ROOT"/*/shared/"$PAK_NAME"/enabled; do
		[ -f "$enabled" ] && return 0
	done
	return 1
}

# Unmounts the tag folders and uninstalls the layer once no profile has Core
# Saves enabled. Removing the last layer also removes mountctl and its hook.
release_mount_layer() {
	core_saves_enabled_anywhere && return 0
	remove_legacy_mount_files
	[ -f "$MOUNT_LAYER_FILE" ] || return 0
	run_mountctl remove "$MOUNT_LAYER"
}

# Takes the tag mounts down so the real /Saves/<tag> folders can be worked on.
# The layer stays installed; the next apply puts the mounts back. Anything
# mounted below /Saves belongs to this layer, including tag mounts left by a
# version that predates mountctl.
unmount_core_mounts() {
	[ -f "$MOUNT_LAYER_FILE" ] || return 0
	run_mountctl down "$MOUNT_LAYER"
}

run_mounts() {
	run_mountctl apply
}

# Brings an install from before mountctl onto it, and keeps the installed layer
# (and mountctl, when this pak's copy is newer) current. Runs on every launch.
ensure_mount_layer() {
	if core_saves_enabled_anywhere; then
		[ -f "$MOUNT_LAYER_FILE" ] || log "Moving Core Saves mounts to mountctl."
		install_mount_layer
	else
		release_mount_layer
	fi
}

restore_previous_mounts() {
	[ -f "$ENABLED_FILE" ] || return 0
	[ -f "$MOUNT_LAYER_FILE" ] || install_mount_layer || {
		log "Could not restore the previous mounts: the mount layer could not be installed."
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
