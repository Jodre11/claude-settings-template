#!/usr/bin/env bash
set -u
HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/secret-path-guard.sh"
pass=0; fail=0
ok()  { printf 'PASS: %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); }

# verdict <tool> <field-json>  -> DENY|ALLOW
verdict() {
    local out
    out=$(printf '%s' "$2" | jq -c --arg t "$1" '{tool_name:$t} + .' | "$HOOK")
    [[ "$out" == *'"permissionDecision":"deny"'* ]] && echo DENY || echo ALLOW
}

[[ "$(verdict Read '{"tool_input":{"file_path":"dev/secrets-manager/secrets/app.json"}}')" == DENY ]] \
    && ok "Read of secrets/ file denied" || bad "Read of secrets/ file allowed"
[[ "$(verdict Read '{"tool_input":{"file_path":"infra/tls.pem"}}')" == DENY ]] \
    && ok "Read of .pem denied" || bad "Read of .pem allowed"
[[ "$(verdict Grep '{"tool_input":{"path":"prod/secrets-manager/secrets"}}')" == DENY ]] \
    && ok "Grep inside secrets/ denied" || bad "Grep inside secrets/ allowed"
[[ "$(verdict Read '{"tool_input":{"file_path":"README.md"}}')" == ALLOW ]] \
    && ok "Read of README allowed" || bad "Read of README denied"
[[ "$(verdict Read '{"tool_input":{"file_path":"config.env.example"}}')" == ALLOW ]] \
    && ok "Read of .example allowed" || bad "Read of .example denied"

# Escape hatch bypasses the guard.
CLAUDE_ALLOW_SECRET_READ=1
export CLAUDE_ALLOW_SECRET_READ
[[ "$(verdict Read '{"tool_input":{"file_path":"x/secrets/y"}}')" == ALLOW ]] \
    && ok "escape hatch allows read" || bad "escape hatch ignored"
unset CLAUDE_ALLOW_SECRET_READ

echo "-----"; echo "passed: $pass  failed: $fail"; [ "$fail" -eq 0 ]
