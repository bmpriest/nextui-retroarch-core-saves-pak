#!/bin/sh

journal_value() {
	local key="$1"
	sed -n "s/^$key=//p" "$OPERATION_JOURNAL" 2>/dev/null | head -n 1
}

snapshot_operation_file() {
	local source="$1"
	local name="$2"
	if [ -f "$source" ]; then
		cp -p "$source" "$OPERATION_STATE/$name" || return 1
		: > "$OPERATION_STATE/$name.exists" || return 1
	fi
}

restore_operation_file() {
	local destination="$1"
	local name="$2"
	if [ -f "$OPERATION_STATE/$name.exists" ]; then
		mkdir -p "$(dirname "$destination")" || return 1
		cp -p "$OPERATION_STATE/$name" "$destination" || return 1
	else
		rm -f "$destination" || return 1
	fi
}

write_operation_journal() {
	local tmp="$OPERATION_JOURNAL.new.$$"
	{
		echo "operation=$TRANSACTION_OPERATION"
		echo "phase=$TRANSACTION_PHASE"
		echo "backup=$TRANSACTION_BACKUP"
	} > "$tmp" || return 1
	mv "$tmp" "$OPERATION_JOURNAL"
}

begin_operation() {
	local operation="$1"
	[ ! -f "$OPERATION_JOURNAL" ] || {
		ACTION_RESULT="An interrupted operation must be recovered first."
		return 1
	}
	rm -rf "$OPERATION_STATE"
	mkdir -p "$OPERATION_STATE" || return 1
	snapshot_operation_file "$MOUNT_TABLE" mounts.conf &&
		snapshot_operation_file "$MANIFEST" migration.manifest &&
		snapshot_operation_file "$ENABLED_FILE" enabled &&
		snapshot_operation_file "$HOOK_FILE" boot-hook &&
		snapshot_operation_file "$HOME_PATH/boot-mount.sh" boot-mount.sh || {
		rm -rf "$OPERATION_STATE"
		return 1
	}
	TRANSACTION_OPERATION="$operation"
	TRANSACTION_PHASE="prepared"
	TRANSACTION_BACKUP=""
	write_operation_journal || {
		rm -rf "$OPERATION_STATE"
		return 1
	}
	sync
}

operation_phase() {
	TRANSACTION_PHASE="$1"
	[ "$#" -lt 2 ] || TRANSACTION_BACKUP="$2"
	write_operation_journal && sync
}

