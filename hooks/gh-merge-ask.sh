#!/usr/bin/env bash
# gh-merge-ask.sh — PreToolUse hook for Bash calls.
# Forces a prompt for gh pr merge unless every repository the command can target is listed in the untracked
# ~/.claude/gh-merge-ask.local (one owner/name per line, # comments; GH_MERGE_ASK_REPOS_FILE overrides the path). This
# replaces a native ask rule, because a native ask rule beats every allow rule and hook "allow" at any scope, so a
# repository could never opt out of it. The targets are each --repo/-R value and each URL or host/owner/repo
# reference, which must name github.com itself; unless a --repo or positional PR URL names the target, also every
# URL git remote -v lists, since gh may pick any of them (upstream, a set-default). Anything the hook cannot judge
# prompts: shell metacharacters (a cd, a variable, a second command), an unquoted glob or brace, any word before gh
# (an assignment such as GIT_DIR=, a path to gh), GH_REPO or GH_HOST in the command or the environment, a malformed
# reference, a directory with no GitHub remote. A merge it judges unprompted, and every other command, gets no decision, so the
# native rules and mode decide them.

set -euo pipefail
source "$(dirname "$0")/_lib.sh"
hook_read_input

# An unreadable payload cannot be judged a merge, so it gets no decision.
cmd=$(hook_field '.tool_input.command' 2>/dev/null || true)

