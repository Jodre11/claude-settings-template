#!/usr/bin/env bash
# statusline.sh — Claude Code status line renderer.
#
# Two rows, always:
#   row 1  ◆ <model> <effort>  <full path>  ·  <branch><git state>
#   row 2  <context bar> <pct> of <size> · <status>  │  metrics…
#
# Row 1 always shows model, effort and the untruncated path. Row 2 segments
# self-hide when their payload data is absent, so Bedrock (no rate_limits)
# and a personal subscription render from one code path.
#
# Visual vocabulary (terracotta palette, eighth-block bar, model diamond,
# status word) adapted from Dreambase Panel by @kyleledbetter, MIT:
# https://github.com/kyleledbetter/claudecode-statusline
set -euo pipefail

# Keep %.2f decimal separators stable regardless of the caller's locale, while
# preserving a UTF-8 ctype so ${#var} counts characters rather than bytes —
# segment-width arithmetic depends on it. LC_ALL would outrank LC_NUMERIC, so
# it is demoted to LC_CTYPE rather than left set.
if [[ -n "${LC_ALL:-}" ]]; then
    LC_CTYPE="${LC_CTYPE:-$LC_ALL}"
    unset LC_ALL
fi
export LC_CTYPE
export LC_NUMERIC=C
probe='█'
[[ ${#probe} -eq 1 ]] || export LC_CTYPE=UTF-8

# ── Palette (256-colour) ──
R=$'\033[0m'
B=$'\033[1m'
D=$'\033[2m'
RUST=$'\033[38;5;173m'
RUST_B=$'\033[38;5;209m'
RUST_D=$'\033[38;5;131m'
GRN=$'\033[38;5;34m'
LIME=$'\033[38;5;118m'
YEL=$'\033[38;5;220m'
ORG=$'\033[38;5;208m'
RED=$'\033[38;5;196m'
CYN=$'\033[38;5;81m'
BLU=$'\033[38;5;69m'
PUR=$'\033[38;5;141m'
WHT=$'\033[38;5;255m'
GRY=$'\033[38;5;243m'

fmt_tok() {
    local n=$1
    if [[ $n -ge 1000000 ]]; then
        printf '%d.%dM' $((n / 1000000)) $(((n % 1000000) / 100000))
    elif [[ $n -ge 1000 ]]; then
        printf '%d.%dK' $((n / 1000)) $(((n % 1000) / 100))
    else
        printf '%d' "$n"
    fi
}

fmt_dur() {
    local s=$(($1 / 1000)) h m
    h=$((s / 3600))
    m=$(((s % 3600) / 60))
    if [[ $h -gt 0 ]]; then
        printf '%dh %dm' "$h" "$m"
    elif [[ $m -gt 0 ]]; then
        printf '%dm %ds' "$m" $((s % 60))
    else
        printf '%ds' "$s"
    fi
}

# Time until a rate-limit window resets, from an epoch-seconds timestamp.
# Reads $now so the clock is sampled once per render rather than per segment.
fmt_reset() {
    # Guarded because set -e turns a non-integer timestamp into an arithmetic
    # abort that loses both rows, not just this segment.
    local ts=${1%%.*} left
    [[ "$ts" =~ ^[0-9]+$ ]] || return 0
    left=$((ts - now))
    [[ $left -lt 0 ]] && left=0
    if [[ $left -ge 86400 ]]; then
        printf '%dd' $((left / 86400))
    elif [[ $left -ge 3600 ]]; then
        printf '%dh%dm' $((left / 3600)) $(((left % 3600) / 60))
    else
        printf '%dm' $((left / 60))
    fi
}

input=$(cat)

# ── Extract all needed fields in one jq call ──
# Newline-delimited rather than TSV: bash `read` treats tab as IFS whitespace
# even when IFS is set to only tab, so runs of empty fields would collapse and
# silently shift every later value.
mapfile -t FIELDS < <(
    jq -r '[
        .model.id // "",
        .model.display_name // "",
        .workspace.current_dir // "",
        .effort.level // "",
        .context_window.used_percentage // 0,
        .context_window.context_window_size // 200000,
        .context_window.total_input_tokens // 0,
        .context_window.total_output_tokens // 0,
        .cost.total_cost_usd // 0,
        .cost.total_duration_ms // 0,
        .cost.total_lines_added // 0,
        .cost.total_lines_removed // 0,
        (.exceeds_200k_tokens // false),
        .rate_limits.five_hour.used_percentage // "",
        .rate_limits.five_hour.resets_at // "",
        .rate_limits.seven_day.used_percentage // "",
        .rate_limits.seven_day.resets_at // ""
    ] | .[]' <<< "$input"
)

model_id=${FIELDS[0]}
model_name=${FIELDS[1]}
cwd_raw=${FIELDS[2]}
effort=${FIELDS[3]}
pct=${FIELDS[4]}
ctx_size=${FIELDS[5]}
in_tok=${FIELDS[6]}
out_tok=${FIELDS[7]}
cost=${FIELDS[8]}
dur_ms=${FIELDS[9]}
lines_add=${FIELDS[10]}
lines_del=${FIELDS[11]}
exceeds=${FIELDS[12]}
rl5_pct=${FIELDS[13]}
rl5_reset=${FIELDS[14]}
rl7_pct=${FIELDS[15]}
rl7_reset=${FIELDS[16]}

# ── Model tier and label ──
# Bedrock inference-profile ARNs are opaque, so the tier falls back to comparing
# against the ANTHROPIC_DEFAULT_*_MODEL vars that select them.
case "$model_id" in
    *opus*)   tier=Opus ;;
    *sonnet*) tier=Sonnet ;;
    *haiku*)  tier=Haiku ;;
    *fable*)  tier=Fable ;;
    *mythos*) tier=Mythos ;;
    *)
        if [[ -n "${ANTHROPIC_DEFAULT_OPUS_MODEL:-}" && "$model_id" == "${ANTHROPIC_DEFAULT_OPUS_MODEL}" ]]; then
            tier=Opus
        elif [[ -n "${ANTHROPIC_DEFAULT_SONNET_MODEL:-}" && "$model_id" == "${ANTHROPIC_DEFAULT_SONNET_MODEL}" ]]; then
            tier=Sonnet
        elif [[ -n "${ANTHROPIC_DEFAULT_HAIKU_MODEL:-}" && "$model_id" == "${ANTHROPIC_DEFAULT_HAIKU_MODEL}" ]]; then
            tier=Haiku
        else
            tier=unknown
        fi
        ;;
