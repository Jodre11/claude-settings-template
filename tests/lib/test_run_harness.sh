#!/usr/bin/env bash
# Tests for tests/run.sh itself: a run that discovers nothing to test must fail, not pass vacuously.

# _rh_tree <dir>: copy run.sh and harness.sh into <dir>/tests beside one passing test file and one passing hook suite.
_rh_tree() {
    mkdir -p "$1/tests/lib" "$1/hooks"
    cp "$REPO_ROOT/tests/run.sh" "$1/tests/run.sh"
    cp "$REPO_ROOT/tests/lib/harness.sh" "$1/tests/lib/harness.sh"
    printf '%s\n' 'test_ok() { pass "ok"; }' >"$1/tests/lib/test_ok.sh"
    printf '%s\n' 'echo "PASS: ok"' >"$1/hooks/ok.test.sh"
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
