#!/bin/sh

set -eu

PAK_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TEST_ROOT=${TMPDIR:-/tmp}/core-saves-tests.$$
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM

PATH="$PAK_DIR/bin/desktop:$PATH"
export PATH

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
command -v jq >/dev/null 2>&1 || fail "missing bin/desktop/jq"
command -v save-rzip >/dev/null 2>&1 || fail "missing bin/desktop/save-rzip"
[ "$(command -v jq)" = "$PAK_DIR/bin/desktop/jq" ] ||
	fail "tests are not using bin/desktop/jq"
[ "$(command -v save-rzip)" = "$PAK_DIR/bin/desktop/save-rzip" ] ||
	fail "tests are not using bin/desktop/save-rzip"

write_emulator() {
	root="$1"
	tag="$2"
	emu="$3"
	path="$root/.system/$PLATFORM/paks/Emus/$tag.pak"
	mkdir -p "$path"
	printf 'EMU_EXE=%s\n' "$emu" > "$path/launch.sh"
}

load_fixture() {
	name="$1"
	SDCARD_PATH="$TEST_ROOT/$name/sd"
	PLATFORM=desktop
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
	show_progress() { :; }
	run_mounts() { :; }
}

test_minui_to_core_and_generic_restore() (
	load_fixture minui
	printf 'saveFormat=0\notherSetting=1\n' > "$SETTINGS_PATH"
	mkdir -p "$SAVES_PATH/GBA" "$SAVES_PATH/GB" "$SAVES_PATH/GBC"
	mkdir -p "$ROMS_PATH/Game Boy (GB)" "$ROMS_PATH/Game Boy Color (GBC)"
	printf 'rom' > "$ROMS_PATH/Game Boy (GB)/Mono.gb"
	printf 'rom' > "$ROMS_PATH/Game Boy Color (GBC)/Color.gbc"
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
			.settings[3].features.unselectable == true and
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
	assert_file "$SAVES_PATH/GBC/Color.sav"
	assert_absent "$SAVES_PATH/GB/Color.sav"
	assert_absent "$SAVES_PATH/GBC/Mono.sav"
	assert_contains "$SETTINGS_PATH" "saveFormat=2"
	assert_absent "$ENABLED_FILE"
	assert_absent "$HOOK_FILE"
	assert_dir "$CORES_PATH"
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

test_reenable_deduplicates_identical_saves() (
	load_fixture reenable
	printf 'saveFormat=3\n' > "$SETTINGS_PATH"
	mkdir -p "$SAVES_PATH/GBA"
	printf 'unchanged-save' > "$SAVES_PATH/GBA/Unchanged.srm"
	printf 'original-save' > "$SAVES_PATH/GBA/Changed.srm"

	enable_core_saves || fail "$ACTION_RESULT"
	restore_to_legacy current || fail "$ACTION_RESULT"
	printf 'updated-save' > "$SAVES_PATH/GBA/Changed.srm"
	enable_core_saves || fail "$ACTION_RESULT"

	assert_file "$CORES_PATH/gpSP/Unchanged.srm"
	assert_absent "$CORES_PATH/gpSP/Unchanged.core-conflict-1.srm"
	[ "$(cat "$CORES_PATH/gpSP/Unchanged.srm")" = "unchanged-save" ] ||
		fail "unchanged save changed during re-enable"
	assert_file "$CORES_PATH/gpSP/Changed.srm"
	assert_file "$CORES_PATH/gpSP/Changed.core-conflict-1.srm"
	[ "$(cat "$CORES_PATH/gpSP/Changed.srm")" = "original-save" ] ||
		fail "original conflicting save changed during re-enable"
	[ "$(cat "$CORES_PATH/gpSP/Changed.core-conflict-1.srm")" = "updated-save" ] ||
		fail "updated conflicting save was not preserved"
	assert_contains "$MANIFEST" "gpSP/Unchanged.srm|GBA/Unchanged.srm"
	assert_contains "$REPORT_FILE" "Changed.core-conflict-1.srm"
	assert_contains "$REPORT_FILE" "Issues requiring attention: 1"
)

test_rzip_to_generic_conversion() (
	load_fixture rzip
	printf 'saveFormat=1\n' > "$SETTINGS_PATH"
	mkdir -p "$SAVES_PATH/GBA"
	printf 'compressed-save-data' > "$TEST_ROOT/rzip-expected.sav"
	save-rzip encode "$TEST_ROOT/rzip-expected.sav" \
		"$SAVES_PATH/GBA/Compressed.srm"

	enable_core_saves || fail "$ACTION_RESULT"
	assert_contains "$SETTINGS_PATH" "saveFormat=1"
	save-rzip is-rzip "$CORES_PATH/gpSP/Compressed.srm" ||
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

test_restore_routes_only_safe_core_saves() (
	load_fixture conservative-restore
	printf 'saveFormat=3\n' > "$SETTINGS_PATH"
	mkdir -p "$CORES_PATH/gpSP" "$CORES_PATH/Gambatte" "$CORES_PATH/ForeignCore"
	mkdir -p "$SAVES_PATH/GBA" "$SAVES_PATH/GB" "$SAVES_PATH/GBC"
	mkdir -p "$ROMS_PATH/Game Boy (GB)" "$ROMS_PATH/Game Boy Color (GBC)"
	printf 'rom' > "$ROMS_PATH/Game Boy (GB)/Mono.gb"
	printf 'rom' > "$ROMS_PATH/Game Boy Color (GBC)/Color.gbc"
	printf 'rom' > "$ROMS_PATH/Game Boy (GB)/Both.gb"
	printf 'rom' > "$ROMS_PATH/Game Boy Color (GBC)/Both.gbc"
	printf 'rom' > "$ROMS_PATH/Game Boy (GB)/Archive.gb.zip"
	printf 'rom' > "$ROMS_PATH/Game Boy Color (GBC)/Extracted.gbc.zip"
	printf 'gba' > "$CORES_PATH/gpSP/No-Rom-Needed.srm"
	printf 'gb' > "$CORES_PATH/Gambatte/Mono.srm"
	printf 'gb-conflict' > "$CORES_PATH/Gambatte/Mono.core-conflict-1.srm"
	printf 'gbc' > "$CORES_PATH/Gambatte/Color.srm"
	printf 'archive' > "$CORES_PATH/Gambatte/Archive.gb.srm"
	printf 'extracted' > "$CORES_PATH/Gambatte/Extracted.srm"
	printf 'ambiguous' > "$CORES_PATH/Gambatte/Both.srm"
	printf 'unmatched' > "$CORES_PATH/Gambatte/No-Matching-Rom.srm"
	printf 'foreign' > "$CORES_PATH/ForeignCore/Other.srm"
	printf 'GBA|gpSP\nGB|Gambatte\nGBC|Gambatte\n' > "$MOUNT_TABLE"
	: > "$ENABLED_FILE"
	mkdir -p "$(dirname "$HOOK_FILE")"
	: > "$HOOK_FILE"

	restore_to_legacy current || fail "$ACTION_RESULT"

	assert_file "$SAVES_PATH/GBA/No-Rom-Needed.srm"
	assert_file "$SAVES_PATH/GB/Mono.srm"
	assert_file "$SAVES_PATH/GB/Mono.core-conflict-1.srm"
	assert_file "$SAVES_PATH/GBC/Color.srm"
	assert_file "$SAVES_PATH/GB/Archive.gb.srm"
	assert_file "$SAVES_PATH/GBC/Extracted.srm"
	assert_absent "$SAVES_PATH/GBC/Mono.srm"
	assert_absent "$SAVES_PATH/GB/Color.srm"
	assert_absent "$SAVES_PATH/GB/Both.srm"
	assert_absent "$SAVES_PATH/GBC/Both.srm"
	assert_absent "$SAVES_PATH/GB/No-Matching-Rom.srm"
	assert_absent "$SAVES_PATH/GBC/No-Matching-Rom.srm"
	assert_absent "$SAVES_PATH/ForeignCore"
	assert_file "$CORES_PATH/Gambatte/Both.srm"
	assert_file "$CORES_PATH/Gambatte/No-Matching-Rom.srm"
	assert_file "$CORES_PATH/ForeignCore/Other.srm"
	assert_contains "$REPORT_FILE" "Matched save files: 6"
	assert_contains "$REPORT_FILE" "Unmatched shared-core files: 1"
	assert_contains "$REPORT_FILE" "Ambiguous shared-core files: 1"
	assert_contains "$REPORT_FILE" "Files ignored in unmapped core folders: 1"
	assert_contains "$REPORT_FILE" "No-Matching-Rom.srm"
	assert_contains "$REPORT_FILE" "Both.srm matches GB, GBC"
	assert_contains "$REPORT_FILE" "Other.srm (no installed emulator maps to ForeignCore)"
	assert_absent "$ENABLED_FILE"
	assert_absent "$HOOK_FILE"
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

	"$PAK_DIR/bin/boot-mount.sh" || fail "boot mount hook failed"
	assert_contains "$FAKE_MOUNT_LOG" \
		"-o bind $CORES_PATH/gpSP $SAVES_PATH/GBA"

	MOUNTINFO_PATH="$TEST_ROOT/boot-mountinfo"
	export MOUNTINFO_PATH
	printf '1 0 8:1 / / rw - ext4 /dev/test rw\n' > "$MOUNTINFO_PATH"
	printf '2 1 8:1 /somewhere-else %s rw - ext4 /dev/test rw\n' \
		"$SAVES_PATH/GBA" >> "$MOUNTINFO_PATH"
	if "$PAK_DIR/bin/boot-mount.sh"; then
		fail "mount hook accepted the wrong bind source"
	fi
	assert_contains "$LOGS_PATH/core-saves-mounts.txt" \
		"Wrong source mounted at $SAVES_PATH/GBA; expected $CORES_PATH/gpSP"

	: > "$MOUNTINFO_PATH"
	printf 'do-not-hide' > "$SAVES_PATH/GBA/existing.sav"
	if "$PAK_DIR/bin/boot-mount.sh"; then
		fail "mount hook hid a non-empty target"
	fi
	assert_contains "$LOGS_PATH/core-saves-mounts.txt" \
		"Refusing to hide non-empty mountpoint: $SAVES_PATH/GBA"

	rm -rf "$SAVES_PATH/GBA" "$CORES_PATH/gpSP"
	if "$PAK_DIR/bin/boot-mount.sh"; then
		fail "mount hook accepted a missing core save source"
	fi
	assert_absent "$CORES_PATH/gpSP"
	assert_contains "$LOGS_PATH/core-saves-mounts.txt" \
		"Missing core save source: $CORES_PATH/gpSP"
)

test_mountinfo_source_verification() (
	load_fixture mountinfo
	mkdir -p "$CORES_PATH/FinalBurn Neo" "$SAVES_PATH/FBA"
	MOUNTINFO_PATH="$TEST_ROOT/mountinfo-verification"
	export MOUNTINFO_PATH
	{
		printf '1 0 8:1 / / rw - ext4 /dev/test rw\n'
		printf '2 1 8:1 %s %s rw - ext4 /dev/test rw\n' \
			"$CORES_PATH/FinalBurn\\040Neo" "$SAVES_PATH/FBA"
	} > "$MOUNTINFO_PATH"
	mount_matches "$CORES_PATH/FinalBurn Neo" "$SAVES_PATH/FBA" ||
		fail "expected bind source was not recognized"
	mount_matches "$CORES_PATH/Gambatte" "$SAVES_PATH/FBA" &&
		fail "wrong bind source was accepted"
	return 0
)

test_inactive_menu_state() (
	load_fixture menu
	printf 'saveFormat=0\n' > "$SETTINGS_PATH"

	current_settings > "$TEST_ROOT/inactive-menu.json"
	jq -e '
		.settings[1].selected == 1 and
		.settings[2].selected == 0 and
		.settings[3].options == ["0 mounted"] and
		.settings[3].features.unselectable == true and
		(.settings | length) == 6 and
		.settings[5].name == "Convert to RetroArch Core Saves" and
		.settings[5].features.unselectable == false and
		.conversions[1].name == ".<pak>.sav" and
		(has("selected") | not)
	' "$TEST_ROOT/inactive-menu.json" >/dev/null ||
		fail "inactive menu state is incorrect"
	cleanup
)

test_active_mount_rows_include_unmapped_folders() (
	load_fixture mount-rows
	printf 'saveFormat=3\n' > "$SETTINGS_PATH"
	mkdir -p "$SAVES_PATH/FC" "$SAVES_PATH/GB" "$SAVES_PATH/GBA"
	mkdir -p "$SAVES_PATH/GBC" "$SAVES_PATH/MD"
	mkdir -p "$CORES_PATH/FCEUmm" "$CORES_PATH/Gambatte"
	mkdir -p "$CORES_PATH/gpSP" "$CORES_PATH/ForeignCore"
	printf 'FC|FCEUmm\nGB|Gambatte\nGBA|gpSP\nGBC|Gambatte\n' > "$MOUNT_TABLE"
	: > "$ENABLED_FILE"
	mount_matches() {
		case "$2" in
			"$SAVES_PATH/FC"|"$SAVES_PATH/GB"|"$SAVES_PATH/GBA"|"$SAVES_PATH/GBC")
				return 0
				;;
			*) return 1 ;;
		esac
	}

	current_settings > "$TEST_ROOT/active-mount-rows.json"
	jq -e '
		.settings[3].name == "> Mounts:" and
		.settings[3].options == ["4/4 mounted"] and
		.settings[3].selected == 0 and
		.settings[3].features.unselectable == true and
		(.settings[3].features | has("confirm_text") | not) and
		.settings[4].name == "View Mounts" and
		.settings[4].features.alignment == "right" and
		.settings[4].features.unselectable == false and
		.settings[4].features.confirm_text == "VIEW" and
		(.mounts | length) == 7 and
		([.mounts[] | select(.name == " /FC" and .options[0] == " /FCEUmm")] | length) == 1 and
		([.mounts[] | select(.name == " /GB" and .options[0] == " /Gambatte")] | length) == 1 and
		([.mounts[] | select(.name == " /GBC" and .options[0] == " /Gambatte")] | length) == 1 and
		([.mounts[] | select(.name == " /GBA" and .options[0] == " /gpSP")] | length) == 1 and
		([.mounts[] | select(.name == " /MD" and .options[0] == " ")] | length) == 1 and
		([.mounts[] | select(.name == " " and .options[0] == " /ForeignCore")] | length) == 1 and
		([.mounts[] | select(.name == " /Cores")] | length) == 0
	' "$TEST_ROOT/active-mount-rows.json" >/dev/null ||
		fail "active mount rows are incomplete or incorrectly mapped"
)

