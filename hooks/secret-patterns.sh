#!/usr/bin/env bash
# secret-patterns.sh — single source of truth for secret recognition, sourced
# by the runtime firewall hooks (secret-*-guard.sh, secret-output-scrubber.sh).
# Two axes: high-precision VALUE shapes (scanned in every tool result) and
# conservative PATH globs (blocked before a read). Never emits raw values.

# class|ERE regex. Keep precision high — matches trigger redaction + alarm. Each regex runs under grep -E, sed -E
# and jq (Oniguruma), so use only syntax all three share.
# private-key spans the whole PEM block: the BEGIN line, then a body that holds no run of five dashes (so it stops
# at the END line; [^-] also matches a newline in jq), then the END line if present. A truncated block is redacted
# from BEGIN to the end of the text. grep -E and sed -E match per line, so the scan still triggers on the BEGIN line
# and a transcript (one JSON line, breaks escaped as \n) loses the whole block.
_PEM_BODY='([^-]|-[^-]|--[^-]|---[^-]|----[^-])*'
SECRET_CONTENT_PATTERNS=(
    'aws-access-key|AKIA[0-9A-Z]{16}'
    'aws-secret-key|aws_secret_access_key[[:space:]]*=[[:space:]]*[A-Za-z0-9/+]{40}'
    "private-key|-{5}BEGIN[A-Za-z ]*PRIVATE KEY-{5}${_PEM_BODY}(-{5}END[A-Za-z ]*PRIVATE KEY-{5})?"
    'github-pat|ghp_[0-9A-Za-z]{36}'
    'github-fine-pat|github_pat_[0-9A-Za-z_]{82}'
    'slack-token|xox[baprs]-[0-9A-Za-z-]{10,}'
)

# Secret-bearing path globs (bash `case` patterns). '*/secrets/*' matches an
# at-rest git-filter convention (files decrypted to plaintext in the working tree).
SECRET_PATH_GLOBS=(
    '*/secrets/*'
    '*/secrets'
    'secrets/*'
    'secrets'
    '*.secret'
    '*.pem'
    '*.p12'
    '*.pfx'
    '*.key'
    '*/.strongbox-keyid'
    '.env'
    '*.env'
    '.env.*'
    '*/.env.*'
    '*/id_rsa'
    '*/id_ed25519'
    '*/.aws/credentials'
    '*/.netrc'
    '*/config.env'
    '*/.pgpass'
    '*/proc/*/environ'
    '$CLAUDE_SECRET_DIR'
    '$CLAUDE_SECRET_DIR/*'
    '${CLAUDE_SECRET_DIR}'
    '${CLAUDE_SECRET_DIR}/*'
    '*/tmp/claude-*-vault'
    '*/tmp/claude-*-vault/*'
)

# Overrides: paths that look secret but hold placeholders / public material.
SECRET_PATH_ALLOW=(
    '*.pub'
    '*.tmpl'
    '*config.env.example'
    '*.example'
)

# Self-referential paths whose CONTENTS legitimately embed secret-shaped example
# vectors: the pattern library itself, the firewall tests, the design docs, and
# the SDD scratch dir (diffs/reports). The PostToolUse scrubber skips scanning a
# tool result whose target is one of these — otherwise every Read/Grep/cat of the
# firewall's own source fires a false breach alarm, training the alarm to be
# ignored. This is a PATH skip, NOT a content allowlist: a real secret in any
# ordinary file is still detected; only the firewall's own definition/test/doc
# files are exempt. Kept tight so collision with a genuine secret file is
# implausible; Layer 1 still guards the original source reads regardless.
SECRET_SCAN_SKIP_PATHS=(
    '*/hooks/secret-patterns.sh'
    '*/hooks/secret-*.test.sh'
    '*secret-context-firewall*'
    '*/breach-ledger.log'
    '*/.superpowers/*'
)

