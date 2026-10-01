#!/usr/bin/env bash
# Tests that this repository's own history passes its own pre-push. A fork's first push publishes every commit, so a
# pattern, exemption or allowlist change that made old history fail would lock every fork out. A clone of HEAD takes
# the working tree's guard files in one extra commit, then pushes its whole history by URL to a scratch bare repo,
# with no local pattern list. Skips in a shallow clone. Bash 3.2 compatible. Run: bash tests/test-history-push.sh
# shellcheck disable=SC2154  # rc, out, repo_root and tmp come from guard-test-lib.sh
set -euo pipefail
# shellcheck source=guard-test-lib.sh
source "$(dirname "$0")/guard-test-lib.sh"

if [[ "$(git -C "$repo_root" rev-parse --is-shallow-repository)" == true ]]; then
    skip "this repository's whole history passes its own pre-push" "a shallow clone; fetch the full history"
else
    d="$tmp/history"
    git init -q "$d"
    git -C "$d" fetch -q "$repo_root" HEAD
    git -C "$d" checkout -q --detach FETCH_HEAD
    for f in .githooks/pre-commit .githooks/pre-push .githooks/guard-lib.sh .githooks/guard-config.sh .gitleaks.toml; do
        if [[ -e "$repo_root/$f" ]]; then
            cp -p "$repo_root/$f" "$d/$f"
        fi
    done
    git -C "$d" add .githooks .gitleaks.toml
    if ! git -C "$d" diff --cached --quiet; then
        git -C "$d" -c core.hooksPath=/dev/null commit -q -m "the working tree's guard files"
    fi
    git -C "$d" config core.hooksPath .githooks
    git init -q --bare "$d.git"
    rc=0
    out=$(git -C "$d" push "$d.git" HEAD:refs/heads/main 2>&1) || rc=$?
    check "this repository's whole history passes its own pre-push" 0 "$rc"
    check_match "the pre-push scanned every commit" "$(git -C "$d" rev-list --count HEAD) commit\\(s\\) scanned" \
        "$out"
fi
finish
