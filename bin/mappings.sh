#!/bin/sh

# Maps an EMU_EXE value to the core's exact retro_system_info.library_name,
# which is the folder RetroArch and MinArch use under /Saves/Cores. Every entry
# below is taken from the core's own retro_get_system_info, not from libretro
# .info metadata: the two disagree (freeintv reports "freeintv" while its .info
# corename is "FreeIntv"), and only the source value decides the folder name.
#
# Returns non-zero for anything not listed. Callers must not fall back to the
# EMU_EXE name -- guessing produces a folder the emulator never writes to, and
# the saves silently diverge. Unknown cores are reported and left unmapped so
# the user can add a mapping.conf override.
retro_core_name_for_emu() {
	case "$1" in
		a5200) echo "a5200" ;;
		bluemsx) echo "blueMSX" ;;
		cap32) echo "Caprice32" ;;
		fake08) echo "FAKE-08" ;;
		fbneo) echo "FinalBurn Neo" ;;
		fceumm) echo "FCEUmm" ;;
		freeintv) echo "freeintv" ;;
		gambatte) echo "Gambatte" ;;
		gearcoleco) echo "Gearcoleco" ;;
		gpsp) echo "gpSP" ;;
		handy) echo "Handy" ;;
		mednafen_pce_fast) echo "Beetle PCE Fast" ;;
		mednafen_supafaust) echo "Supafaust" ;;
		mednafen_supergrafx) echo "Beetle SuperGrafx" ;;
		mednafen_vb) echo "Beetle VB" ;;
		mgba) echo "mGBA" ;;
		mupen64plus_next) echo "Mupen64Plus-Next" ;;
		opera) echo "Opera" ;;
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
		virtualjaguar) echo "Virtual Jaguar" ;;
		*) return 1 ;;
	esac
}

launch_emu_exe() {
	sed -n 's/^[	 ]*EMU_EXE=\([^	 #]*\).*/\1/p' "$1" | tail -n 1
}

core_for_launch() {
	local tag="$1"
	local launch="$2"
	local override emu

	override=$(awk -F= -v tag="$tag" '$1 == tag { print substr($0, index($0, "=") + 1); exit }' \
		"$MAPPING_CONF" 2>/dev/null)

	if [ -n "$override" ]; then
		echo "$override"
		return 0
	fi

	emu=$(launch_emu_exe "$launch")
	[ -n "$emu" ] || return 1

	retro_core_name_for_emu "$emu"
}

report_unmapped_emulator() {
	local tag="$1"
	local launch="$2"
	local emu

	emu=$(launch_emu_exe "$launch")

	if [ -z "$emu" ]; then
		# No EMU_EXE at all means a standalone emulator pak, which keeps its own
		# saves and is not expected to map. Informational, not actionable.
		report_note "UNMAPPED: /Saves/$tag was left in place ($launch declares no EMU_EXE, which is normal for a standalone emulator pak)."
		return
	fi

	report_issue "Unrecognized emulator \"$emu\" for /Saves/$tag. Its RetroArch core folder name is unknown, so /Saves/$tag was left in place and its saves were not moved. If \"$emu\" is a libretro core, add \"$tag=<core folder name>\" to $MAPPING_CONF, reopen this pak, and choose \"Re-apply Core Save Mappings\". If it is a standalone emulator, leave it unmapped."
}

