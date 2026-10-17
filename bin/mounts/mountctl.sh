#!/bin/sh
# mountctl.sh: the one place that changes bind mounts for NextUI paks.
#
# Paks never call mount or umount themselves. Each installs a layer script into
# $MOUNTS_HOME/layers.d and asks mountctl to apply. A layer answers two
# questions when run with sh:
#
#   <layer> scope   where it may mount and what it reads, one per line:
#                     at<TAB>/path      mounts exactly at /path
#                     below<TAB>/path   mounts somewhere strictly below /path
#                     reads<TAB>/path   reads its own state from /path
#   <layer> plan    the mounts it wants right now, one per line:
#                     source<TAB>target[<TAB>empty-target]
#                   empty-target refuses to hide a target that has files in it.
#                   A non-zero exit means "cannot decide": nothing of that layer
#                   or any later one is changed.
#
# Layers run in filename order (10-profiles.sh before 20-core-saves.sh). Each is
# planned only after every earlier layer is mounted, so a layer may read state
# that an earlier layer mounted. The number must therefore put a layer after
# anything that mounts over its targets or its state. apply checks the declared
# scopes first and changes nothing if the numbering gets that wrong.
#
# Commands:
#   install <layer.sh>...  install this copy (if newer), the layers and the hook
#   remove <name>...       unmount a layer's mounts and uninstall it
#   apply [--boot]         make the mount table match every layer's plan
#   down [name...]         unmount what the named layers own (default: all),
#                          leaving them installed; the next apply mounts them again
#   status                 print layers, scopes, plans and live mounts
#
# Sourced with MOUNTCTL_LIB=1 it only defines the mc_* read-only helpers.

MOUNTCTL_VERSION=2

: "${SDCARD_PATH:=/mnt/SDCARD}"
: "${PLATFORM:=tg5040}"
: "${USERDATA_PATH:=$SDCARD_PATH/.userdata/$PLATFORM}"
: "${SHARED_USERDATA_PATH:=$SDCARD_PATH/.userdata/shared}"
: "${LOGS_PATH:=$USERDATA_PATH/logs}"
# Outside .userdata/shared on purpose: that folder is itself a mount target.
: "${MOUNTS_HOME:=$USERDATA_PATH/Mounts}"
: "${MOUNTS_HOOK:=$USERDATA_PATH/.hooks/boot.d/00-mounts.sync.sh}"
: "${MOUNTS_LOG:=$LOGS_PATH/mounts.txt}"
: "${MOUNTS_LOCK:=/tmp/mountctl.lock}"
: "${MOUNTINFO_PATH:=/proc/self/mountinfo}"
export SDCARD_PATH PLATFORM USERDATA_PATH SHARED_USERDATA_PATH LOGS_PATH MOUNTS_HOME

MC_LAYER_DIR="$MOUNTS_HOME/layers.d"
MC_TAB=$(printf '\t')
MC_DECODE='function decode(path) {
	gsub(/\\040/, " ", path); gsub(/\\011/, sprintf("%c", 9), path)
	gsub(/\\012/, sprintf("%c", 10), path); gsub(/\\134/, sprintf("%c", 92), path)
	return path
}
function clean(path) {
	gsub(/\/+/, "/", path)
	if (length(path) > 1) sub(/\/$/, "", path)
	return path
}'

