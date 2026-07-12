#!/usr/bin/env bash
# secret-path-guard.sh — PreToolUse hook for Read|Grep. Denies reads of
# secret-bearing paths so a secret value is never pulled into context.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/_lib.sh"
source "$DIR/secret-patterns.sh"
# Fail SAFE: any unexpected error forces a manual permission prompt.
trap 'hook_ask "secret-path-guard failed to evaluate; approve manually."' ERR
hook_read_input

if [[ "${CLAUDE_ALLOW_SECRET_READ:-0}" == "1" ]]; then
    exit 0
fi

# Read uses file_path; Grep uses path (the directory it searches).
path=$(hook_field '.tool_input.file_path')
if [[ -z "$path" ]]; then
    path=$(hook_field '.tool_input.path')
fi

if [[ -n "$path" ]] && path_is_secret "$path"; then
    hook_deny "SECRET-PATH BLOCK: '$path' matches a secret-bearing path (e.g. **/secrets/**, .env, *.pem, .strongbox-keyid). Reading it would pull a secret into context. Have a script write the value to \$CLAUDE_TEMP_DIR and consume it there, or set CLAUDE_ALLOW_SECRET_READ=1 for a deliberate one-off."
fi
exit 0
