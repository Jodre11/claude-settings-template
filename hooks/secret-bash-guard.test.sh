#!/usr/bin/env bash
set -u
HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/secret-bash-guard.sh"
pass=0; fail=0
ok()  { printf 'PASS: %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); }
RUN_CWD=$(mktemp -d)
run() {  # run <cmd>: DENY, ASK (the hook failed to evaluate, or held an ask) or ALLOW; HOOK_BASH, when set, runs the
    # hook; RUN_CWD is the payload's cwd and RUN_SID, when set, its session_id
    local out
    out=$(jq -nc --arg c "$1" --arg d "$RUN_CWD" --arg s "${RUN_SID:-}" \
            '{tool_input:{command:$c}, cwd:$d} + (if $s == "" then {} else {session_id:$s} end)' \
        | ${HOOK_BASH:+"$HOOK_BASH"} "$HOOK")
    if [[ "$out" == *'"permissionDecision":"deny"'* ]]; then echo DENY
    elif [[ "$out" == *'"permissionDecision":"ask"'* ]]; then echo ASK
    else echo ALLOW; fi
}
expect() {  # expect <DENY|ALLOW> <description> <cmd>
    local got
    got=$(run "$3")
    if [[ "$got" == "$1" ]]; then ok "$2"; else bad "$2 (want $1 got $got)"; fi
}
expect_in() {  # expect_in <cwd> <DENY|ASK|ALLOW> <description> <cmd>
    local RUN_CWD="$1"
    expect "$2" "$3" "$4"
}
expect_sid() {  # expect_sid <session id> <DENY|ASK|ALLOW> <description> <cmd>
    local RUN_SID="$1"
    expect "$2" "$3" "$4"
}
# A grep or rg default the session sets would change what the rows below read.
unset GREP_OPTIONS RIPGREP_CONFIG_PATH

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
expect DENY "a fetch redirected to a session file outside the vault denied" \
    'aws secretsmanager get-secret-value --secret-id foo > /tmp/claude-abc/s.json'
[[ "$(run 'aws ecr get-login-password --region eu-west-1')" == DENY ]] && ok "ecr login bare denied" || bad "ecr login bare allowed"

# The fetch check must run ahead of the (slower) floor/stage passes, so a fetch command whose later stage
# would ALSO be denied by a different check still gets the SECRET-FETCH message, not that other one.
fetch_want="SECRET-FETCH BLOCK: this command emits a live secret to stdout (→ context). Fetch it into the vault"
fetch_want+=" instead, as the whole command with one redirection of stdout: '... > \$CLAUDE_SECRET_DIR/<name>'. Then"
fetch_want+=" have a script read that file. A registry password may instead be piped straight into"
fetch_want+=" '... login --password-stdin'."
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

# A crash asks through the backstop: malformed input makes the hook fail before any check runs.
crash=$(printf '%s' '{not json' | ${HOOK_BASH:+"$HOOK_BASH"} "$HOOK" 2>/dev/null)
if [[ "$crash" == *'"permissionDecision":"ask"'* && "$crash" == *"secret-bash-guard failed to evaluate"* ]]; then
    ok "a crash asks through the backstop"
else
    bad "a crash did not ask through the backstop: $crash"
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
expect DENY  "env VAR=value prefix wrapping sh -c is a shell command string, denied" 'env FOO=bar sh -c env'

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

# Every word of every stage is screened: prefixes, wrappers, assignments, grouping and spellings of the command name
# no longer hide a reader.
expect DENY  "a grouped reader denied"                             '(cat .env)'
expect DENY  "command cat denied"                                  'command cat .env'
expect DENY  "xargs cat of a secret operand denied"                'xargs cat .env'
expect DENY  "nice cat denied"                                     'nice cat .env'
expect DENY  "time cat denied"                                     'time cat .env'
expect DENY  "sudo cat denied"                                     'sudo cat .env'
expect DENY  "an assignment prefix before cat denied"              'FOO=1 cat .env'
expect DENY  "! cat denied"                                        '! cat .env'
expect DENY  "exec cat denied"                                     'exec cat .env'
expect DENY  "/bin/cat denied"                                     '/bin/cat .env'
expect DENY  "a backslash-escaped command name denied"             '\cat .env'
expect DENY  "a quote-split command name denied"                   'c""at .env'
expect DENY  "an escaped quote does not open a quote"              "echo \\' | cat 'a|b' .env"
expect DENY  "cp -t DIR with a secret source denied"               'cp -t /tmp/claude-x/d .env'
expect DENY  "cp -tDIR with a secret source denied"                'cp -t/tmp/claude-x/d .env'
expect DENY  "cp --target-directory= with a secret source denied"  'cp --target-directory=/tmp/claude-x/d .env'
expect DENY  "cp -rt DIR with a secret source denied"              'cp -rt /tmp/claude-x/d secrets/app.json'
expect DENY  "cp -vt DIR with a secret source denied"              'cp -vt /tmp/claude-x/d .env'
expect ALLOW "cp -rv of a source tree allowed"                     'cp -rv src/ /tmp/claude-x/d'
expect DENY  "cp --target DIR (a prefix of the long option) with a secret source denied" \
    'cp --target /tmp/claude-x/d .env'
expect DENY  "cp --target-dir=DIR with a secret source denied" \
    'cp --target-dir=/tmp/claude-x/d secrets/app.json'
expect DENY  "cp -S with a glued value ending in t still reads its source" \
    'cp -Sbackupt secrets/app.json /tmp/claude-x/d'
expect DENY  "install -m with a glued value ending in t still reads its source" \
    'install -m644t secrets/app.json /tmp/claude-x/d'
expect DENY  "a long cp bundle with -S before a late t still reads its source" \
    'cp -rrrrrrrrrrrrrrrrrrrrrSbackupt secrets/app.json /tmp/claude-x/d'
expect DENY  "a secret path in an --opt= value denied"             'grep --file=secrets/patterns.txt x'
expect DENY  "env with a quoted spaced assignment and a reader denied" "env 'FOO=a b' cat .env"
expect DENY  "env with only a quoted spaced assignment denied"     "env 'FOO=a b'"
expect DENY  "printenv -0 denied"                                  'printenv -0'
expect DENY  "a reader in a quoted alternation's later stage denied" 'grep -E "a|b" x | cat .env'

# Readers and fetch forms the first-word list missed.
for r in sort uniq cut paste diff tr column pr fmt expand unexpand iconv look hexdump cmp comm fold rev yq zcat; do
    expect DENY "$r of .env denied"                                "$r .env"
done
expect DENY  "git show REV:.env denied"                            'git show HEAD:.env'
expect DENY  "git -C dir show REV:path of a secret denied"         'git -C /repo show HEAD~1:secrets/app.json'
expect DENY  "git diff of a secret path denied"                    'git diff -- .env'
expect DENY  "git log -p of a secret path denied"                  'git log -p config.env'
expect DENY  "dd if= of a secret denied"                           'dd if=.env'
expect DENY  "openssl -in of a secret denied"                      'openssl enc -base64 -in .env'
expect DENY  "scp host:path of a secret denied"                    'scp host:.env /tmp/claude-x/e'
expect ALLOW "git log and git diff without secret paths allowed"   'git log --oneline -3'
expect ALLOW "git diff of source allowed"                          'git diff main...HEAD -- src/'
fetches=(
    'aws secretsmanager get-secret-value --secret-id x'
    'aws secretsmanager batch-get-secret-value --secret-id-list x'
    'aws ssm get-parameter --name x --with-decryption'
    'aws ssm get-parameters --names x --with-decryption'
    'aws ssm get-parameters-by-path --path /x --with-decryption'
    'aws ecr get-login-password'
    'aws ecr get-authorization-token'
    'aws ecr-public get-login-password'
    'aws sts assume-role --role-arn x --role-session-name y'
    'aws sts assume-role-with-saml --role-arn x'
    'aws sts assume-role-with-web-identity --role-arn x'
    'aws sts get-session-token'
    'aws sts get-federation-token --name x'
    'aws sso get-role-credentials --role-name x'
    'aws codeartifact get-authorization-token --domain x'
    'aws eks get-token --cluster-name x'
    'aws rds generate-db-auth-token --hostname x'
    'aws iam create-access-key --user-name x'
    'aws configure get aws_secret_access_key'
    'aws configure export-credentials'
    'gh auth token'
    'gh auth status -t'
    'gh auth status --show-token'
    'security find-generic-password -s x -w'
    'security find-internet-password -s x -g'
    'security dump-keychain -d'
    'kubectl get secret x -o yaml'
    'kubectl -n y get secrets -o json'
    'kubectl config view --raw'
    'kubectl create token x'
    'gcloud auth print-access-token'
    'gcloud auth print-identity-token'
    'gcloud auth application-default print-access-token'
    'gcloud secrets versions access latest --secret x'
    'az account get-access-token'
    'az keyvault secret show --name x --vault-name y'
    'git credential fill'
    'docker-credential-desktop get'
    'sops -d secrets.enc.yaml'
    'sops --decrypt x.yaml'
    'strongbox -decrypt -key k'
    'op read op://vault/item/field'
    'vault kv get secret/x'
    'bw get password x'
    'rbw get x'
    'env FOO=1 op read op://vault/item/field'
)
for f in "${fetches[@]}"; do
    expect DENY "fetch denied: $f"                                 "$f"
done
expect ALLOW "aws configure get of a non-secret key allowed"       'aws configure get region'
expect ALLOW "aws sts get-caller-identity allowed"                 'aws sts get-caller-identity'
expect DENY  "a fetch with a global option before the operation denied" \
    'aws secretsmanager --region eu-west-1 get-secret-value --secret-id x'
expect DENY  "an ssm fetch with a global option denied" \
    'aws ssm --region x get-parameter --name y --with-decryption'
expect DENY  "an sts fetch with a global option denied" \
    'aws sts --region x assume-role --role-arn y --role-session-name z'
expect ALLOW "a non-fetch with a global option allowed" \
    'aws secretsmanager --region eu-west-1 list-secrets'
expect DENY  "an aws kms decrypt denied" \
    'aws kms decrypt --ciphertext-blob fileb://x --query Plaintext --output text'
expect DENY  "gpg -d denied"                                       'gpg -d secret.gpg'
expect DENY  "gpg --decrypt denied"                                'gpg --decrypt x.asc'
expect DENY  "age -d denied"                                       'age -d -i key.txt x.age'
expect ALLOW "gpg --list-keys allowed"                             'gpg --list-keys'
expect ALLOW "aws kms list-keys allowed"                           'aws kms list-keys'
expect ALLOW "a gpg decrypt into the vault allowed"                'gpg -d secret.gpg > $CLAUDE_SECRET_DIR/x'
expect DENY  "gpg -qd (a bundle holding d) denied"                 'gpg -qd x.gpg'
expect DENY  "gpg --decrypt-files denied"                          'gpg --decrypt-files x.gpg'
expect ALLOW "gpg -q --list-keys allowed"                          'gpg -q --list-keys'
expect DENY  "a gpg decrypt behind a runner outside the wrapper list denied" 'aws-vault exec prod -- gpg -d x.gpg'
expect DENY  "a gpg decrypt inside interpreter inline code denied" \
    "python3 -c \"import os; os.system('gpg -d x')\""
expect ALLOW "a quoted title naming age before -d allowed"         'gh pr create -t "Fix age in form" -d'
expect ALLOW "a container named age started detached allowed"      'docker run --name age -d nginx'
expect ALLOW "find -name age with -maxdepth allowed"               'find . -name age -maxdepth 1'
expect DENY  "an ssm fetch with two global options denied" \
    'aws ssm --region x --profile y get-parameter --name z --with-decryption'
expect DENY  "a fetch with a global option value holding a space denied" \
    "aws secretsmanager --query 'a b' get-secret-value --secret-id x"
expect ALLOW "a commit message mentioning configure and get tokens allowed" \
    'git commit -m "configure the client to get tokens lazily"'
expect ALLOW "prose mentioning configure, get and keys allowed"    'echo configure the repo and get keys'
expect ALLOW "op --version allowed"                                'op --version'
expect ALLOW "kubectl get pods in a namespace named vault allowed" 'kubectl -n vault get pods'
expect DENY  "kubectl get with -o before the resource denied"      'kubectl get -o yaml secret x'
expect DENY  "kubectl get of a resource list holding secret denied" 'kubectl get secret,configmap -o yaml'
expect DENY  "kubectl get of a list ending in secrets denied"      'kubectl get configmap,secrets -o json'
expect DENY  "kubectl get of a versioned secrets resource denied"  'kubectl get secrets.v1 -o json'
expect ALLOW "kubectl get pods piped to grep secret allowed"       'kubectl get pods -o yaml | grep secret'
expect ALLOW "kubectl get secrets without -o allowed"              'kubectl get secrets'
expect ALLOW "kubectl get secretstores -o yaml allowed"            'kubectl get secretstores -o yaml'
expect DENY  "kubectl get secret with --template and no -o denied" \
    "kubectl get secret x --template='{{.data.password}}'"
expect DENY  "kubectl get with a quoted template holding a pipe denied" \
    "kubectl get -o go-template='{{.data.token | base64decode}}' secret x"
expect DENY  "kubectl get with a quoted option value holding a pipe denied" \
    "kubectl --context 'a|b' get secret x -o yaml"
expect ALLOW "kubectl get secret into the vault allowed"           'kubectl get secret x -o yaml > $CLAUDE_SECRET_DIR/k'
expect DENY  "kubectl get secret piped onward denied"              'kubectl get secret x -o yaml | cat'
expect ALLOW "kubectl get pods in a namespace named secrets allowed" 'kubectl -n secrets get pods -o yaml'
expect DENY  "kubectl get with a capitalised Secret denied"        'kubectl get Secret x -o yaml'
expect DENY  "kubectl get with an upper-case SECRETS denied"       'kubectl get SECRETS -o json'
# oc takes kubectl's fetch forms, and has its own: extract writes (or, with --to=-, prints) each key, whoami -t and sa
# get-token print a token.
oc_fetches=(
    'oc get secret x -o yaml'
    'oc -n y get secrets -o json'
    "oc get secret x -o jsonpath='{.data}'"
    'oc get -o yaml secret x'
    'oc config view --raw'
    'oc create token x'
    'oc extract secret/x'
    'oc extract secret/x --to=-'
    'oc extract secret/x --to /tmp/x'
    'oc extract secret/x --to=$CLAUDE_SECRET_DIR/../x'
    'oc whoami -t'
    'oc whoami --show-token'
    'oc sa get-token x'
    'oc serviceaccounts get-token x'
    'oc sa new-token x'
    'oc debug node/x -- env'
    'kubectl exec p -- oc extract secret/x --to=-'
    '/usr/local/bin/oc whoami -t'
    '"oc" get secret x -o yaml'
    'OC get secret x -o yaml'
)
for f in "${oc_fetches[@]}"; do
    expect DENY "oc fetch denied: $f"                              "$f"
done
expect ALLOW "oc get pods allowed"                                 'oc get pods'
expect ALLOW "oc get pods -o yaml allowed"                         'oc get pods -o yaml'
expect ALLOW "oc whoami allowed"                                   'oc whoami'
expect ALLOW "oc extract into the vault allowed"                   'oc extract secret/x --to=$CLAUDE_SECRET_DIR/x'
expect ALLOW "oc extract with a separate --to into the vault allowed" 'oc extract secret/x --to $CLAUDE_SECRET_DIR/x'
expect ALLOW "oc extract printed into the vault allowed"           'oc extract secret/x --to=- > $CLAUDE_SECRET_DIR/x'
expect ALLOW "oc get secret into the vault allowed"                'oc get secret x -o yaml > $CLAUDE_SECRET_DIR/k'
expect ALLOW "oc debug of ls allowed"                              'oc debug node/x -- ls'
expect ALLOW "a word ending in oc before get secret -o allowed"    'doc get secret -o x'
expect DENY  "oc extract into a reassigned vault denied" \
    'CLAUDE_SECRET_DIR=/tmp/x oc extract secret/x --to=$CLAUDE_SECRET_DIR/x'
expect DENY  "a debug kubectl fetch with a separate level denied" \
    'kubectl -v 9 get secret x -o yaml > $CLAUDE_SECRET_DIR/k'
expect DENY  "a debug kubectl fetch with a glued level denied" \
    'kubectl -v9 get secret x -o yaml > $CLAUDE_SECRET_DIR/k'
expect DENY  "a debug kubectl fetch with --v denied" \
    'kubectl --v 9 get secret x -o yaml > $CLAUDE_SECRET_DIR/k'
expect DENY  "a debug gcloud fetch with --log-http denied" \
    'gcloud secrets versions access latest --secret x --log-http > $CLAUDE_SECRET_DIR/x'
expect ALLOW "the ECR login pipe allowed" \
    'aws ecr get-login-password --region eu-west-1 | docker login --username AWS --password-stdin 1.dkr.ecr.x.io'
expect ALLOW "a fetch into the vault allowed" \
    'aws secretsmanager get-secret-value --secret-id x > $CLAUDE_SECRET_DIR/x.json'
expect ALLOW "a fetch into the braced vault path allowed" \
    'aws ssm get-parameter --name x --with-decryption > "${CLAUDE_SECRET_DIR}/p"'
expect ALLOW "a fetch into the literal vault path allowed"         'gh auth token > /tmp/claude-abc-vault/secrets/gh'
expect DENY  "a fetch into a literal vault path with a slash in the session segment denied" \
    'gh auth token > /tmp/claude-abc/x-vault/secrets/gh'
expect ALLOW "a single-word fetch into the vault allowed" \
    'op read op://vault/item/field > $CLAUDE_SECRET_DIR/f'
expect DENY  "a fetch into the vault with two stdout targets denied" \
    'aws secretsmanager get-secret-value --secret-id x > $CLAUDE_SECRET_DIR/a > $CLAUDE_SECRET_DIR/b'
expect DENY  "a fetch into the vault followed by a pipe denied"    'gh auth token > $CLAUDE_SECRET_DIR/gh | cat'
expect DENY  "a fetch with only stderr redirected denied" \
    'aws secretsmanager get-secret-value --secret-id x 2>/tmp/claude-x/err'
expect DENY  "a fetch into the vault through .. denied"            'gh auth token > $CLAUDE_SECRET_DIR/../gh'
expect DENY  "a fetch with stdout duplicated to stderr denied"     'gh auth token >&2'
expect DENY  "a fetch with a zero-padded stdout duplication denied" \
    'gh auth token > $CLAUDE_SECRET_DIR/gh 01>&2'
expect DENY  "a fetch with a read-write open of stdout denied" \
    'gh auth token > $CLAUDE_SECRET_DIR/gh 1<>/tmp/claude-x/leak'
expect DENY  "a fetch with a zero-padded second stdout target denied" \
    'gh auth token 01> $CLAUDE_SECRET_DIR/gh > /tmp/claude-x/leak'
expect ALLOW "a fetch into the vault with stderr duplicated to stdout allowed" \
    'gh auth token > $CLAUDE_SECRET_DIR/gh 2>&1'
expect DENY  "a fetch with a two-digit fd duplicated to stdout denied (zsh)" \
    'gh auth token > $CLAUDE_SECRET_DIR/gh 10>&1'
expect DENY  "security -g into the vault denied (stderr)" \
    'security find-generic-password -s x -g > $CLAUDE_SECRET_DIR/p'
expect DENY  "a debug fetch into the vault denied" \
    'aws --debug secretsmanager get-secret-value --secret-id x > $CLAUDE_SECRET_DIR/x'
expect DENY  "a verbose kubectl fetch into the vault denied" \
    'kubectl -v=9 get secret x -o yaml > $CLAUDE_SECRET_DIR/k'
expect DENY  "a fetch fed into a non-login stage denied"           'aws ecr get-login-password --password-stdin | cat'
expect DENY  "a fetch piped through an unknown command into docker denied" \
    'aws ecr get-login-password | tee x | docker login --password-stdin r'
expect DENY  "a fetch inside quotes denied" \
    'echo "aws secretsmanager get-secret-value --secret-id x"'
expect DENY  "a fetch with a quote inside a word denied" \
    'aws secrets"manager" get-secret-value --secret-id x'
expect DENY  "a fetch with quoted words denied" \
    'aws "secretsmanager" "get-secret-value" --secret-id x'
expect DENY  "a fetch with an empty quote pair inside a word denied" "gh auth to''ken"
expect DENY  "a fetch with a backslash inside a word denied"       'gh auth \token'
expect ALLOW "a quoted non-fetch aws command allowed"              'aws "secretsmanager" list-secrets'
expect ALLOW "a quoted fetch into the vault allowed" \
    'aws "secretsmanager" get-secret-value --secret-id x > "$CLAUDE_SECRET_DIR/x.json"'
expect ALLOW "a commit message naming a fetch form allowed" \
    $'git commit -m "$(cat <<\'EOF\'\nDocument aws secretsmanager get-secret-value\nEOF\n)"'
expect ALLOW "a commit message naming a reader and a secret path allowed" \
    $'git commit -m "$(cat <<\'EOF\'\nStop cat .env and grep secrets/app.json in setup\nEOF\n)"'
# The guard tokenises the command with the commit-message heredoc removed, as bash-guard screens it: a quote in the
# message must neither hide a later stage nor open a quote that swallows one.
expect DENY  "an odd double quote in a commit message does not hide a later reader" \
    $'git commit -m "$(cat <<\'EOF\'\nSupport 3.5" drives\nEOF\n)" | cat .env'
expect DENY  "an apostrophe inside quotes in a commit message does not hide a later reader" \
    $'git commit -m "$(cat <<\'EOF\'\nExplain "don\'t" here\nEOF\n)" | cat .env'
expect DENY  "a heredoc marker inside quoted text does not hide a reader after it" \
    $'git commit -m \'x -m "$(cat <<\'EOF\'\n\' ; cat .env ; \'\nEOF\n)"\''
expect DENY  "a commit message whose ) ends the substitution early under bash 3.2 denied" \
    $'git commit -m "$(cat <<\'EOF\'\nfix ) early\nEOF\n)"'
expect ALLOW "a commit message with an apostrophe allowed" \
    $'git commit -m "$(cat <<\'EOF\'\nFix the parser\'s quote handling\nEOF\n)"'
expect ALLOW "a commit message with an inch mark allowed" \
    $'git commit -m "$(cat <<\'EOF\'\nCut a 12" pipe\nEOF\n)"'
expect DENY  "a commit message with an apostrophe and text after the closer denied" \
    $'git commit -m "$(cat <<\'EOF\'\nFix the parser\'s quote handling\nEOF\n)" | cat .env'
expect DENY  "a commit message with a stray closing parenthesis denied" \
    $'git commit -m "$(cat <<\'EOF\'\nSteps: 1) parse\nEOF\n)"'
hd_got=$(jq -nc --arg c $'git commit -m "$(cat <<\'EOF\'\nSteps: 1) parse\nEOF\n)"' '{tool_input:{command:$c}}' \
    | "$HOOK" | jq -r '.hookSpecificOutput.permissionDecisionReason')
if [[ "$hd_got" == *backquote* && "$hd_got" == *"stray closing parenthesis"* && "$hd_got" == *"git commit -F <file>"* ]]
then
    ok "the commit heredoc deny names the backquote and parenthesis limits and git commit -F"
else
    bad "the commit heredoc deny message drifted: $hd_got"
fi
expect ALLOW "a commit message quoting a grouped reader allowed" \
    $'git commit -m "$(cat <<\'EOF\'\nDeny "(cat .env)" forms\nEOF\n)"'
expect ALLOW "a commit message quoting a separator and env allowed" \
    $'git commit -m "$(cat <<\'EOF\'\nDrop "; env " usage\nEOF\n)"'
expect ALLOW "a commit message quoting a pipe and eval allowed" \
    $'git commit -m "$(cat <<\'EOF\'\nNever "| eval x" here\nEOF\n)"'
expect ALLOW "a secret path given to a non-reader as an option value allowed" 'docker compose --env-file .env up'

# Bare secret names, the vault, and globbed names.
for p in config.env .netrc .pgpass id_rsa id_ed25519 .aws/credentials .strongbox-keyid /proc/self/environ; do
    expect DENY "cat of the bare name $p denied"                   "cat $p"
done
expect DENY  "cat of a vault file denied"                          'cat $CLAUDE_SECRET_DIR/x.json'
expect DENY  "cat of a braced vault file denied"                   'cat "${CLAUDE_SECRET_DIR}/x.json"'
expect DENY  "grep -r of the vault denied"                         'grep -r KEY $CLAUDE_SECRET_DIR'
expect DENY  "grep -r of the vault root denied"                    'grep -r KEY /tmp/claude-abc-vault'
expect DENY  "grep -r of the vault root with a trailing slash denied" 'grep -r KEY /tmp/claude-abc-vault/'
expect DENY  "grep -r of the vault root as a dot path denied"      'grep -r KEY /tmp/claude-abc-vault/.'
expect DENY  "grep -r of the vault root under /private/tmp denied" 'grep -r KEY /private/tmp/claude-abc-vault'
expect ALLOW "cat of a module file in a key-vault directory allowed" \
    'cat /Users/x/Repos/claude-tools/modules/key-vault/main.tf'
expect DENY  "a copy out of the vault denied"                      'cp $CLAUDE_SECRET_DIR/x /tmp/claude-x/y'
expect ALLOW "a script given a vault path allowed"                 'bash $CLAUDE_TEMP_DIR/use.sh $CLAUDE_SECRET_DIR/x'
expect ALLOW "cat of a session file allowed"                       'cat $CLAUDE_TEMP_DIR/notes.txt'
expect DENY  "cat .env* denied"                                    'cat .env*'
expect DENY  "cat config/*.env denied"                             'cat config/*.env'
expect DENY  "cat .en[v] denied"                                   'cat .en[v]'
expect DENY  "cat ~/.aws/cred* denied"                             'cat ~/.aws/cred*'
expect ALLOW "cat *.md allowed"                                    'cat *.md'
expect ALLOW "cat of a bracket-only date glob allowed" \
    'cat logs/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].log'
expect DENY  "a reader of a too-wildcarded glob is denied (not matched)" 'cat *a*b*c*d*e*f'
expect ALLOW "a non-reader of a too-wildcarded glob is allowed"          'ls *a*b*c*d*e*f'
# A quoted ( is literal text, never a glob group, so a pattern or filter holding one is not a secret path.
expect ALLOW "a grep regex group after a bracket allowed"          "grep -E '[a-z]+(foo|bar)' notes.txt"
expect ALLOW "a grep regex group between bounded classes allowed" \
    'LC_ALL=C grep -a -o -E "[^;]{0,250}(LaunchEffort|effortLevel)[^;]{0,250}" /opt/x/claude'
expect ALLOW "a jq filter of .[] and select allowed"               "jq '.[] | select(.type == \"stdio\")' x.json"
expect ALLOW "a jq array filter with select allowed"               "jq '[.projects[] | select(.x == 1)]' x.json"
expect DENY  "a quoted extglob of a secret still denied beside it" "cat '@(x)' .env"
expect DENY  "a remote copy of a grouped secret glob denied"       "scp 'host:.e?(v|x)' /tmp/claude-x/"
expect DENY  "a remote copy of an extglob secret name denied"      "rsync 'host:.en@(v)' /tmp/claude-x/"
expect DENY  "a remote copy whose group supplies the dot denied"   "scp 'host:@(.n)etrc' /tmp/claude-x/"
expect DENY  "a remote copy from a bracketed IPv6 host denied"     "scp '[::1]:.e?(v|x)' /tmp/claude-x/"
expect DENY  "a remote copy from a user at an IPv6 host denied"    "scp 'u@[fe80::1]:.en@(v)' /tmp/claude-x/"
expect DENY  "an IPv6 remote copy whose group holds a colon denied" "scp '[::1]:.en@(v|:)' /tmp/claude-x/"
expect DENY  "a git show of an index-stage secret denied"           'git show :0:.netrc'
expect DENY  "a git show of a merge-stage key denied"               'git show :2:id_rsa'
expect DENY  "a reader of a bracket holding ( denied"              "cat '.en[v(]'"
expect DENY  "a git show of a bracket holding ( denied"            "git show 'HEAD:.en[v(]'"

# SSH keys by any common name and the credential files beside them are secret paths; the public halves and the ssh
# client's own files are not.
# shellcheck disable=SC2088  # the ~ is the operand as written, unexpanded
for p in '~/.ssh/id_ecdsa' '~/.ssh/id_dsa' '~/.ssh/work_ed25519' 'id_rsa_work' '~/.ssh/random_file' \
        '~/.docker/config.json' '~/.config/containers/auth.json' '~/.kube/config' '~/.config/gh/hosts.yml' \
        '~/.git-credentials' '.npmrc' '~/.pypirc'; do
    expect DENY "cat of $p denied"                                 "cat $p"
done
# shellcheck disable=SC2088  # the ~ is the operand as written, unexpanded
for p in '~/.ssh/id_ed25519.pub' '~/.ssh/known_hosts' '~/.ssh/config' '~/.ssh/authorized_keys' \
        'src/id_generator.py'; do
    expect ALLOW "cat of $p allowed"                               "cat $p"
done
# A glob operand that can expand to a name under one of those globs is denied as well.
# shellcheck disable=SC2088  # the ~ is the operand as written, unexpanded
for p in '~/.ssh/work_*' '~/.ssh/id_rsa_*' '~/.ssh/id_ed25519_*' '~/.ssh/d*' '~/.ssh/[w]*' '~/.ssh/work_?' \
        '~/.docker/conf*' '~/.kube/conf*' '~/.ssh/known_hosts/../id_rsa'; do
    expect DENY "cat of the glob $p denied"                        "cat $p"
done

# Names compare case-insensitively: a case-insensitive file system (macOS, Windows) opens .ENV as .env and runs CAT as
# cat, and git's icase pathspec magic folds case as it matches.
expect DENY  "a reader of an upper-case .env denied"                'cat .ENV'
expect DENY  "a reader of a mixed-case secrets dir denied"          'cat Secrets/app.json'
expect DENY  "a reader of an upper-case key denied"                 'cat ~/.ssh/ID_RSA'
expect DENY  "a reader of an upper-case glob of .env denied"        "cat '.EN?'"
expect DENY  "an input redirection from an upper-case .env denied"  'cat < .ENV'
expect ALLOW "a reader of an upper-case .env.example allowed"       'cat .ENV.EXAMPLE'
expect DENY  "an upper-case reader denied"                          'CAT .env'
expect DENY  "a mixed-case reader denied"                           'Cat .env'
expect DENY  "an upper-case reader by path denied"                  '/BIN/CAT .env'
expect DENY  "an upper-case grep denied"                            'GREP -n x .env'
expect DENY  "an upper-case git reader denied"                      'GIT show HEAD:.env'
expect DENY  "an upper-case printenv denied"                        'PRINTENV'
expect DENY  "an upper-case env dump denied"                        'ENV'
expect DENY  "an upper-case shell string denied"                    "BASH -c 'cat .env'"
expect DENY  "an upper-case reader behind a wrapper denied"         'sudo CAT .env'
expect ALLOW "an upper-case reader of a benign file allowed"        'CAT README.md'
expect ALLOW "an upper-case word that names no command allowed"     'echo HELLO WORLD'
expect DENY  "a git icase pathspec of .env denied"                  "git log -p -- ':(icase).ENV'"
expect DENY  "a git icase pathspec among other magic denied"        "git log -p -- ':(top,icase).Env'"
expect DENY  "a git grep icase pathspec denied"                     "git grep x -- ':(icase).NETRC'"
expect DENY  "a git icase pathspec glob denied"                     "git log -p -- ':(icase).EN?'"
expect DENY  "git --icase-pathspecs of an upper-case path denied"   'git --icase-pathspecs log -p -- .ENV'
expect DENY  "GIT_ICASE_PATHSPECS of an upper-case path denied"     'GIT_ICASE_PATHSPECS=1 git log -p -- .ENV'
expect ALLOW "a git icase pathspec of a benign file allowed"        "git log -p -- ':(icase)README.md'"
# Pathspec magic that narrows matching still names the secret path after it.
for m in '(top)' '(literal)' '(attr:x)' '(glob)**/' '/' '/:'; do
    expect DENY "a git pathspec with magic $m naming .env denied"   "git log -p -- ':$m.env'"
done
expect ALLOW "a git pathspec with magic naming a benign dir allowed" "git log --oneline -- ':(top)src'"
expect ALLOW "a git exclude pathspec of a benign glob allowed"      "git diff -- ':(exclude)*.lock'"
# APFS folds case fully, so a non-ASCII letter whose fold is ASCII (long s, Kelvin sign, sharp s, the ff/fi/st
# ligatures) opens the ASCII-named file and runs the ASCII-named program. Byte escapes keep the rows locale-free.
ls_=$'\xc5\xbf'; kv_=$'\xe2\x84\xaa'; ff_=$'\xef\xac\x80'; fi_=$'\xef\xac\x81'; st_=$'\xef\xac\x86'
expect DENY  "a reader of a long-s secret name denied"              "cat creds.${ls_}ecret"
expect DENY  "a reader of a long-s key denied"                      "cat ~/.ssh/id_r${ls_}a"
expect DENY  "a reader of a Kelvin-sign key file denied"            "cat tls.${kv_}ey"
expect DENY  "a reader of a ligature keyid denied"                  "cat .${st_}rongbox-keyid"
expect DENY  "an input redirection from a long-s secret denied"     "cat < creds.${ls_}ecret"
expect DENY  "a ligature reader name denied"                        "di${ff_} .env /dev/null"
expect DENY  "a long-s reader name denied"                          "${ls_}ed -n 1p .env"
expect DENY  "a git pathspec of a long-s secret denied"             "git log -p -- 'creds.${ls_}ecret'"
expect ALLOW "a grep for a pound sign allowed"                      $'grep -n \'\xc2\xa35\' notes.md'
expect ALLOW "a reader of an accented benign name allowed"          $'cat R\xc3\xa9sum\xc3\xa9.md'
expect ALLOW "a reader of a ligature benign name allowed"           "cat ${fi_}le.txt"

# ssh joins its remote words with spaces and hands them to the remote shell, which parses them again: a word holding
# whitespace or shell syntax is a command string, and the remote words are commands.
expect DENY  "an ssh remote command in one quoted word denied"      "ssh host 'cat .env'"
expect DENY  "an ssh remote redirection denied"                     "ssh host 'cat<.env'"
expect DENY  "an ssh remote word holding a backslash denied"        "ssh host 'ca\\t' .env"
expect DENY  "an ssh remote word holding quotes denied"             "ssh host \"c'a't\" .env"
expect DENY  "an ssh remote word holding a glob denied"             "ssh host '/bin/c?t' .env"
expect DENY  "an ssh remote word holding braces denied"             "ssh host 'c{a,}t' .env"
expect DENY  "an ssh remote word holding a parameter denied"        "ssh host '\$x' .env"
expect DENY  "an ssh remote env dump denied"                        'ssh host env'
expect DENY  "an ssh ProxyCommand holding a command string denied"  "ssh -o 'ProxyCommand=sh -c x' host"
expect DENY  "an ssh behind a wrapper denied"                       "sudo ssh host 'cat .env'"
expect DENY  "slogin with a remote command string denied"           "slogin host 'cat .env'"
expect DENY  "an upper-case ssh with a remote command string denied" "SSH host 'cat .env'"
expect ALLOW "an ssh remote command of plain words allowed"         'ssh host uptime'
expect ALLOW "an ssh with an identity file and port allowed"        'ssh -i ~/.ssh/deploy_key -p 2222 user@host uptime'
expect ALLOW "an ssh with options and a forward allowed"            'ssh -o StrictHostKeyChecking=no -L 8080:localhost:80 host'
expect ALLOW "an ssh listing a remote directory allowed"            'ssh host ls -la /var/log'
expect ALLOW "an ssh word not at command position allowed"          "echo ssh 'a b'"
expect ALLOW "an ssh in a later stage leaves an earlier one alone"  "grep -n 'a b' x.txt | ssh host wc -l"
# watch and parallel run their command words through sh -c too. parallel quotes its arguments (after :::), and its {}
# is a replacement string, so there only a brace span with , or .. (brace expansion) counts as syntax.
expect DENY  "a watch word holding a backslash denied"              "watch 'ca\\t' .env"
expect DENY  "a watch redirection denied"                           "watch 'cat<.env'"
expect DENY  "a parallel command word holding a backslash denied"   "parallel 'ca\\t' ::: .env"
expect DENY  "a parallel command word holding brace expansion denied" "parallel 'c{a,}t' ::: .env"
expect DENY  "a parallel command word holding a parameter denied"   "parallel '\$x' ::: a"
expect DENY  "a parallel argument with no command template denied"  "parallel ::: 'cat<.env'"
expect DENY  "a parallel perl replacement string denied"            "parallel echo '{=uc=}' ::: a"
expect DENY  "a parallel word starting with = denied"               'parallel =cat ::: .env'
expect ALLOW "a watch of a plain command allowed"                   'watch -n 1 date'
expect ALLOW "a parallel replacement string allowed"                'parallel echo {} ::: a b'
expect ALLOW "a parallel replacement string variant allowed"        'parallel gzip -k {.} ::: a.txt'
expect ALLOW "the other parallel replacement strings allowed"       'parallel echo {/} {//} {/.} {#} {%} {1} {+.} {+..} ::: a'
expect DENY  "a parallel numeric brace expansion denied"            "parallel echo 'a{1..3}' ::: x"
# parallel with no command template reads its commands from its input.
expect DENY  "a fed parallel with no command denied"                'echo x | parallel'
expect DENY  "a fed parallel with only an option and its value denied" 'echo x | parallel -j 4'
expect DENY  "a parallel with no command fed by a file denied"      'parallel --tag < x.txt'
expect DENY  "a fed parallel whose only template word is empty denied" "echo x | parallel ''"
expect ALLOW "a fed parallel with a command allowed"                'ls | parallel gzip'
expect ALLOW "a fed parallel with an attached option value allowed" 'ls | parallel -j4 --jobs=2 gzip -k'
# ssh's local-command options run a command on this machine, and ssh with no remote command runs its input there.
expect DENY  "an ssh LocalCommand option denied"                    'ssh -oPermitLocalCommand=yes -oLocalCommand=env host'
expect DENY  "an ssh LocalCommand option value denied"              'ssh -o localcommand=env host'
expect DENY  "an ssh with no remote command fed by a pipe denied"   'echo x | ssh host'
expect DENY  "an ssh with no remote command fed by a file denied"   'ssh -p 22 -i k host < x.sh'
expect DENY  "an ssh remote word starting with = denied"            'ssh host =cat .env'
expect ALLOW "an ssh remote command fed by a pipe allowed"          'echo x | ssh host cat'
expect ALLOW "an ssh with option values and no command allowed"     'ssh -l user -p 2222 host'
expect DENY  "a fed ssh with only options after the host denied"    'echo x | ssh host -T'
expect DENY  "a fed ssh with an option value before the host denied" 'echo x | ssh -P tag host'
expect DENY  "a fed ssh with an unknown option letter denied"       'echo x | ssh -Z x host'
expect ALLOW "a fed ssh with options after the host and a command allowed" 'echo x | ssh host -l user cat'
expect DENY  "a fed ssh whose only remote word is empty denied"     "echo x | ssh host ''"
expect DENY  "an ssh config read from its input denied"             'echo x | ssh -F /dev/stdin host uptime'
expect DENY  "an ssh config read from an attached fd path denied"   'ssh -F/dev/fd/3 host uptime'
expect DENY  "an ssh option value read from its input denied"       'ssh -oPKCS11Provider=/dev/stdin host uptime'
expect DENY  "an ssh config reaching stdin through .. denied"       'ssh -F /tmp/../dev/stdin host uptime'
expect DENY  "an ssh config reaching stdin by a relative path denied" 'ssh -F ../../../dev/stdin host uptime'
expect DENY  "an ssh config of a dev path relative to / denied"     'ssh -F dev/stdin host uptime'
expect DENY  "an ssh config of stdin relative to /dev denied"       'ssh -F stdin host uptime'
expect DENY  "an ssh config of an upper-case fd path denied"        'ssh -F /DEV/FD/3 host uptime'
expect DENY  "an ssh config of a mixed-case fd path denied"         'ssh -F /Dev/Fd/0 host uptime'
expect DENY  "an ssh config of an upper-case stdin denied"          'ssh -F STDIN host uptime'
# The root volume folds case, so /DEV/stdin is the shell's own input too.
expect DENY  "a fed shell reading an upper-case /dev path denied"   'echo x | bash /DEV/stdin'
expect DENY  "a fed shell reading /dev through .. denied"           'echo x | bash /tmp/../dev/stdin'
expect DENY  "a fed shell reading a dev path relative to / denied"  'echo x | bash dev/stdin'
expect DENY  "a fed shell reading an fd path relative to /dev denied" 'echo x | bash fd/0'
expect DENY  "a fed shell reading stdin relative to /dev denied"    'echo x | bash stdin'
expect DENY  "a fed shell reading a bare fd number denied"          'echo x | bash 0'
expect DENY  "an ssh config of a bare fd number denied"             'ssh -F 3 host uptime'
expect DENY  "an ssh config of an attached bare fd number denied"   'ssh -F3 host uptime'
expect ALLOW "an ssh port value allowed"                            'ssh -p 22 -p22 -oPort=22 host uptime'
expect ALLOW "a shell running a script by a .. path allowed"        'bash ../scripts/x.sh'
expect ALLOW "an ssh config file allowed"                           'ssh -F ~/.ssh/config.d/x host uptime'
expect ALLOW "an ssh config in the working directory allowed"       'ssh -F ./ssh_config.d/devices host uptime'
expect ALLOW "an ssh remote read of /proc allowed"                  'ssh host cat /proc/cpuinfo'

# Input redirection, here-strings and the environment.
expect DENY  "a leading input redirection from .env denied"        '<.env cat'
expect DENY  "a bare input redirection from .env denied (zsh READNULLCMD)" '<.env'
expect DENY  "tee fed from .env denied"                            'tee /tmp/claude-x/t < .env'
expect DENY  "xargs fed from .env denied"                          'xargs < .env'
expect DENY  "xargs -a .env denied"                                'xargs -a .env echo'
expect DENY  "a here-string of a secret variable denied"           'cat <<< $GITHUB_TOKEN'
expect DENY  "export -p denied"                                    'export -p'
expect DENY  "bare export denied"                                  'export'
expect DENY  "declare -x denied"                                   'declare -x'
expect DENY  "declare -p denied"                                   'declare -p'
expect DENY  "typeset -m denied"                                   "typeset -m 'AWS*'"
expect DENY  "printenv of an indirect pattern denied"              'printenv ${!AWS*}'
expect DENY  "printenv of a secret variable denied"                'printenv GITHUB_TOKEN'
expect DENY  "bare set denied"                                     'set'
expect DENY  "jq -n env denied"                                    'jq -n env'
expect DENY  "jq of \$ENV denied"                                  "jq -n '\$ENV.HOME'"
expect DENY  "awk ENVIRON denied"                                  "awk 'BEGIN { print ENVIRON[\"HOME\"] }'"
expect DENY  "ps with an e bundle denied"                          'ps eww'
expect DENY  "ps -E denied"                                        'ps -E'
expect ALLOW "export of an assignment allowed"                     'export FOO=bar'
expect ALLOW "declare of an assignment allowed"                    'declare FOO=bar'
expect ALLOW "declare -p of a named variable allowed"              'declare -p HOME'
expect ALLOW "set -x allowed"                                      'set -x'
expect ALLOW "python3 -m venv env allowed"                         'python3 -m venv env'
expect ALLOW "conda env list allowed"                              'conda env list'
expect ALLOW "ps aux allowed"                                      'ps aux'
expect ALLOW "ps -o user allowed"                                  'ps -o pid,user,command'
expect ALLOW "jq .environment allowed"                             "jq '.environment' package.json"

# Shell command strings, and shells or interpreters reading a secret.
expect DENY  "bash -c denied"                                      "bash -c 'echo hi'"
expect DENY  "bash -lc denied"                                     "bash -lc 'echo hi'"
expect DENY  "sh -c inside find -exec denied"                      "find . -exec sh -c 'echo {}' \\;"
expect DENY  "eval denied"                                         'eval cat .env'
expect DENY  "a command string piped into sh denied"               "echo 'cat .env' | sh"
expect DENY  "a here-string into sh denied"                        "sh <<< 'cat .env'"
expect DENY  "a script file fed to bash on stdin denied"           'bash < script.sh'
expect DENY  "bash -x denied"                                      'bash -x script.sh'
expect DENY  "zsh -o xtrace denied"                                'zsh -o xtrace script.zsh'
expect DENY  "bash --verbose denied"                               'bash --verbose script.sh'
expect DENY  "sh -v of a secret denied"                            'sh -v .env'
expect DENY  "sh reading a secret as its script denied"            'sh .env'
expect DENY  "perl -pe1 of a secret denied"                        'perl -pe1 .env'
expect DENY  "python3 -c with a later secret operand denied"       "python3 -c 'import sys' .env"
expect DENY  "python3 -m with a later secret operand denied"       'python3 -m json.tool .env'
expect DENY  "su -c denied"                                        "su -c 'cat .env' root"
expect DENY  "watch given a command string denied"                 "watch 'cat .env'"
expect ALLOW "bash script.sh allowed"                              'bash script.sh'
expect ALLOW "zsh script.zsh allowed"                              'zsh script.zsh'
expect DENY  "bash -O before -c denied"                            "bash -O extglob -c 'echo hi'"
expect DENY  "bash --rcfile before -c denied"                      "bash --rcfile /dev/null -c 'cat .env'"
expect DENY  "bash +O before -c denied"                            "bash +O extglob -c 'echo hi'"
expect ALLOW "bash -O with a script allowed"                       'bash -O extglob script.sh'
expect DENY  "bash -eo before -c denied"                           "bash -eo pipefail -c 'cat .env'"
expect DENY  "bash -euo before -c denied"                          "bash -euo pipefail -c 'echo hi'"
expect DENY  "bash -eo xtrace denied"                              'bash -eo xtrace script.sh'
expect ALLOW "bash -euo pipefail with a script allowed"            'bash -euo pipefail script.sh'
expect DENY  "bash -oe before -c denied"                           "bash -oe pipefail -c 'cat .env'"
expect DENY  "bash -Oe before -c denied"                           "bash -Oe extglob -c 'echo hi'"
expect DENY  "bash -oeo (two values) before -c denied"             "bash -oeo pipefail errexit -c 'echo hi'"
expect ALLOW "bash -oe pipefail with a script allowed"             'bash -oe pipefail script.sh'
expect DENY  "bash --rcfile of a secret denied"                    'bash --rcfile .env -i'
expect DENY  "bash --init-file= of a secret denied"                'bash --init-file=.env -i'
expect ALLOW "bash --rcfile of /dev/null with a script allowed"    'bash --rcfile /dev/null script.sh'
expect DENY  "a shell fed on /dev/stdin denied"                    "echo 'cat .env' | bash /dev/stdin"
expect DENY  "a shell fed on - denied"                             'echo x | sh -'
expect DENY  "a shell fed on /dev/fd/0 denied"                     'echo x | bash /dev/fd/0'
expect DENY  "python3 fed from a secret with no program denied"    'python3 < .env'
expect DENY  "node fed from a secret with no program denied"       'node < .env'
expect ALLOW "python3 fed from an ordinary file allowed"           'python3 < input.txt'
expect ALLOW "python3 running a script fed a secret allowed"       'python3 script.py < .env'
expect DENY  "python3 with inline code fed a secret denied"        "python3 -c 'import sys' < .env"
expect DENY  "python3 reading its program from stdin fed a secret denied" 'python3 - < .env'
expect DENY  "python3 given /dev/stdin fed a secret denied"        'python3 /dev/stdin < .env'
expect ALLOW "python3 with inline code fed an ordinary file allowed" "python3 -c 'print(1)' < input.txt"
expect DENY  "a shell given /dev//stdin and a pipe denied"         'echo x | bash /dev//stdin'
expect DENY  "a shell given a /proc fd and a pipe denied"          'echo x | bash /proc/self/fd/0'
expect DENY  "a shell whose program under /proc names a secret denied"  'bash /proc/self/cwd/.env'
expect DENY  "an interpreter whose program under /proc names a secret denied" 'python3 /proc/self/cwd/.env'
expect ALLOW "ps aux | grep bash allowed"                          'ps aux | grep bash'
expect ALLOW "a script given a secret path as an argument allowed" 'python3 tools/use.py .env'
expect DENY  "source of a secret denied"                           'source .env'
expect DENY  ". of a secret denied"                                '. .env'
expect DENY  "source of a bare secret name denied"                 'source config.env'
expect ALLOW "source of an activate script allowed"                'source venv/bin/activate'
expect ALLOW ". of a script allowed"                               '. ./script.sh'
expect ALLOW "time find with a dot and a secret pattern allowed"   'time find . -name .env'
expect ALLOW "sudo find with a secret glob pattern allowed"        "sudo find . -name '*.pem'"
expect ALLOW "timeout find with a secret pattern allowed"          'timeout 60 find . -name .env'
expect ALLOW "xargs find with a secret pattern allowed"            'echo x | xargs find . -name .env'
expect ALLOW "sudo ls with a dot and a secret name allowed"        'sudo ls -la . .env'
expect DENY  "command . of a secret denied"                        'command . .env'
expect DENY  "command -p . of a secret denied"                     'command -p . .env'
expect DENY  "command -- . of a secret denied"                     'command -- . .env'
expect DENY  "time -p . of a secret denied"                        'time -p . .env'
expect DENY  "time with an assignment . of a secret denied"        'time FOO=1 . .env'
expect DENY  "! with an assignment . of a secret denied"           '! FOO=1 . .env'
expect DENY  "time -p source of a secret denied"                   'time -p source .env'

# xargs and parallel read their input as operands; copiers and accepted carve-outs.
expect DENY  "echo .env | xargs cat denied"                        'echo .env | xargs cat'
expect DENY  "find .env | xargs cat denied"                        'find . -name .env | xargs cat'
expect DENY  "xargs git log of a secret from an earlier stage denied"  'echo .env | xargs git log -p'
expect DENY  "xargs git show of a secret revision path denied"         'echo HEAD:.env | xargs git show'
expect DENY  "parallel git show of a secret denied"                    'echo .env | parallel git show HEAD:{}'
expect DENY  "xargs perl with inline code and a secret denied"         'echo .env | xargs perl -pe1'
expect DENY  "xargs python3 -m with a secret denied" \
    'echo secrets/app.json | xargs python3 -m json.tool'
expect ALLOW "ls .env | cat allowed"                               'ls .env | cat'
expect ALLOW "cp .env.example .env allowed"                        'cp .env.example .env'
expect ALLOW "grep --exclude=.env allowed"                         'grep -rn --exclude=.env TODO .'
expect ALLOW "rsync --exclude=.env allowed"                        'rsync -a --exclude=.env ./ /tmp/claude-x/d'
expect ALLOW "a quoted alternation holding env is not an env stage" "grep -E '\"(a|env|b)\"' file"

# Wrappers beyond the common list, and find -exec, still run their command at command position.
expect DENY  "direnv exec env denied"                              'direnv exec . env'
expect DENY  "setsid env denied"                                   'setsid env'
expect DENY  "find -exec env denied"                               'find . -maxdepth 0 -exec env \;'
expect DENY  "parallel op read denied"                             'parallel op read ::: x'
expect ALLOW "find -name env allowed"                              'find . -name env'
expect ALLOW "direnv allow allowed"                                'direnv allow'
expect DENY  "find -execdir printenv denied"                       'find . -maxdepth 0 -execdir printenv \;'
expect DENY  "find -exec env -u denied"                            'find . -exec env -u X \;'
expect ALLOW "find -exec grep ... + allowed"                       'find . -exec grep -l TODO {} +'
expect DENY  "find -exec env -u X + denied (a bare + is an argument)" 'find . -exec env -u X +'
expect DENY  "a bare + does not end find -exec before a later env" \
    'find . -maxdepth 0 -exec xargs -I + env \;'
expect DENY  "{ env } denied (zsh runs it with no ;)"              '{ env }'
expect DENY  "{ set } denied"                                      '{ set }'
expect DENY  "{ export -p } denied"                                '{ export -p }'
expect DENY  "{ source of a secret } denied"                       '{ source .env }'
expect DENY  "repeat env denied"                                   'repeat 1 env'
expect ALLOW "echo { allowed"                                      'echo {'
expect ALLOW "find -exec ls {} allowed"                            'find . -exec ls {} \;'
expect DENY  "a nested { group denied"                             '{ { set } }'
expect DENY  "a { group holding a pipeline denied"                 '{ true | printenv }'
expect DENY  "repeat holding source of a secret denied"            'repeat 1 source .env'
expect DENY  "a plain { group denied"                              '{ ls }'
expect ALLOW "a git stash reference holding a brace allowed"       'git stash show stash@{0}'
expect ALLOW "echo of a brace expansion allowed"                   'echo {a,b}'

# The directory probe: a recursive reader that prints file contents is denied when its root holds a secret file, and
# outright when the root is at or above $HOME or the vault. Fixtures are empty files with secret names.
pt=$(mktemp -d)
mkdir -p "$pt/plain/src" "$pt/plain/sub dir" "$pt/repo/src" "$pt/sec" "$pt/lroot" "$pt/sp/a b" "$pt/cfg" \
    "$pt/aws/.aws/sub"
: >"$pt/plain/.env"
: >"$pt/plain/src/a.py"
: >"$pt/plain/sub dir/b.txt"
git -C "$pt/repo" init -q
printf '.env\n' >"$pt/repo/.gitignore"
: >"$pt/repo/.env"
: >"$pt/repo/src/a.py"
: >"$pt/sec/.env"
ln -s "$pt/sec" "$pt/lroot/s"
: >"$pt/sp/a b/.env"
: >"$pt/cfg/config.env"
: >"$pt/aws/.aws/credentials"
P="$pt/plain"
R="$pt/repo"
expect_in "$P" DENY  "a recursive grep of a root holding .env denied"            'grep -rn KEY .'
expect_in "$P" DENY  "a recursive grep with no path, from a root holding .env, denied" 'grep -rn KEY'
expect_in "$P" ALLOW "grep -rl lists names only, allowed"                        'grep -rl KEY .'
expect_in "$P" ALLOW "grep -rc counts only, allowed"                             'grep -rc KEY .'
expect_in "$P" ALLOW "grep -r --files-with-matches allowed"                      'grep -r --files-with-matches KEY .'
expect_in "$P" ALLOW "a recursive grep of a subdirectory without secrets allowed" 'grep -rn KEY src'
expect_in "$P" ALLOW "a recursive grep narrowed by --include allowed"            "grep -rn --include='*.py' KEY ."
expect_in "$P" ALLOW "a recursive grep narrowed by a separate --include allowed" "grep -rn --include '*.py' KEY ."
expect_in "$P" ALLOW "a recursive grep excluding .env allowed"                   'grep -rn --exclude=.env KEY .'
expect_in "$P" DENY  "a recursive grep whose --include holds a brace denied"     "grep -rn --include='*.{py,env}' KEY ."
expect_in "$P" ALLOW "a recursive grep -e of a clean subdirectory allowed"       'grep -r -e KEY src'
expect_in "$P" DENY  "grep -r -A 3 src searches . for src, denied"               'grep -r -A 3 src'
expect_in "$P" DENY  "grep -d recurse denied"                                    'grep -d recurse KEY .'
expect_in "$P" DENY  "grep --directories=recurse denied"                         'grep --directories=recurse KEY .'
expect_in "$P" DENY  "egrep -R denied"                                           'egrep -R KEY .'
expect_in "$P" ALLOW "a non-recursive grep of a file allowed"                    'grep -n KEY src/a.py'
expect_in "$P" DENY  "rg with no path, from a root holding .env, denied"         'rg KEY'
expect_in "$P" ALLOW "rg -l allowed"                                             'rg -l KEY'
expect_in "$P" ALLOW "rg --files allowed"                                        'rg --files'
expect_in "$P" ALLOW "rg fed by a pipe reads its input, allowed"                 'git diff | rg foo'
expect_in "$P" ALLOW "rg of a clean subdirectory allowed"                        'rg KEY src'
expect_in "$P" ALLOW "rg -g with a value before the pattern, of a clean subdirectory, allowed" "rg -g '*.py' KEY src"
expect_in "$R" ALLOW "rg in a repo whose .env is gitignored allowed"             'rg KEY'
expect_in "$R" DENY  "rg --no-ignore in that repo denied"                        'rg --no-ignore KEY'
expect_in "$R" DENY  "rg -uu in that repo denied"                                'rg -uu KEY'
expect_in "$R" DENY  "grep -r ignores .gitignore, denied"                        'grep -rn KEY .'
expect_in "$R" ALLOW "git grep where .env is untracked allowed"                  'git grep KEY'
expect_in "$R" ALLOW "git grep --untracked honours .gitignore, allowed"          'git grep --untracked KEY'
expect_in "$R" DENY  "git grep --no-index reads ignored files, denied"           'git grep --no-index KEY'
expect_in "$P" DENY  "git grep outside a repository denied"                      'git grep KEY'
expect_in "$P" ALLOW "git grep -l allowed"                                       'git grep -l KEY'
expect      DENY  "git -C a root holding .env, then grep, denied"                "git -C $P grep KEY"
expect_in "$P" DENY  "find piped into xargs cat, over a root holding .env, denied" 'find . -type f | xargs cat'
expect_in "$P" ALLOW "find -name of a plain name piped into xargs cat allowed"    'find . -name x | xargs cat'
expect_in "$P" DENY  "find -exec cat over a root holding .env denied"            "find . -exec cat {} \\;"
expect_in "$P" ALLOW "find -exec cat of a clean subdirectory allowed"            "find src -exec cat {} \\;"
expect_in "$P" ALLOW "find with no reader allowed"                               'find . -name x'
expect_in "$P" ALLOW "find piped into xargs ls allowed"                          'find . -name x | xargs ls'
expect_in "$P" DENY  "diff -r of a root holding .env denied"                     'diff -r . src'
expect_in "$P" ALLOW "diff -r of two clean directories allowed"                  "diff -r src 'sub dir'"
expect_in "$pt/lroot" DENY  "grep -R over a symlinked secret directory denied"   'grep -R KEY .'
expect_in "$pt/lroot" ALLOW "grep -r does not follow a symlinked directory, allowed" 'grep -r KEY .'
expect_in "$pt/sp" DENY "a recursive grep under a directory whose name holds a space denied" "grep -rn KEY 'a b'"
expect      DENY  "a recursive grep of ~ denied"                                 'grep -rn KEY ~'
expect      DENY  "a recursive grep of \"\$HOME\" denied"                        'grep -rn KEY "$HOME"'
expect      DENY  "a recursive grep of / denied"                                 'grep -rn KEY /'
expect      DENY  "a recursive grep of /tmp denied (the vault is below)"         'grep -rn KEY /tmp'
expect_in "$HOME" DENY "a recursive grep with no path, from \$HOME, denied at once" 'grep -rn KEY'
expect      ASK   "a recursive grep of a variable root asks"                     'grep -rn KEY $SOMEDIR'
expect      DENY  "a held ask loses to a later deny"                             'grep -rn KEY $SOMEDIR | cat .env'
expect_in "$P" ALLOW "cat * matches no dotfile, allowed"                         'cat *'
expect_in "$pt/cfg" DENY "cat * matching config.env denied"                      'cat *'
expect_in "$P" DENY  "grep -r over a wildcard-only operand reads its directory, denied" 'grep -r KEY *'
HOME="$pt/aws" expect DENY "cat ~/.aws/* denied"                                 'cat ~/.aws/*'
expect_in "$P" ALLOW "ls * stays allowed (not a reader)"                         'ls *'
gdir2=$(mktemp -d)
mkdir -p "$gdir2/secrets"
: >"$gdir2/secrets/readme.pub"
expect_in "$gdir2" DENY "a glob operand is still screened as written when it expands to an allowed name" 'cat secrets/*'
rm -rf "$gdir2"
want="SECRET-PROBE BLOCK: 'grep -r' prints the contents of files under a directory that holds secret-bearing files"
got=$(jq -nc --arg d "$P" '{tool_input:{command:"grep -rn KEY ."}, cwd:$d}' | "$HOOK" \
    | jq -r '.hookSpecificOutput.permissionDecisionReason')
[[ "$got" == "$want ($P/.env)"* ]] && ok "the probe deny names the reader and the file" \
    || bad "probe deny drifted: $got"
got=$(cd "$P" && jq -nc '{tool_input:{command:"grep -rn KEY ."}}' | "$HOOK" \
    | jq -r '.hookSpecificOutput.permissionDecision')
[[ "$got" == deny ]] && ok "a payload with no cwd probes the hook's own directory" || bad "no-cwd payload: $got"

# The Bash tool's grep is ugrep, a script's is BSD grep on a Mac and GNU grep on Linux: where they read an option
# differently, the probe takes the reading that searches more.
mkdir -p "$pt/xd/sec" "$pt/trk/src" "$pt/gl/secrets" "$pt/gl/src" "$pt/qd"
: >"$pt/xd/sec/.env"
: >"$pt/qd/.env"
git -C "$pt/trk" init -q
: >"$pt/trk/config.env"
: >"$pt/trk/src/a.py"
git -C "$pt/trk" add config.env src/a.py
: >"$pt/gl/secrets/app.json"
: >"$pt/gl/src/a.py"
X="$pt/xd"
T="$pt/trk"
G="$pt/gl"
expect_in "$P" DENY  "a grep of a directory reads the files in it, denied"       'grep -n KEY .'
expect_in "$P" ALLOW "a grep of a clean directory allowed"                       'grep -n KEY src'
expect_in "$P" ALLOW "a grep of * reads the directories it matches, none holding a secret, allowed" 'grep -n KEY *'
expect_in "$P" ALLOW "a grep of a glob matching files only allowed"              'grep -n KEY src/*'
expect_in "$P" DENY  "grep -3 with no file searches . three levels deep, denied" 'grep -3 KEY'
expect_in "$P" DENY  "grep --index searches recursively, denied"                 'grep --index KEY'
expect_in "$P" DENY  "an abbreviated --recursive denied"                         'grep --recur KEY'
expect_in "$X" DENY  "an abbreviated --dereference-recursive denied"             'grep --deref KEY'
expect_in "$P" DENY  "an --include holding a / is not used to narrow, denied"    "grep -rn --include='src/*.py' KEY ."
expect_in "$P" DENY  "an --exclude holding a / is not used to narrow, denied"    "grep -rn --exclude='sub/*.env' KEY ."
expect_in "$pt" DENY "an --include that BSD grep matches against the whole path is not used to narrow, denied" \
    "grep -rn --include='q*' KEY qd"
expect_in "$P" DENY  "a later --include overrides an earlier --exclude, denied" \
    "grep -rn --exclude=.env --include='*.env' KEY ."
expect_in "$P" DENY  "after an --exclude, a file no --include matches is still searched, denied" \
    "grep -rn --exclude=x --include='*.py' KEY ."
expect_in "$P" ALLOW "an --include before an --exclude narrows, allowed" \
    "grep -rn --include='*.py' --exclude=x KEY ."
expect_in "$P" DENY  "a -g glob adds to the includes, denied" \
    "grep -rn --include='*.py' -g '*.env' KEY ."
expect_in "$P" DENY  "a negated --exclude includes the file again, denied" \
    "grep -rn --exclude=.env --exclude='!.env' KEY ."
expect_in "$X" ALLOW "an --exclude-dir narrows, allowed"                         'grep -rn --exclude-dir=sec KEY .'
expect_in "$X" DENY  "an --include-dir can override an --exclude-dir, denied" \
    'grep -rn --exclude-dir=sec --include-dir=sec KEY .'
expect_in "$P" DENY  "--context may take no separate value, so . may be a root, denied" 'grep -r --context KEY . src'
expect_in "$P" DENY  "GREP_OPTIONS can make grep recursive, denied"              'GREP_OPTIONS=-r grep -n KEY'
expect_in "$P" DENY  "ugrep -r denied"                                           'ugrep -rn KEY .'
expect_in "$P" DENY  "ggrep -r denied"                                           'ggrep -rn KEY .'
expect_in "$P" ALLOW "rg --version searches nothing, allowed"                    'rg --version'
expect_in "$P" ALLOW "a reader named with no pattern searches nothing, allowed"  'which rg'
expect_in "$R" ALLOW "rg --hidden still honours .gitignore, allowed"             'rg --hidden KEY'
expect_in "$R" DENY  "RIPGREP_CONFIG_PATH can widen rg, denied"                  'RIPGREP_CONFIG_PATH=x rg KEY'
expect_in "$R" DENY  "an abbreviated git grep --no-index denied"                 'git grep --no-ind KEY'
expect_in "$R" DENY  "git grep --untracked --no-exclude-standard reads ignored files, denied" \
    'git grep --untracked --no-exclude-standard KEY'
expect_in "$T" DENY  "git grep of a repository holding a tracked secret denied"  'git grep KEY'
expect_in "$T" ALLOW "git grep -l there allowed"                                 'git grep -l KEY'
expect_in "$T" DENY  "git grep -O shows whole files in a pager, denied"          'git grep -Ocat KEY'
expect_in "$R" ASK   "git grep of a revision asks"                               'git grep KEY HEAD'
expect_in "$R" ALLOW "git grep of a clean path after -- allowed"                 'git grep KEY -- src'
expect_in "$R" ASK   "git grep of a pathspec holding magic asks"                 'git grep KEY -- :/'
expect      DENY  "git -C twice resolves the second against the first, denied"   "git -C $pt -C plain grep KEY"
expect      DENY  "a git grep path resolves against git -C, denied"              "git -C $P grep KEY ."
expect      ASK   "git grep in another work tree asks"                           "git --work-tree=$P grep KEY"
expect_in "$R" DENY  "a git -c core setting can change what git reads, so the root is listed in full, denied" \
    'git -c core.excludesFile=/dev/null grep --untracked KEY'
expect_in "$P" ALLOW "git diff of a path is a diff against git's index, allowed" 'git diff -- .'
expect_in "$P" DENY  "git diff --no-index of a root holding .env denied"         'git diff --no-index . src'
expect_in "$P" DENY  "diff of two directories reads the files in both, denied"   'diff . src'
expect_in "$P" ALLOW "diff -rq reports only which files differ, allowed"         'diff -rq . src'
expect_in "$P" ALLOW "diff --brief likewise, allowed"                            'diff -r --brief . src'
expect_in "$P" DENY  "a q that is diff -x's value is no -q, denied"              'diff -rxq . src'
expect      ASK   "env -C moves the directory a relative root resolves against, asks" "env -C $P grep -rn KEY ."
expect_in "$P" DENY  "an operand named like a reader does not start a second walk, denied" "grep -rn KEY src rg $pt/sec"
expect_in "$P" DENY  "a names-only grep piped into xargs cat reads what it lists, denied" 'grep -rl KEY . | xargs cat'
expect_in "$P" ALLOW "a names-only grep of a clean directory piped into xargs cat allowed" \
    'grep -rl KEY src | xargs cat'
expect_in "$P" DENY  "rg --files piped into xargs cat denied"                    'rg --files | xargs cat'
expect      DENY  "find -f names a root, denied"                                 "find -f $P -type f -exec cat {} \\;"
expect      ALLOW "find -f with a -name narrowing allowed"                       "find -f $P -name x -exec cat {} \\;"
expect      DENY  "a find root after the expression denied"                      "find -name x $P -exec cat {} \\;"
expect      DENY  "a find root after -exec denied"                               "find $P/src -exec cat {} \\; $P"
expect      DENY  "find -D takes a value, so the root after it is probed, denied" "find -D tree $P -exec cat {} \\;"
expect_in "$pt/lroot" DENY  "find -follow follows a symlinked secret directory, denied" \
    "find . -follow -exec cat {} \\;"
expect_in "$pt/lroot" ALLOW "find without -follow does not, allowed"             "find . -exec cat {} \\;"
expect_in "$P" ALLOW "a find -name pattern is not a root, allowed"         "find src -name '*.py' -exec cat {} \\;"
expect_in "$G" DENY  "cat */* reaches a secrets directory one level down, denied" 'cat */*'
expect_in "$G" DENY  "cat */a* denied"                                           'cat */a*'
expect_in "$G" DENY  "echo */* piped into xargs cat denied"                      'echo */* | xargs cat'
expect_in "$G" ALLOW "ls */* stays allowed (not a reader)"                       'ls */*'
expect_in "$P" ALLOW "cat of a clean directory's * allowed"                      'cat src/*'

# A reader after xargs takes more words from its input; stdin feeds rg only from a pipe or a regular file; -O shows
# whole files whatever else git grep is told; rg searches a root it is named even when .gitignore ignores it.
mkdir -p "$pt/ig/ign" "$pt/ns/sub" "$pt/plain/doc"
git -C "$pt/ig" init -q
printf 'ign/\n' >"$pt/ig/.gitignore"
: >"$pt/ig/ign/k.pem"
: >"$pt/ns/sub/.env"
: >"$pt/plain/src/README.md"
: >"$pt/plain/doc/README.md"
I="$pt/ig"
N="$pt/ns"
expect_in "$P" DENY  "xargs gives grep -r its pattern, so it searches ., denied"  'echo KEY | xargs grep -r'
expect_in "$P" DENY  "xargs gives rg its pattern, so it searches ., denied"       'echo KEY | xargs rg'
expect_in "$P" DENY  "xargs gives rg its root, denied"                            'echo . | xargs rg KEY'
expect_in "$P" DENY  "rg does not read a /dev/null stdin, so it searches ., denied" 'rg KEY < /dev/null'
expect_in "$P" ALLOW "rg reading a regular file on stdin allowed"                 'rg KEY < src/a.py'
expect_in "$T" DENY  "git grep -l -O shows whole files, denied"                   'git grep -l -Ocat KEY'
expect_in "$T" DENY  "git grep -lO shows whole files, denied"                     'git grep -lOcat KEY'
expect_in "$T" DENY  "git grep -c -O shows whole files, denied"                   'git grep -c -Ocat KEY'
expect_in "$T" DENY  "git grep -O -l shows whole files, denied"                   'git grep -O -l KEY'
expect_in "$T" DENY  "git grep --open-files-in-pager -l shows whole files, denied" \
    'git grep --open-files-in-pager=cat -l KEY'
expect_in "$T" DENY  "an abbreviated --open-files-in-pager shows whole files, denied" 'git grep --open=cat -l KEY'
expect_in "$I" DENY  "rg searches a root it is named although .gitignore ignores it, denied" 'rg KEY ign'
expect_in "$I" ALLOW "rg with no root skips the ignored directory, allowed"       'rg KEY'
mkdir -p "$pt/many"
many=""
for i in {1..32}; do
    mkdir "$pt/many/d$i"
    many+="git -C $pt/many/d$i grep a | "
done
: >"$pt/repo/src/.env"
expect_in "$R" ALLOW "rg of a root .gitignore does not ignore keeps git's listing, allowed" 'rg KEY src'
expect_in "$R" DENY  "past the hook's 32 git calls, rg lists its root in full, denied" "${many}rg KEY src"
expect_in "$P" ALLOW "cat */README.md matches no secret, allowed"                 'cat */README.md'
expect_in "$P" ALLOW "head of */README.md allowed"                                'head -n 5 */README.md'
expect_in "$P" ALLOW "a grep of */*.py allowed"                                   'grep -n foo */*.py'
expect_in "$N" DENY  "cat */.env denied"                                          'cat */.env'
expect_in "$N" DENY  "a grep of */ reads a directory holding .env, denied"        'grep -n KEY */'
expect_in "$N" DENY  "a grep of * reads a directory holding .env, denied"         'grep -n KEY *'
expect_in "$P" ALLOW "find piped into a names-only xargs grep allowed" \
    "find . -name '*.py' | xargs grep -l foo"
expect_in "$P" ALLOW "find piped into a counting xargs grep allowed"              'find . -type f | xargs grep -c foo'
expect_in "$P" DENY  "find piped into a content xargs grep denied"                'find . | xargs grep foo'
expect_in "$P" ALLOW "find -exec of a names-only grep allowed" \
    "find . -name '*.py' -exec grep -l foo {} +"
expect_in "$P" DENY  "find -exec sed -i may still print through w /dev/stdout, denied" \
    "find . -type f -exec sed -i '' s/a/b/ {} +"
# A find expression of only -name or -iname plain globs (with -type f or d, -maxdepth, -mindepth, -print, -print0 and
# -exec) lists only names that match, so it narrows its roots' probe; a directory that matches keeps all below it.
expect_in "$P" ALLOW "find -name piped into a content xargs grep allowed"     "find . -name '*.py' | xargs grep -n foo"
expect_in "$P" ALLOW "find -name -exec of a content grep allowed" "find . -name '*.py' -exec grep -n foo {} +"
expect_in "$P" ALLOW "find -name -exec sed -i of matching files allowed" \
    "find . -name '*.py' -exec sed -i '' s/a/b/ {} +"
expect_in "$P" ALLOW "find -iname with -type, -maxdepth and -print0 narrows too, allowed" \
    "find . -maxdepth 3 -type f -iname '*.PY' -print0 | xargs -0 grep -n foo"
expect_in "$P" DENY  "find -name of a secret glob into xargs grep denied" "find . -name '*.env' | xargs grep -n foo"
expect_in "$P" DENY  "find -iname of a secret glob in another case denied"   "find . -iname '*.ENV' | xargs grep -n foo"
expect_in "$P" DENY  "find -name with -o piped into xargs grep denied" \
    "find . -name '*.py' -o -name .env | xargs grep -n foo"
expect_in "$P" DENY  "find with ! before -name denied"                       "find . ! -name '*.py' | xargs grep -n foo"
expect_in "$P" DENY  "find -name with another predicate denied"   "find . -name '*.py' -newer x | xargs grep -n foo"
expect_in "$P" DENY  "find -name with -type l denied"             "find . -name '*.py' -type l | xargs grep -n foo"
expect_in "$P" DENY  "find -name of a bracket glob denied"        "find . -name '[.]env' | xargs grep -n foo"
expect_in "$P" DENY  "find -name with a later -o after -exec's end denied" \
    "find . -name '*.py' -exec grep -n foo {} \\; -o -name x -exec grep -n foo {} \\;"
mkdir -p "$pt/fn/src" "$pt/fn/sub.py"
: >"$pt/fn/src/a.py"
: >"$pt/fn/sub.py/.env"
expect_in "$pt/fn" DENY "find -name matching a directory that holds .env, -exec grep -r, denied" \
    "find . -name '*.py' -exec grep -rn foo {} +"
expect_in "$pt/fn" ALLOW "find -name under a clean subdirectory allowed" "find src -name '*.py' | xargs grep -n foo"
# find tests each starting point against -name too: a root its own glob matches is handed over whole.
mkdir -p "$pt/fx/deep/inner"
: >"$pt/fx/deep/inner/server.pem"
expect_in "$pt/fx" DENY "find of a root its -name matches, -exec grep -r, denied" \
    "find deep -name deep -exec grep -rn KEY {} +"
expect_in "$pt/fx" DENY "find of a root with a / its -iname matches denied" \
    "find deep/ -iname DEEP -exec grep -rn KEY {} +"
expect_in "$pt/fx/deep" DENY "find . -maxdepth 0 -name . denied" "find . -maxdepth 0 -name . -exec grep -rn KEY {} +"
expect_in "$pt/fx/deep" DENY "find . -name '?' matches the root ., denied" "find . -name '?' -exec grep -rn KEY {} +"
expect_in "$pt/fx" DENY "a -name matching one of two roots denied" "find src deep -name deep -exec grep -rn KEY {} +"
expect_in "$pt/fx" ALLOW "with -mindepth 1 the root is not tested, allowed" \
    "find deep -mindepth 1 -name deep -exec grep -rn KEY {} +"
expect_in "$P" DENY  "xargs sed -i may still print through w /dev/stdout, denied" \
    "grep -rl foo . | xargs sed -i '' s/a/b/"
expect_in "$P" DENY  "find -exec sed -n p prints the files, denied"               'find . -exec sed -n p {} +'
expect_in "$P" DENY  "a find primary after -exec's end is no sed option, denied"  'find . -exec sed -n p {} \; -print'
expect_in "$P" DENY  "sed -i with w /dev/stdout prints the files, denied" \
    "find . -type f -exec sed -i '' -n 'w /dev/stdout' {} +"
expect_in "$P/src" ASK "a find -exec operand built on {} that may leave find's roots asks" \
    'find . -maxdepth 0 -exec grep -rn KEY {}/.. \;'
mkdir -p "$pt/qq/a/b/c"
: >"$pt/qq/a/b/c/.env"
expect_in "$pt/qq" DENY "a directory glob piped into xargs grep -r is probed, denied" \
    'echo */* | xargs grep -rn KEY /dev/null'
expect_in "$pt/qq" DENY "a bare wildcard piped into xargs grep -r is probed, denied" \
    'echo * | xargs grep -rn KEY /dev/null'
expect_in "$P" DENY  "a numbered fd redirection is not rg's stdin, denied"       'rg KEY 10< src/a.py'

# A recursive reader after xargs takes its operands from its input: its working directory is always probed, and so is
# a directory an earlier stage names outside it.
mkdir -p "$pt/xg/docs.md" "$pt/xg/sub/deep" "$pt/xr/src"
: >"$pt/xg/docs.md/.env"
: >"$pt/xg/sub/deep/.env"
git -C "$pt/xr" init -q
printf '.env\n' >"$pt/xr/.gitignore"
: >"$pt/xr/.env"
: >"$pt/xr/src/a.py"
git -C "$pt/xr" add .gitignore src/a.py
XG="$pt/xg"
XR="$pt/xr"
expect_in "$XG" DENY "a partial glob piped into xargs grep -r, denied"      'echo *.md | xargs grep -rn KEY /dev/null'
expect_in "$XG" DENY "a ? glob piped into xargs grep -r, denied"            'echo su? | xargs grep -rn KEY /dev/null'
expect_in "$XG" DENY "a bracket glob piped into xargs grep -r, denied"      'echo [s]ub | xargs grep -rn KEY /dev/null'
expect_in "$XG" DENY "a literal directory piped into xargs grep -r, denied" 'echo sub | xargs grep -rn KEY /dev/null'
expect_in "$XG" DENY "a dot piped into xargs grep -r, denied"               'echo . | xargs grep -rn KEY /dev/null'
expect_in "$XG" DENY "a name piped into xargs rg, denied"                   'echo docs.md | xargs rg KEY /dev/null'
expect_in "$P/src" DENY "a directory outside the cwd piped into xargs grep -r, denied" \
    "echo $pt/ns | xargs grep -rn KEY /dev/null"
expect_in "$XG" ALLOW "echo * into xargs ls stays allowed"                        'echo * | xargs ls'
expect_in "$XG" ALLOW "echo */* into xargs wc stays allowed"                      'echo */* | xargs wc -l'
expect_in "$XG" ALLOW "ls * into head stays allowed"                              'ls * | head'
expect_in "$XR" ALLOW "git ls-files into a non-recursive xargs grep allowed"      'git ls-files | xargs grep -n foo'
expect_in "$XR" ALLOW "git ls-files into xargs rg honours .gitignore, allowed"    'git ls-files | xargs rg foo'
expect_in "$P/src" DENY "a reader inside find -exec reads its own root too, denied" \
    'find . -maxdepth 0 -exec grep -rn KEY .. \;'
expect_in "$P/src" ALLOW "a reader inside find -exec given only {} allowed"       'find . -exec grep -rn KEY {} \;'
s300=$(printf '/%.0s' {1..300})
expect_in "$P/src" ASK "a path of more than 256 slashes piped into xargs grep -r is not resolved, asks" \
    "echo ${s300}$P/doc | xargs grep -rn KEY"

# A replacement string stands for a name from the input: the directory before it is probed.
mkdir -p "$pt/xi/cw" "$pt/xi/tgt/sub" "$pt/xi/cln/sub"
: >"$pt/xi/tgt/sub/.env"
: >"$pt/xi/cln/sub/a.txt"
XI="$pt/xi"
expect_in "$XI/cw" DENY "an xargs -I operand under a directory outside the cwd is probed, denied" \
    "echo sub | xargs -I{} grep -rn KEY $XI/tgt/{}"
expect_in "$XI/cw" DENY "a relative xargs -I operand outside the cwd is probed, denied" \
    'echo sub | xargs -I{} grep -rn KEY ../tgt/{}'
expect_in "$XI/cw" DENY "an xargs -I with a separate value, denied"  'echo sub | xargs -I % grep -rn KEY ../tgt/%'
expect_in "$XI/cw" DENY "xargs -i replaces {}, denied"               'echo sub | xargs -i grep -rn KEY ../tgt/{}'
expect_in "$XI/cw" DENY "xargs --replace replaces {}, denied"        'echo sub | xargs --replace grep -rn KEY ../tgt/{}'
expect_in "$XI/cw" DENY "a bundled xargs -0I, denied"                'echo sub | xargs -0I@ grep -rn KEY ../tgt/@'
expect_in "$XI/cw" DENY "a parallel replacement string outside the cwd, denied" \
    'parallel grep -rn KEY ../tgt/{} ::: sub'
expect_in "$XI/cw" ALLOW "an xargs -I operand under a clean directory allowed" \
    'echo sub | xargs -I{} grep -rn KEY ../cln/{}'
expect_in "$XI/cw" DENY "an xargs -I operand at the root is too wide, denied" 'echo tmp | xargs -I{} grep -rn KEY /{}'
expect_in "$XI/cw" ASK "a .. after the replacement string may climb past the cwd, asks" \
    'echo a/b | xargs -I{} grep -rn KEY {}/../..'
expect_in "$XI/cw" ASK "text beside the replacement string may spell .., asks"  'echo . | xargs -I{} grep -rn KEY {}.'
mkdir -p "$pt/xj/cw" "$pt/xi/tgt/sub/x"
expect_in "$pt/xj/cw" ASK "an input holding .. under another directory may climb past it, asks" \
    "echo .. | xargs -I{} grep -rn KEY $XI/tgt/sub/x/{}"
expect_in "$XI/cw" ASK "a parallel replacement string other than {} asks"     'parallel grep -rn KEY {.} ::: x'
expect_in "$XI/cw" ASK "a dot glob may match .. in bash, asks"                  'echo .? | xargs grep -rn KEY'
expect_in "$XI/cw" DENY "xargs -I running the command its input names denied" 'echo sh | xargs -I% % -c id'
expect_in "$XI/cw" DENY "parallel running the command its input names denied"  'parallel {} ::: id'

# A recursive reader after xargs reads paths its input names: only an earlier stage whose output the hook models
# (its own words, or a listing) leaves the probe to decide; any other, or an argument file, asks.
mkdir -p "$pt/rp/src"
git -C "$pt/rp" init -q
: >"$pt/rp/.env"
: >"$pt/rp/src/a.py"
RP="$pt/rp/src"
expect_in "$RP" ASK "a path git prints at run time, piped into xargs grep -r, asks" \
    'git rev-parse --show-toplevel | xargs grep -rn KEY'
expect_in "$RP" ASK "xargs -a reads its arguments from a file, asks"            'xargs -a list grep -rn KEY'
expect_in "$RP" ASK "xargs --arg-file reads its arguments from a file, asks"    'xargs --arg-file=list grep -rn KEY'
expect_in "$RP" ASK "xargs fed by an input redirection asks"                    'xargs grep -rn KEY < list'
expect_in "$RP" ASK "a list cat prints, piped into xargs grep -r, asks"         'cat list | xargs grep -rn KEY'
expect_in "$RP" ASK "a variable printenv prints, piped into xargs grep -r, asks" 'printenv HOME | xargs grep -rn KEY'
expect_in "$RP" ASK "parallel :::: reads its arguments from a file, asks"       'parallel grep -rn KEY :::: list'
expect_in "$RP" ASK "sort of a file operand reads a list, asks"                 'sort list | xargs grep -rn KEY'
expect_in "$RP" ASK "sort fed by an input redirection reads a list, asks"       'sort < list | xargs grep -rn KEY'
expect_in "$RP" ASK "a printf conversion other than %s asks"                    "printf '%b ' x | xargs grep -rn KEY"
expect_in "$RP" ASK "an echo of an escape asks"                                 "echo '\\x2e\\x2e' | xargs grep -rn KEY"
expect_in "$RP" ASK "an echo of a brace expansion asks"                         'echo {.,x}. | xargs grep -rn KEY'
expect_in "$RP" ASK "ls -a lists .., asks"                                      'ls -a | xargs grep -rn KEY'
expect_in "$RP" ASK "ls -l prints link targets, asks"                           'ls -l | xargs grep -rn KEY'
expect_in "$RP" ASK "find -exec prints what it runs, asks" 'find . -exec echo {} \; | xargs grep -rn KEY'
expect_in "$RP" ASK "git ls-files of a top pathspec prints ../ paths, asks"     'git ls-files :/ | xargs grep -rn KEY'
expect_in "$RP" ASK "a grep -o filter prints parts of names, asks" 'git ls-files | grep -o x | xargs grep -rn KEY'
expect_in "$RP" ASK "tr rewrites names, asks"                     'git ls-files | tr a b | xargs grep -rn KEY'
expect_in "$XR" ALLOW "names through sort into xargs rg allowed"  'git ls-files | sort | xargs rg foo'
expect_in "$XR" ALLOW "names through grep -v into xargs rg allowed" 'git ls-files | grep -v test | xargs rg foo'
expect_in "$XR" ALLOW "names through head -n into xargs rg allowed" 'git ls-files | head -n 5 | xargs rg foo'
expect_in "$XR" ALLOW "names through uniq and tail into xargs rg allowed" \
    'git ls-files | uniq | tail -3 | xargs rg foo'
expect_in "$XR" ALLOW "printf of %s into xargs rg allowed"                      "printf '%s ' src | xargs rg foo"
expect_in "$XR" ALLOW "a names-only grep into xargs rg allowed"                 'grep -rl foo src | xargs rg foo'
expect_in "$XR" ALLOW "git diff --name-only into xargs rg allowed"              'git diff --name-only | xargs rg foo'
expect_in "$XR" ALLOW "find into xargs rg allowed"                              "find src -name '*.py' | xargs rg foo"
expect_in "$XR" ALLOW "ls into xargs rg allowed"                                'ls src | xargs rg foo'
expect_in "$XR" ALLOW "fd into xargs rg allowed"                                'fd py | xargs rg foo'
expect_in "$XR" ALLOW "a non-recursive reader after any stage is unchanged, allowed" 'cat list | xargs grep -n foo'
expect_in "$P" DENY  "an asking stage still loses to the probe's deny"          'cat list | xargs grep -rn KEY'

# grep -r follows a symlink it is given on the command line: through xargs, or as a match of a wildcard.
mkdir -p "$pt/lk"
ln -s "$pt/sec" "$pt/lk/l"
expect_in "$pt/lroot" DENY "a link in the cwd fed through xargs to grep -r is followed, denied" \
    'echo s | xargs grep -rn KEY'
expect_in "$pt/lroot" DENY "grep -r of * follows a link it matches, denied"     'grep -r KEY *'
expect_in "$P/src" DENY "a glob outside the cwd matching a link, fed through xargs to grep -r, denied" \
    "echo $pt/lk/l* | xargs grep -rn KEY"
expect_in "$P/src" DENY "find outside the cwd lists a link xargs grep -r follows, denied" \
    "find $pt/lk | xargs grep -rn KEY"
expect_in "$pt/lroot" ALLOW "rg does not follow a link without -L, allowed"     'echo s | xargs rg KEY'
expect DENY "a ** word in a parallel stage is a command string, denied"        'echo x | parallel echo a/**/b'

# A producer's attached option value can name where it lists, or what it prints; a pattern followed by .. climbs out.
B="$pt/r5"
mkdir -p "$B/cw" "$B/tgt/sub" "$B/p/cw/d"
: >"$B/tgt/sub/.env"
: >"$B/p/.env"
expect_in "$B/cw" DENY "fd --search-path= names a root outside the cwd, denied" \
    "fd --search-path=$B/tgt | xargs grep -rn KEY"
expect_in "$B/cw" DENY "fd --base-directory= names a root outside the cwd, denied" \
    "fd -a --base-directory=$B/tgt | xargs grep -rn KEY"
expect_in "$B/cw" ASK "an fd long option with a value the hook does not model asks" \
    'fd --path-separator=x | xargs grep -rn KEY'
expect_in "$B/cw" ASK "a names-only grep --label prints any name, asks" \
    "echo KEY | grep -l --label=$B/tgt/sub KEY | xargs grep -rn KEY"
expect_in "$B/cw" ASK "a names-only rg --path-separator rewrites names, asks" \
    'rg -l --path-separator=x KEY | xargs grep -rn KEY'
expect_in "$B/cw" ALLOW "a names-only grep with a narrowing long option allowed" \
    'grep -rl --include=*.py KEY . | xargs grep -rn KEY'
expect_in "$B/p/cw" ASK "a pattern followed by .. may climb out, asks"   'echo */../.. | xargs grep -rn KEY'
expect_in "$B/p/cw" ASK "ls -d of a pattern followed by .. asks"         'ls -d */../.. | xargs grep -rn KEY'
expect_in "$B/p/cw" DENY "a literal path followed by .. is resolved, denied" 'echo d/../.. | xargs grep -rn KEY'
# Before bash 5.2, a component starting with . and holding a pattern character (..*, .?, .a*) can match ..
mkdir -p "$B/p/cw/.github"
: >"$B/p/cw/.github/ci.yml"
: >"$B/p/cw/.gitignore"
expect_in "$B/p/cw" ASK "a ..* pattern may match .., asks"                'echo ..* | xargs grep -rn KEY'
expect_in "$B/p/cw" ASK "..* components after a pattern may match .., asks" 'echo */..*/..* | xargs grep -rn KEY'
expect_in "$B/p/cw" ASK "a ..* component under a directory may match .., asks" 'echo d/..* | xargs grep -rn KEY'
expect_in "$B/p/cw" ASK "an fd --search-path= of ..* may match .., asks"  'fd --search-path=..* | xargs grep -rn KEY'
expect_in "$B/p/cw" ALLOW "cat of a dot file is unaffected, allowed"      'cat .gitignore'
expect_in "$B/p/cw" ALLOW "a pattern under a dot directory is unaffected, allowed" 'ls .github/*'
expect_in "$B/p/cw" ALLOW "a pattern under a dot directory into xargs grep -r allowed" \
    'ls .github/* | xargs grep -rn KEY'

# cd or pushd into a secret directory makes a later reader's operand relative and bare, so it is denied.
expect DENY  "cd ~/.aws denied"                                          'cd ~/.aws'
expect DENY  "pushd secrets denied"                                      'pushd secrets'
expect DENY  "cd into the vault variable denied"                         'cd $CLAUDE_SECRET_DIR'
expect DENY  "cd into the literal vault denied"                          'cd /tmp/claude-abc-vault/secrets'
expect DENY  "cd ~/.ssh denied"                                          'cd ~/.ssh'
expect DENY  "cd -- ~/.kube denied"                                      'cd -- ~/.kube'
expect DENY  "cd -P ~/.aws denied"                                       'cd -P ~/.aws'
expect DENY  "builtin cd ~/.aws denied"                                  'builtin cd ~/.aws'
expect_in "$pt/aws/.aws/sub" DENY "a cd whose relative target resolves into a secret directory denied" 'cd ..'
expect ALLOW "cd src allowed"                                            'cd src'
expect ALLOW "cd /tmp allowed"                                           'cd /tmp'
expect ALLOW "cd ~ allowed"                                              'cd ~'
expect ALLOW "a bare cd allowed"                                         'cd'
expect ALLOW "cd - allowed"                                              'cd -'
expect ALLOW "pushd +1 allowed"                                          'pushd +1'
expect ALLOW "cd .. allowed"                                             'cd ..'
expect ALLOW "cd as data allowed"                                        'echo cd ~/.aws'
# The cd forms a shell resolves past the written word: wrappers, options, links, variables, patterns, CDPATH, zsh's
# two-operand substitution. A target the hook cannot resolve asks.
mkdir -p "$pt/cdl" "$pt/aws/.awz"
ln -s "$pt/aws/.aws" "$pt/cdl/l"
ln -s "$pt/aws/.aws/sub" "$pt/cdl/m"
expect_in "$pt/cdl" DENY "a .. after a link, resolved physically, denied" 'cd -P m/..'
expect DENY  "command cd ~/.aws denied"                                  'command cd ~/.aws'
expect DENY  "pushd -n ~/.aws denied"                                    'pushd -n ~/.aws'
expect DENY  "cd after a pipe denied"                                    'true | cd ~/.aws'
expect DENY  "cd after an assignment denied"                             'X=1 cd ~/.aws'
expect DENY  "a word that is no cd option is a target, denied"           'cd -x/../.aws'
expect_in "$pt/cdl" DENY "cd into a link to a secret directory denied"  'cd l'
expect_in "$pt/aws" DENY "cd into a subdirectory of a secret directory denied" 'cd .aws/sub'
expect_in "$pt/cdl" DENY "cd into a subdirectory through a link denied" 'cd l/sub'
expect_in "$pt/aws/.awz" DENY "zsh's two-operand cd, substituted into the cwd, denied" 'cd .awz .aws'
expect ASK   "cd into an unresolved variable asks"                       'cd $SOMEDIR'
expect ASK   "cd into a glob asks"                                       'cd ~/.aw*'
expect ASK   "cd into a brace expansion asks"                            'cd ~/.{x,aws}'
expect ASK   "cd into another user's home asks"                          'cd ~root'
expect ASK   "cd with CDPATH set in the command asks"                    'CDPATH=~/.config cd gh'
expect ASK   "a relative cd after an earlier cd asks"                    'cd /tmp ; cd foo'
expect ALLOW "cd \$HOME allowed"                                         'cd "$HOME"'
expect ALLOW "cd -P /tmp allowed"                                        'cd -P /tmp'
expect ALLOW "a ./ cd with CDPATH set allowed"                           'CDPATH=/x cd ./src'
expect ASK   "cd after an export of CDPATH asks"                         'export CDPATH | cd gh'
expect ALLOW "cd beside a mere mention of CDPATH allowed"                'echo CDPATH | cd gh'
# The session's temp directory and $PWD resolve, so a cd there is screened like any other.
expect_sid abc-123 ALLOW "cd into the session temp directory allowed"   'cd $CLAUDE_TEMP_DIR'
expect_sid abc-123 ALLOW "cd below the session temp directory allowed"  'cd "${CLAUDE_TEMP_DIR}/x"'
expect_sid abc-123 ALLOW "cd \$PWD allowed"                              'cd "$PWD"'
expect_sid abc-123 DENY  "cd into secrets below the session temp directory denied" 'cd "$CLAUDE_TEMP_DIR/secrets"'
RUN_SID=abc-123 expect_in "$pt/aws/.aws/sub" DENY "cd from \$PWD into a secret directory denied" 'cd "$PWD/.."'
expect_sid 'a/../b' ASK  "a session id that is not plain asks"          'cd $CLAUDE_TEMP_DIR'
expect ASK   "cd into the session temp directory with no session id asks" 'cd $CLAUDE_TEMP_DIR'
expect ASK   "cd \$OLDPWD asks"                                          'cd "$OLDPWD"'
# Only the real podman and proc credential locations count, and a directory above a literal one is secret too.
expect ALLOW "cd src/containers allowed"                                 'cd src/containers'
expect ALLOW "cd src/containers/Foo allowed"                             'cd src/containers/Foo'
expect ALLOW "cd src/proc/handlers allowed"                              'cd src/proc/handlers'
expect DENY  "cd ~/.config/containers denied"                            'cd ~/.config/containers'
expect DENY  "cd /proc/1 denied"                                         'cd /proc/1'
expect DENY  "cd ~/.config, above gh/hosts.yml, denied"                  'cd ~/.config'
expect ALLOW "cd below ~/.config, beside gh, allowed"                    'cd ~/.config/nvim'
expect DENY  "cd below a /proc entry denied"                             'cd /proc/1/task'
expect DENY  "cd /proc/thread-self denied"                               'cd /proc/thread-self'
expect ALLOW "cd /etc allowed"                                           'cd /etc'
expect ALLOW "cd /opt/homebrew/etc allowed"                              'cd /opt/homebrew/etc'
expect DENY  "cat /proc/thread-self/environ denied"                      'cat /proc/thread-self/environ'
expect DENY  "cat /proc/self/task/1/environ denied"                      'cat /proc/self/task/1/environ'
expect DENY  "cat /proc/thread-self/task/1/environ denied"               'cat /proc/thread-self/task/1/environ'
# $PWD, $CLAUDE_TEMP_DIR and $HOME resolve only while the command itself cannot have changed them: no earlier cd,
# pushd or popd for $PWD, and no assignment, export or declaration of the name.
mkdir -p "$pt/aws/.config/nvim"
expect_sid abc-123 ASK "\$PWD after an earlier cd asks" "cd $pt/aws/.config/nvim ; cd \"\$PWD/..\""
expect_sid abc-123 ASK "\$PWD after a popd asks"                         'popd ; cd "$PWD"'
expect_sid abc-123 ASK "\$PWD the command assigns asks"                  "PWD=$pt/aws/.aws ; cd \"\$PWD\""
expect_sid abc-123 ASK "\$PWD the command reads asks"                    'read PWD | cd "$PWD"'
expect_sid abc-123 ASK "\$CLAUDE_TEMP_DIR the command assigns asks" \
    "CLAUDE_TEMP_DIR=$pt/aws/.aws ; cd \"\$CLAUDE_TEMP_DIR\""
expect_sid abc-123 ASK "\$CLAUDE_TEMP_DIR the command exports asks" \
    "export CLAUDE_TEMP_DIR=$pt/aws/.aws ; cd \$CLAUDE_TEMP_DIR"
expect_sid abc-123 ASK "\$CLAUDE_TEMP_DIR set by printf -v asks" \
    'printf -v CLAUDE_TEMP_DIR x | cd $CLAUDE_TEMP_DIR'
expect ASK   "a bare cd after HOME is assigned asks"                     "HOME=$pt/aws/.aws ; cd"
expect ASK   "cd \$HOME after HOME is assigned asks"                     "HOME=$pt/aws/.aws ; cd \"\$HOME\""
expect ASK   "cd ~ after HOME is exported asks"                          "export HOME=$pt/aws/.aws ; cd ~"
expect DENY  "cd ~/.aws after HOME is assigned denied"                   "HOME=$pt/aws ; cd ~/.aws"
expect_sid abc-123 ALLOW "cd \$PWD beside \$OLDPWD allowed"              'echo $OLDPWD | cd "$PWD"'
# An expansion that may assign (${NAME:=…}, zsh's ${(P)…}) or a builtin writing a computed name counts as naming it.
expect_sid abc-123 ASK "\$PWD after \${PWD:=…} asks"                    'echo ${PWD:=/x} ; cd "$PWD"'
expect ASK   "cd ~ after \${HOME=…} asks"                                'echo ${HOME=/x} ; cd ~'
expect_sid abc-123 ASK "\$CLAUDE_TEMP_DIR after \${CLAUDE_TEMP_DIR::=…} asks" \
    'echo ${CLAUDE_TEMP_DIR::=/x} ; cd $CLAUDE_TEMP_DIR'
expect_sid abc-123 ASK "\$PWD after zsh's \${(P)…} asks"                 'echo ${(P)n::=/x} ; cd "$PWD"'
expect_sid abc-123 ASK "\$PWD after a read into a variable name asks"    'n=PWD ; read "$n" <<< /x ; cd "$PWD"'
expect_sid abc-123 ASK "\$PWD after a read into a computed name asks"    'n=P ; read "${n}WD" <<< /x ; cd "$PWD"'
expect_sid abc-123 ASK "\$PWD after a nameref asks"                      'declare -n r="$n" ; r=/x ; cd "$PWD"'
expect_sid abc-123 ALLOW "\$PWD beside \${PWD/…} allowed"                'echo ${PWD/a/b} | cd "$PWD"'
expect_sid abc-123 ALLOW "\$PWD beside an export of a \$ value allowed"  'export X=$Y | cd "$PWD"'
# bash's cd - reads a temporary OLDPWD; zsh's chdir is cd.
expect ASK   "cd - with OLDPWD set in its prefix asks"                   'OLDPWD=~/.aws cd -'
expect ASK   "cd - with OLDPWD set to an ssh directory asks"             'OLDPWD=/tmp/x/.ssh cd -'
expect DENY  "chdir ~/.aws denied"                                       'chdir ~/.aws'
expect ALLOW "chdir src allowed"                                         'chdir src'
# After a sequence separator (; && || & newline) an earlier command may have changed $PWD, $HOME or
# $CLAUDE_TEMP_DIR in ways the hook does not model, so a target built on one asks; a pipe's stages are subshells.
expect_sid abc-123 ASK "\$PWD after a separator asks"                    'cd /tmp ; cd "$PWD"'
expect ASK   "cd ~ after a separator asks"                               'true ; cd ~'
expect_sid abc-123 ASK "\$CLAUDE_TEMP_DIR after && asks"                 'true && cd $CLAUDE_TEMP_DIR/x'
expect ASK   "a bare cd after a separator asks"                          'exec {HOME}>/dev/null ; cd'
expect ASK   "cd - after a separator asks"                               'true ; cd -'
expect_sid abc-123 ALLOW "cd \$PWD/src alone allowed"                    'cd "$PWD/src"'
expect_sid abc-123 ALLOW "cd \$CLAUDE_TEMP_DIR/x alone allowed"          'cd $CLAUDE_TEMP_DIR/x'
expect_sid abc-123 ALLOW "cd \$PWD after a pipe allowed"                 'true | cd "$PWD"'
expect ALLOW "cd ~ beside a mention of \$HOME allowed"                   'echo $HOME | cd ~'

# More fetch forms: each is denied bare and allowed into the vault.
fetches2=(
    'ansible-vault view secrets.yml'
    'terraform output -raw db_password'
    'terraform output -json'
    'terraform output --raw=true x'
    'terraform -chdir=infra output -json'
    'terraform show -json'
    'terraform state pull'
    'npm config get //registry.npmjs.org/:_authToken'
    'doppler secrets get API_KEY --plain'
    'doppler secrets download --no-file'
    'doppler secrets'
    'doppler secrets --project p --config c'
    'heroku config:get DATABASE_URL'
    'heroku config'
    'heroku config --app x'
    'launchctl getenv GITHUB_TOKEN'
    'aws-vault export prod'
    'aws-vault exec prod --json'
)
for f in "${fetches2[@]}"; do
    expect DENY  "fetch denied: $f"                                      "$f"
    expect ALLOW "fetch into the vault allowed: $f"                      "$f > \$CLAUDE_SECRET_DIR/x"
done
expect DENY  "a fetch ending at its options, piped on, denied"           'doppler secrets | cat'
expect DENY  "a fetch ending at its options, stderr kept, denied"        'heroku config 2>&1'
expect ALLOW "terraform output with no format allowed"                   'terraform output'
expect ALLOW "terraform state list allowed"                              'terraform state list'
expect ALLOW "terraform show of a plan allowed"                          'terraform show plan.out'
expect ALLOW "npm config get of a non-secret key allowed"                'npm config get registry'
expect ALLOW "doppler secrets set allowed"                               'doppler secrets set X=1'
expect ALLOW "heroku config:set allowed"                                 'heroku config:set X=1'
expect ALLOW "launchctl getenv of PATH allowed"                          'launchctl getenv PATH'
expect ALLOW "aws-vault exec of a plain command allowed"                 'aws-vault exec prod -- ls'
expect DENY  "ansible-vault decrypt denied"                              'ansible-vault decrypt x.yml'
expect DENY  "ansible-vault decrypt into the vault still denied" \
    'ansible-vault decrypt x.yml --output $CLAUDE_SECRET_DIR/x'
# A quoted |, ; or & is no stage boundary, so it cannot hide an aws fetch form.
expect DENY  "an aws fetch with a quoted pipe before the operation denied" \
    "aws secretsmanager --query 'a|b' get-secret-value --secret-id x"
expect DENY  "an aws fetch with a global option and a quoted pipe denied" \
    "aws --no-cli-pager secretsmanager --query 'a|b' get-secret-value"
expect DENY  "an aws fetch with a quoted ; and & denied" \
    "aws ssm --query 'a;b&c' get-parameter --name x --with-decryption"
expect ALLOW "a quoted pipe in a non-fetch allowed"                      "aws secretsmanager --query 'a|b' list-secrets"
# A registry login may store its credentials only in the vault, or at its default location.
expect DENY  "podman login --authfile outside the vault denied" \
    'podman login --authfile /tmp/x --password-stdin r'
expect DENY  "podman login --authfile= outside the vault denied"         'podman login --authfile=/tmp/x r'
expect DENY  "REGISTRY_AUTH_FILE outside the vault denied"               'REGISTRY_AUTH_FILE=/tmp/x podman login r'
expect DENY  "helm registry login --registry-config outside the vault denied" \
    'helm registry login --registry-config /tmp/x r'
expect DENY  "docker --config outside the vault denied"                  'docker --config /tmp/d login r'
expect DENY  "DOCKER_CONFIG outside the vault denied"                    'DOCKER_CONFIG=/tmp/d docker login r'
expect ALLOW "podman login --authfile into the vault allowed" \
    'podman login --authfile $CLAUDE_SECRET_DIR/auth.json --password-stdin r'
expect ALLOW "DOCKER_CONFIG into the vault allowed" \
    'DOCKER_CONFIG=$CLAUDE_SECRET_DIR/d docker login r'
expect ALLOW "a docker login at its default location allowed"            'docker login r'
expect ALLOW "docker --config with no login allowed"                     'docker --config /tmp/d ps'
# compose config prints the project's configuration with its .env interpolated, unless names-only or uninterpolated.
expect DENY  "docker compose config denied"                              'docker compose config'
expect DENY  "docker compose --env-file .env config denied"              'docker compose --env-file .env config'
expect DENY  "docker compose config --no-interpolate alone denied"       'docker compose config --no-interpolate'
expect DENY  "docker compose config --environment denied"                'docker compose config --environment'
expect DENY  "uninterpolated compose config with --variables denied" \
    'docker compose config --no-interpolate --no-env-resolution --variables'
expect DENY  "compose config --services -o denied"                       'docker compose config --services -o x.yml'
expect DENY  "docker-compose config denied"                              'docker-compose config'
expect DENY  "podman compose config denied"                              'podman compose config'
expect DENY  "compose config --format json denied"                       'docker compose config --format json'
expect ALLOW "docker compose config --services allowed"                  'docker compose config --services'
expect ALLOW "docker compose -f a.yml config -q allowed"                 'docker compose -f a.yml config -q'
expect ALLOW "compose config --images --format json allowed"             'docker compose config --images --format json'
expect ALLOW "uninterpolated compose config allowed" \
    'docker compose config --no-interpolate --no-env-resolution'
expect ALLOW "docker compose up allowed"                                 'docker compose up -d'

# The same tools' other spellings: a named terraform output is printed unredacted, TF_CLI_ARGS adds flags or names, a
# case-insensitive file system runs TERRAFORM as terraform, and the CLIs take options before their subcommands.
fetches3=(
    'terraform output db_password'
    'terraform output -no-color db_password'
    'terraform output 2>&1 db_password'
    'TERRAFORM output -json'
    'TF_CLI_ARGS_output=-json terraform output'
    'npm get //registry.npmjs.org/:_authToken'
    'npm config get --json //r/:_authToken'
    'pnpm config get _authToken'
    'doppler --project p secrets'
    'doppler secrets --project p get K'
    'doppler secrets substitute tpl.txt'
    'doppler secrets upload x.json'
    'doppler secrets delete X -y'
    'heroku config get DATABASE_URL'
    'heroku auth:token'
    'heroku pg:credentials:url DATABASE'
    'heroku config:edit'
    'launchctl getenv github_token'
    'launchctl getenv $NAME'
    'launchctl export'
    'aws-vault login prod --stdout'
    'aws-vault exec prod'
    'aws-vault exec --duration 1h prod --'
)
for f in "${fetches3[@]}"; do
    expect DENY  "fetch denied: $f"                                      "$f"
    expect ALLOW "fetch into the vault allowed: $f"                      "$f > \$CLAUDE_SECRET_DIR/x"
done
expect ALLOW "terraform output into a plain file allowed"                'terraform output > out.txt'
expect DENY  "aws-vault exec of env denied"                              'aws-vault exec prod -- env'
expect ALLOW "aws-vault exec of an aws command allowed"                  'aws-vault exec prod -- aws s3 ls'
expect DENY  "ansible-vault edit denied"                                 'ansible-vault edit x.yml'
expect DENY  "an aws fetch with an escaped pipe denied" \
    'aws secretsmanager --query a\|b get-secret-value'
expect DENY  "an aws fetch split by quotes and a quoted pipe denied" \
    "aws secrets\"manager\" --query 'a|b' get-secret-value"
expect DENY  "an aws fetch with a double-quoted pipe denied" \
    'aws ssm --query "a|b" get-parameter --name x --with-decryption'
expect DENY  "an aws fetch with an ANSI-C quoted pipe denied" \
    "aws secretsmanager --query \$'a|b' get-secret-value"
expect DENY  "podman login --compat-auth-file outside the vault denied"  'podman login --compat-auth-file /tmp/x r'
expect DENY  "HELM_REGISTRY_CONFIG outside the vault denied" \
    'HELM_REGISTRY_CONFIG=/tmp/x helm registry login r'
expect DENY  "XDG_RUNTIME_DIR outside the vault denied"                  'XDG_RUNTIME_DIR=/tmp/x podman login r'
expect DENY  "DOCKER_CONFIG exported before the login denied"            'export DOCKER_CONFIG=/tmp/d ; docker login r'
expect DENY  "DOCKER_CONFIG appended to denied"                          'DOCKER_CONFIG+=/d docker login r'
expect DENY  "a vault path built on a reassigned vault variable denied" \
    'CLAUDE_SECRET_DIR=/tmp/z DOCKER_CONFIG=$CLAUDE_SECRET_DIR/d docker login r'
expect DENY  "a vault path with a .. segment denied" \
    'DOCKER_CONFIG=$CLAUDE_SECRET_DIR/../d docker login r'
expect DENY  "docker --config= outside the vault denied"                 'docker --config=/tmp/d login r'
expect DENY  "DOCKER_CONFIG behind sudo denied"                          'sudo DOCKER_CONFIG=/tmp/d docker login r'
expect DENY  "DOCKER_CONFIG behind env denied"                           'env DOCKER_CONFIG=/tmp/d docker login r'
expect DENY  "skopeo login --authfile outside the vault denied"          'skopeo login --authfile /tmp/x r'
expect ALLOW "docker --config into the vault allowed"                    'docker --config $CLAUDE_SECRET_DIR/d login r'
expect ALLOW "DOCKER_CONFIG exported before a non-login allowed"         'export DOCKER_CONFIG=/tmp/d ; docker ps'
expect DENY  "docker compose convert denied"                             'docker compose convert'
expect DENY  "docker compose config of a service denied"                 'docker compose config svc'
expect DENY  "docker-compose -p config denied"                           'docker-compose -p p config'
expect DENY  "a bundled -o after uninterpolated compose config denied" \
    'docker compose config --no-interpolate --no-env-resolution -qo x.yml'
expect DENY  "nerdctl compose config denied"                             'nerdctl compose config'
expect DENY  "compose config behind sudo denied"                         'sudo docker compose config'
expect DENY  "a quoted compose config denied"                            "docker 'compose' config"
expect DENY  "upper-case DOCKER compose config denied"                   'DOCKER compose config'
expect ALLOW "compose --profile config --services allowed"               'docker compose --profile p config --services'
expect ALLOW "docker-compose -p config --services allowed"               'docker-compose -p p config --services'
# aws-vault exec -j prints the credential JSON and -s or --*-server serves the credentials on a local endpoint, in a
# short bundle or after the profile; an option after -- belongs to the command.
for f in 'aws-vault exec -j prod -- true' 'aws-vault exec prod -j -- true' 'aws-vault exec -nj prod -- true' \
        'aws-vault exec -s prod -- true' 'aws-vault exec --server prod -- true' \
        'aws-vault exec --ec2-server prod -- true' 'aws-vault exec --ecs-server prod -- true'; do
    expect DENY  "aws-vault credential output denied: $f"                "$f"
done
expect ALLOW "an option of the command aws-vault runs allowed"          'aws-vault exec prod -- ls -s'
expect ALLOW "doppler run of a command allowed"                          'doppler run -- npm test'
# terraform output takes one name, so prose naming the command and a later line are no named output.
expect ALLOW "a commit message naming terraform output allowed" \
    'git commit -m "Expose the terraform output for the vpc id"'
expect ALLOW "terraform output on a line before another command allowed" $'terraform output\nterraform plan'
expect DENY  "terraform output of a name after -state denied"           'terraform output -state x.tfstate db_password'
# bash deletes a backslash-newline before it splits words, so a continuation joins a form's words.
for f in $'terraform output \\\n-json' $'terraform \\\noutput -json' $'terraform -chdir=infra \\\noutput -json' \
        $'terraform output \\\n-raw x' $'terraform \\\nshow -json' $'terraform state \\\npull' \
        $'terraform output \\\ndb_password' $'TF_CLI_ARGS=-json terraform \\\noutput' \
        $'aws secretsmanager\\\n get-secret-value'; do
    expect DENY  "a fetch across a line continuation denied: ${f//$'\n'/\\n}" "$f"
done
# A comment does not continue across a backslash-newline, so the command as written is matched too.
expect DENY  "terraform output -json after a comment ending in a backslash denied" $'#a\\\nterraform output -json'
expect DENY  "terraform show -json after a comment ending in a backslash denied"   $'#a\\\nterraform show -json'
# A fetch into the vault is one line: a fetch in a command holding a newline is denied, whatever marker it shows.
expect DENY  "a fetch into a vault path split by a continuation denied" \
    $'terraform output -json > $CLAUDE_SECRET\\\n_DIR/x'
expect DENY  "a fetch after a comment naming the vault and a continuation denied" \
    $'# $CLAUDE_SECRET_DIR/x \\\nterraform output -json'
expect DENY  "a fetch after a comment naming --password-stdin and a continuation denied" \
    $'echo a # --password-stdin \\\nterraform output -json'
expect ALLOW "a one-line terraform fetch into the vault allowed"        'terraform output -json > $CLAUDE_SECRET_DIR/x'
# compose's subcommand is its first word past its global options and their values; config elsewhere is an argument.
expect ALLOW "a git config inside compose exec allowed"                  'docker compose exec web git config --list'
expect ALLOW "compose logs of a service named config allowed"            'docker compose logs config'
expect DENY  "compose config after valued globals denied"                'docker compose -f a.yml --profile p config'
expect DENY  "compose config after an unknown global and its value denied" 'docker compose --x v config'
# Runners put every later word at command position, so a dump or reader they run is screened.
expect DENY  "kubectl exec of env denied"                                'kubectl exec pod -- env'
expect DENY  "kubectl exec after a namespace of env denied"              'kubectl -n ns exec pod -- env'
expect DENY  "kubectl exec with a container of env denied"               'kubectl exec -it pod -c ctr -- env'
expect DENY  "kubectl exec of a shell string denied"                     "kubectl exec pod -- sh -c 'env'"
expect DENY  "docker exec of env denied"                                 'docker exec c env'
expect DENY  "docker exec with an option of env denied"                  'docker exec --privileged c env'
expect DENY  "docker exec as root of env denied"                         'docker exec -it -u root c env'
expect DENY  "docker exec with an env option of env denied"              'docker exec --env X=1 c env'
expect DENY  "docker container exec of env denied"                       'docker container exec c env'
expect DENY  "docker exec of printenv denied"                            'docker exec c printenv'
expect DENY  "docker exec behind sudo of env denied"                     'sudo docker exec c env'
expect DENY  "podman exec of cat .env denied"                            'podman exec c cat .env'
expect DENY  "podman container exec of env denied"                       'podman container exec c env'
expect DENY  "nerdctl exec of env denied"                                'nerdctl exec c env'
expect DENY  "docker compose exec of env denied"                         'docker compose exec web env'
expect DENY  "docker compose run of env denied"                          'docker compose run web env'
expect DENY  "compose exec after a file option of env denied"            'docker compose -f a.yml exec web env'
expect DENY  "compose exec after an unknown global and its value denied" 'docker compose --x v exec web env'
expect DENY  "compose exec after an unknown global denied"               'docker compose --x exec web env'
expect DENY  "compose exec after a project named run denied"             'docker compose -p run exec web env'
expect DENY  "docker exec behind xargs of env denied"                    'echo c | xargs docker exec c env'
expect DENY  "upper-case KUBECTL exec of env denied"                     'KUBECTL exec pod -- env'
expect DENY  "docker-compose exec of printenv denied"                    'docker-compose exec web printenv'
expect DENY  "podman-compose run of env denied"                          'podman-compose run web env'
expect DENY  "doppler run of env denied"                                 'doppler run -- env'
expect DENY  "doppler run with a project and config of env denied"       'doppler run -p proj -c dev -- env'
expect DENY  "doppler run --command denied"                              'doppler run --command ls'
expect DENY  "doppler run --command= denied"                             'doppler run --command=ls'
expect DENY  "heroku run of env denied"                                  'heroku run env'
expect DENY  "heroku run of a quoted env denied"                         'heroku run "env"'
expect DENY  "heroku run of a command string denied"                     "heroku run 'printenv | sort'"
expect DENY  "heroku run of words the dyno's shell parses denied"        "heroku run -a app 'ls;' env"
expect DENY  "heroku run:inside of env denied"                           'heroku run:inside web.1 env'
expect ALLOW "docker exec of ls allowed"                                 'docker exec c ls'
expect ALLOW "kubectl exec of ls allowed"                                'kubectl exec pod -- ls /'
expect ALLOW "docker compose exec of a test run allowed"                 'docker compose exec web npm test'
expect ALLOW "doppler run with a config of a plain command allowed"      'doppler run -p proj -c dev -- npm test'
expect ALLOW "an option of the command doppler runs allowed"             'doppler run -- ./tool --command x'
expect ALLOW "heroku run of a plain command allowed"                     'heroku run -a app rake db:migrate'
expect DENY  "heroku local:run of env denied"                            'heroku local:run env'
expect DENY  "heroku local --start-cmd denied"                           'heroku local --start-cmd ls'
expect DENY  "heroku local:start --start-cmd= denied"                    'heroku local:start --start-cmd=ls'
expect ALLOW "heroku local:run of a plain command allowed"               'heroku local:run npm test'
expect DENY  "heroku local:run of a quoted argument denied"              "heroku local:run echo 'a b'"
expect DENY  "heroku local:run of a quoted command string denied"        'heroku local:run "sh -c env"'
expect DENY  "heroku local:run of a word with shell syntax denied"       "heroku local:run 'ls;' npm test"
expect ALLOW "heroku local of a process allowed"                         'heroku local web'
expect DENY  "oc exec of env denied"                                     'oc exec pod -- env'
expect DENY  "oc rsh of env denied"                                      'oc rsh pod env'
expect ALLOW "oc exec of ls allowed"                                     'oc exec pod -- ls'
expect DENY  "doppler run --mount outside the vault denied"              'doppler run --mount secrets.json -- npm test'
expect DENY  "doppler run --mount= outside the vault denied"             'doppler run --mount=s.json -- npm test'
expect DENY  "doppler run --mount-format with no vault mount denied"     'doppler run --mount-format json -- npm test'
expect DENY  "doppler run --mount-template with no vault mount denied"   'doppler run --mount-template=t.tpl -- npm t'
expect DENY  "doppler run --mount with a .. out of the vault denied" \
    'doppler run --mount $CLAUDE_SECRET_DIR/../s.json -- npm test'
expect DENY  "doppler run --mount into a reassigned vault denied" \
    'CLAUDE_SECRET_DIR=/tmp/x doppler run --mount $CLAUDE_SECRET_DIR/s.json -- npm test'
expect ALLOW "doppler run --mount into the vault allowed" \
    'doppler run --mount $CLAUDE_SECRET_DIR/s.json -- npm test'
expect ALLOW "doppler run --mount= and a format into the vault allowed" \
    'doppler run --mount-format json --mount=$CLAUDE_SECRET_DIR/s.json -- npm test'
expect ALLOW "a --mount of the command doppler runs allowed"             'doppler run -- ./tool --mount x'
# heroku's command-string deny names the fix that works on a dyno, not a local script.
got=$(jq -nc --arg c "heroku run 'printenv | sort'" '{tool_input:{command:$c}}' | "$HOOK" \
    | jq -r '.hookSpecificOutput.permissionDecisionReason')
if [[ "$got" == *'separate unquoted words'* && "$got" != *'bash <file>'* ]]; then
    ok "the heroku command-string deny reason names separate words"
else
    bad "the heroku command-string deny reason drifted: $got"
fi
got=$(jq -nc --arg c "heroku local:run 'printenv | sort'" '{tool_input:{command:$c}}' | "$HOOK" \
    | jq -r '.hookSpecificOutput.permissionDecisionReason')
if [[ "$got" == *'heroku local:run passes'*'separate unquoted words'* ]]; then
    ok "the heroku local:run command-string deny reason names local:run and separate words"
else
    bad "the heroku local:run command-string deny reason drifted: $got"
fi
# A copier after xargs or parallel copies what earlier stages named.
expect DENY  "a copier after xargs, fed a secret name, denied"           'echo .env | xargs -I{} cp {} /tmp/claude-x/n'
expect DENY  "a copier after parallel, fed a secret name, denied"        'echo .env | parallel cp {} /tmp/claude-x/n'
expect DENY  "a copier after xargs, fed a found secret, denied"          'find . -name .env | xargs -I{} cp {} /tmp/x'
expect DENY  "an rsync after xargs, fed a secret name, denied"           'echo .env | xargs -I{} rsync {} /tmp/x/n'
expect DENY  "a copier with -t after xargs, fed a secret name, denied"   'echo .env | xargs cp -t /tmp/claude-x'
expect DENY  "a copier after parallel given a secret input denied"       'parallel cp {} /tmp/claude-x ::: .env'
expect ALLOW "a copier after xargs, fed a plain name, allowed"           'echo a.txt | xargs -I{} cp {} /tmp/claude-x/n'
expect ALLOW "a copier after parallel given a plain input allowed"       'parallel cp {} /tmp/claude-x ::: a.txt'
# An interpreter option that takes a value is skipped with its value, so the stdin rule still sees no program.
expect DENY  "python3 -W ignore fed a secret denied"                     'python3 -W ignore < .env'
expect DENY  "python3 -X utf8 fed a secret denied"                       'python3 -X utf8 < .env'
expect DENY  "perl -I lib fed a secret denied"                           'perl -I lib < .env'
expect DENY  "perl -M strict fed a secret denied"                        'perl -M strict < .env'
expect DENY  "ruby -I lib fed a secret denied"                           'ruby -I lib < .env'
expect DENY  "ruby -C dir fed a secret denied"                           'ruby -C dir < .env'
expect DENY  "node --require x fed a secret denied"                      'node --require x < .env'
expect DENY  "node --input-type module fed a secret denied"              'node --input-type module < .env'
expect DENY  "node -C production fed a secret denied"                    'node -C production < .env'
expect DENY  "php -d x=1 fed a secret denied"                            'php -d x=1 < .env'
expect DENY  "a skipped option value naming a secret is still denied"    'perl -x .env'
expect ALLOW "python3 -W ignore with a script allowed"                   'python3 -W ignore script.py'
expect ALLOW "python3 -W ignore with a script fed a secret allowed"      'python3 -W ignore script.py < .env'
expect DENY  "ruby -E (inline code) with a secret operand still denied"  'ruby -E x .env'
expect DENY  "a value-taking letter ending a bundle fed a secret denied" 'python3 -IW ignore < .env'
expect DENY  "an option value then -- fed a secret denied"               'python3 -W ignore -- < .env'
expect ALLOW "python3 -I (no value) with a script fed a secret allowed"  'python3 -I script.py < .env'
expect ALLOW "python3 -x (no value) with a script fed a secret allowed"  'python3 -x script.py < .env'
expect ALLOW "an option value before a script given a secret argument allowed" 'python3 -W ignore tools/use.py .env'
expect DENY  "a long option taking the next word, fed a secret, denied" \
    'python3 --check-hash-based-pycs default < .env'
expect DENY  "node --conditions production fed a secret denied"          'node --conditions production < .env'
expect DENY  "node --title fed a secret denied"                          'node --title x < .env'
expect DENY  "ruby --disable gems fed a secret denied"                   'ruby --disable gems < .env'
expect DENY  "an option value is never an inline-code bundle"            'node --no-warnings -e code .env'
expect DENY  "node --eval fed a secret denied"                           'node --eval code < .env'
expect DENY  "node --eval with a later secret operand denied"            'node --eval code x .env'
expect DENY  "php -R fed a secret denied"                                'php -R code < .env'
expect DENY  "php --run with a later secret operand denied"              'php --run code x .env'
expect DENY  "an attached option value naming a secret denied"           'node --require=./.env'
expect DENY  "an attached option value after inline code denied"         'python3 -c code --x=./.env'
expect ALLOW "an attached option value in the vault allowed" \
    'node --env-file=$CLAUDE_SECRET_DIR/app.env app.js'
expect DENY  "an attached option value naming a secret outside the vault denied" 'node --env-file=.env app.js'
expect DENY  "an attached option value leaving the vault by .. denied" \
    'node --env-file=$CLAUDE_SECRET_DIR/../.env app.js'
expect DENY  "an attached option value in a reassigned vault denied" \
    'CLAUDE_SECRET_DIR=/tmp/x node --env-file=$CLAUDE_SECRET_DIR/app.env app.js'
expect DENY  "a skipped value in the vault that may be the program denied" \
    'node --no-warnings $CLAUDE_SECRET_DIR/app.env'
expect ALLOW "a vault --env-file-if-exists with a script allowed" \
    'node --env-file-if-exists=$CLAUDE_SECRET_DIR/app.env app.js'
expect DENY  "a vault file node --require runs as code denied"   'node --require=$CLAUDE_SECRET_DIR/x.js app.js'
expect DENY  "a vault file node --import runs as code denied"    'node --import=$CLAUDE_SECRET_DIR/x.js app.js'
expect DENY  "a vault file ruby --require runs as code denied"   'ruby --require=$CLAUDE_SECRET_DIR/x.rb'
expect DENY  "a vault env file before -e denied"                 'node --env-file=$CLAUDE_SECRET_DIR/app.env -e x'
expect DENY  "a vault env file before --eval= denied"            'node --env-file=$CLAUDE_SECRET_DIR/app.env --eval=x'
expect DENY  "a vault env file before -p denied"                 'node --env-file=$CLAUDE_SECRET_DIR/app.env -p x'
expect DENY  "a vault env file after -e denied"                  'node -e x --env-file=$CLAUDE_SECRET_DIR/app.env'
expect DENY  "a vault env file with a program on stdin denied" \
    "echo x | node --env-file=\$CLAUDE_SECRET_DIR/app.env"
expect DENY  "a vault env file with no script file denied"       'node --env-file=$CLAUDE_SECRET_DIR/app.env - < p.js'
# A vault env file is allowed only as node's one option, before a script named by a plain literal word, in a stage
# nothing feeds.
vef='node --env-file=$CLAUDE_SECRET_DIR/x'
expect DENY  "a vault env file with an empty script word denied"         "$vef \"\""
expect DENY  "a vault env file with a variable script word denied"       "$vef \$UNSET"
expect DENY  "a vault env file with a glob script word denied"           "$vef '*.js'"
expect DENY  "a vault env file with a brace script word denied"          "$vef {-,x}"
expect DENY  "a vault env file with a backslash script word denied"      "$vef a\\\\b.js"
expect DENY  "a vault env file then --import= denied"                    "$vef --import=data:text/javascript,1 app.js"
expect DENY  "a vault env file then --run denied"                        "$vef --run start"
expect DENY  "a vault env file then - denied"                            "$vef -"
expect DENY  "a vault env file then -- denied"                           "$vef -- app.js"
expect DENY  "a vault env file then --inspect denied"                    "$vef --inspect app.js"
expect DENY  "an option before a vault env file denied"     'node --inspect --env-file=$CLAUDE_SECRET_DIR/x app.js'
expect DENY  "an attached option before a vault env file denied" \
    'node --import=data:text/javascript,1 --env-file=$CLAUDE_SECRET_DIR/x app.js'
expect DENY  "a vault env file in a stage fed by a pipe denied"          "echo x | $vef app.js"
expect DENY  "a vault env file in a stage fed by a redirection denied"   "$vef app.js < in.txt"
expect ALLOW "a vault env file before a script allowed"                  "$vef app.js"
expect ALLOW "a vault env file before a script and its arguments allowed" "$vef app.js --port 3000"
expect ALLOW "a vault env file before a script piped onward allowed"     "$vef app.js | tee out.log"
expect ALLOW "a vault env file before a script under a directory allowed" "$vef src/app.js"
# NODE_OPTIONS adds the options a vault env file's node may not take on its command line.
expect DENY  "a vault env file with a NODE_OPTIONS prefix denied" \
    "NODE_OPTIONS=--import=data:text/javascript,1 $vef app.js"
expect DENY  "a vault env file with NODE_OPTIONS through env denied" "env NODE_OPTIONS=--require=./p.js $vef app.js"
expect DENY  "a vault env file after an exported NODE_OPTIONS denied" "export NODE_OPTIONS=--require=x ; $vef app.js"
expect DENY  "a vault env file after a computed-name write denied"    "read \"\${n}_OPTIONS\" <<< x ; $vef app.js"
expect ALLOW "a vault env file reading NODE_OPTIONS only allowed"     "$vef app.js \$NODE_OPTIONS"
# A sourced file, set -a, or any command before a separator may set NODE_OPTIONS unseen.
expect DENY  "a vault env file after a sourced file denied"          ". ./env.sh ; $vef app.js"
expect DENY  "a vault env file after set -a denied"                  "set -a ; $vef app.js"
expect DENY  "a vault env file after set -o allexport denied"        "set -o allexport ; $vef app.js"
expect DENY  "a vault env file after any separator denied"           "true ; $vef app.js"
expect DENY  "a vault env file in a command that sources a file denied" "$vef app.js | . ./env.sh"
expect DENY  "a vault env file in a command that runs source denied" "$vef app.js | builtin source ./env.sh"
expect ALLOW "a vault env file with a script option named source allowed" "$vef app.js --source x"
# The exemption holds only for node as the stage's first word: an assignment or wrapper before it may set NODE_OPTIONS
# under a name no text test can read.
expect DENY  "a vault env file behind env and an ANSI-C quoted assignment denied" \
    "env \$'NODE_OPTIONS=--require=./p.js' $vef app.js"
expect DENY  "a vault env file behind env and a locale-quoted assignment denied" \
    "env \$\"NODE_OPTIONS=--require=./p.js\" $vef app.js"
expect DENY  "a vault env file behind env and an escaped assignment name denied" \
    "env \$'\\x4eODE_OPTIONS=--require=./p.js' $vef app.js"
expect DENY  "a vault env file behind sudo and a quoted assignment denied" \
    "sudo \$'NODE_OPTIONS=--require=./p.js' $vef app.js"
expect DENY  "a vault env file behind env and a spliced assignment name denied" \
    "env NODE_OPT\${HOME:0:0}IONS=--require=./p.js $vef app.js"
expect DENY  "a vault env file behind command denied"                "command $vef app.js"
expect DENY  "a vault env file behind a prefix assignment denied"    "FOO=1 $vef app.js"

# bash32_rows: rows that must also hold with the hook under /bin/bash (bash 3.2, a stock Mac's bash).
bash32_rows() {
    expect_in "$P" DENY  "under bash 3.2, a recursive grep of a root holding .env denied" 'grep -rn KEY .'
    expect_in "$P" ALLOW "under bash 3.2, grep -rl allowed"                       'grep -rl KEY .'
    expect_in "$R" ALLOW "under bash 3.2, rg in a repo whose .env is ignored allowed" 'rg KEY'
    expect      ASK   "under bash 3.2, a variable root asks"                      'grep -rn KEY $SOMEDIR'
    expect_in "$pt/cfg" DENY "under bash 3.2, cat * matching config.env denied"   'cat *'
    expect_in "$P" DENY  "under bash 3.2, find piped into xargs cat denied"       'find . -type f | xargs cat'
    expect_in "$P" DENY  "under bash 3.2, a grep of a directory denied"           'grep -n KEY .'
    expect_in "$P" DENY  "under bash 3.2, --context may leave . a root, denied"   'grep -r --context KEY . src'
    expect_in "$P" DENY  "under bash 3.2, an --exclude before an --include denied" \
        "grep -rn --exclude=x --include='*.py' KEY ."
    expect_in "$T" DENY  "under bash 3.2, git grep -O denied"                     'git grep -Ocat KEY'
    expect_in "$R" ASK   "under bash 3.2, git grep of a revision asks"            'git grep KEY HEAD'
    expect      DENY  "under bash 3.2, a find root after the expression denied"   "find -name x $P -exec cat {} \\;"
    expect_in "$G" DENY  "under bash 3.2, cat */* denied"                         'cat */*'
    expect_in "$P" DENY  "under bash 3.2, a names-only grep piped into xargs cat denied" 'grep -rl KEY . | xargs cat'
    expect_in "$P" DENY  "under bash 3.2, xargs gives grep -r its pattern, denied" 'echo KEY | xargs grep -r'
    expect_in "$P" DENY  "under bash 3.2, rg with a /dev/null stdin denied"      'rg KEY < /dev/null'
    expect_in "$T" DENY  "under bash 3.2, git grep -lO denied"                   'git grep -lOcat KEY'
    expect_in "$I" DENY  "under bash 3.2, rg of a named ignored root denied"     'rg KEY ign'
    expect_in "$P" ALLOW "under bash 3.2, cat */README.md allowed"               'cat */README.md'
    expect_in "$N" DENY  "under bash 3.2, a grep of */ over sub/.env denied"     'grep -n KEY */'
    expect_in "$P" ALLOW "under bash 3.2, find piped into a names-only xargs grep allowed" \
        "find . -name '*.py' | xargs grep -l foo"
    expect_in "$P" DENY  "under bash 3.2, find -exec sed -i denied" \
        "find . -type f -exec sed -i '' s/a/b/ {} +"
    expect_in "$P" ALLOW "under bash 3.2, find -name piped into a content xargs grep allowed" \
        "find . -name '*.py' | xargs grep -n foo"
    expect_in "$P" ALLOW "under bash 3.2, find -iname -exec of a content grep allowed" \
        "find . -iname '*.PY' -exec grep -n foo {} +"
    expect_in "$P" DENY  "under bash 3.2, find -name with -o denied" \
        "find . -name '*.py' -o -name .env | xargs grep -n foo"
    expect_in "$pt/qq" DENY "under bash 3.2, a bare wildcard piped into xargs grep -r denied" \
        'echo * | xargs grep -rn KEY /dev/null'
    expect_in "$P/src" ASK "under bash 3.2, a find -exec {}/.. operand asks" \
        'find . -maxdepth 0 -exec grep -rn KEY {}/.. \;'
    expect_in "$XG" DENY "under bash 3.2, a partial glob piped into xargs grep -r denied" \
        'echo *.md | xargs grep -rn KEY /dev/null'
    expect_in "$P/src" DENY "under bash 3.2, a directory outside the cwd piped into xargs grep -r denied" \
        "echo $pt/ns | xargs grep -rn KEY /dev/null"
    expect_in "$XR" ALLOW "under bash 3.2, git ls-files into xargs rg allowed"   'git ls-files | xargs rg foo'
    expect_in "$P/src" DENY "under bash 3.2, a find -exec reader's own root denied" \
        'find . -maxdepth 0 -exec grep -rn KEY .. \;'
    expect_in "$XI/cw" DENY "under bash 3.2, a relative xargs -I operand outside the cwd denied" \
        'echo sub | xargs -I{} grep -rn KEY ../tgt/{}'
    expect_in "$XI/cw" DENY "under bash 3.2, xargs -I running the command its input names denied" \
        'echo sh | xargs -I% % -c id'
    expect_in "$RP" ASK "under bash 3.2, a path git prints at run time asks" \
        'git rev-parse --show-toplevel | xargs grep -rn KEY'
    expect_in "$RP" ASK "under bash 3.2, xargs fed by an input redirection asks" 'xargs grep -rn KEY < list'
    expect_in "$XR" ALLOW "under bash 3.2, names through sort and grep -v into xargs rg allowed" \
        'git ls-files | sort | grep -v test | xargs rg foo'
    expect_in "$pt/lroot" DENY "under bash 3.2, a link in the cwd fed through xargs to grep -r denied" \
        'echo s | xargs grep -rn KEY'
    expect_in "$P/src" ASK "under bash 3.2, a path of more than 256 slashes asks" \
        "echo ${s300}$P/doc | xargs grep -rn KEY"
    expect_in "$B/cw" DENY "under bash 3.2, fd --search-path= outside the cwd denied" \
        "fd --search-path=$B/tgt | xargs grep -rn KEY"
    expect_in "$B/cw" ASK "under bash 3.2, a names-only grep --label asks" \
        "echo KEY | grep -l --label=$B/tgt/sub KEY | xargs grep -rn KEY"
    expect_in "$B/p/cw" ASK "under bash 3.2, a pattern followed by .. asks" 'echo */../.. | xargs grep -rn KEY'
    expect      DENY  "under bash 3.2, a vault env file with an empty script word denied" "$vef \"\""
    expect      DENY  "under bash 3.2, a vault env file in a stage fed by a pipe denied" "echo x | $vef app.js"
    expect      ALLOW "under bash 3.2, a vault env file before a script allowed" "$vef app.js --port 3000"
    expect      DENY  "under bash 3.2, a vault env file with a NODE_OPTIONS prefix denied" \
        "NODE_OPTIONS=--require=./p.js $vef app.js"
    expect      DENY  "under bash 3.2, a vault env file after a sourced file denied" ". ./env.sh ; $vef app.js"
    expect      DENY  "under bash 3.2, a vault env file after set -a denied" "set -a ; $vef app.js"
    expect      DENY  "under bash 3.2, a vault env file behind env denied" \
        "env \$'NODE_OPTIONS=--require=./p.js' $vef app.js"
    expect_in "$pt/fx" DENY "under bash 3.2, find of a root its -name matches denied" \
        "find deep -name deep -exec grep -rn KEY {} +"
    expect      DENY  "under bash 3.2, oc whoami -t denied"              'oc whoami -t'
    expect      DENY  "under bash 3.2, oc extract denied"                'oc extract secret/x'
    expect      ALLOW "under bash 3.2, oc extract into the vault allowed" \
        'oc extract secret/x --to=$CLAUDE_SECRET_DIR/x'
    expect_in "$B/p/cw" ASK "under bash 3.2, a ..* pattern asks"          'echo ..* | xargs grep -rn KEY'
    expect_in "$B/p/cw" ASK "under bash 3.2, ..* components after a pattern ask" 'echo */..*/..* | xargs grep -rn KEY'
    expect      DENY  "under bash 3.2, cd ~/.aws denied"                  'cd ~/.aws'
    expect      DENY  "under bash 3.2, chdir ~/.aws denied"               'chdir ~/.aws'
    expect      ALLOW "under bash 3.2, chdir src allowed"                 'chdir src'
    expect      ALLOW "under bash 3.2, cd src allowed"                    'cd src'
    expect_in "$pt/cdl" DENY "under bash 3.2, cd into a link to a secret directory denied" 'cd l'
    expect      ASK   "under bash 3.2, cd into an unresolved variable asks" 'cd $SOMEDIR'
    expect_sid abc-123 ASK "under bash 3.2, \$PWD the command assigns asks" 'PWD=/x ; cd "$PWD"'
    expect_sid abc-123 ALLOW "under bash 3.2, cd \$PWD allowed"            'cd "$PWD"'
    expect_sid abc-123 ASK "under bash 3.2, \$PWD after \${PWD:=…} asks"  'echo ${PWD:=/x} ; cd "$PWD"'
    expect_sid abc-123 ASK "under bash 3.2, \$PWD after a computed read asks" 'read "${n}WD" <<< /x ; cd "$PWD"'
    expect      DENY  "under bash 3.2, terraform output -json denied"    'terraform output -json'
    expect      DENY  "under bash 3.2, docker compose config denied"     'docker compose config'
    expect      DENY  "under bash 3.2, an authfile outside the vault denied" 'podman login --authfile /tmp/x r'
    expect      DENY  "under bash 3.2, an aws fetch with a quoted pipe denied" \
        "aws secretsmanager --query 'a|b' get-secret-value"
    expect      DENY  "under bash 3.2, DOCKER_CONFIG exported before a login denied" \
        'export DOCKER_CONFIG=/tmp/d ; docker login r'
    expect      DENY  "under bash 3.2, launchctl getenv of a lower-case name denied" 'launchctl getenv github_token'
    expect      ALLOW "under bash 3.2, docker compose config --services allowed" 'docker compose config --services'
    expect      ALLOW "under bash 3.2, a git config inside compose exec allowed" \
        'docker compose exec web git config --list'
    expect      DENY  "under bash 3.2, aws-vault exec -j denied"          'aws-vault exec -j prod -- true'
    expect      DENY  "under bash 3.2, terraform output across a continuation denied" $'terraform output \\\n-json'
    expect      DENY  "under bash 3.2, docker exec of env denied"        'docker exec c env'
    expect      DENY  "under bash 3.2, heroku run of a command string denied" "heroku run 'printenv | sort'"
    expect      DENY  "under bash 3.2, a copier after xargs denied"      'echo .env | xargs -I{} cp {} /tmp/claude-x/n'
    expect      DENY  "under bash 3.2, python3 -W ignore fed a secret denied" 'python3 -W ignore < .env'
    expect      DENY  "under bash 3.2, node --eval fed a secret denied"  'node --eval code < .env'
}
if [[ -x /bin/bash ]] && [[ "$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"')" == 3 ]]; then
    HOOK_BASH=/bin/bash
    bash32_rows
    unset HOOK_BASH
fi

# Timing. A PreToolUse hook that overruns its 5 s timeout does not block, so a command this hook cannot screen in
# time passes unscreened. bash-guard denies anything over 64 KiB, so each case is at most 65536 characters, and each
# must be decided within TIME_LIMIT_MS, half the timeout, in one of TIME_RUNS runs: a CI runner is two to three times
# slower per core than a current Mac, so a row that passes there leaves the hook at least twice its worst case inside
# the timeout. The budget is a speed target that load on a busy machine can push one run past, so a slow run is
# retried; TIME_HARD_MS, kept below the timeout, bounds every run, and a run that reaches it fails the row at once.
TIME_LIMIT_MS=2500
TIME_HARD_MS=4000
TIME_RUNS=3

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

# expect_fast <verdict> <description> <cmd>: pass when the hook decides <cmd> as expected (DENY, ASK, ALLOW, or a
# |-separated choice of them) within TIME_LIMIT_MS in one of TIME_RUNS runs; a wrong verdict or a run of TIME_HARD_MS
# or more fails at once.
expect_fast() {
    local got start elapsed i times="" under="${HOOK_BASH:+, $HOOK_BASH}${LC_ALL:+, LC_ALL=$LC_ALL}"
    for (( i = 1; i <= TIME_RUNS; i++ )); do
        start=$(_ms)
        got=$(run "$3")
        elapsed=$(( $(_ms) - start ))
        times+="${times:+, }${elapsed}"
        if [[ "|$1|" != *"|$got|"* ]] || (( elapsed >= TIME_HARD_MS || ${#3} > 65536 )); then
            break
        fi
        if (( elapsed < TIME_LIMIT_MS )); then
            ok "$2 (${#3} characters, ${times} ms$under)"
            return
        fi
    done
    bad "$2 (${#3} characters$under): want $1 within ${TIME_LIMIT_MS} ms in one of ${TIME_RUNS} runs, each under\
 ${TIME_HARD_MS} ms, got $got in ${times} ms"
}

# expect_fast against a stub hook that sleeps for the listed seconds, one per run, with the limits scaled down: a run
# over the budget is retried, up to three runs; a wrong verdict, or a run at the hard limit, fails at once.
sdir=$(mktemp -d)
cat > "$sdir/hook" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
n=$(( $(cat "$STUB_DIR/n") + 1 ))
echo "$n" > "$STUB_DIR/n"
sleep "$(sed -n "${n}p" "$STUB_DIR/delays")"
printf '%s' '{"hookSpecificOutput":{"permissionDecision":"deny"}}'
EOF
chmod +x "$sdir/hook"
export STUB_DIR="$sdir"
# _stub_case <want verdict> <delays> <want PASS|FAIL> <want runs> <description>
_stub_case() {
    local res runs
    printf '%s\n' $2 > "$sdir/delays"
    echo 0 > "$sdir/n"
    res=$(HOOK="$sdir/hook" TIME_LIMIT_MS=1000 TIME_HARD_MS=2000 expect_fast "$1" stub x)
    runs=$(cat "$sdir/n")
    if [[ "$res" == "$3: "* && "$runs" == "$4" ]]; then
        ok "expect_fast: $5"
    else
        bad "expect_fast: $5 (want $3 after $4 runs, got '${res%%:*}' after $runs)"
    fi
}
_stub_case DENY  '0'           PASS 1 "a fast run passes at once"
_stub_case DENY  '1.2 0'       PASS 2 "a run over the budget is retried, and a fast retry passes"
_stub_case DENY  '1.2 1.2 1.2' FAIL 3 "three runs over the budget fail"
_stub_case DENY  '2.2 0'       FAIL 1 "a run at the hard limit fails without a retry"
_stub_case ALLOW '0 0'         FAIL 1 "a wrong verdict fails without a retry"
rm -rf "$sdir"
unset STUB_DIR

# Over the bound, the hook denies without screening, whatever the content.
expect DENY "a command over the scan bound denied" "true $(printf 'a%.0s' {1..70000})"
expect DENY "a command at the scan bound still screened" "cat $(printf 'a%.0s' {1..65527}) .env"
expect ALLOW "a benign command at the scan bound allowed" "true $(printf 'a%.0s' {1..65531})"

# The screening budget: a command with more options, paths or wrapped words than SECRET_SCAN_WORD_BUDGET is denied
# without walking them all; one at the budget is screened as usual.
expect ALLOW "a command at the word budget allowed" "ls $(printf -- '-x %.0s' {1..6000})"
expect DENY  "a command over the word budget denied" "ls $(printf -- '-x %.0s' {1..6001})"
budget_want="SECRET-SCAN BLOCK: this command has more words to screen than the hook can check in time (over 6000"
budget_want+=" options, paths or wrapped words). Split it into smaller commands, or put long content in a file."
budget_got=$(jq -nc --arg c "ls $(printf -- '-x %.0s' {1..6001})" '{tool_input:{command:$c}}' | "$HOOK" \
    | jq -r '.hookSpecificOutput.permissionDecisionReason')
if [[ "$budget_got" == "$budget_want" ]]; then
    ok "the word budget deny reason is pinned"
else
    bad "the word budget deny reason drifted: $budget_got"
fi
# Separators count toward the same budget: each ; (here, 6000 or 6001 one-word commands) is one element.
expect ALLOW "6000 separators at the budget allowed" "$(printf 'a;%.0s' {1..6000})true"
expect DENY  "6001 separators over the budget denied" "$(printf 'a;%.0s' {1..6001})true"
budget_got=$(jq -nc --arg c "$(printf 'a;%.0s' {1..6001})true" '{tool_input:{command:$c}}' | "$HOOK" \
    | jq -r '.hookSpecificOutput.permissionDecisionReason')
if [[ "$budget_got" == "$budget_want" ]]; then
    ok "the separator budget deny reason is the word budget's"
else
    bad "the separator budget deny reason drifted: $budget_got"
fi

# timing_rows: every worst case, run once per bash below.
timing_rows() {
local RUN_CWD="$tdir"
# Short tokens maximise the per-word work; a trailing secret operand must still be found.
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
# Many stages before xargs, whose earlier stages' secret words count.
expect_fast DENY "many stages before an xargs reader" "$(printf 'echo a|%.0s' {1..9300})echo .env|xargs cat"
# Many redirections, each target screened.
expect_fast DENY "many input redirections" "cat $(printf '<a %.0s' {1..21000})<.env"
# Every word at command position behind a wrapper, each env a fresh walk candidate.
expect_fast DENY "many env words behind a wrapper" "sudo $(printf 'env %.0s' {1..16000})cat .env"
# One 64 KiB word through the whole-word secret match.
expect_fast DENY "one 64 KiB word" "cat /$(printf 'a%.0s' {1..65000}).env"
# Many glob-bearing words, each through the representative test.
expect_fast DENY "many glob-bearing words" "cat $(printf 'a%s* ' {1..9000}).env"
# Long words with = at the end, through the bounded variant test.
expect_fast DENY "long words with a late =" "$(printf -- '--o=%04090d ' {1..15})cat .env"
# A fetch into the vault reads every word of its stage for the fetch shapes.
expect_fast ALLOW "a long fetch into the vault" \
    "aws secretsmanager get-secret-value --secret-id x > \$CLAUDE_SECRET_DIR/x $(printf 'a %.0s' {1..32000})"
# Many glob words with an empty literal prefix, each through the representative loop.
expect_fast DENY "many empty-prefix glob words" "cat $(printf '*x %.0s' {1..21000}).env"
# Many glob words with a literal prefix that starts a representative.
expect_fast DENY "many literal-prefix glob words" "cat $(printf 'x* %.0s' {1..21000}).env"
# Glob words stacking a class ten times, the representative match's worst backtracking.
expect_fast DENY "many stacked-class glob words" \
    "cat $(printf '*[a-z]*[a-z]*[a-z]*[a-z]*[a-z]*[a-z]*[a-z]*[a-z]*[a-z]*[a-z]*. %.0s' {1..1000}).env"
# Quoted glob words stacking an extglob group six times.
expect_fast DENY "many stacked-extglob glob words" \
    "cat $(printf "'*@(e|s|r)*@(e|s|r)*@(e|s|r)*@(e|s|r)*@(e|s|r)*@(e|s|r)*.' %.0s" {1..1000}).env"
# Glob words at the wildcard bound (three stars and two brackets tally five), the most the glob test will match.
expect_fast DENY "many glob words at the wildcard bound" \
    "cat $(printf '*[a-z]*[a-z]*x %.0s' {1..4000}).env"
# A kubectl get with -o at every word: each kubectl starts an attempt of the fetch form that scans to the end. Four
# words a copy, so 1400 copies stay inside the word budget.
expect_fast ALLOW "many kubectl get words with -o" "$(printf 'kubectl get -o x %.0s' {1..1400})"
# The same, quoted, so the pre-check also strips the quotes and matches the copy.
expect_fast ALLOW "many quoted kubectl get words" "$(printf "kubectl get '-o' x %.0s" {1..1400})"
# The same at the full command size: over the word budget, so denied, after the pre-check has run its forms over it.
expect_fast DENY "many kubectl get words over the word budget" "$(printf 'kubectl get -o x %.0s' {1..3800})"
expect_fast DENY "many quoted kubectl get words over the word budget" "$(printf "kubectl get '-o' x %.0s" {1..3000})"
# The same for oc, and for its whoami and sa forms.
expect_fast ALLOW "many oc get words with -o" "$(printf 'oc get -o x %.0s' {1..1400})"
expect_fast ALLOW "many oc whoami words with options" "$(printf 'oc whoami -x y %.0s' {1..1400})"
expect_fast ALLOW "many oc sa words with options" "$(printf 'oc sa -x y %.0s' {1..1400})"
expect_fast DENY "many oc extract words" "$(printf 'oc extract --to x %.0s' {1..1400})"
# A find narrowed by many -name globs, its 64 roots and 64 candidate roots: past 16 globs it does not narrow.
expect_fast DENY "a find of many -name globs and roots" \
    "find $(printf 'd%d ' {1..64})-type f $(printf -- '-name a%d* -type f ' {1..1300})| xargs grep -n x .env"
# One-character words that hold a form separator: every variant of the word is tested unless the value is empty.
expect_fast DENY "many one-character colon words" "cat $(printf ': %.0s' {1..32760}).env"
expect_fast DENY "many colon stages" "$(printf ':|%.0s' {1..32760})cat .env"
expect_fast DENY "many short variant words behind every walk" \
    "sudo jq awk perl -e cp printenv ps su watch xargs cat $(printf -- '-:= %.0s' {1..16300}).env"
# Glob words whose brackets dominate their cost, at the bound's wildcard count.
cls='[[:alnum:][:punct:]]'
expect_fast DENY "many bracketed glob words" \
    "cat $(printf "*${cls}*${cls}*${cls}*${cls}*${cls}# %.0s" {1..610}).env"
# A local component holding ( is skipped before any match, and a host:path one has its groups matched as one *: an
# extglob group inside repeating groups is exponential.
expect_fast DENY "many extglob glob words" \
    "cat $(printf "'?+(?|??)+(?|??)+(?|??)+(?|??)+(?|??)#' %.0s" {1..1400}).env"
expect_fast DENY "many remote extglob glob words" \
    "scp $(printf "'h:?+(?|??)+(?|??)+(?|??)+(?|??)+(?|??)#' %.0s" {1..1300}).env"
# Components at the length bound of brackets holding (, each read bracket by bracket before any match.
expect_fast DENY "many bracket-and-paren glob words" \
    "cat $(printf "'.$(printf '[(]%.0s' {1..42})' %.0s" {1..500}).env"
# Glob words that match inside the bound (two stars, two brackets), up to the test budget, then fail closed.
cls2='[!abcdefghijklmnopqrstuvwxyz]'
expect_fast DENY "many glob words inside the bound" \
    "cat $(printf "*${cls2}*${cls2}x %.0s" {1..1000}).env"
# aws forms with a run of options after each service word: each start of a form scans the options that follow.
expect_fast ALLOW "many aws service words with options" "$(printf 'ssm -x y %.0s' {1..5500})"
# More words than the screening budget, behind every walk and behind a wrapper: denied without walking them all.
expect_fast DENY "a long run of words behind every walk" \
    "sudo jq awk perl -e cp printenv ps su watch xargs cat $(printf 'a %.0s' {1..32700}).env"
expect_fast DENY "a long run of dot words behind every walk" \
    "sudo jq awk perl -e cp printenv ps su watch xargs cat kubectl find git $(printf '. %.0s' {1..32700}).env"
expect_fast DENY "a wrapper and many dot words" "sudo $(printf '. %.0s' {1..32700})"
# Separators count toward the budget too: 32 700 one-word commands.
expect_fast DENY "many one-word commands" "$(printf 'a;%.0s' {1..32700})cat .env"
# Upper-case command names, each folded before its class lookup, up to the word budget.
expect_fast DENY "many upper-case command words" "sudo $(printf 'UNEXPAND %.0s' {1..5990})CAT .env"
# Upper-case words holding a secret fragment, each through the case-insensitive path match.
expect_fast DENY "many upper-case fragment words" "cat $(printf 'A/.ENVX/B %.0s' {1..5990}).ENV"
# An ssh walk reads every later word of its stage, plain ones included, up to the word budget.
expect_fast ALLOW "an ssh with many remote words" "ssh host $(printf 'a %.0s' {1..5990})"
# Words holding a non-ASCII letter, each folded before screening.
expect_fast DENY "many words holding a foldable letter" "cat $(printf $'a\xc5\xbfb %.0s' {1..5990}).env"
# Words at the fold's length bound, each holding foldable letters, through every substitution.
expect_fast DENY "long words holding foldable letters" \
    "$(printf -- $'--o=%04080d\xc5\xbf\xef\xac\x80\xc3\x9f ' {1..15})cat .env"
# gpg candidates each followed by a run of option-shaped words: the raw decrypt form scans the run for each.
expect_fast DENY "many gpg words with options" "$(printf 'gpg -x y %.0s' {1..7000})"
# A commit heredoc behind a long run of option words on both sides of commit, 32 452 characters, just under the strip's
# size bound: the strip, the body scan and the tokeniser all run on it before the word budget denies it.
hd=$'-m "$(cat <<\'EOF\'\nmsg\nEOF\n)"'
expect_fast DENY "a commit heredoc behind many option words" \
    "git$(printf ' -a%.0s' {1..5400}) commit$(printf ' -b%.0s' {1..5400}) $hd"
# A recursive grep of 64 directories: one listing pipeline over all of them.
expect_fast ALLOW "a recursive grep of 64 directories" "grep -rn KEY $(printf 'd%d ' {1..64})"
# Many distinct wildcard-only operands: the first 64 are expanded, the rest hold an ask, and the .env denies.
expect_fast DENY "many wildcard-only operands" "cat $(printf 'd%d/* ' {1..5000}).env"
# Many distinct directory globs: the first 64 are expanded and recorded for xargs, the rest hold an ask.
expect_fast DENY "many directory-glob operands" "cat $(printf 'd%d*/x* ' {1..5000}).env"
# Many git grep stages, then a secret read: git is asked about submodules once per directory, not once per stage.
expect_fast DENY "many git grep stages" "$(printf 'git grep a|%.0s' {1..700})cat .env"
expect_fast DENY "git grep stages in 64 directories" "$(printf 'git -C d%d grep a|' {1..64})cat .env"
# Many rg stages naming a root: git is asked which roots it ignores once per distinct set of roots.
expect_fast DENY "many rg stages naming a root" "$(printf 'rg a d1|%.0s' {1..700})cat .env"
# Words of 4090 slashes each, which a recursive reader after xargs would probe: normalising a path costs time linear in
# its length, and one of more than 256 slashes is not normalised at all.
expect_fast ALLOW "many words of many slashes" "ls $(printf "${sl}x%d " {1..16})"
expect_fast DENY "many words of many slashes, then a secret" "cat $(printf "${sl}x%d " {1..15}).env"
expect_fast ALLOW "a recursive grep of many slash-heavy operands" "grep -rn KEY $(printf "${sl}x%d " {1..15})"
# Many name-producing stages before xargs, each classified, inside the word budget.
expect_fast DENY "many sort stages before xargs grep -r" "$(printf 'sort|%.0s' {1..2900})xargs grep -rn KEY .env"
# A long xargs -I string and a long operand or command: matching one inside the other is bounded, so they ask.
expect_fast DENY "a long xargs -I string and a long operand" "echo x | xargs -I $xr grep -rn KEY $xop .env"
expect_fast ASK "a long xargs -I string and a long command" "echo x | xargs -I $xr $xop"
# A cd tests its target's every ancestor, at a cost linear in their length: long targets, and cd commands past the
# bound, ask.
expect_fast ASK "many cd stages to long paths" "$(printf "cd $cdl/x%d|" {1..8})true"
expect_fast ASK "many cd stages" "$(printf 'cd d%d|' {1..2900})true"
# A 65 KiB run of quoted separators: the masked pre-check copy is built and matched.
expect_fast ALLOW "a long quoted run of separators through the masked pre-check" "echo '$(printf 'a|%.0s' {1..32700})'"
# Fetch forms that end at their last option, each start scanning the options after it.
expect_fast ALLOW "many doppler secrets words with options" "$(printf 'doppler secrets -x y %.0s' {1..1400})list"
expect_fast ALLOW "many heroku config words with options" "$(printf 'heroku config -a y %.0s' {1..1400})list"
# Option words and redirections after each terraform output, the named-output form's skip.
expect_fast ALLOW "many terraform output stages with options" \
    "$(printf 'terraform output -x 2>&1 -y|%.0s' {1..1400})true"
# A 64 KiB run of line continuations: the joined pre-check copy is built and matched.
expect_fast ALLOW "a long run of line continuations through the joined pre-check" \
    "echo $(printf 'a\\\n%.0s' {1..21800})"
# Quoted separators and continuations together: both texts get a dequoted and a masked copy.
expect_fast ALLOW "a long quoted run of separators and continuations through every copy" \
    "echo '$(printf 'a|\\\n%.0s' {1..16300})'"
# Many aws-vault exec words, each start scanning every word after it for a credential flag.
expect_fast ALLOW "many aws-vault exec words" "$(printf 'aws-vault exec p a %.0s' {1..1400})"
# Many terraform output words, each start trying every word after it as the one name.
expect_fast ALLOW "many terraform output words" "$(printf 'terraform output -state s x y %.0s' {1..1100})"
# Many registry-login and compose words behind one docker, each through the login walk.
expect_fast ALLOW "a docker stage of many option words" "docker $(printf -- '--config=/tmp/d -q %.0s' {1..2900})ps"
# Runner words at command position, each restarting the runner walk.
expect_fast DENY "many runner words" "$(printf 'docker exec c %.0s' {1..1900})env"
expect_fast DENY "many kubectl exec words" "$(printf 'kubectl exec p -- %.0s' {1..1400})env"
expect_fast DENY "many heroku run words" "$(printf 'heroku run a %.0s' {1..1900})env"
# One long interpreter option bundle with no value letter, searched for one.
expect_fast DENY "a long python3 option bundle fed a secret" "python3 -$(printf 's%.0s' {1..65000}) < .env"
expect_fast DENY "a long node option bundle fed a secret" "node -$(printf 's%.0s' {1..65000}) < .env"
expect_fast DENY "a long php option bundle fed a secret" "php -$(printf 's%.0s' {1..65000}) < .env"
big_rows
}

# big_rows: deep wildcards over a tree of about 40 000 entries, whose expansion takes seconds under bash 5's compgen:
# every expansion and the probe share the run-wide deadline, so each row is decided in time, holding an ask if cut.
big_rows() {
local RUN_CWD="$bigt"
expect_fast "DENY|ASK" "a deep wildcard over a large tree" 'cat */*/*/*'
expect_fast "DENY|ASK" "three deep wildcards over a large tree" 'cat */*/*/* d*/*/*/* */e*/*/*'
expect_fast "DENY|ASK" "a recursive grep of a deep directory wildcard" 'grep -rn KEY */*/*/'
expect_fast "DENY|ASK" "a deep wildcard piped into xargs grep -r" 'echo */*/*/* | xargs grep -rn KEY'
}

# Desktops and CI runners usually run a UTF-8 locale, and glibc's regex engine is many times slower in a multibyte
# locale than in C: time the rows under one whenever the system has one, whatever locale this suite was started in.
utf8_locale=""
for l in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
    if locale -a 2>/dev/null | grep -Fqx "$l"; then
        utf8_locale="$l"
        export LC_ALL="$l"
        break
    fi
done
if [[ -z "$utf8_locale" ]]; then
    echo "NOTE: none of C.UTF-8 or en_US.UTF-8 is installed, so the timing rows run in the session locale"
fi
tdir=$(mktemp -d)
for i in {1..64}; do mkdir "$tdir/d$i"; done
sl=$(printf '/%.0s' {1..4090})
xr="$(printf 'a%.0s' {1..20999})b"
xop=$(printf 'a%.0s' {1..42000})
cdl=$(printf '/abcdefghij%.0s' {1..370})
# 8 420 directories and 32 000 files, with one key deep inside.
bigt=$(mktemp -d)
mkdir -p "$bigt"/d{1..20}/e{1..20}/f{1..20}
(cd "$bigt" && touch d{1..20}/e{1..20}/f{1..20}/{a,b,c,d})
: >"$bigt/d20/e20/f20/k.pem"
timing_rows
# The hooks run under #!/usr/bin/env bash, which on a stock Mac is bash 3.2: time every row there too.
if [[ -x /bin/bash ]] && [[ "$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"')" == 3 ]]; then
    HOOK_BASH=/bin/bash
    timing_rows
    unset HOOK_BASH
fi

rm -rf "$pt" "$tdir" "$bigt" "$RUN_CWD"
echo "-----"; echo "passed: $pass  failed: $fail"; [ "$fail" -eq 0 ]
