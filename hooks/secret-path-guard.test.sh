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

# A bare */X name, a vault file and a process environment are secret paths for Read and Grep too.
for p in config.env .netrc id_rsa /tmp/claude-abc-vault/secrets/gh /proc/self/environ; do
    [[ "$(verdict Read "{\"tool_input\":{\"file_path\":\"$p\"}}")" == DENY ]] \
        && ok "Read of $p denied" || bad "Read of $p allowed"
done
[[ "$(verdict Grep '{"tool_input":{"path":"/tmp/claude-abc-vault/secrets"}}')" == DENY ]] \
    && ok "Grep of the vault denied" || bad "Grep of the vault allowed"
[[ "$(verdict Grep '{"tool_input":{"path":"/tmp/claude-abc-vault"}}')" == DENY ]] \
    && ok "Grep of the vault root denied" || bad "Grep of the vault root allowed"
for p in /tmp/claude-abc-vault/ /tmp/claude-abc-vault/. /private/tmp/claude-abc-vault //tmp/claude-abc-vault; do
    [[ "$(verdict Grep "{\"tool_input\":{\"path\":\"$p\"}}")" == DENY ]] \
        && ok "Grep of the vault root as $p denied" || bad "Grep of the vault root as $p allowed"
done

# A case-insensitive file system (macOS, Windows) opens .ENV as .env: names compare case-insensitively.
for p in .ENV Secrets/app.json a/.ssh/ID_RSA infra/TLS.PEM $'creds.\xc5\xbfecret' $'a/.ssh/id_r\xc5\xbfa' \
        $'tls.\xe2\x84\xaaey'; do
    [[ "$(verdict Read "{\"tool_input\":{\"file_path\":\"$p\"}}")" == DENY ]] \
        && ok "Read of $p denied" || bad "Read of $p allowed"
done

# Escape hatch bypasses the guard.
CLAUDE_ALLOW_SECRET_READ=1
export CLAUDE_ALLOW_SECRET_READ
[[ "$(verdict Read '{"tool_input":{"file_path":"x/secrets/y"}}')" == ALLOW ]] \
    && ok "escape hatch allows read" || bad "escape hatch ignored"
unset CLAUDE_ALLOW_SECRET_READ

echo "-----"; echo "passed: $pass  failed: $fail"; [ "$fail" -eq 0 ]
