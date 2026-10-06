#!/usr/bin/env bash
set -u
HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/secret-bash-guard.sh"
pass=0; fail=0
ok()  { printf 'PASS: %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); }
run() {  # run <cmd>: DENY, ASK (the hook failed to evaluate) or ALLOW; HOOK_BASH, when set, runs the hook
    local out
    out=$(jq -nc --arg c "$1" '{tool_input:{command:$c}}' | ${HOOK_BASH:+"$HOOK_BASH"} "$HOOK")
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

# expect_fast <DENY|ALLOW> <description> <cmd>: pass when the hook decides <cmd> as expected within TIME_LIMIT_MS in
# one of TIME_RUNS runs; a wrong verdict or a run of TIME_HARD_MS or more fails at once.
expect_fast() {
    local got start elapsed i times="" under="${HOOK_BASH:+, $HOOK_BASH}${LC_ALL:+, LC_ALL=$LC_ALL}"
    for (( i = 1; i <= TIME_RUNS; i++ )); do
        start=$(_ms)
        got=$(run "$3")
        elapsed=$(( $(_ms) - start ))
        times+="${times:+, }${elapsed}"
        if [[ "$got" != "$1" ]] || (( elapsed >= TIME_HARD_MS || ${#3} > 65536 )); then
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
timing_rows
# The hooks run under #!/usr/bin/env bash, which on a stock Mac is bash 3.2: time every row there too.
if [[ -x /bin/bash ]] && [[ "$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"')" == 3 ]]; then
    HOOK_BASH=/bin/bash
    timing_rows
    unset HOOK_BASH
fi

echo "-----"; echo "passed: $pass  failed: $fail"; [ "$fail" -eq 0 ]
