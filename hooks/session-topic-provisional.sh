#!/usr/bin/env bash
# session-topic-provisional.sh — UserPromptSubmit hook. Writes a cheap heuristic
# @topic immediately on first-prompt submit so the window title has something
# useful while the first (potentially long) turn runs. The Stop hook upgrades
# this to a Haiku-quality topic when it completes.
#
# Gating:
#   - CLAUDE_TOPIC_GUESS set     → exit (avoid recursion from nested claude -p)
#   - agent_id/agent_type set    → exit (subagent; defensive — docs are silent)
#   - $TMUX unset                → exit (not in tmux; nothing to title)
#   - tmux name not an auto-slug → exit (manually renamed; respect human name)
#   - @topic already non-empty   → exit (provisional or final already written)
#
# Heuristic: lowercase prompt → drop stopwords → first ~4 significant words.
# Synchronous (sub-ms, no LLM), no backgrounding.

set -euo pipefail

if [[ -n "${CLAUDE_TOPIC_GUESS:-}" ]]; then
    exit 0
fi

input=$(cat)

agent_id=$(jq -r '.agent_id // empty' <<< "$input")
agent_type=$(jq -r '.agent_type // empty' <<< "$input")
if [[ -n "$agent_id" || -n "$agent_type" ]]; then
    exit 0
fi

if [[ -z "${TMUX:-}" ]]; then
    exit 0
fi

session=$(tmux display-message -p '#S' 2>/dev/null || true)
if [[ ! "$session" =~ ^[a-z]-[a-z0-9]+-[0-9a-f]{4}$ ]]; then
    exit 0
fi

existing_topic=$(tmux show-options -t "$session" -qv @topic 2>/dev/null || true)
if [[ -n "$existing_topic" ]]; then
    exit 0
fi

prompt=$(jq -r '.prompt // empty' <<< "$input")
if [[ -z "$prompt" ]]; then
    exit 0
fi

# Heuristic: lowercase, strip non-alpha/digit/space, drop stopwords, take first 4 words.
heuristic=$(printf '%s' "$prompt" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9 ]//g; s/  +/ /g; s/^ +//; s/ +$//' \
    | tr ' ' '\n' \
    | grep -vxE '(the|a|an|can|you|please|help|me|i|we|to|of|for|and|is|it|this|that|in|on|my|do|if|be|so|are|was|will|would|could|should|have|has|had|not|but|or|with|just|also|its|im|ive|dont|lets|get|got|our|your|some|any|all|been|being|does|did|make|made|how|what|why|when|where|which|who)' \
    | head -4 \
    | tr '\n' ' ' \
    | sed -E 's/ +$//' || true)

if [[ -z "$heuristic" ]]; then
    exit 0
fi

tmux set-option -t "$session" @topic "$heuristic" 2>/dev/null || true
tmux set-option -t "$session" @topic_provisional 1 2>/dev/null || true

exit 0
