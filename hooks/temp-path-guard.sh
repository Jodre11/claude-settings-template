#!/usr/bin/env bash
# temp-path-guard.sh — PreToolUse hook for Write|Edit calls
# Blocks writes to /tmp/, $TMPDIR, or /var/folders/ — redirect to ~/.claude/tmp/

set -euo pipefail

input=$(cat)
file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty')

if [ -z "$file_path" ]; then
    exit 0
fi

if echo "$file_path" | grep -qE '^(/tmp/|/var/folders/)'; then
    msg="TEMP DIRECTORY VIOLATION: Use ~/.claude/tmp/ (with \$PPID prefix) instead of $file_path. See CLAUDE.md 'Temporary Files' section."
    jq -n --arg m "$msg" '{
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": $m
        }
    }'
fi
