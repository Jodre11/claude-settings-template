#!/usr/bin/env bash
# Tests for the commit side of the git leak guards: .githooks/pre-commit, the local pattern lists it reads,
# .gitleaks.toml, and the CI check scripts under tests/ that keep them consistent. The helpers and fixtures are in
# tests/guard-test-lib.sh, so this file carries no literal the guards flag. Bash 3.2 compatible.
# Run: bash tests/test-git-guards.sh
# shellcheck disable=SC2154  # the fixtures, rc, out, repo_root and tmp come from guard-test-lib.sh
set -euo pipefail
# shellcheck source=guard-test-lib.sh
source "$(dirname "$0")/guard-test-lib.sh"

# --- git runs a hook only when it is executable, and skips it silently otherwise
check "the pre-commit hook is executable" yes \
    "$(if [[ -x "$repo_root/.githooks/pre-commit" ]]; then echo yes; else echo no; fi)"

# --- pre-commit: where the pattern scan bites
try notes.md "see $word"
check "pre-commit rejects an identity word in an ordinary file" 1 "$rc"
check_match "the rejection comes from the pattern scan" 'sensitive pattern detected' "$out"
try README.md "see $word"
check "pre-commit rejects an identity word in README.md" 1 "$rc"
try config.env.example "SSO_START_URL=  # e.g. see $word"
check "pre-commit rejects an identity word in config.env.example" 1 "$rc"
for sample in "${exempt_samples[@]}"; do
    try "$sample" "see $word"
    check "pre-commit applies IDENTITY_EXEMPT_RE to $sample" "$(exempt_rc "$sample" "$IDENTITY_EXEMPT_RE")" "$rc"
done
try "$memory" "account \`$digits\`"
check_match "a secret-shaped value bites under a memory path" 'sensitive pattern detected' "$out"
try notes.md "see $lower_handle"
check_match "pre-commit matches identity case-insensitively" 'sensitive pattern detected' "$out"
try notes.md "$(printf 'account %013d' 42)"
check "pre-commit allows a 13-digit number after the word account" 0 "$rc"
try config.env.example "ECR_REGISTRY=  # e.g. $placeholder.dkr.ecr.eu-west-1.amazonaws.com"
check "pre-commit allows the AWS documentation account ID" 0 "$rc"
try .githooks/guard-config.sh "# see $word"
check "pre-commit skips the file that defines the patterns" 0 "$rc"
try .githooks/pre-commit "# see $word"
check "pre-commit skips the hook that defined the patterns before guard-config.sh" 0 "$rc"
firewall=hooks/secret-x.test.sh
if [[ -n "$ALWAYS_EXEMPT_RE" && "$firewall" =~ $ALWAYS_EXEMPT_RE ]]; then
    firewall_rc=0
else
    firewall_rc=1
fi
try "$firewall" "account \`$digits\`"
check "pre-commit applies ALWAYS_EXEMPT_RE to a secret-firewall test file" "$firewall_rc" "$rc"
try "$firewall" "see $word"
check "identity still bites in a secret-firewall test file" 1 "$rc"

# --- pre-commit: fingerprint forms
for line in "account \`$digits\`" "the account (\`$digits\`)" "aws_account:$digits" "arn:aws:iam::$digits:role/x" \
    "arn:aws-cn:iam::$digits:role/x" "$digits (prod account)" "$profile" "export $nuget=x"; do
    try notes.md "$line"
    check_match "pre-commit flags '$line'" 'sensitive pattern detected' "$out"
done
utf8_line=$(printf 'account \342\200\234prod\342\200\235 \342\200\224 \342\200\234live\342\200\235 \342\200\224 %s' \
    "$digits")
try notes.md "$utf8_line"
check_match "pre-commit counts characters, not bytes, between the word account and an account ID" \
    'sensitive pattern detected' "$out"

# --- the bypass split: every tracked pattern is mirrored in .gitleaks.toml, so the bypass only lifts the local lists
try_listed identity "$local_word" notes.md "see $local_word" SKIP_PATTERN_SCAN=1
check "SKIP_PATTERN_SCAN=1 skips the pattern scan" 0 "$rc"
check_match "the bypass is announced" 'skipping the pattern scan; gitleaks still runs' "$out"
try_listed identity "$local_word" notes.md "see $local_word" SKIP_SECRET_SCAN=1
check "the retired SKIP_SECRET_SCAN bypasses nothing" 1 "$rc"
if have_gitleaks "gitleaks row of the bypass split"; then
    try notes.md "see $word" SKIP_PATTERN_SCAN=1
    check "gitleaks still catches a tracked identity pattern under SKIP_PATTERN_SCAN=1" 1 "$rc"
    check_match "that refusal comes from gitleaks" 'There is no bypass' "$out"
fi

