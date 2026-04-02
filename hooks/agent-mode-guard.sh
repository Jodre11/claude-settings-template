#!/usr/bin/env bash
# agent-mode-guard.sh — PreToolUse hook for Agent calls
#
# Two guards:
# 1. Denies Agent tool calls that don't set an autonomous mode, preventing
#    subagents from inheriting defaultMode: "plan" from settings.json.
# 2. In plan mode, only allows read-only agent types (allowlist). Writing
#    agents would inherit plan mode and stall on Write/Edit/Bash.
#
# Related upstream bug: https://github.com/anthropics/claude-code/issues/4462

set -euo pipefail

input=$(cat)
mode=$(echo "$input" | jq -r '.tool_input.mode // empty')
permission_mode=$(echo "$input" | jq -r '.permission_mode // empty')
subagent_type=$(echo "$input" | jq -r '.tool_input.subagent_type // empty')

# Guard 1: Require autonomous mode on all Agent dispatches
if [ "$mode" != "auto" ] && [ "$mode" != "bypassPermissions" ] && [ "$mode" != "dontAsk" ] && [ "$mode" != "acceptEdits" ]; then
    msg="AGENT MODE GUARD: Agent tool call missing or has restrictive mode (got: \"${mode:-<unset>}\"). Set mode: \"auto\" to prevent subagents inheriting defaultMode: \"plan\" from settings.json. See CLAUDE.md 'Agents' section."
    jq -n --arg m "$msg" '{
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": $m
        }
    }'
    exit 0
fi

# Guard 2: In plan mode, only allow read-only agent types
if [ "$permission_mode" = "plan" ]; then
    # Allowlist of agent types that only read (no Write/Edit/Bash needed)
    case "$subagent_type" in
        Explore|Plan|claude-code-guide|statusline-setup)
            exit 0
            ;;
        *)
            msg="AGENT MODE GUARD: Plan mode active — blocked agent type \"${subagent_type:-<unset>}\". Only read-only agents are allowed in plan mode. Current allowlist: Explore, Plan, claude-code-guide, statusline-setup. To unblock: either exit plan mode (shift+tab) or add the agent type to the case statement allowlist in ~/.claude/hooks/agent-mode-guard.sh."
            jq -n --arg m "$msg" '{
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": $m
                }
            }'
            exit 0
            ;;
    esac
fi