# scan_content_for_secrets [text]: reads $1 or stdin. Prints matched class per
# line. Returns 0 if any secret found, 1 if clean.
scan_content_for_secrets() {
    local text entry class re found=1
    if [[ $# -ge 1 ]]; then text="$1"; else text="$(cat)"; fi
    for entry in "${SECRET_CONTENT_PATTERNS[@]}"; do
        class="${entry%%|*}"; re="${entry#*|}"
        if printf '%s' "$text" | grep -E -- "$re" >/dev/null; then
            printf '%s\n' "$class"; found=0
        fi
    done
    return $found
}

# redact_secrets <text>: replaces every secret span with a class-tagged marker.
# Uses '#' as the sed delimiter because patterns contain '/'.
redact_secrets() {
    local text="$1" entry class re
    for entry in "${SECRET_CONTENT_PATTERNS[@]}"; do
        class="${entry%%|*}"; re="${entry#*|}"
        text="$(printf '%s' "$text" | sed -E "s#${re}#[REDACTED-SECRET-BREACH:${class}]#g")"
    done
    printf '%s' "$text"
}

# secret_patterns_json: prints SECRET_CONTENT_PATTERNS as a JSON array of {class, re}.
secret_patterns_json() {
    local entry
    for entry in "${SECRET_CONTENT_PATTERNS[@]}"; do
        jq -nc --arg class "${entry%%|*}" --arg re "${entry#*|}" '{class: $class, re: $re}'
    done | jq -sc .
}

# redact_json_strings: reads a JSON value on stdin and prints it with every secret span in
# every string leaf and every object key replaced by a class-tagged marker (a structured
# result can carry a secret as a key). Numbers, booleans and nesting are untouched, so the
# value keeps its shape.
redact_json_strings() {
    jq -c --argjson pats "$(secret_patterns_json)" '
        def redact: reduce $pats[] as $p (.; gsub($p.re; "[REDACTED-SECRET-BREACH:" + $p.class + "]"));
        walk(if type == "string" then redact elif type == "object" then with_entries(.key |= redact) else . end)'
}

_ASCII_UPPER=ABCDEFGHIJKLMNOPQRSTUVWXYZ
_ASCII_LOWER=abcdefghijklmnopqrstuvwxyz

# ascii_lower <word>: set ASCII_LOWER to <word> with A-Z folded to a-z and every other character kept (bash 3.2 has
# no ${word,,}).
ascii_lower() {
    local s="$1" ch p i
    ASCII_LOWER=""
    for (( i = 0; i < ${#s}; i++ )); do
        ch="${s:i:1}"
        p="${_ASCII_UPPER%%"$ch"*}"
        if (( ${#p} < 26 )); then ch="${_ASCII_LOWER:${#p}:1}"; fi
        ASCII_LOWER+="$ch"
    done
}

# Every non-ASCII letter whose full case fold (Unicode CaseFolding.txt, C and F) is ASCII, each before its fold: APFS
# folds case fully, so creds.<long s>ecret opens creds.secret and di<ff ligature> runs diff. Byte escapes, as bash
# 3.2 has no \u: long s, Kelvin sign, sharp s, capital sharp s, then the ligatures ff fi fl ffi ffl, long st and st.
_NAME_FOLDS=(
    $'\xc5\xbf' 's' $'\xe2\x84\xaa' 'k' $'\xc3\x9f' 'ss' $'\xe1\xba\x9e' 'ss'
    $'\xef\xac\x80' 'ff' $'\xef\xac\x81' 'fi' $'\xef\xac\x82' 'fl' $'\xef\xac\x83' 'ffi' $'\xef\xac\x84' 'ffl'
    $'\xef\xac\x85' 'st' $'\xef\xac\x86' 'st'
)
# One bracket of the letters, not an @(…) alternation: *@(…)* is super-linear on a long word. In a C locale the
# bracket holds their bytes instead, a superset that name_fold resolves.
_NAME_FOLD_ANY=""
for (( _i = 0; _i < ${#_NAME_FOLDS[@]}; _i += 2 )); do
    _NAME_FOLD_ANY+="${_NAME_FOLDS[_i]}"
done
_NAME_FOLD_ANY="*[$_NAME_FOLD_ANY]*"
unset _i

# name_fold <word>: set NAME_FOLD to <word> with each letter of _NAME_FOLDS written as its ASCII fold. A caller on a
# hot path tests [[ <word> == $_NAME_FOLD_ANY ]] first.
name_fold() {
    local s="$1" i
    for (( i = 0; i < ${#_NAME_FOLDS[@]}; i += 2 )); do
        s="${s//"${_NAME_FOLDS[i]}"/${_NAME_FOLDS[i+1]}}"
    done
    # shellcheck disable=SC2034  # read by the guards
    NAME_FOLD="$s"
}

# _glob_fold <glob>: set _GLOB_FOLD to <glob> with each ASCII letter written as a bracket of both its cases, so the
# pattern matches case-insensitively with no shopt toggled per test. The globs hold no bracket of their own.
_glob_fold() {
    local ch p i
    ascii_lower "$1"
    _GLOB_FOLD=""
    for (( i = 0; i < ${#ASCII_LOWER}; i++ )); do
        ch="${ASCII_LOWER:i:1}"
        p="${_ASCII_LOWER%%"$ch"*}"
        if (( ${#p} < 26 )); then ch="[$ch${_ASCII_UPPER:${#p}:1}]"; fi
        _GLOB_FOLD+="$ch"
    done
}

# _secret_path_alternations: join each glob list into one @(…|…) pattern, matched against "/<path>" so a */X glob also
# covers a bare X (config.env, id_rsa, .aws/credentials from ~). [[ == ]] matches a pattern as if extglob were on, so
# one test replaces a loop over the globs: path_is_secret runs once per operand, and a 64 KiB command can carry 30,000
# of them. No glob may contain |, ( or ): one would split or close the alternation. A glob that starts with * is kept
# as it is (the * also takes the extra /); any other glob gets a leading /, so "/<path>" matches it exactly when
# <path> does. Both alternations fold ASCII case: a case-insensitive file system (macOS, Windows) opens .ENV as .env.
# Also derive SECRET_PATH_REPRESENTATIVES, one name per glob: its last component with every * replaced by x,
# duplicates dropped; and SECRET_PATH_FRAGMENT_RE, an awk regex of the longest literal piece of each such "/"-adjusted
# glob, lower-cased (each of . $ { } bracketed): "/<path>", lower-cased, can match a glob only if it holds that piece,
# so a path matching none cannot be secret.
_secret_path_alternations() {
    local IFS='|' g gp last piece rest best seen='|' lb='{' rb='}'
    local -a any=() allow=() pieces=()
    SECRET_PATH_REPRESENTATIVES=()
    for g in "${SECRET_PATH_GLOBS[@]}"; do
        if [[ "$g" == '*'* ]]; then gp="$g"; else gp="/$g"; fi
        _glob_fold "$gp"
        any+=("$_GLOB_FOLD")
        best=""
        rest="$gp"
        while [[ -n "$rest" ]]; do
            piece="${rest%%\**}"
            if (( ${#piece} > ${#best} )); then best="$piece"; fi
            if [[ "$rest" == *\** ]]; then rest="${rest#*\*}"; else rest=""; fi
        done
        ascii_lower "$best"
        best="${ASCII_LOWER//./[.]}"
        best="${best//\$/[\$]}"
        best="${best//$lb/[$lb]}"
        pieces+=("${best//$rb/[$rb]}")
        last="${g##*/}"
        last="${last//\*/x}"
        if [[ "$seen" != *"|$last|"* ]]; then
            SECRET_PATH_REPRESENTATIVES+=("$last")
            seen+="$last|"
        fi
    done
    for g in "${SECRET_PATH_ALLOW[@]}"; do
        if [[ "$g" == '*'* ]]; then gp="$g"; else gp="/$g"; fi
        _glob_fold "$gp"
        allow+=("$_GLOB_FOLD")
    done
    _SECRET_PATH_ANY="@(${any[*]})"
    _SECRET_ALLOW_ANY="@(${allow[*]})"
    _SECRET_REPRESENTATIVE_LIST="$seen"
    # shellcheck disable=SC2034  # read by secret-bash-guard.sh
    SECRET_PATH_FRAGMENT_RE="${pieces[*]}"
}
_secret_path_alternations

# Bounds on path_glob_is_secret, whose cost under bash 3.2 grows with the wildcards in the operand: glob tests allowed
# per hook run (one hook run sources this file once), the longest component matched, the most * characters in a matched
# component plus, when it has a *, its [ characters (next to a *, a bracket expression costs as much to match as
# another star; alone it is linear), and the running count of tests.
_SECRET_GLOB_BUDGET=500
_SECRET_GLOB_MAX_CHARS=128
_SECRET_GLOB_MAX_WILD=5
_SECRET_GLOB_TESTS=0

# path_is_secret <path>: 0 if <path> or /<path> matches a secret glob and neither matches an allow glob, else 1.
path_is_secret() {
    # The alternations are intentional patterns here — do NOT quote them.
    # shellcheck disable=SC2053
    [[ "/$1" == $_SECRET_PATH_ANY && "/$1" != $_SECRET_ALLOW_ANY ]]
}

# _glob_brackets_as_any <pattern>: set _GLOB_ANY to <pattern> with each bracket expression, and each [ that opens
# none, read as ?: a superset of what it matches, leaving every ( outside a bracket. A backslash escapes the next
# character, inside a bracket or out, and a [:class:], [.sym.] or [=eq=] inside a bracket is skipped whole: neither ]
# closes the bracket.
_glob_brackets_as_any() {
    local p="$1" i=0 j e d t n=${#1}
    _GLOB_ANY=""
    while (( i < n )); do
        if [[ "${p:i:1}" == '\' ]]; then
            _GLOB_ANY+="${p:i:2}"
            i=$(( i + 2 ))
            continue
        fi
        if [[ "${p:i:1}" != '[' ]]; then
            _GLOB_ANY+="${p:i:1}"
            i=$(( i + 1 ))
            continue
        fi
        j=$(( i + 1 ))
        if [[ "${p:j:1}" == [\!^] ]]; then j=$(( j + 1 )); fi
        if [[ "${p:j:1}" == ']' ]]; then j=$(( j + 1 )); fi
        e=-1
        while (( j < n )); do
            if [[ "${p:j:1}" == '\' ]]; then
                j=$(( j + 2 ))
                continue
            fi
            if [[ "${p:j:1}" == ']' ]]; then
                e=$j
                break
            fi
            d="${p:j+1:1}"
            if [[ "${p:j:1}" == '[' && "$d" == [:.=] ]]; then
                t="${p:j+2}"
                if [[ "$t" == *"$d]"* ]]; then
                    t="${t%%"$d]"*}"
                    j=$(( j + ${#t} + 4 ))
                    continue
                fi
            fi
            j=$(( j + 1 ))
        done
        _GLOB_ANY+='?'
        if (( e < 0 )); then i=$(( i + 1 )); else i=$(( e + 1 )); fi
    done
}

# path_glob_is_secret <form> [remote]: 0 if the last path component of <form> holds *, ? or [ and, read as a pattern,
# matches a representative secret name for which path_is_secret holds in its place, else 1. A pattern that does not
# start with . cannot match a dotfile, and a component made only of * and ? is skipped (it would match every name). A
# local component holding ( outside a bracket expression is skipped too: that ( is literal (bash-guard denies an
# unquoted one, and fnmatch-style consumers have no groups) and no secret name holds one; inside a bracket, a ( is a
# member like any other. Given remote (a host:path operand, which a remote shell may expand), a ( makes the component
# a pattern, and with its brackets read as ?, the span from its first ( to its last ), with any extglob operator before
# it, is matched as a *: a superset of what a group matches, with no exponential match; the dotfile rule is then
# dropped, as the group may supply the leading dot. A component over _SECRET_GLOB_MAX_CHARS characters, or with more
# than _SECRET_GLOB_MAX_WILD * characters (plus [ characters, when it has a *), and every test once
# _SECRET_GLOB_BUDGET have run, is not matched: it is treated as secret (fail closed). The match folds ASCII case, as
# git's icase pathspec magic does; nocasematch is set for it and cleared after, so a caller must not rely on it.
path_glob_is_secret() {
    local rc=0
    shopt -s nocasematch
    _path_glob_match "$@" || rc=1
    shopt -u nocasematch
    return $rc
}

_path_glob_match() {
    local c="$1" dir="" r s pre post dots
    # ${1%/*} then a substring, not ${1##*/}: a longest-prefix removal is quadratic in the operand's length.
    if [[ "$1" == */* ]]; then
        dir="${1%/*}"
        c="${1:${#dir}+1}"
        dir+="/"
    fi
    if [[ "${2:-}" == remote ]]; then
        if [[ "$c" != *[\*\?\[\(]* || "$c" != *[!\*\?]* ]]; then
            return 1
        fi
        r="${c%%[\*\?\[\(]*}"
        if [[ "${c:${#r}:1}" == '(' ]]; then
            r="${r%[@!+]}"
        fi
    else
        if [[ "$c" != *[\*\?\[]* || "$c" != *[!\*\?]* ]] || [[ "$c" == *\(* && "$c" != *\[* ]]; then
            return 1
        fi
        r="${c%%[\*\?\[]*}"
    fi
    # The pattern's literal prefix must start some representative (the list holds each as |r|).
    if [[ -n "$r" && "$_SECRET_REPRESENTATIVE_LIST" != *"|$r"* ]]; then
        return 1
    fi
    # bash 3.2 backtracks per representative on stacked wildcards, so a component too long or too wildcarded to
    # match cheaply, or any glob test past the per-run budget, is treated as secret (fail closed) instead.
    _SECRET_GLOB_TESTS=$(( _SECRET_GLOB_TESTS + 1 ))
    if (( _SECRET_GLOB_TESTS > _SECRET_GLOB_BUDGET || ${#c} > _SECRET_GLOB_MAX_CHARS )); then
        return 0
    fi
    s="$c"
    if [[ "$c" == *\(* && "$c" == *\[* ]]; then
        _glob_brackets_as_any "$c"
        s="$_GLOB_ANY"
    fi
    # dots marks a component whose dotfile filter applies; a group may supply the leading . itself.
    dots=1
    if [[ "$s" == *\(* ]]; then
        if [[ "${2:-}" != remote ]]; then
            return 1
        fi
        pre="${s%%\(*}"
        post=""
        if [[ "$s" == *\(*\)* ]]; then
            post="${s##*\)}"
        fi
        c="${pre%[@!+?*]}*$post"
        dots=0
    fi
    r="${c//[!\*]/}"
    if [[ -n "$r" ]]; then
        r+="${c//[!\[]/}"
    fi
    if (( ${#r} > _SECRET_GLOB_MAX_WILD )); then
        return 0
    fi
    for r in "${SECRET_PATH_REPRESENTATIVES[@]}"; do
        if (( dots )) && [[ "$r" == .* && "$c" != .* ]]; then
            continue
        fi
        # shellcheck disable=SC2053  # c is the operand's own pattern
        if [[ "$r" == $c ]] && path_is_secret "$dir$r"; then
            return 0
        fi
    done
    return 1
}

# path_is_scan_exempt <path>: 0 if the path is a firewall self-definition/test/
# doc file whose contents legitimately embed example secret vectors (so the
# output scrubber should NOT scan a result targeting it), else 1. Empty path
# (many tools carry no path) is never exempt.
path_is_scan_exempt() {
    local p="$1" g
    [[ -z "$p" ]] && return 1
    for g in "${SECRET_SCAN_SKIP_PATHS[@]}"; do
        # shellcheck disable=SC2254
        case "$p" in $g) return 0 ;; esac
    done
    return 1
}
