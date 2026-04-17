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
source "$(dirname "$0")/_lib.sh"
hook_read_input

file_path=$(hook_field '.tool_input.file_path')
if [[ -z "$file_path" ]]; then
    exit 0
fi

# Allow session-scoped temp directory (mirrors Write(//tmp/claude-**) and Edit(//tmp/claude-**))
if [[ "$file_path" == "/tmp/claude-"* ]]; then
    hook_allow "Allowed by allow-write-permissions hook (mirrors settings.json permissions.allow)"
fi

# No match — fall through silently to subsequent hooks
exit 0