esac

# display_name is the raw inference-profile ARN until the first API call
# completes on Bedrock, so it is only trusted when it does not look like one.
if [[ -n "$model_name" && "$model_name" != arn:* ]]; then
    model_label="$model_name"
else
    model_label="$tier"
fi

case "$tier" in
    Opus)   m_col=$RUST_B ;;
    Sonnet) m_col=$BLU ;;
    Haiku)  m_col=$GRN ;;
    Fable)  m_col=$PUR ;;
    *)      m_col=$GRY ;;
esac

# ── Working directory (cygpath for Windows, tilde-shorten for display) ──
if command -v cygpath >/dev/null 2>&1; then
    cwd=$(cygpath -u "$cwd_raw")
else
    cwd="$cwd_raw"
fi
if [[ "$cwd" == "$HOME"* ]]; then
    cwd_short="~${cwd#"$HOME"}"
else
    cwd_short="$cwd"
fi

# ── Git state ──
# One porcelain=v2 call yields branch, upstream divergence and dirtiness
# together; deliberately uncached, since a shared cache would report another
# repository's branch when several sessions run concurrently.
branch=""
dirty=""
ahead=0
behind=0
if git_status=$(git -C "$cwd" status --porcelain=v2 --branch 2>/dev/null); then
    while IFS= read -r line; do
        case "$line" in
            '# branch.head '*)
                branch="${line#\# branch.head }"
                ;;
            '# branch.ab '*)
                ab="${line#\# branch.ab }"
                ahead="${ab%% *}"
                ahead="${ahead#+}"
                behind="${ab##* }"
                behind="${behind#-}"
                ;;
            '#'*) ;;
            ?*) dirty="●" ;;
        esac
    done <<< "$git_status"
    [[ "$branch" == "(detached)" ]] && branch="detached"
fi

# ── Eighth-block bar (shared by the context and quota meters) ──
BLOCKS=" ▏▎▍▌▋▊▉█"

make_bar() {
    local value=$1 width=$2 eighths full partial empty out=""
    eighths=$((value * width * 8 / 100))
    # A 6-cell bar spans only 48 eighths, so sub-2.08% usage would floor to an
    # empty bar and read as unused. Any non-zero value gets at least a sliver.
    [[ $eighths -eq 0 && $value -gt 0 ]] && eighths=1
    full=$((eighths / 8))
    partial=$((eighths % 8))
    [[ $full -gt $width ]] && full=$width
    empty=$((width - full))
    while [[ $full -gt 0 ]]; do
        out+="█"
        full=$((full - 1))
    done
    if [[ $partial -gt 0 && $empty -gt 0 ]]; then
        out+="${BLOCKS:partial:1}"
        empty=$((empty - 1))
    fi
    while [[ $empty -gt 0 ]]; do
        out+="░"
        empty=$((empty - 1))
    done
    printf '%s' "$out"
}

# ── Assemble ──
pct=${pct%%.*}
[[ -z "$pct" ]] && pct=0

if [[ $pct -ge 95 ]]; then
    bar_col=$RED status_plain=CRITICAL status="${RED}${B}CRITICAL${R}"
elif [[ $pct -ge 85 ]]; then
    bar_col=$ORG status_plain=HIGH status="${ORG}HIGH${R}"
elif [[ $pct -ge 70 ]]; then
    bar_col=$YEL status_plain=MODERATE status="${YEL}MODERATE${R}"
elif [[ $pct -ge 50 ]]; then
    bar_col=$LIME status_plain=OK status="${LIME}OK${R}"
