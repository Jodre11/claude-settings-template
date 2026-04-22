#!/usr/bin/env bash
# temp-path-guard.sh — PreToolUse hook for Write|Edit calls
# Allows writes to /tmp/claude-*; blocks other /tmp/ and /var/folders/ paths.

set -euo pipefail
source "$(dirname "$0")/_lib.sh"
hook_read_input

file_path=$(hook_field '.tool_input.file_path')
if [[ -z "$file_path" ]]; then
    exit 0
fi

# Allow session-scoped temp directory
if is_session_temp_file "$file_path"; then
    exit 0
fi

# Block bare /tmp/ and /var/folders/
if [[ "$file_path" == /tmp/* || "$file_path" == /var/folders/* ]]; then
    hook_deny "TEMP DIRECTORY VIOLATION: Attempted to write to '$file_path'. Per CLAUDE.md 'Temporary Files': use \$CLAUDE_TEMP_DIR for ALL temp files. The SessionStart hook creates the directory automatically. NEVER use bare /tmp/, /var/folders/, or \$TMPDIR."
fi

exit 0
