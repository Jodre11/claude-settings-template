#!/usr/bin/env bash
# Fixture-driven tests for statusline.sh.
#
# Feeds synthetic statusLine payloads on stdin and asserts on the rendered
# output with ANSI escapes stripped. Fixtures cover both providers: Bedrock
# (rate_limits null, display_name an opaque ARN) and a personal Claude.ai
# subscription (rate_limits present, display_name friendly).
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
STATUSLINE="$SCRIPT_DIR/../statusline.sh"

pass=0
fail=0

strip_ansi() {
    perl -pe 's/\e\[[0-9;]*m//g'
}

# Render the status line for a fixture. Width is pinned so padding assertions
# are stable regardless of the terminal the suite runs in.
render() {
    local json=$1 cols=${2:-120}
    printf '%s' "$json" | COLUMNS="$cols" bash "$STATUSLINE" 2>&1 | strip_ansi
}

# Character count, not byte count — the bar and separators are multi-byte.
row_width() {
    printf '%s' "$1" | perl -CS -ne 'chomp; print length($_)'
}

ok() {
    pass=$((pass + 1))
    printf '  ok   %s\n' "$1"
}

ko() {
    fail=$((fail + 1))
    printf '  FAIL %s\n     %s\n' "$1" "$2"
}

assert_contains() {
    local name=$1 haystack=$2 needle=$3
    if [[ "$haystack" == *"$needle"* ]]; then
        ok "$name"
    else
        ko "$name" "expected to contain '$needle' in:
$haystack"
    fi
}

assert_not_contains() {
    local name=$1 haystack=$2 needle=$3
    if [[ "$haystack" != *"$needle"* ]]; then
        ok "$name"
    else
        ko "$name" "expected NOT to contain '$needle' in:
$haystack"
    fi
}

assert_at_most() {
    local name=$1 got=$2 limit=$3
    if [[ "$got" -le "$limit" ]]; then
        ok "$name"
    else
        ko "$name" "expected at most $limit, got $got"
    fi
}

assert_line_count() {
    local name=$1 haystack=$2 want=$3
    local got
    got=$(printf '%s\n' "$haystack" | grep -c '')
    if [[ "$got" == "$want" ]]; then
        ok "$name"
    else
        ko "$name" "expected $want lines, got $got in:
$haystack"
    fi
}

# ── Fixtures ──────────────────────────────────────────────────────────────
# Bedrock: opaque inference-profile ARN, rate_limits null, cost populated.
read -r -d '' FIX_BEDROCK <<'JSON'
{
  "model": {
    "id": "arn:aws:bedrock:eu-west-1:ACCOUNT-ID:application-inference-profile/PROFILE-ID",
    "display_name": "arn:aws:bedrock:eu-west-1:ACCOUNT-ID:application-inference-profile/PROFILE-ID[1m]"
  },
  "workspace": { "current_dir": "WORKDIR", "project_dir": "WORKDIR" },
  "effort": { "level": "xhigh" },
  "context_window": {
    "used_percentage": 22,
    "context_window_size": 200000,
    "total_input_tokens": 44000,
    "total_output_tokens": 1400
  },
  "cost": {
    "total_cost_usd": 0.41,
    "total_duration_ms": 612000,
    "total_lines_added": 128,
    "total_lines_removed": 34
  },
  "rate_limits": null,
  "exceeds_200k_tokens": false
}
JSON

# Personal: friendly display_name, rate_limits present.
read -r -d '' FIX_PERSONAL <<'JSON'
{
  "model": { "id": "claude-opus-5", "display_name": "Opus 5" },
  "workspace": { "current_dir": "WORKDIR", "project_dir": "WORKDIR" },
  "effort": { "level": "high" },
  "context_window": {
    "used_percentage": 48,
    "context_window_size": 200000,
    "total_input_tokens": 96000,
    "total_output_tokens": 1400
  },
  "cost": {
    "total_cost_usd": 1.24,
    "total_duration_ms": 3720000,
    "total_lines_added": 12,
    "total_lines_removed": 3
  },
  "rate_limits": {
    "five_hour": { "used_percentage": 34, "resets_at": 4102444800 },
    "seven_day": { "used_percentage": 12, "resets_at": 4102444800 }
  },
  "exceeds_200k_tokens": false
}
JSON

# Substitute a real directory in so the git segment has something to read.
fixture() {
    local json=$1 dir=$2
    printf '%s' "${json//WORKDIR/$dir}"
}

