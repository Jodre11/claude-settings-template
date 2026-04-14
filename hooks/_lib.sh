#!/usr/bin/env bash
# _lib.sh — Shared helpers for Claude Code PreToolUse hooks.
# Source this at the top of each hook script:
#   source "$(dirname "$0")/_lib.sh"
#   hook_read_input
#   cmd=$(hook_field '.tool_input.command')

# Read stdin into HOOK_INPUT global. Must be called before hook_field.
hook_read_input() {
    HOOK_INPUT=$(cat)
}

# Extract a field from HOOK_INPUT via jq. Returns empty string if missing.
hook_field() {
    jq -r "$1 // empty" <<< "$HOOK_INPUT"
}

# Emit a PreToolUse "allow" decision and exit.
hook_allow() {
    jq -n --arg r "${1:-Allowed by hook}" '{
        hookSpecificOutput: {
            hookEventName: "PreToolUse",
            permissionDecision: "allow",
            permissionDecisionReason: $r
        }
    }'
    exit 0
}

# Emit a PreToolUse "deny" decision and exit.
hook_deny() {
    jq -n --arg r "$1" '{
        hookSpecificOutput: {
            hookEventName: "PreToolUse",
            permissionDecision: "deny",
            permissionDecisionReason: $r
        }
    }'
    exit 0
}

# Returns 0 if the path starts with /tmp/claude- (for file_path arguments).
is_session_temp_file() {
    [[ "$1" == /tmp/claude-* ]]
}

# Returns 0 if the string contains /tmp/claude- anywhere (for command strings).
cmd_mentions_session_temp() {
    [[ "$1" == *"/tmp/claude-"* ]]
}

# Returns 0 if the string contains any temp-like directory reference:
# bare /tmp/, /var/folders/, or $TMPDIR. Includes session-scoped paths —
# callers must carve out the exception via is_session_temp_file/cmd_mentions_session_temp.
mentions_temp_path() {
    [[ "$1" == */tmp/* || "$1" == *'$TMPDIR'* || "$1" == */var/folders/* ]]
}
