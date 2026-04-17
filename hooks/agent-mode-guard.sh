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
source "$(dirname "$0")/_lib.sh"
hook_read_input

# Extract all needed fields in one jq call (TSV)
IFS=$'\t' read -r mode permission_mode subagent_type <<< "$(
    jq -r '[
        .tool_input.mode // "",
        .permission_mode // "",
        .tool_input.subagent_type // ""
    ] | @tsv' <<< "$HOOK_INPUT"
)"

# Guard 1: Require autonomous mode on all Agent dispatches
if [[ "$mode" != "auto" && "$mode" != "bypassPermissions" && "$mode" != "dontAsk" && "$mode" != "acceptEdits" ]]; then
    hook_deny "AGENT MODE GUARD: Agent tool call missing or has restrictive mode (got: \"${mode:-<unset>}\"). Set mode: \"auto\" to prevent subagents inheriting defaultMode: \"plan\" from settings.json. See CLAUDE.md 'Agents' section."
fi

# Guard 2: In plan mode, only allow read-only agent types
if [[ "$permission_mode" == "plan" ]]; then
    # Allowlist of agent types that only read (no Write/Edit/Bash needed)
    case "$subagent_type" in
        Explore|Plan|claude-code-guide|statusline-setup)
            exit 0
            ;;
        *)
            hook_deny "AGENT MODE GUARD: Plan mode active — blocked agent type \"${subagent_type:-<unset>}\". Only read-only agents (Explore, Plan, claude-code-guide, statusline-setup) are allowed in plan mode. Do NOT plan or retry — ask the user to switch out of plan mode (shift+tab) so you can proceed. If this agent type should be allowed in plan mode, the user can add it to the allowlist in ~/.claude/hooks/agent-mode-guard.sh."
            ;;
    esac
fi

exit 0
