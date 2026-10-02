#!/usr/bin/env bash
# Tests for tests/test-output-ignore.sh, the check that every tracked template's output, config.env and the local
# pattern lists are gitignored and untracked. Kept apart from the shared guard suites, which assume no hydration. The
# helpers are in tests/guard-test-lib.sh. Bash 3.2 compatible. Run: bash tests/test-output-ignore-check.sh
# shellcheck disable=SC2154  # rc, out, repo_root and tmp come from guard-test-lib.sh
set -euo pipefail
# shellcheck source=guard-test-lib.sh
source "$(dirname "$0")/guard-test-lib.sh"

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
