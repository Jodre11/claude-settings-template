#!/usr/bin/env bash
# secret-bash-guard.sh — PreToolUse hook for Bash. Denies commands that print a secret to stdout (→ context) or copy
# a secret-bearing file somewhere it can be read. bash-guard.sh denies every compound form except a pipeline, so
# this hook screens the whole command, every naive |-split stage, and every quote-aware stage, each as a simple
# command by its first word. Hooks run in parallel; deny wins. Indirect handling via scripts is permitted:
# secret-fetch commands are allowed only when their output is redirected to a /tmp/claude-* file. The secret-fetch
# check runs first, before the floor and stage passes: it is a single cheap regex over the whole command, and under
# load those other passes can approach the 5 s hook timeout, which would fail open on a command this check alone
# can deny instantly.
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

# 1. Secret-fetch commands: allowed only when redirected to a /tmp/claude-* file.
fetch_re='(secretsmanager[[:space:]]+get-secret-value|ecr[[:space:]]+get-login-password'
fetch_re+='|ssm[[:space:]]+get-parameter([[:space:]].*)?--with-decryption)'
if [[ "$cmd" =~ $fetch_re ]]; then
    if [[ ! "$cmd" =~ \>\>?[[:space:]]*/tmp/claude- ]]; then
        msg="SECRET-FETCH BLOCK: this command emits a live secret to stdout (→ context). Redirect it to a"
        msg+=" \$CLAUDE_TEMP_DIR file, e.g. '... > /tmp/claude-XXXX/secret.json', so a script can consume it"
        msg+=" indirectly."
        hook_deny "$msg"
    fi
fi

