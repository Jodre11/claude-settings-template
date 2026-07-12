#!/usr/bin/env bash
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/secret-breach-alarm.sh"
pass=0; fail=0
ok()  { printf 'PASS: %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); }

# Sandbox HOME so the real ledger is untouched; suppress OS notification.
TMP=$(mktemp -d /tmp/claude-breach-test.XXXXXX)
export HOME="$TMP"; mkdir -p "$HOME/.claude"
export CLAUDE_BREACH_NO_NOTIFY=1

# A transcript containing a raw secret must be scrubbed in place.
tfile="$TMP/transcript.jsonl"
printf '{"content":"leak AKIAIOSFODNN7EXAMPLE here"}\n' > "$tfile"

"$HOOK" "aws-access-key" "tool=Bash" "$tfile" >/dev/null 2>&1

# 1. Ledger written with class + source, and NOT the raw value.
if [[ -f "$HOME/.claude/breach-ledger.log" ]] \
    && grep -q 'class=aws-access-key' "$HOME/.claude/breach-ledger.log" \
    && grep -q 'source=tool=Bash' "$HOME/.claude/breach-ledger.log" \
    && ! grep -q 'AKIAIOSFODNN7EXAMPLE' "$HOME/.claude/breach-ledger.log"; then
    ok "ledger records class/source, not value"
else
    bad "ledger missing/incorrect or leaked value"
fi

# 2. Transcript scrubbed: raw value gone, marker present.
if ! grep -q 'AKIAIOSFODNN7EXAMPLE' "$tfile" && grep -q 'REDACTED-SECRET-BREACH' "$tfile"; then
    ok "transcript scrubbed in place"
else
    bad "transcript not scrubbed"
fi

rm -rf "$TMP"
echo "-----"; echo "passed: $pass  failed: $fail"; [ "$fail" -eq 0 ]
