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

_HOOK_DECISION_FMT='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s",'
_HOOK_DECISION_FMT+='"permissionDecisionReason":"%s"}}'

# _hook_decision <allow|ask|deny> <reason>: emit a PreToolUse decision, mark the hook settled and exit 0. The reason
# is escaped before the mark, so a crash while escaping still reaches the backstop.
_hook_decision() {
    local r
    r=$(_json_escape "$2")
    _HOOK_SETTLED=1
    # shellcheck disable=SC2059  # the format is the fixed decision template
    printf "$_HOOK_DECISION_FMT" "$1" "$r"
    exit 0
}

# Emit a PreToolUse "allow" decision and exit.
hook_allow() {
    _hook_decision allow "${1:-Allowed by hook}"
}

# Emit a PreToolUse "ask" decision (forces permission prompt with reason) and exit.
hook_ask() {
    _hook_decision ask "$1"
}

# Emit a PreToolUse "deny" decision and exit.
hook_deny() {
    _hook_decision deny "$1"
}

# hook_pass: end the hook with no decision (the native permission rules decide). A hook that installs hook_backstop
# must leave through hook_pass or a decision helper; any other exit counts as a crash.
hook_pass() {
    _HOOK_SETTLED=1
    exit 0
}

# hook_backstop <ask|deny> <reason>: install an EXIT trap that emits <decision> with <reason> when the hook exits
# without settling. An unbound variable under set -u exits without running the ERR trap (on bash 3.2 an empty array
# counts as unbound), as does a crash inside a function, and a hook that exits without a decision does not block.
# <reason> is printed unescaped, so it must be plain ASCII with no quote or backslash.
hook_backstop() {
    _HOOK_BACKSTOP_DECISION="$1"
    _HOOK_BACKSTOP_REASON="$2"
    trap _hook_backstop_fire EXIT
}

# _hook_backstop_fire: the EXIT trap hook_backstop installs.
_hook_backstop_fire() {
    if [[ "${_HOOK_SETTLED:-0}" != 1 ]]; then
        _HOOK_SETTLED=1
        # shellcheck disable=SC2059  # the format is the fixed decision template
        printf "$_HOOK_DECISION_FMT" "$_HOOK_BACKSTOP_DECISION" "$_HOOK_BACKSTOP_REASON"
        exit 0
    fi
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

# The git walk locates a git invocation's subcommand one word at a time, so a caller walking shell_words output
# forward can run it from any word whose command name is git. git_walk_start begins a walk; git_walk_word <word>
# feeds the next word, skipping global options (-C <path>, -c <kv>, and <value> for each of --git-dir, --work-tree,
# --namespace, --config-env and --attr-source, plus every other - option, their =forms included) until the first other
# word, which it stores in GW_SUB, clearing GW_ACTIVE.
# shellcheck disable=SC2034  # GW_ACTIVE and GW_SUB are read by the calling hook
git_walk_start() {
    GW_ACTIVE=1
    GW_SKIP=0
    GW_SUB=""
}

# shellcheck disable=SC2034  # GW_ACTIVE and GW_SUB are read by the calling hook
git_walk_word() {
    if (( GW_SKIP )); then
        GW_SKIP=0
        return 0
    fi
    case "$1" in
        -C|-c|--git-dir|--work-tree|--namespace|--config-env|--attr-source) GW_SKIP=1 ;;
        -*) ;;
        *) GW_SUB="$1"; GW_ACTIVE=0 ;;
    esac
    return 0
}

# git_sub_mutating <subcommand>: 0 if the git subcommand mutates the working tree, index, refs or history. Dual-mode
# read commands the review pipeline relies on are deliberately NOT treated as mutating: diff/log/show/status/
# rev-parse/symbolic-ref (read form)/hash-object/branch/tag/config — these are read-only in their pipeline usage and
# excluding them avoids false-positive denials that would break a reviewer's base-branch resolution. worktree/notes/
# submodule/sparse-checkout/lfs/replace count as mutating in every form, read forms included: no reviewer prompt uses
# them, and the orchestrator, not a reviewer, creates review worktrees.
git_sub_mutating() {
    case "$1" in
        commit|add|rm|mv|push|reset|checkout|switch|restore|stash|rebase|merge|revert|cherry-pick|clean|am|apply|\
        update-ref|update-index|write-tree|commit-tree|fast-import|filter-branch|gc|prune|repack|fetch|pull|\
        worktree|notes|submodule|sparse-checkout|lfs|replace)
            return 0 ;;
    esac
    return 1
}

# git_sub_reader <subcommand>: 0 if the git subcommand prints file content (a history or blob reader).
git_sub_reader() {
    case "$1" in
        show|diff|log|blame|annotate|cat-file|grep|archive|format-patch) return 0 ;;
    esac
    return 1
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

