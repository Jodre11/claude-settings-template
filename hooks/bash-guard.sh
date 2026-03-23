#!/usr/bin/env bash
# bash-guard.sh — PreToolUse hook for Bash calls
# Warns (does not block) when a command violates CLAUDE.md Bash rules:
#   1. Compound operators: && || ;
#   2. Command substitution: $(...) or backticks
#
# Strips single-quoted and double-quoted strings before checking,
# so patterns inside string literals don't trigger false positives.

set -euo pipefail

# Read the tool input from stdin
input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // empty')

if [ -z "$cmd" ]; then
    exit 0
fi

# Whitelist: git commit HEREDOC pattern requires $(cat <<'EOF'...) — no clean alternative
if echo "$cmd" | grep -qE '^git\s.*commit\s' ; then
    exit 0
fi

# Strip single-quoted strings (cannot contain escapes)
stripped=$(echo "$cmd" | sed "s/'[^']*'//g")
# Strip double-quoted strings (handle escaped quotes inside)
stripped=$(echo "$stripped" | sed 's/"[^"]*"//g')

warnings=""

# Check for && (but not inside a test bracket or [[ ]])
if echo "$stripped" | grep -qE '&&'; then
    warnings="${warnings}  - compound operator '&&' detected (use separate Bash calls)\n"
fi

# Check for ||
if echo "$stripped" | grep -qE '\|\|'; then
    warnings="${warnings}  - compound operator '||' detected (use separate Bash calls)\n"
fi

# Check for ; (but not in comments starting with #)
# Remove comments first, then check
stripped_no_comments=$(echo "$stripped" | sed 's/#.*//')
if echo "$stripped_no_comments" | grep -qE ';'; then
    warnings="${warnings}  - compound operator ';' detected (use separate Bash calls)\n"
fi

# Check for $(...) command substitution
if echo "$stripped" | grep -qE '\$\('; then
    warnings="${warnings}  - command substitution '\$(...)' detected (capture output from separate Bash calls)\n"
fi

# Check for backtick command substitution
if echo "$stripped" | grep -qE '`'; then
    warnings="${warnings}  - backtick command substitution detected (capture output from separate Bash calls)\n"
fi

if [ -n "$warnings" ]; then
    msg=$(printf "CLAUDE.md VIOLATION (Bash rules):\n%bRewrite as separate Bash tool calls." "$warnings")
    jq -n --arg m "$msg" '{
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": $m
        }
    }'
fi
