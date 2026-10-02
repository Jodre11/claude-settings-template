#!/usr/bin/env bash
# Tests that .gitignore keeps Claude Code's per-project memory out of git, and that its opt-in line re-includes it.
# Sourced by tests/run.sh.

# _mi_ignored <repo> <path>: print yes when <path> is gitignored in <repo>, no when not, and the exit code otherwise.
_mi_ignored() {
    local rc=0
    git -C "$1" check-ignore -q --no-index -- "$2" || rc=$?
    case "$rc" in
        0) echo yes ;;
        1) echo no ;;
        *) echo "check-ignore exited $rc" ;;
    esac
}

test_memory_ignore_default() {
    assert_equals yes "$(_mi_ignored "$REPO_ROOT" projects/p/memory/MEMORY.md)" \
        "a per-project memory note is gitignored"
    assert_equals no "$(_mi_ignored "$REPO_ROOT" projects/p/notes.md)" \
        "a file beside the memory directory is not"
}

test_memory_ignore_opt_in() {
    local tmp
    tmp=$(mktemp -d)
    git init -q "$tmp"
    sed 's|^# !projects/\*/memory/$|!projects/*/memory/|' "$REPO_ROOT/.gitignore" >"$tmp/.gitignore"
    assert_equals 1 "$(grep -c -x '!projects/\*/memory/' "$tmp/.gitignore" || true)" \
        ".gitignore carries exactly one commented opt-in line"
    assert_equals no "$(_mi_ignored "$tmp" projects/p/memory/MEMORY.md)" \
        "uncommenting the opt-in line re-includes the memory note"
    assert_equals yes "$(_mi_ignored "$tmp" projects/p/session.jsonl)" \
        "the opt-in leaves session transcripts ignored"
    rm -rf "$tmp"
}