# The kernel records mount points by their resolved path. On h700 /mnt/SDCARD
# is normally a symlink to /mnt/sdcard, so a path built from SDCARD_PATH never
# appears in mountinfo as written. Resolve the deepest existing ancestor and
# re-append whatever does not exist yet.
mc_physical() {
	local dir="$1" rest="" real
	while [ -n "$dir" ] && [ "$dir" != / ]; do
		if real=$(CDPATH= cd -P -- "$dir" 2>/dev/null && pwd -P); then
			[ "$real" = / ] && [ -n "$rest" ] && real=""
			printf '%s\n' "$real$rest"
			return 0
		fi
		rest="/${dir##*/}$rest"
		case "$dir" in
			*/*) dir=${dir%/*} ;;
			*) break ;;
		esac
	done
	printf '%s\n' "$1"
}

# Every mount point, resolved, in mount-table order (newest last).
mc_mountpoints() {
	awk "$MC_DECODE"'{ print clean(decode($5)) }' "$MOUNTINFO_PATH" 2>/dev/null
}

mc_is_mounted() {
	local target
	target=$(mc_physical "$1")
	awk -v target="$target" "$MC_DECODE"'
		clean(decode($5)) == target { found = 1 }
		END { exit !found }' "$MOUNTINFO_PATH" 2>/dev/null
}

# Mount points strictly below $1.
mc_descendants() {
	local target
	target=$(mc_physical "$1")
	awk -v target="$target" "$MC_DECODE"'
		{ path = clean(decode($5)) }
		path != target && substr(path, 1, length(target) + 1) == target "/" { print path }' \
		"$MOUNTINFO_PATH" 2>/dev/null
}

# True when the newest mount at $2 shows the directory $1. The source is found
# through the mount that contains it, so an alias such as /Saves/Cores (itself
# under a bind mount) still matches.
mc_matches() {
	local source target
	source=$(mc_physical "$1")
	target=$(mc_physical "$2")
	awk -v source="$source" -v target="$target" "$MC_DECODE"'
		{
			root = decode($4); point = clean(decode($5))
			if (point == target) { found = 1; target_device = $3; target_root = clean(root) }
			if (point == "/" || source == point || substr(source, 1, length(point) + 1) == point "/") {
				if (length(point) > best) { best = length(point); source_device = $3; source_root = root; source_mount = point }
			}
		}
		END {
			if (!found || !best || target_device != source_device) exit 1
			suffix = (source_mount == "/") ? source : substr(source, length(source_mount) + 1)
			exit target_root != clean(source_root "/" suffix)
		}' "$MOUNTINFO_PATH" 2>/dev/null
}

mc_quote() {
	printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

mc_version_of() {
	sed -n 's/^MOUNTCTL_VERSION=\([0-9][0-9]*\)$/\1/p' "$1" 2>/dev/null | sed -n '1p'
}

# The copy a pak should run: the installed one, unless the pak's bundled copy
# ($1) is newer because this pak was updated and has not installed it yet.
mc_newest() {
	local installed bundled
	installed=$(mc_version_of "$MOUNTS_HOME/mountctl.sh")
	bundled=$(mc_version_of "$1")
	if [ -n "$installed" ] && [ "$installed" -ge "${bundled:-0}" ]; then
		printf '%s\n' "$MOUNTS_HOME/mountctl.sh"
	else
		printf '%s\n' "$1"
	fi
}

[ "${MOUNTCTL_LIB:-0}" = 1 ] && return 0

MC_SELF=$0
MC_FIRST_ERROR=""
MC_QUIESCED=0
MC_BATMON_WAS_RUNNING=0
MC_BATMON_LD_LIBRARY_PATH=""
MC_LOCKED=0
MC_CHANGED=0

mc_log() {
	mkdir -p "$LOGS_PATH" 2>/dev/null
	printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo unknown-time)" "$*" >> "$MOUNTS_LOG"
}

# The first error is what a calling pak shows; the log keeps all of them.
mc_error() {
	mc_log "ERROR: $*"
	[ -n "$MC_FIRST_ERROR" ] || MC_FIRST_ERROR=$*
}

mc_lock() {
	local tries=0 owner
	while ! mkdir "$MOUNTS_LOCK" 2>/dev/null; do
		owner=$(cat "$MOUNTS_LOCK/pid" 2>/dev/null)
		if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
			mc_log "Removing stale lock from pid $owner"
			rm -rf "$MOUNTS_LOCK"
			continue
		fi
		tries=$((tries + 1))
		[ "$tries" -le 30 ] || {
			mc_error "Another mount change is still running (pid ${owner:-unknown})."
			return 1
		}
		sleep 1
	done
	echo $$ > "$MOUNTS_LOCK/pid"
	MC_LOCKED=1
}

mc_unlock() {
	[ "$MC_LOCKED" = 1 ] || return 0
	rm -rf "$MOUNTS_LOCK"
	MC_LOCKED=0
}

mc_log_users() {
	local target="$1" proc pid comm cwd fd path
	mc_log "Processes using $target:"
	for proc in /proc/[0-9]*; do
		[ -d "$proc" ] || continue
		pid=${proc##*/}
		comm=$(cat "$proc/comm" 2>/dev/null || echo unknown)
		cwd=$(readlink "$proc/cwd" 2>/dev/null || true)
		case "$cwd" in
			"$target"|"$target"/*) mc_log "  pid=$pid comm=$comm cwd=$cwd" ;;
		esac
		for fd in "$proc"/fd/*; do
			[ -e "$fd" ] || [ -L "$fd" ] || continue
			path=$(readlink "$fd" 2>/dev/null || true)
			path=${path% (deleted)}
			case "$path" in
				"$target"|"$target"/*) mc_log "  pid=$pid comm=$comm fd=${fd##*/} path=$path" ;;
			esac
		done
	done
}

