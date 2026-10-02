#!/usr/bin/env bash
# git-signing-ask.sh — PreToolUse hook for Bash calls.
# Forces a permission prompt for a command that overrides or removes git's signing setting (commit/tag/rebase
# gpgsign): an inline key=value (-c, --config-env, GIT_CONFIG_* env), a git config write, or an unset. Git reads
# config keys case-insensitively and the native ask globs cannot, so this also catches spellings such as GPGSIGN.
# Reads (git config --get, --get-regexp, --list, or a bare key) get no decision, so the native rules decide them.

set -euo pipefail
source "$(dirname "$0")/_lib.sh"
hook_read_input

cmd=$(hook_field '.tool_input.command')
checked=$(strip_commit_heredoc "$cmd")
shopt -s nocasematch
if [[ "$checked" != *gpgsign* ]]; then
    exit 0
fi

reason="This command overrides or removes git signing (gpgsign). Commits must stay signed: approve only for a"
reason+=" throwaway repo, and fix the signing setup rather than bypass it."

if [[ "$checked" == *gpgsign=* || "$checked" == *GIT_CONFIG_* ]]; then
    hook_ask "$reason"
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
        hook_ask "$reason"
    fi
    if [[ "$stage" =~ $read_re ]]; then
        continue
    fi
    if [[ "$stage" =~ $value_re ]] && ! [[ "${BASH_REMATCH[1]}" =~ $redirect_re ]]; then
        hook_ask "$reason"
    fi
done

exit 0
