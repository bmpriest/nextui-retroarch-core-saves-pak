# RetroArch Core Saves.pak

Tool pak for keeping NextUI saves in RetroArch core-name folders. Automatically converts `.<tag>.sav/.sav` files to RetroArch's `.srm` format and creates folders in `/mnt/SDCARD/Saves/Cores` corresponding to RetroArch Cores. Can also convert all `.<tag>.sav/.sav` files to RetroArch's `.srm` format (even compressing or decompressing them!) and vice versa (See note on Save Ownership).

After running, saves will be in:

```text
/mnt/SDCARD/Saves/Cores/<RetroArch core name>/
```

RetroArch Core Saves bind-mounts those folders onto the system-tag paths expected by
MinArch:

```text
/mnt/SDCARD/Saves/GB  -> /mnt/SDCARD/Saves/Cores/Gambatte
/mnt/SDCARD/Saves/GBC -> /mnt/SDCARD/Saves/Cores/Gambatte
/mnt/SDCARD/Saves/GBA -> /mnt/SDCARD/Saves/Cores/gpSP
```

You can then point SyncThing at `/mnt/SDCARD/Saves/Cores` without performing any manual mapping. **If Profiles.pak is installed, use the canonical path instead** — see [Profiles](#profiles). The tag folders (such as `/Saves/GB`) are runtime aliases, not duplicate save trees. When viewing the folders from the on-device file manager, they will be populated, but viewing the SD card from your computer will display empty directories.

If multiple systems sharing a core contain the same save filename, files with
different contents are preserved. The first keeps the normal filename and
additional saves use `Game.core-conflict-N.srm`. Byte-identical files reuse the
existing core save instead of creating a conflict. Because MinArch will not load
conflict names automatically, the completion dialog reports differing files and
asks you to review them.

## UI

The pak displays:

- The active profile, when Profiles.pak is installed.
- Current NextUI save format.
- Where saves currently live, as a path.
- How many installed emulators are mapped to a core, as `resolved/mappable`.
- How many configured tag folders are mounted, if any.

The Mappings row counts only emulator paks that declare an `EMU_EXE`, so a
standalone emulator that can never map is left out of the total rather than
holding it below 100% forever. `3/4` therefore means one installed libretro
emulator still needs a `mapping.conf` entry.

## Completing partial mappings

When an emulator cannot be mapped, its saves are left in `/Saves/<tag>` and the
conversion report names it. After adding the override to `mapping.conf`, reopen
the pak: while core saves are active and mappings are incomplete — or the mount
table no longer matches what discovery produces, which also covers installing or
removing an emulator pak — a **Re-apply Core Save Mappings** action appears above
**Revert to NextUI Saves**, with the cursor defaulting to it.

Re-applying runs the same migration as the initial conversion. It is safe to
repeat: systems already in `/Saves/Cores` are detected as unchanged and left
alone, so only the newly mapped ones move. The action disappears once every
mappable emulator is mapped and applied. Reverting and converting again is not
required, and should not be used for this — a full restore does ROM-name
matching that can leave shared-core saves ambiguous.

The Mounts row shows the active count. It is selectable only while at least one
bind mount is verified live in `/proc/self/mountinfo`; otherwise it is a plain
status readout, so a mount table left behind by an earlier session cannot be
opened as if it were current. When selectable, confirming it opens a read-only
detail screen showing every immediate `/Saves` folder except `Cores` beside its
mapped `/Saves/Cores` folder. Unmapped folders from either side are also shown
with a blank opposite column.

The Convert Saves screen presents the configured format as a left-aligned
`From` value and all four formats as selectable targets. The current format
remains selectable so conversion can be reapplied when actual files do not
match the setting. When Core Saves is enabled, pressing X displays the sync
compatibility warning before opening the conversion screen.

Available actions depend on current state.

## Converting to Core Saves

1. Makes a backup of saves in `.core-saves-backups`
2. Creates folders in `/Saves/Cores` corresponding to on-device emulator cores
3. Copies save files to `/Saves/Cores`
4. If necessary, converts save files to .srm (uncompressed)
5. Installs script to mount folders at boot
6. Mounts folders


## Netplay

Netplay.pak covers an emulator pak by bind-mounting a staged copy over its
directory. The staged `launch.sh` is a wrapper that execs the original, kept
beside it as `launch.sh.old`, and the wrapper carries no `EMU_EXE` line.

`launch.sh.old` is the pak's real launcher, so Core Saves takes its `EMU_EXE`
as authoritative whenever the file is present and only falls back to the visible
`launch.sh`. A covered emulator therefore maps exactly as it does normally. Without that, every emulator Netplay covers dropped
out of discovery for as long as its mounts were up: the Mappings ratio collapsed
to whatever handful of systems Netplay does not cover, **Re-apply Core Save
Mappings** appeared and disappeared as those mounts came and went, and a
migration run at that moment would have left the covered systems' saves behind
in `/Saves/<tag>`.

`MGBA.pak`, which Netplay installs under `Emus/<platform>`, is a real libretro
emulator pak with its own bundled core, so it counts in Mappings and maps to
`/Saves/Cores/mGBA` — its own folder, separate from the stock GBA pak's
`/Saves/Cores/gpSP`. mGBA and gpSP are different cores with different save
formats, so the same ROM keeps a separate save under each. That separation is
deliberate; the two are never merged.

`NETPLAY.pak` is the game-switcher launcher rather than an emulator; it owns no
`/Saves` folder and is no longer named in the conversion report.

## Profiles

Profiles.pak bind-mounts `.profiles/<name>/Saves` onto `/Saves` at boot, so
`/Saves` and `/Saves/Cores` are the active profile's folders under a second
name — the same directories, not copies. Core Saves keeps mounting and writing
through `/Saves`, because NextUI and MinArch have that path hardcoded and the
tag aliases have to land where the emulators look for them.

What changes is what the pak reports and where it puts things that sit outside
`/Saves`:

- A **Profile** row shows the active profile. If Profiles has assigned Core
  Saves to a different profile, it shows that owner too, and the actions are
  refused until you switch back.
- **Location** shows the canonical path — `.profiles/<name>/Saves/Cores` rather
  than `/Saves/Cores`.
- Backups go to `.profiles/<name>/.core-saves-backups`. They used to share one
  SD-root folder across every profile, where the five-backup retention limit
  meant one profile's conversions could evict another's. An existing SD-root
  folder is moved into the active profile the next time the pak is opened.

Core Saves may only be enabled for one profile, which Profiles records in
`.profiles/core-saves-profile`. Its tag mounts are torn down before Profiles
switches the `/Saves` parent and re-established only for the owning profile.

### Syncthing with Profiles

Point Syncthing at:

```text
/mnt/SDCARD/.profiles/<name>/Saves/Cores
```

Not `/mnt/SDCARD/Saves/Cores`. Under Profiles that is a moving alias — it
points at whichever profile is active — and Profiles blocks initial setup if
Syncthing's `config.xml` contains `/Saves` or anything under it.

Scope the folder to `Cores`, not to the profile's whole `Saves` directory. The
tag bind mounts exist at `/Saves/<tag>`, so the matching
`.profiles/<name>/Saves/<tag>` folders sit empty on disk — but a peer device
that is not running Core Saves has real files in its `<tag>` folders, and those
would sync down underneath the mount where nothing can read them.

## Boot Mounts

Enabling core saves installs a synchronous NextUI boot hook:

```text
/mnt/SDCARD/.userdata/<platform>/.hooks/boot.d/core-saves.sync.sh
```

No pre-launch or post-launch hook is installed. Mounts are established once
per boot and remain active until shutdown or reversion.

Persistent state and the generated mount table live in:

```text
/mnt/SDCARD/.userdata/shared/RetroArch Core Saves/
```

The most recent migration or restore report is saved as:

```text
/mnt/SDCARD/.userdata/shared/RetroArch Core Saves/conversion-report.txt
```

It records filename collisions, conversion or copy failures, restore mappings,
and any ambiguous, unmatched, or ignored restore files. When a report contains
issues, the completion dialog displays the issue count and report location.

## Reverting to normal NextUI behavior

Restore only considers cores mapped by emulator paks currently installed on the
device. A core used by one system restores directly to that system's `/Saves`
folder. When several systems share a core, each save is restored only when its
filename matches a ROM in exactly one corresponding `/Roms/... (<tag>)` folder.
For zipped ROMs, matching accepts the exact names MinArch can derive by removing
the archive extension alone or by removing both the archive and enclosed ROM
extensions. It does not use fuzzy or filename-prefix matching.
Ambiguous and unmatched files, along with files in unmapped core folders, remain
untouched in `/Saves/Cores` and are listed in the conversion report.

Reverting removes the folder mapping and attempts to match save files to on-device ROMs so save files end up in the correct places. It should ignore folders in `/Saves/Cores` that do not match known on-device emulation cores. Reverting does not delete any data in `/Saves/Cores/.`

## Save Ownership and Backups

NextUI owns the normal `/Saves/<tag>` folders, so save game conversion may update
save files throughout `/Saves` (excluding `/Saves/Cores`). When core mounts are
active, the files may be shared with other devices. Conversion therefore warns
about sync compatibility and touches only core directories referenced by the
active mount table; unrelated directories under `/Saves/Cores` are ignored.

Every migration, restore, or in-place conversion first creates a backup under:

```text
/mnt/SDCARD/.core-saves-backups/
```

The five newest completed backups are retained. Failed, incomplete backups are
removed instead of counting toward that limit.

Enable, restore, and in-place conversion operations also use a small durable
operation journal. It
records the operation, current phase, pre-operation control files, and the
backup path. If an error occurs after changes begin, the pak immediately rolls
back the save tree, format setting, mount table, enabled state, and boot hook.
Conversion rollback is limited to the exact source and destination files in its
conversion plan, so unrelated saves—including files that arrive through
Syncthing while conversion runs—are not replaced from the backup.

If the process or device stops before that can happen, opening the pak again
detects the unfinished journal and performs the same recovery before showing
the menu. The conversion report remains the human-readable account of mappings,
results, and problems; it is not used as recovery state.



## Save Formats

NextUI formats are:

- `0`: MinUI, raw SRAM named `Game.gba.sav`
- `1`: RetroArch compressed, RZIP data named `Game.srm`
- `2`: Generic, raw SRAM named `Game.sav`
- `3`: RetroArch uncompressed, raw SRAM named `Game.srm`

Moving formats `0` or `2` into the core tree changes the setting to format `3`
and renames the files. Their SRAM payload is not transformed. Format `1` is
kept compressed and must not be treated as a raw `.sav` merely by renaming it.

When reverting while Generic format is active, RZIP-compressed `.srm` files are
decoded and raw `.srm` payloads pass through unchanged before being named
`.sav`. Reverting while an `.srm` format is active retains the payload encoding.

Raw save compatibility is still core-dependent. A save produced by one
libretro core is not guaranteed to load in a different core for the same
console. RTC files, memory cards, and other files in the save directory are
copied alongside SRAM.

Avoid having two devices write the same game save concurrently. Bind mounts do
not add a new SyncThing compatibility issue, but they also cannot prevent a
normal SyncThing conflict or a sync taken while an emulator is writing a file.

## Folder Mapping

Installed emulator paks are discovered from their `EMU_EXE=` setting and
converted to the core's exact `retro_system_info.library_name`, which is the
folder name RetroArch and MinArch actually use. Every core shipped in NextUI
Base and Extras is covered, along with the pak-store cores whose names have been
verified against core source.

An `EMU_EXE` value that is not recognized is **not** guessed at. That tag is left
unmapped, its saves stay in `/Saves/<tag>`, and the conversion report names the
emulator and asks you to add an override. Falling back to the `EMU_EXE` spelling
would create a folder the emulator never writes to and silently split your saves
across two locations. A pak with no `EMU_EXE` at all — a standalone emulator such
as PPSSPP or DraStic, which keeps its own saves — is noted rather than flagged,
since there is nothing to map.

Note that `library_name` is not always the name RetroArch displays, nor the
`corename` in libretro's `.info` metadata: FreeIntv reports `freeintv`. On device
you can read the real value with
`strings /path/to/<core>_libretro.so | grep -i <core>`.

Custom overrides go in `mapping.conf`:

```text
TAG=RetroArch core folder
```

For example:

```text
GBA=gpSP
GB=Gambatte
GBC=Gambatte
SFC=Snes9x
```

Overrides take precedence over the built-in mapping, so they also let you
correct an entry that turns out to be wrong without waiting for a release.

## Installation

0. Mount your SD card.
1. Download the release archive. GitHub replaces spaces with periods on upload,
   so it downloads as `RetroArch.Core.Saves.pak.zip`.
2. Create the folder `Tools/<PLATFORM>/RetroArch Core Saves.pak` on the SD card.
3. Extract the archive into that folder, so that `launch.sh`, `pak.json`,
   and `bin/` sit directly inside it. 
4. Safely unmount your SD card, insert it into device, enjoy

The folder may be renamed (for example to control menu ordering); the pak reads
its own folder name and the installed boot hook is generated to match.

`<PLATFORM>` should match your device:

- `tg5040` for TrimUI Brick or TrimUI Smart Pro.
- `tg5050` for TrimUI Smart Pro S.
- `h700` for the Anbernic RG XX family.
- `my285` for the Miyoo Mini Flip.

Each supported platform has its own binaries under `bin/<PLATFORM>`, and the pak
refuses to run on anything else rather than guessing. Library search paths are
also per-platform, matching what that platform's own launcher exports: h700
resolves `libGLESv2` and `libsamplerate` from the device's aarch64 multiarch
directories, which the other platforms do not have.

## Dependencies

The platform binaries are from the MIT-licensed projects:

- `josegonzalez/minui-list` 
- `josegonzalez/minui-presenter` 
- `jqlang/jq`

Their license texts are included under `bin/`.

## Tests

Run the host-side migration suite with:

```sh
"RetroArch Core Saves.pak/bin/tests/test-core-saves.sh"
```

The suite uses the host executables in `bin/desktop/`, reached through the same
`PATH`-based command lookup used on device.

## Release Archive

Build the release zip from committed files with:

```sh
make release
```

This uses `git archive`, so uncommitted and untracked changes are intentionally
excluded. To package the current working tree instead, use:

```sh
make dev
```

`make release` writes `dist/RetroArch Core Saves.pak.zip`; `make dev` writes
`RetroArch Core Saves.pak.zip` beside the pak. Both archives are flat. Development-only findings, desktop binaries, tests, Git metadata, and `bin/SHA256SUMS` are excluded.

## To Do:

- Add a save-format audit: report which files under `/Saves` are `.srm`,
  compressed `.srm`, `.sav`, or `.<ext>.sav`, flag any that disagree with the
  configured `saveFormat`, and offer to align them. Conversion currently refuses
  to run when it meets a file it cannot name (for example a format-`0` `.sav`
  with no ROM extension to strip) and lists it in
  `logs/core-saves-conversion-unresolved.txt`, but it cannot yet tell you the
  overall shape of the save tree before you start.
- Right now the last five backups are preserved. Need to make this user editable.
