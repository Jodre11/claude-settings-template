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

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // empty')

if [ -z "$cmd" ]; then
    exit 0
fi

# Extract the base command (first word)
base=$(echo "$cmd" | awk '{print $1}')

allow() {
    jq -n '{
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
            "permissionDecisionReason": "Allowed by allow-permissions hook (mirrors settings.json permissions.allow)"
        }
    }'
    exit 0
}

case "$base" in
    # Version control and GitHub CLI
    git)        allow ;;
    gh)         allow ;;

    # Build tools
    dotnet)     allow ;;
    terraform)  allow ;;
    cargo)      allow ;;

    # Browser automation
    playwright-cli) allow ;;
    npx)        allow ;;

    # Code inspection
    jb)         allow ;;

    # Rich text clipboard pipeline
    md2clip)    allow ;;

    # General utilities
    curl)       allow ;;
    jq)         allow ;;
    cp)         allow ;;
    chmod)      allow ;;
    python3)    allow ;;
    brew)       allow ;;
    open)       allow ;;
    grep)       allow ;;
    aws)        allow ;;
    command)    allow ;;
    whisper-cli) allow ;;
    tmux)       allow ;;

    # Read-only utilities used by code reviewers
    wc)         allow ;;
    tail)       allow ;;
    xxd)        allow ;;

    # Temp directory operations — only allow for /tmp/claude-* paths
    mkdir)
        if echo "$cmd" | grep -qE '^mkdir -p /tmp/claude-'; then
            allow
        fi
        ;;
    ls)
        if echo "$cmd" | grep -qE '^ls /tmp/claude-'; then
            allow
        fi
        ;;
    cat)
        if echo "$cmd" | grep -qF '/tmp/claude-'; then
            allow
        fi
        ;;
    rm)
        if echo "$cmd" | grep -qE '^rm (-f |-rf )?/tmp/claude-'; then
            allow
        fi
        ;;
esac

# No match — fall through silently to subsequent hooks
exit 0