# --- services -----------------------------------------------------------------

# batmon keeps battery_logs.sqlite open in .userdata/shared on every platform,
# which makes that mount busy. It is stopped before the first change that
# touches shared data and restarted once apply is done.
mc_batmon_pid() {
	local pid state
	for pid in $(pidof batmon.elf 2>/dev/null); do
		state=$(awk '/^State:/ { print $2 }' "/proc/$pid/status" 2>/dev/null)
		[ "$state" != Z ] && { printf '%s\n' "$pid"; return 0; }
	done
	return 1
}

mc_batmon_running() {
	mc_batmon_pid >/dev/null 2>&1
}

mc_stop_services() {
	local pid attempt=1
	MC_QUIESCED=1
	pid=$(mc_batmon_pid) || return 0
	# batmon exits at once without the firmware library path, which differs per
	# platform, so reuse the running process's environment for the restart.
	MC_BATMON_LD_LIBRARY_PATH=$(tr '\0' '\n' 2>/dev/null < "/proc/$pid/environ" |
		sed -n 's/^LD_LIBRARY_PATH=//p' | sed -n '1p')
	MC_BATMON_WAS_RUNNING=1
	mc_log "Stopping batmon for a shared-data remount"
	killall -TERM batmon.elf 2>/dev/null || true
	while mc_batmon_running && [ "$attempt" -le 3 ]; do
		sleep 1
		attempt=$((attempt + 1))
	done
	if mc_batmon_running; then
		killall -9 batmon.elf 2>/dev/null || true
		sleep 1
	fi
	if mc_batmon_running; then
		mc_error "Could not stop battery monitoring before remounting shared data."
		return 1
	fi
	return 0
}

mc_resume_services() {
	[ "$MC_BATMON_WAS_RUNNING" = 1 ] || return 0
	MC_BATMON_WAS_RUNNING=0
	command -v batmon.elf >/dev/null 2>&1 || {
		mc_log "Warning: batmon was stopped but its executable is unavailable"
		return 1
	}
	if [ -n "$MC_BATMON_LD_LIBRARY_PATH" ]; then
		LD_LIBRARY_PATH="$MC_BATMON_LD_LIBRARY_PATH" batmon.elf >> "$LOGS_PATH/batmon.txt" 2>&1 &
	else
		batmon.elf >> "$LOGS_PATH/batmon.txt" 2>&1 &
	fi
	sleep 1
	if mc_batmon_running; then
		mc_log "Restarted batmon"
		return 0
	fi
	mc_log "Warning: batmon did not stay running; see batmon.txt"
	return 1
}

