#!/usr/bin/env bash
# Tests for .githooks/pre-push: every commit a push would publish is scanned, whatever made it, under the config its
# tip commits. The helpers and fixtures are in tests/guard-test-lib.sh, so this file carries no literal the guards
# flag. Bash 3.2 compatible. Run: bash tests/test-pre-push.sh
# shellcheck disable=SC2154  # the fixtures, rc, out, repo_root and tmp come from guard-test-lib.sh
set -euo pipefail
# shellcheck source=guard-test-lib.sh
source "$(dirname "$0")/guard-test-lib.sh"

# --- git runs a hook only when it is executable, and skips it silently otherwise
check "the pre-push hook is executable" yes \
    "$(if [[ -x "$repo_root/.githooks/pre-push" ]]; then echo yes; else echo no; fi)"

# push_repo: new_repo with a bare origin, <repo>.git, holding its first commit on main; print the repo's path.
push_repo() {
    local d
    d=$(new_repo)
    git init -q --bare "$d.git"
    git -C "$d" remote add origin "$d.git"
    git -C "$d" -c core.hooksPath=/dev/null push -q origin main
    printf '%s\n' "$d"
}

# raw_commit <repo> <path> <line> [commit-option...]: append <line> to <path> and commit it with the hooks off, as a
# rebase, cherry-pick or am would.
raw_commit() {
    local d="$1" path="$2" line="$3"
    shift 3
    mkdir -p "$(dirname "$d/$path")"
    printf '%s\n' "$line" >>"$d/$path"
    git -C "$d" add -f -- "$path"
    git -C "$d" -c core.hooksPath=/dev/null commit -q -m "add $path" "$@"
}

# push_to <repo> <arg>... [--env VAR=value...]: run git push <arg>... in <repo>; set rc and out.
push_to() {
    local d="$1"
    shift
    rc=0
    out=$(git -C "$d" push "$@" 2>&1) || rc=$?
}

# push_env <repo> <VAR=value> <arg>...: push_to with one environment setting.
push_env() {
    local d="$1" setting="$2"
    shift 2
    rc=0
    out=$(env "$setting" git -C "$d" push "$@" 2>&1) || rc=$?
}

# landed <repo> <branch>: print the commit <branch> names in <repo>'s origin, or nothing.
landed() {
    git -C "$1.git" rev-parse -q --verify "refs/heads/$2" 2>/dev/null || true
}

