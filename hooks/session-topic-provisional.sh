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
# Slash-command first prompts are a special case (a /command's first "prompt" is
# the literal `/name args`, so the heuristic would name the window after the
# command — every /rehydrate becomes "rehydrate", every /review-gh-pr becomes a
# spaceless mash). So:
#   - For PR-bearing commands (/review-gh-pr, /shakedown <pr>) we background a
#     `gh pr view --json title` and set @topic from the PR title — the name that
#     actually matters while a long review runs. Backgrounded so the gh call
#     never blocks the 5 s hook timeout.
#   - For any other slash command we write nothing: the command itself (e.g.
#     /rehydrate) sets @topic from its own subject, or there is nothing better to
#     guess. Either way the naive heuristic must not stamp the command name.
#
# Plain (non-command) prompts keep the original heuristic below:
# lowercase prompt → drop stopwords → first ~4 significant words.
# Synchronous (sub-ms, no LLM) for the plain path; backgrounded for the PR fetch.

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

# Slash-command first prompt: never apply the heuristic to a `/command args`
# string. For PR-bearing commands, background a gh fetch of the PR title and set
# @topic from it; for any other command, write nothing and let the command name
# itself (or stay empty for the Stop hook to handle).
if [[ "$prompt" == /* ]]; then
    cmd="${prompt%% *}"          # e.g. /review-gh-pr
    rest="${prompt#"$cmd"}"      # args after the command
    rest="${rest# }"
    case "$cmd" in
        /review-gh-pr|/shakedown|/review|/review-pr)
            # Extract a PR reference: a bare number, #123, or a PR URL ending /pull/123.
            pr=$(printf '%s' "$rest" \
                | grep -oE '([0-9]+)|(#[0-9]+)|(/pull/[0-9]+)' \
                | grep -oE '[0-9]+' \
                | head -1 || true)
            [[ -z "$pr" ]] && exit 0
            # Background the gh call so the 5 s hook timeout is never at risk.
            (
                title=$(gh pr view "$pr" --json title --jq '.title' 2>/dev/null || true)
                [[ -z "$title" ]] && exit 0
                "$(dirname "${BASH_SOURCE[0]}")/../scripts/set-session-topic.sh" "$title" || true
            ) >/dev/null 2>&1 &
            exit 0
            ;;
        *)
            # Other slash commands: the command sets its own topic (or nothing better exists).
            exit 0
            ;;
    esac
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
