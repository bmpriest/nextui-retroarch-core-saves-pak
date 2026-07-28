#!/bin/sh

set -eu

PAK_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TEST_ROOT=${TMPDIR:-/tmp}/core-saves-tests.$$
HOST_RZIP="$TEST_ROOT/save-rzip"
HOST_JQ=$(command -v jq)
CONVERTER_SRC="$PAK_DIR/../Save Convert.pak/src"
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

assert_file() {
	[ -f "$1" ] || fail "missing file: $1"
}

assert_dir() {
	[ -d "$1" ] || fail "missing directory: $1"
}

assert_absent() {
	[ ! -e "$1" ] || fail "expected absent: $1"
}

assert_empty_dir() {
	assert_dir "$1"
	[ -z "$(find "$1" -mindepth 1 -print -quit)" ] || fail "expected empty: $1"
}

assert_contains() {
	grep -Fq -- "$2" "$1" || fail "$1 does not contain: $2"
}

assert_value() {
	actual=$("$1")
	[ "$actual" = "$2" ] || fail "expected '$2', got '$actual'"
}

mkdir -p "$TEST_ROOT"
cc -std=c99 -O2 -Wall -Wextra -Wno-unused-function \
	-DMINIZ_NO_ARCHIVE_APIS -DMINIZ_NO_TIME \
	-ffunction-sections -fdata-sections -Wl,--gc-sections \
	"$CONVERTER_SRC/save-rzip.c" "$CONVERTER_SRC/miniz.c" \
	-o "$HOST_RZIP" || fail "could not compile host save-rzip"

write_emulator() {
	root="$1"
	tag="$2"
	emu="$3"
	path="$root/.system/tg5040/paks/Emus/$tag.pak"
	mkdir -p "$path"
	printf 'EMU_EXE=%s\n' "$emu" > "$path/launch.sh"
}

load_fixture() {
	name="$1"
	SDCARD_PATH="$TEST_ROOT/$name/sd"
	PLATFORM=tg5040
	SYSTEM_PATH="$SDCARD_PATH/.system/$PLATFORM"
	SHARED_USERDATA_PATH="$SDCARD_PATH/.userdata/shared"
	USERDATA_PATH="$SDCARD_PATH/.userdata/$PLATFORM"
	LOGS_PATH="$USERDATA_PATH/logs"
	CORE_SAVES_DIR="$PAK_DIR"
	CORE_SAVES_SOURCE_ONLY=1
	export SDCARD_PATH PLATFORM SYSTEM_PATH SHARED_USERDATA_PATH USERDATA_PATH
	export LOGS_PATH CORE_SAVES_DIR CORE_SAVES_SOURCE_ONLY

	mkdir -p "$SDCARD_PATH/Saves" "$SHARED_USERDATA_PATH"
	write_emulator "$SDCARD_PATH" GBA gpsp
	write_emulator "$SDCARD_PATH" GB gambatte
	write_emulator "$SDCARD_PATH" GBC gambatte

	# shellcheck source=../../launch.sh
	. "$PAK_DIR/launch.sh"
	RZIP_BIN="$HOST_RZIP"
	JQ_BIN="$HOST_JQ"
	show_progress() { :; }
	run_mounts() { :; }
}