mc_touches_shared() {
	local path shared
	path=$(mc_physical "$1")
	shared=$(mc_physical "$SHARED_USERDATA_PATH")
	case "$path" in "$shared"|"$shared"/*) return 0 ;; esac
	case "$shared" in "$path"/*) return 0 ;; esac
	return 1
}

mc_quiesce_for() {
	[ "$MC_QUIESCED" = 1 ] && return 0
	mc_touches_shared "$1" || return 0
	mc_stop_services
}

# --- mounting -----------------------------------------------------------------

mc_umount_once() {
	local target="$1" attempt=1
	while [ "$attempt" -le 3 ]; do
		umount "$target" >> "$MOUNTS_LOG" 2>&1 && return 0
		sync
		sleep 1
		attempt=$((attempt + 1))
	done
	mc_log_users "$target"
	return 1
}

# Unmount $1 and everything below it, deepest first. A path listed twice is a
# stacked mount and is taken off twice.
mc_teardown() {
	local target list path guard=0
	target=$(mc_physical "$1")
	list="$MC_TMP/teardown"
	mc_descendants "$target" | awk '{ print length($0) "\t" $0 }' | sort -rn | cut -f2- > "$list"
	while IFS= read -r path; do
		[ -n "$path" ] || continue
		mc_is_mounted "$path" || continue
		mc_quiesce_for "$path" || return 1
		mc_umount_once "$path" || { mc_error "Could not unmount $path."; return 1; }
		MC_CHANGED=1
		mc_log "unmounted $path"
	done < "$list"
	while mc_is_mounted "$target"; do
		guard=$((guard + 1))
		[ "$guard" -le 8 ] || { mc_error "$target is still mounted after 8 unmounts."; return 1; }
		mc_quiesce_for "$target" || return 1
		mc_umount_once "$target" || { mc_error "Could not unmount $target."; return 1; }
		MC_CHANGED=1
		mc_log "unmounted $target"
	done
}

mc_mount_entry() {
	local source="$1" target="$2" opts="$3"
	if mc_is_mounted "$target" && mc_matches "$source" "$target"; then
		return 0
	fi
	mc_quiesce_for "$target" || return 1
	mc_teardown "$target" || return 1
	[ -d "$source" ] || { mc_error "Missing mount source $source for $target."; return 1; }
	mkdir -p "$target" || { mc_error "Could not create $target."; return 1; }
	if [ "$opts" = empty-target ] && [ -n "$(ls -A "$target" 2>/dev/null)" ]; then
		mc_error "Refusing to hide files already in $target."
		return 1
	fi
	mount -o bind "$source" "$target" >> "$MOUNTS_LOG" 2>&1 || {
		mc_error "Could not mount $source on $target."
		return 1
	}
	MC_CHANGED=1
	mc_matches "$source" "$target" || {
		mc_error "Mounted $target, but the mount table does not show $source there."
		return 1
	}
	mc_log "mounted $target -> $source"
}

# --- layers -------------------------------------------------------------------

# Writes $MC_TMP/layers (index, file) and $MC_TMP/scopes (index, kind, path).
mc_load_scopes() {
	local idx=0 layer name kind path
	: > "$MC_TMP/layers"
	: > "$MC_TMP/scopes"
	for layer in "$MC_LAYER_DIR"/[0-9]*.sh; do
		[ -f "$layer" ] || continue
		idx=$((idx + 1))
		name=${layer##*/}
		printf '%s\t%s\n' "$idx" "$layer" >> "$MC_TMP/layers"
		sh "$layer" scope > "$MC_TMP/scope.raw" 2>> "$MOUNTS_LOG" || {
			mc_error "$name could not report its scope."
			return 1
		}
		while IFS="$MC_TAB" read -r kind path; do
			[ -n "$kind" ] || continue
			case "$kind" in
				at|below|reads) ;;
				*) mc_error "$name declares an unknown scope kind: $kind"; return 1 ;;
			esac
			case "$path" in
				/*) ;;
				*) mc_error "$name declares a relative scope path: $path"; return 1 ;;
			esac
			printf '%s\t%s\t%s\n' "$idx" "$kind" "$(mc_physical "$path")" >> "$MC_TMP/scopes"
		done < "$MC_TMP/scope.raw"
	done
}

mc_layer_name() {
	awk -F '\t' -v idx="$1" '$1 == idx { n = $2; sub(/.*\//, "", n); print n }' "$MC_TMP/layers"
}

# An earlier layer must not have anything where a later layer mounts: the later
# mount would hide its mounts or the state it was planned from. "at A" covers A
# and everything under it; "below B" covers what is strictly under B.
mc_check_order() {
	local i ikind ipath j jkind jpath status=0
	awk -F '\t' '
		function inside(p, a) { return p == a || substr(p, 1, length(a) + 1) == a "/" }
		function under(p, b) { return substr(p, 1, length(b) + 1) == b "/" }
		{ n++; idx[n] = $1 + 0; kind[n] = $2; path[n] = $3 }
		END {
			for (i = 1; i <= n; i++) for (j = 1; j <= n; j++) {
				if (idx[i] >= idx[j]) continue
				hit = 0
				if (kind[j] == "at" && inside(path[i], path[j])) hit = 1
				if (kind[j] == "below" && under(path[i], path[j])) hit = 1
				if (hit) print idx[i] "\t" kind[i] "\t" path[i] "\t" idx[j] "\t" kind[j] "\t" path[j]
			}
		}' "$MC_TMP/scopes" > "$MC_TMP/order-errors"
	while IFS="$MC_TAB" read -r i ikind ipath j jkind jpath; do
		[ -n "$i" ] || continue
		mc_error "$(mc_layer_name "$i") ($ikind $ipath) sits where $(mc_layer_name "$j") mounts ($jkind $jpath); number $(mc_layer_name "$i") after it."
		status=1
	done < "$MC_TMP/order-errors"
	return "$status"
}

# True when $2 (resolved) is a target layer $1 declared it may mount.
mc_in_scope() {
	awk -F '\t' -v idx="$1" -v target="$2" '
		$1 == idx && $2 == "at" && target == $3 { ok = 1 }
		$1 == idx && $2 == "below" && substr(target, 1, length($3) + 1) == $3 "/" { ok = 1 }
		END { exit !ok }' "$MC_TMP/scopes"
}

# Live mount points that belong to layer $1 (the latest layer whose at/below
# scope covers them) and that $2, its normalised plan, does not want. Deepest
# first.
mc_stale() {
	mc_mountpoints | awk -F '\t' -v me="$1" -v scopes="$MC_TMP/scopes" -v plan="$2" '
		BEGIN {
			while ((getline line < scopes) > 0) {
				split(line, f, "\t")
				if (f[2] == "at" || f[2] == "below") { n++; si[n] = f[1] + 0; sk[n] = f[2]; sp[n] = f[3] }
			}
			while ((getline line < plan) > 0) { split(line, f, "\t"); want[f[5]] = 1 }
		}
		{
			m = $0; owner = 0
			for (k = 1; k <= n; k++) {
				hit = (sk[k] == "at" && m == sp[k]) || (sk[k] == "below" && substr(m, 1, length(sp[k]) + 1) == sp[k] "/")
				if (hit && si[k] > owner) owner = si[k]
			}
			if (owner == me + 0 && !(m in want) && !(m in seen)) { seen[m] = 1; print length(m) "\t" m }
		}' | sort -rn | cut -f2-
}

mc_owned_by() {
	: > "$MC_TMP/empty-plan"
	mc_stale "$1" "$MC_TMP/empty-plan"
}

mc_apply_layers() {
	local idx layer name source target opts phys len failed
	: > "$MC_TMP/planned"
	while IFS="$MC_TAB" read -r idx layer; do
		name=${layer##*/}
		sh "$layer" plan > "$MC_TMP/plan.raw" 2>> "$MOUNTS_LOG" || {
			mc_error "$name could not work out its mounts; see mounts.txt."
			return 1
		}
		: > "$MC_TMP/plan"
		while IFS="$MC_TAB" read -r source target opts; do
			[ -n "$source$target" ] || continue
			[ -n "$source" ] && [ -n "$target" ] || {
				mc_error "$name planned a malformed mount: $source $target"
				return 1
			}
			phys=$(mc_physical "$target")
			mc_in_scope "$idx" "$phys" || {
				mc_error "$name planned $target, outside the scope it declared."
				return 1
			}
			if grep -Fxq -- "$phys" "$MC_TMP/planned"; then
				mc_error "$name planned $target, which an earlier layer already mounts."
				return 1
			fi
			printf '%s\n' "$phys" >> "$MC_TMP/planned"
			# Empty fields collapse when read back with a tab IFS, so opts
			# always holds something and goes last.
			printf '%s\t%s\t%s\t%s\t%s\n' "${#phys}" "$source" "$target" "${opts:--}" "$phys" >> "$MC_TMP/plan"
		done < "$MC_TMP/plan.raw"

		mc_stale "$idx" "$MC_TMP/plan" > "$MC_TMP/stale"
		while IFS= read -r target; do
			[ -n "$target" ] || continue
			mc_is_mounted "$target" || continue
			mc_log "$name no longer wants $target"
			mc_teardown "$target" || return 1
		done < "$MC_TMP/stale"

		failed=0
		sort -n "$MC_TMP/plan" > "$MC_TMP/plan.sorted"
		while IFS="$MC_TAB" read -r len source target opts phys; do
			mc_mount_entry "$source" "$target" "$opts" || failed=1
		done < "$MC_TMP/plan.sorted"
		# Later layers may be planned from what this one mounts.
		[ "$failed" = 0 ] || return 1
	done < "$MC_TMP/layers"
}

