#!/usr/bin/env bash
# Hermetic tests for secret-output-scrubber.sh. Fixtures use the tool_response shapes
# observed in CLI 2.1.282 transcripts (toolUseResult): Bash {stdout, stderr, interrupted,
# isImage, noOutputExpected}; Read {type, file: {filePath, content, numLines, startLine,
# totalLines}}. Secret vectors are assembled at run time so this file never holds one.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/secret-output-scrubber.sh"
pass=0; fail=0
ok()  { printf 'PASS: %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); }

# Sandbox HOME + suppress notification so side-effects are inert.
TMP=$(mktemp -d /tmp/claude-scrub-test.XXXXXX)
export HOME="$TMP"; mkdir -p "$HOME/.claude"
export CLAUDE_BREACH_NO_NOTIFY=1

AWS_KEY="AKIA""IOSFODNN7EXAMPLE"

# One vector per SECRET_CONTENT_PATTERNS class. A class without a vector fails below, so a
# new pattern cannot ship without proving it redacts through the jq engine.
declare -A VECTOR=(
    [aws-access-key]="$AWS_KEY"
    [aws-secret-key]="aws_secret_access_key"" = ""wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
    [private-key]="-----BEG""IN RSA PRIVATE KEY-----"
    [github-pat]="ghp_""0123456789abcdefghijABCDEFGHIJ012345"
    [github-fine-pat]="github_pat_$(printf '%082d' 0)"
    [slack-token]="xoxb-""1234567890abcdef"
)

bash_payload() {  # bash_payload <stdout> — text goes via stdin so large outputs never hit argv limits
    printf '%s' "$1" | jq -Rsc '{tool_name: "Bash", transcript_path: "", tool_input: {command: "cat notes.txt"},
        tool_response: {stdout: ., stderr: "", interrupted: false, isImage: false, noOutputExpected: false}}'
}

# 1. Bash object: stdout redacted, every other field and the key set preserved.
out=$(bash_payload "aws=$AWS_KEY done" | "$HOOK")
upd=$(jq -c '.hookSpecificOutput.updatedToolOutput' <<< "$out")
if [[ "$(jq -r 'type' <<< "$upd")" == object \
    && "$(jq -c 'keys' <<< "$upd")" == '["interrupted","isImage","noOutputExpected","stderr","stdout"]' \
    && "$(jq -r '.stdout' <<< "$upd")" == 'aws=[REDACTED-SECRET-BREACH:aws-access-key] done' \
    && "$(jq -c '[.interrupted, .isImage, .noOutputExpected, .stderr]' <<< "$upd")" == '[false,false,false,""]' \
    && "$(jq -r '.hookSpecificOutput.additionalContext' <<< "$out")" == *'SECRET BREACH'* ]]; then
    ok "Bash object result redacted in place, shape preserved, alarm injected"
else
    bad "Bash object result not redacted in shape (got: $upd)"
fi

# 1b. The scrubber hands the payload's session_id to the alarm, so the ledger names the session.
printf 'aws=%s\n' "$AWS_KEY" | jq -Rsc '{tool_name: "Bash", session_id: "sess-5678", transcript_path: "",
    tool_input: {command: "cat notes.txt"}, tool_response: {stdout: ., stderr: "", interrupted: false,
    isImage: false, noOutputExpected: false}}' | "$HOOK" >/dev/null
if grep -q 'session=sess-5678' "$HOME/.claude/breach-ledger.log"; then
    ok "the ledger records the payload session id"
else
    bad "ledger lacks the payload session id: $(cat "$HOME/.claude/breach-ledger.log")"
fi

# 2. Read object: nested file.content redacted; type enum and numeric fields untouched.
out=$(jq -nc --arg c "     1	key=$AWS_KEY" '{tool_name: "Read", transcript_path: "",
    tool_input: {file_path: "/work/src/config.js"},
    tool_response: {type: "text", file: {filePath: "/work/src/config.js", content: $c,
        numLines: 1, startLine: 1, totalLines: 1}}}' | "$HOOK")
