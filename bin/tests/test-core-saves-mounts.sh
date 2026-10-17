#!/bin/sh
# Core Saves through mountctl, with real bind mounts: moving a 0.6 install off
# its own boot hook, re-applying mappings with the tag folders mounted, boot,
# and reverting. Re-runs itself inside a private user+mount namespace
# (unshare -rm), so it needs no root and leaves the host alone.

set -u

if [ "${CORE_SAVES_TEST_NS:-0}" != 1 ]; then
	command -v unshare >/dev/null 2>&1 || { echo "SKIP: unshare is not available"; exit 0; }
	CORE_SAVES_TEST_NS=1 exec unshare -rm sh "$0" "$@"
fi

PAK_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/core-saves-mounts.XXXXXX")
TEST_ROOT=$(CDPATH= cd -P -- "$TEST_ROOT" && pwd -P)

PATH="$PAK_DIR/bin/desktop:$PATH"
SDCARD_PATH="$TEST_ROOT/sd"
PLATFORM=desktop
SYSTEM_PATH="$SDCARD_PATH/.system/$PLATFORM"
SHARED_USERDATA_PATH="$SDCARD_PATH/.userdata/shared"
USERDATA_PATH="$SDCARD_PATH/.userdata/$PLATFORM"
LOGS_PATH="$USERDATA_PATH/logs"
CORE_SAVES_DIR="$PAK_DIR"
CORE_SAVES_SOURCE_ONLY=1
MOUNTS_LOCK="$TEST_ROOT/mountctl.lock"
TMPDIR="$TEST_ROOT"
export PATH SDCARD_PATH PLATFORM SYSTEM_PATH SHARED_USERDATA_PATH USERDATA_PATH
export LOGS_PATH CORE_SAVES_DIR CORE_SAVES_SOURCE_ONLY MOUNTS_LOCK TMPDIR

cleanup() {
	awk -v root="$TEST_ROOT" 'substr($5, 1, length(root) + 1) == root "/" { print length($5) " " $5 }' \
		/proc/self/mountinfo | sort -rn | cut -d' ' -f2- | while IFS= read -r path; do
		umount "$path" 2>/dev/null || true
	done
	rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
	echo "FAIL: $*" >&2
	for log in "$LOGS_PATH/core-saves.txt" "$LOGS_PATH/mounts.txt"; do
		[ -f "$log" ] && { echo "--- $log" >&2; cat "$log" >&2; }
	done
	exit 1
}

assert_eq() {
	[ "$1" = "$2" ] || fail "expected [$2], got [$1]"
}

mount_count() {
	awk -v target="$1" '$5 == target { n++ } END { print n + 0 }' /proc/self/mountinfo
}

mounts_below_saves() {
	awk -v root="$SDCARD_PATH/Saves" 'substr($5, 1, length(root) + 1) == root "/" { print $5 }' \
		/proc/self/mountinfo | sort
}

write_emulator() {
	path="$SDCARD_PATH/.system/$PLATFORM/paks/Emus/$1.pak"
	mkdir -p "$path"
	printf 'EMU_EXE=%s\n' "$2" > "$path/launch.sh"
}

write_emulator GBA gpsp
mkdir -p "$SDCARD_PATH/Saves/Cores/gpSP" "$SDCARD_PATH/Saves/GBA" "$SHARED_USERDATA_PATH" "$LOGS_PATH"
printf 'saveFormat=3\n' > "$SHARED_USERDATA_PATH/minuisettings.txt"
echo advance > "$SDCARD_PATH/Saves/Cores/gpSP/Advance.srm"

. "$PAK_DIR/launch.sh"
show_progress() { :; }

# A 0.6 install: enabled, its own hook and helper, and the tag folder mounted
# by that helper at boot.
printf 'GBA|gpSP\n' > "$MOUNT_TABLE"
printf 'backup=\nold_format=3\n' > "$ENABLED_FILE"
mkdir -p "$(dirname "$LEGACY_HOOK_FILE")"
printf '#!/bin/sh\n' > "$LEGACY_HOOK_FILE"
printf '#!/bin/sh\n' > "$HOME_PATH/boot-mount.sh"
mount --bind "$CORES_PATH/gpSP" "$SAVES_PATH/GBA" || fail "could not fake the 0.6 boot mount"

# What main() does on launch.
ensure_mount_layer || fail "moving to mountctl: $MOUNT_ERROR"
run_mounts || fail "first apply: $MOUNT_ERROR"
[ -e "$LEGACY_HOOK_FILE" ] && fail "the 0.6 boot hook was left behind"
[ -e "$HOME_PATH/boot-mount.sh" ] && fail "the 0.6 boot helper was left behind"
assert_eq "$(mount_count "$SAVES_PATH/GBA")" "1"
assert_eq "$(mount_status)" "1/1 mounted"
assert_eq "$(cat "$SAVES_PATH/GBA/Advance.srm")" "advance"

# Re-applying after a new emulator appears: the live tag mounts come down for
# the migration and everything is mounted again, once.
write_emulator GB gambatte
mkdir -p "$SAVES_PATH/GB"
echo mono > "$SAVES_PATH/GB/Mono.gb.sav"
enable_core_saves || fail "re-apply: $ACTION_RESULT"
assert_eq "$(mount_status)" "2/2 mounted"
assert_eq "$(mount_count "$SAVES_PATH/GBA")" "1"
assert_eq "$(mount_count "$SAVES_PATH/GB")" "1"
assert_eq "$(cat "$SAVES_PATH/GB/Mono.gb.sav")" "mono"
[ -f "$CORES_PATH/Gambatte/Mono.gb.sav" ] || fail "the GB save did not move into Cores"

# Boot: nothing mounted yet, then mountctl's hook.
sh "$MOUNTS_HOME/mountctl.sh" down || fail "down failed"
assert_eq "$(mounts_below_saves)" ""
sh "$MOUNTS_HOOK" || fail "boot hook failed"
assert_eq "$(mount_status)" "2/2 mounted"

# A tag folder that gained files while unmounted is not hidden.
sh "$MOUNTS_HOME/mountctl.sh" down || fail "down failed"
echo stray > "$SAVES_PATH/GBA/stray.sav"
sh "$MOUNTS_HOOK" >/dev/null && fail "boot mounted over a folder with files in it"
assert_eq "$(mount_count "$SAVES_PATH/GBA")" "0"
[ -f "$SAVES_PATH/GBA/stray.sav" ] || fail "stray save disappeared"
rm "$SAVES_PATH/GBA/stray.sav"
run_mounts || fail "remount: $MOUNT_ERROR"

# Reverting unmounts the tags, puts the saves back in place and removes the
# layer, and with it mountctl, since no other pak has a layer here.
restore_to_legacy current || fail "revert: $ACTION_RESULT"
assert_eq "$(mounts_below_saves)" ""
assert_eq "$(cat "$SAVES_PATH/GBA/Advance.srm")" "advance"
assert_eq "$(cat "$SAVES_PATH/GB/Mono.gb.sav")" "mono"
[ -e "$MOUNT_LAYER_FILE" ] && fail "layer left installed after revert"
[ -e "$MOUNTS_HOOK" ] && fail "mountctl boot hook left behind"
[ -e "$MOUNTS_HOME/mountctl.sh" ] && fail "mountctl left behind"

echo "PASS: Core Saves with real mounts"
