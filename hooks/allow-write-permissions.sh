#!/usr/bin/env bash
# allow-write-permissions.sh — PreToolUse hook for Write|Edit calls
# Mirrors the Write/Edit permissions.allow patterns from ~/.claude/settings.json as a hook,
# so that subagents (which inherit hooks but not permission patterns) get the same
# auto-allow behaviour as the main conversation.
#
# Workaround for: https://github.com/anthropics/claude-code/issues/18950
#
# If the file path matches, emits permissionDecision: "allow".
# If not, exits silently (falls through to subsequent hooks like temp-path-guard.sh).

set -euo pipefail

input=$(cat)
file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty')

if [ -z "$file_path" ]; then
    exit 0
fi

# Allow session-scoped temp directory (mirrors Write(//tmp/claude-**) and Edit(//tmp/claude-**))
if echo "$file_path" | grep -qE '^/tmp/claude-'; then
    jq -n '{
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
            "permissionDecisionReason": "Allowed by allow-write-permissions hook (mirrors settings.json permissions.allow)"
        }
    }'
    exit 0
fi

# No match — fall through silently to subsequent hooks
exit 0
