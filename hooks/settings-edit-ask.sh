#!/usr/bin/env bash
# settings-edit-ask.sh — PreToolUse hook for Write|Edit calls.
# Forces a permission prompt, with a reason, for a direct edit of ~/.claude/settings.json: the file is generated from
# settings.json.tmpl and untracked, so a direct edit stays on this machine. It decides nothing for any other path;
# the native permission rules, which subagents inherit, decide those. Hooks run in parallel; deny wins.

set -euo pipefail
source "$(dirname "$0")/_lib.sh"
hook_read_input

file_path=$(hook_field '.tool_input.file_path')
if [[ "$file_path" == *"/.claude/settings.json" ]]; then
    msg="settings.json is generated from settings.json.tmpl and is not tracked by git, so a direct edit stays on"
    msg+=" this machine only. For a permanent change, edit settings.json.tmpl and run scripts/apply-settings.sh."
    msg+=" Proceed only if testing locally."
    hook_ask "$msg"
fi

exit 0
