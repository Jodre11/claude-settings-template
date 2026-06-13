#!/usr/bin/env bash
# session-topic.sh — Stop hook. Once per session, guesses a short topic from the
# first user prompt + cwd basename and renames the tmux session to it. The topic
# propagates to the terminal window title, the OS window switcher, and any tool
# (e.g. a status dropdown) that reads the tmux session name — via tmux title
# propagation, no other wiring.
#
# Gating (stateless — no flag files):
#   - CLAUDE_TOPIC_GUESS set  → exit (we are the nested `claude -p`; avoid recursion)
#   - agent_id/agent_type set → exit (subagent turn; don't rename the session)
#   - $TMUX unset             → exit (not in tmux; nothing to rename)
#   - tmux name not an auto-slug → exit (already titled, or manually renamed)
# Only when the name still matches the auto-slug grammar does it guess. The
# guessed topic contains spaces and so can never re-match the grammar, so the
# guess happens exactly once and a manual rename always wins.
#
# The `claude -p` call + rename run backgrounded so the hook returns with no
# user-visible latency. `claude -p` inherits the session env, so model/auth
# resolves the same way the parent session does — no provider branching here.

set -euo pipefail

# Recursion guard: the backgrounded `claude -p` below itself fires Stop hooks.
# This sentinel makes the nested invocation's hook bail before doing anything.
if [[ -n "${CLAUDE_TOPIC_GUESS:-}" ]]; then
    exit 0
fi

input=$(cat)

# Subagent turns carry agent_id / agent_type — never rename on those.
agent_id=$(jq -r '.agent_id // empty' <<< "$input")
agent_type=$(jq -r '.agent_type // empty' <<< "$input")
if [[ -n "$agent_id" || -n "$agent_type" ]]; then
    exit 0
fi

# Not in tmux → nothing to rename.
if [[ -z "${TMUX:-}" ]]; then
    exit 0
fi

session=$(tmux display-message -p '#S' 2>/dev/null || true)
# Auto-slug grammar guard: act only on an un-renamed slug name. The single-letter
# prefix matches any origin convention (e.g. c-/p- for work/personal).
if [[ ! "$session" =~ ^[a-z]-[a-z0-9]+-[0-9a-f]{4}$ ]]; then
    exit 0
fi

transcript_path=$(jq -r '.transcript_path // empty' <<< "$input")
cwd=$(jq -r '.cwd // empty' <<< "$input")
if [[ -z "$transcript_path" || ! -f "$transcript_path" ]]; then
    exit 0
fi
dir_name="${cwd##*/}"

# Everything below runs backgrounded so the Stop hook returns immediately.
(
    # First user prompt: 32 KiB head slice (the first prompt lives at the start),
    # string-type user content only, skipping harness tag-wrapper lines.
    prompt=$(head -c 32768 "$transcript_path" \
        | jq -rc 'select(.type=="user") | .message.content | select(type=="string")' 2>/dev/null \
        | grep -vE '^[[:space:]]*</?[A-Za-z]' \
        | head -1)
    [[ -z "$prompt" ]] && exit 0
    prompt="${prompt:0:500}"

    sys="You name Claude Code coding sessions. Given the user's first message and the project directory name, reply with a 2-4 word lowercase topic label with no punctuation. Examples: fix auth bug, add dark mode, refactor feed parser. Reply with ONLY the label."

    topic=$(printf 'project: %s\nfirst message: %s' "$dir_name" "$prompt" \
        | CLAUDE_TOPIC_GUESS=1 claude -p --model haiku --system-prompt "$sys" 2>/dev/null \
        | head -1 \
        | tr '[:upper:]' '[:lower:]')
    # Normalise: strip anything but lowercase/digits/space, collapse + trim spaces.
    topic=$(printf '%s' "$topic" | sed -E 's/[^a-z0-9 ]//g; s/  +/ /g; s/^ +//; s/ +$//')
    [[ -z "$topic" ]] && exit 0

    tmux rename-session -t "$session" "$topic" 2>/dev/null || true
) >/dev/null 2>&1 &

exit 0