# The commit message body as bash 3.2 reads it inside "$(…)": quotes and backslash escapes respected, parentheses
# counted. Prints bad when the depth drops below zero, ok when it ends at zero with no quote left open, else open (a
# quote or a ( left open is a parse error under bash 3.2, which runs nothing).
_HEREDOC_BODY_AWK='
{ s = (NR == 1) ? $0 : s "\n" $0 }
END {
    n = length(s); st = "N"; depth = 0; bad = 0
    if (split(s, ch, "") != n) for (i = 1; i <= n; i++) ch[i] = substr(s, i, 1)
    for (i = 1; i <= n && !bad; i++) {
        c = ch[i]
        if (st == "S") { if (c == q) st = "N"; continue }
        if (st == "D") {
            if (c == "\\") i++
            else if (c == "\"") st = "N"
            continue
        }
        if (c == "\\") i++
        else if (c == q) st = "S"
        else if (c == "\"") st = "D"
        else if (c == "(") depth++
        else if (c == ")") { depth--; if (depth < 0) bad = 1 }
    }
    print bad ? "bad" : ((st == "N" && depth == 0) ? "ok" : "open")
}'

# strip_commit_heredoc <cmd>: print <cmd> with the documented commit-message heredoc span
# (-m "$(cat <<'EOF' … EOF\n)") replaced by -m '' when <cmd> starts with `git … commit` and is
# at most COMMIT_HEREDOC_MAX_CHARS; otherwise print <cmd> unchanged. The quoted delimiter makes
# the body inert text. The body ends at the first line that STARTS with EOF, and that line must
# be exactly EOF: bash also ends a heredoc inside $(…) at a line such as `EOF)`, running the
# lines after it. The text before the marker must be only plain command words (letters, digits and _ . / = @ : - ~):
# a quote or shell metacharacter there could put the marker inside quoted text, where the span is not an inert heredoc
# and stripping it would hide the real commands between the marker and the closer. The body must also be inert under
# bash 3.2, which does not see the heredoc and matches parentheses instead (_HEREDOC_BODY_AWK): otherwise a ) in the
# message would end the substitution early and run the rest. A body that leaves a quote or a ( open is a parse error
# there, so it strips only when nothing follows the closing )" (the command ends with it).
strip_commit_heredoc() {
    local cmd="$1" open=$'-m "$(cat <<\'EOF\'\n' prefix tail body scan
    local close_re='^[[:blank:]]*\)"(.*)$'
    if (( ${#cmd} > COMMIT_HEREDOC_MAX_CHARS )); then printf '%s' "$cmd"; return 0; fi
    if [[ "$cmd" != *"$open"* ]]; then printf '%s' "$cmd"; return 0; fi
    prefix="${cmd%%"$open"*}"
    # git, blank-separated plain words with a commit among them, and a trailing blank: three linear glob tests (a
    # regex over nested word groups takes over a second on a 32 KB prefix).
    if [[ "$prefix" != git[[:blank:]]* || "$prefix" == *[![:alnum:]_./=@:~[:blank:]-]* \
            || "$prefix" != *[[:blank:]]commit[[:blank:]]* || "$prefix" != *[[:blank:]] ]]; then
        printf '%s' "$cmd"
        return 0
    fi
    # Substrings by offset, not ${cmd#*"$open"}: a shortest-prefix removal is quadratic in the command's length.
    tail=$'\n'"${cmd:${#prefix}+${#open}}"
    if [[ "$tail" != *$'\nEOF'* ]]; then printf '%s' "$cmd"; return 0; fi
    body="${tail%%$'\nEOF'*}"
    tail="${tail:${#body}+4}"
    # The scan does not model a backquote or a $'…' string, so a body holding either is not known to be inert.
    if [[ "$body" == *'`'* || "$body" == *"\$'"* ]]; then printf '%s' "$cmd"; return 0; fi
    scan=$(printf '%s' "$body" | LC_ALL=C awk -v q="'" "$_HEREDOC_BODY_AWK") || scan=bad
    if [[ "$scan" != ok && "$scan" != open ]]; then printf '%s' "$cmd"; return 0; fi
    if [[ "$tail" != $'\n'* ]]; then printf '%s' "$cmd"; return 0; fi
    tail="${tail#$'\n'}"
    if ! [[ "$tail" =~ $close_re ]]; then printf '%s' "$cmd"; return 0; fi
    if [[ "$scan" == open && -n "${BASH_REMATCH[1]}" ]]; then printf '%s' "$cmd"; return 0; fi
    printf '%s' "${prefix}-m ''${BASH_REMATCH[1]}"
    return 0
}

# Byte-wise quote state machine for shell_scan (N unquoted, S '…', A $'…', D "…"). Streams the
# skeleton, then prints a newline, the flags and a "." sentinel.
_SHELL_SCAN_AWK='
{ s = (NR == 1) ? $0 : s "\n" $0 }
END {
    n = length(s); st = "N"; subst = 0; paren = 0
    for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (st == "N") {
            if (c == "\\") { printf "%s%s", c, substr(s, i + 1, 1); i++ }
            else if (c == q) st = "S"
            else if (c == "\"") st = "D"
            else if (c == "$" && substr(s, i + 1, 1) == q) { st = "A"; i++ }
            else if (c == "$" && substr(s, i + 1, 1) == "\"") { st = "D"; i++ }
            else {
                if (c == "(" && substr(s, i - 1, 1) !~ /[$<>]/) paren = 1
                printf "%s", c
            }
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
    printf "\n%s%s%s.", (subst ? "S" : ""), (paren ? "P" : ""), (st != "N" ? "U" : "")
}'

# shell_scan runs awk only on commands up to this many characters. The per-byte substr loop is
# quadratic on BSD awk (~0.2 s at 100 KB, ~10 s at 800 KB) and the hooks time out at 5 s, so a
# longer command is reported as a scan failure (E) rather than scanned.
SHELL_SCAN_MAX_CHARS=65536

# shell_scan <cmd>: quote-aware scan of a shell command. Sets SHELL_SKELETON (<cmd> with the
# content of '…', $'…' and "…" removed; newlines inside quotes kept; escapes outside quotes kept
# verbatim; comments NOT stripped) and SHELL_SCAN_FLAGS: S = "…" holds $( or a backtick (both
# run commands; $(( counts, since bash falls back to command substitution when arithmetic
# fails), P = an unquoted, unescaped ( not preceded by $, < or > (a subshell, grouping, zsh glob
# qualifier or extglob), U = a quote is left open, E = the scan itself failed or <cmd> is over
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

# Byte-wise tokeniser for shell_words, in the quote states of _SHELL_SCAN_AWK. Prints each element followed by \x1f,
# then a \x1e sentinel. A word is held in buf up to MAXB characters, so it can be classified and an all-digit word
# read as an fd prefix (2>, 10<); a longer one is streamed as it arrives, so no string grows without bound.
_SHELL_WORDS_AWK='
function begin_word() {
    if (inw) return
    inw = 1; wq = 0; long = 0; buf = ""
    if (pend != "") { printf "r%s ", pend; pend = ""; wr = 1 } else wr = 0
}
function add(ch) {
    if (wr || long) { printf "%s", ch; return }
    buf = buf ch
    if (length(buf) > MAXB) { printf "w%s", buf; buf = ""; long = 1 }
}
function plain(b,   nm) {
    if (b == "" || b ~ /[$=:*?[]/ || b ~ /^-[^-]/ || ("/" b) ~ frag) return 0
    nm = b
    sub(/.*\//, "", nm)
    return !(nm in CLS)
}
function end_word() {
    if (!inw) return
    inw = 0
    if (wr || long) printf "%s", US
    else printf "%s%s%s", (classify && plain(buf)) ? "p" : "w", buf, US
}
function dangling() {
    if (pend != "") { printf "r%s %s", pend, US; pend = "" }
}
function sep(t) {
    end_word(); dangling()
    printf "%s%s", t, US
}
BEGIN {
    US = sprintf("%c", 31); SENT = sprintf("%c", 30); MAXB = 256
    classify = (names != "" && frag != "")
    if (classify) { k = split(names, a, " "); for (j = 1; j <= k; j++) CLS[a[j]] = 1 }
}
{ s = (NR == 1) ? $0 : s "\n" $0 }
END {
    # split into characters is about three times as fast as a substr per character; an awk that cannot split on ""
    # gets the substr loop instead.
    n = length(s); st = "N"; inw = 0; pend = ""
    if (split(s, ch, "") != n) for (i = 1; i <= n; i++) ch[i] = substr(s, i, 1)
    ch[n + 1] = ""; ch[n + 2] = ""
    for (i = 1; i <= n; i++) {
        c = ch[i]
        if (st == "S") {
            if (c == q) st = "N"; else add(c)
            continue
        }
        if (st == "A") {
            if (c == "\\") { add(c); add(ch[i + 1]); i++ }
            else if (c == q) st = "N"
            else add(c)
            continue
        }
        if (st == "D") {
            if (c == "\\") {
                d = ch[i + 1]
                if (d == "$" || d == "`" || d == "\"" || d == "\\") { add(d); i++ }
                else if (d == "\n") i++
                else add(c)
            }
            else if (c == "\"") st = "N"
            else add(c)
            continue
        }
        nx = ch[i + 1]
        if (c == " " || c == "\t") { end_word(); continue }
        if (c == "\n" || c == ";" || c == "(" || c == ")") { sep(";"); continue }
        if (c == "&" && nx != ">") { if (nx == "&") i++; sep(";"); continue }
        if (c == "|") {
            if (nx == "|") { i++; sep(";") }
            else { if (nx == "&") i++; sep("|") }
            continue
        }
        if (c == "<" || c == ">" || c == "&") {
            fd = ""
            if (c != "&" && inw && !wr && !long && !wq && buf ~ /^[0-9]+$/ && length(buf) <= 9) {
                fd = buf; inw = 0
            }
            end_word(); dangling()
            if (c == "&") { op = "&>"; i++; if (ch[i + 1] == ">") { op = "&>>"; i++ } }
            else if (c == "<") {
                if (nx == "<" && ch[i + 2] == "<") { op = "<<<"; i += 2 }
                else if (nx == "<" && ch[i + 2] == "-") { op = "<<-"; i += 2 }
                else if (nx == "<") { op = "<<"; i++ }
                else if (nx == ">") { op = "<>"; i++ }
                else if (nx == "&") { op = "<&"; i++ }
                else if (nx == "(") { i++; sep(";"); continue }
                else op = "<"
            } else {
                if (nx == ">") { op = ">>"; i++ }
                else if (nx == "|") { op = ">|"; i++ }
                else if (nx == "&") { op = ">&"; i++ }
                else if (nx == "(") { i++; sep(";"); continue }
                else op = ">"
            }
            pend = fd op
            continue
        }
        if (c == "\\") {
            if (nx == "\n") { i++; continue }
            begin_word(); wq = 1
            if (i < n) { add(nx); i++ } else add(c)
            continue
        }
        if (c == q) { begin_word(); wq = 1; st = "S"; continue }
        if (c == "\"") { begin_word(); wq = 1; st = "D"; continue }
        if (c == "$" && nx == q) { begin_word(); wq = 1; st = "A"; i++; continue }
        if (c == "$" && nx == "\"") { begin_word(); wq = 1; st = "D"; i++; continue }
        begin_word(); add(c)
    }
    end_word(); dangling()
    printf "%s", SENT
}'

# shell_words <cmd> [<names> <fragments>]: split <cmd> into words as bash and zsh would, expanding nothing. Sets
# SW_WORDS to its elements in order: w<word> (quotes and escapes removed; $(…) and backticks inside "…" stay text),
# r<op> <target> (a redirection: the operator as written with any fd prefix, one space, then the target word), | (a
# pipe, | or |&) and ; (any other separator: ; & && || newline ( ), and <( or >( ). $'…' keeps its content undecoded.
# # does not start a comment: zsh honours one only under INTERACTIVE_COMMENTS, so its text is screened as words.
# Parameters, ~, braces and globs stay as written. Given <names> (space-separated words) and <fragments> (an awk
# regex), a word of at most 256 characters becomes p<word> instead when it is plain: not empty, no $ = : * ? [, not a
# single-dash option, "/<word>" not matching <fragments>, and its basename not in <names>. Sets SW_OK=1, or
# SW_OK=0 with SW_WORDS empty when <cmd> is over SHELL_SCAN_MAX_CHARS, holds \x1e or \x1f, or awk fails. Walk SW_WORDS
# forward with ${SW_WORDS[@]+"${SW_WORDS[@]}"}: bash 3.2 treats an empty array as unbound under set -u, and indexes an
# array in O(index). Always returns 0.
# A consumer that interprets any other character inside a word must list it in <names>; p excludes only $ = : * ? [.
# shellcheck disable=SC2034  # SW_WORDS and SW_OK are read by the calling hook
shell_words() {
    local raw restore_glob=1
    SW_WORDS=()
    SW_OK=0
    if (( ${#1} > SHELL_SCAN_MAX_CHARS )) || [[ "$1" == *$'\x1e'* || "$1" == *$'\x1f'* ]]; then
        return 0
    fi
    raw=$(printf '%s' "$1" | LC_ALL=C awk -v q="'" -v names="${2:-}" -v frag="${3:-}" "$_SHELL_WORDS_AWK") || raw=""
    if [[ "$raw" != *$'\x1e' ]]; then
        return 0
    fi
    raw="${raw%$'\x1e'}"
    if [[ "$-" == *f* ]]; then
        restore_glob=0
    fi
    set -f
    local IFS=$'\x1f'
    # shellcheck disable=SC2206  # split on \x1f with pathname expansion off
    SW_WORDS=($raw)
    if (( restore_glob )); then
        set +f
    fi
    SW_OK=1
    return 0
}
