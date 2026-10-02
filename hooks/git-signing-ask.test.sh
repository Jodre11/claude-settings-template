#!/usr/bin/env bash
# Tests for git-signing-ask.sh: a command that overrides or removes git signing asks, in any key spelling; reads of
# the signing setting, plain commits and unrelated commands get no decision, so the native rules decide them.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/git-signing-ask.sh"
pass=0; fail=0
ok()  { printf 'PASS: %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); }

# run <command>: the hook's stdout for a Bash payload carrying <command>.
run() {
    jq -nc --arg c "$1" '{hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: $c}}' \
        | "$HOOK" 2>&1
}

asks=(
    'git -c commit.gpgsign=false commit -m x'
    'git -C /r -c commit.gpgsign=false commit -q -m x'
    'git -c commit.GPGSIGN=false commit -m x'
    'git -c "commit.gpgsign=false" commit -m x'
    'git -c tag.gpgSign=0 tag -a v1 -m v1'
    'git -c rebase.gpgSign=false rebase main'
    'git --config-env=commit.gpgsign=NOSIGN commit -m x'
    'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false git commit -m x'
    'env GIT_CONFIG_PARAMETERS=commit.gpgsign=false git commit -m x'
    'git config commit.gpgsign false'
    'git config --global commit.gpgsign false'
    'git -C /r config commit.gpgSign false'
    'git config --local Commit.GpgSign 0'
    'git config --bool commit.gpgsign "false"'
    'git config set commit.gpgsign false'
    'git config --unset commit.gpgsign'
    'git config --unset-all tag.gpgsign'
    'git config unset --global commit.gpgsign'
    '/usr/bin/git config commit.gpgsign no'
    'git config --list | grep gpgsign | git config commit.gpgsign false'
)
for c in "${asks[@]}"; do
    out=$(run "$c")
    if [[ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$out" 2>/dev/null)" == ask ]]; then
        ok "asks: $c"
    else
        bad "did not ask: $c -> $out"
    fi
done

quiet=(
    'git config --get commit.gpgsign'
    'git -C /r config --get rebase.gpgSign'
    'git config --get commit.gpgsign 2>&1'
    "git -C /r config --get-regexp 'commit.gpgsign|gpg.format|user.signingkey|gpg.ssh'"
    'git config commit.gpgsign'
    'git config commit.gpgsign 2>/dev/null'
    'git config get commit.gpgsign'
    'git config --show-origin --get commit.gpgsign'
    'git config --list | grep -i gpgsign'
    'git config -l | grep gpgsign'
    'git log --oneline -S gpgsign'
    'grep -rn gpgsign settings.json.tmpl'
    'git commit -m x'
    'git -C /r commit -S -m x'
    'git config --get commit.gpgSign | cat'
    'ls -la'
    ''
)
for c in "${quiet[@]}"; do
    out=$(run "$c")
    if [[ -z "$out" ]]; then ok "no decision: ${c:-<empty>}"; else bad "decided for ${c:-<empty>}: $out"; fi
done

heredoc=$'git commit -m "$(cat <<\'EOF\'\ndocs: explain why -c commit.gpgsign=false prompts\nEOF\n)"'
out=$(run "$heredoc")
if [[ -z "$out" ]]; then ok "a commit-message heredoc that mentions gpgsign= is not judged"; else bad "heredoc: $out"; fi

reason="This command overrides or removes git signing (gpgsign). Commits must stay signed: approve only for a"
reason+=" throwaway repo, and fix the signing setup rather than bypass it."
out=$(run 'git -c commit.gpgsign=false commit -m x')
if [[ "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$out" 2>/dev/null)" == "$reason" ]]; then
    ok "the ask reason names the signing bypass"
else
    bad "ask reason drifted: $out"
fi

out=$(printf '{"tool_input":{}}' | "$HOOK" 2>&1)
if [[ -z "$out" ]]; then ok "a payload with no command is ignored"; else bad "no-command payload decided: $out"; fi

TMPL="$DIR/../settings.json.tmpl"
if jq -e '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[]
        | select(.command == "~/.claude/hooks/git-signing-ask.sh")' "$TMPL" >/dev/null 2>&1; then
    ok "settings.json.tmpl registers git-signing-ask.sh on Bash"
else
    bad "settings.json.tmpl does not register git-signing-ask.sh on Bash"
fi

echo "-----"; echo "passed: $pass  failed: $fail"; [ "$fail" -eq 0 ]
