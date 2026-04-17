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

# Extract the base command (first word)
read -r base _ <<< "$cmd"

REASON="Allowed by allow-permissions hook (mirrors settings.json permissions.allow)"

case "$base" in
    # Version control and GitHub CLI
    git|gh)         hook_allow "$REASON" ;;

    # Build tools
    dotnet|terraform|cargo) hook_allow "$REASON" ;;

    # Browser automation
    playwright-cli|npx) hook_allow "$REASON" ;;

    # Code inspection
    jb)             hook_allow "$REASON" ;;

    # Rich text clipboard pipeline
    md2clip)        hook_allow "$REASON" ;;

    # General utilities
    curl|jq|cp|chmod|python3|brew|open|grep|aws|command|whisper-cli|tmux)
                    hook_allow "$REASON" ;;

    # Read-only utilities used by code reviewers
    wc|tail|xxd|find|head|sort|uniq|diff|file)
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
