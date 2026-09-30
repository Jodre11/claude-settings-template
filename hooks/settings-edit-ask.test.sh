#!/usr/bin/env bash
# Tests for settings-edit-ask.sh: a direct edit of ~/.claude/settings.json asks (reason pinned); every other path,
# including the session temp dir and a `..` escape from it, gets no decision, so the native rules decide.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/settings-edit-ask.sh"
pass=0; fail=0
ok()  { printf 'PASS: %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); }

# run <tool> <path>: the hook's stdout for a documented Edit / Write payload.
run() {
    jq -nc --arg t "$1" --arg p "$2" '{hook_event_name: "PreToolUse", tool_name: $t, tool_input: {file_path: $p}}' \
        | "$HOOK" 2>&1
}

want="settings.json is generated from settings.json.tmpl and is not tracked by git, so a direct edit stays on"
want+=" this machine only. For a permanent change, edit settings.json.tmpl and run scripts/apply-settings.sh."
want+=" Proceed only if testing locally."

for tool in Edit Write; do
    out=$(run "$tool" "$HOME/.claude/settings.json")
    if [[ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$out" 2>/dev/null)" == ask ]]; then
        ok "$tool of settings.json asks"
    else
        bad "$tool of settings.json did not ask: $out"
    fi
    if [[ "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$out" 2>/dev/null)" == "$want" ]]; then
        ok "the $tool ask reason describes the untracked, generated settings.json"
    else
        bad "$tool ask reason drifted: $out"
    fi
done

for p in "$HOME/.claude/settings.json.tmpl" /tmp/claude-x/notes.md /tmp/claude-x/../../etc/passwd; do
    out=$(run Write "$p")
    if [[ -z "$out" ]]; then ok "no decision for $p"; else bad "decided for $p: $out"; fi
done

out=$(printf '{"tool_input":{}}' | "$HOOK" 2>&1)
if [[ -z "$out" ]]; then ok "a payload with no path is ignored"; else bad "no-path payload decided: $out"; fi

TMPL="$DIR/../settings.json.tmpl"
if jq -e '.hooks.PreToolUse[] | select(.matcher == "Write|Edit") | .hooks[]
        | select(.command == "~/.claude/hooks/settings-edit-ask.sh")' "$TMPL" >/dev/null 2>&1; then
    ok "settings.json.tmpl registers settings-edit-ask.sh on Write|Edit"
else
    bad "settings.json.tmpl does not register settings-edit-ask.sh on Write|Edit"
fi
if jq -e '[.hooks[][] | .hooks[] | .command] | index("~/.claude/hooks/allow-write-permissions.sh") == null' \
        "$TMPL" >/dev/null 2>&1; then
    ok "settings.json.tmpl no longer registers allow-write-permissions.sh"
else
    bad "settings.json.tmpl still registers allow-write-permissions.sh"
fi

echo "-----"; echo "passed: $pass  failed: $fail"; [ "$fail" -eq 0 ]
