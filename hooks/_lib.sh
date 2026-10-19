#!/usr/bin/env bash
# _lib.sh — Shared helpers for Claude Code PreToolUse hooks.
# Source this at the top of each hook script:
#   source "$(dirname "$0")/_lib.sh"
#   hook_read_input
#   cmd=$(hook_field '.tool_input.command')

# Read stdin into HOOK_INPUT global, starting the run's clock (hook_clock_start). Must be called before hook_field.
hook_read_input() {
    hook_clock_start
    HOOK_INPUT=$(cat)
}

# The run-wide deadline for the steps whose cost the command's size does not bound (wildcard expansion and the
# directory probe): together they end HOOK_DEADLINE_MS after the clock starts, well inside the hook's 5 s timeout,
# after which a hook does not block. bash 5 times it with EPOCHREALTIME; an older bash has whole seconds only
# (SECONDS), so there the deadline falls a second early or late and each step is also bounded by PROBE_WATCHDOG_S.
HOOK_DEADLINE_MS=1500
HOOK_T0=""

# hook_clock_start: start the run's clock. With no clock started, each step is bounded by PROBE_WATCHDOG_S alone.
hook_clock_start() {
    if [[ -n "${EPOCHREALTIME:-}" ]]; then
        HOOK_T0="${EPOCHREALTIME/[.,]/}"
    else
        SECONDS=0
        HOOK_T0=s
    fi
}

# hook_time_left: set HOOK_LEFT_MS to the milliseconds the next bounded step may take: the time left before the
# deadline, 0 once it has passed.
hook_time_left() {
    local now left=$(( PROBE_WATCHDOG_S * 1000 ))
    if [[ "$HOOK_T0" == s ]]; then
        now=$(( ( (HOOK_DEADLINE_MS + 999) / 1000 - SECONDS ) * 1000 ))
        if (( now < left )); then left=$now; fi
    elif [[ -n "$HOOK_T0" ]]; then
        now="${EPOCHREALTIME/[.,]/}"
        left=$(( HOOK_DEADLINE_MS - (now - HOOK_T0) / 1000 ))
    fi
    if (( left < 0 )); then left=0; fi
    HOOK_LEFT_MS=$left
}

