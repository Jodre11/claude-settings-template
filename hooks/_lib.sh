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

# _json_escape <s>: print <s> escaped for a JSON string body: backslash, double quote and every control character
# (\b \f \n \r \t get their short forms, the rest \u00XX). A raw control character makes the whole decision invalid
# JSON, which the CLI cannot read, so a deny quoting one would be lost. A string over 512 characters goes to jq
# instead: bash 3.2's pattern substitution is quadratic in the string's length, so a deny quoting a long operand of
# backslashes or control characters would overrun the hook's timeout, and a timed-out hook does not block. Shorter
# strings fork nothing.
_json_escape() {
    local s="$1" i c hex out
    if (( ${#s} > 512 )); then
        out=$(printf '%s' "$s" | jq -Rs .)
        printf '%s' "${out:1:${#out}-2}"
        return 0
    fi
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\b'/\\b}"
    s="${s//$'\f'/\\f}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    for (( i = 1; i < 32; i++ )); do
        printf -v hex '%02x' "$i"
        printf -v c "\\x$hex"
        if [[ "$s" == *"$c"* ]]; then
            s="${s//"$c"/\\u00$hex}"
        fi
    done
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

# Emit a PostToolUse decision that REPLACES the tool result the model sees with the JSON
# value <json> (it must keep the tool's output shape: built-in tools ignore a mismatched
# value), optionally with additionalContext (the breach alarm). Exits 0.
hook_post_redact() {
    jq -c --arg ctx "${2:-}" \
        '{hookSpecificOutput: ({hookEventName: "PostToolUse", updatedToolOutput: .}
            + (if $ctx != "" then {additionalContext: $ctx} else {} end))}' <<< "$1"
    exit 0
}

# Emit an additionalContext note for event $2 (default PostToolUse; PostToolUseFailure also honours it) without
# replacing the tool result. Exits 0.
hook_post_context() {
    jq -nc --arg ctx "$1" --arg ev "${2:-PostToolUse}" \
        '{hookSpecificOutput: {hookEventName: $ev, additionalContext: $ctx}}'
    exit 0
}

# Emit a UserPromptSubmit block decision (top-level decision, per docs). Exits 0.
hook_prompt_block() {
    local r
    r=$(_json_escape "$1")
    printf '{"decision":"block","reason":"%s"}' "$r"
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
# worktree/notes/submodule/sparse-checkout/lfs/replace count as mutating in every form,
# read forms included: no reviewer prompt uses them, and the orchestrator, not a
# reviewer, creates review worktrees.
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
        commit|add|rm|mv|push|reset|checkout|switch|restore|stash|rebase|merge|revert|cherry-pick|clean|am|apply|\
        update-ref|update-index|write-tree|commit-tree|fast-import|filter-branch|gc|prune|repack|fetch|pull|\
        worktree|notes|submodule|sparse-checkout|lfs|replace)
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

# Returns 0 if the string references a code-review ephemeral worktree path, i.e.
# a `review-worktrees/wt-…` segment. These worktrees are created by the
# code-review pipeline / standalone helpers and may legitimately land under
# /var/folders/ when a session temp dir cannot be resolved; commands operating on
# them must be exempted from the temp-write policy (see bash-guard.sh).
cmd_mentions_review_worktree() {
    [[ "$1" == *"/review-worktrees/wt-"* ]]
}

# Returns 0 if the string contains any temp-like directory reference:
# bare /tmp/ or /var/tmp/, /var/folders/, or $TMPDIR. Includes session-scoped paths —
# callers must carve out the exception via is_session_temp_file/cmd_mentions_session_temp.
#
# The /tmp/ arm is anchored to a token boundary rather than matched anywhere in the
# string. A plain substring test also fires on project-local scratch dirs whose path
# merely ends in tmp (e.g. <repo>/tmp/, ./tmp/, ~/tmp/, tools/x/tmp/), which some repos
# sanction as their scratch root — those are not the system temp dir this policy governs.
# The (\.?/)* arm absorbs //tmp/ and /./tmp/; (private/)? covers macOS's canonical
# /private/tmp/ and /private/var/tmp/, which /tmp and /var/tmp symlink to.
mentions_temp_path() {
    local re='(^|[^[:alnum:]._~/-])/(\.?/)*(private/)?(var/)?tmp/'
    [[ "$1" =~ $re ]] \
        || [[ "$1" == *'$TMPDIR'* || "$1" == */var/folders/* ]]
}

# strip_commit_heredoc's pattern matching (the git_re backtrack and the tail substring scans)
# is superlinear in bash on both an adversarial prefix and a large legitimate commit body, so
# anything over this bound skips the strip entirely; shell_scan then denies the unstripped
# heredoc as an unterminated/substitution-bearing quote, so an over-long commit message must
# use `git commit -F` instead.
COMMIT_HEREDOC_MAX_CHARS=32768

# strip_commit_heredoc <cmd>: print <cmd> with the documented commit-message heredoc span
# (-m "$(cat <<'EOF' … EOF\n)") replaced by -m '' when <cmd> starts with `git … commit` and is
# at most COMMIT_HEREDOC_MAX_CHARS; otherwise print <cmd> unchanged. The quoted delimiter makes
# the body inert text. The body ends at the first line that STARTS with EOF, and that line must
# be exactly EOF: bash also ends a heredoc inside $(…) at a line such as `EOF)`, running the
# lines after it.
strip_commit_heredoc() {
    local cmd="$1" open=$'-m "$(cat <<\'EOF\'\n' prefix tail
    local git_re='^git([[:space:]]+[^[:space:]]+)*[[:space:]]+commit[[:space:]]'
    local close_re='^[[:blank:]]*\)"(.*)$'
    if (( ${#cmd} > COMMIT_HEREDOC_MAX_CHARS )); then printf '%s' "$cmd"; return 0; fi
    if [[ "$cmd" != *"$open"* ]]; then printf '%s' "$cmd"; return 0; fi
    prefix="${cmd%%"$open"*}"
    if ! [[ "$prefix" =~ $git_re ]]; then printf '%s' "$cmd"; return 0; fi
    tail=$'\n'"${cmd#*"$open"}"
    if [[ "$tail" != *$'\nEOF'* ]]; then printf '%s' "$cmd"; return 0; fi
    tail="${tail#*$'\nEOF'}"
    if [[ "$tail" != $'\n'* ]]; then printf '%s' "$cmd"; return 0; fi
    tail="${tail#$'\n'}"
    if ! [[ "$tail" =~ $close_re ]]; then printf '%s' "$cmd"; return 0; fi
    printf '%s' "${prefix}-m ''${BASH_REMATCH[1]}"
    return 0
}

# Byte-wise quote state machine for shell_scan (N unquoted, S '…', A $'…', D "…"). Streams the
# skeleton, then prints a newline, the flags and a "." sentinel.
_SHELL_SCAN_AWK='
{ s = (NR == 1) ? $0 : s "\n" $0 }
END {
    n = length(s); st = "N"; subst = 0
    for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (st == "N") {
            if (c == "\\") { printf "%s%s", c, substr(s, i + 1, 1); i++ }
            else if (c == q) st = "S"
            else if (c == "\"") st = "D"
            else if (c == "$" && substr(s, i + 1, 1) == q) { st = "A"; i++ }
            else if (c == "$" && substr(s, i + 1, 1) == "\"") { st = "D"; i++ }
            else printf "%s", c
        } else if (st == "S") {
            if (c == q) st = "N"
            else if (c == "\n") printf "\n"
        } else if (st == "A") {
            if (c == "\\") { i++; if (substr(s, i, 1) == "\n") printf "\n" }
            else if (c == q) st = "N"
            else if (c == "\n") printf "\n"
        } else {
            if (c == "\\") { i++; if (substr(s, i, 1) == "\n") printf "\n" }
            else if (c == "\"") st = "N"
            else if (c == "`" || (c == "$" && substr(s, i + 1, 1) == "(")) subst = 1
            else if (c == "\n") printf "\n"
        }
    }
    printf "\n%s%s.", (subst ? "S" : ""), (st != "N" ? "U" : "")
}'

# shell_scan runs awk only on commands up to this many characters. The per-byte substr loop is
# quadratic on BSD awk (~0.2 s at 100 KB, ~10 s at 800 KB) and the hooks time out at 5 s, so a
# longer command is reported as a scan failure (E) rather than scanned.
SHELL_SCAN_MAX_CHARS=65536

# shell_scan <cmd>: quote-aware scan of a shell command. Sets SHELL_SKELETON (<cmd> with the
# content of '…', $'…' and "…" removed; newlines inside quotes kept; escapes outside quotes kept
# verbatim; comments NOT stripped) and SHELL_SCAN_FLAGS: S = "…" holds $( or a backtick (both
# run commands; $(( counts, since bash falls back to command substitution when arithmetic
# fails), U = a quote is left open, E = the scan itself failed or <cmd> is over
# SHELL_SCAN_MAX_CHARS. Always returns 0.
# shellcheck disable=SC2034  # SHELL_SKELETON and SHELL_SCAN_FLAGS are read by the calling hook
shell_scan() {
    local raw
    if (( ${#1} > SHELL_SCAN_MAX_CHARS )); then
        SHELL_SKELETON="$1"
        SHELL_SCAN_FLAGS="E"
        return 0
    fi
    raw=$(printf '%s' "$1" | LC_ALL=C awk -v q="'" "$_SHELL_SCAN_AWK") || raw=""
    if [[ "$raw" != *. ]]; then
        SHELL_SKELETON="$1"
        SHELL_SCAN_FLAGS="E"
        return 0
    fi
    raw="${raw%.}"
    SHELL_SCAN_FLAGS="${raw##*$'\n'}"
    SHELL_SKELETON="${raw%$'\n'*}"
}