# --- pre-push: every commit a push publishes is scanned
d=$(push_repo)
raw_commit "$d" notes.md "clean line"
push_to "$d" origin main
check "pre-push allows a clean push" 0 "$rc"
check "the clean push landed" "$(git -C "$d" rev-parse main)" "$(landed "$d" main)"
check_match "pre-push reports what it scanned" '1 commit\(s\) scanned' "$out"
d=$(push_repo)
raw_commit "$d" notes.md "see $word"
push_to "$d" origin main
check "pre-push refuses an identity word committed with the hooks off" 1 "$rc"
check_match "the refusal comes from the pattern scan" 'sensitive pattern detected' "$out"
check "nothing landed" "$(git -C "$d" rev-parse main~1)" "$(landed "$d" main)"
d=$(push_repo)
with_list "$d" identity "$local_word"
raw_commit "$d" notes.md "see $local_word"
push_to "$d" origin main
check "pre-push refuses a word from identity-patterns.local" 1 "$rc"
d=$(push_repo)
with_list "$d" always "$local_id"
raw_commit "$d" notes.md "profile|$local_id|role"
push_to "$d" origin main
check "pre-push refuses a literal from always-patterns.local" 1 "$rc"
d=$(push_repo)
with_list "$d" identity "$local_word"
git -C "$d" worktree add -q -b wt "$d-wt"
raw_commit "$d-wt" notes.md "see $local_word"
push_to "$d-wt" origin wt
check "pre-push applies the main worktree's local lists in a linked worktree" 1 "$rc"
d=$(push_repo)
with_list "$d" identity "$local_word "
raw_commit "$d" notes.md "clean line"
push_to "$d" origin main
check "pre-push fails closed on a local pattern with a trailing space" 1 "$rc"
d=$(push_repo)
with_list "$d" identity "$local_word"
raw_commit "$d" .githooks/guard-config.sh "# see $local_word"
push_to "$d" origin main
check "pre-push refuses a local identity word in guard-config.sh" 1 "$rc"
d=$(push_repo)
git -C "$d" checkout -q -b side
raw_commit "$d" .githooks/guard-config.sh "# side change"
git -C "$d" checkout -q main
push_to "$d" origin side
check "pre-push refuses a ref whose committed guard-config.sh differs from the one in use" 1 "$rc"
check_match "the refusal names guard-config.sh" 'guard-config.sh committed at' "$out"
d=$(push_repo)
git -C "$d" checkout -q -b side
raw_commit "$d" .githooks/guard-config.sh "# side change"
push_to "$d" origin side
check "pre-push accepts a ref whose committed guard-config.sh is the one in use" 0 "$rc"
d=$(push_repo)
raw_commit "$d" .githooks/guard-config.sh "# a change"
push_to "$d" origin main
git -C "$d" tag old main~1
push_to "$d" origin old
check "pre-push allows a tag of a pushed commit after guard-config.sh changes" 0 "$rc"
git -C "$d" branch at-old main~1
push_to "$d" origin at-old
check "pre-push allows a new branch at a pushed commit after guard-config.sh changes" 0 "$rc"
d=$(push_repo)
printf '%s\n' "# an unstaged change" >>"$d/.githooks/guard-config.sh"
git -C "$d" tag v1
push_to "$d" origin v1
check "pre-push refuses while guard-config.sh differs from its staged copy" 1 "$rc"
d=$(push_repo)
git -C "$d" rm -q --cached .githooks/guard-config.sh
git -C "$d" -c core.hooksPath=/dev/null commit -q -m "untrack the config"
printf '%s\n' "# an edit" >>"$d/.githooks/guard-config.sh"
raw_commit "$d" notes.md "clean line"
push_to "$d" origin main
check "pre-push refuses while guard-config.sh is not in the index" 1 "$rc"
d=$(push_repo)
raw_commit "$d" .gitleaks.toml "# account \`$digits\`"
push_to "$d" origin main
check "pre-push refuses a secret-shaped value in .gitleaks.toml" 1 "$rc"
d=$(push_repo)
git -C "$d" config log.showRoot false
git -C "$d" checkout -q --orphan side
raw_commit "$d" notes.md "see $word"
push_to "$d" origin side
check "pre-push scans a root commit under log.showRoot=false" 1 "$rc"
d=$(push_repo)
git -C "$d" config log.showRoot false
git -C "$d" checkout -q --orphan side
raw_commit "$d" .githooks/identity-patterns.local "x"
push_env "$d" SKIP_PATTERN_SCAN=1 origin side
check "pre-push refuses a root commit that adds a local list under log.showRoot=false" 1 "$rc"
d=$(push_repo)
git -C "$d" config i18n.logOutputEncoding UTF-16
with_list "$d" identity "$local_word"
raw_commit "$d" notes.md "clean line" -m "mentions $local_word"
push_to "$d" origin main
check "pre-push scans commit metadata under i18n.logOutputEncoding=UTF-16" 1 "$rc"
d=$(push_repo)
raw_commit "$d" "$memory" "see $word"
push_to "$d" origin main
check "pre-push applies IDENTITY_EXEMPT_RE to a memory path" "$memory_rc" "$rc"
d=$(push_repo)
with_list "$d" identity "$local_word"
raw_commit "$d" notes.md "see $local_word"
git -C "$d" rm -q notes.md
git -C "$d" -c core.hooksPath=/dev/null commit -q -m remove
push_to "$d" origin main
check "pre-push scans each commit, so a value added and removed within the push is caught" 1 "$rc"
d=$(push_repo)
with_list "$d" identity "$local_word"
raw_commit "$d" notes.md "clean line" -m "mentions $local_word"
push_to "$d" origin main
check "pre-push refuses a local identity word in a commit message" 1 "$rc"
check_match "the refusal names the metadata" 'metadata: mentions' "$out"
d=$(push_repo)
raw_commit "$d" notes.md "clean line" -m "mentions account \`$digits\`"
push_to "$d" origin main
check "pre-push refuses a secret-shaped value in a commit message" 1 "$rc"
d=$(push_repo)
raw_commit "$d" notes.md "clean line" -m "documents the $word placeholder"
push_to "$d" origin main
check "a commit message may name a tracked identity placeholder" 0 "$rc"
d=$(push_repo)
with_list "$d" identity "$local_word"
raw_commit "$d" notes.md "clean line" --author "Someone <someone@$local_word.example>"
push_to "$d" origin main
check "pre-push refuses a local identity word in the author email" 1 "$rc"
d=$(push_repo)
with_list "$d" identity "$local_word"
raw_commit "$d" notes.md "clean line"
git -C "$d" -c core.hooksPath=/dev/null -c user.name="$local_word" commit -q --amend --no-edit --reset-author
push_to "$d" origin main
check "pre-push refuses a local identity word in the committer name" 1 "$rc"
d=$(push_repo)
with_list "$d" identity "$local_word"
raw_commit "$d" notes.md "clean line" --author "Someone <1+$local_word@users.noreply.github.com>"
push_to "$d" origin main
check "pre-push allows the GitHub noreply alias of a listed handle" 0 "$rc"
d=$(push_repo)
with_list "$d" identity "$local_word"
raw_commit "$d" notes.md "clean line" --author "Someone <1+a.${local_word}_b@users.noreply.github.com>"
push_to "$d" origin main
check "pre-push refuses a noreply-shaped author whose handle GitHub would not issue" 1 "$rc"
d=$(push_repo)
with_list "$d" identity "$local_word"
raw_commit "$d" notes.md "clean line" -m "see 9+$local_word@users.noreply.github.com"
push_to "$d" origin main
check "pre-push scans a noreply-shaped address in a commit message" 1 "$rc"
d=$(push_repo)
with_list "$d" identity "$local_word"
git -C "$d" tag -a -m "mentions $local_word" v1
push_to "$d" origin v1
check "pre-push refuses a local identity word in an annotated tag's message" 1 "$rc"
check_match "the refusal names the tag" 'sensitive pattern detected in the tag' "$out"
d=$(push_repo)
with_list "$d" identity "$local_word"
git -C "$d" -c user.email="someone@$local_word.example" tag -a -m "release" v1
push_to "$d" origin v1
check "pre-push refuses a local identity word in a tagger email" 1 "$rc"
d=$(push_repo)
git -C "$d" tag -a -m "mentions account \`$digits\`" v1
push_to "$d" origin v1
check "pre-push refuses a secret-shaped value in a tag message" 1 "$rc"
d=$(push_repo)
git -C "$d" tag -a -m "release" v1
push_to "$d" origin v1
check "pre-push allows a clean annotated tag of a pushed commit" 0 "$rc"
d=$(push_repo)
with_list "$d" identity "$local_word"
git -C "$d" tag -a -m "mentions $local_word" v1
push_env "$d" SKIP_PATTERN_SCAN=1 origin v1
check "SKIP_PATTERN_SCAN=1 skips the tag scan too" 0 "$rc"
d=$(push_repo)
blob=$(printf 'see %s\n' "$word" | git -C "$d" hash-object -w --stdin)
git -C "$d" tag blobtag "$blob"
push_to "$d" origin blobtag
check "pre-push refuses a ref that names a blob" 1 "$rc"
check_match "the refusal names the object type" 'names a blob' "$out"
d=$(push_repo)
git -C "$d" tag treetag "main^{tree}"
push_to "$d" origin treetag
check "pre-push refuses a ref that names a tree" 1 "$rc"
d=$(push_repo)
blob=$(printf 'x\n' | git -C "$d" hash-object -w --stdin)
git -C "$d" tag -a -m "a blob" blobtag "$blob"
push_to "$d" origin blobtag
check "pre-push refuses an annotated tag of a blob" 1 "$rc"
d=$(push_repo)
with_list "$d" identity "$local_word"
raw_commit "$d" notes.md "see $local_word" -m "mentions $local_word"
push_env "$d" SKIP_PATTERN_SCAN=1 origin main
check "SKIP_PATTERN_SCAN=1 skips the pre-push pattern scan of lines and metadata" 0 "$rc"
d=$(push_repo)
with_list "$d" identity "$local_word"
raw_commit "$d" notes.md "see $local_word"
push_env "$d" SKIP_SECRET_SCAN=1 origin main
check "the retired SKIP_SECRET_SCAN bypasses nothing at push" 1 "$rc"
d=$(push_repo)
raw_commit "$d" .githooks/identity-patterns.local "x"
push_env "$d" SKIP_PATTERN_SCAN=1 origin main
check "pre-push refuses a commit that adds a local list, even with the bypass" 1 "$rc"
check_match "the refusal names the local list" 'machine-local pattern list' "$out"
d=$(push_repo)
raw_commit "$d" notes.md "see $word"
git -C "$d" -c core.hooksPath=/dev/null push -q origin main
git -C "$d" switch -q -c topic
raw_commit "$d" topic.md "clean line"
push_to "$d" origin topic
check "a new branch is scanned only for the commits the remote lacks" 0 "$rc"
check "the new branch landed" "$(git -C "$d" rev-parse topic)" "$(landed "$d" topic)"
d=$(push_repo)
raw_commit "$d" notes.md "see $word"
git -C "$d" -c core.hooksPath=/dev/null push -q origin main
raw_commit "$d" later.md "clean line"
push_to "$d" origin main
check "an update is scanned only for the commits after the remote's tip" 0 "$rc"
d=$(push_repo)
raw_commit "$d" notes.md "see $word"
git -C "$d" -c core.hooksPath=/dev/null push -q origin main
git -C "$d" switch -q -c topic
raw_commit "$d" topic.md "clean line"
push_to "$d" "$d.git" topic
check "a push to a URL scans the whole history" 1 "$rc"
d=$(push_repo)
git clone -q "$d.git" "$d.other"
git -C "$d.other" -c core.hooksPath=/dev/null commit -q --allow-empty -m other
git -C "$d.other" -c core.hooksPath=/dev/null push -q origin main
raw_commit "$d" notes.md "see $word"
push_to "$d" origin +main
check "pre-push still scans when the remote's tip is unknown here" 1 "$rc"
raw_commit "$d" clean.md "clean line"
git -C "$d" reset -q --hard HEAD~2
raw_commit "$d" clean.md "clean line"
push_to "$d" origin +main
check "a clean force-push over an unknown remote tip is allowed" 0 "$rc"
d=$(push_repo)
git -C "$d" -c core.hooksPath=/dev/null push -q origin main:gone
push_to "$d" origin --delete gone
check "pre-push allows a branch deletion" 0 "$rc"
d=$(push_repo)
git -C "$d" switch -q -c side
raw_commit "$d" side.md "side line"
git -C "$d" switch -q main
git -C "$d" -c core.hooksPath=/dev/null merge -q --no-ff --no-commit side
printf 'see %s\n' "$word" >>"$d/side.md"
git -C "$d" add side.md
git -C "$d" -c core.hooksPath=/dev/null commit -q -m merge
push_to "$d" origin main
check "pre-push scans what a merge itself adds" 1 "$rc"
d=$(push_repo)
git -C "$d" switch -q -c side
raw_commit "$d" side.md "see $word"
git -C "$d" rm -q side.md
git -C "$d" -c core.hooksPath=/dev/null commit -q -m remove
git -C "$d" switch -q main
git -C "$d" -c core.hooksPath=/dev/null merge -q --no-ff -m merge side
push_to "$d" origin main
check "pre-push scans a side branch whose merge leaves no net change" 1 "$rc"
d=$(push_repo)
git -C "$d" switch -q -c clean
raw_commit "$d" clean.md "clean line"
git -C "$d" switch -q -c dirty main
raw_commit "$d" dirty.md "see $word"
push_to "$d" origin clean dirty
check "pre-push refuses a push when any of its refs is dirty" 1 "$rc"
d=$(push_repo)
raw_commit "$d" notes.md "see $word"
git -C "$d" tag -a -m tag v1
git -C "$d" reset -q --hard HEAD~1
push_to "$d" origin v1
check "pre-push scans the commits a tag publishes" 1 "$rc"
for setting in "color.ui always" "diff.external true" "diff.noprefix true" "diff.dstPrefix x/"; do
    read -r cfg_key cfg_value <<<"$setting"
    d=$(push_repo)
    git -C "$d" config "$cfg_key" "$cfg_value"
    raw_commit "$d" notes.md "see $word"
    push_to "$d" origin main
    check "the pre-push pattern scan still bites under $setting" 1 "$rc"
