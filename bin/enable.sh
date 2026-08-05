#!/bin/sh

preflight_migration() {
	local table="$1"
	local files="$HOME_PATH/migration-files.$$"
	local tag core src

	while IFS='|' read -r tag core; do
		[ -n "$tag" ] && [ -n "$core" ] || continue
		src="$SAVES_PATH/$tag"
		[ -d "$src" ] || continue
		write_file_list "$src" "$files" || {
			rm -f "$files"
			ACTION_RESULT="Could not inspect /Saves/$tag."
			report_issue "$ACTION_RESULT"
			return 1
		}
	done < "$table"
	rm -f "$files"
}

migrate_tag() {
	local tag="$1"
	local core="$2"
	local format="$3"
	local src="$SAVES_PATH/$tag"
	local dst_root="$CORES_PATH/$core"
	local file rel rel_dir original_base base dst final mode files

	[ -d "$src" ] || {
		mkdir -p "$src"
		return
	}

	files="$HOME_PATH/migrate-$tag-files.$$"

	write_file_list "$src" "$files" || {
		rm -f "$files"
		ACTION_RESULT="Could not inspect /Saves/$tag."
		return 1
	}

	while IFS= read -r file; do
		rel=${file#"$src"/}
		rel_dir=$(dirname "$rel")
		original_base=$(basename "$file")
		base=$(core_target_name "$original_base" "$format")

		if [ "$rel_dir" = "." ]; then
			dst="$dst_root/$base"
		else
			dst="$dst_root/$rel_dir/$base"
		fi

		mkdir -p "$(dirname "$dst")" || {
			rm -f "$files"
			return 1
		}

		mode=copy
		if [ -f "$dst" ] && cmp -s "$file" "$dst"; then
			final="$dst"
		else
			final=$(unique_path "$dst")

			if [ "$final" != "$dst" ]; then
				report_issue "Collision: $file was copied to $final. Review both saves and choose the correct one."
			fi

			copy_save_file "$file" "$final" "$mode" || {
				rm -f "$files"
				report_issue "Could not copy $file to $final."
				return 1
			}
		fi

		printf '%s|%s\n' "${final#"$CORES_PATH"/}" "$tag/$rel" >> "$MANIFEST"
	done < "$files"
	rm -f "$files"
}

enable_core_saves() {
	local format tmp backup tag core
	format=$(get_save_format)

	case "$format" in 0|1|2|3) ;; *) ACTION_RESULT="Unknown save format: $format"; return 1 ;; esac

	start_report "Move or import saves into /Saves/Cores"
	tmp="$HOME_PATH/mounts.new.$$"

	discover_mappings "$tmp" || {
		rm -f "$tmp"
		ACTION_RESULT="No emulator mappings were found."
		return 1
	}

	preflight_migration "$tmp" || {
		rm -f "$tmp"
		finish_report
		ACTION_RESULT="$ACTION_RESULT
Report: $REPORT_FILE"
		return 1
	}

	begin_operation enable || {
		rm -f "$tmp"
		finish_report
		ACTION_RESULT="Could not initialize recoverable migration state.
Report: $REPORT_FILE"
		return 1
	}

	unmount_table "$MOUNT_TABLE" || {
		rm -f "$tmp"
		report_issue "Could not unmount an existing save folder."
		finish_report
		abort_operation "Could not unmount an existing save folder.
Report: $REPORT_FILE"
		return 1
	}

	show_progress "Backing up saves..." 10
	backup=$(make_backup enable) || {
		rm -f "$tmp"
		finish_report
		abort_operation "Could not back up the Saves folder.
Report: $REPORT_FILE"
		return 1
	}

	operation_phase backed-up "$backup" || {
		rm -f "$tmp"
		finish_report
		abort_operation "Could not record the save backup in the operation journal.
Report: $REPORT_FILE"
		return 1
	}

	create_core_folders "$tmp" || {
		rm -f "$tmp"
		finish_report
		abort_operation "Could not create the core save folders.
Report: $REPORT_FILE"
		return 1
	}

	: > "$MANIFEST"
	operation_phase migrating || {
		rm -f "$tmp"
		finish_report
		abort_operation "Could not update the operation journal.
Report: $REPORT_FILE"
		return 1
	}

	show_progress "Moving saves into Cores..." 45

	while IFS='|' read -r tag core; do
		migrate_tag "$tag" "$core" "$format" || {
			rm -f "$tmp"
			report_issue "Migration stopped while processing /Saves/$tag."
			finish_report
			abort_operation "Migration failed.
Report: $REPORT_FILE"
			return 1
		}
	done < "$tmp"

	while IFS='|' read -r tag core; do
		clear_mountpoint "$tag" || {
			rm -f "$tmp"
			report_issue "Could not empty /Saves/$tag for its bind mount."
			finish_report
			abort_operation "Could not prepare /Saves/$tag.
Report: $REPORT_FILE"
			return 1
		}
	done < "$tmp"

	if [ "$format" = 0 ] || [ "$format" = 2 ]; then
		set_save_format 3 || {
			report_issue "Could not set RetroArch uncompressed format."
			finish_report
			abort_operation "Could not set RetroArch uncompressed format.
Report: $REPORT_FILE"
			return 1
		}
	fi

	mv "$tmp" "$MOUNT_TABLE" || {
		finish_report
		abort_operation "Could not install the new mount table.
Report: $REPORT_FILE"
		return 1
	}

	{
		echo "backup=$backup"
		echo "old_format=$format"
		echo "enabled_at=$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now)"
	} > "$ENABLED_FILE" || {
		finish_report
		abort_operation "Could not record the enabled state.
Report: $REPORT_FILE"
		return 1
	}

	install_boot_hook || {
		finish_report
		abort_operation "Could not install the boot mount hook.
Report: $REPORT_FILE"
		return 1
	}

	operation_phase mounting || {
		finish_report
		abort_operation "Could not update the operation journal.
Report: $REPORT_FILE"
		return 1
	}

	show_progress "Mounting core save folders..." 80

	run_mounts || {
		report_issue "Saves were copied, but one or more bind mounts failed."
		finish_report
		abort_operation "One or more core save mounts failed.
Report: $REPORT_FILE"
		return 1
	}

	sync

	commit_operation || {
		finish_report
		abort_operation "Core saves were prepared, but the operation could not be committed.
Report: $REPORT_FILE"
		return 1
	}
	
	finish_report
	ACTION_RESULT="Core saves are active.
Sync /Saves/Cores with SyncThing.$(report_notice)"
}
