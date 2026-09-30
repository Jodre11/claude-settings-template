#!/usr/bin/env bash
set -u
HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/secret-bash-guard.sh"
pass=0; fail=0
ok()  { printf 'PASS: %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); }
run() {  # run <cmd>: DENY, ASK (the hook failed to evaluate) or ALLOW
    local out
    out=$(jq -nc --arg c "$1" '{tool_input:{command:$c}}' | "$HOOK")
    if [[ "$out" == *'"permissionDecision":"deny"'* ]]; then echo DENY
    elif [[ "$out" == *'"permissionDecision":"ask"'* ]]; then echo ASK
    else echo ALLOW; fi
}
expect() {  # expect <DENY|ALLOW> <description> <cmd>
    local got
    got=$(run "$3")
    if [[ "$got" == "$1" ]]; then ok "$2"; else bad "$2 (want $1 got $got)"; fi
}

# Readers of secret paths -> DENY
[[ "$(run 'cat dev/secrets-manager/secrets/app.json')" == DENY ]] && ok "cat secrets file denied" || bad "cat secrets file allowed"
[[ "$(run 'xxd infra/tls.pem')" == DENY ]] && ok "xxd .pem denied" || bad "xxd .pem allowed"
[[ "$(run 'head .env')" == DENY ]] && ok "head .env denied" || bad "head .env allowed"

# Benign reader -> ALLOW
[[ "$(run 'cat README.md')" == ALLOW ]] && ok "cat README allowed" || bad "cat README denied"

# env / printenv
[[ "$(run 'env')" == DENY ]] && ok "bare env denied" || bad "bare env allowed"
[[ "$(run 'env AWS_PROFILE=x dotnet run')" == ALLOW ]] && ok "env prefix form allowed" || bad "env prefix form denied"
[[ "$(run 'printenv')" == DENY ]] && ok "bare printenv denied" || bad "bare printenv allowed"
[[ "$(run 'printenv AWS_SECRET_ACCESS_KEY')" == DENY ]] && ok "printenv secret var denied" || bad "printenv secret var allowed"
[[ "$(run 'printenv HOME')" == ALLOW ]] && ok "printenv HOME allowed" || bad "printenv HOME denied"

# echo/printf of secret-named var
[[ "$(run 'echo $AWS_SECRET_ACCESS_KEY')" == DENY ]] && ok "echo secret var denied" || bad "echo secret var allowed"
[[ "$(run 'echo hello world')" == ALLOW ]] && ok "echo plain text allowed" || bad "echo plain text denied"

# secret-fetch: bare stdout DENY, redirect to /tmp/claude-* ALLOW
[[ "$(run 'aws secretsmanager get-secret-value --secret-id foo')" == DENY ]] && ok "secret-fetch bare denied" || bad "secret-fetch bare allowed"
[[ "$(run 'aws secretsmanager get-secret-value --secret-id foo > /tmp/claude-abc/s.json')" == ALLOW ]] && ok "secret-fetch redirected allowed" || bad "secret-fetch redirected denied"
[[ "$(run 'aws ecr get-login-password --region eu-west-1')" == DENY ]] && ok "ecr login bare denied" || bad "ecr login bare allowed"

# The fetch check must run ahead of the (slower) floor/stage passes, so a fetch command whose later stage
# would ALSO be denied by a different check still gets the SECRET-FETCH message, not that other one.
fetch_want="SECRET-FETCH BLOCK: this command emits a live secret to stdout (→ context). Redirect it to a"
fetch_want+=" \$CLAUDE_TEMP_DIR file, e.g. '... > /tmp/claude-XXXX/secret.json', so a script can consume it"
fetch_want+=" indirectly."
fetch_got=$(jq -nc '{tool_input:{command:"aws secretsmanager get-secret-value --secret-id x | cat .env"}}' \
    | "$HOOK" | jq -r '.hookSpecificOutput.permissionDecisionReason')
if [[ "$fetch_got" == "$fetch_want" ]]; then
    ok "a fetch command denied ahead of a later stage's own deny"
else
    bad "fetch-vs-stage ordering drifted: $fetch_got"
fi

# The fetch check runs on the whole command, ahead of the floor and stage passes, so it still wins the message
# even when the OTHER deniable stage comes first in the pipeline.
fetch_got2=$(jq -nc '{tool_input:{command:"cat .env | aws secretsmanager get-secret-value --secret-id x"}}' \
    | "$HOOK" | jq -r '.hookSpecificOutput.permissionDecisionReason')
if [[ "$fetch_got2" == "$fetch_want" ]]; then
    ok "a fetch command denied ahead of an earlier stage's own deny"
else
    bad "fetch-vs-earlier-stage ordering drifted: $fetch_got2"
fi

# More readers, a quoted operand, and cp/mv out of a secret path.
expect DENY  "grep of a secrets file denied"                'grep -n password secrets/app.json'
expect DENY  "rg of AWS credentials denied"                 'rg token ~/.aws/credentials'
expect DENY  "awk of config.env denied"                     "awk '{print}' ~/.claude/config.env"
expect DENY  "sed -n of a .secret file denied"              'sed -n 1p creds.secret'
expect DENY  "jq of a secrets file denied"                  'jq . secrets/app.json'
expect DENY  "base64 of a private key denied"               'base64 -i ~/.ssh/id_rsa'
expect DENY  "a quoted secret operand denied"               'cat "secrets/app.json"'
expect ALLOW "grep of source allowed"                       'grep -rn TODO src'
expect ALLOW "jq of package.json allowed"                   'jq .name package.json'
expect DENY  "cp from a secrets file denied"                'cp secrets/app.json /tmp/claude-x/a.json'
expect DENY  "mv from .env denied"                          'mv .env /tmp/claude-x/e'
expect DENY  "cp -r of a secrets dir denied"                'cp -r secrets/ /tmp/claude-x/s'
expect ALLOW "cp of an ordinary file allowed"                'cp README.md /tmp/claude-x/r.md'
expect ALLOW "cp into a secrets path allowed (no read-out)" 'cp /tmp/claude-x/new.json secrets/app.json'

# env with a command after its options is fine; env with none prints the environment.
expect ALLOW "env -u VAR cmd allowed"                       'env -u AWS_PROFILE dotnet run'
expect ALLOW "env -i with assignments and a command allowed" 'env -i PATH=/usr/bin ls'
expect DENY  "env -u VAR with no command denied"            'env -u AWS_PROFILE'
expect DENY  "env with only an assignment denied"           'env FOO=bar'
expect DENY  "env - denied"                                 'env -'
want="SECRET-ENV BLOCK: 'env' with no command prints every variable, secret-bearing ones included, into context."
want+=" Use the 'env VAR=value command' prefix form, or reference a specific non-secret variable."
got=$(jq -nc '{tool_input:{command:"env -u X"}}' | "$HOOK" | jq -r '.hookSpecificOutput.permissionDecisionReason')
[[ "$got" == "$want" ]] && ok "the env deny reason is pinned" || bad "env deny reason drifted: $got"

# A deny reason quotes the operand, so a control character in it must still leave valid JSON: the CLI cannot read an
# invalid decision, and the deny would be lost. run() matches a substring, so this row parses the output instead.
got=$(jq -nc --arg c $'cat secrets/a\x01b' '{tool_input:{command:$c}}' | "$HOOK" \
    | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)
if [[ "$got" == deny ]]; then
    ok "a deny quoting a control character is valid JSON"
else
    bad "a deny quoting a control character is not valid JSON (got '$got')"
fi

# Pipelines: bash-guard allows them, so every stage is screened.
expect DENY  "a reader in a later pipeline stage denied"    'true | cat .env'
expect DENY  "printenv of a secret in a later stage denied" 'echo hi | printenv AWS_SECRET_ACCESS_KEY'
expect ALLOW "an ordinary pipeline allowed"                 'git log --oneline | head -5'
expect ALLOW "a | inside quotes is harmless"                "jq '.a | .b' f.json"

# A | inside quotes must not hide a later operand from its reader, echo or printf.
expect DENY  "single-quoted pipe hides a later cat operand"        "cat 'a|b' .env"
expect DENY  "double-quoted pipe hides a later cat operand"        'cat "x|y" secrets/app.json'
expect DENY  "single-quoted pipe hides a secret in printf"         "printf 'a|%s\n' \"\$AWS_SECRET_ACCESS_KEY\""
expect DENY  "double-quoted pipe hides a secret in echo"           'echo "a|$GITHUB_TOKEN"'
expect DENY  "grep -E alternation on a secrets file denied"        "grep -E 'password|token' secrets/app.json"
expect DENY  "awk -F pipe on .env denied"                          "awk -F'|' '{print \$2}' .env"
expect DENY  "a real pipe after a quoted pipe still denied"        "true | cat 'a|b' .env"
expect DENY  "a backslash-escaped quote before a real pipe still denied" "echo \' | cat .env"
expect ALLOW "grep -E alternation on source allowed"                "grep -E 'foo|bar' src/app.ts"
expect ALLOW "an apostrophe inside double quotes before a real pipe allowed" "echo \"it's\" | wc -l"

# Per-stage scoping must not narrow what the whole command already exposes.
expect DENY  "echo piped into sed substituting a secret denied"    "echo x | sed \"s/.*/\$API_TOKEN/\""
expect DENY  "echo piped into awk with a secret var denied"        "echo x | awk -v t=\"\$GITHUB_TOKEN\" '{print t}'"
expect DENY  "echo piped into xargs printf of a secret denied"     'echo x | xargs printf $AWS_SECRET_ACCESS_KEY'
expect DENY  "cat piped into diff against .env denied"             'cat README.md | diff - .env'
expect DENY  "head piped into sort of .env denied"                 'head -1 README.md | sort .env'

# env must not wrap a command unscreened.
expect DENY  "env wrapping printenv denied"                        'env printenv'
expect DENY  "env -u wrapping printenv denied"                     'env -u FOO printenv'
expect DENY  "env wrapping printenv of a secret denied"            'env printenv AWS_SECRET_ACCESS_KEY'
expect DENY  "env wrapping cat of .env denied"                     'env cat .env'
expect DENY  "env -i wrapping cat of .env denied"                  'env -i cat .env'
expect DENY  "env wrapping head of aws credentials denied"         'env head ~/.aws/credentials'

# env -S and a clustered short option must not slip through the option walk.
expect DENY  "env -S with an assignment denied"                    "env -S 'FOO=bar'"
expect DENY  "env -S empty denied"                                 "env -S ''"
expect DENY  "env clustered -0u with no command denied"            'env -0u FOO'
expect DENY  "env clustered -vu with no command denied"            'env -vu FOO'

# -S bundled behind a harmless flag, and a value glued onto -u, must not slip through either.
expect DENY  "env -vS with a command string denied"                "env -vS 'cat .env'"
expect DENY  "env -iS with a command string denied"                "env -iS 'cat .env'"
expect DENY  "env -vS empty denied"                                 "env -vS ''"
expect DENY  "env -u with a glued value wrapping cat of .env denied" 'env -uHTTP cat .env'
expect DENY  "env -u with a glued value wrapping head of aws credentials denied" 'env -uAWS_P head ~/.aws/credentials'
expect ALLOW "env -u with a glued value and a real command allowed" 'env -uHTTP dotnet run'

# env wrapping a command runner, or carrying an unrecognised option, must fall back to denying: the
# runner's own arguments are not screened by this hook, and an unrecognised option can select a mode (like -S)
# this walk does not know about, so both cases are treated the same as an env this hook cannot see through.
expect DENY  "env wrapping nice denied"                            'env nice cat .env'
expect DENY  "env wrapping xargs denied"                            'env xargs cat .env'
expect DENY  "env wrapping command denied"                          'env command cat .env'
expect DENY  "env wrapping time denied"                             'env time cat .env'
expect DENY  "env wrapping sudo denied"                              'env sudo cat .env'
expect DENY  "env wrapping sh -c denied"                             "env sh -c 'cat .env'"
expect DENY  "env wrapping bash -c denied"                           'env bash -c env'
expect DENY  "env -u wrapping sh -c denied"                          'env -u X sh -c env'
expect DENY  "env -a (GNU-only, unrecognised) wrapping cat of .env denied" 'env -a x cat .env'
expect DENY  "env --uns (unrecognised abbreviation) wrapping cat of .env denied" 'env --uns FOO cat .env'
expect ALLOW "env VAR=value prefix wrapping sh -c stays allowed, as before the fallback" 'env FOO=bar sh -c env'

# A bundled short-option run must match exactly, not as a glob prefix: an unknown trailing flag (GNU env) must
# still mark the walk unsure, not slip through behind a recognised leading flag.
expect DENY  "env -ia (unrecognised trailing flag in a bundle) wrapping cat of .env denied" 'env -ia x cat .env'

# A bare env wrapping a command outside the known runner list, with no option consumed at all, must still fall
# back to denying — no finite runner list can be complete.
expect DENY  "env wrapping setsid (outside runners_re) denied"     'env setsid cat .env'
expect DENY  "env wrapping python3 -c denied"                      "env python3 -c 'print(1)'"

# The env fallback must not fire on a naive |-split FRAGMENT of quoted text: a quote spanning several naive
# pieces means each piece may be only part of a word, so the env unwrap's fallback is unreliable there and must
# be skipped per piece, relying on the joined, fully-quoted stage (screened strictly) instead.
expect ALLOW "a quoted alternation containing '|env word' is not a real env stage"  'grep -rn -E "dotenv|env var" src'
expect ALLOW "a quoted '|env ls|' in a commit message allowed" \
    'git commit -m "docs: table | env ls | lists files"'
expect DENY  "env wrapping setsid in a REAL later pipeline stage still denied"      'true | env setsid cat .env'

# Bonus: a real trailing pipeline stage after an unbalanced open quote is now always screened via the joined
# run at the end of the command, not just the un-merged naive piece a mis-tracked escaped quote leaves behind.
expect DENY  "a real trailing stage after a single-quoted open tail still denied"   "true | cat 'a|b' .env \'"
expect DENY  "a real trailing stage after a double-quoted open tail still denied"   'true | cat "a|b" .env \"'

# The first-word fast path must cut the word exactly as the full split does (leading spaces, tabs and newlines are
# skipped), and every word a check acts on must still reach the checks.
expect DENY  "a reader stage after two spaces denied"             'true |  cat .env'
expect DENY  "a reader stage after a tab denied"                  $'true |\tcat .env'
expect DENY  "a reader stage after a newline denied"              $'true |\ncat .env'
expect DENY  "a lone reader after leading spaces denied"          '   head .env'
expect DENY  "an env chain in a later stage denied"               'true | env env cat .env'
expect DENY  "a stage over the fast-path bound denied"            "true | cat $(printf 'a%.0s' {1..60}) .env"
for r in cat less more head tail xxd strings od nl tac bat grep rg awk sed jq base64; do
    expect DENY "$r in a later stage denied"                      "true | $r .env"
done
expect DENY  "cp in a later stage denied"                         'true | cp .env /tmp/claude-x/e'
expect DENY  "mv in a later stage denied"                         'true | mv .env /tmp/claude-x/e'
expect DENY  "printenv in a later stage denied"                   'true | printenv GITHUB_TOKEN'
expect DENY  "printf in a later stage denied"                     'true | printf $API_TOKEN'
expect ALLOW "an allowlisted .env.example operand allowed"        'cat .env.example'
expect ALLOW "an allowlisted .tmpl under secrets/ allowed"        'cat deploy/secrets/README.tmpl'

# A quote opened in a stage longer than the fast-path bound still spans the pipe that follows it.
expect DENY  "a quoted pipe opened in a long stage is still tracked" \
    "true | cat 'x$(printf 'a%.0s' {1..70})|y' .env"

# Operands are screened as written: the hook must not expand a glob against its own cwd, where it could become a
# different, allowlisted name.
gdir=$(mktemp -d)
mkdir -p "$gdir/secrets"
: >"$gdir/secrets/readme.pub"
got=$(cd "$gdir" && run 'cat secrets/*')
rm -rf "$gdir"
[[ "$got" == DENY ]] && ok "a glob operand is screened as written" || bad "a glob operand was expanded: $got"

# Timing. A PreToolUse hook that overruns its 5 s timeout does not block, so a command this hook cannot screen in
# time passes unscreened. bash-guard denies anything over 64 KiB, so each case is at most 65536 characters, and each
# must be decided within TIME_LIMIT_MS, half the timeout: a CI runner is two to three times slower per core than a
# current Mac, so a row that passes there leaves the hook at least twice its worst case inside the timeout.
TIME_LIMIT_MS=2500

# _ms: print the time in milliseconds. bash 5 has EPOCHREALTIME; an older bash falls back to whole seconds, which
# can fail a row early but never passes one the precise clock would fail.
_ms() {
    if [[ -n "${EPOCHREALTIME:-}" ]]; then
        local t="${EPOCHREALTIME/[.,]/}"
        echo $(( t / 1000 ))
    else
        echo $(( SECONDS * 1000 ))
    fi
}

# expect_fast <DENY|ALLOW> <description> <cmd>: pass when the hook decides <cmd> as expected within TIME_LIMIT_MS.
expect_fast() {
    local got start elapsed
    start=$(_ms)
    got=$(run "$3")
    elapsed=$(( $(_ms) - start ))
    if [[ "$got" == "$1" && "$elapsed" -lt "$TIME_LIMIT_MS" && ${#3} -le 65536 ]]; then
        ok "$2 (${#3} characters, ${elapsed} ms)"
    else
        bad "$2 (${#3} characters): want $1 within ${TIME_LIMIT_MS} ms, got $got in ${elapsed} ms"
    fi
}

# Over the bound, the hook denies without screening, whatever the content.
expect DENY "a command over the scan bound denied" "true $(printf 'a%.0s' {1..70000})"
expect DENY "a command at the scan bound still screened" "cat $(printf 'a%.0s' {1..65527}) .env"
expect ALLOW "a benign command at the scan bound allowed" "true $(printf 'a%.0s' {1..65531})"

# Short tokens maximise the floor's operand loop; a trailing secret operand must still be found.
expect_fast DENY "a command of short operands" "cat $(printf 'a.txt %.0s' {1..10900})secrets/app.json"
expect_fast DENY "a command of 1-char operands" "cat $(printf 'a %.0s' {1..32700})secrets/app.json"
# One-word pipe stages maximise the number of naive pieces.
expect_fast DENY "a command of 1-word stages" "$(printf 'a|%.0s' {1..32700})cat .env"
# Self-balanced '|' pieces maximise the quote walk and make one long run.
expect_fast DENY "a quote-heavy command" "$(printf "'|'%.0s" {1..21800})| cat .env"
# A quote left open until the end makes one long run, joined once. The string matches no secret pattern.
expect_fast ALLOW "a single long open quote" "cat '$(printf 'a|%.0s' {1..32700})secrets/app.json'"
# The env unwrap advances in one pass.
expect_fast DENY "a chain of env wrappers" "$(printf 'env %.0s' {1..16000})cat .env"
# One long run of quotes in a single piece.
expect_fast DENY "a single long run of quotes" "echo $(printf "'%.0s" {1..64000}) | cat 'a|b' .env"
# The fetch check runs first, ahead of an expensive tail.
expect_fast DENY "a fetch command with an expensive tail" \
    "aws secretsmanager get-secret-value --secret-id x | grep -v '$(printf 'a|%.0s' {1..32680})z'"
# One long piece with no quotes: deleting its non-quote characters is quadratic, so it is walked instead.
expect_fast DENY "one long piece with no quotes" "echo $(printf 'a%.0s' {1..65000})|cat .env"
# Every stage a reader: none can take the first-word fast path.
expect_fast DENY "a command whose every stage is a reader" "$(printf 'cat a|%.0s' {1..10900})cat .env"
# Every stage an echo of a variable: the echo check's regex runs on every stage.
expect_fast DENY "a command whose every stage echoes a variable" "$(printf 'echo $a|%.0s' {1..8170})cat .env"
# Every stage an env with an option: the env walk runs on every stage.
expect_fast DENY "a command whose every stage is an env wrapper" "$(printf 'env -u X cat a|%.0s' {1..4360})cat .env"
# Many short quote-spanning runs: each is joined on its own, so a run must not cost O(its position).
expect_fast DENY "many short quote-spanning runs" "$(printf "'|'x|%.0s" {1..13100})cat .env"
# One long echo stage full of variables.
expect_fast DENY "one long echo stage of variables" "echo $(printf '$a%.0s' {1..32000}) |cat .env"
# Pieces just over the fast-path bound are all screened in full.
expect_fast DENY "pieces just over the fast-path bound" \
    "$(printf "$(printf 'x%.0s' {1..65})|%.0s" {1..990})cat .env"
# A deny quotes the operand it denies, so escaping its reason must stay fast too: bash 3.2's pattern substitution is
# quadratic in the string's length, and every backslash or control character in the operand is substituted.
expect_fast DENY "a deny quoting a long run of backslashes" "cat $(printf '\\%.0s' {1..8000}).env secrets/app.json"
expect_fast DENY "a deny quoting a long run of control characters" "cat $(printf '\001%.0s' {1..8000}).env"

echo "-----"; echo "passed: $pass  failed: $fail"; [ "$fail" -eq 0 ]
