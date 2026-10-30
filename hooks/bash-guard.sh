#!/usr/bin/env bash
# bash-guard.sh — PreToolUse hook for Bash calls
# Denies commands that violate CLAUDE.md Bash rules:
#   1. Lists (; && || newline), except as list_check admits them (_lib.sh), and a lone &
#   2. Command substitution: $(...) or backticks, including inside double quotes
#   3. Process substitution: <(...) or >(...)
#   4. Control-flow loops (for/while/until) and case statements
#   5. Temp-directory write policy, judged on each list part
#   6. Subshells and grouping: an unquoted ( (also a zsh glob qualifier or extglob, by intent)
#
# The documented git-commit heredoc message is removed first (strip_commit_heredoc), and so is the body of a
# quoted-delimiter cat or tee heredoc that writes a file (strip_text_heredoc) and of a quoted-delimiter heredoc fed to
# Python (script_heredoc_parse, its body Python code, not shell): the sanctioned exemptions, each only as the
# command's last part. A cat heredoc is not a read-only cat for the temp-write rule below, and the carve-out excludes
# a generated file (a hydrated output or a Claude Code settings.json) as its target. The syntax checks then run on a
# quote-aware skeleton of the command (shell_scan): operators inside string literals are ignored, but nothing outside
# them is hidden. A backslash-newline continuation, a newline inside quotes and an escaped ; & or | read as text, but
# only in a command with no unquoted, unescaped # (a comment can hide what bash reads as a separator).

set -euo pipefail
source "$(dirname "$0")/_lib.sh"
hook_backstop deny "bash-guard failed to evaluate; the command is denied. Retry it or simplify it."
hook_read_input

cmd=$(hook_field '.tool_input.command')
if [[ -z "$cmd" ]]; then
    hook_pass
fi

checked=$(strip_commit_heredoc "$cmd")
text_heredoc_parse "$checked"
text_checked="$TEXT_HEREDOC_OUT"
text_heredoc=0
if [[ "$text_checked" != "$checked" ]]; then
    text_heredoc=1
fi
checked="$text_checked"
script_heredoc=0
if (( ! text_heredoc )); then
    script_heredoc_parse "$checked"
    if [[ "$SCRIPT_HEREDOC_OUT" != "$checked" ]]; then
        script_heredoc=1
    fi
    checked="$SCRIPT_HEREDOC_OUT"
fi

# A text heredoc that writes a generated file goes through Edit or Write, where the edit guards decide.
if (( text_heredoc )); then
    hd_cwd=$(hook_field '.cwd')
    for hd_tgt in ${TEXT_HEREDOC_TARGETS[@]+"${TEXT_HEREDOC_TARGETS[@]}"}; do
        # shellcheck disable=SC2088  # matching a literal, unexpanded ~ as the command carries it
        if [[ "$hd_tgt" == "~" ]]; then
            hd_abs="$HOME"
        elif [[ "$hd_tgt" == "~/"* ]]; then
            hd_abs="$HOME/${hd_tgt#"~/"}"
        elif [[ "$hd_tgt" == /* ]]; then
            hd_abs="$hd_tgt"
        else
            hd_abs="${hd_cwd:-$PWD}/$hd_tgt"
        fi
        hd_norm=$(normalise_path "$hd_abs")
        hd_res=$(resolve_path "$hd_norm")
        if [[ "$hd_norm" == */.claude/settings.json || "$hd_res" == */.claude/settings.json ]]; then
            msg="GENERATED FILE: '$hd_tgt' is a Claude Code settings.json, generated from settings.json.tmpl; a Bash"
            msg+=" heredoc write skips its edit check. Write it with Edit or Write, which ask, or edit"
            msg+=" settings.json.tmpl and run scripts/apply-settings.sh."
            hook_deny "$msg"
        fi
        if hydrated_output_tmpl "$hd_abs"; then
            msg="HYDRATED OUTPUT: '$hd_tgt' is generated from '$HYDRATED_TMPL' by hydrate.sh, so a heredoc write is"
            msg+=" lost or reverted. Edit '$HYDRATED_TMPL' with Edit or Write instead, then run that repo's hydrate.sh."
            hook_deny "$msg"
        fi
    done
