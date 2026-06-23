#!/usr/bin/env bash
# set-session-topic.sh — Set the tmux session @topic (window-title description)
# from a command-supplied subject, bypassing the heuristic/Haiku topic hooks.
#
# Commands that know their real subject better than the topic hooks ever could —
# /rehydrate (the handover's one-line title), /shakedown (the PR title) — call
# this to name the window correctly from the start, which matters most for
# long-running turns where the name is on screen for minutes or hours.
#
# It mirrors the topic hooks' gating exactly so it never fights them and never
# clobbers a human rename:
#   - $TMUX unset                → exit (not in tmux; nothing to title)
#   - tmux name not an auto-slug → exit (manually renamed; respect the human name)
#
# Writing @topic and clearing @topic_provisional means the provisional hook (which
# bails when @topic is non-empty) and the Stop hook (which bails when @topic is set
# and @topic_provisional is unset) both treat this as the final topic and leave it
# alone — same contract a manual `/rename` mirror produces.
#
# Usage: set-session-topic.sh "<subject text>"
# Bash 3.2 compatible (macOS system bash).
set -euo pipefail

subject="${1:-}"
[[ -z "$subject" ]] && exit 0

# Not in tmux → no window/session to title.
[[ -z "${TMUX:-}" ]] && exit 0

session=$(tmux display-message -p '#S' 2>/dev/null || true)
# Act only on an un-renamed auto-slug name; a manual rename must win. The
# single-letter prefix matches any origin convention (e.g. work/personal wrappers).
if [[ ! "$session" =~ ^[a-z]-[a-z0-9]+-[0-9a-f]{4}$ ]]; then
    exit 0
fi

# Normalise to the same shape the topic hooks produce: lowercase, strip anything
# but lowercase/digits/space, collapse runs of space, trim, cap at 5 words so a
# long PR title stays a readable window label.
topic=$(printf '%s' "$subject" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9 ]//g; s/  +/ /g; s/^ +//; s/ +$//' \
    | tr ' ' '\n' \
    | head -5 \
    | tr '\n' ' ' \
    | sed -E 's/ +$//' || true)
[[ -z "$topic" ]] && exit 0

tmux set-option -t "$session" @topic "$topic" 2>/dev/null || true
tmux set-option -u -t "$session" @topic_provisional 2>/dev/null || true

exit 0