test_conversion_menu_uses_selectable_targets() (
	load_fixture conversion-menu
	printf 'saveFormat=1\n' > "$SETTINGS_PATH"

	current_settings > "$TEST_ROOT/conversion-menu.json"
	jq -e '
		(.conversions | length) == 6 and
		.conversions[0].name == "From:" and
		.conversions[0].features.unselectable == true and
		.conversions[1].name == ".srm (compressed)" and
		(.conversions[1].features.alignment // "left") == "left" and
		.conversions[1].features.unselectable == true and
		[.conversions[2:][].name] ==
			[".sav", ".<pak>.sav", ".srm", ".srm (compressed)"] and
		([.conversions[2:][] | select(.features.unselectable == false)] | length) == 4
	' "$TEST_ROOT/conversion-menu.json" >/dev/null ||
		fail "conversion menu does not expose all selectable targets"
)

test_in_place_conversion() (
	load_fixture conversion
	printf 'saveFormat=2\n' > "$SETTINGS_PATH"
	mkdir -p "$SAVES_PATH/GBA"
	printf 'convert-me' > "$SAVES_PATH/GBA/Game.sav"

	convert_saves_in_place 1 || fail "$ACTION_RESULT"
	assert_file "$SAVES_PATH/GBA/Game.srm"
	assert_absent "$SAVES_PATH/GBA/Game.sav"
	save-rzip is-rzip "$SAVES_PATH/GBA/Game.srm" ||
		fail "in-place conversion did not encode RZIP"
	assert_contains "$SETTINGS_PATH" "saveFormat=1"

	convert_saves_in_place 2 || fail "$ACTION_RESULT"
	assert_file "$SAVES_PATH/GBA/Game.sav"
	assert_absent "$SAVES_PATH/GBA/Game.srm"
	[ "$(cat "$SAVES_PATH/GBA/Game.sav")" = "convert-me" ] ||
		fail "in-place conversion changed save payload"
	assert_contains "$SETTINGS_PATH" "saveFormat=2"
)

test_same_format_conversion_reapplies_payload_format() (
	load_fixture same-format-conversion
	printf 'saveFormat=3\n' > "$SETTINGS_PATH"
	mkdir -p "$SAVES_PATH/GBA"
	printf 'expected-payload' > "$TEST_ROOT/same-format-expected"
	save-rzip encode "$TEST_ROOT/same-format-expected" "$SAVES_PATH/GBA/Game.srm"

	convert_saves_in_place 3 || fail "$ACTION_RESULT"
	save-rzip is-rzip "$SAVES_PATH/GBA/Game.srm" &&
		fail "same-format uncompressed conversion left RZIP data compressed"
	cmp "$TEST_ROOT/same-format-expected" "$SAVES_PATH/GBA/Game.srm" ||
		fail "same-format conversion changed the payload"

	convert_saves_in_place 1 || fail "$ACTION_RESULT"
	save-rzip is-rzip "$SAVES_PATH/GBA/Game.srm" ||
		fail "compressed conversion did not encode the save"
	convert_saves_in_place 1 || fail "$ACTION_RESULT"
	save-rzip decode "$SAVES_PATH/GBA/Game.srm" "$TEST_ROOT/same-format-decoded"
	cmp "$TEST_ROOT/same-format-expected" "$TEST_ROOT/same-format-decoded" ||
		fail "reapplying compressed format double-encoded the save"
)

test_conversion_failure_rolls_back_only_planned_files() (
	load_fixture conversion-scoped-rollback
	printf 'saveFormat=3\n' > "$SETTINGS_PATH"
	mkdir -p "$CORES_PATH/gpSP" "$CORES_PATH/ForeignCore"
	printf 'mapped' > "$CORES_PATH/gpSP/Game.srm"
	printf 'foreign-original' > "$CORES_PATH/ForeignCore/Other.srm"
	printf 'GBA|gpSP\n' > "$MOUNT_TABLE"
	: > "$ENABLED_FILE"
	printf '#!/bin/sh\nexit 0\n' > "$HOME_PATH/boot-mount.sh"
	chmod +x "$HOME_PATH/boot-mount.sh"
	set_save_format() {
		printf 'synced-during-conversion' > "$CORES_PATH/ForeignCore/New.srm"
		return 1
	}

	if convert_saves_in_place 1; then
		fail "conversion unexpectedly survived a settings failure"
	fi
	assert_file "$CORES_PATH/gpSP/Game.srm"
	[ "$(cat "$CORES_PATH/gpSP/Game.srm")" = "mapped" ] ||
		fail "planned save was not rolled back"
	assert_file "$CORES_PATH/ForeignCore/Other.srm"
	assert_file "$CORES_PATH/ForeignCore/New.srm"
	assert_absent "$OPERATION_JOURNAL"
	assert_absent "$OPERATION_STATE"
)

test_interrupted_conversion_is_recovered_selectively() (
	load_fixture interrupted-conversion
	printf 'saveFormat=2\n' > "$SETTINGS_PATH"
	mkdir -p "$SAVES_PATH/GBA" "$SAVES_PATH/Unrelated"
	printf 'before' > "$SAVES_PATH/GBA/Game.sav"
	printf 'unrelated-before' > "$SAVES_PATH/Unrelated/Keep.sav"
	plan="$TEST_ROOT/interrupted-conversion.plan"
	printf '%s\t%s\tencode\n' "$SAVES_PATH/GBA/Game.sav" \
		"$SAVES_PATH/GBA/Game.srm" > "$plan"
	backup=$(make_backup conversion) || fail "could not make conversion recovery backup"
	begin_operation conversion || fail "$ACTION_RESULT"
	prepare_conversion_recovery "$plan" || fail "could not prepare selective recovery"
	operation_phase converting "$backup" || fail "could not journal conversion"
	rm -f "$SAVES_PATH/GBA/Game.sav"
	printf 'partial' > "$SAVES_PATH/GBA/Game.srm"
	printf 'arrived-during-conversion' > "$SAVES_PATH/Unrelated/New.sav"
	printf 'saveFormat=1\n' > "$SETTINGS_PATH"

	audit_operation || fail "$ACTION_RESULT"

	assert_file "$SAVES_PATH/GBA/Game.sav"
	assert_absent "$SAVES_PATH/GBA/Game.srm"
	assert_file "$SAVES_PATH/Unrelated/New.sav"
	assert_contains "$SETTINGS_PATH" "saveFormat=2"
	assert_absent "$OPERATION_JOURNAL"
	assert_absent "$OPERATION_STATE"
)

test_recovery_keeps_journal_when_remount_fails() (
	load_fixture recovery-remount-failure
	printf 'saveFormat=3\n' > "$SETTINGS_PATH"
	mkdir -p "$CORES_PATH/gpSP" "$SAVES_PATH/GBA" "$(dirname "$HOOK_FILE")"
	printf 'GBA|gpSP\n' > "$MOUNT_TABLE"
	: > "$ENABLED_FILE"
	printf '#!/bin/sh\nexit 1\n' > "$HOME_PATH/boot-mount.sh"
	chmod +x "$HOME_PATH/boot-mount.sh"
	: > "$HOOK_FILE"
	begin_operation restore || fail "$ACTION_RESULT"
	backup=$(make_backup restore) || fail "could not make remount recovery backup"
	operation_phase installing "$backup" || fail "could not journal remount fixture"
	run_mounts() { return 1; }

	if audit_operation; then
		fail "recovery falsely succeeded after remount failure"
	fi
	assert_file "$OPERATION_JOURNAL"
	assert_dir "$OPERATION_STATE"
	assert_contains "$OPERATION_JOURNAL" "phase=recovering-mounts"
	case "$ACTION_RESULT" in
		*"previous mounts could not be restored"*) ;;
		*) fail "remount recovery failure was not reported: $ACTION_RESULT" ;;
	esac
	printf 'arrived-after-rollback' > "$CORES_PATH/gpSP/New.srm"
	run_mounts() { return 0; }
	audit_operation || fail "$ACTION_RESULT"
	assert_file "$CORES_PATH/gpSP/New.srm"
	assert_absent "$OPERATION_JOURNAL"
	assert_absent "$OPERATION_STATE"
)