# Quotes and backslashes are removed as the shell would splice them out, and flags (with an optional value) may sit
# between gh, pr and merge, so neither hides a merge. A flag value that is itself a subcommand word still stops it.
# zsh expands =gh to gh's path, so = also leads gh.
unquoted=${cmd//\"/}
unquoted=${unquoted//\'/}
unquoted=${unquoted//\\/}
flags='([[:space:]]+-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?)*'
merge_re='(^|[[:space:];&|(`/=])gh'"$flags"'[[:space:]]+pr'"$flags"'[[:space:]]+merge([[:space:]]|$)'
pr_word_re='(^|[[:space:];&|(`/=])pr([[:space:]]|$)'

# glob_scan <cmd>: set spaced to <cmd> with its quotes removed and every unquoted glob, brace or comma made a space,
# and glob_seen to 1 when an unquoted glob or brace was found. Quoted and escaped characters stay literal.
glob_scan() {
    local s="$1" q="" c i
    spaced=""
    glob_seen=0
    for (( i = 0; i < ${#s}; i++ )); do
        c=${s:i:1}
        if [[ -n "$q" ]]; then
            if [[ "$c" == "$q" ]]; then
                q=""
            elif [[ "$q" == \" && "$c" == \\ ]]; then
                i=$((i + 1))
                spaced+=${s:i:1}
            else
                spaced+=$c
            fi
        elif [[ "$c" == \" || "$c" == \' ]]; then
            q=$c
        elif [[ "$c" == \\ ]]; then
            i=$((i + 1))
            spaced+=${s:i:1}
        else
            case "$c" in
                '*'|'?'|'['|']'|'{'|'}') glob_seen=1; spaced+=' ' ;;
                ',') spaced+=' ' ;;
                *) spaced+=$c ;;
            esac
        fi
    done
}

# A glob or brace can assemble gh or merge from pieces ({gh,pr} merge, gh pr {m,7}erge, /bin/?h), but gh still needs
# pr as a word of its own, and no brace yields exactly pr without spelling it ({p,}r gives pr r). So an unquoted glob
# or brace beside a bare pr word is judged a possible merge, and the word split below prompts on it.
if ! [[ "$unquoted" =~ $merge_re ]]; then
    uspaced=${unquoted//[][\{\}*?,]/ }
    [[ "$unquoted" == *[][\{\}*?]* && "$uspaced" =~ $pr_word_re ]] || exit 0
    if (( ${#cmd} <= 4096 )); then
        glob_scan "$cmd"
        (( glob_seen )) && [[ "$spaced" =~ $pr_word_re ]] || exit 0
    fi
fi

hook_backstop ask "gh pr merge: the merge guard could not finish, so this merge needs your approval."

# Owner/name pairs whose merges skip the prompt, compared case-insensitively as GitHub does. A missing file lists none.
repos_file=${GH_MERGE_ASK_REPOS_FILE:-$HOME/.claude/gh-merge-ask.local}
UNPROMPTED_REPOS=()
if [[ -r "$repos_file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=${line%%#*}
        read -r line _ <<< "$line" || true
        if [[ -n "$line" ]]; then
            UNPROMPTED_REPOS+=("$line")
        fi
    done < "$repos_file"
fi

# ask_merge <why>: prompt, naming why the merge was not judged unprompted.
ask_merge() {
    hook_ask "gh pr merge needs approval: $1. Merges skip the prompt only for: ${UNPROMPTED_REPOS[*]:-no repository}."
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

# unprompted <owner/name>: succeed when the pair is in UNPROMPTED_REPOS.
unprompted() {
    local want r
    (( ${#UNPROMPTED_REPOS[@]} )) || return 1
    want=$(tr '[:upper:]' '[:lower:]' <<< "$1")
    for r in "${UNPROMPTED_REPOS[@]}"; do
        if [[ "$want" == "$(tr '[:upper:]' '[:lower:]' <<< "$r")" ]]; then
            return 0
        fi
    done
    return 1
}

if [[ "$cmd" == *[\;\&\|\(\)\<\>\`\$\\]* || "$cmd" == *$'\n'* ]]; then
    ask_merge "the command holds shell syntax the guard does not follow"
fi
# The shell splits words on space and tab only; any other control character (\r \v \f ...) stays inside a word.
if [[ "${cmd//$'\t'/ }" == *[[:cntrl:]]* ]]; then
    ask_merge "the command holds a control character"
fi
if [[ "$cmd" == *GH_REPO* || "$cmd" == *GH_HOST* || -n "${GH_REPO:-}${GH_HOST:-}" ]]; then
    ask_merge "GH_REPO or GH_HOST is set"
fi

# Split into words as the shell would: with $ and \ already refused, a quoted span is literal and stays inside its
# word, and an unquoted # at the start of a word begins a comment. The walk is per character, so it is bounded.
if (( ${#cmd} > 4096 )); then
    ask_merge "the command is too long for the guard to split"
fi
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
            '*'|'?'|'['|']'|'{'|'}') ask_merge "the command holds a glob or brace the guard does not expand" ;;
        esac
        word+=$c
        in_word=1
    fi
done
if [[ -n "$quote" ]]; then
    ask_merge "the command has an unterminated quote"
fi
if (( in_word )); then
    words+=("$word")
fi
# A word before gh (GIT_DIR=, GIT_CONFIG_*=, env, a path) can change the repository gh resolves or the binary run.
if [[ "${words[0]:-}" != gh ]]; then
    ask_merge "the command does not start with gh"
fi

# Only a --repo/-R value or a positional full PR URL names the target outright; gh reads any other positional as a
# number or branch of the working directory's repository, so it leaves the remotes to be checked. Every other
# reference, flag values included, must still be listed. Flags are parsed as cobra parses them, so a URL given as a
# flag value is never read as the positional: in a short cluster (-sbR) the boolean letters d m r s may lead, and the
# first value-taking letter (R, or A b F t) takes the rest of the word, or the next word, as its value. Any other
# letter prompts.
pr_url_re='^https://github\.com/[A-Za-z0-9-]+/[A-Za-z0-9._-]+/pull/[0-9]+(/.*)?$'
long_value_re='^--(author-email|body|body-file|match-head-commit|subject)$'

# is_reference <word>: succeed when <word> looks like a URL or a host/owner/repo reference.
is_reference() {
    [[ "$1" == *://* || "$1" == *github.com* || "$1" == *.*/*/* ]]
}

targets=()
explicit=0
expect_repo=0
expect_value=0
for w in "${words[@]}"; do
    value=""
    if (( expect_repo )); then
        value=$w
        expect_repo=0
        explicit=1
    elif (( expect_value )); then
        expect_value=0
        is_reference "$w" || continue
        value=$w
    elif [[ "$w" == --repo ]]; then
        expect_repo=1
        continue
    elif [[ "$w" == --repo=* ]]; then
        value=${w#--repo=}
        explicit=1
    elif [[ "$w" =~ $long_value_re ]]; then
        expect_value=1
        continue
    elif [[ "$w" == -[!-]* ]]; then
        rest=""
        letter=""
        for (( i = 1; i < ${#w}; i++ )); do
            letter=${w:i:1}
            case "$letter" in
                d|m|r|s) letter="" ;;
                R|A|b|F|t) rest=${w:i+1}; break ;;
                *) ask_merge "the short flag -$letter is not one the guard knows" ;;
            esac
        done
        if [[ -z "$letter" ]]; then
            continue
        elif [[ -z "$rest" && "$letter" == R ]]; then
            expect_repo=1
            continue
        elif [[ -z "$rest" ]]; then
            expect_value=1
            continue
        elif [[ "$letter" == R ]]; then
            value=$rest
            explicit=1
        elif is_reference "$rest"; then
            value=$rest
        else
            continue
        fi
    elif is_reference "$w"; then
        # A URL or host/owner/repo reference is judged whole, so its host must be github.com itself.
        value=$w
        if [[ "$w" =~ $pr_url_re ]]; then
            explicit=1
        fi
    else
        continue
    fi
    repo=$(normalise_repo "$value")
    if [[ -z "$repo" ]]; then
        ask_merge "'$value' is not a GitHub owner/name"
    fi
    targets+=("$repo")
done
if (( expect_repo )); then
    ask_merge "--repo has no value"
fi

if (( ! explicit )); then
    cwd=$(hook_field '.cwd')
    if [[ -z "$cwd" || ! -d "$cwd" ]]; then
        ask_merge "the working directory is unknown"
    fi
    # gh resolves its repository from git remote -v (insteadOf rewrites applied, push URLs too), preferring upstream
    # or a set-default over origin, so every URL it lists must be listed here.
    remotes=$(git -C "$cwd" remote -v 2>/dev/null || true)
    found=0
    while read -r _ url _; do
        [[ -n "${url:-}" ]] || continue
        found=1
        repo=$(normalise_repo "$url")
        if [[ -z "$repo" ]]; then
            ask_merge "the working directory has a remote that is not on github.com"
        fi
        targets+=("$repo")
    done <<< "$remotes"
    if (( ! found )); then
        ask_merge "no --repo was given and the working directory has no GitHub remote"
    fi
fi

for repo in "${targets[@]}"; do
    if ! unprompted "$repo"; then
        ask_merge "it targets $repo"
    fi
done

hook_pass
