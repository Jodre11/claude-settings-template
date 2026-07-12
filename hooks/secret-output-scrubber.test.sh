#!/usr/bin/env bash
set -u
HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/secret-output-scrubber.sh"
pass=0; fail=0
ok()  { printf 'PASS: %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); }

# Sandbox HOME + suppress notification so side-effects are inert.
TMP=$(mktemp -d /tmp/claude-scrub-test.XXXXXX)
export HOME="$TMP"; mkdir -p "$HOME/.claude"
export CLAUDE_BREACH_NO_NOTIFY=1

# tool_response as a string containing a secret -> redacted + additionalContext.
out=$(jq -nc '{tool_name:"Bash",transcript_path:"",tool_response:"aws=AKIAIOSFODNN7EXAMPLE done"}' | "$HOOK")
if [[ "$out" == *'"updatedToolOutput"'* && "$out" != *AKIAIOSFODNN7EXAMPLE* \
    && "$out" == *'REDACTED-SECRET-BREACH'* && "$out" == *'"additionalContext"'* ]]; then
    ok "secret in result redacted + alarm injected"
else
    bad "secret in result not redacted"
fi

# Clean result -> no output (passes through untouched).
out=$(jq -nc '{tool_name:"Read",transcript_path:"",tool_response:"nothing secret here"}' | "$HOOK")
if [[ -z "$out" ]]; then ok "clean result passes through"; else bad "clean result wrongly modified"; fi

rm -rf "$TMP"
echo "-----"; echo "passed: $pass  failed: $fail"; [ "$fail" -eq 0 ]
