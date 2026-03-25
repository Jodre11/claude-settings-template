#!/usr/bin/env bash
# temp-path-guard.sh — PreToolUse hook for Write|Edit calls
# Allows writes to /tmp/claude-*; blocks other /tmp/ and /var/folders/ paths.

set -euo pipefail

input=$(cat)
file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty')

if [ -z "$file_path" ]; then
    exit 0
fi

# Allow session-scoped temp directory
if echo "$file_path" | grep -qE '^/tmp/claude-'; then
    exit 0
fi

# Block bare /tmp/ and /var/folders/
if echo "$file_path" | grep -qE '^(/tmp/|/var/folders/)'; then
    msg="TEMP DIRECTORY VIOLATION: Use /tmp/claude-\$PPID/ instead of $file_path. See CLAUDE.md 'Temporary Files' section."
    jq -n --arg m "$msg" '{
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": $m
        }
    }'
fi
