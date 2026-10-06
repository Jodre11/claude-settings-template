#!/usr/bin/env bash
# session-init.sh — SessionStart hook
# Reads session_id from stdin JSON, creates the session-scoped temp directory and secret vault,
# resolves the slug (c-<abbrev>-<4hex>), and emits hookSpecificOutput with
# sessionTitle + additionalContext.
# It also exports CLAUDE_SESSION_ID, CLAUDE_TEMP_DIR and CLAUDE_SECRET_DIR to Bash commands via $CLAUDE_ENV_FILE.
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

# make_vault <vault> <secrets>: creates both directories with mode 0700, failing instead of acting through a symlink
# or on a directory another user owns: /tmp is shared, so either could have been planted at this path.
make_vault() {
    [[ ! -L "$1" ]] || return 1
    mkdir -p "$2" 2>/dev/null || return 1
    [[ ! -L "$1" && ! -L "$2" && -O "$1" && -O "$2" ]] || return 1
    chmod 0700 "$1" "$2" 2>/dev/null
}

# The secret vault sits beside the session directory, not inside it: secret-path-guard.sh checks only a Grep's root,
# so a Grep of the session directory would reach a vault inside it. Every path under it matches */secrets/*.
# A vault that cannot be made safely is left out of the exports; the session directory does not depend on it.
vault_dir="/tmp/claude-${session_id}-vault"
secret_dir="${vault_dir}/secrets"
if ! make_vault "$vault_dir" "$secret_dir"; then
    secret_dir=""
fi

exports="CLAUDE_SESSION_ID=${session_id} CLAUDE_TEMP_DIR=${temp_dir}"
if [[ -n "$secret_dir" ]]; then
    exports+=" CLAUDE_SECRET_DIR=${secret_dir}"
fi

if [[ -n "${CLAUDE_ENV_FILE:-}" ]]; then
    printf 'export %s\n' "$exports" >> "$CLAUDE_ENV_FILE" || true
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
    --arg ctx "$exports" \
    --arg title "$slug" \
    '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx, sessionTitle: $title}}'
