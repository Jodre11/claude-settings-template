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

# scan_content_for_secrets: true positives
scan_content_for_secrets 'id=AKIAIOSFODNN7EXAMPLE end' >/dev/null \
    && ok "AWS access key detected" || bad "AWS access key missed"
scan_content_for_secrets '-----BEGIN RSA PRIVATE KEY-----' >/dev/null \
    && ok "private key header detected" || bad "private key header missed"
scan_content_for_secrets 'token ghp_012345678901234567890123456789abcdef' >/dev/null \
    && ok "github PAT detected" || bad "github PAT missed"

# scan_content_for_secrets: clean text is a true negative
if scan_content_for_secrets 'the quick brown fox jumped' >/dev/null; then
    bad "clean text wrongly flagged"
else
    ok "clean text not flagged"
fi

# redact_secrets: value removed, marker present
red=$(redact_secrets 'x AKIAIOSFODNN7EXAMPLE y')
[[ "$red" != *AKIAIOSFODNN7EXAMPLE* && "$red" == *"[REDACTED-SECRET-BREACH:aws-access-key]"* ]] \
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

# path_is_secret matches "/<path>" against "/"-adjusted globs; that must equal the direct rule, <path> or /<path>
# against the globs as written, with neither matching an allow glob.
shopt -s extglob
any=$(IFS='|'; printf '@(%s)' "${SECRET_PATH_GLOBS[*]}")
allow=$(IFS='|'; printf '@(%s)' "${SECRET_PATH_ALLOW[*]}")
drift=""
for p in config.env a/config.env .env x.env .env.x secrets secrets/a a/secrets a/secrets/b id_rsa a/id_rsa \
        .aws/credentials /h/.aws/credentials README.md a.pub x.env.example tmp/secrets.md '' / . .. a/proc/1/environ; do
    # shellcheck disable=SC2053
    if [[ ( "$p" == $any || "/$p" == $any ) && "$p" != $allow && "/$p" != $allow ]]; then want=0; else want=1; fi
    path_is_secret "$p" && got=0 || got=1
    [[ "$got" == "$want" ]] || drift+=" '$p'"
done
[[ -z "$drift" ]] && ok "path_is_secret equals the <path>-or-/<path> rule" || bad "path_is_secret drifted on:$drift"

# The glob list uses * as its only metacharacter, so a glob's literal pieces are plain text (SECRET_PATH_FRAGMENT_RE
# relies on it), and "/<instance>" of every glob holds one of the fragments.
odd=""
for g in "${SECRET_PATH_GLOBS[@]}"; do
    [[ "$g" == *[\?\[\]]* ]] && odd+=" $g"
done
[[ -z "$odd" ]] && ok "no secret path glob uses ? or [" || bad "secret path globs with ? or [:$odd"
missed=""
for g in "${SECRET_PATH_GLOBS[@]}"; do
    p="${g//\*/x}"
    awk -v p="/$p" -v frag="$SECRET_PATH_FRAGMENT_RE" 'BEGIN { exit !(p ~ frag) }' || missed+=" $p"
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
# A component holding ( fails closed: an extglob group inside repeating groups matches in exponential time.
path_glob_is_secret '*(q|z)' && ok "a component holding ( is treated as secret" \
    || bad "a component holding ( was matched"
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

# path_is_scan_exempt: firewall self-definition/test/doc files are exempt from
# output scanning (they embed example vectors by design); ordinary files are not.
for p in a/hooks/secret-patterns.sh b/hooks/secret-path-guard.test.sh docs/2026-07-12-secret-context-firewall-design.md /x/.superpowers/sdd/review.diff /y/.claude/breach-ledger.log; do
    path_is_scan_exempt "$p" && ok "scan-exempt: $p" || bad "scan NOT exempt (should be): $p"
done
for p in src/app.js README.md hooks/bash-guard.sh ''; do
    if path_is_scan_exempt "$p"; then bad "wrongly scan-exempt: '$p'"; else ok "scanned (not exempt): '$p'"; fi
done

echo "-----"; echo "passed: $pass  failed: $fail"; [ "$fail" -eq 0 ]
