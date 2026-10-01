#!/usr/bin/env bash
# Runs the standalone git leak guard suites, every tests/test-*.sh that sources tests/guard-test-lib.sh, and reports
# each of their checks as a harness row. Sourced by tests/run.sh.

test_leak_guards() {
    local suite out line reason rc rows=0 suites=0
    for suite in "$REPO_ROOT"/tests/test-*.sh; do
        if ! grep -q 'guard-test-lib\.sh' "$suite"; then
            continue
        fi
        suites=$((suites + 1))
        rc=0
        out=$(bash "$suite" 2>&1) || rc=$?
        while IFS= read -r line; do
            case "$line" in
                'PASS '*)
                    pass "${line#PASS }"
                    rows=$((rows + 1))
                    ;;
                'FAIL '*)
                    fail "${line#FAIL }"
                    rows=$((rows + 1))
                    ;;
                'SKIP '*)
                    line="${line#SKIP }"
                    reason="${line##* (}"
                    skip "${line% (*}" "${reason%)}"
                    rows=$((rows + 1))
                    ;;
            esac
        done <<<"$out"
        if [[ $rc -ne 0 ]] && ! grep -q '^FAIL ' <<<"$out"; then
            fail "${suite##*/} exited $rc without a FAIL line" "$(tail -n 5 <<<"$out")"
        fi
    done
    if [[ $suites -eq 0 || $rows -eq 0 ]]; then
        fail "no git leak guard suite reported a check"
    fi
}
