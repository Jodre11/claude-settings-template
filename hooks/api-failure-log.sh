#!/usr/bin/env bash
# api-failure-log.sh — StopFailure / PostToolUseFailure hook. Appends a JSONL record
# so provider errors (Bedrock 4xx/5xx, tool failures) accumulate passively.
# The `error` field probes the known/likely keys, but the live payload does not
# always expose the error text at a predictable key — so `raw` captures the ENTIRE
# hook payload verbatim. Never drop detail: `error` is a convenience projection,
# `raw` is the source of truth for later diagnosis.
set -euo pipefail
source "$(dirname "$0")/_lib.sh"
hook_read_input
root="${HOME_OVERRIDE:-$HOME}"
mkdir -p "$root/.claude/telemetry"
jq -c '{ts: (now|todate),
        event: (.hook_event_name // "unknown"),
        error: (.error_type // .tool_error // .error // .reason
                // .tool_response.error // .message // null),
        tool:  (.tool_name // null),
        cwd:   (.cwd // null),
        raw:   .}' <<< "$HOOK_INPUT" \
    >> "$root/.claude/telemetry/api-failures.jsonl"
exit 0
