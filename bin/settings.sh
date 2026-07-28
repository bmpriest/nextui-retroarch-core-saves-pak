#!/bin/sh

save_format_name() {
	case "$1" in
		0) echo "MinUI (.ext.sav)" ;;
		1) echo "RetroArch compressed (.srm)" ;;
		2) echo "Generic (.sav)" ;;
		3) echo "RetroArch uncompressed (.srm)" ;;
		*) echo "Unknown ($1)" ;;
	esac
}

get_save_format() {
	local value=""
	if [ -f "$SETTINGS_PATH" ]; then
		value=$(sed -n 's/^saveFormat=\([0-9][0-9]*\).*/\1/p' "$SETTINGS_PATH" | tail -n 1)
	fi
	echo "${value:-0}"
}

set_save_format() {
	local value="$1"
	local tmp="$SETTINGS_PATH.tmp.$$"
	mkdir -p "$(dirname "$SETTINGS_PATH")" || return 1
	if [ -f "$SETTINGS_PATH" ]; then
		if grep -q '^saveFormat=' "$SETTINGS_PATH"; then
			sed "s/^saveFormat=.*/saveFormat=$value/" "$SETTINGS_PATH" > "$tmp" || return 1
		else
			cp "$SETTINGS_PATH" "$tmp" || return 1
			echo "saveFormat=$value" >> "$tmp"
		fi
	else
		echo "saveFormat=$value" > "$tmp" || return 1
	fi
	mv "$tmp" "$SETTINGS_PATH"
}