mc_apply() {
	mc_load_scopes || return 1
	mc_check_order || return 1
	mc_apply_layers
}

mc_down() {
	local idx layer target name wanted
	mc_load_scopes || return 1
	for name in "$@"; do
		[ -f "$(mc_layer_file "$name")" ] || { mc_error "Layer $name is not installed."; return 1; }
	done
	: > "$MC_TMP/owned"
	while IFS="$MC_TAB" read -r idx layer; do
		if [ $# -gt 0 ]; then
			wanted=0
			for name in "$@"; do
				[ "$(mc_layer_file "$name")" = "$layer" ] && wanted=1
			done
			[ "$wanted" = 1 ] || continue
		fi
		mc_owned_by "$idx" >> "$MC_TMP/owned"
	done < "$MC_TMP/layers"
	awk '{ print length($0) "\t" $0 }' "$MC_TMP/owned" | sort -rn | cut -f2- > "$MC_TMP/owned.sorted"
	while IFS= read -r target; do
		mc_is_mounted "$target" || continue
		mc_teardown "$target" || return 1
	done < "$MC_TMP/owned.sorted"
}

mc_layer_file() {
	case "$1" in
		*.sh) printf '%s\n' "$MC_LAYER_DIR/$1" ;;
		*) printf '%s\n' "$MC_LAYER_DIR/$1.sh" ;;
	esac
}

