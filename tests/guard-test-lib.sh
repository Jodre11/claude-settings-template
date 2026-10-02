# shellcheck shell=bash
# shellcheck disable=SC2034  # the suites that source this file read its fixtures, rc and out
# Shared helpers for the git leak guard suites, the tests/test-*.sh files that source it: pass and fail bookkeeping,
# fixtures assembled at run time, and scratch repos that run copies of the tracked guard files under an isolated git
# config, so this repository, any local pattern list on this machine and the user's git config are never touched.
# Sourced, never run. Bash 3.2 compatible.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp=$(mktemp -d)
# Under an EXIT trap, bash 3.2 exits 0 when an unset variable aborts the suite; suite_done makes that exit 1.
trap 'rm -rf "$tmp"; if [ "${suite_done:-0}" != 1 ]; then exit 1; fi' EXIT
export GIT_CONFIG_GLOBAL="$tmp/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.name test
git config --global user.email test@example.invalid
git config --global commit.gpgsign false
git config --global tag.gpgsign false
git config --global init.defaultBranch main
# shellcheck source=../.githooks/guard-config.sh
source "$repo_root/.githooks/guard-config.sh"
passes=0
failures=0
skips=0
rc=0
out=""

# check <description> <expected> <actual>: record PASS when <actual> equals <expected>.
check() {
    if [[ "$3" == "$2" ]]; then
        passes=$((passes + 1))
        echo "PASS $1"
    else
        failures=$((failures + 1))
        echo "FAIL $1 (expected '$2', got '$3')"
    fi
}

# check_match <description> <regex> <actual>: record PASS when <actual> matches <regex>.
check_match() {
    if [[ "$3" =~ $2 ]]; then
        passes=$((passes + 1))
        echo "PASS $1"
    else
        failures=$((failures + 1))
        echo "FAIL $1 (no match for '$2')"
    fi
}

# skip <description> <reason>: record a SKIP.
skip() {
    skips=$((skips + 1))
    echo "SKIP $1 ($2)"
}

# have_gitleaks <description>: return 0 when gitleaks is installed; otherwise record a SKIP and return 1.
have_gitleaks() {
    if command -v gitleaks >/dev/null 2>&1; then
        return 0
    fi
    skip "$1" "gitleaks not installed"
    return 1
}

