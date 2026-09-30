#!/usr/bin/env bash
# api-failure-log.sh — StopFailure hook. Appends one slim JSONL record per turn that ended on an API error (Bedrock
# 4xx/5xx, rate limits, auth): {ts, error, error_details, session_id, cwd}. It ignores every other event and never
# stores the raw payload, tool inputs or message text.
set -euo pipefail
source "$(dirname "$0")/_lib.sh"
hook_read_input
if [[ "$(hook_field '.hook_event_name')" != "StopFailure" ]]; then
    exit 0
fi
root="${HOME_OVERRIDE:-$HOME}"
mkdir -p "$root/.claude/telemetry"
jq -c '{ts: (now | todate), error: (.error // null), error_details: (.error_details // null),
        session_id: (.session_id // null), cwd: (.cwd // null)}' <<< "$HOOK_INPUT" \
    >> "$root/.claude/telemetry/api-failures.jsonl"
exit 0