# ── Tests ─────────────────────────────────────────────────────────────────
printf 'statusline.sh\n'

# Empty leading fields must not shift later ones: bash `read` collapses runs of
# tabs because tab counts as IFS whitespace even when IFS is set to just tab.
out=$(render '{}')
assert_line_count "survives a payload with no fields at all" "$out" 2
assert_not_contains "does not misparse empty fields" "$out" "invalid number"

out=$(render "$(fixture "$FIX_BEDROCK" "$HOME")")
assert_line_count "renders exactly two lines" "$out" 2
assert_contains "shows the full path untruncated" "$out" "~"
assert_contains "shows the effort level" "$out" "xhigh"

out=$(render "$(fixture "$FIX_PERSONAL" "$HOME")")
assert_contains "prefers the friendly display_name" "$out" "Opus 5"

BEDROCK_ARN="arn:aws:bedrock:eu-west-1:ACCOUNT-ID:application-inference-profile/PROFILE-ID"
out=$(ANTHROPIC_DEFAULT_OPUS_MODEL="$BEDROCK_ARN" render "$(fixture "$FIX_BEDROCK" "$HOME")")
assert_not_contains "never renders a raw ARN as the model label" "$out" "arn:aws:bedrock"
assert_contains "maps an ARN to its tier via the default-model env var" "$out" "Opus"

FIX_NO_EFFORT=${FIX_PERSONAL/'"effort": { "level": "high" },'/}
out=$(render "$(fixture "$FIX_NO_EFFORT" "$HOME")")
assert_not_contains "omits effort when the payload lacks it" "$out" "high"

# 22% of a 20-cell bar is 4 full cells plus 3/8 of the fifth.
out=$(render "$(fixture "$FIX_BEDROCK" "$HOME")")
assert_contains "renders a partially filled bar of exactly 20 cells" "$out" \
    "████▍░░░░░░░░░░░░░░░"

FIX_NULL_PCT=${FIX_PERSONAL/'"used_percentage": 48,'/'"used_percentage": null,'}
out=$(render "$(fixture "$FIX_NULL_PCT" "$HOME")")
assert_contains "renders an empty bar when usage is not yet known" "$out" \
    "░░░░░░░░░░░░░░░░░░░░"

out=$(render "$(fixture "$FIX_PERSONAL" "$HOME")")
assert_contains "renders the 5-hour quota meter when rate_limits is present" "$out" "5h"
assert_contains "renders the 7-day quota meter when rate_limits is present" "$out" "7d"

# Verified empirically on Bedrock: rate_limits is null, but cost still populates.
out=$(render "$(fixture "$FIX_BEDROCK" "$HOME")")
assert_not_contains "omits quota meters when rate_limits is null" "$out" "5h"
# shellcheck disable=SC2016  # literal '$' — asserting on the rendered cost
assert_contains "shows session cost even on Bedrock" "$out" '$0.41'
assert_contains "labels the context window size" "$out" "200K"
assert_contains "shows the status word for low usage" "$out" "GOOD"

FIX_HIGH=${FIX_BEDROCK/'"used_percentage": 22,'/'"used_percentage": 91,'}
out=$(render "$(fixture "$FIX_HIGH" "$HOME")")
assert_contains "shows the status word for high usage" "$out" "HIGH"

# ── Git segment, against purpose-built repos so results are deterministic ──
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

git_q() {
    git -c user.name=test -c user.email=test@example.com -c commit.gpgsign=false "$@" >/dev/null 2>&1
}

REPO="$TMPROOT/work"
mkdir -p "$REPO"
git_q -C "$REPO" init -b main
printf 'one\n' > "$REPO/file.txt"
git_q -C "$REPO" add file.txt
git_q -C "$REPO" commit --no-verify -m one

git_q init --bare -b main "$TMPROOT/origin"
git_q -C "$REPO" remote add origin "$TMPROOT/origin"
git_q -C "$REPO" push -u origin main

out=$(render "$(fixture "$FIX_BEDROCK" "$REPO")")
assert_contains "shows the branch name" "$out" "main"
assert_not_contains "shows no dirty marker on a clean tree" "$out" "●"

printf 'two\n' >> "$REPO/file.txt"
out=$(render "$(fixture "$FIX_BEDROCK" "$REPO")")
assert_contains "marks a dirty working tree" "$out" "●"