upd=$(jq -c '.hookSpecificOutput.updatedToolOutput' <<< "$out")
if [[ "$(jq -r '.type' <<< "$upd")" == text \
    && "$(jq -c '.file | keys' <<< "$upd")" == '["content","filePath","numLines","startLine","totalLines"]' \
    && "$(jq -r '.file.content' <<< "$upd")" == *'[REDACTED-SECRET-BREACH:aws-access-key]'* \
    && "$(jq -c '[.file.numLines, .file.startLine, .file.totalLines]' <<< "$upd")" == '[1,1,1]' ]]; then
    ok "Read object result redacted in nested content, shape preserved"
else
    bad "Read object result not redacted in shape (got: $upd)"
fi

# 3. MCP-style string result stays a string.
out=$(jq -nc --arg r "token $AWS_KEY" '{tool_name: "mcp__x__y", transcript_path: "", tool_response: $r}' | "$HOOK")
if [[ "$(jq -r '.hookSpecificOutput.updatedToolOutput | type' <<< "$out")" == string \
    && "$(jq -r '.hookSpecificOutput.updatedToolOutput' <<< "$out")" \
        == 'token [REDACTED-SECRET-BREACH:aws-access-key]' ]]; then
    ok "string result redacted and kept a string"
else
    bad "string result mishandled (got: $out)"
fi

# 4. Every pattern class redacts through the full hook, and no vector survives anywhere.
source "$DIR/secret-patterns.sh"
for entry in "${SECRET_CONTENT_PATTERNS[@]}"; do
    class="${entry%%|*}"
    vec="${VECTOR[$class]:-}"
    if [[ -z "$vec" ]]; then bad "class $class has no test vector"; continue; fi
    out=$(bash_payload "x $vec y" | "$HOOK")
    if [[ "$out" != *"$vec"* \
        && "$(jq -r '.hookSpecificOutput.updatedToolOutput.stdout' <<< "$out")" \
            == *"[REDACTED-SECRET-BREACH:$class]"* ]]; then
        ok "class $class redacted"
    else
        bad "class $class not redacted"
    fi
done

# 4b. A PEM block is redacted whole: BEGIN line, body (including a Proc-Type header with single dashes) and END line
# become one marker; the lines around it survive. A truncated block loses everything after BEGIN.
pem_b="-----BEG""IN RSA PRIVATE KEY-----"
pem_e="-----E""ND RSA PRIVATE KEY-----"
nl=$'\n'
block="before${nl}${pem_b}${nl}Proc-Type: 4,ENCRYPTED${nl}MIIEfakeBODY1${nl}fakeBODY2==${nl}${pem_e}${nl}after"
out=$(bash_payload "$block" | "$HOOK")
if [[ "$(jq -r '.hookSpecificOutput.updatedToolOutput.stdout' <<< "$out")" \
        == "before${nl}[REDACTED-SECRET-BREACH:private-key]${nl}after" && "$out" != *fakeBODY* ]]; then
    ok "a PEM block is redacted whole, body included"
else
    bad "PEM block not redacted whole (got: $out)"
fi
out=$(bash_payload "x${nl}${pem_b}${nl}MIIEfakeBODY1${nl}fakeBODY2" | "$HOOK")
if [[ "$(jq -r '.hookSpecificOutput.updatedToolOutput.stdout' <<< "$out")" \
        == "x${nl}[REDACTED-SECRET-BREACH:private-key]" && "$out" != *fakeBODY* ]]; then
    ok "a truncated PEM block loses everything after BEGIN"
else
    bad "truncated PEM block not redacted (got: $out)"
fi

# 5. Clean result -> no output (passes through untouched).
out=$(bash_payload "nothing secret here" | "$HOOK")
if [[ -z "$out" ]]; then ok "clean result passes through"; else bad "clean result wrongly modified"; fi

# 6. A Read whose target is a firewall self-definition file is scan-exempt.
out=$(jq -nc --arg c "line $AWS_KEY end" '{tool_name: "Read", transcript_path: "",
    tool_input: {file_path: "/x/hooks/secret-patterns.sh"},
    tool_response: {type: "text", file: {filePath: "/x/hooks/secret-patterns.sh", content: $c,
        numLines: 1, startLine: 1, totalLines: 1}}}' | "$HOOK")
if [[ -z "$out" ]]; then ok "scan-exempt path not alarmed"; else bad "scan-exempt path wrongly scanned"; fi

# 7. A result with no string leaves but a secret elsewhere raises the alarm without a rewrite,
# and the wording does not claim a redaction that never happened.
out=$(jq -nc --arg c "$AWS_KEY" '{tool_name: "Write", transcript_path: "", tool_input: {content: $c},
    tool_response: null}' | "$HOOK")
