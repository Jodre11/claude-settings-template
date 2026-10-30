#!/usr/bin/env bash
# Tests for gh-rerun-ask.sh: gh run rerun gets no decision when the run was triggered by a pull request, and prompts
# for any other trigger, a failed or slow lookup, or a form the guard does not judge. Other commands get no decision.
# A stub gh on PATH answers the trigger lookup by run id and logs each call.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/gh-rerun-ask.sh"
pass=0; fail=0
ok()  { printf 'PASS: %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); }

scratch=$(mktemp -d "${CLAUDE_TEMP_DIR:-/tmp}/gra-test.XXXX") || { printf 'FAIL: mktemp -d\n'; exit 1; }
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin" "$scratch/repo"
cat > "$scratch/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s\n' "$PWD" "$*" >> "$GRA_LOG"
case "$3" in
    100) echo pull_request ;;
    200) echo push ;;
    300) echo schedule ;;
    400) echo 'HTTP 404: Not Found' >&2; exit 1 ;;
    500) sleep 10; echo pull_request ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$scratch/bin/gh"
export PATH="$scratch/bin:$PATH"
export GRA_LOG="$scratch/log"
unset GH_REPO GH_HOST
r="$scratch/repo"

# run <cwd> <command>: the hook's stdout for a Bash payload carrying <command>, run from <cwd>.
run() {
    jq -nc --arg c "$2" --arg d "$1" \
        '{hook_event_name: "PreToolUse", tool_name: "Bash", cwd: $d, tool_input: {command: $c}}' \
        | "$HOOK" 2>&1
}

# expect <ask|deny|none> <command> [<reason fragment>]
expect() {
    local out decision reason
    out=$(run "$r" "$2")
    decision=$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<< "$out" 2>/dev/null)
    reason=$(jq -r '.hookSpecificOutput.permissionDecisionReason // empty' <<< "$out" 2>/dev/null)
    if [[ "$1" == none && -z "$out" ]] \
            || [[ "$1" != none && "$decision" == "$1" && "$reason" == *"${3:-}"* ]]; then
        ok "$1: $2"
    else
        bad "$1: $2 -> ${out:-<no output>}"
    fi
}

# A pull_request run reruns unprompted, with the flags gh run rerun takes.
expect none 'gh run rerun 100'
expect none 'gh run rerun 100 --failed'
expect none 'gh run rerun --failed 100 --debug'
expect none 'gh run rerun 100 -d'
expect none 'gh run rerun 100 --repo ExampleOrg/ours'
expect none 'gh run rerun 100 --repo=ExampleOrg/ours'
expect none 'gh run rerun 100 -R ExampleOrg/ours'
expect none 'gh run rerun 100 -RExampleOrg/ours'
expect none 'gh run rerun 100 -R https://github.com/ExampleOrg/ours'
expect none 'gh run rerun "100"'

# Any other trigger, or a lookup that fails or overruns, prompts.
expect ask 'gh run rerun 200' "triggered by 'push'"
expect ask 'gh run rerun 300 --failed' "triggered by 'schedule'"
expect ask 'gh run rerun 400' 'could not be looked up'
expect ask 'gh run rerun 500' 'could not be looked up'

# Forms the guard does not judge prompt.
expect ask 'gh run rerun' 'no run id'
expect ask 'gh run rerun 100 200' 'more than one run'
expect ask 'gh run rerun abc' 'not a run id'
expect ask 'gh run rerun --job 123' 'one job'
expect ask 'gh run rerun -j 123' 'one job'
expect ask 'gh run rerun 100 --verbose' 'not one the guard knows'
expect ask 'gh run rerun 100 --repo' 'no value'
expect ask 'gh run rerun 100 --repo ghe.example.com/o/r' 'not a GitHub owner/name'
expect ask 'gh run -R ExampleOrg/ours rerun 100' 'flags after rerun'
expect ask '"gh" run "re"run 200'
expect ask 'cd /x && gh run rerun 100' 'shell syntax'
expect ask 'gh run rerun 100; echo done' 'shell syntax'
expect ask 'gh run rerun $ID' 'shell syntax'
expect ask 'gh run rerun 100 | cat' 'shell syntax'
expect ask $'gh run rerun 100\necho x' 'shell syntax'
expect ask 'GH_REPO=a/b gh run rerun 100' 'GH_REPO'
expect ask 'env gh run rerun 100' 'does not start with gh'
expect ask '/usr/local/bin/gh run rerun 100' 'does not start with gh'
expect ask "gh run rerun 100 'unterminated" 'unterminated quote'

# With no literal rerun, a glob, brace or expansion beside a run word could assemble one: denied with a way to rewrite
# it. Double quotes leave $ and backquote live, so an expansion in them counts; so does one that assembles gh.
expect deny 'gh run {re,}run 100' 'could assemble gh run rerun'
expect deny 'gh run r?run 100' 'could assemble gh run rerun'
expect deny "gh run \$'rerun' 100" 'could assemble gh run rerun'
expect deny 'gh run ${X:-rerun} 100' 'could assemble gh run rerun'
expect deny 'gh run "${X:-rerun}" 100' 'could assemble gh run rerun'
expect deny 'gh run "`printf rerun`" 100' 'could assemble gh run rerun'
expect deny '${G:-g}h run rerun 100' 'could assemble gh run rerun'
expect deny 'npm run test -- $FOO' 'written out literally'
expect deny 'docker run -v "$PWD:/w" img' 'written out literally'
# A run word inside an expansion, or any rerun, beside an expansion counts too.
expect deny 'gh ${X:-run} rerun 100' 'could assemble gh run rerun'
expect deny 'gh ${X:-run rerun} 100' 'could assemble gh run rerun'
expect deny 'gh $X rerun 100' 'could assemble gh run rerun'
expect deny '${G:-g}h ${R:-run} ${S:-rerun} 100' 'could assemble gh run rerun'
# A redirection ends a word, so it hides neither a rerun nor a run word.
expect ask 'gh run rerun>/dev/null 1' 'shell syntax'
expect ask 'gh run rerun<x 1' 'shell syntax'
expect deny 'gh $X rerun>/dev/null 1' 'could assemble gh run rerun'
expect deny 'npm run>$F' 'written out literally'
# A command with a run word too long to scan is denied too.
long=$(printf 'x%.0s' {1..4100})
expect deny "gh run \"\${X:-rerun}\" 100 # $long" 'too long'
expect deny "npm run build # $long" 'too long'

