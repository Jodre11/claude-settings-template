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
# Fail LOUD (not open): a mid-evaluation crash must not silently pass a result
# through as if screened. We do not withhold the result (updatedToolOutput is
# detector-only on 2.1.207 anyway, and a false withhold on every parse hiccup
# would hurt more than help), but we surface a visible 'screening failed' notice
# so a silent scrubber death is never invisible. Trap set before any real work.
trap 'printf "{\"hookSpecificOutput\":{\"hookEventName\":\"PostToolUse\",\"additionalContext\":\"⚠ secret-output-scrubber failed to evaluate this result — it was NOT screened for secrets. Treat any credential-shaped content in it as unscreened.\"}}"; exit 0' ERR
hook_read_input

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

    alarm="⛔ SECRET BREACH: a value matching [$csv] was detected in the result of ${tool} and logged. Depending on the Claude Code version, the raw value may still be present in this turn's context — treat it as exposed and REGENERATE IT NOW. Logged to ~/.claude/breach-ledger.log."
    hook_post_redact "$redacted" "$alarm"
fi
exit 0
