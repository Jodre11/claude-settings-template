#!/usr/bin/env bash
# Tests for git-signing-ask.sh: a command that overrides or removes git signing, or passes --no-gpg-sign, is denied
# with guidance, in any key spelling; reads of the signing setting, plain commits, -S and unrelated commands get no
# decision, so the native rules decide them.
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

denies=(
    'git commit --no-gpg-sign -m m'
    'git -C x commit --no-gpg-sign -m m'
    'git merge --no-gpg-sign topic'
    'git rebase --no-gpg-sign main'
    'git -C /r cherry-pick --no-gpg-sign abc123'
    'git --no-gpg-sign commit -m m'
    'cd /r && git commit -m m --no-gpg-sign'
    'git commit --no-gpg-sign;echo hi'
    'git commit --no-gpg-sign&&echo hi'
    '(git commit --no-gpg-sign)'
    'true|git commit --no-gpg-sign'
    'echo m |git commit -F - --no-gpg-sign'
    'true;git commit --no-gpg-sign'
    'true&&git commit --no-gpg-sign'
    'true&git commit --no-gpg-sign'
    '`git commit --no-gpg-sign`'
    'echo `git commit --no-gpg-sign`'
    'git commit "--no-gpg-sign"'
    "git commit '--no-gpg-sign'"
    '"git" commit --no-gpg-sign'
    "'git' commit --no-gpg-sign"
    'git commit --no-gpg-sig -m m'
    'git commit --no-gpg-si -m m'
    'git commit --no-gpg-s -m m'
    'git commit --no-gpg- -m m'
    'git commit --no-gpg -m m'
    'git commit --no-gp -m m'
    'git commit --no-g -m m'
    'git commit --no-"gpg"-sign -m m'
    "git commit --no-'gpg-sign' -m m"
    'git commit --no-gpg\-sign -m m'
    'g"it" commit --no-gpg-sign -m m'
    'gi\t commit --no-gpg-sign -m m'
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
for c in "${denies[@]}"; do
    out=$(run "$c")
    if [[ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$out" 2>/dev/null)" == deny ]]; then
        ok "denies: $c"
    else
        bad "did not deny: $c -> $out"
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
    'git commit -S -m m'
    'git commit --gpg-sign -m m'
    'git log --show-signature'
    'git commit --NO-GPG-SIGN -m m'
    'echo --no-gpg-sign'
    'git commit --no-gpgx -m m'
    'git commit --no-gpg-signature -m m'
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

reason="SIGNING BLOCK: this command overrides or removes git commit signing (gpgsign). Signing works automatically"
reason+=" here, throwaway repos included: drop the override and run the command again."
for c in 'git -c commit.gpgsign=false commit -m x' 'git commit --no-gpg-sign -m m'; do
    out=$(run "$c")
    if [[ "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$out" 2>/dev/null)" == "$reason" ]]; then
        ok "the deny reason says signing works automatically: $c"
    else
        bad "deny reason drifted for $c: $out"
    fi
done
out=$(run 'git -c commit.gpgsign=false commit -m x')
got=$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$out" 2>/dev/null)
if [[ "$got" == *"Signing works automatically"* ]]; then
    ok "the deny reason contains the guidance sentence"
else
    bad "the deny reason lost the guidance sentence: $out"
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
