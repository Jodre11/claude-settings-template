#!/usr/bin/env bash
# git-signing-ask.sh — PreToolUse hook for Bash calls.
# Denies, with guidance, a command that overrides or removes git's signing setting (commit/tag/rebase gpgsign): an
# inline key=value (-c, --config-env, GIT_CONFIG_* env), a git config write, an unset, or git's --no-gpg-sign option.
# Signing works automatically here, so no command needs the override; the reason tells the agent to drop it and retry.
# It sits beside the native ask rules, which stay as a backstop: git reads config keys case-insensitively and the
# native globs cannot, so this also catches spellings such as GPGSIGN.
# Reads (git config --get, --get-regexp, --list, or a bare key) get no decision, so the native rules decide them.

set -euo pipefail
source "$(dirname "$0")/_lib.sh"
hook_read_input

cmd=$(hook_field '.tool_input.command')
checked=$(strip_commit_heredoc "$cmd")

reason="SIGNING BLOCK: this command overrides or removes git commit signing (gpgsign). Signing works automatically"
reason+=" here, throwaway repos included: drop the override and run the command again."

# Git's option parser is case-sensitive, so this runs before nocasematch is set. Quotes and backslashes are removed
# first, as the shell would splice them out; the regex accepts git right after a separator, pipe, ( or backquote,
# every unambiguous long-option prefix from --no-g up, and any non-word character after the option.
unquoted=${checked//\"/}
unquoted=${unquoted//\'/}
unquoted=${unquoted//\\/}
nosign_re='(^|[[:space:](/;&|`])git[[:space:]](.*[[:space:]])?--no-g(p|pg|pg-|pg-s|pg-si|pg-sig|pg-sign)?'
nosign_re+='([^[:alnum:]_-]|$)'
if [[ "$unquoted" =~ $nosign_re ]]; then
    hook_deny "$reason"
fi

shopt -s nocasematch
if [[ "$checked" != *gpgsign* ]]; then
    exit 0
fi

if [[ "$checked" == *gpgsign=* || "$checked" == *GIT_CONFIG_* ]]; then
    hook_deny "$reason"
fi

config_re='(^|[[:space:]/])git[[:space:]](.*[[:space:]])?config([[:space:]]|$)'
unset_re='(^|[[:space:]])(--unset|--unset-all|unset)([[:space:]]|$)'
read_re='(^|[[:space:]])(--get|--get-all|--get-regexp|--get-urlmatch|get|--list|-l|list)([[:space:]=]|$)'
value_re="gpgsign[\"']?[[:space:]]+([^[:space:]]+)"
redirect_re='^[0-9]*[<>&]'

# Each pipeline stage is judged on its own, so a read in one stage cannot vouch for a write in another.
IFS='|' read -ra stages <<< "${checked//$'\n'/|}"
for stage in "${stages[@]}"; do
    if [[ "$stage" != *gpgsign* ]] || ! [[ "$stage" =~ $config_re ]]; then
        continue
    fi
    if [[ "$stage" =~ $unset_re ]]; then
        hook_deny "$reason"
    fi
    if [[ "$stage" =~ $read_re ]]; then
        continue
    fi
    if [[ "$stage" =~ $value_re ]] && ! [[ "${BASH_REMATCH[1]}" =~ $redirect_re ]]; then
        hook_deny "$reason"
    fi
done

exit 0
