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
    msg="TEMP DIRECTORY VIOLATION: Attempted to write to '$file_path'. Per CLAUDE.md 'Temporary Files': use /tmp/claude-{session_id}/ for ALL temp files. Create with 'mkdir -p /tmp/claude-{session_id}' before first use. NEVER use bare /tmp/, /var/folders/, or \$TMPDIR."
    jq -n --arg m "$msg" '{
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": $m
        }
    }'
fi
