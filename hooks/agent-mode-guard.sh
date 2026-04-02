#!/usr/bin/env bash
# agent-mode-guard.sh — PreToolUse hook for Agent calls
# Denies Agent tool calls that don't set mode: "auto", preventing subagents
# from inheriting defaultMode: "plan" from settings.json and stalling.
#
# Related upstream bug: https://github.com/anthropics/claude-code/issues/4462
#
# If mode is missing or set to "plan", emits permissionDecision: "deny" with guidance.
# Otherwise exits silently (falls through).

set -euo pipefail

input=$(cat)
mode=$(echo "$input" | jq -r '.tool_input.mode // empty')

if [ "$mode" = "auto" ] || [ "$mode" = "bypassPermissions" ] || [ "$mode" = "dontAsk" ] || [ "$mode" = "acceptEdits" ]; then
    exit 0
fi

msg="AGENT MODE GUARD: Agent tool call missing or has restrictive mode (got: \"${mode:-<unset>}\"). Set mode: \"auto\" to prevent subagents inheriting defaultMode: \"plan\" from settings.json. See CLAUDE.md 'Agents' section."
jq -n --arg m "$msg" '{
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": $m
    }
}'
