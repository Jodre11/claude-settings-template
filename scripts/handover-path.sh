#!/usr/bin/env bash
# handover-path.sh — Resolve the handover-artifact path for the current working
# directory. Single source of truth shared by the /handover + /rehydrate
# commands so the key rule is defined exactly once.
#
# Key rule (matches the staleness model — see README "Handover workflow"):
#   - Inside a git repo: key on the MAIN worktree root, so invoking from the repo
#     root, any subdirectory, OR any linked worktree maps to the SAME handover.
#   - Outside a repo (parent dirs like ~/Repos, a multi-repo checkout dir, or
#     $HOME): key on the cwd absolute path. Reconciliation degrades to
#     trust-the-file mode.
#
# Why the main worktree and not `--show-toplevel`: inside a linked worktree,
# `--show-toplevel` returns the WORKTREE directory. Keying on that produces an
# artifact that is unreachable the moment the worktree is removed — no session can
# ever have that cwd again — so the handover is silently orphaned. This is not
# hypothetical: it happened twice, and the second time the artifact had to be
# hand-promoted from a draft because the session that wrote it was pinned to a
# worktree that had just been deleted and could no longer run git at all.
#
# Consequence, deliberate: one active handover per REPOSITORY, not per worktree.
# A handover is already "one per directory, a new phase supersedes the old" (see
# the /handover command), so this extends that model rather than changing it. Work
# happening in a worktree records its branch and HEAD in the artifact's front
# matter, which is what /rehydrate reconciles against — so a fresh session started
# in the main checkout is told which branch the work is on and can switch to it.
#
# Filename: <basename>-<8hex-of-root-path>.md
#   - basename keeps the file human-readable when you `ls` the handovers dir
#   - the path hash makes it collision-safe: two repos both called `api` at
#     different paths get different files (no silent clobber)
#
# Output: prints the absolute handover path to stdout. Also prints, on fd 3 when
# open, the resolved mode (`repo` or `path`) and the root used — callers that
# want the mode capture fd 3; plain callers just read stdout.
#
# Bash 3.2 compatible (macOS system bash) — no associative arrays, no ${,,}.
set -euo pipefail

HANDOVER_DIR="${HANDOVER_DIR:-$HOME/.claude/handovers}"

root=""
mode=""
if root=$(git rev-parse --show-toplevel 2>/dev/null) && [[ -n "$root" ]]; then
    mode="repo"
    # Collapse a linked worktree onto its main worktree so the key survives the
    # worktree being removed. `--git-common-dir` is the shared .git for every
    # worktree of a repo; its parent is the main working tree.
    common=$(git rev-parse --git-common-dir 2>/dev/null) || common=""
    # It is relative ('.git') in the main checkout and absolute in a linked one, so
    # absolutise before reasoning about it. -P resolves symlinks, matching the
    # already-physical path --show-toplevel returns.
    if [[ -n "$common" ]]; then
        common=$(cd "$common" 2>/dev/null && pwd -P) || common=""
    fi
    # Only rewrite when the common dir is literally a `.git` DIRECTORY whose parent
    # is a working tree. That guard is what keeps two cases correct:
    #   - submodules, whose common dir is <super>/.git/modules/<name> — basename is
    #     the module name, so a submodule keeps its own key rather than being folded
    #     into its superproject's
    #   - bare repos, whose common dir is typically <name>.git with no working tree
    #     parent (and which have no --show-toplevel anyway)
    if [[ -n "$common" && "${common##*/}" == ".git" ]]; then
        main_root="${common%/*}"
        [[ -n "$main_root" && -d "$main_root" ]] && root="$main_root"
    fi
else
    root="${PWD:-/}"
    mode="path"
fi

basename="${root##*/}"
basename="${basename#.}"
[[ -z "$basename" ]] && basename="root"
basename=$(printf '%s' "$basename" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-')
# collapse runs of '-' and trim leading/trailing
basename=$(printf '%s' "$basename" | tr -s '-')
basename="${basename#-}"
basename="${basename%-}"
[[ -z "$basename" ]] && basename="root"

# 8 hex chars of the root path. Prefer shasum (always present on macOS); fall
# back to cksum so the script still resolves a stable key if shasum is absent.
if command -v shasum >/dev/null 2>&1; then
    hash=$(printf '%s' "$root" | shasum | cut -c1-8)
else
    hash=$(printf '%s' "$root" | cksum | tr -d ' ' | cut -c1-8)
fi

printf '%s/%s-%s.md\n' "$HANDOVER_DIR" "$basename" "$hash"

# Emit mode + root on fd 3 if the caller opened it (e.g. `... 3>capturefile`).
if { true >&3; } 2>/dev/null; then
    printf 'mode=%s root=%s\n' "$mode" "$root" >&3
fi
