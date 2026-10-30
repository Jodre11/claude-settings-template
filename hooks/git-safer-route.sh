#!/usr/bin/env bash
# git-safer-route.sh — PreToolUse hook for Bash calls.
# Denies, with the safer equivalent to run instead, a git command whose native ask rule would otherwise park an
# unattended session on a prompt: a forced branch deletion or move, a hard reset, a forced clean, a force push. Each
# route keeps what its rule protects: git branch -d refuses unmerged work, git reset --keep refuses to drop local
# changes, git clean -n only lists, and a new commit or branch rewrites no remote history. When the route does not
# fit, the agent leaves the change for the user and reports it; the user can still run the original with !.
# Detection reads unquoted words only, so a quoted message or pattern ("reset --hard" in a commit message) is never
# denied. A form it does not recognise, or a command too long to scan, gets no decision, and the native ask rules,
# kept as the backstop, prompt.

set -euo pipefail
source "$(dirname "$0")/_lib.sh"
hook_read_input

cmd=$(hook_field '.tool_input.command')
cmd=$(strip_commit_heredoc "$cmd")
if [[ "$cmd" != *git* ]] || (( ${#cmd} > 16384 )); then
    exit 0
fi

ROUTE_NOTE=" This guard names a safer equivalent instead of prompting, so an unattended run is never parked; if the"
ROUTE_NOTE+=" equivalent does not fit, leave the change undone and list it in your final report for the user."

BRANCH_DELETE="BRANCH DELETE: use 'git branch -d <name>' instead. It deletes a branch whose commits are merged into its"
BRANCH_DELETE+=" upstream (or into HEAD when it has none), so it works for a pushed branch even after a squash merge,"
BRANCH_DELETE+=" and refuses to lose unmerged work. Delete the local branch before its remote branch is removed:"
BRANCH_DELETE+=" once the upstream is gone, -d compares with HEAD and refuses a squash-merged branch. Do not force it."
BRANCH_MOVE="BRANCH FORCE-MOVE: create a new branch at the commit instead ('git branch <new-name> <commit>' or"
BRANCH_MOVE+=" 'git switch -c <new-name> <commit>'). Moving an existing branch with -f can orphan its commits."
HARD_RESET="HARD RESET: use 'git reset --keep <commit>' instead, which refuses to discard uncommitted changes, or save"
HARD_RESET+=" them first with 'git stash push -u'."
FORCED_CLEAN="FORCED CLEAN: list what would be removed with 'git clean -n' without -f (add -d or -x as needed), then"
FORCED_CLEAN+=" remove the files you mean by name."
FORCE_PUSH="FORCE PUSH: push the change as a new commit, or to a new branch name ('git push -u origin"
FORCE_PUSH+=" HEAD:<new-name>'), instead of rewriting a remote branch."

# judge <word>...: deny when the words, which start at a git invocation, are a guarded form.
judge() {
    local -a w=("$@")
    local n=${#w[@]} i=1 sub a
    # Global options; those listed take their value as the next word.
    while (( i < n )); do
        case "${w[i]}" in
            -C|-c|--git-dir|--work-tree|--namespace|--exec-path|--config-env|--attr-source) i=$((i + 2)) ;;
            -*) i=$((i + 1)) ;;
            *) break ;;
        esac
    done
    (( i < n )) || return 0
    sub=${w[i]}
    local del=0 force=0 big_d=0 hard=0 plus=0
    for (( i = i + 1; i < n; i++ )); do
        a=${w[i]}
        case "$a" in
            --delete) del=1 ;;
            --force|--force-with-lease|--force-with-lease=*|--force-if-includes) force=1 ;;
            --hard) hard=1 ;;
            --*) ;;
            -?*)
                [[ "$a" == *D* ]] && big_d=1
                [[ "$a" == *d* ]] && del=1
                [[ "$a" == *f* ]] && force=1
                ;;
            +?*) plus=1 ;;
        esac
    done
    case "$sub" in
        branch)
            if (( big_d || (del && force) )); then
                hook_deny "$BRANCH_DELETE$ROUTE_NOTE"
            elif (( force )); then
                hook_deny "$BRANCH_MOVE$ROUTE_NOTE"
            fi
            ;;
        reset) if (( hard )); then hook_deny "$HARD_RESET$ROUTE_NOTE"; fi ;;
        clean) if (( force )); then hook_deny "$FORCED_CLEAN$ROUTE_NOTE"; fi ;;
        push) if (( force || plus )); then hook_deny "$FORCE_PUSH$ROUTE_NOTE"; fi ;;
    esac
    return 0
}

# judge_stage: judge the words gathered for one command, from its git word onwards, then start the next command.
judge_stage() {
    local k
    for (( k = 0; k < ${#stage[@]}; k++ )); do
        if [[ "${stage[k]}" == git || "${stage[k]}" == */git ]]; then
            judge "${stage[@]:k}"
            break
        fi
    done
    stage=()
}

# One pass splits the command into words and commands as the shell would at its unquoted separators, joining quoted
# spans into their word, so a quoted message is one word that never reads as a subcommand or flag while "git" or
# -"D" still reads as itself. bash-guard.sh denies the separators themselves; each command a separator starts is
# still judged on its own.
stage=()
word=""
quote=""
for (( i = 0; i < ${#cmd}; i++ )); do
    c=${cmd:i:1}
    if [[ -n "$quote" ]]; then
        if [[ "$c" == "$quote" ]]; then
            quote=""
        elif [[ "$quote" == '"' && "$c" == \\ ]]; then
            i=$((i + 1))
            word+=${cmd:i:1}
        else
            word+=$c
        fi
        continue
    fi
    case "$c" in
        \"|\') quote=$c ;;
        \\)
            i=$((i + 1))
            [[ "${cmd:i:1}" == $'\n' ]] || word+=${cmd:i:1}
            ;;
        ' '|$'\t')
            if [[ -n "$word" ]]; then stage+=("$word"); fi
            word=""
            ;;
        '|'|';'|'&'|'('|')'|'`'|$'\n')
            if [[ -n "$word" ]]; then stage+=("$word"); fi
            word=""
            judge_stage
            ;;
        *) word+=$c ;;
    esac
done
if [[ -n "$word" ]]; then stage+=("$word"); fi
judge_stage

exit 0