mc_remove() {
	local name file idx target
	for name in "$@"; do
		file=$(mc_layer_file "$name")
		[ -f "$file" ] || continue
		mc_load_scopes || return 1
		idx=$(awk -F '\t' -v file="$file" '$2 == file { print $1 }' "$MC_TMP/layers")
		mc_owned_by "$idx" > "$MC_TMP/owned"
		while IFS= read -r target; do
			mc_is_mounted "$target" || continue
			mc_teardown "$target" || return 1
		done < "$MC_TMP/owned"
		rm -f "$file" || { mc_error "Could not remove layer $name."; return 1; }
		mc_log "removed layer ${file##*/}"
	done
	for file in "$MC_LAYER_DIR"/[0-9]*.sh; do
		[ -f "$file" ] && return 0
	done
	# Last layer out takes the manager and its boot hook with it.
	rm -f "$MOUNTS_HOOK" "$MOUNTS_HOME/mountctl.sh"
	rmdir "$MC_LAYER_DIR" "$MOUNTS_HOME" 2>/dev/null || true
	mc_log "no layers left; removed mountctl and its boot hook"
}

mc_installed_version() {
	mc_version_of "$MOUNTS_HOME/mountctl.sh"
}

mc_write_hook() {
	local tmp="$MOUNTS_HOOK.new.$$"
	mkdir -p "${MOUNTS_HOOK%/*}" || return 1
	{
		echo '#!/bin/sh'
		echo '# Installed by mountctl. The .sync.sh name makes run_hooks.sh finish it'
		echo '# before NextUI starts, so every layer is mounted by then.'
		printf 'exec sh %s apply --boot\n' "$(mc_quote "$MOUNTS_HOME/mountctl.sh")"
	} > "$tmp" && chmod 0755 "$tmp" && mv "$tmp" "$MOUNTS_HOOK"
}

