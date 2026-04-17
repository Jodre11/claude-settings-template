#!/usr/bin/env bash
# statusline.sh — Claude Code status line renderer.
# Reads JSON from stdin, outputs an ANSI-coloured status line:
#   [model] ~/path (branch)  ...padding...  7%
#
# Single jq call extracts all fields; single git call gets branch.
# Context % is coloured green (≤50%), amber (≤80%), or red (>80%).
#
# The -6 in the padding formula accounts for the ANSI escape overhead
# that is present in the rendered left_part but absent from left_plain.
set -euo pipefail

input=$(cat)

# ── Extract all needed fields in one jq call (TSV) ──
IFS=$'\t' read -r model_id cwd_raw context_size input_tok cache_create cache_read <<< "$(
    jq -r '[
        .model.id // "",
        .workspace.current_dir // "",
        .context_window.context_window_size // 200000,
        .context_window.current_usage.input_tokens // 0,
        .context_window.current_usage.cache_creation_input_tokens // 0,
        .context_window.current_usage.cache_read_input_tokens // 0
    ] | @tsv' <<< "$input"
)"

# ── Model type: case substring match first, then env var fallback for Bedrock ARNs ──
# Direct API model IDs contain the tier name (e.g. claude-opus-4-6).
# Bedrock ARNs are opaque slugs — fall back to comparing against ANTHROPIC_DEFAULT_*_MODEL.
model_type="unknown"
case "$model_id" in
    *opus*)   model_type=opus ;;
    *sonnet*) model_type=sonnet ;;
    *haiku*)  model_type=haiku ;;
    *)
        if [[ -n "${ANTHROPIC_DEFAULT_OPUS_MODEL:-}" && "$model_id" == "$ANTHROPIC_DEFAULT_OPUS_MODEL" ]]; then
            model_type=opus
        elif [[ -n "${ANTHROPIC_DEFAULT_SONNET_MODEL:-}" && "$model_id" == "$ANTHROPIC_DEFAULT_SONNET_MODEL" ]]; then
            model_type=sonnet
        elif [[ -n "${ANTHROPIC_DEFAULT_HAIKU_MODEL:-}" && "$model_id" == "$ANTHROPIC_DEFAULT_HAIKU_MODEL" ]]; then
            model_type=haiku
        fi
        ;;
esac

# ── Working directory (cygpath for Windows, tilde-shorten for display) ──
if command -v cygpath >/dev/null 2>&1; then
    cwd=$(cygpath -u "$cwd_raw")
else
    cwd="$cwd_raw"
fi
if [[ "$cwd" == "$HOME"* ]]; then
    cwd_short="~${cwd#$HOME}"
else
    cwd_short="$cwd"
fi

# ── Terminal width ──
term_width=$(stty size 2>/dev/null </dev/tty | cut -d' ' -f2) || true
[[ -z "$term_width" ]] && term_width=${COLUMNS:-80}

# ── Context usage percentage (coloured) ──
ctx_pct=""
ctx_pct_plain=""
if [[ "$input_tok" -gt 0 || "$cache_create" -gt 0 || "$cache_read" -gt 0 ]]; then
    total=$((input_tok + cache_create + cache_read))
    pct=$((total * 100 / context_size))
    if [[ "$pct" -le 50 ]]; then
        col='\033[32m'
    elif [[ "$pct" -le 80 ]]; then
        col='\033[33m'
    else
        col='\033[31m'
    fi
    ctx_pct=$(printf '%b%d%%\033[0m' "$col" "$pct")
    ctx_pct_plain="${pct}%"
fi

# ── Left side: [model] ~/path (branch) ──
left_part=$(printf '\033[32m[%s]\033[0m \033[36m%s\033[0m' "$model_type" "$cwd_short")
left_plain="[$model_type] $cwd_short"

# Single git call for the common case; fallback for detached HEAD (rebase/bisect)
if branch=$(git -C "$cwd" symbolic-ref --short -q HEAD 2>/dev/null); then
    left_part="$left_part $(printf '\033[33m(%s)\033[0m' "$branch")"
    left_plain="$left_plain ($branch)"
elif git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
    left_part="$left_part $(printf '\033[33m(%s)\033[0m' 'detached')"
    left_plain="$left_plain (detached)"
fi

# ── Assemble with padding ──
left_len=${#left_plain}
right_len=${#ctx_pct_plain}
padding=$((term_width - left_len - right_len - 6))  # -6: ANSI escape byte overhead (left_part vs left_plain)
[[ $padding -lt 1 ]] && padding=1

printf '%b%*s%b' "$left_part" "$padding" "" "$ctx_pct"