# Pass "quiet" as $2 to discover without touching the conversion report. The
# menu needs the counts on every render; only a real operation should write a
# report. Either way MAPPING_RESOLVED / MAPPING_MAPPABLE are left set.
#
# MAPPABLE counts only paks that declare an EMU_EXE, so the ratio stays
# actionable: a standalone emulator pak can never map and is excluded rather
# than sitting in the denominator forever.
discover_mappings() {
	local output="$1"
	local quiet="${2:-}"
	local raw="$output.raw.$$"
	local launch tag core

	: > "$raw" || return 1

	MAPPING_RESOLVED=0
	MAPPING_MAPPABLE=0

	for launch in "$SDCARD_PATH/Emus/$PLATFORM"/*.pak/launch.sh "$SYSTEM_PATH/paks/Emus"/*.pak/launch.sh; do
		[ -f "$launch" ] || continue
		tag=$(basename "$(dirname "$launch")" .pak)

		if awk -F'|' -v tag="$tag" '$1 == tag { found=1 } END { exit !found }' "$raw"; then
			continue
		fi

		if core=$(core_for_launch "$tag" "$launch") && [ -n "$core" ]; then
			printf '%s|%s\n' "$tag" "$core" >> "$raw"
			MAPPING_RESOLVED=$((MAPPING_RESOLVED + 1))
			MAPPING_MAPPABLE=$((MAPPING_MAPPABLE + 1))
		else
			if [ -n "$(launch_emu_exe "$launch")" ]; then
				MAPPING_MAPPABLE=$((MAPPING_MAPPABLE + 1))
			fi
			[ -n "$quiet" ] || report_unmapped_emulator "$tag" "$launch"
		fi
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

build_restore_rom_index() {
	local mappings="$1"
	local output="$2"
	local roms="$output.roms"
	local raw="$output.raw"
	local tag core rom base stem archive_stem

	: > "$raw" || return 1
	find "$ROMS_PATH" -type f > "$roms" 2>/dev/null || :

	while IFS='|' read -r tag core; do
		[ -n "$tag" ] || continue
		while IFS= read -r rom; do
			case "$rom" in
				"$ROMS_PATH"/*"($tag)"/*)
					base=$(basename "$rom")
					stem=$(strip_short_ext "$base")
					printf '%s|%s\n' "$tag" "$stem" >> "$raw"
					case "$base" in
						*.[zZ][iI][pP])
							archive_stem=$(strip_short_ext "$stem")
							[ "$archive_stem" = "$stem" ] ||
								printf '%s|%s\n' "$tag" "$archive_stem" >> "$raw"
							;;
					esac
					;;
			esac
		done < "$roms"
	done < "$mappings"

	sort -u "$raw" > "$output"
	rm -f "$roms" "$raw"
}

restore_save_stems() {
	local base="$1"
	local stem alternate

	stem=${base%.*}
	stem=${stem%.core-conflict-[0-9]*}
	printf '%s\n' "$stem"
	alternate=$(strip_short_ext "$stem")
	[ "$alternate" = "$stem" ] || printf '%s\n' "$alternate"
}

build_restore_plan() {
	local mappings="$1"
	local rom_index="$2"
	local plan="$3"
	local cores="$plan.cores"
	local core_dirs="$plan.core-dirs"
	local files="$plan.files"
	local stems="$plan.stems"
	local matches="$plan.matches"
	local core src file subrel tag_count tag stem match_count match_list

	RESTORE_MATCHED=0
	RESTORE_UNMATCHED=0
	RESTORE_AMBIGUOUS=0
	RESTORE_IGNORED=0

	: > "$plan" || return 1
	build_restore_rom_index "$mappings" "$rom_index" || return 1
	awk -F'|' 'NF >= 2 { print $2 }' "$mappings" | sort -u > "$cores"

	while IFS= read -r core; do
		[ -n "$core" ] || continue
		src="$CORES_PATH/$core"
		[ -d "$src" ] || continue
		tag_count=$(awk -F'|' -v core="$core" '$2 == core { count++ } END { print count + 0 }' \
			"$mappings")

		if [ "$tag_count" = 1 ]; then
			tag=$(awk -F'|' -v core="$core" '$2 == core { print $1; exit }' "$mappings")
			report_note "MAPPING: /Saves/Cores/$core -> /Saves/$tag (one-to-one)"
		else
			match_list=$(awk -F'|' -v core="$core" '
				$2 == core {
					if (list != "") list = list ", "
					list = list $1
				}
				END { print list }
			' "$mappings")
			report_note "MAPPING: /Saves/Cores/$core -> $match_list (ROM-name matching)"
		fi

		write_file_list "$src" "$files" || {
			rm -f "$cores" "$core_dirs" "$files" "$stems" "$matches"
			return 1
		}

		while IFS= read -r file; do
			[ -n "$file" ] || continue
			subrel=${file#"$src"/}
			if [ "$tag_count" = 1 ]; then
				printf '%s\t%s\t%s\n' "$file" "$tag" "$subrel" >> "$plan"
				report_note "MATCHED: $file -> /Saves/$tag"
				RESTORE_MATCHED=$((RESTORE_MATCHED + 1))
				continue
			fi

			restore_save_stems "$(basename "$file")" > "$stems"
			: > "$matches"

			while IFS= read -r stem; do
				[ -n "$stem" ] || continue
				awk -F'|' -v core="$core" -v stem="$stem" '
					NR == FNR {
						if ($2 == core) tags[$1] = 1
						next
					}
					tags[$1] && $2 == stem { print $1 }
				' "$mappings" "$rom_index" >> "$matches"
			done < "$stems"

			sort -u "$matches" > "$matches.sorted"
			mv "$matches.sorted" "$matches"
			match_count=$(wc -l < "$matches" | tr -d ' ')

			case "$match_count" in
				1)
					tag=$(cat "$matches")
					printf '%s\t%s\t%s\n' "$file" "$tag" "$subrel" >> "$plan"
					report_note "MATCHED: $file -> /Saves/$tag (matching ROM)"
					RESTORE_MATCHED=$((RESTORE_MATCHED + 1))
					;;
				0)
					report_issue "Unmatched shared-core file left in place: $file"
					RESTORE_UNMATCHED=$((RESTORE_UNMATCHED + 1))
					;;
				*)
					match_list=$(awk '
						{
							if (list != "") list = list ", "
							list = list $0
						}
						END { print list }
					' "$matches")
					report_issue "Ambiguous shared-core file left in place: $file matches $match_list"
					RESTORE_AMBIGUOUS=$((RESTORE_AMBIGUOUS + 1))
					;;
			esac
		done < "$files"
	done < "$cores"

	find "$CORES_PATH" -mindepth 1 -maxdepth 1 -type d > "$core_dirs" 2>/dev/null || :

	while IFS= read -r src; do
		[ -n "$src" ] || continue
		core=$(basename "$src")

		if awk -F'|' -v core="$core" '$2 == core { found=1 } END { exit !found }' \
			"$mappings"; then
			continue
		fi

		write_file_list "$src" "$files" || {
			rm -f "$cores" "$core_dirs" "$files" "$stems" "$matches"
			return 1
		}

		while IFS= read -r file; do
			[ -n "$file" ] || continue
			report_note "IGNORED: $file (no installed emulator maps to $core)"
			RESTORE_IGNORED=$((RESTORE_IGNORED + 1))
		done < "$files"
	done < "$core_dirs"

	rm -f "$cores" "$core_dirs" "$files" "$stems" "$matches"
	return 0
}
