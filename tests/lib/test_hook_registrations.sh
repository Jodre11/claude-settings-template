#!/usr/bin/env bash
# Tests for the hook registrations in settings.json.tmpl. Sourced by tests/run.sh.

# _hr_commands: print every hook command registered in settings.json.tmpl, one per line.
_hr_commands() {
    jq -r '.hooks[][] | .hooks[] | .command' "$REPO_ROOT/settings.json.tmpl"
}

test_hook_registrations_scripts_exist() {
    local cmd path missing=""
    while IFS= read -r cmd; do
        # shellcheck disable=SC2088  # the tmpl stores a literal ~ for Claude Code to expand
        [[ "$cmd" == '~/.claude/hooks/'* ]] || continue
        path="$REPO_ROOT/${cmd#'~/.claude/'}"
        if [[ ! -x "$path" ]]; then
            missing+=" $cmd"
        fi
    done < <(_hr_commands)
    assert_equals "" "$missing" "every registered hook script exists and is executable"
}

test_hook_registrations_no_agent_guard() {
    assert_equals 0 "$(jq '[.hooks.PreToolUse[] | select(.matcher == "Agent")] | length' \
        "$REPO_ROOT/settings.json.tmpl")" "no PreToolUse group is registered on Agent"
    assert_equals "" "$(_hr_commands | grep -F agent-mode-guard.sh || true)" "agent-mode-guard.sh is not registered"
}

# test_hook_retired_names_gone: the three retired hook names are neither shipped nor registered.
test_hook_retired_names_gone() {
    local name
    for name in allow-permissions.sh allow-write-permissions.sh agent-mode-guard.sh; do
        if [[ -e "$REPO_ROOT/hooks/$name" ]]; then
            fail "$name is no longer shipped" "still present: hooks/$name"
        else
            pass "$name is no longer shipped"
        fi
        assert_equals "" "$(_hr_commands | grep -F "$name" || true)" "$name is not registered in settings.json.tmpl"
    done
}
