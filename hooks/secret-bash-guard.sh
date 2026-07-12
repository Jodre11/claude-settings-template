#!/usr/bin/env bash
# secret-bash-guard.sh — PreToolUse hook for Bash. Denies commands that print a
# secret to stdout (→ context). Runs AFTER bash-guard.sh, so it can assume the
# command is a single simple command (no &&/||/;/subshells). Indirect handling
# via scripts is permitted: secret-fetch commands are allowed only when their
# output is redirected to a /tmp/claude-* file.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/_lib.sh"
source "$DIR/secret-patterns.sh"
trap 'hook_ask "secret-bash-guard failed to evaluate; approve manually."' ERR
hook_read_input

if [[ "${CLAUDE_ALLOW_SECRET_READ:-0}" == "1" ]]; then
    exit 0
fi

cmd=$(hook_field '.tool_input.command')
if [[ -z "$cmd" ]]; then
    exit 0
fi

read -ra toks <<< "$cmd"
c0="${toks[0]:-}"

# 1. Readers that would print a secret-bearing file into context.
readers_re='^(cat|less|more|head|tail|xxd|strings|od|nl|tac|bat)$'
if [[ "$c0" =~ $readers_re ]]; then
    for t in "${toks[@]:1}"; do
        [[ "$t" == -* ]] && continue
        if path_is_secret "$t"; then
            hook_deny "SECRET-PATH BLOCK: '$c0 $t' would print a secret-bearing file into context. Have a script write only the non-secret parts to \$CLAUDE_TEMP_DIR instead."
        fi
    done
fi

# 2. `env`: bare form dumps all vars; the 'env VAR=val cmd' prefix form is fine.
if [[ "$c0" == "env" ]]; then
    if [[ "${toks[1]:-}" != *=* ]]; then
        hook_deny "SECRET-ENV BLOCK: bare 'env' can dump secret-bearing variables into context. Use the 'env VAR=value command' prefix form, or reference a specific non-secret variable."
    fi
fi

# 3. `printenv`: bare dumps all; a secret-named var is blocked; a named non-secret var is fine.
secret_name_re='(SECRET|TOKEN|PASSWORD|PASSWD|CREDENTIAL|PRIVATE_KEY|API_KEY|ACCESS_KEY)'
if [[ "$c0" == "printenv" ]]; then
    if [[ ${#toks[@]} -eq 1 ]]; then
        hook_deny "SECRET-ENV BLOCK: bare 'printenv' can dump secret-bearing variables into context. Name a specific non-secret variable."
    fi
    for t in "${toks[@]:1}"; do
        [[ "$t" == -* ]] && continue
        if [[ "$t" =~ $secret_name_re ]]; then
            hook_deny "SECRET-ENV BLOCK: 'printenv $t' would print a secret variable into context."
        fi
    done
fi

# 4. echo/printf of a secret-named variable.
if [[ "$c0" == "echo" || "$c0" == "printf" ]]; then
    if [[ "$cmd" =~ \$\{?[A-Za-z_]*${secret_name_re}[A-Za-z_]*\}? ]]; then
        hook_deny "SECRET-ECHO BLOCK: printing a secret-shaped variable into context is not allowed. Write it to \$CLAUDE_TEMP_DIR from a script instead."
    fi
fi

# 5. Secret-fetch commands: allowed only when redirected to a /tmp/claude-* file.
fetch_re='(secretsmanager[[:space:]]+get-secret-value|ecr[[:space:]]+get-login-password|ssm[[:space:]]+get-parameter([[:space:]].*)?--with-decryption)'
if [[ "$cmd" =~ $fetch_re ]]; then
    if [[ ! "$cmd" =~ \>\>?[[:space:]]*/tmp/claude- ]]; then
        hook_deny "SECRET-FETCH BLOCK: this command emits a live secret to stdout (→ context). Redirect it to a \$CLAUDE_TEMP_DIR file, e.g. '... > /tmp/claude-XXXX/secret.json', so a script can consume it indirectly."
    fi
fi

exit 0
