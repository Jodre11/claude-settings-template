#!/usr/bin/env bash
# Tests for tmpl-output-guard.sh. The fixtures mimic Stow: a relative leaf symlink (~/.zshrc) and a relative,
# folded directory symlink (~/.aws) into a dotfiles tree whose outputs sit beside their .tmpl sources.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/tmpl-output-guard.sh"
pass=0; fail=0
ok()  { printf 'PASS: %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); }

FX=$(mktemp -d)
FX=$(cd "$FX" && pwd -P)
mkdir -p "$FX/home" "$FX/dot/zsh" "$FX/dot/aws/.aws" "$FX/repo" "$FX/cyc"
for f in dot/zsh/.zshrc dot/aws/.aws/config repo/CLAUDE.md repo/settings.json; do
    printf 'x\n' >"$FX/$f.tmpl"
done
printf 'x\n' >"$FX/dot/zsh/.zshrc"
printf 'x\n' >"$FX/repo/plain.md"
ln -s ../dot/zsh/.zshrc "$FX/home/.zshrc"
ln -s ../dot/aws/.aws "$FX/home/.aws"
ln -s b "$FX/cyc/a"
ln -s a "$FX/cyc/b"

# run <tool> <path> [<cwd>]: the hook's stdout for a documented Edit / Write / NotebookEdit payload.
run() {
    jq -nc --arg t "$1" --arg p "$2" --arg c "${3:-/}" \
        '{hook_event_name: "PreToolUse", tool_name: $t, cwd: $c,
          tool_input: (if $t == "NotebookEdit" then {notebook_path: $p, new_source: "x"}
                       else {file_path: $p} end)}' | "$HOOK" 2>&1
}
# decision <hook-stdout>: deny / allow / ask, or none for empty or non-JSON output.
decision() {
    local d
    d=$(jq -r '.hookSpecificOutput.permissionDecision // "none"' <<<"$1" 2>/dev/null) || d=none
    printf '%s' "${d:-none}"
}
reason() { jq -r '.hookSpecificOutput.permissionDecisionReason // ""' <<<"$1" 2>/dev/null; }

# expect <decision> <description> <hook-stdout>
expect() {
    if [[ "$(decision "$3")" == "$1" ]]; then ok "$2"; else bad "$2 — got: $3"; fi
}

# want_msg <given-path> <resolved-output>: the pinned deny reason.
want_msg() {
    local fmt="HYDRATED OUTPUT: '%s' is generated from '%s.tmpl' by hydrate.sh, so a direct edit is lost or"
    fmt+=" reverted. Edit '%s.tmpl' instead, then run that repo's hydrate.sh."
    # shellcheck disable=SC2059  # the format string is the literal built above
    printf "$fmt" "$1" "$2" "$2"
}

out=$(run Edit "$FX/repo/CLAUDE.md")
expect deny "Edit of an output beside its .tmpl is denied" "$out"
if [[ "$(reason "$out")" == "$(want_msg "$FX/repo/CLAUDE.md" "$FX/repo/CLAUDE.md")" ]]; then
    ok "the deny reason names the .tmpl to edit"
else
    bad "deny reason drifted: $(reason "$out")"
fi

out=$(run Edit "$FX/home/.zshrc")
expect deny "Edit through a Stow leaf symlink is denied" "$out"
if [[ "$(reason "$out")" == "$(want_msg "$FX/home/.zshrc" "$FX/dot/zsh/.zshrc")" ]]; then
    ok "the reason names the resolved .tmpl, not the symlink"
else
    bad "symlink deny reason drifted: $(reason "$out")"
fi

expect deny "Edit through a Stow-folded directory symlink is denied" "$(run Edit "$FX/home/.aws/config")"
expect deny "Write of a not-yet-hydrated output is denied" "$(run Write "$FX/repo/CLAUDE.md")"
expect deny "NotebookEdit (notebook_path) is denied" "$(run NotebookEdit "$FX/repo/CLAUDE.md")"
expect deny "a relative file_path resolves against cwd" "$(run Edit CLAUDE.md "$FX/repo")"

out=$(run Write "$FX/repo/missing/../CLAUDE.md")
expect deny "a .. through a missing directory is denied" "$out"
if [[ "$(reason "$out")" == "$(want_msg "$FX/repo/missing/../CLAUDE.md" "$FX/repo/CLAUDE.md")" ]]; then
    ok "the reason names the normalised .tmpl"
else
    bad "normalised deny reason drifted: $(reason "$out")"
fi
expect deny "a relative .. through a missing directory is denied" "$(run Edit sub/../CLAUDE.md "$FX/repo")"
expect deny "a .. through a missing directory still follows a Stow symlink" "$(run Edit "$FX/home/nope/../.zshrc")"
expect deny "a . segment is denied" "$(run Edit "$FX/repo/./CLAUDE.md")"
expect deny "a doubled slash is denied" "$(run Edit "$FX//repo/CLAUDE.md")"
expect none "a .. that leaves the output's directory is allowed" "$(run Edit "$FX/repo/../elsewhere/CLAUDE.md")"
expect none "settings.json is exempt" "$(run Edit "$FX/repo/settings.json")"
expect none "a file with no .tmpl sibling is allowed" "$(run Edit "$FX/repo/plain.md")"
expect none "the .tmpl itself is editable" "$(run Edit "$FX/repo/CLAUDE.md.tmpl")"
expect none "a path under a missing directory is allowed" "$(run Write "$FX/nope/deeper/x")"
expect none "a symlink cycle terminates and allows" "$(run Edit "$FX/cyc/a")"
expect none "a payload with no path is ignored" "$(printf '{"tool_input":{}}' | "$HOOK" 2>&1)"

# shellcheck disable=SC2088  # a literal, unexpanded tilde path, as a tool payload can carry it
tilde_path='~/.zshrc'
out=$(jq -nc --arg p "$tilde_path" '{hook_event_name: "PreToolUse", tool_name: "Edit", cwd: "/",
        tool_input: {file_path: $p}}' | HOME="$FX/home" "$HOOK" 2>&1)
expect deny "a ~/ file_path expands against HOME, through the Stow symlink" "$out"

if jq -e '.hooks.PreToolUse[] | select(.matcher == "Edit|Write|NotebookEdit")
        | .hooks[] | select(.command == "~/.claude/hooks/tmpl-output-guard.sh")' \
        "$DIR/../settings.json.tmpl" >/dev/null 2>&1; then
    ok "settings.json.tmpl registers the guard on Edit|Write|NotebookEdit"
else
    bad "settings.json.tmpl does not register the guard on Edit|Write|NotebookEdit"
fi

rm -rf "$FX"
echo "-----"; echo "passed: $pass  failed: $fail"; [ "$fail" -eq 0 ]