# plain_entry_after <marker>: print the first single-quoted plain-word pattern in guard-config.sh after the first line
# equal to <marker>.
plain_entry_after() {
    local line seen=0
    while IFS= read -r line; do
        if [[ "$line" == "$1" ]]; then
            seen=1
        elif [[ $seen -eq 1 && "$line" =~ ^\ +\'([A-Za-z0-9]+)\'$ ]]; then
            printf '%s\n' "${BASH_REMATCH[1]}"
            return 0
        fi
    done <"$repo_root/.githooks/guard-config.sh"
}

# exempt_rc <path> <ere>: print 0 when <ere> exempts <path>, else 1: the exit code a commit of a matching word at
# <path> should give.
exempt_rc() {
    if [[ -n "$2" && "$1" =~ $2 ]]; then
        echo 0
    else
        echo 1
    fi
}

word=$(plain_entry_after 'IDENTITY_PATTERNS=(')
handle=$(plain_entry_after '    # Personal')
lower_handle=$(printf '%s' "$handle" | tr '[:upper:]' '[:lower:]')
nuget=$(grep -m 1 -o -E '[A-Z]+_NUGET_PAT' "$repo_root/.githooks/guard-config.sh")
digits=$(printf '%012d' 42)
key=$(printf '%s%s%s' AKIA QWERTYUI OPASDFGH)
placeholder=$(printf '%s%s' 123456 789012)
profile="application-inference-profile/$(printf '%s%s' abcdef 012345)"
local_word="qzv$(printf '%s' localmarker)"
other_word="qzv$(printf '%s' othermarker)"
local_id=$(printf '%012d' 31337)
memory=projects/p/memory/m.md
memory_rc=$(exempt_rc "$memory" "$IDENTITY_EXEMPT_RE")
exempt_samples=("$memory" docs/whisper-prompt-technique.md tests/test-pattern-sync.sh)
# exempt_path: the first sample IDENTITY_EXEMPT_RE exempts, for the rows that check an exemption cannot be spoofed.
exempt_path=$memory
for sample in "${exempt_samples[@]}"; do
    if [[ "$(exempt_rc "$sample" "$IDENTITY_EXEMPT_RE")" == 0 ]]; then
        exempt_path=$sample
        break
    fi
done
exempt_path_rc=$(exempt_rc "$exempt_path" "$IDENTITY_EXEMPT_RE")

# new_repo: create a scratch repo whose first commit holds copies of the guard files, hooks active; print its path.
# The copies are committed because the pre-commit refuses to run gitleaks on an untracked or unstaged .gitleaks.toml.
# No local pattern list is copied.
new_repo() {
    local d f
    d=$(mktemp -d "$tmp/repo.XXXXXX")
    git -C "$d" init -q
    mkdir "$d/.githooks"
    for f in pre-commit pre-push guard-lib.sh guard-config.sh; do
        if [[ -e "$repo_root/.githooks/$f" ]]; then
            cp -p "$repo_root/.githooks/$f" "$d/.githooks/$f"
        fi
    done
    cp "$repo_root/.gitleaks.toml" "$d/.gitleaks.toml"
    git -C "$d" add .githooks .gitleaks.toml
    git -C "$d" -c core.hooksPath=/dev/null commit -q -m init
    git -C "$d" config core.hooksPath .githooks
    printf '%s\n' "$d"
}

# commit_staged <repo> [VAR=value...]: commit what is staged in <repo> with the given environment; set rc and out.
commit_staged() {
    local d="$1"
    shift
    rc=0
    out=$(env "$@" git -C "$d" commit -q -m test 2>&1) || rc=$?
}

# commit_line <repo> <path> <line> [VAR=value...]: append <line> to <path>, stage it and commit with the given
# environment; set rc and out.
commit_line() {
    local d="$1" path="$2" line="$3"
    shift 3
    mkdir -p "$(dirname "$d/$path")"
    printf '%s\n' "$line" >>"$d/$path"
    git -C "$d" add -- "$path"
    commit_staged "$d" "$@"
}

# try <path> <line> [VAR=value...]: commit_line in a fresh scratch repo.
try() {
    commit_line "$(new_repo)" "$@"
}

# with_list <repo> <identity|always> <line>...: write the lines to <repo>'s local pattern list of that kind.
with_list() {
    local d="$1" kind="$2"
    shift 2
    printf '%s\n' "$@" >"$d/.githooks/$kind-patterns.local"
}

# with_ignore <repo> <entry>...: set <repo>'s LOCAL_IDENTITY_IGNORE to the entries, each single-quoted as written, and
# commit guard-config.sh with the hooks off, so its staged and committed copies are the one the hooks read.
with_ignore() {
    local d="$1" entry
    shift
    {
        printf '%s\n' 'LOCAL_IDENTITY_IGNORE=('
        for entry in "$@"; do
            printf "    '%s'\n" "$entry"
        done
        printf '%s\n' ')'
    } >>"$d/.githooks/guard-config.sh"
    git -C "$d" add .githooks/guard-config.sh
    git -C "$d" -c core.hooksPath=/dev/null commit -q -m "set LOCAL_IDENTITY_IGNORE"
}

# with_empty <repo> <array>...: empty each named array in <repo>'s guard-config.sh and commit it with the hooks off.
with_empty() {
    local d="$1" name
    shift
    for name in "$@"; do
        NAME="$name" awk '$0 == ENVIRON["NAME"] "=(" { print ENVIRON["NAME"] "=()"; skip = 1; next }
            skip { if ($0 == ")") skip = 0; next } { print }' "$d/.githooks/guard-config.sh" >"$d/guard-config.sh.new"
        mv "$d/guard-config.sh.new" "$d/.githooks/guard-config.sh"
    done
    git -C "$d" add .githooks/guard-config.sh
    git -C "$d" -c core.hooksPath=/dev/null commit -q -m "empty $*"
}

# without_setting <repo> <name>: delete the line assigning <name> from <repo>'s guard-config.sh, as in a fork whose
# copy predates that setting, and commit it with the hooks off.
without_setting() {
    NAME="$2" awk 'index($0, ENVIRON["NAME"] "=") != 1' "$1/.githooks/guard-config.sh" >"$1/guard-config.sh.new"
    mv "$1/guard-config.sh.new" "$1/.githooks/guard-config.sh"
    git -C "$1" add .githooks/guard-config.sh
    git -C "$1" -c core.hooksPath=/dev/null commit -q -m "drop $2"
}

# try_listed <kind> <list-line> <path> <line> [VAR=value...]: in a fresh scratch repo whose <kind> local list holds
# <list-line>, commit <line> at <path>; set rc and out.
try_listed() {
    local d kind="$1" entry="$2"
    shift 2
    d=$(new_repo)
    with_list "$d" "$kind" "$entry"
    commit_line "$d" "$@"
}

# scan_ids <path> <line>: stage <line> as <path> in a fresh scratch repo and print the comma-joined rule IDs gitleaks
# reports for the staged change (empty when clean).
scan_ids() {
    local d
    d=$(new_repo)
    mkdir -p "$(dirname "$d/$1")"
    printf '%s\n' "$2" >"$d/$1"
    git -C "$d" add -- "$1"
    (cd "$d" && gitleaks git --pre-commit --staged --no-banner --redact --exit-code 0 --config .gitleaks.toml \
        --report-format json --report-path "$d.json" . >/dev/null 2>&1)
    jq -r '[.[].RuleID] | unique | join(",")' "$d.json"
}

# finish: print the summary and exit 1 when any check failed.
finish() {
    suite_done=1
    echo ""
    echo "$((passes + failures + skips)) checks: $passes passed, $failures failed, $skips skipped"
    if [[ $failures -gt 0 ]]; then
        exit 1
    fi
}
