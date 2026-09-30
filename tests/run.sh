#!/usr/bin/env bash
# Run all tests under ~/.claude/tests, then every hooks/*.test.sh suite.
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

# Hook suites are standalone scripts: PASS/FAIL lines on stdout, non-zero exit on any failure.
printf '\n\033[1m%s\033[0m\n' "hook suites"
for suite in "${hook_suites[@]}"; do
    if output=$(bash "$suite" 2>&1); then
        pass "${suite##*/}"
    else
        fail "${suite##*/}" "$(grep -E '^FAIL' <<< "$output" || printf 'exited non-zero without a FAIL line')"
    fi
done

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
