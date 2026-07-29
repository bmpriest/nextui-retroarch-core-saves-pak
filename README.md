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

You can then point SyncThing at `/mnt/SDCARD/Saves/Cores` without performing any manual mapping. The tag folders (such as `/Saves/GB`) are runtime aliases, not duplicate save trees. When viewing the folders from the on-device file manager, they will be populated, but viewing the SD card from your computer will display empty directories.

If multiple systems sharing a core contain the same save filename, every copy
is preserved. The first keeps the normal filename and additional saves use
`Game.core-conflict-N.srm`. Because MinArch will not load those conflict names
automatically, the completion dialog reports the issue and asks you to review
the files.

## UI

The pak displays:

- Current NextUI save format.
- Whether saves currently point to `/Saves` or `/Saves/Cores`.
- How many configured tag folders are mounted, if any.

The Mounts row shows the active count in two columns. When at least one bind
mount is active, a separate `View Mounts` action appears beneath it. Its
read-only detail screen shows every immediate `/Saves` folder except `Cores`
beside its mapped `/Saves/Cores` folder. Unmapped folders from either side are
also shown with a blank opposite column.

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

Installed emulator paks are discovered from their `EMU_EXE=` setting. Known
core executable names are converted to exact `retro_system_info.library_name`
spelling.

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

Additional emulator .paks still need testing, but should function as built-in emulators.

## Installation

0. Mount your SD card.
1. Download `RetroArch Core Saves.pak.zip` from Releases. It should be named `RetroArch Core Saves.pak.zip`
2. Copy the archive to `Tools/<PLATFORM>/Retroarch Core Saves.pak.zip`
3. Extract the archive in place, then delete it
4. Safely unmount your SD card, insert it into device, enjoy

`<PLATFORM>` should match your device:

- `tg5040` for TrimUI Brick or TrimUI Smart Pro.
- `tg5050` for TrimUI Smart Pro S

## Dependencies

The platform binaries are from the MIT-licensed projects:

- `josegonzalez/minui-list` 0.14.0
- `josegonzalez/minui-presenter` 0.12.0
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

Both targets create the sibling archive `RetroArch Core Saves.pak.zip`,
containing the top-level `RetroArch Core Saves.pak` directory. Development-only
findings, desktop binaries, tests, Git metadata, and `bin/SHA256SUMS` are
excluded.

## To Do:

- Make the save converter more robust. Build report on mismatch between save format setting and actual save files found in folders.
- Right now the last five backups are preserved. Need to make this user editable.
