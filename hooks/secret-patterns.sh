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
    'bedrock-arn|application-inference-profile/[a-z0-9]{10,16}'
)

# Secret-bearing path globs (bash `case` patterns). '*/secrets/*' matches the
# the organisation strongbox convention (files decrypted to plaintext in the working tree).
SECRET_PATH_GLOBS=(
    '*/secrets/*'
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

# Combined ERE of just the regex halves, cached on first use.
_secret_combined_re() {
    local entry parts=()
    for entry in "${SECRET_CONTENT_PATTERNS[@]}"; do parts+=("${entry#*|}"); done
    local IFS='|'; printf '%s' "${parts[*]}"
}

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
    for g in "${SECRET_PATH_ALLOW[@]}"; do
        case "$p" in $g) return 1 ;; esac
    done
    for g in "${SECRET_PATH_GLOBS[@]}"; do
        case "$p" in $g) return 0 ;; esac
    done
    return 1
}
