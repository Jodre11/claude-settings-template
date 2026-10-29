#!/usr/bin/env bash
# gh-rerun-ask.sh — PreToolUse hook for Bash calls.
# Forces a prompt for gh run rerun unless the run was triggered by a pull request, so an agent can rerun a flaky PR
# check unattended while a rerun of a push, schedule or dispatch run (a deploy, a release) still needs approval. This
# replaces a native ask rule, because a native ask rule beats every hook "allow", so no run could skip it. The run's
# trigger comes from gh run view in the payload's working directory, or the --repo given. Anything the hook cannot
# judge prompts: shell syntax (a cd, a variable, a second command), a glob or brace, any word before gh, flags before
# rerun, GH_REPO or GH_HOST, --job, an unknown flag, a missing or non-numeric run id, a failed or slow lookup. A rerun
# it judges unprompted, and every other command, gets no decision, so the native rules and mode decide them.

set -euo pipefail
source "$(dirname "$0")/_lib.sh"
# The lookup is a network call: it gets most of the hook's 5 s timeout, after which a hook does not block.
# shellcheck disable=SC2034  # read by hook_bounded in _lib.sh
HOOK_DEADLINE_MS=3500
# shellcheck disable=SC2034  # read by hook_bounded in _lib.sh
PROBE_WATCHDOG_S=3
hook_read_input

# An unreadable payload cannot be judged a rerun, so it gets no decision.
cmd=$(hook_field '.tool_input.command' 2>/dev/null || true)

