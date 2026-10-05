#!/usr/bin/env bash
# bash-guard.sh — PreToolUse hook for Bash calls
# Denies commands that violate CLAUDE.md Bash rules:
#   1. Compound operators: && || ; a lone & or newline separators
#   2. Command substitution: $(...) or backticks, including inside double quotes
#   3. Process substitution: <(...) or >(...)
#   4. Control-flow loops (for/while/until) and case statements
#   5. Temp-directory write policy
#   6. Subshells and grouping: an unquoted ( (also a zsh glob qualifier or extglob, by intent)
#
# The documented git-commit heredoc message is removed first (strip_commit_heredoc, the one
# sanctioned exemption). The syntax checks then run on a quote-aware skeleton of the command
# (shell_scan): operators inside string literals are ignored, but nothing outside them is hidden.

set -euo pipefail
source "$(dirname "$0")/_lib.sh"
hook_backstop deny "bash-guard failed to evaluate; the command is denied. Retry it or simplify it."
hook_read_input

cmd=$(hook_field '.tool_input.command')
if [[ -z "$cmd" ]]; then
    hook_pass
fi

checked=$(strip_commit_heredoc "$cmd")

# ── Temp directory enforcement ──
# Block $TMPDIR / /var/folders/ unconditionally. Block bare /tmp/ writes (must use $CLAUDE_TEMP_DIR).
# Session-scoped /tmp/claude-* paths are exempt from temp-write policy, but DO fall through
# to the syntax checks below — referencing a session temp path must not bypass other rules.
#
# Carve-out: code-review ephemeral worktrees (…/review-worktrees/wt-…) may land under
# /var/folders/ when no session temp dir can be resolved (e.g. the standalone /shakedown
# path). Commands operating on such a worktree are legitimate and must not be denied by the
# unconditional /var/folders/ block below — otherwise the worktree is unusable and teardown
# falls back to an in-place delete. They still fall through to the syntax checks. Any other
# /var/folders/ or $TMPDIR reference remains blocked.
if mentions_temp_path "$checked" && ! cmd_mentions_review_worktree "$checked"; then
    if [[ "$checked" == *'$TMPDIR'* || "$checked" == */var/folders/* ]]; then
        hook_deny "TEMP DIRECTORY VIOLATION: Use \$CLAUDE_TEMP_DIR instead of \$TMPDIR or /var/folders/. See CLAUDE.md 'Temporary Files' section."
    fi
    if ! cmd_mentions_session_temp "$checked"; then
        # Allow read-only commands against bare /tmp/, deny anything else writing there
        if ! [[ "$checked" =~ ^(cat|ls|head|tail|wc|file|stat|diff|less|more|grep|rg|find|readlink)[[:space:]] ]]; then
            hook_deny "TEMP DIRECTORY VIOLATION: Use \$CLAUDE_TEMP_DIR for writing to temp. See CLAUDE.md 'Temporary Files' section."
        fi
    fi
fi

shell_scan "$checked"
stripped="$SHELL_SKELETON"

warnings=""

if [[ "$SHELL_SCAN_FLAGS" == *E* ]]; then
    warnings="${warnings}  - command could not be scanned (over ${SHELL_SCAN_MAX_CHARS} characters,"
    warnings="${warnings} or the quote scanner failed; put long content in a file)\n"
fi
if [[ "$SHELL_SCAN_FLAGS" == *S* ]]; then
    warnings="${warnings}  - command substitution inside double quotes detected (use separate Bash calls, or"
    warnings="${warnings} git commit -F <file> for a commit message)\n"
fi
if [[ "$SHELL_SCAN_FLAGS" == *U* ]]; then
    warnings="${warnings}  - unterminated quote detected\n"
fi
if [[ "$SHELL_SCAN_FLAGS" == *P* ]]; then
    warnings="${warnings}  - subshell or grouping '(...)' detected (use separate Bash calls)\n"
fi

# Check for &&
if [[ "$stripped" == *'&&'* ]]; then
    warnings="${warnings}  - compound operator '&&' detected (use separate Bash calls)\n"
fi

# Check for ||
if [[ "$stripped" == *'||'* ]]; then
    warnings="${warnings}  - compound operator '||' detected (use separate Bash calls)\n"
fi

# Check for ;
if [[ "$stripped" == *';'* ]]; then
    warnings="${warnings}  - compound operator ';' detected (use separate Bash calls)\n"
fi

# Check for a lone & (backgrounds the left side and starts the next command). Excludes && and
# the redirections >&, <&, &> and &>>.
bg_re='(^|[^&<>])&([^&>]|$)'
if [[ "$stripped" =~ $bg_re ]]; then
    warnings="${warnings}  - background operator '&' detected (use separate Bash calls)\n"
fi

# Check for newline command separators (functionally equivalent to ;)
if [[ "$stripped" == *$'\n'* ]]; then
    warnings="${warnings}  - newline command separator detected (use separate Bash calls)\n"
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
    msg=$(printf "CLAUDE.md VIOLATION (Bash rules):\n%bRewrite as separate Bash tool calls." "$warnings")
    hook_deny "$msg"
fi

hook_pass
