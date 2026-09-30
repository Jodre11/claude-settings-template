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
