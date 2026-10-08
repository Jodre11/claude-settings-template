#!/usr/bin/env bash
set -u
HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/secret-path-guard.sh"
pass=0; fail=0
ok()  { printf 'PASS: %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); }

PG_CWD=$(mktemp -d)
# verdict <tool> <field-json>  -> DENY|ASK|ALLOW; PG_CWD is the payload's cwd
verdict() {
    local out
    out=$(printf '%s' "$2" | jq -c --arg t "$1" --arg d "$PG_CWD" '{tool_name:$t, cwd:$d} + .' | "$HOOK")
    if [[ "$out" == *'"permissionDecision":"deny"'* ]]; then echo DENY
    elif [[ "$out" == *'"permissionDecision":"ask"'* ]]; then echo ASK
    else echo ALLOW; fi
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

# SSH keys by any name and the credential files of registries, clusters and package managers; the ssh client's own
# files stay readable.
for p in a/.ssh/id_ecdsa a/.ssh/work_ed25519 a/.docker/config.json a/.kube/config a/.npmrc a/.git-credentials; do
    [[ "$(verdict Read "{\"tool_input\":{\"file_path\":\"$p\"}}")" == DENY ]] \
        && ok "Read of $p denied" || bad "Read of $p allowed"
done
for p in a/.ssh/config a/.ssh/known_hosts a/.ssh/id_ed25519.pub; do
    [[ "$(verdict Read "{\"tool_input\":{\"file_path\":\"$p\"}}")" == ALLOW ]] \
        && ok "Read of $p allowed" || bad "Read of $p denied"
done

# A crash the ERR trap misses (bash 3.2 unbound variables, a crash inside a function) still asks: the hook installs
# the EXIT-trap backstop. A malformed payload asks too.
grep -q '^hook_backstop ask ' "$HOOK" && ok "the path guard installs the crash backstop" \
    || bad "the path guard has no crash backstop"
crash=$(printf '%s' '{not json' | "$HOOK" 2>/dev/null)
[[ "$crash" == *'"permissionDecision":"ask"'* ]] && ok "a malformed payload asks" || bad "a malformed payload: $crash"

# A content-mode Grep prints the matching lines of every file it searches, so its directory is listed and a secret file
# there denies it; files_with_matches (the default) and count print names or counts only. Fixtures are empty files
# with secret names.
pg=$(mktemp -d)
mkdir -p "$pg/plain/src" "$pg/repo/src"
: >"$pg/plain/.env"
: >"$pg/plain/src/a.py"
mkdir -p "$pg/nested/inner"
git -C "$pg/nested" init -q
git -C "$pg/nested/inner" init -q
: >"$pg/nested/inner/.env"
mkdir -p "$pg/deep/src"
: >"$pg/deep/src/a.env"
mkdir -p "$pg/anchor/src/a"
: >"$pg/anchor/src/a/b.env"
git -C "$pg/repo" init -q
printf '.env\n' >"$pg/repo/.gitignore"
: >"$pg/repo/.env"
: >"$pg/repo/src/a.py"
gv() {  # gv <path or ''> <output_mode or ''> [glob]: the verdict on a Grep
    verdict Grep "$(jq -nc --arg p "$1" --arg m "$2" --arg g "${3:-}" '{tool_input: ({pattern: "KEY"}
        + (if $p != "" then {path: $p} else {} end) + (if $m != "" then {output_mode: $m} else {} end)
        + (if $g != "" then {glob: $g} else {} end))}')"
}
expect_g() {  # expect_g <verdict> <description> <gv args...>
    local got
    got=$(gv "${@:3}")
    if [[ "$got" == "$1" ]]; then ok "$2"; else bad "$2 (want $1 got $got)"; fi
}
expect_g ALLOW "a default-mode Grep of a root holding .env allowed"           "$pg/plain" ''
expect_g ALLOW "a files_with_matches Grep of a root holding .env allowed"     "$pg/plain" files_with_matches
expect_g ALLOW "a count Grep of a root holding .env allowed"                  "$pg/plain" count
expect_g DENY  "a content Grep of a root holding .env denied"                 "$pg/plain" content
expect_g ALLOW "a content Grep of a subdirectory without secrets allowed"     "$pg/plain/src" content
expect_g ALLOW "a content Grep of a repo whose .env is gitignored allowed"    "$pg/repo" content
expect_g DENY  "a content Grep of a repo holding a nested repo's .env denied" "$pg/nested" content
expect_g ALLOW "a content Grep narrowed by glob *.py allowed"                 "$pg/plain" content '*.py'
expect_g ALLOW "a content Grep excluding .env by glob allowed"                "$pg/plain" content '!.env'
expect_g DENY  "a content Grep whose glob holds a brace denied (no brace support)" "$pg/plain" content '*.{py,env}'
expect_g DENY  "a content Grep whose glob holds a comma denied (rg may split it)" "$pg/plain" content '*.py,.env'
expect_g DENY  "a content Grep whose glob holds a space denied (rg may split it)" "$pg/plain" content '*.py .env'
expect_g DENY  "a content Grep whose include glob is anchored with / denied (rg anchors it, bash cannot)" \
    "$pg/plain" content '/.env'
expect_g DENY  "a content Grep whose exclude glob holds a / denied (bash * crosses it, rg's does not)" \
    "$pg/anchor" content '!src/*.env'
expect_g DENY  "a content Grep whose glob holds a newline denied (rg may split it)" "$pg/plain" content $'*.py\n.env'
expect_g DENY  "a content Grep whose glob holds a CR denied (rg may split it)" "$pg/plain" content $'*.py\r.env'
expect_g DENY  "a content Grep whose glob holds a no-break space denied" "$pg/plain" content $'*.py\xc2\xa0.env'
expect_g DENY  "a content Grep whose include glob holds a / denied (rg's ** matches zero directories)" \
    "$pg/deep" content 'src/**/*.env'
expect_g DENY  "a content Grep whose glob holds a | denied (extglob differs)" "$pg/plain" content '*.py|.env'
expect_g DENY  "a content Grep whose glob is an extglob denied" "$pg/plain" content '@(*.py|.env)'
expect_g DENY  "a content Grep of / denied"                                  / content
expect_g DENY  "a content Grep of /tmp denied (the vault is below)"           /tmp content
expect_g DENY  "a content Grep of \$HOME denied"                              "$HOME" content
expect_g DENY  "a content Grep of ~ denied"                                   '~' content
pg_cwd0="$PG_CWD"
PG_CWD="$pg/plain"
expect_g DENY  "a content Grep with no path, from a root holding .env, denied" '' content
PG_CWD="$pg/repo"
expect_g ALLOW "a content Grep with no path, from a clean repo, allowed"      '' content
PG_CWD="$HOME"
expect_g DENY  "a content Grep with no path, from \$HOME, denied at once"     '' content
PG_CWD="$pg_cwd0"
want="SECRET-PROBE BLOCK: a content-mode Grep of '$pg/plain' prints the contents of secret-bearing files there"
got=$(jq -nc --arg p "$pg/plain" --arg d "$PG_CWD" \
        '{tool_name: "Grep", cwd: $d, tool_input: {path: $p, output_mode: "content"}}' \
    | "$HOOK" | jq -r '.hookSpecificOutput.permissionDecisionReason')
[[ "$got" == "$want"*"$pg/plain/.env"*files_with_matches* ]] && ok "the Grep probe deny names the file and the way out" \
    || bad "the Grep probe deny drifted: $got"
rm -rf "$pg"

# Escape hatch bypasses the guard.
CLAUDE_ALLOW_SECRET_READ=1
export CLAUDE_ALLOW_SECRET_READ
[[ "$(verdict Read '{"tool_input":{"file_path":"x/secrets/y"}}')" == ALLOW ]] \
    && ok "escape hatch allows read" || bad "escape hatch ignored"
unset CLAUDE_ALLOW_SECRET_READ

rm -rf "$PG_CWD"
echo "-----"; echo "passed: $pass  failed: $fail"; [ "$fail" -eq 0 ]
