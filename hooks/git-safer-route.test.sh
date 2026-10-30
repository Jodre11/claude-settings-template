#!/usr/bin/env bash
# Tests for git-safer-route.sh: a forced branch deletion or move, a hard reset, a forced clean or a force push is
# denied with its safer equivalent; quoted text, the safe forms and unrelated commands get no decision, so the native
# rules decide them.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/git-safer-route.sh"
pass=0; fail=0
ok()  { printf 'PASS: %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); }

# run <command>: the hook's stdout for a Bash payload carrying <command>.
run() {
    jq -nc --arg c "$1" '{hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: $c}}' \
        | "$HOOK" 2>&1
}

# expect <label> <command>...: each command is denied with a reason that starts with <label>.
expect() {
    local label=$1 c out decision reason
    shift
    for c in "$@"; do
        out=$(run "$c")
        decision=$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$out" 2>/dev/null)
        reason=$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$out" 2>/dev/null)
        if [[ "$decision" == deny && "$reason" == "$label:"* && "$reason" == *"list it in your final report"* ]]; then
            ok "$label: $c"
        else
            bad "expected $label for: $c -> $out"
        fi
    done
}

expect "BRANCH DELETE" \
    'git branch -D feat' \
    'git -C /r branch -D feat' \
    'git branch -D a b' \
    'git branch -Dq feat' \
    'git branch --delete --force feat' \
    'git branch -d -f feat' \
    'git branch -df feat' \
    'git branch -d --force feat' \
    'git branch "-D" feat' \
    '"git" branch -D feat' \
    '/usr/bin/git branch -D feat' \
    'git -c core.pager=cat branch -D feat' \
    'cd /r && git branch -D feat' \
    'git fetch;git branch -D feat' \
    'true|git branch -D feat' \
    $'git status\ngit branch -D feat'
expect "BRANCH FORCE-MOVE" \
    'git branch -f main abc123' \
    'git branch --force main HEAD~1'
expect "HARD RESET" \
    'git reset --hard' \
    'git reset --hard origin/main' \
    'git -C /r reset -q --hard HEAD~1'
expect "FORCED CLEAN" \
    'git clean -f' \
    'git clean -fdx' \
    'git clean -d -f' \
    'git clean --force' \
    'git clean -n -f'
expect "FORCE PUSH" \
    'git push --force' \
    'git push -f origin main' \
    'git push origin main --force-with-lease' \
    'git push --force-with-lease=main:abc origin main' \
    'git push --force-if-includes origin main' \
    'git push origin +main' \
    'git push -uf origin feat'

quiet=(
    'git branch -d feat'
    'git branch --delete feat'
    'git branch -m old new'
    'git branch -a'
    'git branch feat abc123'
    'git reset --keep HEAD~1'
    'git reset --soft HEAD~1'
    'git reset HEAD file'
    'git clean -n'
    'git clean -nd'
    'git push'
    'git push -u origin HEAD:feat-2'
    'git push origin main'
    'git commit -m "git reset --hard is gone"'
    "git commit -m 'git branch -D feat'"
    'echo "git push --force"'
    'grep -rn "branch -D" docs'
    'git log --grep=-D'
    'git log --oneline -- clean'
    'ls -la'
    ''
)
for c in "${quiet[@]}"; do
    out=$(run "$c")
    if [[ -z "$out" ]]; then ok "no decision: ${c:-<empty>}"; else bad "decided for ${c:-<empty>}: $out"; fi
done

heredoc=$'git commit -m "$(cat <<\'EOF\'\ndocs: say why git branch -D and git push --force prompt\nEOF\n)"'
out=$(run "$heredoc")
if [[ -z "$out" ]]; then ok "a commit-message heredoc that mentions the forms is not judged"; else bad "heredoc: $out"; fi

out=$(run 'git branch -D feat')
got=$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$out" 2>/dev/null)
if [[ "$got" == *"use 'git branch -d <name>' instead"* && "$got" == *"Do not force it."* ]]; then
    ok "the branch-delete reason names git branch -d"
else
    bad "the branch-delete reason lost its route: $out"
fi
out=$(run 'git reset --hard')
got=$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$out" 2>/dev/null)
if [[ "$got" == *"git reset --keep <commit>"* && "$got" == *"git stash push -u"* ]]; then
    ok "the hard-reset reason names reset --keep and stash"
else
    bad "the hard-reset reason lost its route: $out"
fi

out=$(printf '{"tool_input":{}}' | "$HOOK" 2>&1)
if [[ -z "$out" ]]; then ok "a payload with no command is ignored"; else bad "no-command payload decided: $out"; fi

TMPL="$DIR/../settings.json.tmpl"
if jq -e '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[]
        | select(.command == "~/.claude/hooks/git-safer-route.sh")' "$TMPL" >/dev/null 2>&1; then
    ok "settings.json.tmpl registers git-safer-route.sh on Bash"
else
    bad "settings.json.tmpl does not register git-safer-route.sh on Bash"
fi
for rule in 'Bash(git *branch -D*)' 'Bash(git *reset *--hard*)' 'Bash(git *clean -*f*)' 'Bash(git *push *--force*)'; do
    if jq -e --arg r "$rule" '.permissions.ask | index($r)' "$TMPL" >/dev/null 2>&1; then
        ok "the native ask rule stays as the backstop: $rule"
    else
        bad "the native ask rule is gone: $rule"
    fi
done

echo "-----"; echo "passed: $pass  failed: $fail"; [ "$fail" -eq 0 ]
