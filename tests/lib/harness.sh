#!/usr/bin/env bash
# Minimal test harness — pass/fail/skip helpers with TAP-like output.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

_pass_count=0
_fail_count=0
_skip_count=0
_failures=()

pass() {
    local desc="$1"
    _pass_count=$((_pass_count + 1))
    printf '  \033[32m✓\033[0m %s\n' "$desc"
}

fail() {
    local desc="$1"
    local detail="${2:-}"
    _fail_count=$((_fail_count + 1))
    _failures+=("$desc")
    printf '  \033[31m✗\033[0m %s\n' "$desc"
    if [[ -n "$detail" ]]; then
        printf '    %s\n' "$detail"
    fi
}

skip() {
    local desc="$1"
    local reason="${2:-}"
    _skip_count=$((_skip_count + 1))
    printf '  \033[33m-\033[0m %s (skipped: %s)\n' "$desc" "$reason"
}

assert_file_exists() {
    local path="$1"
    local desc="${2:-file exists: $path}"
    if [[ -f "$REPO_ROOT/$path" ]]; then
        pass "$desc"
    else
        fail "$desc" "not found: $path"
    fi
}

assert_equals() {
    local expected="$1"
    local actual="$2"
    local desc="$3"
    if [[ "$expected" == "$actual" ]]; then
        pass "$desc"
    else
        fail "$desc" "expected: $expected, got: $actual"
    fi
}

assert_matches() {
    local pattern="$1"
    local value="$2"
    local desc="$3"
    if [[ "$value" =~ $pattern ]]; then
        pass "$desc"
    else
        fail "$desc" "value '$value' does not match pattern '$pattern'"
    fi
}

assert_not_matches() {
    local pattern="$1"
    local value="$2"
    local desc="$3"
    if [[ ! "$value" =~ $pattern ]]; then
        pass "$desc"
    else
        fail "$desc" "value '$value' unexpectedly matches pattern '$pattern'"
    fi
}

summary() {
    local total=$((_pass_count + _fail_count + _skip_count))
    echo ""
    printf '%d tests: \033[32m%d passed\033[0m' "$total" "$_pass_count"
    if [[ $_fail_count -gt 0 ]]; then
        printf ', \033[31m%d failed\033[0m' "$_fail_count"
    fi
    if [[ $_skip_count -gt 0 ]]; then
        printf ', \033[33m%d skipped\033[0m' "$_skip_count"
    fi
    echo ""

    if [[ $_fail_count -gt 0 ]]; then
        echo ""
        printf '\033[31mFailed:\033[0m\n'
        for f in "${_failures[@]}"; do
            printf '  - %s\n' "$f"
        done
        return 1
    fi
    return 0
}
