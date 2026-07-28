#!/bin/sh

log() { echo "$*" >> "$LOG_FILE"; }

start_report() {
	REPORT_ISSUES=0
	{
		echo "RetroArch Core Saves conversion report"
		echo "Started: $(date 2>/dev/null || echo unknown)"
		echo "Action: $1"
		echo
	} > "$REPORT_FILE"
}

report_issue() {
	REPORT_ISSUES=$((REPORT_ISSUES + 1))
	printf 'ISSUE: %s\n' "$*" >> "$REPORT_FILE"
	log "$*"
}

finish_report() {
	{
		echo
		echo "Issues requiring attention: $REPORT_ISSUES"
	} >> "$REPORT_FILE"
}

report_notice() {
	if [ "$REPORT_ISSUES" -gt 0 ]; then
		printf '\n%d issue(s) need attention. Report:\n%s' "$REPORT_ISSUES" "$REPORT_FILE"
	fi
}
