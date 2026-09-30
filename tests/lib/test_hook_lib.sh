#!/usr/bin/env bash
# Tests for the decision emitters in hooks/_lib.sh. Sourced by tests/run.sh.

# _hl_emit <emitter> <reason>: run hooks/_lib.sh's <emitter> with <reason> in a child bash (every emitter exits) and
# print what it wrote.
_hl_emit() {
    # shellcheck disable=SC2016  # $1..$3 belong to the child bash
    bash -c 'source "$1/hooks/_lib.sh"; "$2" "$3"' _ "$REPO_ROOT" "$1" "$2"
}

# _hl_reason: print a reason holding every control character from U+0001 to U+001F, a quote, a backslash and an &.
_hl_reason() {
    local i hex c r=$'tab\tcr'
    for (( i = 1; i < 32; i++ )); do
        printf -v hex '%02x' "$i"
        printf -v c "\\x$hex"
        r+="$c"
    done
    printf '%s' "$r\"quote\" \\back & end"
}

test_hook_lib_decisions_survive_control_characters() {
    local reason emitter
    reason=$(_hl_reason)
    for emitter in hook_allow hook_ask hook_deny; do
        assert_equals "$reason" \
            "$(_hl_emit "$emitter" "$reason" | jq -j '.hookSpecificOutput.permissionDecisionReason' 2>&1)" \
            "$emitter writes valid JSON that keeps every control character of the reason"
    done
    assert_equals "$reason" "$(_hl_emit hook_prompt_block "$reason" | jq -j '.reason' 2>&1)" \
        "hook_prompt_block writes valid JSON that keeps every control character of the reason"
}

# A long reason (a deny quoting a long operand) must come out as whole as a short one.
test_hook_lib_long_reasons_survive() {
    local reason
    reason="$(_hl_reason) $(printf 'é\\%.0s' {1..400})"
    assert_equals "$reason" \
        "$(_hl_emit hook_deny "$reason" | jq -j '.hookSpecificOutput.permissionDecisionReason' 2>&1)" \
        "hook_deny writes valid JSON that keeps a long reason whole"
    assert_equals "$reason" "$(_hl_emit hook_prompt_block "$reason" | jq -j '.reason' 2>&1)" \
        "hook_prompt_block writes valid JSON that keeps a long reason whole"
}