test_minui_to_core_and_generic_restore() (
	load_fixture minui
	printf 'saveFormat=0\notherSetting=1\n' > "$SETTINGS_PATH"
	mkdir -p "$SAVES_PATH/GBA" "$SAVES_PATH/GB" "$SAVES_PATH/GBC"
	printf 'gba-save' > "$SAVES_PATH/GBA/Advance.gba.sav"
	printf 'gba-rtc' > "$SAVES_PATH/GBA/Advance.gba.rtc"
	printf 'gb-save' > "$SAVES_PATH/GB/Mono.gb.sav"
	printf 'gbc-save' > "$SAVES_PATH/GBC/Color.gbc.sav"

	enable_core_saves || fail "$ACTION_RESULT"

	assert_file "$CORES_PATH/gpSP/Advance.srm"
	assert_file "$CORES_PATH/gpSP/Advance.gba.rtc"
	assert_file "$CORES_PATH/Gambatte/Mono.srm"
	assert_file "$CORES_PATH/Gambatte/Color.srm"
	assert_empty_dir "$SAVES_PATH/GBA"
	assert_empty_dir "$SAVES_PATH/GB"
	assert_empty_dir "$SAVES_PATH/GBC"
	assert_contains "$SETTINGS_PATH" "saveFormat=3"
	assert_contains "$MOUNT_TABLE" "GBA|gpSP"
	assert_contains "$MOUNT_TABLE" "GB|Gambatte"
	assert_contains "$MOUNT_TABLE" "GBC|Gambatte"
	assert_file "$ENABLED_FILE"
	assert_file "$HOOK_FILE"
	[ "$(retro_core_name_for_emu mednafen_supafaust)" = "Supafaust" ] ||
		fail "Supafaust library name mapping is incorrect"
	if command -v jq >/dev/null 2>&1; then
		current_settings > "$TEST_ROOT/menu-test.json"
		jq -e '
			.settings[1].selected == 2 and
			.settings[2].selected == 1 and
			.settings[3].options == ["0/3 mounted"] and
			(.settings | length) == 6 and
			.settings[5].name == "Revert to NextUI Saves" and
			.settings[5].features.unselectable == false and
			.conversions[1].name == ".srm" and
			(has("selected") | not)
		' "$TEST_ROOT/menu-test.json" >/dev/null ||
			fail "generated menu is not valid JSON"
	fi

	printf 'synced-save' > "$CORES_PATH/gpSP/Synced.srm"
	restore_to_legacy generic || fail "$ACTION_RESULT"

	assert_file "$SAVES_PATH/GBA/Advance.sav"
	assert_file "$SAVES_PATH/GBA/Synced.sav"
	assert_file "$SAVES_PATH/GBA/Advance.gba.rtc"
	assert_file "$SAVES_PATH/GB/Mono.sav"
	assert_file "$SAVES_PATH/GB/Color.sav"
	assert_file "$SAVES_PATH/GBC/Mono.sav"
	assert_file "$SAVES_PATH/GBC/Color.sav"
	assert_contains "$SETTINGS_PATH" "saveFormat=2"
	assert_absent "$ENABLED_FILE"
	assert_absent "$HOOK_FILE"
	assert_dir "$CORES_PATH"

	delete_core_tree || fail "$ACTION_RESULT"
	assert_absent "$CORES_PATH"
)

test_generic_to_core() (
	load_fixture generic
	printf 'saveFormat=2\n' > "$SETTINGS_PATH"
	mkdir -p "$SAVES_PATH/GBA"
	printf 'raw-save' > "$SAVES_PATH/GBA/Generic.sav"

	enable_core_saves || fail "$ACTION_RESULT"

	assert_file "$CORES_PATH/gpSP/Generic.srm"
	assert_contains "$SETTINGS_PATH" "saveFormat=3"
	[ "$(cat "$CORES_PATH/gpSP/Generic.srm")" = "raw-save" ] ||
		fail "raw payload changed during generic migration"
)

test_rzip_to_generic_conversion() (
	load_fixture rzip
	printf 'saveFormat=1\n' > "$SETTINGS_PATH"
	mkdir -p "$SAVES_PATH/GBA"
	printf 'compressed-save-data' > "$TEST_ROOT/rzip-expected.sav"
	"$HOST_RZIP" encode "$TEST_ROOT/rzip-expected.sav" \
		"$SAVES_PATH/GBA/Compressed.srm"

	enable_core_saves || fail "$ACTION_RESULT"
	assert_contains "$SETTINGS_PATH" "saveFormat=1"
	"$HOST_RZIP" is-rzip "$CORES_PATH/gpSP/Compressed.srm" ||
		fail "compressed payload changed during migration"

	restore_to_legacy generic || fail "$ACTION_RESULT"
	assert_file "$SAVES_PATH/GBA/Compressed.sav"
	cmp "$TEST_ROOT/rzip-expected.sav" "$SAVES_PATH/GBA/Compressed.sav" ||
		fail "RZIP save was not decoded during Generic restore"
	assert_contains "$SETTINGS_PATH" "saveFormat=2"
	assert_absent "$ENABLED_FILE"
)