fi
shell_scan "$checked"
stripped="$SHELL_SKELETON"
scan_flags="$SHELL_SCAN_FLAGS"
list_check "$checked"

# ── Temp directory enforcement ──
# Block $TMPDIR / /var/folders/ unconditionally. Block bare /tmp/ writes (must use $CLAUDE_TEMP_DIR).
# Session-scoped /tmp/claude-* paths are exempt from temp-write policy, but DO fall through
# to the syntax checks below — referencing a session temp path must not bypass other rules.
# Each list part is judged on its own text, exemptions included, and any part failing denies the command; the text
# heredoc, when stripped, is the last part. A stripped Python heredoc's body is judged with its part, as python3 -c's
# code is.
#
# Carve-out: code-review ephemeral worktrees (…/review-worktrees/wt-…) may land under
# /var/folders/ when no session temp dir can be resolved (e.g. the standalone /shakedown
# path). Commands operating on such a worktree are legitimate and must not be denied by the
# unconditional /var/folders/ block below — otherwise the worktree is unusable and teardown
# falls back to an in-place delete. They still fall through to the syntax checks. Any other
# /var/folders/ or $TMPDIR reference remains blocked.
ro_re='^(cat|ls|head|tail|wc|file|stat|diff|less|more|grep|rg|find|readlink)[[:space:]]'
temp_write_msg="TEMP DIRECTORY VIOLATION: Use \$CLAUDE_TEMP_DIR for writing to temp."
temp_write_msg+=" See CLAUDE.md 'Temporary Files' section."
part_n=0
for part in ${LIST_PART_TEXT[@]+"${LIST_PART_TEXT[@]}"}; do
    part_n=$(( part_n + 1 ))
    if (( script_heredoc && part_n == LIST_PARTS )); then
        part+=$'\n'"$SCRIPT_HEREDOC_BODY"
    fi
    if ! mentions_temp_path "$part" || cmd_mentions_review_worktree "$part"; then
        continue
    fi
    ro=0
    jq_first=0
    pat_first=0
    if (( text_heredoc && part_n == LIST_PARTS )); then
        :
    elif [[ "$part" =~ $ro_re ]]; then
        ro=1
    elif [[ "$part" =~ ^jq[[:space:]] ]]; then
        jq_first=1
    fi
    if [[ "$part" =~ ^(grep|rg|jq)[[:space:]] ]]; then
        pat_first=1
    fi
    # A single-quoted /var/folders/ or /tmp/ is a search pattern, a filter string or a file operand it reads, not a
    # write, only for a pattern or filter tool (grep, rg, jq) that is the whole part: no output redirection and no
    # pipe in the part's quote-aware skeleton. rg also needs a strict shape (plain options, single-quoted literals and
    # plain paths, no --pre or --hostname-bin, which run a program). Every other part is tested on its full text.
    sq_text="$part"
    sq_ok=0
    if (( pat_first )); then
        part_skel="$stripped"
        if [[ "$part" != "$checked" ]]; then
            shell_scan "$part"
            part_skel="$SHELL_SKELETON"
        fi
        if [[ "$part_skel" != *'>'* && "$part_skel" != *'|'* ]]; then
            sq_ok=1
        fi
    fi
    if (( sq_ok )) && [[ "$part" =~ ^rg[[:space:]] ]] && ! rg_plain_shape "$part"; then
        sq_ok=0
    fi
    if (( sq_ok )); then
        sq_strip "$part"
        sq_text="$SQ_STRIPPED"
    fi
    if [[ "$part" == *'$TMPDIR'* || "$sq_text" == */var/folders/* ]]; then
        hook_deny "TEMP DIRECTORY VIOLATION: Use \$CLAUDE_TEMP_DIR instead of \$TMPDIR or /var/folders/. See CLAUDE.md 'Temporary Files' section."
    fi
    if ! cmd_mentions_session_temp "$part"; then
        # Allow read-only commands against bare /tmp/, deny anything else writing there; jq is judged on its
        # unquoted text, so a redirection or operand into /tmp/ still denies.
        if (( jq_first )); then
            if mentions_temp_path "$sq_text"; then
                hook_deny "$temp_write_msg"
            fi
        elif (( ! ro )); then
            hook_deny "$temp_write_msg"
        fi
    fi
done

warnings=""

if [[ "$scan_flags" == *E* ]]; then
    warnings="${warnings}  - command could not be scanned (over ${SHELL_SCAN_MAX_CHARS} characters,"
    warnings="${warnings} or the quote scanner failed; put long content in a file)\n"
fi
if [[ "$scan_flags" == *S* ]]; then
    warnings="${warnings}  - command substitution inside double quotes detected (use separate Bash calls, or"
    warnings="${warnings} git commit -F <file> for a commit message)\n"
fi
if [[ "$scan_flags" == *U* ]]; then
    warnings="${warnings}  - unterminated or ambiguous quote detected\n"
fi
if [[ "$scan_flags" == *P* ]]; then
    warnings="${warnings}  - subshell or grouping '(...)' detected (use separate Bash calls)\n"
fi

# A ; && || or newline list the shared contract does not admit; printed with %b, so its backslashes are doubled.
if [[ -n "$LIST_REASON" ]]; then
    warnings="${warnings}  - ${LIST_REASON//\\/\\\\}\n"
fi

# Check for a lone & (backgrounds the left side and starts the next command). Excludes && and
# the redirections >&, <&, &> and &>>.
bg_re='(^|[^&<>])&([^&>]|$)'
if [[ "$stripped" =~ $bg_re ]]; then
    warnings="${warnings}  - background operator '&' detected (use separate Bash calls)\n"
fi

# Check for $(...) command substitution
if [[ "$stripped" == *'$('* ]]; then
    warnings="${warnings}  - command substitution '\$(...)' detected (capture output from separate Bash calls)\n"
fi

# Check for <(...) or >(...) process substitution
if [[ "$stripped" == *'<('* || "$stripped" == *'>('* ]]; then
    warnings="${warnings}  - process substitution '<(...)'/'>(...)' detected (capture output from separate Bash calls)\n"
fi

# Check for backtick command substitution
if [[ "$stripped" == *'`'* ]]; then
    warnings="${warnings}  - backtick command substitution detected (capture output from separate Bash calls)\n"
fi

# Check for control-flow loops: for/while/until ... do
if [[ "$stripped" =~ (^|[[:space:]])(for|while|until)[[:space:]] ]] \
   && [[ "$stripped" =~ [[:space:]]do([[:space:]]|$) ]]; then
    warnings="${warnings}  - control-flow loop detected (unroll into separate Bash calls or use the Write tool)\n"
fi

# Check for case statements: case ... in
if [[ "$stripped" =~ (^|[[:space:]])case[[:space:]] ]] \
   && [[ "$stripped" =~ [[:space:]]in([[:space:]]|$) ]]; then
    warnings="${warnings}  - control-flow 'case' detected (unroll into separate Bash calls)\n"
fi

if [[ -n "$warnings" ]]; then
    if [[ "${stripped//<<</}" == *'<<'* ]]; then
        # shellcheck disable=SC2034  # read by hook_deny
        HOOK_DENY_NOTE="$HEREDOC_DENY_NOTE"
    fi
    msg=$(printf "CLAUDE.md VIOLATION (Bash rules):\n%bRewrite as separate Bash tool calls." "$warnings")
    hook_deny "$msg"
fi

hook_pass
