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
    '*/id_rsa'
    '*/id_ed25519'
    '*/.aws/credentials'
    '*/.netrc'
    '*/config.env'
    '*/.pgpass'
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
# every string leaf replaced by a class-tagged marker. Keys, numbers, booleans and nesting
# are untouched, so the value keeps its shape.
redact_json_strings() {
    jq -c --argjson pats "$(secret_patterns_json)" '
        def redact: reduce $pats[] as $p (.; gsub($p.re; "[REDACTED-SECRET-BREACH:" + $p.class + "]"));
        walk(if type == "string" then redact else . end)'
}

# _secret_path_alternations: set _SECRET_PATH_ANY and _SECRET_ALLOW_ANY to @(g1|g2|…) of SECRET_PATH_GLOBS and
# SECRET_PATH_ALLOW. [[ == ]] matches a pattern as if extglob were on, so one test replaces a loop over the globs:
# path_is_secret runs once per operand, and a 64 KiB command can carry 30,000 of them. No glob may contain |, ( or ).
_secret_path_alternations() {
    local IFS='|'
    _SECRET_PATH_ANY="@(${SECRET_PATH_GLOBS[*]})"
    _SECRET_ALLOW_ANY="@(${SECRET_PATH_ALLOW[*]})"
}
_secret_path_alternations

# path_is_secret <path>: 0 if secret-bearing and not allowlisted, else 1.
path_is_secret() {
    # The alternations are intentional patterns here — do NOT quote them.
    # shellcheck disable=SC2053
    [[ "$1" == $_SECRET_PATH_ANY && "$1" != $_SECRET_ALLOW_ANY ]]
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
