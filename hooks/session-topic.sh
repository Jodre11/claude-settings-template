#!/usr/bin/env bash
# session-topic.sh — Stop hook. Once per session, guesses a short topic from the
# first user prompt + cwd basename and stores it on the tmux session as a custom
# `@topic` option. A tmux set-titles-string of `#{?@topic,#{@topic},#T}` (see the
# paired tmux config) surfaces it to the terminal window title and OS window
# switcher, and any tool that reads tmux options (e.g. a status dropdown) can pick
# it up. The tmux session keeps its slug NAME and the pane_title is untouched —
# the hook never renames the session.
#
# It also mirrors a manual `/rename` into `@topic`: `/rename` sets Claude Code's
# session title (a transcript `custom-title` record) but never touches tmux, so
# the window title and any @topic reader would miss it. Every turn the hook takes
# the latest NON-slug custom-title and, if it differs, writes it to `@topic` — so
# a manual name wins over the guess and reaches the window title.
#
# Gating (stateless — no flag files; the `@topic` option IS the once-marker):
#   - CLAUDE_TOPIC_GUESS set   → exit (we are the nested `claude -p`; avoid recursion)
#   - agent_id/agent_type set  → exit (subagent turn; not the main session)
#   - $TMUX unset              → exit (not in tmux; nothing to title)
#   - tmux name not an auto-slug → exit (manually renamed; respect the human name)
#   - manual rename present    → mirror it into @topic, then exit (manual wins)
#   - @topic already set AND @topic_provisional unset → exit (final topic; guess once)
#
# The `claude -p` call + `tmux set-option` run backgrounded so the hook returns
# with no user-visible latency. `claude -p` inherits the session env, so model/
# auth resolves the same way the parent session does — no provider branching here.

set -euo pipefail

# Recursion guard: the backgrounded `claude -p` below itself fires Stop hooks.
# This sentinel makes the nested invocation's hook bail before doing anything.
if [[ -n "${CLAUDE_TOPIC_GUESS:-}" ]]; then
    exit 0
fi

input=$(cat)

# Subagent turns carry agent_id / agent_type — never guess on those.
agent_id=$(jq -r '.agent_id // empty' <<< "$input")
agent_type=$(jq -r '.agent_type // empty' <<< "$input")
if [[ -n "$agent_id" || -n "$agent_type" ]]; then
    exit 0
fi

# Not in tmux → nothing to title.
if [[ -z "${TMUX:-}" ]]; then
    exit 0
fi

session=$(tmux display-message -p '#S' 2>/dev/null || true)
# Auto-slug grammar guard: act only on an un-renamed slug name. The single-letter
# prefix matches any origin convention (e.g. c-/p- for work/personal). A manual
# rename produces a non-matching name; we respect it and never write a topic.
if [[ ! "$session" =~ ^[a-z]-[a-z0-9]+-[0-9a-f]{4}$ ]]; then
    exit 0
fi

transcript_path=$(jq -r '.transcript_path // empty' <<< "$input")
cwd=$(jq -r '.cwd // empty' <<< "$input")
if [[ -z "$transcript_path" || ! -f "$transcript_path" ]]; then
    exit 0
fi
dir_name="${cwd##*/}"

existing_topic=$(tmux show-options -t "$session" -qv @topic 2>/dev/null || true)
provisional=$(tmux show-options -t "$session" -qv @topic_provisional 2>/dev/null || true)

# Manual-rename sync: `/rename` writes a `custom-title` record to the transcript
# (it sets Claude Code's session title) but never touches tmux, so the window
# title — which reads `@topic` — would otherwise miss it. Mirror the latest *real*
# rename into `@topic` so a manual name wins over the guess and reaches the title.
#
# A SessionStart hook that emits `sessionTitle=<slug>` (e.g. to seed the slug)
# leaves slug-valued custom-title records on every start/resume, so take the
# latest NON-slug custom-title, never a slug, or a resume would clobber the user's
# rename. `jq -R fromjson?` tolerates the truncated first line of the tail slice.
manual=$(tail -c 65536 "$transcript_path" 2>/dev/null \
    | jq -Rr 'fromjson? | select(.type=="custom-title") | .customTitle // empty' 2>/dev/null \
    | grep -vE '^[a-z]-[a-z0-9]+-[0-9a-f]{4}$' \
    | tail -1 || true)
if [[ -n "$manual" ]]; then
    if [[ "$manual" != "$existing_topic" ]]; then
        tmux set-option -t "$session" @topic "$manual" 2>/dev/null || true
    fi
    tmux set-option -u -t "$session" @topic_provisional 2>/dev/null || true
    exit 0
fi

# Once-only guard: a non-empty `@topic` means we already guessed for this tmux
# session. Resume-safe — a resumed session reattaches to the same tmux session,
# whose `@topic` is already set, so we skip.
if [[ -n "$existing_topic" && -z "$provisional" ]]; then
    exit 0
fi

# Everything below runs backgrounded so the Stop hook returns immediately.
(
    # First user prompt: 32 KiB head slice (the first prompt lives at the start),
    # string-type user content only, skipping harness tag-wrapper lines.
    # `|| true`: the 32 KiB byte-slice cuts the final JSON line mid-object, so jq
    # exits non-zero (parse error on the partial tail) even though every complete
    # line parsed; and `head -1` closes the pipe early, which can SIGPIPE jq. Under
    # `set -euo pipefail` either status would abort this subshell before the write.
    # The genuinely-empty case is still caught by the `[[ -z "$prompt" ]]` guard.
    prompt=$(head -c 32768 "$transcript_path" \
        | jq -rc 'select(.type=="user") | .message.content | select(type=="string")' 2>/dev/null \
        | grep -vE '^[[:space:]]*</?[A-Za-z]' \
        | head -1 || true)
    [[ -z "$prompt" ]] && exit 0
    prompt="${prompt:0:500}"

    sys="You name Claude Code coding sessions. Given the user's first message and the project directory name, reply with a 2-4 word lowercase topic label with no punctuation. Examples: fix auth bug, add dark mode, refactor feed parser. Reply with ONLY the label."

    # `|| true`: if `claude -p` emits more than one line, `head -1` closes the pipe
    # early and SIGPIPEs claude (exit 141); pipefail would propagate it and abort
    # the subshell before the write. The `[[ -z "$topic" ]]` guard below still
    # handles a genuinely empty guess.
    topic=$(printf 'project: %s\nfirst message: %s' "$dir_name" "$prompt" \
        | CLAUDE_TOPIC_GUESS=1 claude -p --model haiku --system-prompt "$sys" 2>/dev/null \
        | head -1 \
        | tr '[:upper:]' '[:lower:]' || true)
    # Normalise: strip anything but lowercase/digits/space, collapse + trim spaces.
    topic=$(printf '%s' "$topic" | sed -E 's/[^a-z0-9 ]//g; s/  +/ /g; s/^ +//; s/ +$//')
    [[ -z "$topic" ]] && exit 0

    # Store the topic on the tmux session. set-titles-string surfaces it to the
    # window title; any tmux-options reader (e.g. a status dropdown) can read it.
    # A single atomic tmux write — no temp file, no half-read race.
    tmux set-option -t "$session" @topic "$topic" 2>/dev/null || true
    tmux set-option -u -t "$session" @topic_provisional 2>/dev/null || true
) >/dev/null 2>&1 &

exit 0