# hook_bounded <out> <command> [<arg>...]: run <command> in the background, its stdout into the file <out>, and kill it
# (and its children) once the time hook_time_left gives has passed. The caller tells a complete run from a cut one by
# an end marker the command writes last. Returns 3, running nothing, when no time is left.
hook_bounded() {
    local out="$1" p w s
    shift
    hook_time_left
    if (( HOOK_LEFT_MS <= 0 )); then
        return 3
    fi
    printf -v s '%d.%03d' $(( HOOK_LEFT_MS / 1000 )) $(( HOOK_LEFT_MS % 1000 ))
    ( "$@" ) >"$out" 2>/dev/null </dev/null &
    p=$!
    (
        sleep "$s"
        pkill -TERM -P "$p" 2>/dev/null
        kill -TERM "$p" 2>/dev/null
    ) >/dev/null 2>&1 </dev/null &
    w=$!
    wait "$p" 2>/dev/null || :
    kill "$w" 2>/dev/null || :
    # Reaped here, bash 3.2 prints no "Terminated" notice for the killed watchdog on the hook's stderr.
    wait "$w" 2>/dev/null || :
    return 0
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

# The note a guard sets in HOOK_DENY_NOTE when the command holds a here-document.
HEREDOC_DENY_NOTE=" This command holds a here-document, and its body is screened as commands. To write a file, use a"
HEREDOC_DENY_NOTE+=" one-stage cat > <file> or tee <file> here-document with a quoted delimiter ('EOF') and nothing"
HEREDOC_DENY_NOTE+=" after its closing line, or write the file with the Write tool and run 'bash <file>'."

# Emit a PreToolUse "deny" decision and exit; a HOOK_DENY_NOTE a guard set is appended to the reason.
HOOK_DENY_NOTE=""
hook_deny() {
    _hook_decision deny "$1$HOOK_DENY_NOTE"
}

# hook_pass: end the hook with no decision (the native permission rules decide), or with the ask hook_hold_ask
# recorded. A hook that installs hook_backstop must leave through hook_pass or a decision helper; any other exit counts
# as a crash.
hook_pass() {
    if [[ -n "${_HOOK_HELD_ASK:-}" ]]; then
        _hook_decision ask "$_HOOK_HELD_ASK"
    fi
    _HOOK_SETTLED=1
    exit 0
}

# hook_hold_ask <reason>: record an ask for hook_pass to emit once screening is done, so any later deny wins over it.
# The first reason recorded is kept.
hook_hold_ask() {
    if [[ -z "${_HOOK_HELD_ASK:-}" ]]; then
        _HOOK_HELD_ASK="$1"
    fi
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
# submodule/sparse-checkout/lfs/replace/reflog and the plumbing pack-refs/commit-graph/multi-pack-index/rerere/mktree/
# mktag/unpack-objects/update-server-info/merge-file/prune-packed/index-pack count as mutating in every form, read
# forms included: no reviewer prompt uses them, and the orchestrator, not a reviewer, creates review worktrees.
git_sub_mutating() {
    # init, clone, bisect, read-tree, checkout-index, maintenance and bundle write the repository or its working tree;
    # reflog counts in every form, as worktree does; stage is add. remote is left out: reviewer-guard.sh sees the word
    # after it and allows only its read forms. pack-refs and the plumbing after it write refs, the object store or
    # (merge-file) a working-tree file; they count in every form, since a reviewer needs none of their read forms.
    case "$1" in
        commit|add|rm|mv|push|reset|checkout|switch|restore|stash|rebase|merge|revert|cherry-pick|clean|am|apply|\
        update-ref|update-index|write-tree|commit-tree|fast-import|filter-branch|gc|prune|repack|fetch|pull|\
        worktree|notes|submodule|sparse-checkout|lfs|replace|init|clone|bisect|read-tree|checkout-index|\
        maintenance|bundle|reflog|stage|pack-refs|commit-graph|multi-pack-index|rerere|mktree|mktag|unpack-objects|\
        update-server-info|merge-file|prune-packed|index-pack)
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

# Awk body: print the closing line's number only when the first line equal to w (less leading tabs if dash) is the last.
_TEXT_HEREDOC_AWK='
NR >= 2 && !n {
    l = $0
    if (dash) { i = 1; while (substr(l, i, 1) == "\t") i++; l = substr(l, i) }
    if (l == w) n = NR
}
END { if (n && n == NR) print n }'

# _text_heredoc_word <word>: return 0 for a plain word, 2 for $CLAUDE_TEMP_DIR/<plain> (no .. segment), else 1.
_text_heredoc_word() {
    local plain_re='^[A-Za-z0-9_./~@%+=:,-]+$'
    local tmp_re='^(\$CLAUDE_TEMP_DIR|\$\{CLAUDE_TEMP_DIR\}|"\$CLAUDE_TEMP_DIR")/([A-Za-z0-9_./~@%+=:,-]+)$'
    if [[ "$1" =~ $plain_re ]]; then return 0; fi
    if [[ "$1" =~ $tmp_re && "/${BASH_REMATCH[2]}/" != */../* ]]; then return 2; fi
    return 1
}

# strip_text_heredoc <cmd>: print the first line alone when <cmd> is a quoted-delimiter cat or tee heredoc that writes a
# file, else <cmd> unchanged. The body is inert only for that exact shape, a closing line that ends the command and
# write-only first-line words.
strip_text_heredoc() {
    local cmd="$1" fl q="'" tok_re redir_re='^>>?(.+)$' t rc pend=0 nred=0 nfile=0 nheredoc=0 ntmp=0 occ
    local -a toks
    local dash=0 w="" first="" closing
    tok_re="^<<(-?)(${q}([A-Za-z_][A-Za-z0-9_]*)${q}|\"([A-Za-z_][A-Za-z0-9_]*)\"|\\\\([A-Za-z_][A-Za-z0-9_]*))\$"
    if (( ${#cmd} > COMMIT_HEREDOC_MAX_CHARS )) || [[ "$cmd" != *$'\n'* ]]; then printf '%s' "$cmd"; return 0; fi
    fl="${cmd%%$'\n'*}"
    IFS=$' \t' read -ra toks <<<"$fl" || { printf '%s' "$cmd"; return 0; }
    if (( ${#toks[@]} > 64 )); then printf '%s' "$cmd"; return 0; fi
    for t in ${toks[@]+"${toks[@]}"}; do
        if [[ "$t" =~ $tok_re ]]; then
            if (( pend )); then printf '%s' "$cmd"; return 0; fi
            (( ++nheredoc ))
            if [[ -n "${BASH_REMATCH[1]}" ]]; then dash=1; fi
            w="${BASH_REMATCH[3]}${BASH_REMATCH[4]}${BASH_REMATCH[5]}"
            continue
        fi
        if [[ -z "$first" ]]; then
            if [[ "$t" == cat || "$t" == tee ]]; then first="$t"; continue; fi
            printf '%s' "$cmd"
            return 0
        fi
        if [[ "$first" == cat ]]; then
            if (( pend )); then
                rc=0; _text_heredoc_word "$t" || rc=$?
                if (( rc == 1 )); then printf '%s' "$cmd"; return 0; fi
                if (( rc == 2 )); then (( ++ntmp )); fi
                pend=0
                (( ++nred ))
            elif [[ "$t" == '>' || "$t" == '>>' ]]; then
                pend=1
            elif [[ "$t" =~ $redir_re ]]; then
                rc=0; _text_heredoc_word "${BASH_REMATCH[1]}" || rc=$?
                if (( rc == 1 )); then printf '%s' "$cmd"; return 0; fi
                if (( rc == 2 )); then (( ++ntmp )); fi
                (( ++nred ))
            else
                printf '%s' "$cmd"
                return 0
            fi
        elif [[ "$t" == -a || "$t" == --append ]]; then
            :
        elif [[ "$t" != -* ]]; then
            rc=0; _text_heredoc_word "$t" || rc=$?
            if (( rc == 1 )); then printf '%s' "$cmd"; return 0; fi
            if (( rc == 2 )); then (( ++ntmp )); fi
            (( ++nfile ))
        else
            printf '%s' "$cmd"
            return 0
        fi
    done
    # Every CLAUDE_TEMP_DIR in the line must be an accepted target: no reassignment or other use of it.
    occ="${fl//CLAUDE_TEMP_DIR/}"
    if (( (${#fl} - ${#occ}) != ntmp * 15 )); then printf '%s' "$cmd"; return 0; fi
    if (( nheredoc != 1 || pend )) || [[ -z "$first" ]] || { [[ "$first" == cat ]] && (( nred < 1 )); } \
            || { [[ "$first" == tee ]] && (( nfile < 1 )); }; then
        printf '%s' "$cmd"
        return 0
    fi
    closing=$(printf '%s' "$cmd" | LC_ALL=C awk -v w="$w" -v dash="$dash" "$_TEXT_HEREDOC_AWK") || closing=""
    if [[ -z "$closing" ]]; then printf '%s' "$cmd"; return 0; fi
    printf '%s' "$fl"
    return 0
}

# Byte-wise quote state machine for shell_scan (N unquoted, S '…', A $'…', D "…"). A first pass sets
# cm to 1 when the command holds an unquoted, unescaped #. Streams the skeleton, then prints a newline,
# the flags and a "." sentinel. With cm 0, unquoted backslash-newline is dropped and an escaped ; & or |
# prints _ (both read as text), and a newline inside '…', $'…' or "…" is text and prints nothing; with cm 1
# every escape and every newline is printed verbatim, since a comment can hide what bash reads as a separator
# and a quote opened inside one is no quote. A run of two or more $ before a ' reports U: bash and zsh disagree on it.
# Inside "…" a ${ opens a nesting level and its } closes it; a quote met at level 1 or more reports U (the
# shells read it as a nested quote and the scan cannot follow), and neither pass lets it end the "…".
# An unquoted or "…" $[ or $$[ (its ] may follow a } the scan would count) and a ## before a ', " or \ (zsh
# reads that character as a literal) report U in the main pass only: U denies whatever the comment guard says.
_SHELL_SCAN_AWK='
# Returns 1 when s holds an unquoted, unescaped #, else 0.
function has_comment(s, n, q,    i, c, st, dp) {
    st = "N"; dp = 0
    for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (st == "N") {
            if (c == "\\") i++
            else if (c == q) st = "S"
            else if (c == "\"") st = "D"
            else if (c == "$" && substr(s, i + 1, 1) == "$") { while (substr(s, i + 1, 1) == "$") i++ }
            else if (c == "$" && substr(s, i + 1, 1) == q) { st = "A"; i++ }
            else if (c == "$" && substr(s, i + 1, 1) == "\"") { st = "D"; i++ }
            else if (c == "#") return 1
        } else if (st == "S") {
            if (c == q) st = "N"
        } else if (st == "A") {
            if (c == "\\") i++
            else if (c == q) st = "N"
        } else {
            if (c == "\\") i++
            else if (c == "$" && substr(s, i + 1, 1) == "{") { dp++; i++ }
            else if (c == "}" && dp > 0) dp--
            else if (c == "\"" && dp == 0) st = "N"
        }
    }
    return 0
}
{ s = (NR == 1) ? $0 : s "\n" $0 }
END {
    n = length(s); st = "N"; subst = 0; paren = 0; bad = 0; dp = 0
    cm = has_comment(s, n, q)
    for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (st == "N" || st == "D") {
            if (c == "$" && substr(s, i + 1, 1) == "[") bad = 1
            else if (c == "#" && substr(s, i + 1, 1) == "#") {
                e = substr(s, i + 2, 1)
                if (e == q || e == "\"" || e == "\\") bad = 1
            }
        }
        if (st == "N") {
            if (c == "\\") {
                d = substr(s, i + 1, 1); i++
                if (cm) printf "%s%s", c, d
                else if (d == ";" || d == "&" || d == "|") printf "_"
                else if (d != "\n") printf "%s%s", c, d
            }
            else if (c == q) st = "S"
            else if (c == "\"") st = "D"
            else if (c == "$" && substr(s, i + 1, 1) == "$") {
                for (j = i; substr(s, j + 1, 1) == "$"; j++) ;
                if (substr(s, j + 1, 1) == q || substr(s, j + 1, 1) == "[") bad = 1
                printf "%s", substr(s, i, j - i + 1)
                i = j
            }
            else if (c == "$" && substr(s, i + 1, 1) == q) { st = "A"; i++ }
            else if (c == "$" && substr(s, i + 1, 1) == "\"") { st = "D"; i++ }
            else {
                if (c == "(" && substr(s, i - 1, 1) !~ /[$<>]/) paren = 1
                printf "%s", c
            }
        } else if (st == "S") {
            if (c == q) st = "N"
            else if (c == "\n" && cm) printf "\n"
        } else if (st == "A") {
            if (c == "\\") { i++; if (cm && substr(s, i, 1) == "\n") printf "\n" }
            else if (c == q) st = "N"
            else if (c == "\n" && cm) printf "\n"
        } else {
            if (c == "\\") { i++; if (cm && substr(s, i, 1) == "\n") printf "\n" }
            else if (c == "$" && substr(s, i + 1, 1) == "{") { dp++; i++ }
            else if (c == "}" && dp > 0) dp--
            else if (dp > 0 && (c == "\"" || c == q)) bad = 1
            else if (c == "\"") st = "N"
            else if (c == "`" || (c == "$" && substr(s, i + 1, 1) == "(")) subst = 1
            else if (c == "\n" && cm) printf "\n"
        }
    }
    printf "\n%s%s%s.", (subst ? "S" : ""), (paren ? "P" : ""), ((st != "N" || bad) ? "U" : "")
}'

# shell_scan runs awk only on commands up to this many characters. The per-byte substr loop is
# quadratic on BSD awk (~0.2 s at 100 KB, ~10 s at 800 KB) and the hooks time out at 5 s, so a
# longer command is reported as a scan failure (E) rather than scanned.
SHELL_SCAN_MAX_CHARS=65536

# shell_scan <cmd>: quote-aware scan of a shell command. Sets SHELL_SKELETON (<cmd> with the
# content of '…', $'…' and "…" removed; newlines inside quotes kept only when the command holds an unquoted,
# unescaped # (otherwise they are text and dropped with the rest); comments NOT stripped; escapes
# outside quotes kept verbatim, except that when the command holds no unquoted, unescaped # a
# backslash-newline is dropped and an escaped ; & or | becomes _) and SHELL_SCAN_FLAGS: S = "…"
# holds $( or a backtick (both run commands; $(( counts, since bash falls back to command
# substitution when arithmetic fails), P = an unquoted, unescaped ( not preceded by $, < or >
# (a subshell, grouping, zsh glob qualifier or extglob), U = a quote is left open, a run of two or more $
# precedes a ' (bash and zsh read it differently), a quote sits inside ${…} within "…", or there is a $[ or a
# ## before a ', " or \ outside single quotes, E = the scan itself failed or <cmd> is over SHELL_SCAN_MAX_CHARS.
# Always returns 0.
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

# Quote-state awk for sq_strip, in the states of _SHELL_SCAN_AWK (N, S '…', A $'…', D "…" with ${…} nesting;
# a run of $ is passed through whole, as there). Streams the command with '…' and $'…' removed, then a "."
# sentinel. Every shape where the scanner reads a quote differently from the shells reports U there.
_SQ_STRIP_AWK='
{ s = (NR == 1) ? $0 : s "\n" $0 }
END {
    n = length(s); st = "N"; dp = 0
    for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (st == "N") {
            if (c == "\\") { printf "%s%s", c, substr(s, i + 1, 1); i++ }
            else if (c == q) st = "S"
            else if (c == "\"") { printf "%s", c; st = "D" }
            else if (c == "$" && substr(s, i + 1, 1) == "$") {
                for (j = i; substr(s, j + 1, 1) == "$"; j++) ;
                printf "%s", substr(s, i, j - i + 1)
                i = j
            }
            else if (c == "$" && substr(s, i + 1, 1) == q) { st = "A"; i++ }
            else if (c == "$" && substr(s, i + 1, 1) == "\"") { printf "$\""; st = "D"; i++ }
            else printf "%s", c
        } else if (st == "S") {
            if (c == q) st = "N"
        } else if (st == "A") {
            if (c == "\\") i++
            else if (c == q) st = "N"
        } else {
            if (c == "\\") { printf "%s%s", c, substr(s, i + 1, 1); i++ }
            else if (c == "$" && substr(s, i + 1, 1) == "{") { printf "${"; dp++; i++ }
            else if (c == "}" && dp > 0) { printf "%s", c; dp-- }
            else if (c == "\"" && dp == 0) { printf "%s", c; st = "N" }
            else printf "%s", c
        }
    }
    printf "."
}'

# sq_strip <cmd>: sets SQ_STRIPPED to <cmd> with the content and delimiters of '…' and $'…' removed, "…" kept
# whole and escapes outside quotes kept. Over SHELL_SCAN_MAX_CHARS, or when awk fails, SQ_STRIPPED is <cmd>.
# shellcheck disable=SC2034  # SQ_STRIPPED is read by the calling hook
sq_strip() {
    local raw
    SQ_STRIPPED="$1"
    if (( ${#1} > SHELL_SCAN_MAX_CHARS )); then
        return 0
    fi
    raw=$(printf '%s' "$1" | LC_ALL=C awk -v q="'" "$_SQ_STRIP_AWK") || raw=""
    if [[ "$raw" == *. ]]; then
        SQ_STRIPPED="${raw%.}"
    fi
    return 0
}

# rg_plain_shape <cmd>: 0 when <cmd> is rg followed only by space-separated plain options, single-quoted literals and
# plain paths, none of them an option that may run a program (--pre, --hostname-bin or a prefix or extension of
# either). Anything else (braces, globs, $, double quotes, backslashes, newlines) returns 1. Fails closed.
rg_plain_shape() {
    local rest="${1#rg}" name
    local re_long='^--([a-z0-9-]+)(=[A-Za-z0-9._/:,-]*)?( .*)?$'
    local re_short='^-[A-Za-z0-9]+(=[A-Za-z0-9._/:,-]*)?( .*)?$'
    local re_quoted="^'[^']*'( .*)?\$"
    local re_path='^[A-Za-z0-9._/~:,+][A-Za-z0-9._/~:,+-]*( .*)?$'
    if (( ${#1} > 4096 )); then
        return 1
    fi
    while [[ -n "$rest" ]]; do
        if [[ "$rest" != " "* ]]; then
            return 1
        fi
        while [[ "$rest" == " "* ]]; do
            rest="${rest# }"
        done
        if [[ -z "$rest" ]]; then
            return 0
        fi
        if [[ "$rest" =~ $re_long ]]; then
            name="${BASH_REMATCH[1]}"
            if [[ "$name" == pre* || "$name" == hostname-bin* || "pre-glob" == "$name"* \
                    || "hostname-bin" == "$name"* ]]; then
                return 1
            fi
            rest="${BASH_REMATCH[3]}"
        elif [[ "$rest" =~ $re_short ]]; then
            rest="${BASH_REMATCH[2]}"
        elif [[ "$rest" =~ $re_quoted ]]; then
            if [[ "$rest" == "'-"* ]]; then
                return 1
            fi
            rest="${BASH_REMATCH[1]}"
        elif [[ "$rest" != -* && "$rest" =~ $re_path ]]; then
            rest="${BASH_REMATCH[1]}"
        else
            return 1
        fi
    done
    return 0
}

# Byte-wise tokeniser for shell_words, in the quote states of _SHELL_SCAN_AWK. Prints each element followed by \x1f,
# then a \x1e sentinel. A word is held in buf up to MAXB characters, so it can be classified and an all-digit word
# read as an fd prefix (2>, 10<); a longer one is streamed as it arrives, so no string grows without bound.
_SHELL_WORDS_AWK='
function begin_word() {
    if (inw) return
    inw = 1; wq = 0; long = 0; buf = ""; lc = ""; ln = 0
    wg = 0; wgl = 0; wd = 0; wdl = 0; wdq = 0; wb = 0
    qn = 0; qopen = -1; qclose = -1; qbr = 0; wa = 0
    if (pend != "") { printf "r%s ", pend; pend = ""; wr = 1 } else wr = 0
}
function add(ch, live, pbr) {
    if (wr) { printf "%s", ch; return }
    if (!live) {
        qn++
        if ((ch == "{" || ch == "}") && !pbr) qbr = 1
    }
    if (ch == "$") { wd = 1; if (live) wdl = 1; else wdq = 1 }
    else if (ch == "*" || ch == "?" || ch == "[" || ch == "{") {
        wg = 1; if (live) wgl = 1
        if (ch == "{") { wb = 1; if (live && qopen < 0) qopen = qn }
    }
    else if (ch == "}" && live) qclose = qn
    if (long) {
        lc = lc ch
        if (length(lc) >= MAXB) { lk[++ln] = lc; lc = "" }
        return
    }
    buf = buf ch
    if (length(buf) > MAXB) { lc = buf; buf = ""; long = 1 }
}
function plain(b,   nm) {
    if (b == "" || b ~ /[$=:*?[\200-\377]/ || b ~ /^-[^-]/ || tolower("/" b) ~ frag) return 0
    nm = tolower(b)
    sub(/.*\//, "", nm)
    if (nm in CLS) return 0
    if (nm !~ /^[a-z]+[0-9][0-9.]*$/) return 1
    sub(/[0-9][0-9.]*$/, "", nm)
    return !(nm in CLS)
}
function end_word(   mk, lm, i) {
    if (!inw) return
    inw = 0
    if (wr) { printf "%s", US; return }
    mk = ((wg && !wgl) ? "g" : "") ((wd && !wdl) ? "d" : "") ((wdq && wdl) ? "q" : "")
    if (qopen >= 0 && (qbr || qclose > qopen)) mk = mk "x"
    if (long) {
        lm = wb ? mk : ""
        if (wa) lm = lm "a"
        if (lm != "") printf "m%s%s", lm, US
        printf "w"
        for (i = 1; i <= ln; i++) printf "%s", lk[i]
        printf "%s%s", lc, US
        return
    }
    if (wa) mk = mk "a"
    if (mk != "") printf "m%s%s", mk, US
    printf "%s%s%s", (classify && mk == "" && plain(buf)) ? "p" : "w", buf, US
}
function dangling() {
    if (pend != "") { printf "r%s %s", pend, US; pend = "" }
}
function sep(t) {
    end_word(); dangling()
    printf "%s%s", t, US
}
BEGIN {
    US = sprintf("%c", 31); SENT = sprintf("%c", 30); MAXB = 256; pelo = -1; pehi = -1
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
            if (c == "\\") { wa = 1; add(c); add(ch[i + 1]); i++ }
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
            else {
                if (c == "$" && ch[i + 1] == "{") {
                    j = i + 2
                    while (ch[j] ~ /^[A-Za-z0-9_]$/) j++
                    if (j > i + 2 && ch[j] == "}") { pelo = i + 1; pehi = j }
                }
                add(c, c == "$" && ch[i + 1] != "\"", i == pelo || i == pehi)
            }
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
        begin_word(); add(c, 1)
    }
    end_word(); dangling()
    printf "%s", SENT
}'

# shell_words <cmd> [<names> <fragments>]: split <cmd> into words as bash and zsh would, expanding nothing. Sets
# SW_WORDS to its elements in order: w<word> (quotes and escapes removed; $(…) and backticks inside "…" stay text),
# r<op> <target> (a redirection: the operator as written with any fd prefix, one space, then the target word), | (a
# pipe, | or |&) and ; (any other separator: ; & && || newline ( ), and <( or >( ). $'…' keeps its content undecoded.
# # does not start a comment: zsh honours one only under INTERACTIVE_COMMENTS, so its text is screened as words.
# m<flags> directly precedes the w element of a word of at most 256 characters (or of more, if it holds a {), other
# than a redirection target, whose glob characters (g: * ? [ {) or $ (d) are all quoted or escaped, none live (unquoted
# and unescaped; a $ inside "…" is live unless escaped or last before the closing quote); q: a quoted $ and a live one
# both; x: a word with a live { in which a { or } is quoted or escaped, or a quoted or escaped character lies between
# its first live { and last live } (so the unquoted text may not brace-expand as the shell does); a: a $'…' part holds a
# backslash, which stays as written (the word of any length gets it); flags in the order g, d, q, x, a. A marked word
# is never p. A consumer that does not read m skips it.
# Parameters, ~, braces and globs stay as written. Given <names> (space-separated lower-case words) and <fragments> (a
# lower-case awk regex), a word of at most 256 characters becomes p<word> instead when it is plain: not empty, no $ = :
# * ? [ and no non-ASCII byte, not a single-dash option, "/<word>" lower-cased not matching <fragments>, and its
# basename lower-cased not in <names> (a case-insensitive file system runs CAT as cat), nor its leading letters when
# the rest is a version (python3.12, gpg2). Sets SW_OK=1, or
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

# norm_path <path> <cwd> [literal]: set NORM_PATH to <path> made absolute against <cwd>, with a leading ~ or ~/
# expanded (and, unless literal, a leading $HOME or ${HOME}), . and .. segments collapsed lexically and repeated or
# trailing slashes dropped. Returns 1, with NORM_PATH empty, when <path> starts ~user or, unless literal, holds any
# other $: the hook cannot resolve it. The path is split once and the result built as a string, so the cost is linear
# in its length: cutting one segment at a time copies the rest of the path for each.
# shellcheck disable=SC2034  # NORM_PATH is read by the calling hook
norm_path() {
    local p="$1" seg out="" nf=0 IFS=/
    local -a parts=()
    # shellcheck disable=SC2088  # a literal ~ prefix is matched here, then expanded by hand
    case "$p" in
        '~') p="$HOME" ;;
        '~/'*) p="$HOME/${p:2}" ;;
        '~'*) NORM_PATH=""; return 1 ;;
    esac
    if [[ "${3:-}" != literal ]]; then
        case "$p" in
            '$HOME'|'${HOME}') p="$HOME" ;;
            '$HOME/'*) p="$HOME/${p:6}" ;;
            '${HOME}/'*) p="$HOME/${p:8}" ;;
        esac
        if [[ "$p" == *'$'* ]]; then
            NORM_PATH=""
            return 1
        fi
    fi
    if [[ "$p" != /* ]]; then
        p="$2/$p"
    fi
    if [[ "$-" == *f* ]]; then
        nf=1
    fi
    set -f
    # shellcheck disable=SC2206  # split on / with pathname expansion off
    parts=($p)
    if (( ! nf )); then
        set +f
    fi
    for seg in ${parts[@]+"${parts[@]}"}; do
        case "$seg" in
            ''|.) ;;
            ..) out="${out%/*}" ;;
            *) out+="/$seg" ;;
        esac
    done
    NORM_PATH="${out:-/}"
}

# probe_root_too_wide <abs>: 0 if the normalised absolute path <abs> is /, $HOME or an ancestor of it, or an ancestor of
# the secret vault (/tmp/claude-<id>-vault, under /tmp and /private/tmp): a recursive read there reaches ~/.aws, ~/.ssh
# or the vault, so it is denied without listing.
# shellcheck disable=SC2194  # the fixed vault path is the subject and the root the pattern
probe_root_too_wide() {
    if [[ "$1" == / ]]; then
        return 0
    fi
    case "$HOME/" in "$1"/*) return 0 ;; esac
    case /tmp/claude-x-vault/ in "$1"/*) return 0 ;; esac
    case /private/tmp/claude-x-vault/ in "$1"/*) return 0 ;; esac
    return 1
}

# glob_quote <path>: set GLOB_QUOTED to <path> with each \ * ? [ escaped, so a pathname expansion reads it literally.
# shellcheck disable=SC2034  # GLOB_QUOTED is read by the calling hook
glob_quote() {
    local s="${1//\\/\\\\}"
    s="${s//\*/\\*}"
    s="${s//\?/\\?}"
    GLOB_QUOTED="${s//\[/\\[}"
}

# probe_glob_plain <glob>: 0 if <glob> is a plain name glob: ASCII letters, digits and . _ - * ? only. The tools the
# probe models (rg, the grep family) split, anchor or match /, **, braces, brackets and ! in ways bash's pattern
# matching does not, so only a plain glob may narrow a probe: matched in bash, any other could drop a file the tool
# reads.
probe_glob_plain() {
    case "$1" in
        ''|*[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._*?-]*) return 1 ;;
    esac
    return 0
}

# The directory probe: a content-printing recursive read is denied when its root holds a secret file. Every root of one
# hook run is listed by one pipeline, filtered in one awk pass and bounded: it stops after PROBE_MAX_ENTRIES entries,
# and a background watchdog kills it at the run-wide deadline (hook_bounded; a hook that times out does not block).
# Callers source secret-patterns.sh, which supplies the regexes.
PROBE_MAX_ENTRIES=100000
PROBE_MAX_ROOTS=64
PROBE_MAX_HITS=50
PROBE_WATCHDOG_S=1

# probe_reset: forget every probe root.
probe_reset() {
    PROBE_N=0
    PROBE_KIND=()
    PROBE_ROOT=()
    PROBE_FORM=()
    PROBE_INC=()
    PROBE_EXC=()
    PROBE_XDIR=()
    _PROBE_KEYS=$'\x1e'
}
probe_reset

# probe_add <kind> <root> <form> [<include> <exclude> <exclude-dir>]: add the absolute directory <root>, listed by
# <kind>: git (git ls-files -co --exclude-standard in a work tree, with nested repositories and submodules listed in
# full, else find), tracked (git ls-files in a work tree, else find), find, findL (find -L), or a rev kind (a
# revision's tree, listed by git ls-tree; see _dhs_rev). <form> names the reader in a decision. The glob lists
# (\x1f-separated bash patterns) narrow the hits; a glob holding { is ignored. A repeated entry is ignored; returns 1
# once PROBE_MAX_ROOTS are held.
# shellcheck disable=SC2034  # PROBE_FORM is read by the calling hook
probe_add() {
    local key="$1"$'\x1f'"$2"$'\x1f'"${4:-}"$'\x1f'"${5:-}"$'\x1f'"${6:-}"
    if [[ "$_PROBE_KEYS" == *$'\x1e'"$key"$'\x1e'* ]]; then
        return 0
    fi
    if (( PROBE_N >= PROBE_MAX_ROOTS )); then
        return 1
    fi
    _PROBE_KEYS+="$key"$'\x1e'
    PROBE_KIND[PROBE_N]="$1"
    PROBE_ROOT[PROBE_N]="$2"
    PROBE_FORM[PROBE_N]="$3"
    PROBE_INC[PROBE_N]="${4:-}"
    PROBE_EXC[PROBE_N]="${5:-}"
    PROBE_XDIR[PROBE_N]="${6:-}"
    PROBE_N=$(( PROBE_N + 1 ))
}

# _dhs_find <root> [-L]: list every entry under <root>, relative to it, except a directory named secrets (whose files
# the secret globs match themselves), skipping .git and node_modules.
_dhs_find() {
    cd "$1" || return 1
    command find ${2:+"$2"} . \( -name .git -o -name node_modules \) -prune -o \( -type d -iname secrets \) -o -print
}

# _dhs_git <root> <ls-files option>...: list the work tree's files under <root>, one per line, and return git's status,
# or tr's when git's is 0. The list is read NUL-separated: git C-quotes a name holding " \ or a control character in its
# line form whatever core.quotepath says, and a quoted name matches no glob. tr runs in the C locale, as a UTF-8 tr
# stops at a name that is not valid UTF-8; any tr failure still reads as a failed listing.
_dhs_git() {
    local r="$1"
    local -a ps=()
    shift
    if git -C "$r" ls-files -z "$@" | LC_ALL=C tr '\0' '\n'; then
        ps=("${PIPESTATUS[@]}")
    else
        ps=("${PIPESTATUS[@]}")
    fi
    if [[ "${ps[0]}" != 0 ]]; then
        return "${ps[0]}"
    fi
    return "${ps[1]}"
}

# _dhs_rev <kind>: list, relative to it, every file of a revision's tree; <kind> is rev, the directory git runs in, the
# revision and the path of the tree from that directory, \x1d-separated. Returns git's status, or tr's when git's is 0.
# --full-tree: below the repository root, ls-tree would also filter the tree <dir>:./<path> names by the cwd prefix.
_dhs_rev() {
    local s="${1#rev$'\x1d'}" d rv p
    local -a ps=()
    d="${s%%$'\x1d'*}"
    s="${s#*$'\x1d'}"
    rv="${s%%$'\x1d'*}"
    p="${s#*$'\x1d'}"
    if git -C "$d" ls-tree --full-tree -r -z --name-only "$rv^{commit}:./$p" | LC_ALL=C tr '\0' '\n'; then
        ps=("${PIPESTATUS[@]}")
    else
        ps=("${PIPESTATUS[@]}")
    fi
    if [[ "${ps[0]}" != 0 ]]; then
        return "${ps[0]}"
    fi
    return "${ps[1]}"
}

# _dhs_nested <root>: list in full each untracked nested repository (git prints one dir/ entry) and each submodule (one
# gitlink entry) under the work tree <root>, as rg descends into both. Return 1 if any listing step fails or a reported
# path is not a directory.
_dhs_nested() {
    local r="$1" d dirs seen=$'\n' rc=0
    dirs=$(
        set -o pipefail
        git -C "$r" ls-files -z -co --exclude-standard | LC_ALL=C tr '\0' '\n' | LC_ALL=C awk '/\/$/' || exit 1
        git -C "$r" ls-files -z -s | LC_ALL=C tr '\0' '\n' \
            | LC_ALL=C awk 'index($0, "160000 ") == 1 { sub(/^[^\t]*\t/, ""); print }' || exit 1
    ) || return 1
    while IFS= read -r d; do
        d="${d%/}"
        case "$seen" in *$'\n'"$d"$'\n'*) continue ;; esac
        seen+="$d"$'\n'
        if [[ -z "$d" ]]; then
            continue
        elif [[ -d "$r/$d" ]]; then
            (cd "$r" && command find "./$d" \( -name .git -o -name node_modules \) -prune -o \
                \( -type d -iname secrets \) -o -print) || rc=1
        else
            rc=1
        fi
    done <<<"$dirs"
    return "$rc"
}

# _dhs_list: the default lister. For each probe root print \002<index>\t<root>, then its entries, then \003<status>.
_dhs_list() {
    local i=0 rc k r
    while (( i < PROBE_N )); do
        k="${PROBE_KIND[i]}"
        r="${PROBE_ROOT[i]}"
        printf '\002%s\t%s\n' "$i" "$r"
        rc=0
        case "$k" in
            git|tracked)
                if [[ "$(git -C "$r" rev-parse --is-inside-work-tree 2>/dev/null)" != true ]]; then
                    _dhs_find "$r" || rc=$?
                elif [[ "$k" == git ]]; then
                    _dhs_git "$r" -co --exclude-standard || rc=$?
                    if ! _dhs_nested "$r" && (( rc == 0 )); then
                        rc=1
                    fi
                else
                    _dhs_git "$r" --cached || rc=$?
                fi ;;
            findL) _dhs_find "$r" -L || rc=$? ;;
            rev$'\x1d'*) _dhs_rev "$k" || rc=$? ;;
            *) _dhs_find "$r" || rc=$? ;;
        esac
        printf '\003%s\n' "$rc"
        i=$(( i + 1 ))
    done
}

