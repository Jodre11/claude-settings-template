#!/usr/bin/env bash
# secret-breach-alarm.sh — side-effects for a detected secret leak. NEVER
# receives or records the raw secret value; only its class and source.
# Usage: secret-breach-alarm.sh <class-csv> <source> [transcript_path]
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/secret-patterns.sh"

classes="${1:-unknown}"
source_desc="${2:-unknown}"
transcript="${3:-}"
LEDGER="$HOME/.claude/breach-ledger.log"

# 1. Ledger (append-only; class + source + session only).
mkdir -p "$(dirname "$LEDGER")"
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '%s\tclass=%s\tsource=%s\tsession=%s\n' \
    "$ts" "$classes" "$source_desc" "${CLAUDE_SESSION_ID:-unknown}" >> "$LEDGER"

# 2. Out-of-band alert (macOS), unless suppressed (tests).
if [[ "${CLAUDE_BREACH_NO_NOTIFY:-0}" != "1" && "$(uname)" == "Darwin" ]]; then
    osascript -e "display notification \"Leak from ${source_desc} [${classes}]. REGENERATE NOW.\" with title \"CLAUDE SECRET BREACH\" sound name \"Sosumi\"" >/dev/null 2>&1 || true
fi
printf '\a' >&2 || true

# 3. In-place transcript scrub (belt-and-braces; the value may have been
#    persisted before updatedToolOutput took effect).
if [[ -n "$transcript" && -f "$transcript" ]]; then
    scrubbed=$(redact_secrets "$(cat "$transcript")") || scrubbed=""
    if [[ -n "$scrubbed" ]]; then
        printf '%s' "$scrubbed" > "$transcript.tmp" && mv "$transcript.tmp" "$transcript" || rm -f "$transcript.tmp"
    fi
fi

exit 0