test_backup_retention() (
	load_fixture backup-retention
	mkdir -p "$SAVES_PATH/GBA"
	printf 'save' > "$SAVES_PATH/GBA/Game.sav"
	n=1
	while [ "$n" -le 7 ]; do
		make_backup "retention-$n" >/dev/null ||
			fail "could not create retention backup $n"
		n=$((n + 1))
	done
	count=$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d \
		! -name '*.incomplete' | wc -l | tr -d ' ')
	[ "$count" = 5 ] || fail "expected 5 retained backups, got $count"
)

test_enable_mount_failure_rolls_back() (
	load_fixture enable-rollback
	printf 'saveFormat=0\notherSetting=1\n' > "$SETTINGS_PATH"
	mkdir -p "$SAVES_PATH/GBA"
	printf 'original-save' > "$SAVES_PATH/GBA/Original.gba.sav"
	run_mounts() { return 1; }

	if enable_core_saves; then
		fail "enable unexpectedly survived a mount failure"
	fi

	assert_file "$SAVES_PATH/GBA/Original.gba.sav"
	[ "$(cat "$SAVES_PATH/GBA/Original.gba.sav")" = "original-save" ] ||
		fail "enable rollback changed the original save"
	assert_absent "$CORES_PATH"
	assert_absent "$MOUNT_TABLE"
	assert_absent "$ENABLED_FILE"
	assert_absent "$HOOK_FILE"
	assert_absent "$OPERATION_JOURNAL"
	assert_absent "$OPERATION_STATE"
	assert_contains "$SETTINGS_PATH" "saveFormat=0"
	case "$ACTION_RESULT" in
		*"previous save layout and settings were restored"*) ;;
		*) fail "enable rollback was not reported: $ACTION_RESULT" ;;
	esac
)