# Quotes and backslashes are removed as the shell would splice them out, and flags (with an optional value) may sit
# between gh, run and rerun, so neither hides a rerun.
unquoted=${cmd//\"/}
unquoted=${unquoted//\'/}
unquoted=${unquoted//\\/}
flags='([[:space:]]+-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?)*'
rerun_re='(^|[[:space:];&|(`/=])gh'"$flags"'[[:space:]]+run'"$flags"'[[:space:]]+rerun([[:space:]]|$)'
run_word_re='(^|[[:space:];&|(`/=])run([[:space:]]|$)'

# outside_quotes <cmd>: print <cmd> with every quoted span removed.
outside_quotes() {
    local s="$1" q="" c i out=""
    for (( i = 0; i < ${#s}; i++ )); do
        c=${s:i:1}
        if [[ -n "$q" ]]; then
            [[ "$c" == "$q" ]] && q=""
        elif [[ "$c" == \" || "$c" == \' ]]; then
            q=$c
        elif [[ "$c" == \\ ]]; then
            i=$((i + 1))
        else
            out+=$c
        fi
    done
    printf '%s' "$out"
}

# A glob, brace or expansion can assemble rerun from pieces (r?run, {re,}run, $'rerun', ${X:-rerun}), so beside a run
# word one is judged a possible rerun and the word split below prompts on it.
if ! [[ "$unquoted" =~ $rerun_re ]]; then
    [[ "$unquoted" =~ $run_word_re ]] || exit 0
    (( ${#cmd} <= 4096 )) || exit 0
    bare=$(outside_quotes "$cmd")
    [[ "$bare" == *[][\{\}*?\$]* ]] || exit 0
fi

hook_backstop ask "gh run rerun: the rerun guard could not finish, so this rerun needs your approval."

# ask_rerun <why>: prompt, naming why the rerun was not judged unprompted.
ask_rerun() {
    hook_ask "gh run rerun needs approval: $1. Only reruns of pull_request runs skip the prompt."
}

# normalise_repo <ref>: print owner/name for a GitHub repository reference (owner/name, github.com/owner/name, an
# https or ssh URL, optionally with .git or a trailing path), or nothing when <ref> is not one.
normalise_repo() {
    local r="$1" owner name rest
    r=${r#https://}
    r=${r#http://}
    r=${r#ssh://}
    r=${r#git@github.com:}
    r=${r#git@github.com/}
    r=${r#github.com/}
    owner=${r%%/*}
    rest=${r#*/}
    [[ "$rest" != "$r" ]] || return 0
    name=${rest%%/*}
    name=${name%.git}
    if [[ "$owner" =~ ^[A-Za-z0-9-]+$ && "$name" =~ ^[A-Za-z0-9._-]+$ ]]; then
        printf '%s/%s' "$owner" "$name"
    fi
}

if [[ "$cmd" == *[\;\&\|\(\)\<\>\`\$\\]* || "$cmd" == *$'\n'* ]]; then
    ask_rerun "the command holds shell syntax the guard does not follow"
fi
# The shell splits words on space and tab only; any other control character (\r \v \f ...) stays inside a word.
if [[ "${cmd//$'\t'/ }" == *[[:cntrl:]]* ]]; then
    ask_rerun "the command holds a control character"
fi
if [[ "$cmd" == *GH_REPO* || "$cmd" == *GH_HOST* || -n "${GH_REPO:-}${GH_HOST:-}" ]]; then
    ask_rerun "GH_REPO or GH_HOST is set"
fi
if (( ${#cmd} > 4096 )); then
    ask_rerun "the command is too long for the guard to split"
fi

# Split into words as the shell would: with $ and \ already refused, a quoted span is literal and stays inside its
# word, and an unquoted # at the start of a word begins a comment.
words=()
word=""
in_word=0
quote=""
for (( i = 0; i < ${#cmd}; i++ )); do
    c=${cmd:i:1}
    if [[ -n "$quote" ]]; then
        if [[ "$c" == "$quote" ]]; then
            quote=""
        else
            word+=$c
        fi
    elif [[ "$c" == \" || "$c" == \' ]]; then
        quote=$c
        in_word=1
    elif [[ "$c" == ' ' || "$c" == $'\t' ]]; then
        if (( in_word )); then
            words+=("$word")
        fi
        word=""
        in_word=0
    elif [[ "$c" == '#' ]] && (( ! in_word )); then
        break
    else
        case "$c" in
            '*'|'?'|'['|']'|'{'|'}') ask_rerun "the command holds a glob or brace the guard does not expand" ;;
        esac
        word+=$c
        in_word=1
    fi
done
if [[ -n "$quote" ]]; then
    ask_rerun "the command has an unterminated quote"
fi
if (( in_word )); then
    words+=("$word")
fi
if [[ "${words[0]:-}" != gh ]]; then
    ask_rerun "the command does not start with gh"
fi
if [[ "${words[1]:-}" != run || "${words[2]:-}" != rerun ]]; then
    # Flagged here only for an expansion beside a run word: a plain gh run command that is not a rerun passes.
    if [[ "$unquoted" =~ $rerun_re ]]; then
        ask_rerun "the guard judges only gh run rerun with its flags after rerun"
    fi
    hook_pass
fi

run_id=""
repo_args=()
expect_repo=0
for w in "${words[@]:3}"; do
    if (( expect_repo )); then
        expect_repo=0
        value=$w
    else
        case "$w" in
            --failed|--debug|-d) continue ;;
            --repo|-R) expect_repo=1; continue ;;
            --repo=*) value=${w#--repo=} ;;
            -R?*) value=${w#-R} ;;
            --job|--job=*|-j*) ask_rerun "a rerun of one job is not judged" ;;
            -*) ask_rerun "the flag $w is not one the guard knows" ;;
            *)
                if [[ ! "$w" =~ ^[0-9]+$ ]]; then
                    ask_rerun "'$w' is not a run id"
                elif [[ -n "$run_id" ]]; then
                    ask_rerun "it names more than one run"
                fi
                run_id=$w
                continue
                ;;
        esac
    fi
    repo=$(normalise_repo "$value")
    if [[ -z "$repo" ]]; then
        ask_rerun "'$value' is not a GitHub owner/name"
    fi
    repo_args=(--repo "$repo")
done
if (( expect_repo )); then
    ask_rerun "--repo has no value"
fi
if [[ -z "$run_id" ]]; then
    ask_rerun "no run id was given"
fi

cwd=$(hook_field '.cwd')
if [[ -z "$cwd" || ! -d "$cwd" ]]; then
    ask_rerun "the working directory is unknown"
fi

# lookup: print the run's trigger event, then an end marker, so a lookup cut short is told from a complete one.
lookup() {
    cd "$cwd"
    gh run view "$run_id" ${repo_args[@]+"${repo_args[@]}"} --json event --jq .event
    printf '%s\n' __end__
}
out=$(mktemp "${TMPDIR:-/tmp}/claude-gh-rerun.XXXXXX")
hook_bounded "$out" lookup || :
event=$(sed -n 1p "$out")
marker=$(sed -n 2p "$out")
rm -f "$out"
if [[ "$marker" != __end__ || -z "$event" ]]; then
    ask_rerun "the trigger of run $run_id could not be looked up in time"
fi
if [[ "$event" != pull_request ]]; then
    ask_rerun "run $run_id was triggered by '$event'"
fi

hook_pass