# The probe's filter. A \002<i>\t<root> line starts root <i>, a \003<status> line ends it, and any other line is an
# entry relative to the root (a leading ./ dropped), or a full path when no root has started. Each entry is folded (the
# _NAME_FOLDS letters, then ASCII case) and tested as "/<path>" against the secret and allow regexes, which is
# path_is_secret's rule. Prints H<i>\t<path> per hit, up to maxh; then C if the cap stopped it, F if a lister failed,
# and E<entries> last. With fin set, E is printed only when the last line was a lone \004, the end marker of a producer
# that may be killed part way: its cut output then reads as unfinished.
_DHS_AWK='
BEGIN { US = sprintf("%c", 31); nf = split(folds, F, US); idx = -1; pre = "" }
fin && $0 == "\004" { done = 1; next }
substr($0, 1, 1) == "\002" {
    t = substr($0, 2); i = index(t, "\t"); idx = substr(t, 1, i - 1); pre = substr(t, i + 1); next
}
substr($0, 1, 1) == "\003" { if (substr($0, 2) != "0") failed = 1; next }
{
    done = 0
    if (++n > cap) { capped = 1; exit }
    p = $0
    if (substr(p, 1, 2) == "./") p = substr(p, 3)
    if (pre != "") p = pre "/" p
    t = p
    if (t ~ /[\200-\377]/) for (j = 1; j < nf; j += 2) gsub(F[j], F[j + 1], t)
    t = tolower("/" t)
    if (t ~ sre && t !~ are) {
        print "H" idx "\t" p
        if (++hits >= maxh) exit
    }
}
END {
    if (capped) print "C"
    else if (failed) print "F"
    if (!fin || done) print "E" n + 0
}'

