#!/usr/bin/env bash
# allow-permissions.sh — PreToolUse hook for Bash calls
# Mirrors the permissions.allow Bash patterns from ~/.claude/settings.json as a hook,
# so that subagents (which inherit hooks but not permission patterns) get the same
# auto-allow behaviour as the main conversation.
#
# Workaround for: https://github.com/anthropics/claude-code/issues/18950
#
# If the command matches, emits permissionDecision: "allow".
# If not, exits silently (falls through to subsequent hooks like bash-guard.sh).

set -euo pipefail
source "$(dirname "$0")/_lib.sh"
hook_read_input

cmd=$(hook_field '.tool_input.command')
if [[ -z "$cmd" ]]; then
    exit 0
fi

# ── Read-only reviewer guard ──
# Code-review-suite reviewer subagents are READ-ONLY by contract: they run
# analysis tools and read-only git, but must never mutate the repo. Issue
# anthropics/claude-code#18950 means subagents do NOT inherit settings.json
# permissions.deny, so this guard is the only enforcement point. The PreToolUse
# payload carries `agent_type` only for subagents (absent for the main session),
# so this denial is scoped to reviewers and never touches the main conversation.
# agent_type arrives namespaced (e.g. code-review-suite:jbinspect-reviewer); strip
# any prefix before matching so bare and namespaced forms both hit.
agent_type=$(hook_field '.agent_type')
reviewer_type="${agent_type##*:}"
case "$reviewer_type" in
    *-reviewer|code-analysis|review-synthesiser)
        if is_mutating_git "$cmd"; then
            hook_deny "READ-ONLY REVIEWER VIOLATION: \"${reviewer_type}\" is a code-review specialist and MUST NOT mutate the repository. Blocked mutating git command. Reviewers report findings only — describe the change in the finding's 'Suggested fix:' field; never apply it. See includes/specialist-context.md 'READ-ONLY MANDATE'."
        fi
        ;;
esac

# Extract the base command (first word)
read -r base _ <<< "$cmd"

REASON="Allowed by allow-permissions hook (mirrors settings.json permissions.allow)"

# Path-prefix matches (must run before the basename case below — these
# invocations look like absolute paths to the hook, not bare command names).
if [[ "$base" == */node_modules/.bin/eslint || "$base" == */node_modules/.bin/biome ]]; then
    hook_allow "$REASON"
fi

case "$base" in
    # Version control and GitHub CLI
    git|gh)         hook_allow "$REASON" ;;

    # Build tools
    dotnet|terraform|cargo) hook_allow "$REASON" ;;

    # Browser automation
    playwright-cli|npx) hook_allow "$REASON" ;;

    # Code inspection
    jb)             hook_allow "$REASON" ;;

    # Static-analysis tools dispatched by code-review specialists.
    # Reviewer agents invoke these in the user's target repo, so they must be
    # allowed regardless of cwd. Project-local node_modules paths handled above.
    ruff|nbqa|trivy|eslint|biome|housekeeper-freshness) hook_allow "$REASON" ;;

    # Rich text clipboard pipeline
    md2clip)        hook_allow "$REASON" ;;

    # General utilities
    curl|jq|cp|chmod|python3|brew|open|grep|aws|command|whisper-cli|tmux)
                    hook_allow "$REASON" ;;

    # Read-only utilities used by code reviewers
    wc|tail|xxd|find|head|sort|uniq|diff|file|echo|printf|awk)
                    hook_allow "$REASON" ;;

    # Temp directory operations — only allow for /tmp/claude-* paths
    mkdir)
        if [[ "$cmd" == "mkdir -p /tmp/claude-"* ]]; then
            hook_allow "$REASON"
        fi
        ;;
    ls)             hook_allow "$REASON" ;;
    cat)
        if [[ "$cmd" == *"/tmp/claude-"* ]]; then
            hook_allow "$REASON"
        fi
        ;;
    rm)
        if [[ "$cmd" == "rm /tmp/claude-"* || "$cmd" == "rm -f /tmp/claude-"* || "$cmd" == "rm -rf /tmp/claude-"* ]]; then
            hook_allow "$REASON"
        fi
        ;;
esac

# No match — fall through silently to subsequent hooks
exit 0