# --- local pattern lists
try notes.md "see $local_word"
check "a word no list holds commits" 0 "$rc"
try_listed identity "$local_word" notes.md "see $local_word"
check "pre-commit rejects a word from identity-patterns.local" 1 "$rc"
check_match "the local-list rejection comes from the pattern scan" 'sensitive pattern detected' "$out"
for sample in "${exempt_samples[@]}"; do
    try_listed identity "$local_word" "$sample" "see $local_word"
    check "identity-patterns.local follows LOCAL_IDENTITY_EXEMPT_RE at $sample" \
        "$(exempt_rc "$sample" "$LOCAL_IDENTITY_EXEMPT_RE")" "$rc"
done
try_listed identity "$local_word" README.md "SEE $(printf '%s' "$local_word" | tr '[:lower:]' '[:upper:]')"
check "identity-patterns.local matches case-insensitively" 1 "$rc"
try_listed always "$local_id" notes.md "profile|$local_id|role"
check "pre-commit rejects a literal from always-patterns.local" 1 "$rc"
try_listed always "$local_id" "$memory" "profile|$local_id|role"
check "always-patterns.local bites under a memory path" 1 "$rc"
try_listed always "$local_id" "$firewall" "profile|$local_id|role"
check "always-patterns.local bites in a secret-firewall test file" 1 "$rc"
d=$(new_repo)
printf '%s\r\n' '# a comment' "$local_word" >"$d/.githooks/identity-patterns.local"
commit_line "$d" notes.md "see $local_word"
check "pre-commit reads a CRLF local list" 1 "$rc"
d=$(new_repo)
printf '%s\n' "$local_word" >"$tmp/outside-list.txt"
ln -s "$tmp/outside-list.txt" "$d/.githooks/identity-patterns.local"
commit_line "$d" notes.md "see $local_word"
check "pre-commit reads a local list through a symlink" 1 "$rc"
d=$(new_repo)
ln -s "$tmp/no-such-list.txt" "$d/.githooks/identity-patterns.local"
commit_line "$d" notes.md "clean line"
check "pre-commit fails closed on a dangling local-list symlink" 1 "$rc"
check_match "the failure names the unreadable list" 'not a readable file' "$out"
d=$(new_repo)
with_list "$d" always '# only a comment'
commit_line "$d" notes.md "clean line"
check "pre-commit fails closed on a local list with no pattern" 1 "$rc"
check_match "the failure says the list holds no pattern" 'holds no pattern' "$out"
for entry in 'a\sb' 'a\db' '(?:ab)'; do
    d=$(new_repo)
    with_list "$d" identity "$entry"
    commit_line "$d" notes.md "clean line"
    check "pre-commit fails closed on the local pattern $entry" 1 "$rc"
done
d=$(new_repo)
with_list "$d" identity '(unbalanced'
commit_line "$d" notes.md "clean line"
check "pre-commit fails closed on a local pattern awk cannot compile" 1 "$rc"
d=$(new_repo)
printf '%s\n' "IDENTITY_PATTERNS+=('a\\sb')" >>"$d/.githooks/guard-config.sh"
commit_line "$d" notes.md "clean line"
check "pre-commit fails closed on a tracked pattern awk cannot match as written" 1 "$rc"
for name in identity-patterns.local always-patterns.local Identity-Patterns.local; do
    d=$(new_repo)
    printf 'x\n' >"$d/.githooks/$name"
    git -C "$d" add -f -- ".githooks/$name"
    commit_staged "$d" SKIP_PATTERN_SCAN=1
    check "pre-commit refuses to commit .githooks/$name, even with the bypass" 1 "$rc"
    check_match "the refusal names the local list" 'machine-local pattern list' "$out"
done

