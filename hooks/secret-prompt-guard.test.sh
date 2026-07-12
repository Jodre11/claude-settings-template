#!/usr/bin/env bash
set -u
HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/secret-prompt-guard.sh"
pass=0; fail=0
ok()  { printf 'PASS: %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); }
run() {
    local out
    out=$(jq -nc --arg p "$1" '{prompt:$p}' | "$HOOK")
    [[ "$out" == *'"decision":"block"'* ]] && echo BLOCK || echo PASS
}

[[ "$(run 'my key is AKIAIOSFODNN7EXAMPLE please use it')" == BLOCK ]] \
    && ok "prompt with AWS key blocked" || bad "prompt with AWS key passed"
[[ "$(run 'please refactor the auth module')" == PASS ]] \
    && ok "clean prompt passed" || bad "clean prompt blocked"

echo "-----"; echo "passed: $pass  failed: $fail"; [ "$fail" -eq 0 ]
