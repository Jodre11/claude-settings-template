#!/usr/bin/env bash
# secret-breach-alarm.sh — side-effects for a detected secret leak. NEVER
# receives or records the raw secret value; only its class and source.
# Usage: secret-breach-alarm.sh <class-csv> <source> [transcript_path] [session_id]
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/secret-patterns.sh"

classes="${1:-unknown}"
source_desc="${2:-unknown}"
transcript="${3:-}"
session="${4:-${CLAUDE_SESSION_ID:-unknown}}"
LEDGER="$HOME/.claude/breach-ledger.log"
# The scrubber waits for this script before it replies, and a PostToolUse hook that overruns its 5 s timeout does
# not apply its redaction, so the secret would reach the model. The transcript rewrite below costs about 150 ms per
# MB, so a transcript over this bound is left as it is (the ledger says so): redacting the live result matters more.
SCRUB_MAX_BYTES=4194304

scrub=yes
note=""
if [[ -n "$transcript" && -f "$transcript" ]] && (( $(wc -c <"$transcript") > SCRUB_MAX_BYTES )); then
    scrub=no
    note=$'\ttranscript=unscrubbed-too-large'
fi

# 1. Ledger (append-only; class + source + session only).
mkdir -p "$(dirname "$LEDGER")"
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '%s\tclass=%s\tsource=%s\tsession=%s%s\n' \
    "$ts" "$classes" "$source_desc" "$session" "$note" >> "$LEDGER"

# 2. Out-of-band alert (macOS), unless suppressed (tests).
if [[ "${CLAUDE_BREACH_NO_NOTIFY:-0}" != "1" && "$(uname)" == "Darwin" ]]; then
    osascript -e "display notification \"Leak from ${source_desc} [${classes}]. REGENERATE NOW.\" with title \"CLAUDE SECRET BREACH\" sound name \"Sosumi\"" >/dev/null 2>&1 || true
fi
printf '\a' >&2 || true

# 3. In-place transcript scrub (belt-and-braces; the value may have been
#    persisted before updatedToolOutput took effect).
if [[ "$scrub" == yes && -n "$transcript" && -f "$transcript" ]]; then
    scrubbed=$(redact_secrets "$(cat "$transcript")") || scrubbed=""
    if [[ -n "$scrubbed" ]]; then
        printf '%s' "$scrubbed" > "$transcript.tmp" && mv "$transcript.tmp" "$transcript" || rm -f "$transcript.tmp"
    fi
fi

exit 0