else
    bar_col=$GRN status_plain=GOOD status="${GRN}GOOD${R}"
fi

# ── Terminal width ──
term_width=""
if tty_size=$(stty size 2>/dev/null </dev/tty); then
    term_width=${tty_size#* }
fi
[[ -z "$term_width" ]] && term_width=${COLUMNS:-80}
[[ "$term_width" =~ ^[0-9]+$ ]] || term_width=80

if [[ $ctx_size -ge 1000000 ]]; then
    ctx_label="$((ctx_size / 1000000))M"
else
    ctx_label="$((ctx_size / 1000))K"
fi

warn=""
[[ "$exceeds" == "true" ]] && warn=" ${RED}${B}⚠${R}"

row1="${m_col}◆${R} ${m_col}${B}${model_label}${R}"
row1_plain="◆ ${model_label}"
if [[ -n "$effort" ]]; then
    row1+=" ${GRY}${effort}${R}"
    row1_plain+=" ${effort}"
fi
row1+="  ${CYN}${cwd_short}${R}"
row1_plain+="  ${cwd_short}"

# Model, effort and the full path are pinned; git is what gives way when the
# row will not fit.
if [[ -n "$branch" ]]; then
    git_ansi="${PUR}${branch}${R}"
    git_plain="$branch"
    if [[ -n "$dirty" ]]; then
        git_ansi+=" ${YEL}${dirty}${R}"
        git_plain+=" ${dirty}"
    fi
    if [[ "$ahead" -gt 0 ]]; then
        git_ansi+=" ${GRN}⇡${ahead}${R}"
        git_plain+=" ⇡${ahead}"
    fi
    if [[ "$behind" -gt 0 ]]; then
        git_ansi+=" ${ORG}⇣${behind}${R}"
        git_plain+=" ⇣${behind}"
    fi
    if [[ $((${#row1_plain} + 5 + ${#git_plain})) -le $term_width ]]; then
        row1+="  ${RUST_D}·${R}  ${git_ansi}"
    fi
fi

ctx_bar=$(make_bar "$pct" 20)
core="${bar_col}${ctx_bar}${R}  ${WHT}${B}${pct}%${R}${warn}"
core+=" ${D}of${R} ${RUST}${ctx_label}${R}  ${RUST_D}·${R}  ${status}"
core_plain="${ctx_bar}  ${pct}%${warn:+ ⚠} of ${ctx_label}  ·  ${status_plain}"

# Row-2 segments in descending priority. When the row will not fit, the ones
# nearest the end are dropped, so the meters outlive the vanity metrics.
seg_ansi=()
seg_plain=()
add_seg() {
    seg_ansi+=("$1")
    seg_plain+=("$2")
}

# Quota meters exist only on a Claude.ai subscription; on Bedrock rate_limits
# is null, so both segments drop out entirely.
if [[ -n "$rl5_pct" || -n "$rl7_pct" ]]; then
    now=$(date +%s)
fi
for window in "5h:$rl5_pct:$rl5_reset" "7d:$rl7_pct:$rl7_reset"; do
    q_label=${window%%:*}
    q_rest=${window#*:}
    q_pct=${q_rest%%:*}
    q_reset=${q_rest#*:}
    [[ -z "$q_pct" ]] && continue
    q_pct=${q_pct%%.*}
    q_bar=$(make_bar "$q_pct" 6)
    q_left=$(fmt_reset "$q_reset")
    add_seg "${D}${q_label}${R} ${q_bar} ${q_pct}% ${GRY}${q_left}${R}" \
        "${q_label} ${q_bar} ${q_pct}% ${q_left}"
done

cost_s=$(printf '%.2f' "$cost")
[[ "$cost_s" != "0.00" ]] && add_seg "${YEL}\$${cost_s}${R}" "\$${cost_s}"

in_s=$(fmt_tok "$in_tok")
out_s=$(fmt_tok "$out_tok")
add_seg "${BLU}↓${R} ${in_s}  ${PUR}↑${R} ${out_s}" "↓ ${in_s}  ↑ ${out_s}"

[[ "$dur_ms" -gt 0 ]] && add_seg "${GRY}⏱ $(fmt_dur "$dur_ms")${R}" "⏱ $(fmt_dur "$dur_ms")"

if [[ "$lines_add" -gt 0 || "$lines_del" -gt 0 ]]; then
    add_seg "${GRN}+${lines_add}${R}${D}/${R}${RED}-${lines_del}${R}" "+${lines_add}/-${lines_del}"
fi

row2="$core"
row2_len=${#core_plain}
for i in "${!seg_plain[@]}"; do
    seg_len=$((5 + ${#seg_plain[i]}))
    # Stop at the first segment that will not fit rather than skipping it —
    # continuing would let a short low-priority segment leapfrog a dropped
    # high-priority one.
    [[ $((row2_len + seg_len)) -gt $term_width ]] && break
    row2+="  ${RUST_D}│${R}  ${seg_ansi[i]}"
    row2_len=$((row2_len + seg_len))
done

printf '%s\n%s\n' "$row1" "$row2"
