#!/usr/bin/env bash
# handover-path.sh — Resolve the handover-artifact path for the current working
# directory. Single source of truth shared by hooks/handover-detect.sh and the
# /handover + /rehydrate commands so the key rule is defined exactly once.
#
# Key rule (matches the staleness model — see README "Handover workflow"):
#   - Inside a git repo: key on `git rev-parse --show-toplevel` so invoking from
#     the repo root or any subdirectory maps to the SAME handover.
#   - Outside a repo (parent dirs like ~/Repos, ~/Repos/haven, or $HOME): key on
#     the cwd absolute path. Reconciliation degrades to trust-the-file mode.
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
