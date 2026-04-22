#!/usr/bin/env bash
# session-init.sh — SessionStart hook
# Reads session_id from stdin JSON, creates the session-scoped temp directory,
# renames the tmux session, and injects the temp path into conversation context.

set -euo pipefail

input=$(cat)
session_id=$(jq -r '.session_id // empty' <<< "$input")

if [[ -z "$session_id" ]]; then
    exit 0
fi

temp_dir="/tmp/claude-${session_id}"
mkdir -p "$temp_dir"

# Rename the tmux session to the first 8 chars of the UUID for readability.
# Falls back silently if not running inside tmux.
if [[ -n "${TMUX:-}" ]]; then
    tmux rename-session -- "${session_id:0:8}" 2>/dev/null || true
fi

# Inject the temp path and session ID into conversation context.
jq -n \
    --arg ctx "CLAUDE_SESSION_ID=${session_id} CLAUDE_TEMP_DIR=${temp_dir}" \
    '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