test_malformed_rzip_restore_rolls_back() (
	load_fixture malformed
	printf 'saveFormat=1\n' > "$SETTINGS_PATH"
	mkdir -p "$SAVES_PATH/GBA"
	printf '#RZIPv\001#malformed-data' > "$SAVES_PATH/GBA/Broken.srm"

	enable_core_saves || fail "$ACTION_RESULT"
	assert_contains "$SETTINGS_PATH" "saveFormat=1"
	if restore_to_legacy generic; then
		fail "malformed RZIP conversion unexpectedly succeeded"
	fi
	assert_file "$ENABLED_FILE"
	assert_file "$CORES_PATH/gpSP/Broken.srm"
	assert_contains "$SETTINGS_PATH" "saveFormat=1"
)

test_shared_core_collision_is_reported_and_preserved() (
	load_fixture collision
	printf 'saveFormat=3\n' > "$SETTINGS_PATH"
	mkdir -p "$SAVES_PATH/GB" "$SAVES_PATH/GBC"
	gb_dir_inode=$(stat -c %i "$SAVES_PATH/GB")
	gbc_dir_inode=$(stat -c %i "$SAVES_PATH/GBC")
	printf 'gb-save' > "$SAVES_PATH/GB/Same.srm"
	printf 'gbc-save' > "$SAVES_PATH/GBC/Same.srm"

	enable_core_saves || fail "$ACTION_RESULT"

	assert_file "$CORES_PATH/Gambatte/Same.srm"
	assert_file "$CORES_PATH/Gambatte/Same.core-conflict-1.srm"
	[ "$(cat "$CORES_PATH/Gambatte/Same.srm")" = "gb-save" ] ||
		fail "primary collision save changed"
	[ "$(cat "$CORES_PATH/Gambatte/Same.core-conflict-1.srm")" = "gbc-save" ] ||
		fail "conflicting save was not preserved"
	assert_contains "$REPORT_FILE" "ISSUE: Collision:"
	assert_contains "$REPORT_FILE" "Same.core-conflict-1.srm"
	assert_contains "$REPORT_FILE" "Issues requiring attention: 1"
	case "$ACTION_RESULT" in
		*"1 issue(s) need attention"*) ;;
		*) fail "completion message did not notify the user: $ACTION_RESULT" ;;
	esac
	[ "$(stat -c %i "$SAVES_PATH/GB")" = "$gb_dir_inode" ] ||
		fail "stock GB tag directory was replaced"
	[ "$(stat -c %i "$SAVES_PATH/GBC")" = "$gbc_dir_inode" ] ||
		fail "stock GBC tag directory was replaced"
	assert_file "$ENABLED_FILE"
	assert_contains "$SETTINGS_PATH" "saveFormat=3"
)

