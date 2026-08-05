#!/bin/sh

restore_to_legacy() {
	local requested_format="$1"
	local current_format target_format backup stage mappings plan rom_index tags
	local tag file subrel rel_dir original_base base dst_root dst final mode

	[ -f "$ENABLED_FILE" ] || {
		ACTION_RESULT="Core saves are not active."
		return 1
	}
	current_format=$(get_save_format)
	case "$current_format" in 0|1|2|3) ;; *) current_format=3 ;; esac
	if [ "$requested_format" = "generic" ]; then
		target_format=2
	else
		target_format="$current_format"
	fi
	start_report "Restore saves to /Saves as $(save_format_name "$target_format")"
	show_progress "Discovering emulator mappings..." 5
	mappings="$HOME_PATH/restore-mappings.$$"
	plan="$HOME_PATH/restore-plan.$$"
	rom_index="$HOME_PATH/restore-roms.$$"
	tags="$HOME_PATH/restore-tags.$$"
	if ! discover_mappings "$mappings"; then
		rm -f "$mappings" "$plan" "$rom_index" "$tags"
		report_issue "No installed emulator mappings were found."
		finish_report
		ACTION_RESULT="Restore stopped before changing files.
No installed emulator mappings were found.
Report: $REPORT_FILE"
		return 1
	fi
	show_progress "Planning save restore..." 15
	if ! build_restore_plan "$mappings" "$rom_index" "$plan"; then
		rm -f "$mappings" "$plan" "$rom_index" "$tags"
		finish_report
		ACTION_RESULT="Could not determine where core saves belong.
