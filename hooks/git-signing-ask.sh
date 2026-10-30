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

config_re='(^|[[:space:](/;&|`])git[[:space:]](.*[[:space:]])?config([[:space:]]|$)'

# judge_stage: deny when the shell_words elements in sw (one pipeline stage or list part) hold git config unsetting a
# signing key, or with any word after the key, empty included: a value, so a write. Redirections are skipped, and no
# read option exempts a word after the key, as an option's argument (--comment --get) would pass for one. Words are
# compared whole, so a quoted word holding a space and an option name (-C ' --unset ') is no option.
judge_stage() {
    local i n=${#sw[@]} g=0 c=-1 gs=0 k=0 e u
    for (( i = 0; i < n; i++ )); do
        e="${sw[i]}"
        if [[ "$e" == w*gpgsign* ]]; then
            gs=1
            # A word that is itself a git config command (bash -c '…', "$(…)") is code the stage would run; its
            # own quotes and backslashes are removed first, as for the --no-gpg-sign check.
            u="${e:1}"
            u=${u//[\"\'\\]/}
            if [[ "$u" =~ $config_re ]]; then hook_deny "$reason"; fi
        fi
        if (( c < 0 )); then
            # An unquoted backquote stays in its word (`git), so it opens a command as a / path does.
            if [[ "$e" == wgit || "$e" == w*[/\`]git ]]; then g=1
            elif (( g )) && [[ "$e" == wconfig ]]; then c=$i; fi
        fi
    done
    if (( ! gs || c < 0 )); then
        return 0
    fi
    for (( i = c + 1; i < n; i++ )); do
        case "${sw[i]}" in
            w--unset|w--unset-all|wunset) hook_deny "$reason" ;;
            w*gpgsign) if (( k )); then hook_deny "$reason"; fi; k=1 ;;
            w*) if (( k )); then hook_deny "$reason"; fi ;;
        esac
    done
}

# Each pipeline stage and list part is judged on its own, so a read in one cannot vouch for a write in another. The
# body of a quoted cat or tee heredoc is text no shell runs, so its lines are no parts. shell_words cuts the stages
# where the shell would, so a quoted ; & or | (git -C 'R&D' config …) stays inside its word. A command shell_words
# cannot split is denied when it holds both git config and gpgsign, read or not.
staged=$(strip_text_heredoc "$checked")
shell_words "$staged"
if (( ! SW_OK )); then
    if [[ "$staged" == *gpgsign* && "$staged" =~ $config_re ]]; then
        hook_deny "$reason"
    fi
    exit 0
fi
sw=()
for el in ${SW_WORDS[@]+"${SW_WORDS[@]}"} '|'; do
    case "$el" in
        '|'|';') judge_stage; sw=() ;;
        w*|r*) sw+=("$el") ;;
    esac
done

exit 0