test_boot_mount_hook() (
	load_fixture mounts
	mkdir -p "$CORES_PATH/gpSP" "$SAVES_PATH/GBA" "$TEST_ROOT/fake-bin"
	printf 'GBA|gpSP\n' > "$MOUNT_TABLE"
	: > "$ENABLED_FILE"
	FAKE_MOUNT_LOG="$TEST_ROOT/mount-call.txt"
	export FAKE_MOUNT_LOG
	{
		echo '#!/bin/sh'
		echo 'printf "%s\n" "$*" >> "$FAKE_MOUNT_LOG"'
	} > "$TEST_ROOT/fake-bin/mount"
	chmod +x "$TEST_ROOT/fake-bin/mount"
	PATH="$TEST_ROOT/fake-bin:$PATH"
	export PATH

	"$PAK_DIR/bin/mount.sh" || fail "boot mount hook failed"
	assert_contains "$FAKE_MOUNT_LOG" \
		"-o bind $CORES_PATH/gpSP $SAVES_PATH/GBA"

	printf 'do-not-hide' > "$SAVES_PATH/GBA/existing.sav"
	if "$PAK_DIR/bin/mount.sh"; then
		fail "mount hook hid a non-empty target"
	fi
	assert_contains "$LOGS_PATH/core-saves-mounts.txt" \
		"Refusing to hide non-empty mountpoint: $SAVES_PATH/GBA"

	rm -rf "$SAVES_PATH/GBA" "$CORES_PATH/gpSP"
	if "$PAK_DIR/bin/mount.sh"; then
		fail "mount hook accepted a missing core save source"
	fi
	assert_absent "$CORES_PATH/gpSP"
	assert_contains "$LOGS_PATH/core-saves-mounts.txt" \
		"Missing core save source: $CORES_PATH/gpSP"
)

test_active_refresh_is_rejected() (
	load_fixture refresh
	printf 'GBA|gpSP\n' > "$MOUNT_TABLE"
	: > "$ENABLED_FILE"

	if refresh_folders; then
		fail "active refresh unexpectedly succeeded"
	fi

	assert_contains "$MOUNT_TABLE" "GBA|gpSP"
	[ "$ACTION_RESULT" = \
		"Restore saves to /Saves before refreshing core folders." ] ||
		fail "unexpected active refresh message: $ACTION_RESULT"
)

test_inactive_menu_state() (
	load_fixture menu
	printf 'saveFormat=0\n' > "$SETTINGS_PATH"

	current_settings > "$TEST_ROOT/inactive-menu.json"
	jq -e '
		.settings[1].selected == 1 and
		.settings[2].selected == 0 and
		.settings[3].options == ["0 mounted"] and
		(.settings | length) == 6 and
		.settings[5].name == "Convert to RetroArch Core Saves" and
		.settings[5].features.unselectable == false and
		.conversions[1].name == ".<pak>.sav" and
		(has("selected") | not)
	' "$TEST_ROOT/inactive-menu.json" >/dev/null ||
		fail "inactive menu state is incorrect"
	cleanup
)

test_in_place_conversion() (
	load_fixture conversion
	printf 'saveFormat=2\n' > "$SETTINGS_PATH"
	mkdir -p "$SAVES_PATH/GBA"
	printf 'convert-me' > "$SAVES_PATH/GBA/Game.sav"

	convert_saves_in_place 1 || fail "$ACTION_RESULT"
	assert_file "$SAVES_PATH/GBA/Game.srm"
	assert_absent "$SAVES_PATH/GBA/Game.sav"
	"$HOST_RZIP" is-rzip "$SAVES_PATH/GBA/Game.srm" ||
		fail "in-place conversion did not encode RZIP"
	assert_contains "$SETTINGS_PATH" "saveFormat=1"

	convert_saves_in_place 2 || fail "$ACTION_RESULT"
	assert_file "$SAVES_PATH/GBA/Game.sav"
	assert_absent "$SAVES_PATH/GBA/Game.srm"
	[ "$(cat "$SAVES_PATH/GBA/Game.sav")" = "convert-me" ] ||
		fail "in-place conversion changed save payload"
	assert_contains "$SETTINGS_PATH" "saveFormat=2"
)

test_minui_to_core_and_generic_restore
test_generic_to_core
test_rzip_to_generic_conversion
test_malformed_rzip_restore_rolls_back
test_shared_core_collision_is_reported_and_preserved
test_boot_mount_hook
test_active_refresh_is_rejected
test_inactive_menu_state
test_in_place_conversion
echo "RetroArch Core Saves tests passed"
