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

# JSON-escape a string: escape backslashes, double quotes, and newlines.
_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    printf '%s' "$s"
}

# Emit a PreToolUse "allow" decision and exit.
hook_allow() {
    local r
    r=$(_json_escape "${1:-Allowed by hook}")
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"%s"}}' "$r"
    exit 0
}

# Emit a PreToolUse "ask" decision (forces permission prompt with reason) and exit.
hook_ask() {
    local r
    r=$(_json_escape "$1")
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s"}}' "$r"
    exit 0
}

# Emit a PreToolUse "deny" decision and exit.
hook_deny() {
    local r
    r=$(_json_escape "$1")
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}' "$r"
    exit 0
}

# Returns 0 if the command is a git invocation whose subcommand mutates the
# working tree, index, refs, or history. Skips git global options (-C <path>,
# -c <kv>, --git-dir/--work-tree/--namespace and their =forms, -p/--paginate/
# --no-pager, etc.) to locate the real subcommand. Dual-mode read commands the
# review pipeline relies on are deliberately NOT treated as mutating:
# diff/log/show/status/rev-parse/symbolic-ref (read form)/hash-object/branch/tag/
# config — these are read-only in their pipeline usage and excluding them avoids
# false-positive denials that would break a reviewer's base-branch resolution.
is_mutating_git() {
    local c="$1"
    local -a toks
    read -ra toks <<< "$c"
    [[ "${toks[0]:-}" == git ]] || return 1
    local i=1 n=${#toks[@]} sub="" t
    while (( i < n )); do
        t="${toks[i]}"
        case "$t" in
            -C|-c|--git-dir|--work-tree|--namespace)
                (( i += 2 )); continue ;;
            --git-dir=*|--work-tree=*|--namespace=*|-p|--paginate|--no-pager|--bare|--no-replace-objects|--literal-pathspecs|--no-optional-locks)
                (( i += 1 )); continue ;;
            -*) (( i += 1 )); continue ;;
            *)  sub="$t"; break ;;
        esac
    done
    case "$sub" in
        commit|add|rm|mv|push|reset|checkout|switch|restore|stash|rebase|merge|revert|cherry-pick|clean|am|apply|update-ref|update-index|write-tree|commit-tree|fast-import|filter-branch|gc|prune|repack|fetch|pull)
            return 0 ;;
        *)  return 1 ;;
    esac
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
