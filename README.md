# RetroArch Core Saves.pak

Tool pak for keeping NextUI SRAM saves in RetroArch core-name folders. Offers to convert all `.<tag>.sav/.sav` files to RetroArch's `.srm` format (even compressing or decompressing them!).

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

Saves are backed up to `.core-saves-backups` before any changes are made. Running the pak again will also allow you to revert the changes and remove the bindings.

The existing `/Saves/<tag>` directories are retained and emptied before the
core folders are mounted over them.

If multiple systems sharing a core contain the same save filename, every copy
is preserved. The first keeps the normal filename and additional saves use
`Game.core-conflict-N.srm`. Because MinArch will not load those conflict names
automatically, the completion dialog reports the issue and asks you to review
the files.

## UI

The pak displays:

- Current NextUI save format.
- Whether saves currently point to `/Saves` or `/Saves/Cores`.
- How many configured tag folders are mounted.

Available actions depend on current state:

- Create or refresh core folders.
- Move or import saves into `/Saves/Cores`.
- Restore current core saves to `/Saves` while retaining `.srm`.
- Restore core saves to `/Saves` as Generic `.sav`, decoding RZIP when needed.
- Delete `/Saves/Cores` after core saves have been disabled.
- Show save-format compatibility notes.

Every migration, restore, or deletion first creates a backup under:

```text
/mnt/SDCARD/.core-saves-backups/
```

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

It records filename collisions and conversion or copy failures. When a report
contains issues, the completion dialog displays the issue count and report
location.

## Save Formats

NextUI formats are:

- `0`: MinUI, raw SRAM named `Game.gba.sav`
- `1`: RetroArch compressed, RZIP data named `Game.srm`
- `2`: Generic, raw SRAM named `Game.sav`
- `3`: RetroArch uncompressed, raw SRAM named `Game.srm`

Moving formats `0` or `2` into the core tree changes the setting to format `3`
and renames the files. Their SRAM payload is not transformed. Format `1` is
kept compressed and must not be treated as a raw `.sav` merely by renaming it.

The Generic restore decodes RZIP-compressed `.srm` files and passes raw `.srm`
payloads through unchanged before naming them `.sav`. Restoring as `.srm`
retains the active format and payload encoding.

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

1. Download `RetroArch Core Saves.pak.zip` from Releases.
2. Extract the archive.
3. Copy `RetroArch Core Saves.pak` folder to `/Tools/<PLATFORM>/` on your SD Card.
   `<PLATFORM>` should match your device: either `tg5040` or `tg5050`.

## UI Dependencies

The platform UI binaries are from the MIT-licensed projects:

- `josegonzalez/minui-list` 0.14.0
- `josegonzalez/minui-presenter` 0.12.0
- `jqlang/jq`

Their license texts are included under `bin/`.

Shell helpers for reporting, settings, emulator mappings, backups, save-format
handling, and mount management also live under `bin/`. The boot hook installs
its runtime copy from `bin/mount.sh`.

## Tests

Run the host-side migration suite with:

```sh
"RetroArch Core Saves.pak/bin/tests/test-core-saves.sh"
```