git_q -C "$REPO" add file.txt
git_q -C "$REPO" commit --no-verify -m two
out=$(render "$(fixture "$FIX_BEDROCK" "$REPO")")
# ⇡ not ↑ — the latter is the output-token arrow on row 2.
assert_contains "shows the ahead count against upstream" "$out" "⇡1"

git_q -C "$REPO" checkout --detach HEAD
out=$(render "$(fixture "$FIX_BEDROCK" "$REPO")")
assert_contains "reports a detached HEAD" "$out" "detached"

# ── Narrow terminals: row 2 sheds its least useful segments rather than wrap ──
out=$(render "$(fixture "$FIX_PERSONAL" "$REPO")" 80)
mapfile -t rows <<< "$out"
assert_at_most "row 2 fits an 80-column terminal" "$(row_width "${rows[1]}")" 80
assert_contains "keeps the context bar when narrowing" "${rows[1]}" "█"
assert_contains "keeps the status word when narrowing" "${rows[1]}" "GOOD"
assert_contains "keeps the quota meters when narrowing" "${rows[1]}" "5h"
assert_not_contains "sheds the lines-changed segment first" "${rows[1]}" "+12/-3"

# The path is pinned, so when row 1 cannot fit it is the git segment that goes.
git_q -C "$REPO" checkout main
out=$(render "$(fixture "$FIX_BEDROCK" "$REPO")" 60)
mapfile -t rows <<< "$out"
assert_contains "keeps the whole path on a narrow terminal" "${rows[0]}" "$REPO"
assert_not_contains "drops the git segment before truncating the path" "${rows[0]}" "main"

# Shedding must be prefix truncation, not best-fit packing: once a segment does
# not fit, nothing after it may appear either. Otherwise a short low-priority
# segment leapfrogs a long high-priority one — cost outliving the quota meters.
out=$(render "$(fixture "$FIX_PERSONAL" "$REPO")" 80)
mapfile -t rows <<< "$out"
assert_contains "keeps the highest-priority segment at 80 columns" "${rows[1]}" "5h"
# Matched on its percentage, not "7d" — that substring also occurs inside a
# countdown like "26797d".
assert_not_contains "drops the 7-day meter at 80 columns" "${rows[1]}" "12%"
# shellcheck disable=SC2016  # literal '$' — asserting on the rendered cost
assert_not_contains "does not let cost leapfrog a dropped meter" "${rows[1]}" '$1.24'

# A 6-cell bar spans 48 eighths, so anything under ~2.08% floors to zero and an
# in-use quota is indistinguishable from an unused one.
FIX_LOW_QUOTA=${FIX_PERSONAL/'"five_hour": { "used_percentage": 34,'/'"five_hour": { "used_percentage": 1,'}
out=$(render "$(fixture "$FIX_LOW_QUOTA" "$REPO")")
assert_contains "shows a sliver for a quota barely in use" "$out" "5h ▏"

# resets_at is unguarded against a fractional value, unlike used_percentage
# beside it. Under set -e the arithmetic aborts and BOTH rows are lost.
FIX_FRACTIONAL=${FIX_PERSONAL//'"resets_at": 4102444800'/'"resets_at": 4102444800.5'}
out=$(render "$(fixture "$FIX_FRACTIONAL" "$REPO")")
assert_line_count "survives a fractional resets_at" "$out" 2

# Exercise the hours/minutes branch of the countdown, which a year-2100 fixture
# never reaches.
soon=$(($(date +%s) + 17220))
FIX_SOON=${FIX_PERSONAL//4102444800/$soon}
out=$(render "$(fixture "$FIX_SOON" "$REPO")")
assert_contains "renders an hours-and-minutes reset countdown" "$out" "4h"

# First-party reports a 1M window; the 200K fixtures never reach this branch.
FIX_1M=${FIX_PERSONAL/'"context_window_size": 200000,'/'"context_window_size": 1000000,'}
out=$(render "$(fixture "$FIX_1M" "$REPO")")
assert_contains "labels a 1M context window" "$out" "of 1M"

# Bedrock sends rate_limits: null; first-party omits the key entirely before the
# first response. Both must render the same lean row.
FIX_NO_RL=${FIX_PERSONAL/'"rate_limits": {'/'"unused_rate_limits": {'}
out=$(render "$(fixture "$FIX_NO_RL" "$REPO")")
assert_not_contains "omits meters when rate_limits is absent entirely" "$out" "5h"
assert_line_count "still renders two rows without rate_limits" "$out" 2

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
