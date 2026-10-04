#!/usr/bin/env bash
# Tests for scripts/handover-path.sh — the single source of truth for which handover
# artifact a directory maps to. Shared by the /handover + /rehydrate commands, so a
# key-rule regression silently breaks both.
#
# The case that matters most is the linked worktree. Keying on `--show-toplevel`
# returns the worktree directory, producing an artifact that becomes unreachable the
# moment the worktree is removed — no session can ever have that cwd again. That
# orphaned two real handovers before it was fixed, so it is pinned here.

_handover_path() {
    # Run the resolver in $1 with an isolated HANDOVER_DIR so tests never read or
    # write the real handovers directory.
    (cd "$1" && HANDOVER_DIR=/tmp/handover-test-dir bash "$REPO_ROOT/scripts/handover-path.sh")
}

_mkrepo() {
    # A minimal repo with one commit. Identity and signing are set per command so the test
    # does not depend on the machine's global git config (signing needs an agent socket).
    local dir="$1"
    mkdir -p "$dir"
    git -C "$dir" init -q -b main
    printf 'seed\n' >"$dir/seed.txt"
    git -C "$dir" add seed.txt
    git -C "$dir" -c user.email=t@example.com -c user.name=Test -c commit.gpgsign=false commit -qm seed
}

test_handover_path_key_rule() {
    local tmp
    tmp=$(mktemp -d)
    # macOS mktemp returns /var/folders/... which is a symlink to /private/var/...
    # The resolver uses `pwd -P`, so compare against the physical path or every
    # assertion fails on path form rather than on behaviour.
    tmp=$(cd "$tmp" && pwd -P)

    _mkrepo "$tmp/proj"
    mkdir -p "$tmp/proj/nested/deeper"

    local from_root from_subdir
    from_root=$(_handover_path "$tmp/proj")
    from_subdir=$(_handover_path "$tmp/proj/nested/deeper")
    assert_equals "$from_root" "$from_subdir" \
        "a subdirectory maps to the same handover as the repo root"

    # The regression this file exists for.
    git -C "$tmp/proj" worktree add -q "$tmp/proj/.wt/feature" -b feature 2>/dev/null
    if [[ -d "$tmp/proj/.wt/feature" ]]; then
        local from_worktree
        from_worktree=$(_handover_path "$tmp/proj/.wt/feature")
        assert_equals "$from_root" "$from_worktree" \
            "a linked worktree maps to its MAIN worktree's handover, not its own"

        # A worktree outside the repo tree must collapse too — placement is arbitrary
        # and .claude/worktrees/ is only a convention.
        git -C "$tmp/proj" worktree add -q "$tmp/outside-wt" -b outside 2>/dev/null
        if [[ -d "$tmp/outside-wt" ]]; then
            local from_outside
            from_outside=$(_handover_path "$tmp/outside-wt")
            assert_equals "$from_root" "$from_outside" \
                "a worktree outside the repo directory also collapses to the main one"
        else
            skip "worktree outside the repo directory" "git worktree add failed"
        fi
    else
        skip "linked worktree collapses to the main worktree" "git worktree add failed"
    fi

    # Outside any repo, the key is the cwd — and must NOT collide with the repo's.
    local from_parent
    from_parent=$(_handover_path "$tmp")
    if [[ "$from_parent" != "$from_root" ]]; then
        pass "a non-repo parent directory keys on cwd, distinctly from the repo"
    else
        fail "a non-repo parent directory keys on cwd, distinctly from the repo" \
            "collided: $from_parent"
    fi

    # Two same-named repos at different paths must not clobber each other — the
    # reason the filename carries a path hash at all.
    _mkrepo "$tmp/other/proj"
    local from_twin
    from_twin=$(_handover_path "$tmp/other/proj")
    if [[ "$from_twin" != "$from_root" ]]; then
        pass "two repos with the same basename get different handovers"
    else
        fail "two repos with the same basename get different handovers" \
            "collided: $from_twin"
    fi

    rm -rf "$tmp"
}

test_handover_path_submodule_keeps_its_own_key() {
    # The worktree collapse rewrites the key to the parent of `--git-common-dir`. A
    # submodule's common dir is <super>/.git/modules/<name>, whose parent is not a
    # working tree — so a submodule must keep its own key rather than being folded
    # into its superproject's. This guards the guard.
    local tmp
    tmp=$(mktemp -d)
    tmp=$(cd "$tmp" && pwd -P)

    _mkrepo "$tmp/super"
    _mkrepo "$tmp/child"

    if git -C "$tmp/super" -c protocol.file.allow=always \
        -c user.email=t@example.com -c user.name=Test \
        submodule add -q "$tmp/child" sub 2>/dev/null; then
        local super_key sub_key
        super_key=$(_handover_path "$tmp/super")
        sub_key=$(_handover_path "$tmp/super/sub")
        if [[ "$super_key" != "$sub_key" ]]; then
            pass "a submodule keeps its own handover key"
        else
            fail "a submodule keeps its own handover key" "folded into superproject: $sub_key"
        fi
    else
        skip "a submodule keeps its own handover key" "submodule add unavailable"
    fi

    rm -rf "$tmp"
}