# The timing tests cover commands up to SHELL_SCAN_MAX_CHARS, the bound bash-guard denies beyond. Deny a longer
# command here too, so this hook never screens an input its timing was not measured on and does not rely on another
# hook's deny to stay inside its timeout.
if (( ${#cmd} > SHELL_SCAN_MAX_CHARS )); then
    msg="SECRET-SCAN BLOCK: a command over ${SHELL_SCAN_MAX_CHARS} characters is not screened. Put long content in"
    msg+=" a file."
    hook_deny "$msg"
fi

# Words are split by array assignment (toks=($stage)) rather than a here-string read, which creates a temp file per
# call under bash 3.2; noglob keeps that split from expanding * and ?. Nothing in this hook relies on pathname
# expansion (case and [[ == ]] patterns are unaffected by noglob).
set -f

# Readers print a file operand into context. screened_pat is every first word a check below acts on. Both are
# matched with [[ == ]], which treats @(…) as if extglob were on; a pattern, not a regex, because bash recompiles
# a regex on every [[ =~ ]], and these run once per pipeline stage.
readers='cat|less|more|head|tail|xxd|strings|od|nl|tac|bat|grep|rg|awk|sed|jq|base64'
readers_pat="@(${readers})"
screened_pat="@(env|cp|mv|printenv|echo|printf|${readers})"
secret_name_re='(SECRET|TOKEN|PASSWORD|PASSWD|CREDENTIAL|PRIVATE_KEY|API_KEY|ACCESS_KEY)'

# _unquote <token>: set UNQ to <token> with one pair of surrounding single or double quotes removed. It sets a
# variable rather than printing, so the per-token loops below fork nothing.
_unquote() {
    UNQ="$1"
    if (( ${#UNQ} >= 2 )) && [[ "$UNQ" == \"*\" || "$UNQ" == \'*\' ]]; then
        UNQ="${UNQ:1:${#UNQ}-2}"
    fi
}

# _join_run: set JOINED to the global run array joined with |, in one join rather than by repeated concatenation.
# That keeps a long run of merged pieces at O(run length), not O(run length squared).
_join_run() {
    local IFS='|'
    JOINED="${run[*]}"
}

# screen_stage <stage> [<strict>]: deny (and exit) if the simple command <stage> would print a secret-bearing file or
# variable into context, or copy a secret-bearing file somewhere readable. Every check in _screen_words keys on the
# first word, so a short stage whose first word is none of the words they act on cannot be denied and is not passed
# on. The word is cut exactly as _screen_words cuts toks[0] (IFS space, tab and newline; backslashes literal). This
# wrapper stays small because bash copies a function's whole body on every call, and a long |-split command calls it
# once per piece; most pieces end here. Pattern removal is quadratic in the string's length, so a stage over 64
# characters skips the cut and is screened in full (a linear word split).
screen_stage() {
    local w
    if (( ${#1} > 64 )); then
        _screen_words "$@"
        return 0
    fi
    w="${1#"${1%%[!$' \t\n']*}"}"
    w="${w%%[$' \t\n']*}"
    # shellcheck disable=SC2053  # screened_pat is an intentional pattern
    if [[ "$w" == $screened_pat ]]; then
        _screen_words "$@"
    fi
    return 0
}

# _screen_words <stage> [<strict>]: the checks behind screen_stage.
_screen_words() {
    local stage="$1" strict="${2:-1}" c0 t i n msg s_msg first unsure opts runners_re
    local -a toks=() ops=()
    # shellcheck disable=SC2206  # intentional word split; noglob is on (see set -f above)
    toks=($stage)
    c0="${toks[0]:-}"
    if [[ -z "$c0" ]]; then
        return 0
    fi

    # 2. env: unwrap any chain of leading `env` invocations in ONE pass — a single index walks across the words,
    # and a bare `env` in command position is just another word to skip over, so a chain never re-slices the
    # remaining tokens per level (that was O(chain length squared)). Deny outright when a short option bundle
    # ends in S (builds a new, unscreened command line) or when no command remains. A short option that ends in
    # u, C or P takes an argument: glued onto the option (e.g. -uHTTP) it needs no extra word; separate, it
    # consumes the next one. `opts` tracks whether every option seen was fully recognised: a bundle of bare
    # 0/i/v flags must match exactly (^-[0iv]+$), not as a prefix, so an unknown trailing flag (e.g. -ia) cannot
    # hide behind a recognised leading one. An option outside the known set marks the walk `unsure`, since it
    # may select a mode (like -S) this walk does not otherwise recognise; after unwrapping, fall back to denying
    # (as the earlier hook did) when the first word after `env` was not an assignment and either the walk was
    # unsure, or it consumed no recognised option at all (a bare `env` in front of a wrapper or interpreter no
    # finite runner list can enumerate), or the unwrapped command is itself a runner this hook cannot see
    # through — keeping the earlier coverage instead of narrowing scope on a form the walk cannot fully account
    # for. The fallback only applies when <stage> is a real command (the caller's `strict` argument, default 1): a piece
    # of a naive |-split run that turned out to be a fragment of quoted text is screened loosely (strict=0), since
    # the fragment is not a real env invocation and the fallback would false-positive on it.
    if [[ "$c0" == env ]]; then
        i=1
        n=${#toks[@]}
        first="${toks[1]:-}"
        unsure=0
        opts=0
        runners_re='^(command|builtin|exec|nice|nohup|time|timeout|xargs|sudo|doas|stdbuf|ionice|sh|bash|zsh|dash|ksh)$'
        s_msg="SECRET-ENV BLOCK: 'env -S' builds a new command line that is not screened and may print every"
        s_msg+=" variable, secret-bearing ones included, into context. Use the 'env VAR=value command' prefix"
        s_msg+=" form instead."
        while (( i < n )); do
            t="${toks[i]}"
            if [[ "$t" == --split-string || "$t" == --split-string=* ]]; then
                hook_deny "$s_msg"
            elif [[ "$t" =~ ^-[0iv]*([uCPS])(.*)$ ]]; then
                opts=1
                if [[ "${BASH_REMATCH[1]}" == S ]]; then
                    hook_deny "$s_msg"
                elif [[ -n "${BASH_REMATCH[2]}" ]]; then
                    (( i += 1 ))
                else
                    (( i += 2 ))
                fi
            elif [[ "$t" =~ ^-[0iv]+$ ]]; then
                opts=1
                (( i += 1 ))
            else
                case "$t" in
                    --unset|--chdir) opts=1; (( i += 2 )) ;;
                    -|--|--ignore-environment|--null|--debug|--unset=*|--chdir=*) opts=1; (( i += 1 )) ;;
                    -*) unsure=1; (( i += 1 )) ;;
                    *=*) (( i += 1 )) ;;
                    env) (( i += 1 )) ;;
                    *) break ;;
                esac
            fi
        done
        if (( i >= n )); then
            msg="SECRET-ENV BLOCK: 'env' with no command prints every variable, secret-bearing ones included, into"
            msg+=" context. Use the 'env VAR=value command' prefix form, or reference a specific non-secret variable."
            hook_deny "$msg"
        fi
        toks=("${toks[@]:i}")
        c0="${toks[0]}"
        if (( strict )) && [[ "$first" != *=* ]] \
                && { (( unsure )) || (( ! opts )) || [[ "$c0" =~ $runners_re ]]; }; then
            hook_deny "SECRET-ENV BLOCK: 'env' wrapping '$c0' runs a command this hook cannot screen."
        fi
    fi

    # 3. Readers that would print a secret-bearing file into context.
    # shellcheck disable=SC2053  # readers_pat is an intentional pattern
    if [[ "$c0" == $readers_pat ]]; then
        for t in "${toks[@]:1}"; do
            [[ "$t" == -* ]] && continue
            _unquote "$t"
            t="$UNQ"
            if path_is_secret "$t"; then
                msg="SECRET-PATH BLOCK: '$c0 $t' would print a secret-bearing file into context. Have a script"
                msg+=" write only the non-secret parts to \$CLAUDE_TEMP_DIR instead."
                hook_deny "$msg"
            fi
        done
    fi

    # 4. cp/mv out of a secret path: the copy could then be read. Every operand but the last is a source.
    if [[ "$c0" == cp || "$c0" == mv ]]; then
        for t in "${toks[@]:1}"; do
            [[ "$t" == -* ]] && continue
            _unquote "$t"
            ops+=("$UNQ")
        done
        n=${#ops[@]}
        for (( i = 0; i < n - 1; i++ )); do
            if path_is_secret "${ops[i]}"; then
                msg="SECRET-PATH BLOCK: '$c0 ${ops[i]}' would copy a secret-bearing file where it can be read into"
                msg+=" context. Have a script consume it in place instead."
                hook_deny "$msg"
            fi
        done
    fi

    # 5. printenv: bare dumps all; a secret-named var is blocked; a named non-secret var is fine.
    if [[ "$c0" == printenv ]]; then
        if (( ${#toks[@]} == 1 )); then
            msg="SECRET-ENV BLOCK: bare 'printenv' can dump secret-bearing variables into context. Name a specific"
            msg+=" non-secret variable."
            hook_deny "$msg"
        fi
        for t in "${toks[@]:1}"; do
            [[ "$t" == -* ]] && continue
            if [[ "$t" =~ $secret_name_re ]]; then
                hook_deny "SECRET-ENV BLOCK: 'printenv $t' would print a secret variable into context."
            fi
        done
    fi

    # 6. echo/printf of a secret-named variable.
    if [[ "$c0" == echo || "$c0" == printf ]]; then
        if [[ "$stage" == *'$'* && "$stage" =~ \$\{?[A-Za-z_]*${secret_name_re}[A-Za-z_]*\}? ]]; then
            msg="SECRET-ECHO BLOCK: printing a secret-shaped variable into context is not allowed. Write it to"
            msg+=" \$CLAUDE_TEMP_DIR from a script instead."
            hook_deny "$msg"
        fi
    fi
}

# Floor: screen the whole, unsplit command first. This restores the old hook's whole-command scope (the
# echo/printf scan, and a reader's or cp/mv's operand scan) as a floor under the stage screening below, which
# only ever adds denials on top of it, never narrows it.
screen_stage "$cmd"

# Split on |. A | inside quotes splits too, so track the quote state across naive pieces: walk each piece's quote
# characters through an N (open) / S (single-quoted) / D (double-quoted) machine. A piece that starts and ends in N
# is a real pipeline stage and is screened strictly. Otherwise it is part of a quote-spanning run: each piece of the
# run is only a fragment of quoted text, so it is screened loosely (no env fallback — see _screen_words' `strict`
# argument), and the joined, fully-quoted run is then screened strictly. A backslash-escaped quote (e.g. echo \' |
# cat .env) mis-tracks the state, and the loosely-screened piece is what still catches that case. The pieces are
# read in one pass and a run is kept in its own array, joined once when it closes (_join_run): indexing a long array
# is O(index) under bash 3.2, and slicing one per run (the old _join_stage) was O(run position), so many short runs
# cost O(pieces squared).
naive_stages=()
IFS='|' read -ra naive_stages -d '' <<< "$cmd" || true
if (( ${#naive_stages[@]} > 1 )); then
    state=N
    run=()
    for piece in "${naive_stages[@]}"; do
        if (( ${#piece} > 64 )); then
            # A long piece is walked a character at a time with the read builtin. Deleting its non-quote characters
            # (${piece//[^\'\"]/}) and indexing a long string (${qc:i:1}) are both quadratic in its length, and read
            # forks nothing; its here-string costs a temp file under bash 3.2, which is why short pieces, the usual
            # case, take the other branch.
            while IFS= read -r -n 1 -d '' ch; do
                case "$state$ch" in
                    "N'") state=S ;;
                    'N"') state=D ;;
                    "S'"|'D"') state=N ;;
                esac
            done <<< "$piece"
        else
            qc="${piece//[^\'\"]/}"
            for (( j = 0; j < ${#qc}; j++ )); do
                case "$state${qc:j:1}" in
                    "N'") state=S ;;
                    'N"') state=D ;;
                    "S'"|'D"') state=N ;;
                esac
            done
        fi
        if [[ "$state" == N ]] && (( ${#run[@]} == 0 )); then
            screen_stage "$piece" 1
            continue
        fi
        # A run's first piece is screened loosely only once a second piece shows it really is a run: a lone open
        # piece at the end of the command is a real stage, screened strictly below.
        run+=("$piece")
        if (( ${#run[@]} == 2 )); then
            screen_stage "${run[0]}" 0
        fi
        if (( ${#run[@]} >= 2 )); then
            screen_stage "$piece" 0
        fi
        if [[ "$state" == N ]]; then
            _join_run
            screen_stage "$JOINED" 1
            run=()
        fi
    done
    if (( ${#run[@]} == 1 )); then
        screen_stage "${run[0]}" 1
    elif (( ${#run[@]} > 1 )); then
        _join_run
        screen_stage "$JOINED" 1
    fi
fi

exit 0
