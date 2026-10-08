#!/usr/bin/env bash
# Unit tests for secret-patterns.sh (recognition library).
# pipefail matches every real caller (secret-*-guard.sh, secret-output-scrubber.sh all set it before sourcing
# this library), so a pipeline bug that only manifests under pipefail is exercised here too.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/secret-patterns.sh"
pass=0; fail=0
ok()  { printf 'PASS: %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); }

# Secret-shaped fixtures are assembled at run time, so no line of this file matches a value pattern as written.
aws_key="AKIA""IOSFODNN7EXAMPLE"
gh_pat="ghp_""012345678901234567890123456789abcdef"
pk_head="-----BEG""IN RSA PRIVATE KEY-----"

# scan_content_for_secrets: true positives
scan_content_for_secrets "id=${aws_key} end" >/dev/null \
    && ok "AWS access key detected" || bad "AWS access key missed"
scan_content_for_secrets "$pk_head" >/dev/null \
    && ok "private key header detected" || bad "private key header missed"
scan_content_for_secrets "token ${gh_pat}" >/dev/null \
    && ok "github PAT detected" || bad "github PAT missed"

# scan_content_for_secrets: clean text is a true negative
if scan_content_for_secrets 'the quick brown fox jumped' >/dev/null; then
    bad "clean text wrongly flagged"
else
    ok "clean text not flagged"
fi

# redact_secrets: value removed, marker present
red=$(redact_secrets "x ${aws_key} y")
[[ "$red" != *"$aws_key"* && "$red" == *"[REDACTED-SECRET-BREACH:aws-access-key]"* ]] \
    && ok "AWS key redacted to marker" || bad "AWS key not redacted"

# redact_secrets over a transcript line: a PEM block is one JSON string there, its line breaks escaped as \n. The
# whole BEGIN…END block goes, body included; the text after it stays. Markers are built at run time.
pem_b="-----BEG""IN RSA PRIVATE KEY-----"
pem_e="-----E""ND RSA PRIVATE KEY-----"
line="{\"content\":\"k ${pem_b}\\nMIIEfakeBODY1\\nfakeBODY2==\\n${pem_e}\\n tail\"}"
red=$(redact_secrets "$line")
[[ "$red" == '{"content":"k [REDACTED-SECRET-BREACH:private-key]\n tail"}' ]] \
    && ok "a transcript PEM block is redacted whole" || bad "transcript PEM block not redacted whole: $red"

# scan_content_for_secrets: a secret near the TOP of a payload larger than the pipe buffer must still be
# detected. grep -Eq exits at the first match; the upstream printf then takes SIGPIPE on the data it has not
# yet written, and every caller runs under pipefail, which turns that SIGPIPE (141) into a false "clean" result.
# grep -E without -q reads all its input, so nothing is lost.
key="AKIA""IOSFODNN7EXAMPLE"
pad=$(printf '%0200000d' 0)
big="id=${key} end"$'\n'"${pad}"
start=$SECONDS
if scan_content_for_secrets "$big" >/dev/null; then
    ok "a secret on line 1 of a $(( ${#big} / 1024 )) KB payload is still detected"
else
    bad "a secret on line 1 of a large payload was missed (SIGPIPE false-clean)"
fi
elapsed=$((SECONDS - start))
[[ "$elapsed" -lt 5 ]] && ok "large-payload scan completes in ${elapsed}s" || bad "large-payload scan took ${elapsed}s"

# path_is_secret: strongbox convention + common secret files (incl. relative
# top-level 'secrets/…' and bare 'secrets' — the finding D gap where the leading
# '*/' variant did not match a path with no directory prefix).
for p in dev/secrets-manager/secrets/app.json prod/x/.strongbox-keyid config/app.pem .env creds.secret secrets/app.json secrets; do
    path_is_secret "$p" && ok "secret path blocked: $p" || bad "secret path missed: $p"
done

# path_is_secret: allowlisted / benign (src/notes/secrets.md must stay allowed —
# it is not inside a secrets/ directory; guards against over-matching the new
# relative globs).
for p in config.env.example settings.json.tmpl id_rsa.pub README.md src/notes/secrets.md; do
    if path_is_secret "$p"; then bad "benign path wrongly blocked: $p"; else ok "benign path allowed: $p"; fi
done

# A */X glob also covers the bare name X, and the allow list still applies to a bare name.
for p in config.env .netrc .pgpass id_rsa id_ed25519 .aws/credentials .strongbox-keyid /proc/self/environ \
        '$CLAUDE_SECRET_DIR' '$CLAUDE_SECRET_DIR/x.json' '${CLAUDE_SECRET_DIR}/x' /tmp/claude-abc-vault \
        /tmp/claude-abc-vault/ /tmp/claude-abc-vault/. /private/tmp/claude-abc-vault //tmp/claude-abc-vault; do
    path_is_secret "$p" && ok "bare or vault secret path blocked: $p" || bad "bare or vault secret path missed: $p"
done
for p in config.env.example x/.env.example id_rsa.pub credentials environ /tmp/claude-abc/notes.txt \
        /Users/x/Repos/claude-tools/modules/key-vault/main.tf; do
    if path_is_secret "$p"; then bad "benign bare path wrongly blocked: $p"; else ok "benign bare path allowed: $p"; fi
done

# A nested .env.* file is a secret path, as a root one is; the allow list still applies.
for p in config/.env.local /app/.env.production; do
    path_is_secret "$p" && ok "nested .env.* path blocked: $p" || bad "nested .env.* path missed: $p"
done
if path_is_secret config/.env.example; then
    bad "nested .env.example wrongly blocked"
else
    ok "nested .env.example allowed"
fi

# Every glob, with each * written as x, is a secret path: no allow glob cancels a whole secret glob.
for g in "${SECRET_PATH_GLOBS[@]}"; do
    p="${g//\*/x}"
    path_is_secret "$p" && ok "glob instance is secret: $p" || bad "glob instance not secret: $p"
done

# ascii_lower folds A-Z only, leaving every other character as it is.
ASCII_LOWER='not set'
ascii_lower 'CaT-9_X./Zz'
[[ "$ASCII_LOWER" == 'cat-9_x./zz' ]] && ok "ascii_lower folds A-Z" || bad "ascii_lower gave '$ASCII_LOWER'"
ascii_lower ''
[[ -z "$ASCII_LOWER" ]] && ok "ascii_lower of an empty word is empty" || bad "ascii_lower of '' gave '$ASCII_LOWER'"

# name_fold writes each non-ASCII letter that case-folds to ASCII as its fold (APFS opens creds.ſecret as
# creds.secret, and a ﬀ ligature as ff), leaving every other character as it is.
NAME_FOLD='not set'
fold_in=$'aſKßẞﬀﬁﬂﬃﬄﬅﬆ-Résumé-£5'
fold_want=$'askssssfffiflffifflstst-Résumé-£5'
name_fold "$fold_in"
[[ "$NAME_FOLD" == "$fold_want" ]] && ok "name_fold folds the ASCII-folding letters" \
    || bad "name_fold gave '$NAME_FOLD'"
name_fold 'plain/ascii.txt'
[[ "$NAME_FOLD" == 'plain/ascii.txt' ]] && ok "name_fold leaves ASCII as it is" || bad "name_fold gave '$NAME_FOLD'"

# Names compare case-insensitively: a case-insensitive file system (macOS, Windows) opens .ENV as .env, and git's
# icase pathspec magic folds case too. The allow list folds in the same way.
for p in .ENV Secrets/app.json a/.ssh/ID_RSA CONFIG.ENV x.PEM .Env.Local .AWS/Credentials a/.NetRC; do
    path_is_secret "$p" && ok "a secret path in another case blocked: $p" || bad "a secret path in another case missed: $p"
done
for p in .ENV.EXAMPLE ID_RSA.PUB README.MD; do
    if path_is_secret "$p"; then bad "a benign path in another case blocked: $p"; else
        ok "a benign path in another case allowed: $p"; fi
done
for g in "${SECRET_PATH_GLOBS[@]}"; do
    p="${g//\*/x}"
    path_is_secret "${p^^}" && ok "upper-case glob instance is secret: ${p^^}" \
        || bad "upper-case glob instance not secret: ${p^^}"
done

# path_is_secret matches "/<path>" against "/"-adjusted globs; that must equal the direct rule, <path> or /<path>
# against the globs as written, with neither matching an allow glob, every name compared case-insensitively.
shopt -s extglob
any=$(IFS='|'; printf '@(%s)' "${SECRET_PATH_GLOBS[*]}")
allow=$(IFS='|'; printf '@(%s)' "${SECRET_PATH_ALLOW[*]}")
drift=""
for p in config.env a/config.env .env x.env .env.x secrets secrets/a a/secrets a/secrets/b id_rsa a/id_rsa \
        .aws/credentials /h/.aws/credentials README.md a.pub x.env.example tmp/secrets.md '' / . .. a/proc/1/environ \
        CONFIG.ENV .Env SECRETS/a A/Id_Rsa X.PUB X.ENV.Example A/PROC/1/ENVIRON; do
    shopt -s nocasematch
    # shellcheck disable=SC2053
    if [[ ( "$p" == $any || "/$p" == $any ) && "$p" != $allow && "/$p" != $allow ]]; then want=0; else want=1; fi
    shopt -u nocasematch
    path_is_secret "$p" && got=0 || got=1
    [[ "$got" == "$want" ]] || drift+=" '$p'"
done
[[ -z "$drift" ]] && ok "path_is_secret equals the <path>-or-/<path> rule" || bad "path_is_secret drifted on:$drift"

# The glob list uses * as its only metacharacter, so a glob's literal pieces are plain text (SECRET_PATH_FRAGMENT_RE
# relies on it), and "/<instance>" of every glob, in either case and lowered as the tokeniser lowers it, holds one of
# the fragments.
odd=""
for g in "${SECRET_PATH_GLOBS[@]}"; do
    [[ "$g" == *[\?\[\]]* ]] && odd+=" $g"
done
[[ -z "$odd" ]] && ok "no secret path glob uses ? or [" || bad "secret path globs with ? or [:$odd"
missed=""
for g in "${SECRET_PATH_GLOBS[@]}"; do
    p="${g//\*/x}"
    for q in "$p" "${p^^}"; do
        awk -v p="/$q" -v frag="$SECRET_PATH_FRAGMENT_RE" 'BEGIN { exit !(tolower(p) ~ frag) }' || missed+=" $q"
    done
done
[[ -z "$missed" ]] && ok "every glob instance holds a fragment" || bad "glob instances with no fragment:$missed"

# path_glob_is_secret: a glob in the last component that matches a secret name.
# shellcheck disable=SC2088  # the ~ is the operand as written, unexpanded
for p in '.env*' 'config/*.env' '.en[v]' '~/.aws/cred*' 'x/*.pem' 'id_*' '.e*x'; do
    path_glob_is_secret "$p" && ok "secret glob operand blocked: $p" || bad "secret glob operand missed: $p"
done
for p in '*' '?*' '*.md' 'a*' 'docs/*.txt' 'notes.tx?'; do
    if path_glob_is_secret "$p"; then bad "benign glob wrongly blocked: $p"; else ok "benign glob allowed: $p"; fi
done
# A glob in another case matches a secret name too (git's icase pathspec magic folds case as it matches).
for p in '.EN?' 'ID_*' 'x/*.PEM' '.En[V]' 'CONFIG/*.Env'; do
    path_glob_is_secret "$p" && ok "a secret glob in another case blocked: $p" \
        || bad "a secret glob in another case missed: $p"
done
for p in '.E?(N|X)V' '(ICASE).ENV' '(top,icase).En?'; do
    if path_glob_is_secret "$p" remote; then ok "a remote group in another case is secret: $p"; else
        bad "a remote group in another case was missed: $p"; fi
done
if path_glob_is_secret 'README.M?'; then bad "a benign upper-case glob wrongly blocked"; else
    ok "a benign upper-case glob allowed"; fi

# The glob test is bounded: a component too long or too wildcarded, or a test past the per-run budget, is treated
# as secret without matching (fail closed); within the bound it is matched as before.
_SECRET_GLOB_TESTS=0
path_glob_is_secret '*a*b*c*d*e*f' && ok "a six-wildcard component is treated as secret" \
    || bad "a six-wildcard component was matched"
path_glob_is_secret "*$(printf 'a%.0s' {1..130})" && ok "a component over 128 characters is treated as secret" \
    || bad "a long component was matched"
if path_glob_is_secret '*a*b*c*d*e'; then bad "a five-wildcard component was not matched"; else
    ok "a five-wildcard component is still matched"; fi
# With a *, each [ counts with it: a bracket expression costs as much to match as a star. No representative matches
# these, so they are treated as secret only through the bound.
path_glob_is_secret '*[q]*[q]*[q]' && ok "three stars and three brackets are treated as secret" \
    || bad "a component of three stars and three brackets was matched"
if path_glob_is_secret '*[q]*[q]'; then bad "a four-wildcard bracketed component was not matched"; else
    ok "a four-wildcard bracketed component is still matched"; fi
# A bracket-only component matches in linear time, so its brackets are not counted.
if path_glob_is_secret '[0-9][0-9][0-9][0-9]-[0-9][0-9]'; then
    bad "a bracket-only date component was treated as secret"
else
    ok "a bracket-only date component is matched, not treated as secret"
fi
# A local operand's ( is literal (bash-guard denies an unquoted one) and no secret name holds one, so it cannot match.
for p in '*(q|z)' '*@(.env)' '.e?(v|x)' '[^;]{0,9}(a|b)' '.[] | select(.a == 1)' '[.x[] | select(.k == 1)]'; do
    if path_glob_is_secret "$p"; then bad "a local component holding ( was treated as secret: $p"; else
        ok "a local component holding ( is not secret: $p"; fi
done
# Inside a bracket expression a ( is a member, which fnmatch-style consumers match, so it does not make a component
# literal.
for p in '.en[v(]' '.e[(n]v' 'id_rs[(a]' '.en[!(]' '.en[v\](]' 'id_rs[\]a(]'; do
    if path_glob_is_secret "$p"; then ok "a bracket holding ( is still matched: $p"; else
        bad "a bracket holding ( was skipped: $p"; fi
done
# A remote shell may read a ( group in a host:path operand, so there the span from the first ( to the last ), with any
# extglob operator before it, is matched as a * (a superset of what any group matches; no exponential match), and a (
# alone makes the component a pattern.
for p in '*(q|z)' '*@(.env)' '.e?(v|x)' '.en@(v)' '.e(n|x)?' '.en+(v' 'id_r?(s|x)a' '@(.n)etrc' '?(.)pgpass' \
        '[.]e?(v|x)' '.e[)(]+(v)'; do
    if path_glob_is_secret "$p" remote; then ok "a remote group that could match a secret name is secret: $p"; else
        bad "a remote group that could match a secret name was missed: $p"; fi
done
for p in 'notes(1).txt' 'notes?(1).txt'; do
    if path_glob_is_secret "$p" remote; then bad "a remote group that cannot match was treated as secret: $p"; else
        ok "a remote group that cannot match a secret name is not secret: $p"; fi
done
_SECRET_GLOB_TESTS=$_SECRET_GLOB_BUDGET
path_glob_is_secret '*.md' && ok "a glob test past the budget is treated as secret" \
    || bad "a glob test past the budget was matched"
_SECRET_GLOB_TESTS=0

# path_is_secret joins each glob list into one @(…|…) pattern, so no glob may hold |, ( or ): one would split or close
# the alternation and change what it matches.
odd=""
for g in "${SECRET_PATH_GLOBS[@]}" "${SECRET_PATH_ALLOW[@]}"; do
    [[ "$g" == *[\|\(\)]* ]] && odd+=" $g"
done
[[ -z "$odd" ]] && ok "no secret path glob holds |, ( or )" || bad "secret path globs that break the alternation:$odd"

# path_is_scan_exempt: firewall self-definition and doc files are exempt from
# output scanning (they embed example vectors by design); test and ordinary files are not.
for p in a/hooks/secret-patterns.sh docs/2026-07-12-secret-context-firewall-design.md /x/.superpowers/sdd/review.diff /y/.claude/breach-ledger.log; do
    path_is_scan_exempt "$p" && ok "scan-exempt: $p" || bad "scan NOT exempt (should be): $p"
done
for p in src/app.js README.md hooks/bash-guard.sh b/hooks/secret-path-guard.test.sh ''; do
    if path_is_scan_exempt "$p"; then bad "wrongly scan-exempt: '$p'"; else ok "scanned (not exempt): '$p'"; fi
done

# Every firewall suite builds its secret-shaped fixtures at run time, so none holds one as written and the output
# scrubber need not skip them.
held=""
for f in "$DIR"/secret-*.test.sh; do
    if scan_content_for_secrets "$(cat "$f")" >/dev/null; then
        held+=" ${f##*/}"
    fi
done
[[ -z "$held" ]] && ok "no firewall suite holds a secret-shaped value as written" \
    || bad "firewall suites holding a secret-shaped value as written:$held"

# SSH private keys under any common name, the whole ~/.ssh directory but the client's own public files, and the
# credential files of registries, clusters, the GitHub CLI and package managers are secret paths.
for p in a/.ssh/id_ecdsa a/.ssh/id_dsa a/.ssh/id_ed25519_sk id_rsa_work a/.ssh/work_ed25519 a/.ssh/deploy_key x_rsa \
        x_dsa x_ecdsa a/.docker/config.json a/.config/containers/auth.json /run/user/501/containers/auth.json \
        a/.kube/config a/.config/gh/hosts.yml .git-credentials a/.git-credentials .npmrc a/.npmrc .pypirc \
        /proc/1/environ /proc/self/environ /proc/thread-self/environ /proc/self/task/1/environ \
        /proc/thread-self/task/1/environ /run/containers/0/auth.json; do
    path_is_secret "$p" && ok "credential path blocked: $p" || bad "credential path missed: $p"
done
for p in a/.ssh/id_ed25519.pub a/.ssh/known_hosts a/.ssh/known_hosts.old a/.ssh/config a/.ssh/authorized_keys \
        src/id_generator.py a/config.json a/auth.json a/.kube/cache/x a/.config/gh/config.yml \
        src/containers/auth.json src/proc/handlers/environ; do
    if path_is_secret "$p"; then bad "benign path wrongly blocked: $p"; else ok "benign path allowed: $p"; fi
done
# An allow glob never overrides a secret match for a path holding a .. segment: the segment can climb out of the
# allowed name into a secret one.
for p in a/.ssh/known_hosts/../id_rsa a/.ssh/known_hosts.x/../deploy_key a/b.pub/../.env a/.ssh/known_hosts.x \
        a/.ssh/known_hosts_backup; do
    path_is_secret "$p" && ok "traversal past an allow glob blocked: $p" \
        || bad "traversal past an allow glob missed: $p"
done

# The directory probe matches in awk: SECRET_PATH_AWK_RE and SECRET_ALLOW_AWK_RE, applied to "/<path>" lower-cased,
# decide exactly as path_is_secret does.
odd=""
for g in "${SECRET_PATH_GLOBS[@]}" "${SECRET_PATH_ALLOW[@]}"; do
    [[ "$g" == *[\+\^\\]* ]] && odd+=" $g"
done
[[ -z "$odd" ]] && ok "no path glob holds + ^ or \\" || bad "path globs the awk forms cannot carry:$odd"
drift=""
for g in "${SECRET_PATH_GLOBS[@]}" "${SECRET_PATH_ALLOW[@]}"; do
    p="${g//\*/x}"
    for q in "$p" "${p^^}" "a/$p" "/abs/$p"; do
        path_is_secret "$q" && want=0 || want=1
        LC_ALL=C awk -v p="/$q" -v s="$SECRET_PATH_AWK_RE" -v a="$SECRET_ALLOW_AWK_RE" \
            'BEGIN { t = tolower(p); exit !(t ~ s && t !~ a) }' && got=0 || got=1
        [[ "$got" == "$want" ]] || drift+=" '$q'"
    done
done
for q in README.md src/a.py .env.example x/.env.local '' / . .. a/proc/1/environ /tmp/claude-a-vault/secrets/g; do
    path_is_secret "$q" && want=0 || want=1
    LC_ALL=C awk -v p="/$q" -v s="$SECRET_PATH_AWK_RE" -v a="$SECRET_ALLOW_AWK_RE" \
        'BEGIN { t = tolower(p); exit !(t ~ s && t !~ a) }' && got=0 || got=1
    [[ "$got" == "$want" ]] || drift+=" '$q'"
done
[[ -z "$drift" ]] && ok "the awk glob forms agree with path_is_secret" || bad "the awk glob forms drift on:$drift"
n=0
for s in "${_NAME_FOLDS[@]}"; do n=$(( n + 1 )); done
IFS=$'\x1f' read -r -a folds <<< "$SECRET_FOLDS_AWK"
[[ "${#folds[@]}" == "$n" ]] && ok "SECRET_FOLDS_AWK carries every fold pair" \
    || bad "SECRET_FOLDS_AWK holds ${#folds[@]} of $n fold entries"

# dir_is_secret: a directory that is secret, or that holds a directory-named secret (credentials under .aws, anything
# under secrets, .ssh or the vault), or above one by a literal path (gh/hosts.yml under .config). An anywhere-name
# (.env, *.pem) does not make every directory secret.
for d in '~/.aws' a/.ssh secrets a/secrets/ /tmp/claude-abc-vault /tmp/claude-abc-vault/secrets '$CLAUDE_SECRET_DIR' \
        /proc/1 a/.kube a/.docker a/.config/gh a/.config/containers a/.config /run/user/501/containers; do
    dir_is_secret "$d" && ok "a secret directory: $d" || bad "a secret directory missed: $d"
done
for d in src /tmp '~' / . .. src/containers src/containers/Foo src/proc/handlers; do
    if dir_is_secret "$d"; then bad "a plain directory counted as secret: $d"; else ok "a plain directory: $d"; fi
done
# near: only a secret directly in the directory counts.
dir_is_secret a/.aws near && ok "near: a/.aws holds a secret directly" || bad "near: a/.aws missed"
for d in a/.config src/proc; do
    if dir_is_secret "$d" near; then bad "near: $d counted as secret"; else ok "near: $d holds none directly"; fi
done

echo "-----"; echo "passed: $pass  failed: $fail"; [ "$fail" -eq 0 ]