ctx=$(jq -r '.hookSpecificOutput.additionalContext' <<< "$out")
if [[ "$ctx" == *'SECRET BREACH'* && "$ctx" == *'Nothing was redacted'* \
    && "$ctx" != *'redacted before reaching you'* \
    && "$(jq -r '.hookSpecificOutput | has("updatedToolOutput")' <<< "$out")" == false ]]; then
    ok "leafless result: alarm only, no rewrite, accurate wording"
else
    bad "leafless result mishandled (got: $out)"
fi

# 8. MCP content-block array keeps its array shape; only the text leaf changes.
out=$(jq -nc --arg t "token $AWS_KEY" '{tool_name: "mcp__x__y", transcript_path: "",
    tool_response: [{type: "text", text: $t}]}' | "$HOOK")
upd=$(jq -c '.hookSpecificOutput.updatedToolOutput' <<< "$out")
if [[ "$upd" == '[{"type":"text","text":"token [REDACTED-SECRET-BREACH:aws-access-key]"}]' ]]; then
    ok "content-block array redacted, shape preserved"
else
    bad "content-block array mishandled (got: $upd)"
fi

# 9. A 600 KB result is redacted within the 5 s hook timeout (no argv limit, no slow path).
big=$(printf '%0300000d' 0)
start=$SECONDS
out=$(bash_payload "${big} $AWS_KEY ${big}" | "$HOOK")
elapsed=$((SECONDS - start))
if [[ "$out" != *"$AWS_KEY"* \
    && "$(jq -r '.hookSpecificOutput.updatedToolOutput.stdout | length' <<< "$out")" -gt 600000 \
    && "$elapsed" -lt 5 ]]; then
    ok "600 KB result redacted in ${elapsed}s"
else
    bad "600 KB result not redacted in time (elapsed ${elapsed}s)"
fi

# 9b-9d. A multi-line result over the ~64 KB pipe buffer, with the secret near the TOP, must still be
# detected. grep -Eq's early exit on a match takes the upstream printf's write via SIGPIPE, and pipefail turns
# that into a false "clean" scan; test 9 above has the secret in the middle of one long line, which grep must
# read in full before it can decide, so it never triggers the SIGPIPE and hides this bug. grep -E without -q
# reads all its input, so nothing is lost, regardless of where the match falls.
pad=$(printf '%0200000d' 0)
start=$SECONDS
out=$(bash_payload "line1${nl}aws=${AWS_KEY}${nl}${pad}" | "$HOOK")
elapsed=$((SECONDS - start))
if [[ "$out" != *"$AWS_KEY"* \
    && "$(jq -r '.hookSpecificOutput.updatedToolOutput.stdout' <<< "$out")" \
        == *'[REDACTED-SECRET-BREACH:aws-access-key]'* \
    && "$elapsed" -lt 5 ]]; then
    ok "a multi-line >64 KB Bash result with the secret near the top is redacted in ${elapsed}s"
else
    bad "a multi-line >64 KB Bash result with the secret near the top was not redacted (elapsed ${elapsed}s)"
fi

# stdin, not --arg: Linux caps one argv string at 128 KiB.
out=$(printf '%s' "line1${nl}key=${AWS_KEY}${nl}${pad}" | jq -Rsc '{tool_name: "Read", transcript_path: "",
    tool_input: {file_path: "/work/src/config.js"},
    tool_response: {type: "text", file: {filePath: "/work/src/config.js", content: .,
        numLines: 3, startLine: 1, totalLines: 3}}}' | "$HOOK")
if [[ "$(jq -r '.hookSpecificOutput.updatedToolOutput.file.content' <<< "$out")" \
        == *'[REDACTED-SECRET-BREACH:aws-access-key]'* && "$out" != *"$AWS_KEY"* ]]; then
    ok "a multi-line >64 KB Read result with the secret near the top is redacted"
else
    bad "a multi-line >64 KB Read result with the secret near the top was not redacted (got: $out)"
fi

