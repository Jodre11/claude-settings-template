#!/usr/bin/env bash
# secret-patterns.sh — single source of truth for secret recognition, sourced
# by the runtime firewall hooks (secret-*-guard.sh, secret-output-scrubber.sh).
# Two axes: high-precision VALUE shapes (scanned in every tool result) and
# conservative PATH globs (blocked before a read). Never emits raw values.

# class|ERE regex. Keep precision high — matches trigger redaction + alarm.
SECRET_CONTENT_PATTERNS=(
    'aws-access-key|AKIA[0-9A-Z]{16}'
    'aws-secret-key|aws_secret_access_key[[:space:]]*=[[:space:]]*[A-Za-z0-9/+]{40}'
    'private-key|-----BEGIN[A-Za-z ]*PRIVATE KEY-----'
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
        if printf '%s' "$text" | grep -Eq -- "$re"; then
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

# path_is_secret <path>: 0 if secret-bearing and not allowlisted, else 1.
path_is_secret() {
    local p="$1" g
    # $g is an intentional glob pattern here — do NOT quote it (SC2254).
    for g in "${SECRET_PATH_ALLOW[@]}"; do
        # shellcheck disable=SC2254
        case "$p" in $g) return 1 ;; esac
    done
    for g in "${SECRET_PATH_GLOBS[@]}"; do
        # shellcheck disable=SC2254
        case "$p" in $g) return 0 ;; esac
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