mc_install() {
	local installed layer name tmp
	mkdir -p "$MC_LAYER_DIR" || { mc_error "Could not create $MC_LAYER_DIR."; return 1; }
	installed=$(mc_installed_version)
	if [ -z "$installed" ] || [ "$installed" -lt "$MOUNTCTL_VERSION" ]; then
		tmp="$MOUNTS_HOME/mountctl.sh.new.$$"
		cp "$MC_SELF" "$tmp" && chmod 0755 "$tmp" && mv "$tmp" "$MOUNTS_HOME/mountctl.sh" || {
			rm -f "$tmp"
			mc_error "Could not install mountctl."
			return 1
		}
		mc_log "installed mountctl $MOUNTCTL_VERSION (was ${installed:-not installed})"
	fi
	for layer in "$@"; do
		name=${layer##*/}
		case "$name" in
			[0-9][0-9]-*.sh) ;;
			*) mc_error "Layer names must look like NN-name.sh: $name"; return 1 ;;
		esac
		tmp="$MC_LAYER_DIR/.$name.new.$$"
		cp "$layer" "$tmp" && chmod 0755 "$tmp" && mv "$tmp" "$MC_LAYER_DIR/$name" || {
			rm -f "$tmp"
			mc_error "Could not install layer $name."
			return 1
		}
	done
	mc_write_hook || { mc_error "Could not install the boot hook $MOUNTS_HOOK."; return 1; }
}

mc_status() {
	local idx layer target
	echo "mountctl $MOUNTCTL_VERSION (installed: $(mc_installed_version))"
	mc_load_scopes || { echo "error: $MC_FIRST_ERROR"; return 1; }
	mc_check_order || echo "order error: $MC_FIRST_ERROR"
	while IFS="$MC_TAB" read -r idx layer; do
		echo "== ${layer##*/}"
		awk -F '\t' -v idx="$idx" '$1 == idx { print "  scope " $2 " " $3 }' "$MC_TMP/scopes"
		sh "$layer" plan 2>&1 | sed 's/^/  plan  /'
		mc_owned_by "$idx" | while IFS= read -r target; do echo "  live  $target"; done
	done < "$MC_TMP/layers"
}

mc_cleanup() {
	[ "$MC_QUIESCED" = 1 ] && mc_resume_services
	MC_QUIESCED=0
	mc_unlock
	[ -n "${MC_TMP:-}" ] && rm -rf "$MC_TMP"
}

MC_TMP=$(mktemp -d "${TMPDIR:-/tmp}/mountctl.XXXXXX" 2>/dev/null) || {
	MC_TMP="${TMPDIR:-/tmp}/mountctl.$$"
	mkdir -p "$MC_TMP" || exit 1
}
trap mc_cleanup EXIT
trap 'exit 130' INT TERM HUP

command=${1:-}
[ $# -gt 0 ] && shift
case "$command" in
	apply)
		if [ "${1:-}" = --boot ] && [ -f "$MOUNTS_LOG" ]; then
			mv -f "$MOUNTS_LOG" "$MOUNTS_LOG.old" 2>/dev/null || true
		fi
		mc_lock || { echo "$MC_FIRST_ERROR"; exit 1; }
		mc_log "apply ${1:-}"
		if mc_apply; then
			[ "$MC_CHANGED" = 1 ] && sync
			mc_log "apply complete"
			exit 0
		fi
		[ "$MC_CHANGED" = 1 ] && sync
		echo "$MC_FIRST_ERROR"
		exit 1
		;;
	down)
		mc_lock || { echo "$MC_FIRST_ERROR"; exit 1; }
		mc_log "down $*"
		mc_down "$@" && { sync; exit 0; }
		echo "$MC_FIRST_ERROR"
		exit 1
		;;
	install|remove)
		mc_lock || { echo "$MC_FIRST_ERROR"; exit 1; }
		"mc_$command" "$@" && exit 0
		echo "$MC_FIRST_ERROR"
		exit 1
		;;
	status)
		mc_status
		;;
	*)
		echo "usage: mountctl.sh install <layer.sh>... | remove <name>... | apply [--boot] | down [name...] | status" >&2
		exit 2
		;;
esac
