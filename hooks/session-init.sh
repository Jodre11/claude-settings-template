#!/usr/bin/env bash
# session-init.sh — SessionStart hook
# Reads session_id from stdin JSON, creates the session-scoped temp directory,
# resolves the slug (c-<abbrev>-<4hex>), and emits hookSpecificOutput with
# sessionTitle + additionalContext.
# It also exports CLAUDE_SESSION_ID and CLAUDE_TEMP_DIR to Bash commands via $CLAUDE_ENV_FILE.
#
# Slug source of truth:
#   - Inside tmux: the tmux session name set by the zsh wrapper. The wrapper
#     computes the slug at launch time using scripts/derive-claude-slug.sh so
#     the session is born with the right name; the hook just reads it back.
#   - Outside tmux: derived ad-hoc by the hook.

set -euo pipefail

input=$(cat)
session_id=$(jq -r '.session_id // empty' <<< "$input")

# Whole-string match: the ID reaches a sourced env file, where a newline would start a new command.
if [[ ! "$session_id" =~ ^[A-Za-z0-9-]+$ ]]; then
    exit 0
fi

temp_dir="/tmp/claude-${session_id}"
mkdir -p "$temp_dir"

if [[ -n "${CLAUDE_ENV_FILE:-}" ]]; then
    printf 'export CLAUDE_SESSION_ID=%s CLAUDE_TEMP_DIR=%s\n' "$session_id" "$temp_dir" >> "$CLAUDE_ENV_FILE" || true
fi

slug=""
if [[ -n "${TMUX:-}" ]]; then
    candidate=$(tmux display-message -p '#S' 2>/dev/null || true)
    # Honour the wrapper's name only if it looks like our slug format
    # (c-…-…). A user-renamed session keeps its name and we don't override
    # the title from a stale slug.
    if [[ "$candidate" =~ ^[a-z]-[a-z0-9]+-[0-9a-f]{4}$ ]]; then
        slug="$candidate"
    fi
fi

if [[ -z "$slug" ]]; then
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    suffix_hex="${session_id//-/}"
    slug=$("$script_dir/scripts/derive-claude-slug.sh" "${suffix_hex:0:4}")
fi

jq -n \
    --arg ctx "CLAUDE_SESSION_ID=${session_id} CLAUDE_TEMP_DIR=${temp_dir}" \
    --arg title "$slug" \
    '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx, sessionTitle: $title}}'
