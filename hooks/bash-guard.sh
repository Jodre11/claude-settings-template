#!/usr/bin/env bash
# bash-guard.sh — PreToolUse hook for Bash calls
# Warns (does not block) when a command violates CLAUDE.md Bash rules:
#   1. Compound operators: && || ;
#   2. Command substitution: $(...) or backticks
#
# Strips single-quoted and double-quoted strings before checking,
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
# Allow reads from anywhere in /tmp/. Block writes to bare /tmp/ (must use $CLAUDE_TEMP_DIR).
# $TMPDIR and /var/folders/ are always blocked (macOS expands $TMPDIR to /var/folders/).
if mentions_temp_path "$cmd"; then
    # Always allow if command targets session-scoped temp
    if cmd_mentions_session_temp "$cmd"; then
        exit 0
    fi
    # Always block $TMPDIR and /var/folders/ (no read exception)
    if [[ "$cmd" == *'$TMPDIR'* || "$cmd" == */var/folders/* ]]; then
        hook_deny "TEMP DIRECTORY VIOLATION: Use \$CLAUDE_TEMP_DIR instead of \$TMPDIR or /var/folders/. See CLAUDE.md 'Temporary Files' section."
    fi
    # Allow read-only commands against bare /tmp/
    if [[ "$cmd" =~ ^(cat|ls|head|tail|wc|file|stat|diff|less|more|grep|rg|find|readlink)[[:space:]] ]]; then
        exit 0
    fi
    # Block everything else targeting bare /tmp/
    hook_deny "TEMP DIRECTORY VIOLATION: Use \$CLAUDE_TEMP_DIR for writing to temp. See CLAUDE.md 'Temporary Files' section."
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

# Check for $(...) command substitution
if [[ "$stripped" == *'$('* ]]; then
    warnings="${warnings}  - command substitution '\$(...)' detected (capture output from separate Bash calls)\n"
fi

# Check for backtick command substitution
if [[ "$stripped" == *'`'* ]]; then
    warnings="${warnings}  - backtick command substitution detected (capture output from separate Bash calls)\n"
fi

if [[ -n "$warnings" ]]; then
    msg=$(printf "CLAUDE.md VIOLATION (Bash rules):\n%bRewrite as separate Bash tool calls." "$warnings")
    hook_deny "$msg"
fi

exit 0
