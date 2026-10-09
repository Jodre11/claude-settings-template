#!/usr/bin/env bash
# Tests for tests/run.sh itself: a run that discovers nothing to test must fail, not pass vacuously, and so must a run
# whose shellcheck gate fails.

# _rh_tree <dir>: copy run.sh, harness.sh and the secret patterns into <dir> beside one passing test file, one passing
# hook suite and a passing stub of the shellcheck gate.
_rh_tree() {
    mkdir -p "$1/tests/lib" "$1/hooks" "$1/scripts"
    cp "$REPO_ROOT/tests/run.sh" "$1/tests/run.sh"
    cp "$REPO_ROOT/tests/lib/harness.sh" "$1/tests/lib/harness.sh"
    cp "$REPO_ROOT/hooks/secret-patterns.sh" "$1/hooks/secret-patterns.sh"
    printf '%s\n' 'test_ok() { pass "ok"; }' >"$1/tests/lib/test_ok.sh"
    printf '%s\n' 'echo "PASS: ok"' >"$1/hooks/ok.test.sh"
    printf '%s\n' 'exit 0' >"$1/scripts/shellcheck.sh"
}

# _rh_run <dir>: run <dir>/tests/run.sh; sets RH_OUT and RH_RC.
_rh_run() {
    RH_RC=0
    RH_OUT=$(bash "$1/tests/run.sh" 2>&1) || RH_RC=$?
}

test_run_harness_fails_closed_on_empty_discovery() {
    local tmp
    tmp=$(mktemp -d)
    _rh_tree "$tmp"
    _rh_run "$tmp"
    assert_equals 0 "$RH_RC" "a tree with a test file and a hook suite passes"

    rm "$tmp/hooks/ok.test.sh"
    _rh_run "$tmp"
    assert_equals 1 "$RH_RC" "a tree with no hook suites fails"
    assert_matches 'no hooks/\*\.test\.sh suites found' "$RH_OUT" "the failure names the missing hook suites"

    printf '%s\n' 'echo "PASS: ok"' >"$tmp/hooks/ok.test.sh"
    rm "$tmp/tests/lib/test_ok.sh"
    _rh_run "$tmp"
    assert_equals 1 "$RH_RC" "a tree with no test files fails"
    assert_matches 'no tests/lib/test_\*\.sh files found' "$RH_OUT" "the failure names the missing test files"

    printf '%s\n' '_helper() { :; }' >"$tmp/tests/lib/test_ok.sh"
    _rh_run "$tmp"
    assert_equals 1 "$RH_RC" "a tree whose test files define no test_ function fails"
    assert_matches 'no test_ functions found' "$RH_OUT" "the failure names the missing test functions"
    rm -rf "$tmp"
}

# A hook suite that prints a secret-shaped value fails, whether it passes or not, and the run prints none of it. The
# value is assembled at run time, so this file never holds one, and no assertion here echoes the run's output.
test_run_harness_fails_a_suite_that_prints_a_secret_shape() {
    local tmp key="AKIA""IOSFODNN7EXAMPLE"
    tmp=$(mktemp -d)
    _rh_tree "$tmp"
    printf 'echo "PASS: ok %s"\n' "$key" >"$tmp/hooks/leaky.test.sh"
    _rh_run "$tmp"
    assert_equals 1 "$RH_RC" "a passing suite that prints a secret shape fails the run"
    if [[ "$RH_OUT" == *leaky.test.sh* ]]; then pass "the failure names the suite"
    else fail "the failure names the suite" "leaky.test.sh not named (output withheld)"; fi
    if [[ "$RH_OUT" != *"$key"* ]]; then pass "the run prints nothing of the value"
    else fail "the run prints nothing of the value" "the value reached the output (withheld)"; fi
    printf 'echo "FAIL: x %s"; exit 1\n' "$key" >"$tmp/hooks/leaky.test.sh"
    _rh_run "$tmp"
    if [[ "$RH_RC" == 1 && "$RH_OUT" != *"$key"* ]]; then pass "a failing suite's FAIL lines are withheld too"
    else fail "a failing suite's FAIL lines are withheld too" "rc $RH_RC or the value reached the output"; fi
    rm -rf "$tmp"
}

# When the secret scan cannot run (its library is missing), the run fails closed: a failing suite's output stays
# withheld rather than being printed unscanned.
test_run_harness_fails_closed_when_the_secret_scan_cannot_run() {
    local tmp key="AKIA""IOSFODNN7EXAMPLE"
    tmp=$(mktemp -d)
    _rh_tree "$tmp"
    rm "$tmp/hooks/secret-patterns.sh"
    printf 'echo "FAIL: x %s"; exit 1\n' "$key" >"$tmp/hooks/leaky.test.sh"
    _rh_run "$tmp"
    assert_equals 1 "$RH_RC" "a run whose secret scan cannot run fails"
    if [[ "$RH_OUT" == *leaky.test.sh* ]]; then pass "the failure names the suite when the scan cannot run"
    else fail "the failure names the suite when the scan cannot run" "leaky.test.sh not named (output withheld)"; fi
    if [[ "$RH_OUT" != *"$key"* ]]; then pass "an unscanned suite's output is withheld"
    else fail "an unscanned suite's output is withheld" "the value reached the output (withheld)"; fi
    rm -rf "$tmp"
}

# The shellcheck gate fails the run on a finding, showing it, and when shellcheck is not installed.
test_run_harness_fails_on_the_shellcheck_gate() {
    local tmp
    tmp=$(mktemp -d)
    _rh_tree "$tmp"
    printf '%s\n' 'echo "./hooks/x.sh:1:1: warning: x [SC0000]"; exit 1' >"$tmp/scripts/shellcheck.sh"
    _rh_run "$tmp"
    assert_equals 1 "$RH_RC" "a run whose shellcheck gate finds a problem fails"
    assert_matches 'hooks/x\.sh:1:1: warning' "$RH_OUT" "the failure shows the gate's finding"
    printf '%s\n' 'echo "shellcheck is not installed" >&2; exit 127' >"$tmp/scripts/shellcheck.sh"
    _rh_run "$tmp"
    assert_equals 1 "$RH_RC" "a run with no shellcheck installed fails"
    rm -rf "$tmp"
}
