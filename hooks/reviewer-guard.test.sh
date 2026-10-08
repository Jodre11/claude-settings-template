#!/usr/bin/env bash
# Tests for reviewer-guard.sh: reviewer agent types are denied mutating git (deny message pinned), everything else
# gets no decision, and the hook never allows anything (the first-word allow probes). Payloads use the documented
# PreToolUse shape; agent_id marks a subagent call and agent_type names its type.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/reviewer-guard.sh"
pass=0; fail=0
ok()  { printf 'PASS: %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); }

# run <cmd> <agent_id> <agent_type>: the hook's stdout. Empty fields are omitted from the payload.
run() {
    jq -nc --arg c "$1" --arg i "$2" --arg a "$3" \
        '{hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: $c}}
            + (if $i != "" then {agent_id: $i} else {} end)
            + (if $a != "" then {agent_type: $a} else {} end)' | "$HOOK" 2>&1
}
# decision <hook-stdout>: deny / allow / ask, or none for empty or non-JSON output.
decision() {
    local d
    d=$(jq -r '.hookSpecificOutput.permissionDecision // "none"' <<<"$1" 2>/dev/null) || d=none
    printf '%s' "${d:-none}"
}
# expect <decision> <description> <cmd> [agent_type] [agent_id]
expect() {
    local got
    got=$(decision "$(run "$3" "${5-agent-test-1}" "${4-}")")
    if [[ "$got" == "$1" ]]; then ok "$2"; else bad "$2 (want $1 got $got)"; fi
}

REVIEWER=code-review-suite:correctness-reviewer

want="READ-ONLY REVIEWER VIOLATION: \"correctness-reviewer\" is a code-review specialist and MUST NOT mutate the"
want+=" repository. Blocked mutating git command. Reviewers report findings only — describe the change in the"
want+=" finding's 'Suggested fix:' field; never apply it. See includes/specialist-context.md 'READ-ONLY MANDATE'."
out=$(run 'git commit -m x' agent-test-1 "$REVIEWER")
if [[ "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$out" 2>/dev/null)" == "$want" ]]; then
    ok "the reviewer deny reason is pinned"
else
    bad "reviewer deny reason drifted: $out"
fi

expect deny "a namespaced reviewer is denied git commit"       'git commit -m x'         "$REVIEWER"
expect deny "a bare reviewer type is denied git commit"        'git commit -m x'         correctness-reviewer
expect deny "code-analysis is denied git push"                 'git -C /repo push'       code-analysis
expect deny "review-synthesiser is denied git reset"           'git reset --hard HEAD'   review-synthesiser
expect deny "a reviewer run as the main agent is bound too"    'git commit -m x'         "$REVIEWER" ''
expect deny "a reviewer is denied inside a pipeline"           'git commit -m x | cat'   "$REVIEWER"
expect deny "git worktree add is denied"                'git worktree add ../wt'  "$REVIEWER"
expect deny "even git worktree list is denied"          'git worktree list'       "$REVIEWER"
expect deny "git notes add is denied"                   'git notes add -m x'      "$REVIEWER"
expect deny "git submodule update is denied"            'git submodule update'    "$REVIEWER"
expect deny "git sparse-checkout set is denied"         'git sparse-checkout set src' "$REVIEWER"
expect deny "git lfs pull is denied"                    'git lfs pull'            "$REVIEWER"
expect deny "git replace is denied"                     'git replace HEAD HEAD~1' "$REVIEWER"

hidden=('true | git commit -m x' 'command git commit -m x' 'env git commit -m x' '/usr/bin/git commit -m x'
    'GIT_DIR=.git git commit -m x' 'git status | xargs git add' 'sudo git -C /repo push' '\git commit -m x')
for c in "${hidden[@]}"; do
    expect deny "a reviewer is denied a hidden mutating git: $c"  "$c"                     "$REVIEWER"
    expect none "a non-reviewer is untouched by: $c"              "$c"                     general-purpose
done
# A reviewer's commit is denied at the commit word, before any heredoc text, whatever quotes the message holds.
expect deny "a reviewer's commit heredoc with an odd quote is denied" \
    $'git commit -m "$(cat <<\'EOF\'\nSupport 3.5" drives\nEOF\n)"' "$REVIEWER"
expect none "a non-reviewer's commit heredoc with an odd quote is untouched" \
    $'git commit -m "$(cat <<\'EOF\'\nSupport 3.5" drives\nEOF\n)"' general-purpose
# A reviewer never needs the commit carve-out: a command strip_commit_heredoc would change is denied, whatever git
# subcommand the walk finds.
expect deny "a reviewer is denied a command the commit heredoc strip would change" \
    $'git log --grep commit -m "$(cat <<\'EOF\'\nmsg\nEOF\n)"' "$REVIEWER"
expect deny "a | ends the walk of an earlier bare git"         'git --no-pager | git commit -m x' "$REVIEWER"
expect deny "a ; ends the walk of an earlier bare git"         'git --no-pager ; git commit -m x' "$REVIEWER"
expect none "a reviewer may run git -C dir diff"               'git -C /repo diff HEAD~1' "$REVIEWER"
expect none "a reviewer may echo the word git"                 'echo git'                "$REVIEWER"
expect none "a reviewer may pipe git log into grep"            'git log --oneline | grep fix' "$REVIEWER"
expect none "a reviewer may name a mutating word as git data"  'git log --grep=commit -- add.sh' "$REVIEWER"
expect deny "a reviewer is denied git --config-env then commit" 'git --config-env x.y=HOME commit -m x' "$REVIEWER"
expect none "a non-reviewer is untouched by git --config-env"  'git --config-env x.y=HOME commit -m x' general-purpose
expect deny "a reviewer's untokenisable command is denied"     $'git status\x1e'         "$REVIEWER"
expect none "a non-reviewer's untokenisable command is untouched" $'git status\x1e'      general-purpose

expect none "a reviewer may run git status"                    'git status'              "$REVIEWER"
expect none "a reviewer may run git diff"                      'git diff main...HEAD'    "$REVIEWER"
expect none "a reviewer may run git log"                       'git log --oneline -5'    "$REVIEWER"
expect none "a reviewer may run git branch --show-current"     'git branch --show-current' "$REVIEWER"
expect none "a reviewer may run a non-git tool"                'jq --version'            "$REVIEWER"
expect none "a general-purpose subagent is not a reviewer"     'git commit -m x'         general-purpose
expect none "an ordinary main session is untouched"            'git commit -m x'         '' ''
expect none "a payload with no command is ignored"             ''                        "$REVIEWER"
# init, clone, bisect, read-tree, checkout-index, maintenance and bundle write the repository or its working tree, and
# reflog counts in every form; stage is add; remote mutates except in its read forms (no argument, -v, show, get-url).
for c in 'git init x' 'git clone https://example.invalid/r.git' 'git bisect start' 'git read-tree -u HEAD' \
        'git checkout-index -a -f' 'git maintenance run' 'git bundle create x.bundle HEAD' 'git reflog' \
        'git reflog expire --all' 'git stage x' 'git remote update' 'git remote prune origin' \
        'git remote add x y' 'git remote set-url origin z' 'git remote -v update' 'git remote | git remote rm x'; do
    expect deny "a reviewer is denied $c"                               "$c"                     "$REVIEWER"
done
for c in 'git remote' 'git remote -v' 'git remote --verbose' 'git remote show origin' 'git remote get-url origin' \
        'git remote -v | grep origin' 'git remote show origin | git log -1'; do
    expect none "a reviewer may run $c"                                 "$c"                     "$REVIEWER"
done

# The old allow half auto-approved these by first word. This hook must never allow anything, for any caller.
probes=('command rm -rf /tmp/claude-x /home/me' 'npx -y cowsay hi' "python3 -c 'print(1)'" 'find . -name x -delete'
    'curl https://example.invalid' 'rm -rf /tmp/claude-x /home/me' 'git status' 'jq --version' 'mkdir -p /tmp/claude-x')
allowed=""
for c in "${probes[@]}"; do
    for caller in "general-purpose|agent-test-1" "|" "$REVIEWER|agent-test-1"; do
        if [[ "$(decision "$(run "$c" "${caller#*|}" "${caller%%|*}")")" == allow ]]; then
            allowed+=" [$c as ${caller%%|*}]"
        fi
    done
done
if [[ -z "$allowed" ]]; then ok "no probe is ever allowed"; else bad "allowed:$allowed"; fi

TMPL="$DIR/../settings.json.tmpl"
if jq -e '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[]
        | select(.command == "~/.claude/hooks/reviewer-guard.sh")' "$TMPL" >/dev/null 2>&1; then
    ok "settings.json.tmpl registers reviewer-guard.sh on Bash"
else
    bad "settings.json.tmpl does not register reviewer-guard.sh on Bash"
fi
if jq -e '[.hooks[][] | .hooks[] | .command] | index("~/.claude/hooks/allow-permissions.sh") == null' "$TMPL" \
        >/dev/null 2>&1; then
    ok "settings.json.tmpl no longer registers allow-permissions.sh"
else
    bad "settings.json.tmpl still registers allow-permissions.sh"
fi

echo "-----"; echo "passed: $pass  failed: $fail"; [ "$fail" -eq 0 ]