# Other commands get no decision, including a run word beside quoted globs.
expect none 'gh run view 200 --log'
expect none "gh run list --json databaseId --jq '.[0].databaseId'"
expect none 'gh run view 200 --log | grep rerun'
expect none 'gh pr checks 12'
# Quote removal makes a quoted mention read as a rerun; the guard fails closed on it, as gh-merge-ask.sh does.
expect ask 'echo "gh run rerun 200"' 'does not start with gh'
expect none 'npm run build'
expect none "npm run lint -- '*.ts'"
expect none 'echo $HOME'
expect none 'kubectl apply --dry-run=client -f $F'
expect none 'bash tests/run.sh 2>&1 | grep -E "^(FAIL|ok)"'
expect none 'npm run-script build -- $X'
expect none 'grep -n -E "R-[0-9]+" hooks/gh-rerun-ask.sh'
expect none 'ls scripts/run/*.sh'
# The bodies of the sanctioned commit-message and file-writing heredocs are text, so a run word there is not beside an
# expansion.
expect none $'git commit -m "$(cat <<\'EOF\'\nfix: run the tests on ${X:-run}\nEOF\n)"'
expect none $'cat > notes.txt <<\'EOF\'\nnpm run $X\nEOF'
# Any other heredoc is read: one a shell runs, one with no file target, an opener inside a string, an unquoted
# delimiter, text after the terminator, a here-string. A literal rerun in a sanctioned body asks.
expect deny $'bash <<\'EOF\'\nnpm run $X\nEOF' 'written out literally'
expect deny $'cat <<\'EOF\'\nnpm run $X\nEOF' 'written out literally'
expect deny $'echo "<<\'EOF\'"\ngh ${X:-run} rerun 1\nEOF' 'could assemble gh run rerun'
expect deny $'cat > notes.txt <<EOF\nnpm run $X\nEOF' 'written out literally'
expect deny $'cat > notes.txt <<\'EOF\'\nx\nEOF\nnpm run $X' 'written out literally'
expect deny $'cat <<<\'E\'\nnpm run $X\nE' 'written out literally'
expect ask $'git commit -m "$(cat <<\'EOF\'\ngh run rerun 1\nEOF\n)"' 'shell syntax'
expect none 'gh pr create --body-file $CLAUDE_TEMP_DIR/pr-body.md'
expect none 'ls -la'
expect none ''

# The lookup runs in the payload's working directory and passes the --repo given.
: > "$GRA_LOG"
run "$r" 'gh run rerun 100 -R ExampleOrg/ours' >/dev/null
if grep -qx "$r|run view 100 --repo ExampleOrg/ours --json event --jq .event" "$GRA_LOG"; then
    ok "the lookup runs in the working directory with the --repo given"
else
    bad "the lookup call drifted: $(cat "$GRA_LOG")"
fi
: > "$GRA_LOG"
run "$r" 'gh run rerun 100 --repo host/ExampleOrg/ours' >/dev/null
if grep -qx "$r|run view 100 --repo host/ExampleOrg/ours --json event --jq .event" "$GRA_LOG"; then
    ok "the lookup gets --repo as written, so gh resolves the same repository for both"
else
    bad "the lookup rewrote --repo: $(cat "$GRA_LOG")"
fi
: > "$GRA_LOG"
run "$r" 'gh run view 200' >/dev/null
if [[ ! -s "$GRA_LOG" ]]; then ok "a command that is not a rerun runs no lookup"; else bad "lookup ran for a view"; fi

out=$(jq -nc '{tool_input: {command: "gh run rerun 100"}}' | "$HOOK" 2>&1)
if [[ "$(jq -r '.hookSpecificOutput.permissionDecision' <<< "$out" 2>/dev/null)" == ask ]]; then
    ok "a payload with no working directory prompts"
else
    bad "no-cwd payload: $out"
fi

TMPL="$DIR/../settings.json.tmpl"
if jq -e '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[]
        | select(.command == "~/.claude/hooks/gh-rerun-ask.sh")' "$TMPL" >/dev/null 2>&1; then
    ok "settings.json.tmpl registers gh-rerun-ask.sh on Bash"
else
    bad "settings.json.tmpl does not register gh-rerun-ask.sh on Bash"
fi
if jq -e '.permissions.ask | index("Bash(gh run rerun*)")' "$TMPL" >/dev/null 2>&1; then
    bad "the native gh run rerun ask rule is still present, so no rerun could skip the prompt"
else
    ok "no native ask rule overrides the hook for gh run rerun"
fi

echo "-----"; echo "passed: $pass  failed: $fail"; [ "$fail" -eq 0 ]
