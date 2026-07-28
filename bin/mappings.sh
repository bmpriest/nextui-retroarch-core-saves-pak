#!/bin/sh

retro_core_name_for_emu() {
	case "$1" in
		a5200) echo "a5200" ;;
		bluemsx) echo "blueMSX" ;;
		cap32) echo "Caprice32" ;;
		fake08) echo "FAKE-08" ;;
		fbneo) echo "FinalBurn Neo" ;;
		fceumm) echo "FCEUmm" ;;
		gambatte) echo "Gambatte" ;;
		gearcoleco) echo "Gearcoleco" ;;
		gpsp) echo "gpSP" ;;
		handy) echo "Handy" ;;
		mednafen_pce_fast) echo "Beetle PCE Fast" ;;
		mednafen_supafaust) echo "Supafaust" ;;
		mednafen_vb) echo "Beetle VB" ;;
		mgba) echo "mGBA" ;;
		pcsx_rearmed) echo "PCSX-ReARMed" ;;
		picodrive) echo "PicoDrive" ;;
		pokemini) echo "PokeMini" ;;
		prboom) echo "PrBoom" ;;
		prosystem) echo "ProSystem" ;;
		puae2021) echo "PUAE 2021" ;;
		race) echo "RACE" ;;
		snes9x) echo "Snes9x" ;;
		stella2014) echo "Stella 2014" ;;
		vice_x128) echo "VICE x128" ;;
		vice_x64) echo "VICE x64" ;;
		vice_xpet) echo "VICE xpet" ;;
		vice_xplus4) echo "VICE xplus4" ;;
		vice_xvic) echo "VICE xvic" ;;
		*) echo "$1" ;;
	esac
}

core_for_launch() {
	local tag="$1"
	local launch="$2"
	local override emu
	override=$(awk -F= -v tag="$tag" '$1 == tag { print substr($0, index($0, "=") + 1); exit }' \
		"$DIR/mapping.conf" 2>/dev/null)
	if [ -n "$override" ]; then
		echo "$override"
		return
	fi
	emu=$(sed -n 's/^[	 ]*EMU_EXE=\([^	 #]*\).*/\1/p' "$launch" | tail -n 1)
	[ -n "$emu" ] && retro_core_name_for_emu "$emu"
}

discover_mappings() {
	local output="$1"
	local raw="$output.raw.$$"
	local launch tag core
	: > "$raw" || return 1
	for launch in "$SDCARD_PATH/Emus/$PLATFORM"/*.pak/launch.sh "$SYSTEM_PATH/paks/Emus"/*.pak/launch.sh; do
		[ -f "$launch" ] || continue
		tag=$(basename "$(dirname "$launch")" .pak)
		if awk -F'|' -v tag="$tag" '$1 == tag { found=1 } END { exit !found }' "$raw"; then
			continue
		fi
		core=$(core_for_launch "$tag" "$launch")
		[ -n "$core" ] && printf '%s|%s\n' "$tag" "$core" >> "$raw"
	done
	sort -t '|' -k1,1 "$raw" > "$output" || {
		rm -f "$raw"
		return 1
	}
	rm -f "$raw"
	[ -s "$output" ]
}

create_core_folders() {
	local table="$1"
	local tag core
	mkdir -p "$CORES_PATH" || return 1
	while IFS='|' read -r tag core; do
		[ -n "$tag" ] && [ -n "$core" ] || continue
		mkdir -p "$CORES_PATH/$core" "$SAVES_PATH/$tag" || return 1
	done < "$table"
}

refresh_folders() {
	local tmp="$HOME_PATH/mounts.new.$$"
	if [ -f "$ENABLED_FILE" ]; then
		ACTION_RESULT="Restore saves to /Saves before refreshing core folders."
		return 1
	fi
	discover_mappings "$tmp" || {
		rm -f "$tmp"
		ACTION_RESULT="No emulator mappings were found."
		return 1
	}
	create_core_folders "$tmp" || return 1
	rm -f "$tmp"
	sync
	ACTION_RESULT="Core folders refreshed from installed emulator paks."
}
