#!/usr/bin/env bash
# gh-rerun-ask.sh — PreToolUse hook for Bash calls.
# Lets an agent rerun a flaky pull-request check unattended, and denies, with a route, every other gh run rerun: a rerun
# of a push, schedule or dispatch run (a deploy, a release) is left to the user. It never asks, so an unattended session
# is never parked on a prompt. This replaces a native ask rule, because a native ask rule beats every hook "allow", so
# no run could skip it. The run's trigger comes from gh run view in the payload's working directory, or the --repo
# given. A command whose text, with quotes and backslashes removed, holds a literal gh run rerun is judged; anything in
# it the hook cannot follow is denied with the form to write instead: shell syntax (a variable, a pipe, a redirection,
# a list), a glob or brace, any word before gh, flags before rerun, GH_REPO or GH_HOST, --job, an unknown flag, a
# missing or non-numeric run id, a failed or slow lookup. A command with no literal rerun gets no decision, so the
# native rules and mode decide it: a rerun assembled at run time (gh run ${X:-rerun}, words from the environment) is
# deliberate evasion and out of scope, as for the other guards.

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

# The bodies of bash-guard's two sanctioned heredocs (the commit message, and a quoted cat or tee heredoc that writes a
# file) are text no shell runs, so they are left out. Quotes and backslashes are removed as the shell would splice them
# out, and flags (with an optional value) may sit between gh, run and rerun, so neither hides a rerun.
text=$(strip_commit_heredoc "$cmd")
text=$(strip_text_heredoc "$text")
unquoted=${text//\"/}
unquoted=${unquoted//\'/}
unquoted=${unquoted//\\/}
flags='([[:space:]]+-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?)*'
# Only a name character (letter, digit, _ . / -) continues a word, so a redirection (rerun>/dev/null) ends one.
rerun_re='(^|[[:space:];&|(`/=])gh'"$flags"'[[:space:]]+run'"$flags"'[[:space:]]+rerun([^[:alnum:]_./-]|$)'
# A command with no literal rerun is not judged.
[[ "$unquoted" =~ $rerun_re ]] || exit 0

hook_backstop deny "RERUN BLOCK: the rerun guard could not finish. Retry gh run rerun as its own Bash call."

# The plain form the guard judges, named in most routes.
FORM='gh run rerun <run-id> [--failed] [--debug] [--repo owner/name]'
# The route for a command that only mentions a rerun in its text.
MENTION=" If the command only mentions gh run rerun as text, write that text with the Write tool, or break the"
MENTION+=" literal (re[r]un in a search pattern)."

# deny_rerun <why> <route>: deny, naming why the rerun was not judged and what to do instead.
deny_rerun() {
    hook_deny "RERUN BLOCK: $1. $2"
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

# Another part of a list could change what a rerun targets (a cd, an assignment), so a rerun in a list is denied with
# the route to run it alone. bash-guard denies a list that breaks a list rule, so only the part count matters here;
# the sanctioned heredoc bodies are already left out of text, so their lines are no parts.
shell_scan "$text"
list_check "$text"
if (( LIST_PARTS > 1 )); then
    hook_deny "RERUN IN A LIST: run gh run rerun … as its own Bash call, so the rerun guard can check it."
fi

if [[ "$cmd" == *[\;\&\|\(\)\<\>\`\$\\]* || "$cmd" == *$'\n'* ]]; then
    deny_rerun "the command holds shell syntax the guard does not follow" "Write it as one plain command: $FORM.$MENTION"
fi
# The shell splits words on space and tab only; any other control character (\r \v \f ...) stays inside a word.
if [[ "${cmd//$'\t'/ }" == *[[:cntrl:]]* ]]; then
    deny_rerun "the command holds a control character" "Write it as one plain command: $FORM."
fi
if [[ "$cmd" == *GH_REPO* || "$cmd" == *GH_HOST* || -n "${GH_REPO:-}${GH_HOST:-}" ]]; then
    deny_rerun "GH_REPO or GH_HOST is set, so the guard cannot tell which repository the rerun targets" \
        "Name the repository with --repo owner/name instead; if GH_REPO or GH_HOST is set in the environment, leave the \
rerun undone and list it in your final report."
fi
if (( ${#cmd} > 4096 )); then
    deny_rerun "the command is too long for the guard to split" "Write it as one plain command: $FORM."
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
            '*'|'?'|'['|']'|'{'|'}')
                deny_rerun "the command holds a glob or brace the guard does not expand" \
                    "Write it as one plain command: $FORM.$MENTION"
                ;;
        esac
        word+=$c
        in_word=1
    fi
done
if [[ -n "$quote" ]]; then
    deny_rerun "the command has an unterminated quote" "Write it as one plain command: $FORM."
fi
if (( in_word )); then
    words+=("$word")
fi
if [[ "${words[0]:-}" != gh ]]; then
    deny_rerun "the command does not start with gh" "Call it as $FORM, with no word before gh.$MENTION"
fi
if [[ "${words[1]:-}" != run || "${words[2]:-}" != rerun ]]; then
    deny_rerun "the guard judges only gh run rerun with its flags after rerun" "Call it as $FORM."
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
            --job|--job=*|-j*)
                deny_rerun "a rerun of one job is not judged" \
                    "Rerun the run's failed jobs with gh run rerun <run-id> --failed instead."
                ;;
            -*) deny_rerun "the flag $w is not one the guard knows" "Call it as $FORM, with only those flags." ;;
            *)
                if [[ ! "$w" =~ ^[0-9]+$ ]]; then
                    deny_rerun "'$w' is not a run id" "Give one numeric run id (gh run list shows them): $FORM."
                elif [[ -n "$run_id" ]]; then
                    deny_rerun "it names more than one run" "Rerun each run as its own Bash call: $FORM."
                fi
                run_id=$w
                continue
                ;;
        esac
    fi
    if [[ -z "$(normalise_repo "$value")" ]]; then
        deny_rerun "'$value' is not a GitHub owner/name" "Name the repository as --repo owner/name."
    fi
    # The lookup gets the value as written, so gh resolves the same repository for both (a bare a/b/c, say, is
    # HOST/OWNER/REPO to gh).
    repo_args=(--repo "$value")
done
if (( expect_repo )); then
    deny_rerun "--repo has no value" "Name the repository as --repo owner/name."
fi
if [[ -z "$run_id" ]]; then
    deny_rerun "no run id was given" "Give one numeric run id (gh run list shows them): $FORM."
fi

cwd=$(hook_field '.cwd')
if [[ -z "$cwd" || ! -d "$cwd" ]]; then
    deny_rerun "the working directory is unknown" "Retry from a working directory that exists."
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
    deny_rerun "the trigger of run $run_id could not be looked up in time" \
        "Check the run id and repository with gh run view $run_id, then retry."
fi
if [[ "$event" != pull_request ]]; then
    deny_rerun "run $run_id was triggered by '$event', and only pull_request runs are rerun unattended, as a rerun of \
another trigger may deploy or release" "Leave it undone and list it in your final report; the user can rerun it."
fi

hook_pass
