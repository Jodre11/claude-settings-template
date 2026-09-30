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

# test_hook_compat_shims: a settings.json hydrated before reviewer-guard.sh and settings-edit-ask.sh replaced the old
# hooks still names these three scripts until it is re-hydrated; each must exist, stay unregistered here, and behave.
test_hook_compat_shims() {
    local shim out
    for shim in allow-permissions.sh allow-write-permissions.sh agent-mode-guard.sh; do
        if [[ -x "$REPO_ROOT/hooks/$shim" ]]; then
            pass "$shim exists and is executable"
        else
            fail "$shim exists and is executable" "not found or not executable: hooks/$shim"
        fi
        assert_equals "" "$(_hr_commands | grep -F "$shim" || true)" "$shim is not registered in settings.json.tmpl"
    done

    if out=$(jq -nc '{tool_input:{command:"git commit -m x"}, agent_type:"code-review-suite:correctness-reviewer"}' \
            | "$REPO_ROOT/hooks/allow-permissions.sh" 2>/dev/null); then
        assert_equals deny "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$out" 2>/dev/null)" \
            "allow-permissions.sh shim denies a reviewer git commit"
    else
        fail "allow-permissions.sh shim denies a reviewer git commit" "hook exited non-zero or is missing"
    fi

    if out=$(jq -nc '{tool_input:{command:"rm -rf /tmp/claude-x /home/me"}, agent_type:"general-purpose",
            agent_id:"agent-1"}' | "$REPO_ROOT/hooks/allow-permissions.sh" 2>/dev/null); then
        assert_equals "" "$out" "allow-permissions.sh shim no longer allows a subagent command by its first word"
    else
        fail "allow-permissions.sh shim no longer allows a subagent command by its first word" \
            "hook exited non-zero or is missing"
    fi

    if out=$(jq -nc '{tool_input:{file_path:"/x/.claude/settings.json"}}' \
            | "$REPO_ROOT/hooks/allow-write-permissions.sh" 2>/dev/null); then
        assert_equals ask "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$out" 2>/dev/null)" \
            "allow-write-permissions.sh shim asks on a settings.json write"
    else
        fail "allow-write-permissions.sh shim asks on a settings.json write" "hook exited non-zero or is missing"
    fi

    if out=$(jq -nc '{tool_input:{file_path:"/tmp/claude-x/../../etc/passwd"}}' \
            | "$REPO_ROOT/hooks/allow-write-permissions.sh" 2>/dev/null); then
        assert_equals "" "$out" "allow-write-permissions.sh shim no longer allows a write that escapes the temp dir"
    else
        fail "allow-write-permissions.sh shim no longer allows a write that escapes the temp dir" \
            "hook exited non-zero or is missing"
    fi

    if out=$(jq -nc '{tool_name:"Agent", tool_input:{subagent_type:"general-purpose", prompt:"x"},
            permission_mode:"default"}' | "$REPO_ROOT/hooks/agent-mode-guard.sh" 2>/dev/null); then
        assert_equals "" "$out" "agent-mode-guard.sh shim makes no decision on an Agent call"
    else
        fail "agent-mode-guard.sh shim makes no decision on an Agent call" "hook exited non-zero or is missing"
    fi
}