test_interrupted_enable_is_recovered() (
	load_fixture interrupted-enable
	printf 'saveFormat=2\n' > "$SETTINGS_PATH"
	mkdir -p "$SAVES_PATH/GBA"
	printf 'before-enable' > "$SAVES_PATH/GBA/Before.sav"

	begin_operation enable || fail "$ACTION_RESULT"
	backup=$(make_backup enable) || fail "could not make recovery fixture backup"
	operation_phase migrating "$backup" || fail "could not update fixture journal"
	mkdir -p "$CORES_PATH/gpSP"
	printf 'partial-copy' > "$CORES_PATH/gpSP/Before.srm"
	clear_mountpoint GBA
	printf 'saveFormat=3\n' > "$SETTINGS_PATH"
	printf 'GBA|gpSP\n' > "$MOUNT_TABLE"
	: > "$ENABLED_FILE"
	mkdir -p "$(dirname "$HOOK_FILE")"
	: > "$HOOK_FILE"

	audit_operation || fail "$ACTION_RESULT"

	assert_file "$SAVES_PATH/GBA/Before.sav"
	[ "$(cat "$SAVES_PATH/GBA/Before.sav")" = "before-enable" ] ||
		fail "interrupted enable recovery changed the save"
	assert_absent "$CORES_PATH"
	assert_absent "$MOUNT_TABLE"
	assert_absent "$ENABLED_FILE"
	assert_absent "$HOOK_FILE"
	assert_absent "$OPERATION_JOURNAL"
	assert_absent "$OPERATION_STATE"
	assert_contains "$SETTINGS_PATH" "saveFormat=2"
)

