#!/usr/bin/env bash
# Tests for api-failure-log.sh. The StopFailure payload shape was captured from CLI 2.1.283 (a turn that ended on
# an invalid model): session_id, transcript_path, cwd, prompt_id, hook_event_name, error, last_assistant_message.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/api-failure-log.sh"
pass=0; fail=0
ok()  { printf 'PASS: %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); }

TMP="$(mktemp -d /tmp/claude-apilog-test.XXXX)"
export HOME_OVERRIDE="$TMP"
LOG="$TMP/.claude/telemetry/api-failures.jsonl"

out=$(jq -nc '{session_id: "s1", transcript_path: "/x/t.jsonl", cwd: "/work", prompt_id: "p1",
    hook_event_name: "StopFailure", error: "model_not_found",
    last_assistant_message: "API Error (m): 400 The provided model identifier is invalid."}' | "$HOOK")
if [[ -z "$out" ]]; then ok "StopFailure logging prints nothing"; else bad "unexpected output: $out"; fi
rec=$(tail -1 "$LOG" 2>/dev/null)
if [[ "$(jq -c 'keys' <<<"$rec" 2>/dev/null)" == '["cwd","error","error_details","session_id","ts"]' ]]; then
    ok "the record holds only ts, error, error_details, session_id and cwd"
else
    bad "record keys: $rec"
fi
if [[ "$(jq -c '[.error, .error_details, .session_id, .cwd]' <<<"$rec" 2>/dev/null)" \
        == '["model_not_found",null,"s1","/work"]' ]]; then
    ok "the record carries the payload values"
else
    bad "record values: $rec"
fi

jq -nc '{session_id: "s2", cwd: "/work", hook_event_name: "StopFailure", error: "server_error",
    error_details: "HTTP 529"}' | "$HOOK" >/dev/null
if [[ "$(tail -1 "$LOG" | jq -r '.error_details')" == "HTTP 529" ]]; then
    ok "error_details is recorded when present"
else
    bad "error_details missing: $(tail -1 "$LOG")"
fi

before=$(wc -l < "$LOG")
out=$(jq -nc '{session_id: "s3", cwd: "/work", hook_event_name: "PostToolUseFailure",
    error: "Exit code 1\nMARKER-9f3a2b7c-should-not-be-logged"}' | "$HOOK")
after=$(wc -l < "$LOG")
if [[ -z "$out" && "$before" -eq "$after" ]]; then
    ok "PostToolUseFailure is ignored: no output, no record appended"
else
    bad "PostToolUseFailure leaked: out=$out before=$before after=$after last=$(tail -1 "$LOG")"
fi

if [[ "$(jq -c '[.hooks | to_entries[] | select(any(.value[].hooks[]; .command == "~/.claude/hooks/api-failure-log.sh"))
        | .key]' "$DIR/../settings.json.tmpl")" == '["StopFailure"]' ]]; then
    ok "settings.json.tmpl registers api-failure-log.sh on StopFailure only"
else
    bad "api-failure-log.sh is registered on more than StopFailure"
fi

rm -rf "$TMP"
echo "-----"; echo "passed: $pass  failed: $fail"; [ "$fail" -eq 0 ]
