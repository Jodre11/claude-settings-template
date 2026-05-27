#!/usr/bin/env bash
# derive-claude-slug.sh — Mnemonic, low-collision slug for tmux session / Claude
# sessionTitle. Used by both the zsh `claude` wrapper and session-init.sh so the
# format is defined exactly once.
#
# Format: <prefix>-<abbrev>-<4hex>
#
# Abbrev rule (cwd basename → short readable token):
#   - strip a leading dot (`.claude` → `claude`)
#   - if it contains `-` `_` `.` separators: take first letter of each non-empty
#     segment (`claude-settings-template` → `cst`)
#   - else: first 8 chars verbatim (`dotfiles` → `dotfiles`)
#   - lowercase
#
# Suffix: 4 hex chars (16-bit, ~65k space). Random by default; pass an explicit
# value as $1 to make derivation deterministic (the hook does this with the
# first 4 hex of session_id so the slug is stable across resumes).
#
# Prefix: defaults to `c`. Pass `$2` to override (`p` for claude-personal, etc).
set -euo pipefail

cwd="${PWD:-/}"
basename="${cwd##*/}"
basename="${basename#.}"
[[ -z "$basename" ]] && basename="root"

if [[ "$basename" == *[-_.]* ]]; then
    abbrev=""
    # IFS=$'-_.' splits on any of -, _, . — works in bash 3.2 (no brew bash needed).
    OLD_IFS="$IFS"
    IFS=$'-_.'
    read -r -a parts <<< "$basename"
    IFS="$OLD_IFS"
    for part in "${parts[@]}"; do
        [[ -n "$part" ]] && abbrev+="${part:0:1}"
    done
else
    abbrev="${basename:0:8}"
fi
abbrev=$(printf '%s' "$abbrev" | tr '[:upper:]' '[:lower:]')

suffix="${1:-}"
[[ -z "$suffix" ]] && suffix=$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')

prefix="${2:-c}"

printf '%s-%s-%s\n' "$prefix" "$abbrev" "$suffix"