test_interrupted_restore_is_recovered() (
	load_fixture interrupted-restore
	printf 'saveFormat=3\n' > "$SETTINGS_PATH"
	mkdir -p "$CORES_PATH/gpSP" "$SAVES_PATH/GBA" "$(dirname "$HOOK_FILE")"
	printf 'core-save' > "$CORES_PATH/gpSP/Game.srm"
	printf 'GBA|gpSP\n' > "$MOUNT_TABLE"
	printf 'enabled-state\n' > "$ENABLED_FILE"
	printf 'hook-state\n' > "$HOOK_FILE"
	printf 'mount-helper\n' > "$HOME_PATH/boot-mount.sh"
	chmod +x "$HOME_PATH/boot-mount.sh"
	printf 'manifest-state\n' > "$MANIFEST"
	mount_recovery="$TEST_ROOT/interrupted-restore-remounted"
	run_mounts() { : > "$mount_recovery"; }

	begin_operation restore || fail "$ACTION_RESULT"
	backup=$(make_backup restore) || fail "could not make recovery fixture backup"
	operation_phase installing "$backup" || fail "could not update fixture journal"
	clear_mountpoint GBA
	printf 'partial-restore' > "$SAVES_PATH/GBA/Game.sav"
	printf 'saveFormat=2\n' > "$SETTINGS_PATH"
	rm -f "$ENABLED_FILE" "$HOOK_FILE" "$MOUNT_TABLE" "$MANIFEST"

	audit_operation || fail "$ACTION_RESULT"

	assert_file "$CORES_PATH/gpSP/Game.srm"
	assert_empty_dir "$SAVES_PATH/GBA"
	assert_contains "$MOUNT_TABLE" "GBA|gpSP"
	assert_contains "$ENABLED_FILE" "enabled-state"
	assert_contains "$HOOK_FILE" "hook-state"
	assert_contains "$HOME_PATH/boot-mount.sh" "mount-helper"
	assert_contains "$MANIFEST" "manifest-state"
	assert_file "$mount_recovery"
	assert_absent "$OPERATION_JOURNAL"
	assert_absent "$OPERATION_STATE"
	assert_contains "$SETTINGS_PATH" "saveFormat=3"
)