Report: $REPORT_FILE"
		return 1
	fi
	{
		awk -F'|' 'NF { print $1 }' "$MOUNT_TABLE" 2>/dev/null
		cut -f2 "$plan" 2>/dev/null
	} | sort -u > "$tags"
	report_note ""
	report_note "Restore summary:"
	report_note "  Matched save files: $RESTORE_MATCHED"
	report_note "  Unmatched shared-core files: $RESTORE_UNMATCHED"
	report_note "  Ambiguous shared-core files: $RESTORE_AMBIGUOUS"
	report_note "  Files ignored in unmapped core folders: $RESTORE_IGNORED"
	begin_operation restore || {
		rm -f "$mappings" "$plan" "$rom_index" "$tags"
		finish_report
		ACTION_RESULT="Could not initialize recoverable restore state.
Report: $REPORT_FILE"
		return 1
	}
	unmount_table "$MOUNT_TABLE" || {
		rm -f "$mappings" "$plan" "$rom_index" "$tags"
		report_issue "Could not unmount the core save folders."
		finish_report
		abort_operation "Could not unmount the core save folders.
Report: $REPORT_FILE"
		return 1
	}
	show_progress "Backing up saves..." 30
	backup=$(make_backup restore) || {
		rm -f "$mappings" "$plan" "$rom_index" "$tags"
		finish_report
		abort_operation "Could not back up the current saves.
Report: $REPORT_FILE"
		return 1
	}
	operation_phase backed-up "$backup" || {
		rm -f "$mappings" "$plan" "$rom_index" "$tags"
		finish_report
		abort_operation "Could not record the save backup in the operation journal.
Report: $REPORT_FILE"
		return 1
	}

	show_progress "Restoring /Saves folders..." 50
	stage="$OPERATION_STATE/restore-stage"
	rm -rf "$stage"
	mkdir -p "$stage" || {
		rm -f "$mappings" "$plan" "$rom_index" "$tags"
		finish_report
		abort_operation "Could not create restore staging.
Report: $REPORT_FILE"
		return 1
	}
	while IFS= read -r tag; do
		[ -n "$tag" ] || continue
		dst_root="$stage/$tag"
		mkdir -p "$dst_root" || {
			rm -f "$mappings" "$plan" "$rom_index" "$tags"
			rm -rf "$stage"
			finish_report
			abort_operation "Could not create staging for /Saves/$tag.
Report: $REPORT_FILE"
			return 1
		}
		if [ -d "$SAVES_PATH/$tag" ]; then
			cp -a "$SAVES_PATH/$tag"/. "$dst_root"/ || {
				rm -f "$mappings" "$plan" "$rom_index" "$tags"
				rm -rf "$stage"
				finish_report
				abort_operation "Could not stage the existing /Saves/$tag folder.
Report: $REPORT_FILE"
				return 1
			}
		fi
	done < "$tags"

	while IFS="$(printf '\t')" read -r file tag subrel; do
		[ -n "$file" ] && [ -n "$tag" ] || continue
		dst_root="$stage/$tag"
		rel_dir=$(dirname "$subrel")
		original_base=$(basename "$file")
		base=$(legacy_name_for_file "$subrel" "$target_format")
		if [ "$rel_dir" = "." ]; then
			dst="$dst_root/$base"
		else
			dst="$dst_root/$rel_dir/$base"
		fi
		mkdir -p "$(dirname "$dst")" || {
			rm -f "$mappings" "$plan" "$rom_index" "$tags"
			rm -rf "$stage"
			finish_report
			abort_operation "Could not create a restore destination.
Report: $REPORT_FILE"
			return 1
		}
		final=$(unique_path "$dst")
		if [ "$final" != "$dst" ]; then
			report_issue "Collision: $file was restored to $final. Review both saves and choose the correct one."
		fi
		mode=copy
		if [ "$target_format" = 2 ] &&
			[ "$base" != "$original_base" ]; then
			mode=decode
		fi
		copy_save_file "$file" "$final" "$mode" || {
			rm -f "$mappings" "$plan" "$rom_index" "$tags"
			rm -rf "$stage"
			report_issue "Could not convert or copy $file to $final."
			finish_report
			abort_operation "Could not restore one or more save files.
Report: $REPORT_FILE"
			return 1
		}
	done < "$plan"

	operation_phase installing || {
		rm -f "$mappings" "$plan" "$rom_index" "$tags"
		rm -rf "$stage"
		finish_report
		abort_operation "Could not update the operation journal.
Report: $REPORT_FILE"
		return 1
	}
	show_progress "Installing restored saves..." 75
	set_save_format "$target_format" || {
		rm -f "$mappings" "$plan" "$rom_index" "$tags"
		rm -rf "$stage"
		finish_report
		abort_operation "Could not update the save format.
Report: $REPORT_FILE"
		return 1
	}

	while IFS= read -r tag; do
		[ -n "$tag" ] || continue
		clear_mountpoint "$tag" || {
			rm -f "$mappings" "$plan" "$rom_index" "$tags"
			rm -rf "$stage"
			finish_report
			abort_operation "Could not prepare /Saves/$tag for restored files.
Report: $REPORT_FILE"
			return 1
		}
		cp -a "$stage/$tag"/. "$SAVES_PATH/$tag"/ || {
			rm -f "$mappings" "$plan" "$rom_index" "$tags"
			rm -rf "$stage"
			finish_report
			abort_operation "Could not install staged files into /Saves/$tag.
Report: $REPORT_FILE"
			return 1
		}
	done < "$tags"
	show_progress "Finishing restore..." 90
	rm -f "$HOOK_FILE" "$ENABLED_FILE"
	rm -f "$mappings" "$plan" "$rom_index" "$tags"
	rm -rf "$stage"
	sync
	commit_operation || {
		finish_report
		abort_operation "Saves were restored, but the operation could not be committed.
Report: $REPORT_FILE"
		return 1
	}
	finish_report
	ACTION_RESULT="Saves now point to /Saves using $(save_format_name "$target_format").
$RESTORE_MATCHED files restored; $RESTORE_UNMATCHED unmatched, $RESTORE_AMBIGUOUS ambiguous, $RESTORE_IGNORED ignored.
Backup: $backup
Report: $REPORT_FILE"
}