# _dhs_glob <glob> <rel>: 0 if <glob> matches the relative path <rel> as grep and rg match one: against the basename
# when the glob has no /, else against the whole path, a leading **/ also matching at the top.
_dhs_glob() {
    # shellcheck disable=SC2053  # the glob is a pattern
    if [[ "$1" != */* ]]; then
        [[ "${2##*/}" == $1 ]]
    else
        [[ "$2" == $1 ]] || { [[ "$1" == '**/'* ]] && [[ "$2" == ${1#'**/'} ]]; }
    fi
}

# _dhs_keep <index> <path>: 0 unless root <index>'s narrowing drops <path>: an include list none of whose globs it
# matches, an exclude glob it matches, or an exclude-dir glob that one of its directories matches.
_dhs_keep() {
    local inc="${PROBE_INC[$1]}" exc="${PROBE_EXC[$1]}" xd="${PROBE_XDIR[$1]}" rel g d ok=0
    rel="${2#"${PROBE_ROOT[$1]}"/}"
    if [[ -n "$inc" ]]; then
        while [[ -n "$inc" ]]; do
            g="${inc%%$'\x1f'*}"
            if [[ "$inc" == *$'\x1f'* ]]; then inc="${inc#*$'\x1f'}"; else inc=""; fi
            if [[ "$g" == *'{'* ]] || _dhs_glob "$g" "$rel"; then
                ok=1
                break
            fi
        done
        if (( ! ok )); then
            return 1
        fi
    fi
    while [[ -n "$exc" ]]; do
        g="${exc%%$'\x1f'*}"
        if [[ "$exc" == *$'\x1f'* ]]; then exc="${exc#*$'\x1f'}"; else exc=""; fi
        if [[ -n "$g" && "$g" != *'{'* ]] && _dhs_glob "$g" "$rel"; then
            return 1
        fi
    done
    while [[ -n "$xd" ]]; do
        g="${xd%%$'\x1f'*}"
        if [[ "$xd" == *$'\x1f'* ]]; then xd="${xd#*$'\x1f'}"; else xd=""; fi
        if [[ -z "$g" || "$g" == *'{'* || "$rel" != */* ]]; then
            continue
        fi
        d="${rel%/*}"
        while [[ -n "$d" ]]; do
            # shellcheck disable=SC2053  # the glob is a pattern
            if [[ "${d##*/}" == $g ]]; then
                return 1
            fi
            if [[ "$d" == */* ]]; then d="${d%/*}"; else d=""; fi
        done
    done
    return 0
}

# _dhs_run <lister>: the probe's pipeline, the lister's output filtered by _DHS_AWK.
_dhs_run() {
    set +o pipefail
    "$1" 2>/dev/null </dev/null | LC_ALL=C awk -v cap="$PROBE_MAX_ENTRIES" -v maxh="$PROBE_MAX_HITS" \
        -v sre="$SECRET_PATH_AWK_RE" -v are="$SECRET_ALLOW_AWK_RE" -v folds="$SECRET_FOLDS_AWK" "$_DHS_AWK"
}

# dir_holds_secret [<lister>]: list every probe root with <lister> (default _dhs_list) in one bounded pipeline. Returns
# 0 when a root holds a secret file its narrowing keeps, setting DHS_HITS (up to three paths, comma-separated) and
# DHS_IDX (the first hit's root); 1 when none does; 2 when the listing is inconclusive, setting DHS_WHY to the reason.
# shellcheck disable=SC2034  # DHS_WHY is read by the calling hook
dir_holds_secret() {
    local lister="${1:-_dhs_list}" out line i path n=0 capped=0 failed=0 finished=0 hits=0
    DHS_HITS=""
    DHS_IDX=""
    DHS_WHY=""
    if (( PROBE_N == 0 )); then
        return 1
    fi
    if ! out=$(mktemp "${TMPDIR:-/tmp}/claude-probe.XXXXXX" 2>/dev/null); then
        DHS_WHY="no scratch file could be made"
        return 2
    fi
    if ! hook_bounded "$out" _dhs_run "$lister"; then
        rm -f "$out"
        DHS_WHY="the hook ran out of time before listing it"
        return 2
    fi
    while IFS= read -r line; do
        case "$line" in
            H*)
                n=$(( n + 1 ))
                i="${line:1}"
                i="${i%%$'\t'*}"
                path="${line#*$'\t'}"
                if _dhs_keep "$i" "$path"; then
                    if (( hits < 3 )); then
                        DHS_HITS+="${DHS_HITS:+, }$path"
                    fi
                    if [[ -z "$DHS_IDX" ]]; then
                        DHS_IDX="$i"
                    fi
                    hits=$(( hits + 1 ))
                fi ;;
            C) capped=1 ;;
            F) failed=1 ;;
            E*) finished=1 ;;
        esac
    done <"$out"
    rm -f "$out"
    if (( hits > 0 )); then
        return 0
    fi
    if (( ! finished )); then
        DHS_WHY="it could not be listed in the time the hook has"
    elif (( capped )); then
        DHS_WHY="it holds more than $PROBE_MAX_ENTRIES entries"
    elif (( n >= PROBE_MAX_HITS )); then
        DHS_WHY="it holds more secret-named files than the narrowing can check"
    elif (( failed )); then
        DHS_WHY="part of it could not be listed"
    else
        return 1
    fi
    return 2
}

# _wh_run <pattern>: expand the absolute <pattern>, then write the end marker, through _DHS_AWK.
_wh_run() {
    set +o pipefail
    { compgen -G "$1" 2>/dev/null; printf '\004\n'; } | LC_ALL=C awk -v cap="$PROBE_MAX_ENTRIES" -v maxh=1 -v fin=1 \
        -v sre="$SECRET_PATH_AWK_RE" -v are="$SECRET_ALLOW_AWK_RE" -v folds="$SECRET_FOLDS_AWK" "$_DHS_AWK"
}

# wild_holds_secret <pattern>: expand <pattern> (an absolute path glob whose directory part glob_quote escaped) and test
# every match as the probe tests an entry, bounded by the run-wide deadline (hook_bounded). Returns 0 with WH_HIT the
# first secret match, 1 if none, 2 past PROBE_MAX_ENTRIES, 3 when it could not be expanded in time.
# shellcheck disable=SC2034  # WH_HIT is read by the calling hook
wild_holds_secret() {
    local out line rc=0
    WH_HIT=""
    hook_time_left
    if (( HOOK_LEFT_MS <= 0 )) || ! out=$(mktemp "${TMPDIR:-/tmp}/claude-wild.XXXXXX" 2>/dev/null); then
        return 3
    fi
    hook_bounded "$out" _wh_run "$1" || rc=$?
    if (( rc == 0 )); then
        rc=3
        while IFS= read -r line; do
            case "$line" in
                H*) WH_HIT="${line#*$'\t'}"; rc=0; break ;;
                C) rc=2; break ;;
                E*) rc=1 ;;
            esac
        done <"$out"
    fi
    rm -f "$out"
    return "$rc"
}

# _glob_run <pattern>: expand <pattern> and write the end marker after it, in one process, keeping the first 65 lines.
_glob_run() {
    set +o pipefail
    { compgen -G "$1" 2>/dev/null; printf '\004\n'; } | head -n 65
}

# glob_dirs <pattern>: set GLOB_DIRS to the newline-separated matches of <pattern> (one ending in /, so directories),
# bounded by the run-wide deadline (hook_bounded): all of them, or 65 when there are more. Returns 0, or 3 when it could
# not be expanded in time. 65 lines with no end marker are 65 matches, whether more were cut or never printed.
# shellcheck disable=SC2034  # GLOB_DIRS is read by the calling hook
glob_dirs() {
    local out rc=0 m="" rest n=0
    GLOB_DIRS=""
    hook_time_left
    if (( HOOK_LEFT_MS <= 0 )) || ! out=$(mktemp "${TMPDIR:-/tmp}/claude-glob.XXXXXX" 2>/dev/null); then
        return 3
    fi
    hook_bounded "$out" _glob_run "$1" || rc=$?
    if (( rc == 0 )); then
        IFS= read -r -d '' m <"$out" || :
        rest="$m"
        while (( n < 65 )) && [[ "$rest" == *$'\n'* ]]; do
            rest="${rest#*$'\n'}"
            n=$(( n + 1 ))
        done
        if [[ "$m" == *$'\004\n' ]]; then
            m="${m%$'\004\n'}"
            GLOB_DIRS="${m%$'\n'}"
        elif (( n >= 65 )); then
            GLOB_DIRS="${m%$'\n'}"
        else
            rc=3
        fi
    fi
    rm -f "$out"
    return "$rc"
}