done

if have_gitleaks "pre-push gitleaks rows"; then
    d=$(push_repo)
    raw_commit "$d" notes.md "aws $key"
    push_env "$d" SKIP_PATTERN_SCAN=1 origin main
    check "pre-push gitleaks still runs under SKIP_PATTERN_SCAN=1" 1 "$rc"
    check_match "the pre-push gitleaks refusal says there is no bypass" 'There is no bypass' "$out"
    d=$(push_repo)
    printf 'bin\000ary aws %s\n' "$key" >"$d/blob.bin"
    git -C "$d" add blob.bin
    git -C "$d" -c core.hooksPath=/dev/null commit -q -m blob
    push_to "$d" origin main
    check "pre-push flags a key in a binary blob" 1 "$rc"
    check_match "the built-ins pass names the blob's path" 'built-in rules found a secret in:.*blob\.bin' "$out"
    d=$(push_repo)
    raw_commit "$d" package-lock.json "aws $key"
    push_to "$d" origin main
    check "pre-push flags a key in a path gitleaks' default allowlist skips" 1 "$rc"
    d=$(push_repo)
    raw_commit "$d" notes.md "see $word"
    printf '%s\n' "$(git -C "$d" rev-parse HEAD):notes.md:org-name:1" >"$d/.gitleaksignore"
    push_env "$d" SKIP_PATTERN_SCAN=1 origin main
    check "a working-tree .gitleaksignore cannot silence the push" 1 "$rc"
    d=$(push_repo)
    raw_commit "$d" notes.md "see $word"
    printf '%s\n' '' '[[allowlists]]' "paths = ['''^notes\\.md\$''']" >>"$d/.gitleaks.toml"
    push_env "$d" SKIP_PATTERN_SCAN=1 origin main
    check "a working-tree .gitleaks.toml edit cannot silence the push" 1 "$rc"
    d=$(push_repo)
    raw_commit "$d" notes.md "see $word"
    sha=$(git -C "$d" rev-parse HEAD)
    raw_commit "$d" .gitleaksignore "$sha:notes.md:org-name:1"
    push_env "$d" SKIP_PATTERN_SCAN=1 origin main
    check "pre-push honours the .gitleaksignore committed at the pushed tip" 0 "$rc"
    d=$(push_repo)
    raw_commit "$d" notes.md "aws $key"
    sha=$(git -C "$d" rev-parse HEAD)
    raw_commit "$d" .gitleaksignore "$sha:notes.md:aws-access-token:1"
    push_env "$d" SKIP_PATTERN_SCAN=1 origin main
    check "a committed .gitleaksignore cannot silence the built-ins pass" 1 "$rc"
    d=$(push_repo)
    sed -i.bak -e 's/^useDefault = true$/path = "local.toml"/' "$d/.gitleaks.toml"
    rm "$d/.gitleaks.toml.bak"
    git -C "$d" add .gitleaks.toml
    git -C "$d" -c core.hooksPath=/dev/null commit -q -m config
    push_to "$d" origin main
    check "pre-push refuses a pushed tip whose .gitleaks.toml extends another file" 1 "$rc"
    check_match "the refusal names the [extend] table" '\[extend\]' "$out"
    d=$(push_repo)
    git -C "$d" rm -q .gitleaks.toml
    git -C "$d" -c core.hooksPath=/dev/null commit -q -m "no config"
    push_to "$d" origin main
    check "pre-push refuses a pushed tip with no .gitleaks.toml" 1 "$rc"
    d=$(push_repo)
    git -C "$d" checkout -q -b side
    raw_commit "$d" side.md "side line"
    git -C "$d" checkout -q main
    raw_commit "$d" main.md "main line"
    git -C "$d" -c core.hooksPath=/dev/null merge -q --no-ff --no-commit side
    printf 'account `%s`\n' "$digits" >"$d/evil.md"
    git -C "$d" add -f evil.md
    git -C "$d" -c core.hooksPath=/dev/null commit -q -m merge
    push_env "$d" SKIP_PATTERN_SCAN=1 origin main
    check "gitleaks reads what only a merge adds, even under SKIP_PATTERN_SCAN=1" 1 "$rc"
    d=$(push_repo)
    printf 'x\000account `%s`\n' "$digits" >"$d/blob.bin"
    git -C "$d" add -f blob.bin
    git -C "$d" -c core.hooksPath=/dev/null commit -q -m binary
    push_env "$d" SKIP_PATTERN_SCAN=1 origin main
    check "gitleaks' custom rules scan a pushed binary blob" 1 "$rc"
    d=$(push_repo)
    printf 'x\000clean\n' >"$d/blob.bin"
    git -C "$d" add -f blob.bin
    git -C "$d" -c core.hooksPath=/dev/null commit -q -m binary
    push_env "$d" SKIP_PATTERN_SCAN=1 origin main
    check "pre-push allows a clean pushed binary blob" 0 "$rc"
    d=$(push_repo)
    git -C "$d" config diff.hide.textconv true
    raw_commit "$d" .gitattributes '*.dat diff=hide'
    raw_commit "$d" notes.dat "account \`$digits\`"
    push_env "$d" SKIP_PATTERN_SCAN=1 origin main
    check "gitleaks' custom rules scan a blob behind a textconv driver" 1 "$rc"
    d=$(push_repo)
    raw_commit "$d" .gitattributes 'wide.txt diff'
    printf 'x\000account `%s`\n' "$digits" >"$d/wide.txt"
    git -C "$d" add -f wide.txt
    git -C "$d" -c core.hooksPath=/dev/null commit -q -m wide
    push_env "$d" SKIP_PATTERN_SCAN=1 origin main
    check "a committed diff attribute cannot hide NUL content from gitleaks' custom rules" 1 "$rc"
    d=$(push_repo)
    git -C "$d" config diff.hide.textconv true
    mkdir -p "$d/.git/info"
    printf '%s\n' '*.dat diff=hide' >"$d/.git/info/attributes"
    raw_commit "$d" notes.dat "account \`$digits\`"
    push_env "$d" SKIP_PATTERN_SCAN=1 origin main
    check "a textconv driver from info/attributes cannot hide content from gitleaks" 1 "$rc"
    d=$(push_repo)
    mkdir -p "$d/projects/p/memory"
    printf 'see %s\n' "$word" >"$d/zz.gitleaks.toml"
    cp "$d/zz.gitleaks.toml" "$d/projects/p/memory/m.md"
    git -C "$d" add -f zz.gitleaks.toml projects/p/memory/m.md
    git -C "$d" -c core.hooksPath=/dev/null commit -q -m dup
    push_env "$d" SKIP_PATTERN_SCAN=1 origin main
    check "the opaque pass scans a pushed blob at every path it is at" 1 "$rc"
    d=$(push_repo)
    raw_commit "$d" docs/old.gitleaks.toml "account \`$digits\`"
    push_env "$d" SKIP_PATTERN_SCAN=1 origin main
    check "gitleaks' custom rules scan a path named like gitleaks.toml" 1 "$rc"
    d=$(push_repo)
    raw_commit "$d" .githooks/guard-config.sh "# account \`$digits\`"
    push_env "$d" SKIP_PATTERN_SCAN=1 origin main
    check "pre-push gitleaks flags an account ID in guard-config.sh under SKIP_PATTERN_SCAN=1" 1 "$rc"
    if [[ -n "$BUILTINS_EXEMPT_RE" && hooks/secret-patterns.test.sh =~ $BUILTINS_EXEMPT_RE ]]; then
        d=$(push_repo)
        raw_commit "$d" hooks/secret-patterns.test.sh "aws $key"
        push_env "$d" SKIP_PATTERN_SCAN=1 origin main
        check "the pre-push built-ins pass honours BUILTINS_EXEMPT_RE" 0 "$rc"
    fi
    d=$(push_repo)
    raw_commit "$d" hooks/secret-new.test.sh "aws $key"
    push_env "$d" SKIP_PATTERN_SCAN=1 origin main
    check "the pre-push built-ins pass scans a secret-*.test.sh file BUILTINS_EXEMPT_RE does not name" 1 "$rc"
fi

finish