restore_save_backup() {
	local backup="$1"

	[ -d "$backup/Saves" ] || return 1
	mkdir -p "$SAVES_PATH" || return 1
	rm -rf "$SAVES_PATH"/* "$SAVES_PATH"/.[!.]* "$SAVES_PATH"/..?* || return 1
	cp -a "$backup/Saves"/. "$SAVES_PATH"/ || return 1
	restore_backup_setting "$backup"
}

restore_backup_setting() {
	local backup="$1"

	if [ "$(cat "$backup/settings-existed" 2>/dev/null)" = 1 ]; then
		mkdir -p "$(dirname "$SETTINGS_PATH")" || return 1
		cp -p "$backup/minuisettings.txt" "$SETTINGS_PATH" || return 1
	else
		rm -f "$SETTINGS_PATH" || return 1
	fi
}

prepare_conversion_recovery() {
	local plan="$1"
	local paths="$OPERATION_STATE/conversion-paths"
	local raw="$paths.raw.$$"
	local validated="$paths.validated.$$"
	local path

	awk -F '	' 'NF >= 2 { print $1; print $2 }' "$plan" > "$raw" || {
		rm -f "$raw"
		return 1
	}
	: > "$validated" || {
		rm -f "$raw"
		return 1
	}
	while IFS= read -r path; do
		[ -n "$path" ] || continue
		case "$path" in
			"$SAVES_PATH"/*) printf '%s\n' "$path" >> "$validated" ;;
			*)
				rm -f "$raw" "$validated" "$paths"
				return 1
				;;
		esac
	done < "$raw"
	LC_ALL=C sort -u "$validated" > "$paths" || {
		rm -f "$raw" "$validated" "$paths"
		return 1
	}
	rm -f "$raw" "$validated"
}

restore_conversion_backup() {
	local backup="$1"
	local paths="$OPERATION_STATE/conversion-paths"
	local path relative saved

	[ -f "$paths" ] || return 1
	while IFS= read -r path; do
		[ -n "$path" ] || continue
		case "$path" in "$SAVES_PATH"/*) ;; *) return 1 ;; esac
		relative=${path#"$SAVES_PATH"/}
		saved="$backup/Saves/$relative"
		rm -rf "$path" || return 1
		if [ -e "$saved" ] || [ -L "$saved" ]; then
			mkdir -p "$(dirname "$path")" || return 1
			cp -a "$saved" "$path" || return 1
		fi
	done < "$paths"
	restore_backup_setting "$backup"
}

audit_operation() {
	local operation phase backup saved_table
	[ -f "$OPERATION_JOURNAL" ] || return 0

	operation=$(journal_value operation)
	phase=$(journal_value phase)
	backup=$(journal_value backup)
	case "$operation" in enable|restore|conversion) ;; *)
		ACTION_RESULT="The operation journal is invalid. No automatic changes were made."
		return 1
	esac
	case "$phase" in
		prepared|backed-up|migrating|mounting|installing|converting|recovering-mounts) ;;
		*)
		ACTION_RESULT="The operation journal has an invalid phase. No automatic changes were made."
		return 1
	esac
	[ -d "$OPERATION_STATE" ] || {
		ACTION_RESULT="The operation recovery snapshot is missing. No automatic changes were made."
		return 1
	}
	if [ -n "$backup" ]; then
		case "$backup" in "$BACKUP_ROOT"/*) ;; *)
			ACTION_RESULT="The operation journal has an invalid backup path. No automatic changes were made."
			return 1
		esac
		[ "$phase" = recovering-mounts ] || [ -d "$backup/Saves" ] || {
			ACTION_RESULT="The operation backup is missing. No automatic changes were made."
			return 1
		}
	fi

	saved_table="$OPERATION_STATE/mounts.conf"
	if [ "$phase" != recovering-mounts ]; then
		show_progress "Recovering interrupted $operation operation..." 10
		unmount_table "$MOUNT_TABLE" || {
			ACTION_RESULT="Could not unmount save folders during recovery. Reopen the pak to retry."
			return 1
		}
		[ "$saved_table" = "$MOUNT_TABLE" ] ||
			unmount_table "$saved_table" || {
				ACTION_RESULT="Could not unmount previous save folders during recovery. Reopen the pak to retry."
				return 1
			}

		if [ -n "$backup" ]; then
			if [ "$operation" = conversion ]; then
				restore_conversion_backup "$backup"
			else
				restore_save_backup "$backup"
			fi || {
				ACTION_RESULT="Could not restore the pre-operation save backup. Reopen the pak to retry."
				return 1
			}
		fi
		restore_operation_file "$MOUNT_TABLE" mounts.conf &&
			restore_operation_file "$MANIFEST" migration.manifest &&
			restore_operation_file "$ENABLED_FILE" enabled &&
			restore_operation_file "$HOOK_FILE" boot-hook &&
			restore_operation_file "$HOME_PATH/boot-mount.sh" boot-mount.sh || {
			ACTION_RESULT="Could not restore the pre-operation configuration. Reopen the pak to retry."
			return 1
		}
		TRANSACTION_OPERATION="$operation"
		TRANSACTION_PHASE="recovering-mounts"
		TRANSACTION_BACKUP="$backup"
		write_operation_journal && sync || {
			ACTION_RESULT="Save files were recovered, but the recovery checkpoint could not be recorded. Reopen the pak to retry."
			return 1
		}
	else
		show_progress "Retrying previous save mounts..." 80
	fi
	if [ -f "$OPERATION_STATE/enabled.exists" ]; then
		restore_previous_mounts || {
			ACTION_RESULT="Save files were recovered, but previous mounts could not be restored. Reopen the pak to retry."
			return 1
		}
	fi

	report_note "RECOVERY: Rolled back interrupted $operation operation."
	rm -f "$OPERATION_JOURNAL"
	rm -rf "$OPERATION_STATE"
	sync
	ACTION_RESULT="Recovered an interrupted $operation operation.
The previous save layout and settings were restored."
}

abort_operation() {
	local reason="$1"
	local recovery_result
	if audit_operation; then
		recovery_result="$ACTION_RESULT"
		ACTION_RESULT="$reason
$recovery_result"
	else
		ACTION_RESULT="$reason
Automatic rollback could not finish. Reopen the pak to retry recovery.
$ACTION_RESULT"
	fi
	return 1
}

commit_operation() {
	sync
	rm -f "$OPERATION_JOURNAL" || return 1
	rm -rf "$OPERATION_STATE" ||
		log "Committed operation left stale transaction state at $OPERATION_STATE."
	return 0
}
