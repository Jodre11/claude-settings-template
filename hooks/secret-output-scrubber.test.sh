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

# Finding B: a Read whose target is a firewall self-definition file is scan-exempt
# even though its result embeds a vector -> no alarm, no output (pass-through).
out=$(jq -nc '{tool_name:"Read",transcript_path:"",tool_input:{file_path:"x/hooks/secret-patterns.sh"},tool_response:"line AKIAIOSFODNN7EXAMPLE end"}' | "$HOOK")
if [[ -z "$out" ]]; then ok "scan-exempt path not alarmed"; else bad "scan-exempt path wrongly scanned"; fi

# Finding B negative: same vector in an ORDINARY file's result is still scanned.
out=$(jq -nc '{tool_name:"Read",transcript_path:"",tool_input:{file_path:"src/config.js"},tool_response:"key AKIAIOSFODNN7EXAMPLE end"}' | "$HOOK")
if [[ "$out" == *'"additionalContext"'* ]]; then ok "ordinary file still scanned"; else bad "ordinary file wrongly exempted"; fi

rm -rf "$TMP"
echo "-----"; echo "passed: $pass  failed: $fail"; [ "$fail" -eq 0 ]
