#!/usr/bin/env bash
# Run all tests under ~/.claude/tests, then every hooks/*.test.sh suite, then the shellcheck gate CI runs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/lib/harness.sh"

# An empty glob expands to nothing, so a missing directory is reported below instead of running a literal pattern.
shopt -s nullglob
test_files=("$SCRIPT_DIR"/lib/test_*.sh)
hook_suites=("$REPO_ROOT"/hooks/*.test.sh)
shopt -u nullglob

for test_file in "${test_files[@]}"; do
    # shellcheck source=/dev/null
    source "$test_file"
done

# Discover and run all test_ functions
mapfile -t test_functions < <(declare -F | awk '{print $3}' | grep '^test_' | sort)

for fn in "${test_functions[@]}"; do
    section="${fn#test_}"
    section="${section//_/ }"
    printf '\n\033[1m%s\033[0m\n' "$section"
    "$fn"
done

# _screened <name> <rc> <output> <detail>: pass <name> when <rc> is 0, else fail it with <detail>. Output holding a
# secret-shaped value fails it, naming it but printing nothing of the output: the output scrubber scans every Bash
# result, so printing a fixture would raise a real breach alarm when run through the Bash tool. The scanner exits 0 on
# a hit and 1 when clean; any other status means the scan could not run, which also fails.
_screened() {
    local scan_rc=0
    # shellcheck disable=SC2016  # $1 belongs to the child bash
    printf '%s' "$3" | bash -c 'source "$1"; scan_content_for_secrets' _ "$REPO_ROOT/hooks/secret-patterns.sh" \
        >/dev/null 2>&1 || scan_rc=$?
    if (( scan_rc == 0 )); then
        fail "$1" "its output holds a secret-shaped value, not shown (exit $2); build fixtures at run time"
    elif (( scan_rc != 1 )); then
        fail "$1" "the secret scan could not run (exit $scan_rc), so its output is not shown"
    elif (( $2 == 0 )); then
        pass "$1"
    else
        fail "$1" "$4"
    fi
}

# Hook suites are standalone scripts: PASS/FAIL lines on stdout, non-zero exit on any failure.
printf '\n\033[1m%s\033[0m\n' "hook suites"
for suite in "${hook_suites[@]}"; do
    rc=0
    output=$(bash "$suite" 2>&1) || rc=$?
    detail=$(grep -E '^FAIL' <<< "$output" || printf 'exited non-zero without a FAIL line')
    _screened "${suite##*/}" "$rc" "$output" "$detail"
done

# CI's shellcheck job runs the same script, so a local pass cannot hide a red CI job. With no shellcheck installed the
# script exits 127, which fails the run: the gate must not vanish silently.
printf '\n\033[1m%s\033[0m\n' "shellcheck"
rc=0
output=$(bash "$REPO_ROOT/scripts/shellcheck.sh" 2>&1) || rc=$?
_screened shellcheck "$rc" "$output" "$output"

# A run that found nothing to test must not pass.
if [[ ${#test_files[@]} -eq 0 ]]; then
    fail "test discovery" "no tests/lib/test_*.sh files found"
fi
if [[ ${#hook_suites[@]} -eq 0 ]]; then
    fail "test discovery" "no hooks/*.test.sh suites found"
fi
if [[ ${#test_functions[@]} -eq 0 ]]; then
    fail "test discovery" "no test_ functions found"
fi

summary
