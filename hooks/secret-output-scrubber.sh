#!/usr/bin/env bash
# secret-output-scrubber.sh — PostToolUse and PostToolUseFailure hook (all tools).
# PostToolUse: scans every string leaf of the tool result for secret value shapes; if any are present, fires the
# breach responder and replaces the result via updatedToolOutput with a copy whose string leaves are redacted. The
# copy keeps the tool's output shape: built-in tools (Bash, Read, ...) return objects and silently ignore a
# replacement of any other shape; MCP results pass through unchecked.
# PostToolUseFailure: scans the failed call's .error text. That event cannot replace what the model sees, so a
# secret there is detected and alarmed, not prevented; prevention stays with the PreToolUse guards.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/_lib.sh"
source "$DIR/secret-patterns.sh"
# Fail LOUD (not open): a mid-evaluation crash must not silently pass a result through as if screened, so surface
# a visible 'screening failed' notice under the payload's own event. Trap set before any work.
SCRUB_EVENT=PostToolUse
SCRUB_FAIL_MSG="⚠ secret-output-scrubber failed to evaluate this result — it was NOT screened for secrets. Treat"
SCRUB_FAIL_MSG+=" any credential-shaped content in it as unscreened."
# scrub_failed: ERR-trap handler; emits the 'NOT screened' notice under $SCRUB_EVENT and exits 0.
scrub_failed() {
    printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"%s"}}' "$SCRUB_EVENT" "$SCRUB_FAIL_MSG"
    exit 0
}
trap scrub_failed ERR
hook_read_input
if [[ "$(hook_field '.hook_event_name')" == PostToolUseFailure ]]; then
    SCRUB_EVENT=PostToolUseFailure
fi

# Skip scanning results whose target is a firewall self-definition/test/doc file
# (their contents embed example secret vectors by design — scanning them fires a
# false breach alarm). Read→file_path, Grep→path, Bash→scan the command string
# for an exempt path. NOT a content allowlist: real secrets elsewhere still caught.
target_path=$(hook_field '.tool_input.file_path')
if [[ -z "$target_path" ]]; then
    target_path=$(hook_field '.tool_input.path')
fi
cmd_str=$(hook_field '.tool_input.command')
if path_is_scan_exempt "$target_path"; then
    exit 0
fi
if [[ -n "$cmd_str" ]] && path_is_scan_exempt "$cmd_str"; then
    exit 0
fi

# raise_alarm <classes> <source-suffix>: set TOOL and CSV for the caller's message, then run the breach responder
# (ledger with the payload session, OS alert, transcript scrub). Never blocks on failure.
raise_alarm() {
    TOOL=$(hook_field '.tool_name')
    CSV=$(printf '%s' "$1" | tr '\n' ',' | sed 's/,$//')
    "$DIR/secret-breach-alarm.sh" "$CSV" "tool=${TOOL}$2" "$(hook_field '.transcript_path')" \
        "$(hook_field '.session_id')" >/dev/null 2>&1 || true
}

if [[ "$SCRUB_EVENT" == PostToolUseFailure ]]; then
    err=$(jq -r '.error | if type == "string" then . else tojson end' <<< "$HOOK_INPUT")
    if classes=$(scan_content_for_secrets "$err"); then
        raise_alarm "$classes" " (failed)"
        alarm="⛔ SECRET BREACH: a value matching [$CSV] was detected in the error output of a failed ${TOOL} call"
        alarm+=" and logged. This event cannot redact it, so the value is already in this conversation. Treat it as"
        alarm+=" exposed and REGENERATE IT NOW. Logged to ~/.claude/breach-ledger.log."
        hook_post_context "$alarm" PostToolUseFailure
    fi
    exit 0
fi

# The text the model would see: every string leaf of tool_response, newline-joined.
leaves=$(jq -r '[.tool_response | .. | strings] | join("\n")' <<< "$HOOK_INPUT" 2>/dev/null || printf '')

# Fallback: with no string leaves, scan the raw payload so a novel response shape cannot
# smuggle a secret past the alarm.
scan_target="$leaves"
if [[ -z "$scan_target" ]]; then
    scan_target="$HOOK_INPUT"
fi

if classes=$(scan_content_for_secrets "$scan_target"); then
    raise_alarm "$classes" ""

    if [[ -z "$leaves" ]]; then
        # Nothing in the result to rewrite: the match is elsewhere in the payload (e.g.
        # tool_input), so nothing was redacted and the value is already in this conversation.
        alarm="⛔ SECRET BREACH: a value matching [$CSV] was detected in the ${TOOL} call payload"
        alarm+=" (not in its result) and logged. Nothing was redacted: the value is already in"
        alarm+=" this conversation. Treat it as exposed and REGENERATE IT NOW. Logged to"
        alarm+=" ~/.claude/breach-ledger.log."
        hook_post_context "$alarm"
    fi
    alarm="⛔ SECRET BREACH: a value matching [$CSV] was detected in the result of ${TOOL} and"
    alarm+=" logged. It was redacted before reaching you, but the tool printed it and telemetry"
    alarm+=" captured the original — treat it as exposed and REGENERATE IT NOW. Logged to"
    alarm+=" ~/.claude/breach-ledger.log."
    redacted=$(jq -c '.tool_response' <<< "$HOOK_INPUT" | redact_json_strings)
    hook_post_redact "$redacted" "$alarm"
fi
exit 0
