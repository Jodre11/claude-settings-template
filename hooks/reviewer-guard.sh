#!/usr/bin/env bash
# reviewer-guard.sh — PreToolUse hook for Bash calls.
# Code-review-suite reviewer agents are read-only by contract: they run analysis tools and read-only git, but never
# mutate the repository. This hook denies a mutating git subcommand (git_sub_mutating in _lib.sh) from any reviewer
# type, wherever git appears in the command: it tokenises the command (shell_words) and runs the git walk from every
# word whose command name is git, so a prefix, wrapper, pipeline stage or path (/usr/bin/git) does not hide it.
# The payload carries agent_type inside a subagent and also in a main session started with --agent, so a reviewer
# run as the main agent is bound too; an ordinary main session has no agent_type and is untouched.
# The hook never allows: the native permission rules, which subagents inherit, decide everything else.
# Hooks run in parallel; deny wins.

set -euo pipefail
source "$(dirname "$0")/_lib.sh"
hook_read_input

cmd=$(hook_field '.tool_input.command')
if [[ -z "$cmd" ]]; then
    exit 0
fi

# agent_type arrives namespaced (e.g. code-review-suite:jbinspect-reviewer); strip any prefix so bare and namespaced
# forms both match.
agent_type=$(hook_field '.agent_type')
reviewer_type="${agent_type##*:}"
case "$reviewer_type" in
    *-reviewer|code-analysis|review-synthesiser) ;;
    *) exit 0 ;;
esac

# From here a crash denies: this agent is a reviewer.
hook_backstop deny "reviewer-guard failed to evaluate a reviewer command; it is denied."
msg="READ-ONLY REVIEWER VIOLATION: \"${reviewer_type}\" is a code-review specialist and MUST NOT mutate"
msg+=" the repository. Blocked mutating git command. Reviewers report findings only — describe the change"
msg+=" in the finding's 'Suggested fix:' field; never apply it. See includes/specialist-context.md"
msg+=" 'READ-ONLY MANDATE'."

# A reviewer never commits, so it has no use for the commit-message heredoc carve-out: a command that
# strip_commit_heredoc would change is denied, whatever git subcommand the walk finds.
checked=$(strip_commit_heredoc "$cmd")
if [[ "$checked" != "$cmd" ]]; then
    hook_deny "$msg"
fi
shell_words "$cmd"
if (( ! SW_OK )); then
    hook_deny "$msg"
fi
GW_ACTIVE=0
# git remote mutates refs or config unless its next word, past -v, is absent, show or get-url.
remote_next=0
for el in ${SW_WORDS[@]+"${SW_WORDS[@]}"}; do
    case "$el" in
        w*) ;;
        '|'|';')
            GW_ACTIVE=0
            remote_next=0
            continue ;;
        *) continue ;;
    esac
    w="${el:1}"
    if (( remote_next )); then
        case "$w" in
            -v|--verbose) ;;
            show|get-url) remote_next=0 ;;
            *) hook_deny "$msg" ;;
        esac
    elif (( GW_ACTIVE )); then
        git_walk_word "$w"
        if (( ! GW_ACTIVE )) && git_sub_mutating "$GW_SUB"; then
            hook_deny "$msg"
        fi
        if (( ! GW_ACTIVE )) && [[ "$GW_SUB" == remote ]]; then
            remote_next=1
        fi
    elif [[ "$w" == git || "$w" == */git ]]; then
        git_walk_start
    fi
done

hook_pass
