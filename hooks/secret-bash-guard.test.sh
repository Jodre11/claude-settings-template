#!/usr/bin/env bash
set -u
HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/secret-bash-guard.sh"
pass=0; fail=0
ok()  { printf 'PASS: %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); }
run() {
    local out
    out=$(jq -nc --arg c "$1" '{tool_input:{command:$c}}' | "$HOOK")
    [[ "$out" == *'"permissionDecision":"deny"'* ]] && echo DENY || echo ALLOW
}

# Readers of secret paths -> DENY
[[ "$(run 'cat dev/secrets-manager/secrets/app.json')" == DENY ]] && ok "cat secrets file denied" || bad "cat secrets file allowed"
[[ "$(run 'xxd infra/tls.pem')" == DENY ]] && ok "xxd .pem denied" || bad "xxd .pem allowed"
[[ "$(run 'head .env')" == DENY ]] && ok "head .env denied" || bad "head .env allowed"

# Benign reader -> ALLOW
[[ "$(run 'cat README.md')" == ALLOW ]] && ok "cat README allowed" || bad "cat README denied"

# env / printenv
[[ "$(run 'env')" == DENY ]] && ok "bare env denied" || bad "bare env allowed"
[[ "$(run 'env AWS_PROFILE=x dotnet run')" == ALLOW ]] && ok "env prefix form allowed" || bad "env prefix form denied"
[[ "$(run 'printenv')" == DENY ]] && ok "bare printenv denied" || bad "bare printenv allowed"
[[ "$(run 'printenv AWS_SECRET_ACCESS_KEY')" == DENY ]] && ok "printenv secret var denied" || bad "printenv secret var allowed"
[[ "$(run 'printenv HOME')" == ALLOW ]] && ok "printenv HOME allowed" || bad "printenv HOME denied"

# echo/printf of secret-named var
[[ "$(run 'echo $AWS_SECRET_ACCESS_KEY')" == DENY ]] && ok "echo secret var denied" || bad "echo secret var allowed"
[[ "$(run 'echo hello world')" == ALLOW ]] && ok "echo plain text allowed" || bad "echo plain text denied"

# secret-fetch: bare stdout DENY, redirect to /tmp/claude-* ALLOW
[[ "$(run 'aws secretsmanager get-secret-value --secret-id foo')" == DENY ]] && ok "secret-fetch bare denied" || bad "secret-fetch bare allowed"
[[ "$(run 'aws secretsmanager get-secret-value --secret-id foo > /tmp/claude-abc/s.json')" == ALLOW ]] && ok "secret-fetch redirected allowed" || bad "secret-fetch redirected denied"
[[ "$(run 'aws ecr get-login-password --region eu-west-1')" == DENY ]] && ok "ecr login bare denied" || bad "ecr login bare allowed"

echo "-----"; echo "passed: $pass  failed: $fail"; [ "$fail" -eq 0 ]