pem_b="-----BEG""IN RSA PRIVATE KEY-----"
pem_e="-----E""ND RSA PRIVATE KEY-----"
out=$(bash_payload "before${nl}${pem_b}${nl}MIIEfakeBODY1${nl}fakeBODY2==${nl}${pem_e}${nl}${pad}" | "$HOOK")
if [[ "$(jq -r '.hookSpecificOutput.updatedToolOutput.stdout' <<< "$out")" \
        == "before${nl}[REDACTED-SECRET-BREACH:private-key]${nl}${pad}" && "$out" != *fakeBODY* ]]; then
    ok "a PEM block near the top of a >64 KB Bash result is redacted whole"
else
    bad "a PEM block near the top of a >64 KB Bash result was not redacted (got: $out)"
fi

# 10. PostToolUseFailure. The payload, captured from CLI 2.1.283, carries the failed call's output in .error,
# a string. A secret there raises the alarm through additionalContext; the event cannot replace the error text.
fail_payload() {  # fail_payload <error-text>
    printf '%s' "$1" | jq -Rsc '{session_id: "sess-fail", transcript_path: "", cwd: "/work", prompt_id: "p1",
        permission_mode: "default", hook_event_name: "PostToolUseFailure", tool_name: "Bash",
        tool_input: {command: "bash deploy.sh", description: "Run the deploy script"}, tool_use_id: "toolu_x",
        error: ., is_interrupt: false, duration_ms: 12}'
}
out=$(fail_payload "Exit code 1${nl}key=$AWS_KEY" | "$HOOK")
ctx=$(jq -r '.hookSpecificOutput.additionalContext' <<< "$out")
if [[ "$(jq -r '.hookSpecificOutput.hookEventName' <<< "$out")" == PostToolUseFailure \
    && "$ctx" == *'SECRET BREACH'* && "$ctx" == *'cannot redact'* \
    && "$(jq -r '.hookSpecificOutput | has("updatedToolOutput")' <<< "$out")" == false ]]; then
    ok "a secret in a failed call's error raises the alarm, with no rewrite"
else
    bad "failure-path secret mishandled (got: $out)"
fi
if grep -q $'source=tool=Bash (failed)\tsession=sess-fail' "$HOME/.claude/breach-ledger.log"; then
    ok "the failure alarm is ledgered with its source and session"
else
    bad "failure alarm not ledgered: $(tail -1 "$HOME/.claude/breach-ledger.log")"
fi
out=$(fail_payload "Exit code 1${nl}No such file or directory" | "$HOOK")
if [[ -z "$out" ]]; then ok "a clean failure passes through"; else bad "clean failure decided: $out"; fi

# 10b. A multi-line >64 KB failed-call error with the secret near the top must still raise the alarm (this
# event cannot redact, only detect).
out=$(fail_payload "Exit code 1${nl}key=${AWS_KEY}${nl}${pad}" | "$HOOK")
ctx=$(jq -r '.hookSpecificOutput.additionalContext' <<< "$out")
if [[ "$ctx" == *'SECRET BREACH'* ]]; then
    ok "a secret near the top of a >64 KB failed-call error still raises the alarm"
else
    bad "a secret near the top of a >64 KB failed-call error was missed"
fi

# 11. Fail loud under the right event: a payload the scrubber cannot evaluate yields the 'NOT screened' notice,
# labelled with the payload's own event.
for ev in PostToolUse PostToolUseFailure; do
    out=$(jq -nc --arg e "$ev" '{hook_event_name: $e, tool_name: "Bash", tool_input: "not-an-object", error: "e"}' \
        | "$HOOK" 2>/dev/null)
    if [[ "$(jq -r '.hookSpecificOutput.hookEventName' <<< "$out")" == "$ev" \
        && "$(jq -r '.hookSpecificOutput.additionalContext' <<< "$out")" == *'NOT screened'* ]]; then
        ok "an unevaluable $ev payload fails loud under $ev"
    else
        bad "unevaluable $ev payload (got: $out)"
    fi
done

TMPL="$DIR/../settings.json.tmpl"
if [[ "$(jq -c '[.hooks.PostToolUseFailure[] | .hooks[] | .command]' "$TMPL")" \
        == '["~/.claude/hooks/secret-output-scrubber.sh"]' ]]; then
    ok "settings.json.tmpl registers only the scrubber on PostToolUseFailure"
else
    bad "PostToolUseFailure registration: $(jq -c '.hooks.PostToolUseFailure' "$TMPL")"
fi

rm -rf "$TMP"
echo "-----"; echo "passed: $pass  failed: $fail"; [ "$fail" -eq 0 ]
