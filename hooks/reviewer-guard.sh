#!/usr/bin/env bash
# reviewer-guard.sh — PreToolUse hook for Bash calls.
# Code-review-suite reviewer agents are read-only by contract: they run analysis tools and read-only git, but never
# mutate the repository. This hook denies a mutating git command (is_mutating_git in _lib.sh) from any reviewer type.
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
    *-reviewer|code-analysis|review-synthesiser)
        if is_mutating_git "$cmd"; then
            msg="READ-ONLY REVIEWER VIOLATION: \"${reviewer_type}\" is a code-review specialist and MUST NOT mutate"
            msg+=" the repository. Blocked mutating git command. Reviewers report findings only — describe the change"
            msg+=" in the finding's 'Suggested fix:' field; never apply it. See includes/specialist-context.md"
            msg+=" 'READ-ONLY MANDATE'."
            hook_deny "$msg"
        fi
        ;;
esac

exit 0
