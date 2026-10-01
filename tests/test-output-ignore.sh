#!/usr/bin/env bash
# Verifies that nothing hydrate.sh writes, and nothing machine-local the guards read, can be committed: each tracked
# *.tmpl's output (the path without .tmpl), config.env, and the git hooks' local pattern lists must be gitignored
# and untracked. Fails when no *.tmpl is tracked, so an empty discovery never passes.
# Run locally or in CI: bash tests/test-output-ignore.sh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
errors=0
checked=0

# fail <message>: report one failed check.
fail() {
    echo "  FAIL: $1"
    errors=$((errors + 1))
}

# check_never_committed <path>: <path> must be gitignored (whether or not it exists) and untracked.
check_never_committed() {
    local rc=0
    git -C "$repo_root" check-ignore -q --no-index -- "$1" || rc=$?
    case "$rc" in
        0) ;;
        1) fail "not gitignored: $1" ;;
        *) fail "git check-ignore failed (exit $rc) for: $1" ;;
    esac
    if git -C "$repo_root" ls-files --error-unmatch -- "$1" >/dev/null 2>&1; then
        fail "tracked, though it must never be committed: $1"
    fi
    checked=$((checked + 1))
}

tmpls=0
while IFS= read -r -d '' tmpl; do
    check_never_committed "${tmpl%.tmpl}"
    tmpls=$((tmpls + 1))
done < <(git -C "$repo_root" ls-files -z -- '*.tmpl')
if [[ $tmpls -eq 0 ]]; then
    fail "no tracked *.tmpl found"
fi
for path in config.env .githooks/identity-patterns.local .githooks/always-patterns.local; do
    check_never_committed "$path"
done

if [[ $errors -gt 0 ]]; then
    echo "FAILED: $errors error(s)"
    exit 1
fi
echo "PASSED: $checked paths are gitignored and untracked"