# --- gitleaks: no bypass, built-ins on, targeted allowlists
if have_gitleaks "gitleaks rows"; then
    try notes.md "aws $key" SKIP_PATTERN_SCAN=1
    check "gitleaks still runs under SKIP_PATTERN_SCAN=1" 1 "$rc"
    check_match "the gitleaks rejection says there is no bypass" 'There is no bypass' "$out"
    try notes.md "aws $key # gitleaks:allow" SKIP_PATTERN_SCAN=1
    check "an inline gitleaks:allow comment does not silence gitleaks" 1 "$rc"
    for path in "$memory" README.md config.env.example .githooks/guard-config.sh; do
        check_match "gitleaks built-ins flag a dummy AWS key in $path" aws-access-token "$(scan_ids "$path" "aws $key")"
    done
    check "gitleaks flags an identity word in an ordinary file" org-name "$(scan_ids notes.md "see $word")"
    for sample in "${exempt_samples[@]}"; do
        if [[ "$(exempt_rc "$sample" "$IDENTITY_EXEMPT_RE")" == 0 ]]; then
            check "gitleaks allows an identity word where the hooks do: $sample" "" \
                "$(scan_ids "$sample" "see $word")"
        else
            check "gitleaks flags an identity word where the hooks do: $sample" org-name \
                "$(scan_ids "$sample" "see $word")"
        fi
    done
    check "gitleaks flags an account ID under a memory path" org-aws-account-context \
        "$(scan_ids "$memory" "account \`$digits\`")"
    check "gitleaks flags the backtick account form" org-aws-account-context \
        "$(scan_ids notes.md "state lives in account \`$digits\`")"
    check "gitleaks flags the parenthesised account form" org-aws-account-context \
        "$(scan_ids notes.md "the account (\`$digits\`)")"
    check "gitleaks flags the aws_account: form" org-aws-account-context "$(scan_ids notes.md "aws_account:$digits")"
    check "gitleaks flags an ARN carrying an account ID" org-aws-arn-account \
        "$(scan_ids notes.md "arn:aws:iam::$digits:role/x")"
    check "gitleaks flags an ARN in another partition" org-aws-arn-account \
        "$(scan_ids notes.md "arn:aws-cn:iam::$digits:role/x")"
    check "gitleaks flags digits before the word account" org-aws-account-context-trailing \
        "$(scan_ids notes.md "$digits (prod account)")"
    check "gitleaks flags an inference profile ID" org-bedrock-arn-fragment "$(scan_ids notes.md "$profile")"
    check "gitleaks flags the NuGet PAT name" org-nuget-pat "$(scan_ids notes.md "export $nuget=x")"
    check "gitleaks allows a 13-digit number after the word account" "" \
        "$(scan_ids notes.md "$(printf 'account %013d' 42)")"
    check "gitleaks allows the AWS documentation account ID" "" \
        "$(scan_ids notes.md "ECR_REGISTRY=  # e.g. $placeholder.dkr.ecr.eu-west-1.amazonaws.com")"
    check "gitleaks flags the handle in lower case" personal-identity "$(scan_ids notes.md "see $lower_handle")"
    check "gitleaks flags an upper-case ARN carrying an account ID" org-aws-arn-account \
        "$(scan_ids notes.md "ARN:AWS:IAM::$digits:role/x")"
    check "gitleaks flags an upper-case inference profile ID" org-bedrock-arn-fragment \
        "$(scan_ids notes.md "APPLICATION-INFERENCE-PROFILE/$(printf '%s%s' ABCDEF 012345)")"
fi

# --- pre-commit: diff parsing
try notes.md "++ $word"
check_match "pre-commit scans an added line that starts with ++" 'sensitive pattern detected' "$out"
d=$(new_repo)
commit_line "$d" "$exempt_path" "see $word"
check "the exempt path's commit lands first" "$exempt_path_rc" "$rc"
git -C "$d" mv "$exempt_path" notes.md
commit_staged "$d"
check_match "pre-commit scans a file renamed out of an exempt path" 'sensitive pattern detected' "$out"

# --- pre-commit: the path comes from +++ b/, and the scan reads the committed bytes
try "docs/x b/$exempt_path" "see $word"
check_match "a path containing ' b/' cannot spoof an exemption" 'sensitive pattern detected' "$out"
try "projects/p/memory/a\"b.md" "see $word"
check_match "a path git quotes gets no exemption" 'sensitive pattern detected' "$out"
try "$(printf 'caf\303\251').md" "see $word"
check_match "a non-ASCII path is scanned" 'sensitive pattern detected' "$out"
try "my notes.md" "see $word"
check_match "a rejected path containing a space prints with no trailing TAB" 'my notes\.md: \+see' "$out"
try notes.md "$(printf '++ b/%s\n%s' "$exempt_path" "see $word")"
check_match "an added line shaped like a +++ header does not switch the path" 'sensitive pattern detected' "$out"
d=$(new_repo)
commit_line "$d" notes.md "clean line"
rm "$d/notes.md"
ln -s "see $word" "$d/notes.md"
git -C "$d" add notes.md
commit_staged "$d"
check_match "pre-commit scans a file turned into a symlink" 'sensitive pattern detected' "$out"
d=$(new_repo)
printf 'bin\000ary see %s\n' "$word" >"$d/blob.bin"
git -C "$d" add blob.bin
commit_staged "$d"
check_match "pre-commit scans past a NUL byte" 'sensitive pattern detected' "$out"
d=$(new_repo)
printf '*.dat binary\n' >"$d/.gitattributes"
printf 'see %s\n' "$word" >"$d/k.dat"
git -C "$d" add .gitattributes k.dat
commit_staged "$d"
check_match "pre-commit scans a file marked binary" 'sensitive pattern detected' "$out"
d=$(new_repo)
printf 'conv.txt diff=hide\n' >"$d/.gitattributes"
git -C "$d" config diff.hide.textconv true
printf 'see %s\n' "$word" >"$d/conv.txt"
git -C "$d" add .gitattributes conv.txt
commit_staged "$d"
check_match "pre-commit scans past a textconv filter" 'sensitive pattern detected' "$out"
d=$(new_repo)
printf 'see %s\n' "$word" | iconv -f UTF-8 -t UTF-16LE >"$d/wide.txt"
git -C "$d" add wide.txt
commit_staged "$d"
check_match "pre-commit scans UTF-16 text" 'sensitive pattern detected' "$out"
d=$(new_repo)
printf '\211PNG\r\n\032\n\377\376\n' >"$d/icon.png"
git -C "$d" add icon.png
commit_staged "$d"
check "pre-commit accepts a clean binary holding non-UTF-8 bytes" 0 "$rc"
d=$(new_repo)
printf '\377\376 see %s\n' "$word" >"$d/blob2.bin"
git -C "$d" add blob2.bin
commit_staged "$d"
check_match "pre-commit scans a binary holding non-UTF-8 bytes" 'sensitive pattern detected' "$out"

# --- pre-commit: the scanned diff format is pinned against colour, external-diff and prefix settings
for setting in "color.ui always" "color.diff always" "diff.external true" "diff.mnemonicPrefix true" \
    "diff.noprefix true" "diff.dstPrefix x/" "diff.dstPrefix x/y/"; do
    read -r cfg_key cfg_value <<<"$setting"
    d=$(new_repo)
    git -C "$d" config "$cfg_key" "$cfg_value"
    commit_line "$d" notes.md "see $word"
    check_match "the pattern scan still bites under $setting" 'sensitive pattern detected' "$out"
    d=$(new_repo)
    git -C "$d" config "$cfg_key" "$cfg_value"
    commit_line "$d" "$exempt_path" "see $word"
    check "an exempt path keeps its exemption under $setting" "$exempt_path_rc" "$rc"
    if have_gitleaks "gitleaks under $setting"; then
        d=$(new_repo)
        git -C "$d" config "$cfg_key" "$cfg_value"
        commit_line "$d" notes.md "aws $key" SKIP_PATTERN_SCAN=1
        check "gitleaks still bites under $setting" 1 "$rc"
    fi
done
try notes.md "see $word" "GIT_CONFIG_PARAMETERS='color.ui'='always'"
check_match "the pattern scan still bites under git -c color.ui=always" 'sensitive pattern detected' "$out"
if have_gitleaks "gitleaks under git -c color.ui=always"; then
    try notes.md "aws $key" SKIP_PATTERN_SCAN=1 "GIT_CONFIG_PARAMETERS='color.ui'='always'"
    check "gitleaks still bites under git -c color.ui=always" 1 "$rc"
fi

# --- pre-commit gitleaks: only the staged config decides the scan, and content gitleaks cannot diff is scanned
if have_gitleaks "gitleaks staged-config and opaque-blob rows"; then
    d=$(new_repo)
    printf 'aws %s\n' "$key" >"$d/notes.md"
    git -C "$d" add notes.md
    printf '%s\n' notes.md:aws-access-token:1 >"$d/.gitleaksignore"
    commit_staged "$d" SKIP_PATTERN_SCAN=1
    check "an untracked .gitleaksignore cannot silence gitleaks" 1 "$rc"
    check_match "the refusal names the unstaged file" 'differs from its staged copy' "$out"
    d=$(new_repo)
    printf '%s\n' '' '[[allowlists]]' "paths = ['''^notes\\.md\$''']" >>"$d/.gitleaks.toml"
    printf 'aws %s\n' "$key" >"$d/notes.md"
    git -C "$d" add notes.md
    commit_staged "$d" SKIP_PATTERN_SCAN=1
    check "an unstaged .gitleaks.toml allowlist cannot silence gitleaks" 1 "$rc"
    d=$(new_repo)
    commit_line "$d" .gitleaksignore '# baseline'
    git -C "$d" update-index --skip-worktree .gitleaksignore
    printf '%s\n' notes.md:aws-access-token:1 >>"$d/.gitleaksignore"
    printf 'aws %s\n' "$key" >"$d/notes.md"
    git -C "$d" add notes.md
    commit_staged "$d" SKIP_PATTERN_SCAN=1
    check "a skip-worktree .gitleaksignore edit cannot silence gitleaks" 1 "$rc"
    d=$(new_repo)
    commit_line "$d" .gitleaksignore '# baseline'
    rm "$d/.gitleaksignore"
    commit_line "$d" notes.md "clean line"
    check "a .gitleaksignore deleted but not staged stops the commit" 1 "$rc"
    d=$(new_repo)
    commit_line "$d" .gitleaksignore '# baseline'
    check "a staged .gitleaksignore change commits" 0 "$rc"
    d=$(new_repo)
    sed -i.bak -e 's/^useDefault = true$/path = "local.toml"/' "$d/.gitleaks.toml"
    rm "$d/.gitleaks.toml.bak"
    git -C "$d" add .gitleaks.toml
    printf '%s\n' '[extend]' 'useDefault = true' '' '[[allowlists]]' "paths = ['''^notes\\.md\$''']" >"$d/local.toml"
    printf 'aws %s\n' "$key" >"$d/notes.md"
    git -C "$d" add notes.md
    commit_staged "$d" SKIP_PATTERN_SCAN=1
    check "a staged [extend] path cannot hand the scan to a working-tree file" 1 "$rc"
    check_match "the refusal names the [extend] table" '\[extend\]' "$out"
    d=$(new_repo)
    sed -i.bak -e 's/^\[extend\]$/extend = { path = "local.toml" }/' -e '/^useDefault = true$/d' "$d/.gitleaks.toml"
    rm "$d/.gitleaks.toml.bak"
    git -C "$d" add .gitleaks.toml
    printf '%s\n' '[extend]' 'useDefault = true' '' '[[allowlists]]' "paths = ['''^notes\\.md\$''']" >"$d/local.toml"
    printf 'aws %s\n' "$key" >"$d/notes.md"
    git -C "$d" add notes.md
    commit_staged "$d" SKIP_PATTERN_SCAN=1
    check "an inline extend table cannot hand the scan to a working-tree file" 1 "$rc"
    d=$(new_repo)
    sed -i.bak -e 's/^\[extend\]$/[EXTEND]/' -e 's/^useDefault = true$/path = "local.toml"/' "$d/.gitleaks.toml"
    rm "$d/.gitleaks.toml.bak"
    git -C "$d" add .gitleaks.toml
    printf '%s\n' '[extend]' 'useDefault = true' '' '[[allowlists]]' "paths = ['''^notes\\.md\$''']" >"$d/local.toml"
    printf 'aws %s\n' "$key" >"$d/notes.md"
    git -C "$d" add notes.md
    commit_staged "$d" SKIP_PATTERN_SCAN=1
    check "an upper-case extend table cannot hand the scan to a working-tree file" 1 "$rc"
    d=$(new_repo)
    sed -i.bak -e 's/^useDefault = true$/disabledRules = [""""]\
[x]\
"""]\
path = "local.toml"/' "$d/.gitleaks.toml"
    rm "$d/.gitleaks.toml.bak"
    git -C "$d" add .gitleaks.toml
    printf '%s\n' '[extend]' 'useDefault = true' '' '[[allowlists]]' "paths = ['''^notes\\.md\$''']" >"$d/local.toml"
    printf 'aws %s\n' "$key" >"$d/notes.md"
    git -C "$d" add notes.md
    commit_staged "$d" SKIP_PATTERN_SCAN=1
    check "a multi-line string cannot hide a later extend path" 1 "$rc"
    d=$(new_repo)
    sed -i.bak -e 's/^\[extend\]$/["\\u0065xtend"]/' -e 's/^useDefault = true$/path = "local.toml"/' "$d/.gitleaks.toml"
    rm "$d/.gitleaks.toml.bak"
    git -C "$d" add .gitleaks.toml
    printf '%s\n' '[extend]' 'useDefault = true' '' '[[allowlists]]' "paths = ['''^notes\\.md\$''']" >"$d/local.toml"
    printf 'aws %s\n' "$key" >"$d/notes.md"
    git -C "$d" add notes.md
    commit_staged "$d" SKIP_PATTERN_SCAN=1
    check "an escaped extend key cannot hand the scan to a working-tree file" 1 "$rc"
    d=$(new_repo)
    printf '# aws %s\n' "$key" >>"$d/.gitleaks.toml"
    git -C "$d" add .gitleaks.toml
    commit_staged "$d"
    check "gitleaks scans a staged .gitleaks.toml with its built-in rules" 1 "$rc"
    d=$(new_repo)
    commit_line "$d" docs/old-gitleaks.toml.md "aws $key"
    check "the built-ins pass flags a key in a path gitleaks' default allowlist would skip" 1 "$rc"
    d=$(new_repo)
    commit_line "$d" docs/old-gitleaks.toml.md "see $word" SKIP_PATTERN_SCAN=1
    check "gitleaks scans a path its default allowlist would skip" 1 "$rc"
    d=$(new_repo)
    printf '# note\n' >>"$d/.gitleaks.toml"
    git -C "$d" add .gitleaks.toml
    commit_staged "$d"
    check "a clean edit to .gitleaks.toml commits" 0 "$rc"

    d=$(new_repo)
    printf 'bin\000ary aws %s\n' "$key" >"$d/blob.bin"
    git -C "$d" add blob.bin
    commit_staged "$d" SKIP_PATTERN_SCAN=1
    check "gitleaks flags a key in a binary file" 1 "$rc"
    check_match "the refusal explains the direct scan" 'scanned its staged content directly' "$out"
    d=$(new_repo)
    printf '*.dat binary\n' >"$d/.gitattributes"
    printf 'aws %s\n' "$key" >"$d/k.dat"
    git -C "$d" add .gitattributes k.dat
    commit_staged "$d" SKIP_PATTERN_SCAN=1
    check "gitleaks flags a key in a file marked binary" 1 "$rc"
    d=$(new_repo)
    printf 'conv.txt diff=hide\n' >"$d/.gitattributes"
    git -C "$d" config diff.hide.textconv true
    printf 'aws %s\n' "$key" >"$d/conv.txt"
    git -C "$d" add .gitattributes conv.txt
    commit_staged "$d" SKIP_PATTERN_SCAN=1
    check "gitleaks flags a key behind a staged textconv attribute" 1 "$rc"
    d=$(new_repo)
    printf 'conv.txt diff=hide\n' >"$d/.gitattributes"
    git -C "$d" config diff.hide.textconv true
    printf 'aws %s\n' "$key" >"$d/conv.txt"
    git -C "$d" add conv.txt
    commit_staged "$d" SKIP_PATTERN_SCAN=1
    check "gitleaks flags a key behind an unstaged textconv attribute" 1 "$rc"
    d=$(new_repo)
    printf 'conv.txt diff=set\n' >"$d/.gitattributes"
    git -C "$d" config diff.set.textconv true
    printf 'aws %s\n' "$key" >"$d/conv.txt"
    git -C "$d" add .gitattributes conv.txt
    commit_staged "$d" SKIP_PATTERN_SCAN=1
    check "gitleaks flags a key behind a textconv driver named set" 1 "$rc"
    d=$(new_repo)
    printf 'aws %s\n' "$key" | iconv -f UTF-8 -t UTF-16LE >"$d/wide.txt"
    git -C "$d" add wide.txt
    commit_staged "$d" SKIP_PATTERN_SCAN=1
    check "gitleaks flags a key in UTF-16 text" 1 "$rc"
    d=$(new_repo)
    printf 'PNG\000\001\002\003 clean header\n' >"$d/clean.bin"
    git -C "$d" add clean.bin
    commit_staged "$d"
    check "a clean binary file commits" 0 "$rc"
    d=$(new_repo)
    printf '\211PNG\r\n\032\n\377\376\000\n' >"$d/icon.png"
    git -C "$d" add icon.png
    commit_staged "$d"
    check "a clean binary holding non-UTF-8 bytes passes the opaque-blob scan" 0 "$rc"
    d=$(new_repo)
    mkdir -p "$d/projects/p/memory"
    printf 'bin\000ary see %s\n' "$word" >"$d/projects/p/memory/m.bin"
    git -C "$d" add projects/p/memory/m.bin
    commit_staged "$d" SKIP_PATTERN_SCAN=1
    check_match "a binary file is scanned with no path allowlist" 'scanned its staged content directly' "$out"
    d=$(new_repo)
    printf 'wide.txt diff\n' >"$d/.gitattributes"
    printf 'aws %s\n' "$key" | iconv -f UTF-8 -t UTF-16LE >"$d/wide.txt"
    git -C "$d" add .gitattributes wide.txt
    commit_staged "$d" SKIP_PATTERN_SCAN=1
    check "gitleaks flags a key in UTF-16 text behind a bare diff attribute" 1 "$rc"
    d=$(new_repo)
    printf 'blob.bin diff\n' >"$d/.gitattributes"
    printf 'bin\000ary aws %s\n' "$key" >"$d/blob.bin"
    git -C "$d" add .gitattributes blob.bin
    commit_staged "$d" SKIP_PATTERN_SCAN=1
    check "gitleaks flags a key after a NUL byte behind a bare diff attribute" 1 "$rc"
    d=$(new_repo)
    printf 'blob.bin diff=forcetext\n' >"$d/.gitattributes"
    git -C "$d" config diff.forcetext.binary false
    printf 'bin\000ary aws %s\n' "$key" >"$d/blob.bin"
    git -C "$d" add .gitattributes blob.bin
    commit_staged "$d" SKIP_PATTERN_SCAN=1
    check "gitleaks flags a key behind a driver that forces a text diff" 1 "$rc"
    d=$(new_repo)
    printf 'conv.txt diff=hide\n' >"$d/.gitattributes"
    git -C "$d" config diff.hide.textconv true
    printf 'see %s\n' "$word" >"$d/conv.txt"
    git -C "$d" add conv.txt
    commit_staged "$d" SKIP_PATTERN_SCAN=1 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=attr.tree GIT_CONFIG_VALUE_0=HEAD
    check "gitleaks flags an identity word behind a textconv attribute under a caller's attr.tree" 1 "$rc"
    d=$(new_repo)
    git -C "$d" config core.bigFileThreshold 16
    printf 'see %s in a file over the threshold\n' "$word" >"$d/big.txt"
    git -C "$d" add big.txt
    commit_staged \
        "$d" \
        SKIP_PATTERN_SCAN=1 \
        GIT_CONFIG_COUNT=1 \
        GIT_CONFIG_KEY_0=core.bigFileThreshold \
        GIT_CONFIG_VALUE_0=1g
    check "gitleaks flags an identity word the caller's bigFileThreshold would hide" 1 "$rc"
    d=$(new_repo)
    commit_line "$d" "$exempt_path" "see $word" SKIP_PATTERN_SCAN=1
    git -C "$d" mv "$exempt_path" notes.md
    commit_staged "$d" SKIP_PATTERN_SCAN=1
    check "gitleaks rescans content renamed out of an allowlisted path" 1 "$rc"
    d=$(new_repo)
    printf 'PNG\000clean\n' >"$d/x.bin"
    git -C "$d" add x.bin
    commit_staged "$d"
    printf 'bin\000ary see %s\n' "$word" >"$d/0:x.bin"
    git -C "$d" add -- '0:x.bin'
    commit_staged "$d" SKIP_PATTERN_SCAN=1
    check "a path shaped like a stage number is scanned as itself" 1 "$rc"
    d=$(new_repo)
    printf 'clean\n' >"$d/a"
    printf 'PNG\000clean\n' >"$d/b.bin"
    git -C "$d" add a b.bin
    commit_staged "$d"
    printf -v name 'a\nb.bin'
    printf 'bin\000ary aws %s\n' "$key" >"$d/$name"
    git -C "$d" add -- "$name"
    commit_staged "$d"
    check "a staged path holding a newline is refused" 1 "$rc"
    check_match "the refusal names the newline" 'newline' "$out"
    d=$(new_repo)
    printf 'aws %s\n' "$key" >"$d/notes.md"
    secret=$(git -C "$d" hash-object -w notes.md)
    clean=$(printf 'clean\n' | git -C "$d" hash-object -w --stdin)
    git -C "$d" replace "$secret" "$clean"
    git -C "$d" add notes.md
    printf 'clean\n' >"$d/notes.md"
    commit_staged "$d"
    check "a replace ref cannot show the guards a clean blob" 1 "$rc"
    d=$(new_repo)
    commit_line "$d" .gitleaksignore ':org-name:1'
    printf 'bin\000ary see %s\n' "$word" >"$d/id.bin"
    git -C "$d" add id.bin
    commit_staged "$d" SKIP_PATTERN_SCAN=1
    check "a pathless .gitleaksignore fingerprint cannot silence the opaque-blob scan" 1 "$rc"
    try k.png "aws $key"
    check "gitleaks built-ins flag a key in a text file named like an image" 1 "$rc"
    try package-lock.json "aws $key"
    check "gitleaks built-ins flag a key in a lockfile" 1 "$rc"
    try node_modules/x/k.js "aws $key"
    check "gitleaks built-ins flag a key in vendored code" 1 "$rc"
    d=$(new_repo)
    commit_line "$d" .gitleaksignore ':aws-access-token:1'
    commit_line "$d" k.png "aws $key"
    check "a pathless .gitleaksignore fingerprint cannot silence the built-ins pass" 1 "$rc"
    d=$(new_repo)
    git -C "$d" update-index --add --cacheinfo "160000,$(git -C "$d" rev-parse HEAD),sub"
    commit_staged "$d"
    check "a staged submodule is not mistaken for a secret" 0 "$rc"
    if [[ -n "$BUILTINS_EXEMPT_RE" && hooks/secret-x.test.sh =~ $BUILTINS_EXEMPT_RE ]]; then
        try hooks/secret-x.test.sh "aws $key"
        check "BUILTINS_EXEMPT_RE exempts the secret-firewall test vectors from the built-ins pass" 0 "$rc"
    else
        try hooks/secret-x.test.sh "aws $key"
        check "with no BUILTINS_EXEMPT_RE match, the built-ins pass scans every path" 1 "$rc"
    fi
fi

# --- pattern sync
# sync_copy: copy the pattern-sync script and the files it reads into a scratch tree; print it.
sync_copy() {
    local d f
    d=$(mktemp -d "$tmp/sync.XXXXXX")
    mkdir -p "$d/tests" "$d/.githooks"
    cp "$repo_root/tests/test-pattern-sync.sh" "$d/tests/"
    for f in pre-commit guard-config.sh; do
        cp "$repo_root/.githooks/$f" "$d/.githooks/$f"
    done
    cp "$repo_root/.gitleaks.toml" "$d/.gitleaks.toml"
    printf '%s\n' "$d"
}

# run_sync <tree>: run <tree>/tests/test-pattern-sync.sh; set rc and out.
run_sync() {
    rc=0
    out=$(bash "$1/tests/test-pattern-sync.sh" 2>&1) || rc=$?
}

# add_identity <tree> <pattern>: insert <pattern> as the first entry of <tree>'s IDENTITY_PATTERNS array.
add_identity() {
    ENTRY="    '$2'" awk '{ print } $0 == "IDENTITY_PATTERNS=(" { print ENVIRON["ENTRY"] }' \
        "$1/.githooks/guard-config.sh" >"$1/.githooks/guard-config.sh.new"
    mv "$1/.githooks/guard-config.sh.new" "$1/.githooks/guard-config.sh"
}

run_sync "$repo_root"
check "guard-config.sh and .gitleaks.toml carry the same patterns" 0 "$rc"
d=$(sync_copy)
add_identity "$d" somethingnew
run_sync "$d"
check_match "pattern sync catches a pattern gitleaks lacks" 'only in the pre-commit: somethingnew' "$out"
d=$(sync_copy)
sed -i.bak -e "/^    '$word'\$/d" "$d/.githooks/guard-config.sh"
run_sync "$d"
check_match "pattern sync catches a pattern the hooks lack" "only in .gitleaks.toml: $word" "$out"
d=$(sync_copy)
add_identity "$d" 'x\sy'
printf '%s\n' '' '[[rules]]' 'id = "drift-test"' "regex = '''(?i)x\\sy'''" >>"$d/.gitleaks.toml"
run_sync "$d"
check_match "pattern sync catches PCRE-only syntax" 'PCRE' "$out"
d=$(sync_copy)
printf '%s\n' 'target_rules = ["personal-identity"]' >>"$d/.gitleaks.toml"
run_sync "$d"
check_match "pattern sync rejects the target_rules spelling" 'target_rules' "$out"
d=$(sync_copy)
printf '%s\n' '' '[[allowlists]]' 'targetRules = ["no-such-rule"]' "paths = ['''^x\$''']" >>"$d/.gitleaks.toml"
run_sync "$d"
check_match "pattern sync catches a targetRules typo" 'unknown rule: no-such-rule' "$out"
d=$(sync_copy)
sed -i.bak -e '/guard-config/d' "$d/.gitleaks.toml"
run_sync "$d"
check_match "pattern sync requires guard-config.sh to be allowlisted" 'guard file is not in' "$out"
d=$(sync_copy)
sed -i.bak -e "1,/^regex = '''(?i)/ s/^regex = '''(?i)/regex = '''/" "$d/.gitleaks.toml"
run_sync "$d"
check_match "pattern sync requires (?i) on every custom rule" 'case-sensitive' "$out"
d=$(sync_copy)
rm "$d/.githooks/guard-config.sh"
run_sync "$d"
check_match "pattern sync fails when it finds no pattern source" 'no pattern source found' "$out"

# --- output-ignore
# ignore_repo <gitignore-line>...: a scratch repo holding the output-ignore script, a tracked a.conf.tmpl and a
# .gitignore of the given lines; print its path.
ignore_repo() {
    local d
    d=$(mktemp -d "$tmp/ignore.XXXXXX")
    git -C "$d" init -q
    mkdir -p "$d/tests"
    cp "$repo_root/tests/test-output-ignore.sh" "$d/tests/"
    printf 'x=__X__\n' >"$d/a.conf.tmpl"
    printf '%s\n' "$@" >"$d/.gitignore"
    git -C "$d" add tests a.conf.tmpl .gitignore
    printf '%s\n' "$d"
}

# run_ignore <tree>: run <tree>/tests/test-output-ignore.sh; set rc and out.
run_ignore() {
    rc=0
    out=$(bash "$1/tests/test-output-ignore.sh" 2>&1) || rc=$?
}

all_ignored=(a.conf config.env /.githooks/identity-patterns.local /.githooks/always-patterns.local)
run_ignore "$repo_root"
check "every tracked template's output, config.env and the local lists are ignored here" 0 "$rc"
run_ignore "$(ignore_repo "${all_ignored[@]}")"
check "output-ignore passes when everything is ignored and untracked" 0 "$rc"
run_ignore "$(ignore_repo config.env /.githooks/identity-patterns.local /.githooks/always-patterns.local)"
check_match "output-ignore catches a template output that is not ignored" 'not gitignored: a\.conf' "$out"
d=$(ignore_repo "${all_ignored[@]}")
printf 'x=1\n' >"$d/a.conf"
git -C "$d" add -f a.conf
run_ignore "$d"
check_match "output-ignore catches a tracked template output" 'tracked, though it must never be committed: a\.conf' \
    "$out"
run_ignore "$(ignore_repo a.conf /.githooks/identity-patterns.local /.githooks/always-patterns.local)"
check_match "output-ignore requires config.env to be ignored" 'not gitignored: config\.env' "$out"
run_ignore "$(ignore_repo a.conf config.env /.githooks/identity-patterns.local)"
check_match "output-ignore requires the local lists to be ignored" 'not gitignored: \.githooks/always-patterns\.local' \
    "$out"
d=$(ignore_repo "${all_ignored[@]}")
git -C "$d" rm -q --cached a.conf.tmpl
run_ignore "$d"
check_match "output-ignore fails when no template is tracked" 'no tracked \*\.tmpl found' "$out"

finish
