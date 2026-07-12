#!/usr/bin/env bash
# secret-output-scrubber.sh — PostToolUse hook (all tools). Scans the tool
# result for secret value shapes; if any are present, emits a redacted result
# via updatedToolOutput and fires the breach responder. Fail SAFE: if the result
# cannot be parsed but the raw hook input contains a secret shape, redact the
# whole result.
#
# KNOWN LIMITATION (Claude Code 2.1.207, verified 2026-07-12): updatedToolOutput
# is NOT applied to the result the model sees on this version (the additionalContext
# alarm from the same JSON IS applied). So in practice this hook DETECTS + ALARMS +
# triggers the on-disk transcript scrub, but does NOT redact the in-turn result the
# model/Bedrock receive. Re-test after CC upgrades; if honoured, this becomes true
# pre-egress prevention as designed. See docs/superpowers/specs/2026-07-12-*.md.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/_lib.sh"
source "$DIR/secret-patterns.sh"
hook_read_input

# Stringify tool_response (may be a string or an object).
resp=$(jq -r '.tool_response | if type=="string" then . elif .==null then "" else tojson end' <<< "$HOOK_INPUT" 2>/dev/null || printf '')

# Fallback: if extraction produced nothing, scan the raw payload so a novel
# response shape cannot smuggle a secret past the scrubber.
scan_target="$resp"
if [[ -z "$scan_target" ]]; then
    scan_target="$HOOK_INPUT"
fi

if classes=$(scan_content_for_secrets "$scan_target"); then
    tool=$(hook_field '.tool_name')
    transcript=$(hook_field '.transcript_path')
    csv=$(printf '%s' "$classes" | tr '\n' ',' | sed 's/,$//')

    # Side-effects (ledger, OS alert, transcript scrub). Never blocks on failure.
    "$DIR/secret-breach-alarm.sh" "$csv" "tool=$tool" "$transcript" >/dev/null 2>&1 || true

    # Redact for the model. If we had a parsed response, redact it; otherwise we
    # cannot safely reconstruct the shape, so replace the whole result.
    if [[ -n "$resp" ]]; then
        redacted=$(redact_secrets "$resp")
    else
        redacted="[REDACTED-SECRET-BREACH: tool result withheld — a secret value ($csv) was detected and could not be selectively redacted]"
    fi

    alarm="⛔ SECRET BREACH: a value matching [$csv] was found in the result of ${tool} and REDACTED before reaching the model. This credential may be exposed — REGENERATE IT NOW. Logged to ~/.claude/breach-ledger.log."
    hook_post_redact "$redacted" "$alarm"
fi
exit 0
