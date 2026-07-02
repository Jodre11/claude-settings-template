#!/usr/bin/env bash
# bash-guard.sh — PreToolUse hook for Bash calls
# Denies commands that violate CLAUDE.md Bash rules:
#   1. Compound operators: && || ; or newline separators
#   2. Command substitution: $(...) or backticks
#   3. Process substitution: <(...) or >(...)
#   4. Control-flow loops (for/while/until) and case statements
#   5. Temp-directory write policy
#
# Strips single-quoted/double-quoted strings and comments before checking,
# so patterns inside string literals don't trigger false positives.

set -euo pipefail
source "$(dirname "$0")/_lib.sh"
hook_read_input

cmd=$(hook_field '.tool_input.command')
if [[ -z "$cmd" ]]; then
    exit 0
fi

# Whitelist: git commit HEREDOC pattern requires $(cat <<'EOF'...) — no clean alternative
if [[ "$cmd" =~ ^git[[:space:]].*commit[[:space:]] ]]; then
    exit 0
fi

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
if mentions_temp_path "$cmd" && ! cmd_mentions_review_worktree "$cmd"; then
    if [[ "$cmd" == *'$TMPDIR'* || "$cmd" == */var/folders/* ]]; then
        hook_deny "TEMP DIRECTORY VIOLATION: Use \$CLAUDE_TEMP_DIR instead of \$TMPDIR or /var/folders/. See CLAUDE.md 'Temporary Files' section."
    fi
    if ! cmd_mentions_session_temp "$cmd"; then
        # Allow read-only commands against bare /tmp/, deny anything else writing there
        if ! [[ "$cmd" =~ ^(cat|ls|head|tail|wc|file|stat|diff|less|more|grep|rg|find|readlink)[[:space:]] ]]; then
            hook_deny "TEMP DIRECTORY VIOLATION: Use \$CLAUDE_TEMP_DIR for writing to temp. See CLAUDE.md 'Temporary Files' section."
        fi
    fi
fi

# Strip quoted strings and comments in one sed call (3 forks → 1)
stripped=$(sed -e "s/'[^']*'//g" -e 's/"[^"]*"//g' -e 's/#.*//' <<< "$cmd")

warnings=""

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

exit 0