test_active_conversion_warns_and_only_converts_mapped_cores() (
	load_fixture active-conversion
	printf 'saveFormat=3\n' > "$SETTINGS_PATH"
	mkdir -p "$TEST_ROOT/active-conversion-bin"
	mkdir -p "$CORES_PATH/gpSP" "$CORES_PATH/Gambatte" "$CORES_PATH/ForeignCore"
	printf 'gba' > "$CORES_PATH/gpSP/Advance.srm"
	printf 'gb' > "$TEST_ROOT/active-conversion-expected"
	save-rzip encode "$TEST_ROOT/active-conversion-expected" \
		"$CORES_PATH/Gambatte/Mono.srm"
	printf 'foreign' > "$CORES_PATH/ForeignCore/Other.srm"
	printf 'GBA|gpSP\nGB|Gambatte\nGBC|Gambatte\n' > "$MOUNT_TABLE"
	: > "$ENABLED_FILE"
	warning="$TEST_ROOT/active-conversion-warning.txt"
	menu_called="$TEST_ROOT/active-conversion-menu-called"
	export menu_called
	{
		echo '#!/bin/sh'
		echo 'state='
		echo 'while [ "$#" -gt 0 ]; do'
		echo '  if [ "$1" = "--write-location" ]; then shift; state=$1; fi'
		echo '  shift'
		echo 'done'
		echo ': > "$menu_called"'
		echo 'printf "%s\n" "{\"selected\":4}" > "$state"'
	} > "$TEST_ROOT/active-conversion-bin/minui-list"
	chmod +x "$TEST_ROOT/active-conversion-bin/minui-list"
	PATH="$TEST_ROOT/active-conversion-bin:$PATH"
	export PATH
	settings=$(current_settings)

	confirm() {
		printf '%s\n' "$1" > "$warning"
		return 1
	}
	conversion_screen "$settings" || fail "cancelled conversion screen returned an error"
	assert_contains "$warning" \
		"Converting saves that are synced to other devices might break compatibility on those devices. Continue?"
	assert_absent "$menu_called"
	assert_file "$CORES_PATH/gpSP/Advance.srm"
	assert_file "$CORES_PATH/Gambatte/Mono.srm"
	assert_file "$CORES_PATH/ForeignCore/Other.srm"

	confirm() {
		printf '%s\n' "$1" > "$warning"
		return 0
	}
	conversion_screen "$settings" || fail "$ACTION_RESULT"
	assert_file "$menu_called"
	assert_file "$CORES_PATH/gpSP/Advance.srm"
	assert_file "$CORES_PATH/Gambatte/Mono.srm"
	save-rzip is-rzip "$CORES_PATH/Gambatte/Mono.srm" &&
		fail "same-format menu conversion did not normalize mapped RZIP data"
	cmp "$TEST_ROOT/active-conversion-expected" "$CORES_PATH/Gambatte/Mono.srm" ||
		fail "same-format menu conversion changed the mapped save"
	assert_file "$CORES_PATH/ForeignCore/Other.srm"
	assert_absent "$CORES_PATH/ForeignCore/Other.sav"
	assert_contains "$SETTINGS_PATH" "saveFormat=3"
)

test_minui_to_core_and_generic_restore
test_generic_to_core
test_reenable_deduplicates_identical_saves
test_rzip_to_generic_conversion
test_malformed_rzip_restore_rolls_back
test_shared_core_collision_is_reported_and_preserved
test_restore_routes_only_safe_core_saves
test_boot_mount_hook
test_mountinfo_source_verification
test_inactive_menu_state
test_active_mount_rows_include_unmapped_folders
test_conversion_menu_uses_selectable_targets
test_in_place_conversion
test_same_format_conversion_reapplies_payload_format
test_conversion_failure_rolls_back_only_planned_files
test_interrupted_conversion_is_recovered_selectively
test_enable_mount_failure_rolls_back
test_interrupted_enable_is_recovered
test_interrupted_restore_is_recovered
test_recovery_keeps_journal_when_remount_fails
test_active_conversion_warns_and_only_converts_mapped_cores
test_backup_retention
echo "RetroArch Core Saves tests passed"
