# shellcheck shell=bash
# Shared code for .githooks/pre-commit and .githooks/pre-push: the pattern sets and their loader, the line scanners,
# the git environment gitleaks runs under, and gitleaks' built-ins-only pass. Sourced by both hooks, never run. The
# repository's own patterns and path exemptions are in .githooks/guard-config.sh. Bash 3.2 compatible.

guard_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=guard-config.sh
source "$guard_dir/guard-config.sh"

# A replace ref would show every git call below, gitleaks' included, a blob other than the one a commit records.
export GIT_NO_REPLACE_OBJECTS=1

# The optional, gitignored local lists: one POSIX ERE per line, blank and # lines ignored. identity-patterns.local
# holds identity markers and is exempt only where LOCAL_IDENTITY_EXEMPT_RE says; always-patterns.local holds
# secret-shaped literals and bites on every path. Neither may ever be committed. They are read from beside these
# hooks and, when that differs, from the main worktree's .githooks/, found through git's common directory: a linked
# worktree's checkout holds no untracked file, so without this its commits and pushes would run with no lists.
local_list_dirs=("$guard_dir")
guard_common_dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
if [ "${guard_common_dir##*/}" = .git ] && [ -d "${guard_common_dir%/.git}/.githooks" ]; then
    guard_main_dir="$(cd "${guard_common_dir%/.git}/.githooks" && pwd)"
    if [ "$guard_main_dir" != "$guard_dir" ]; then
        local_list_dirs+=("$guard_main_dir")
    fi
fi
local_list_path_re='^\.githooks/(identity|always)-patterns\.local$'

# The guard files define the tracked patterns (the pre-commit did, before guard-config.sh), so the pattern scans exempt
# them, in history too, from the identity patterns and from each ALWAYS_PATTERNS entry whose own text it matches (the
# private-key marker, a PAT name), which their definitions would trip; every other ALWAYS_PATTERNS entry and the local
# lists still apply to them. .gitleaks.toml's allowlists name them as well.
guard_file_re='^\.githooks/(guard-config\.sh|pre-commit)$|^\.gitleaks\.toml$'

# Constructs awk's ERE does not support: in a pattern they never match as meant, so the scan would fail open. The
# upper-case forms count too, since every pattern is lowercased, which turns \S into \s.
pcre_only_re='\\[sdwbSDWB]|\(\?:'

# The hook sourcing this file names itself in hook_name, for its messages.
hook_name=${hook_name:-Git hook}

# guard_fail <line>...: print each line to stderr, then exit 1.
guard_fail() {
    printf '%s\n' "$@" >&2
    exit 1
}

# join_patterns <pattern>...: print the patterns joined into one ERE alternation.
join_patterns() {
    local combined="" p
    for p in "$@"; do
        combined="${combined:+$combined|}$p"
    done
    printf '%s' "$combined"
}

# check_pattern <pattern> <source>: exit 1 when <pattern> uses a construct awk's ERE does not support.
check_pattern() {
    if [[ "$1" =~ $pcre_only_re ]]; then
        guard_fail "❌ $hook_name: $2 holds a pattern awk cannot match as written: $1" \
            "Replace \\s, \\d, \\w or \\b with a bracket expression such as [[:space:]], and (?: with (."
    fi
}

# read_pattern_list <file>: fill loaded_patterns from <file>, skipping blank and # lines and stripping a trailing CR.
# A missing file leaves loaded_patterns empty. Exit 1 when <file> is a dangling symlink or unreadable, holds no
# pattern, holds one with leading or trailing whitespace (which would only match padded text), or holds one awk
# cannot match as written, so a local list the user relies on can never fail open.
read_pattern_list() {
    local line
    loaded_patterns=()
    if [ ! -e "$1" ] && [ ! -L "$1" ]; then
        return 0
    fi
    if [ ! -f "$1" ] || [ ! -r "$1" ]; then
        guard_fail "❌ $hook_name: $1 is not a readable file (a dangling symlink?), so the scan cannot run."
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        case "$line" in
            '' | '#'*) continue ;;
            [[:space:]]* | *[[:space:]])
                guard_fail "❌ $hook_name: $1 has a pattern with leading or trailing whitespace; the scan cannot run."
                ;;
        esac
        check_pattern "$line" "$1"
        loaded_patterns+=("$line")
    done <"$1"
    if [ "${#loaded_patterns[@]}" -eq 0 ]; then
        guard_fail "❌ $hook_name: $1 holds no pattern, so the scan cannot run. Add a pattern or delete the file."
    fi
}

# read_local_lists <kind>: fill local_patterns with the patterns of every <kind>-patterns.local in local_list_dirs,
# each read and checked by read_pattern_list.
read_local_lists() {
    local dir
    local_patterns=()
    for dir in "${local_list_dirs[@]}"; do
        read_pattern_list "$dir/$1-patterns.local"
        local_patterns+=(${loaded_patterns[@]+"${loaded_patterns[@]}"})
    done
}

# load_patterns: check the tracked patterns, read the local lists, and export the four pattern sets and the
# exemption as GUARD_* variables for the awk scanners, which read them through ENVIRON so that no escape sequence is
# rewritten on the way in. An absent local list exports an empty set, which matches nothing.
load_patterns() {
    local p
    for p in "${ALWAYS_PATTERNS[@]}" "${IDENTITY_PATTERNS[@]}"; do
        check_pattern "$p" .githooks/guard-config.sh
    done
    GUARD_ALWAYS_RE=$(join_patterns "${ALWAYS_PATTERNS[@]}")
    GUARD_ALWAYS_LIST=$(printf '%s\n' "${ALWAYS_PATTERNS[@]}")
    GUARD_IDENTITY_RE=$(join_patterns "${IDENTITY_PATTERNS[@]}")
    read_local_lists always
    GUARD_LOCAL_ALWAYS_RE=$(join_patterns ${local_patterns[@]+"${local_patterns[@]}"})
    read_local_lists identity
    GUARD_LOCAL_IDENTITY_RE=$(join_patterns ${local_patterns[@]+"${local_patterns[@]}"})
    GUARD_IDENTITY_EXEMPT_RE="$IDENTITY_EXEMPT_RE"
    GUARD_LOCAL_IDENTITY_EXEMPT_RE="$LOCAL_IDENTITY_EXEMPT_RE"
    GUARD_ALWAYS_EXEMPT_RE="$ALWAYS_EXEMPT_RE"
    GUARD_FILE_RE="$guard_file_re"
    export GUARD_ALWAYS_RE GUARD_ALWAYS_LIST GUARD_IDENTITY_RE GUARD_LOCAL_ALWAYS_RE GUARD_LOCAL_IDENTITY_RE \
        GUARD_IDENTITY_EXEMPT_RE GUARD_LOCAL_IDENTITY_EXEMPT_RE GUARD_ALWAYS_EXEMPT_RE GUARD_FILE_RE
}

# The awk body both scanners share: the pattern sets, lowercased; guard_always_re, the ALWAYS_PATTERNS entries that do
# not match their own text, for the guard files; path_matches(path, re), true when a non-empty re matches a known path;
# and line_hits(text, identity_exempt, local_identity_exempt, always_exempt, guard_file), true when the lowercased text
# matches a set it is not exempt from. always-patterns.local has no exemption. UTF-8 continuation bytes are dropped
# from the text and from every pattern alike, so each character counts once, the {0,24} windows count characters, not
# bytes, and a non-ASCII pattern still matches; the AWS documentation account ID 123456789012 is removed, so it never
# counts as an account ID.
guard_awk_common='
    BEGIN {
        always_re = folded(ENVIRON["GUARD_ALWAYS_RE"])
        guard_always_re = ""
        n = split(folded(ENVIRON["GUARD_ALWAYS_LIST"]), always_list, "\n")
        for (i = 1; i <= n; i++) {
            if (always_list[i] != "" && always_list[i] !~ always_list[i]) {
                guard_always_re = guard_always_re (guard_always_re == "" ? "" : "|") always_list[i]
            }
        }
        identity_re = folded(ENVIRON["GUARD_IDENTITY_RE"])
        local_always_re = folded(ENVIRON["GUARD_LOCAL_ALWAYS_RE"])
        local_identity_re = folded(ENVIRON["GUARD_LOCAL_IDENTITY_RE"])
        identity_exempt_re = ENVIRON["GUARD_IDENTITY_EXEMPT_RE"]
        local_identity_exempt_re = ENVIRON["GUARD_LOCAL_IDENTITY_EXEMPT_RE"]
        always_exempt_re = ENVIRON["GUARD_ALWAYS_EXEMPT_RE"]
        guard_file_re = ENVIRON["GUARD_FILE_RE"]
    }
    function folded(s) {
        s = tolower(s)
        gsub(/[\200-\277]/, "", s)
        return s
    }
    function path_matches(path, re) {
        return path != "" && re != "" && path ~ re
    }
    function line_hits(text, identity_exempt, local_identity_exempt, always_exempt, guard_file,    line, re) {
        line = tolower(text)
        gsub(/[\200-\277]/, "", line)
        gsub(/123456789012/, "", line)
        re = guard_file ? guard_always_re : always_re
        if (!always_exempt && re != "" && line ~ re) return 1
        if (local_always_re != "" && line ~ local_always_re) return 1
        if (!identity_exempt && identity_re != "" && line ~ identity_re) return 1
        return !local_identity_exempt && local_identity_re != "" && line ~ local_identity_re
    }
'

# scan_patch: read a git diff, or a git log -p stream whose commits start "commit <sha>", on standard input and print
# "[<sha>] <path>: <line>" for every added line that matches a set it is not exempt from. Lines are tracked by hunk,
# so an added line whose text starts "++" is still scanned. The path comes from the "+++ b/" header before the first
# hunk, which no path text can spoof; a path git must quote (one holding a quote, a backslash or a control character)
# gets no exemption. The guard files, which define the tracked patterns, are exempt only as guard_file_re's comment
# says: the local lists and every ALWAYS_PATTERNS entry their definitions cannot trip still apply, since a hand-ported
# pattern hunk lands there. The caller pins the diff format and drops NUL bytes; this runs in the C locale, so a byte
# that is not valid UTF-8 cannot stop it.
scan_patch() {
    LC_ALL=C awk "$guard_awk_common"'
        /^commit [0-9a-f]+$/ { commit = substr($2, 1, 12) " "; in_hunk = 0; next }
        /^diff --git / {
            path = ""
            shown = ""
            identity_exempt = 0
            local_identity_exempt = 0
            always_exempt = 0
            in_hunk = 0
            next
        }
        !in_hunk && /^\+\+\+ / {
            shown = substr($0, 5)
            sub(/\t$/, "", shown)
            path = ""
            if (shown ~ /^b\//) {
                shown = substr(shown, 3)
                path = shown
            }
            guard_file = path_matches(path, guard_file_re)
            identity_exempt = guard_file || path_matches(path, identity_exempt_re)
            local_identity_exempt = path_matches(path, local_identity_exempt_re)
            always_exempt = path_matches(path, always_exempt_re)
            next
        }
        /^@@/ { in_hunk = 1; next }
        !in_hunk || !/^\+/ { next }
        line_hits(substr($0, 2), identity_exempt, local_identity_exempt, always_exempt, guard_file) {
            print commit shown ": " $0
        }
    '
}

# scan_text <label> <identity-lines>: read commit or tag metadata on standard input and print "<label>: <line>" for
# every line that matches ALWAYS_PATTERNS or a local list. The tracked IDENTITY_PATTERNS are public by definition,
# since guard-config.sh publishes them, and the history of a repository that documents them names them, so they guard
# file content only. In the first <identity-lines> lines (the author, committer or tagger), a GitHub noreply address,
# <id+handle@users.noreply.github.com> with a handle GitHub could issue, is removed first, since GitHub publishes it
# on every commit anyway; anywhere else such a string is scanned like any other text.
scan_text() {
    LC_ALL=C awk -v label="$1" -v identity_lines="$2" "$guard_awk_common"'
        {
            text = tolower($0)
            if (NR <= identity_lines) {
                gsub(/<[0-9]+\+[a-z0-9-]{1,39}@users\.noreply\.github\.com>/, "<>", text)
            }
            if (line_hits(text, 1, 0, 0, 0)) print label ": " $0
        }
    '
}

# is_local_list <path>: return 0 when <path> names one of the local lists, in any case.
is_local_list() {
    local lower
    lower=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    [[ "$lower" =~ $local_list_path_re ]]
}

# refuse_local_lists <what>: read NUL-terminated paths on standard input; print a refusal naming <what> and return 1
# when one is a local list. There is no bypass.
refuse_local_lists() {
    local path
    while IFS= read -r -d '' path; do
        if is_local_list "$path"; then
            printf '%s\n' "❌ $hook_name: $1 $path, a machine-local pattern list. It must never be committed:" \
                "it names what the repository must not publish. There is no bypass. Remove it from the commit." >&2
            return 1
        fi
    done
}

# with_pinned_git [NAME=value...] <command> [arg...]: run <command> with git's diff and log output pinned. gitleaks runs
# git itself: a coloured diff hides every added line, a changed path prefix breaks the anchored path allowlists, rename
# detection hides content moved out of an allowlisted path, log.showRoot=false hides a root commit's whole diff,
# another i18n.logOutputEncoding re-encodes every message the scans read, and log.showSignature inserts lines before
# them. git -c settings arrive in
# GIT_CONFIG_PARAMETERS, which outranks GIT_CONFIG_COUNT, so it is dropped. The hooks run their own git calls for
# content gitleaks git cannot read under this same environment, so both read one config and one set of attributes.
with_pinned_git() {
    env -u GIT_CONFIG_PARAMETERS \
        GIT_CONFIG_COUNT=10 \
        GIT_CONFIG_KEY_0=color.ui GIT_CONFIG_VALUE_0=never \
        GIT_CONFIG_KEY_1=color.diff GIT_CONFIG_VALUE_1=never \
        GIT_CONFIG_KEY_2=diff.noprefix GIT_CONFIG_VALUE_2=false \
        GIT_CONFIG_KEY_3=diff.mnemonicPrefix GIT_CONFIG_VALUE_3=false \
        GIT_CONFIG_KEY_4=diff.srcPrefix GIT_CONFIG_VALUE_4=a/ \
        GIT_CONFIG_KEY_5=diff.dstPrefix GIT_CONFIG_VALUE_5=b/ \
        GIT_CONFIG_KEY_6=diff.renames GIT_CONFIG_VALUE_6=false \
        GIT_CONFIG_KEY_7=log.showRoot GIT_CONFIG_VALUE_7=true \
        GIT_CONFIG_KEY_8=i18n.logOutputEncoding GIT_CONFIG_VALUE_8=UTF-8 \
        GIT_CONFIG_KEY_9=log.showSignature GIT_CONFIG_VALUE_9=false \
        "$@"
}

# extend_is_defaults_only <file>: return 0 only when <file> holds exactly the canonical [extend] block: [extend]
# followed immediately (blank and # lines aside) by useDefault = true, and nothing else naming extend in any case or
# spelling. Any other use of extend could hand the scan to a file outside the committed config. It matches the
# canonical form exactly rather than parsing TOML, because case folding, key escapes and a multi-line string each
# defeated a parser-based check.
extend_is_defaults_only() {
    LC_ALL=C awk '
        BEGIN { extend_count = 0; expect = 0; bad = 0 }
        {
            raw = $0
            stripped = raw
            sub(/[ \t]+$/, "", stripped)
            trimmed = stripped
            sub(/^[ \t]+/, "", trimmed)
            if (trimmed == "" || substr(trimmed, 1, 1) == "#") {
                next
            }
            first = substr(trimmed, 1, 1)
            if ((first == "[" || first == "\"") && index(raw, "\\") > 0) {
                bad = 1
            }
            eq_pos = index(raw, "=")
            bs_pos = index(raw, "\\")
            if (eq_pos > 0 && bs_pos > 0 && bs_pos < eq_pos) {
                bad = 1
            }
            if (expect == 1) {
                if (stripped == "useDefault = true") {
                    expect = 2
                } else {
                    bad = 1
                    expect = 0
                }
            } else if (expect == 2) {
                if (first != "[") {
                    bad = 1
                }
                expect = 0
            }
            is_header = (stripped == "[extend]")
            if (is_header) {
                extend_count++
                expect = 1
            } else if (index(tolower(raw), "extend") > 0) {
                bad = 1
            }
        }
        END {
            if (extend_count != 1) {
                bad = 1
            }
            if (expect == 1) {
                bad = 1
            }
            exit (bad ? 1 : 0)
        }
    ' "$1"
}

# builtins_exempt <path>: return 0 when BUILTINS_EXEMPT_RE exempts <path> from the built-ins pass. It matches in the C
# locale, so no byte in a path changes the match; an empty BUILTINS_EXEMPT_RE exempts nothing.
builtins_exempt() (
    export LC_ALL=C
    [[ -n "$BUILTINS_EXEMPT_RE" && "$1" =~ $BUILTINS_EXEMPT_RE ]]
)

# in_scan_dir <command> [arg...]: run <command> from the empty directory in scan_dir, in a subshell, so a gitleaks run
# there finds no .gitleaksignore or .gitleaks.toml of the repository's.
in_scan_dir() (
    cd "${scan_dir:?}" || exit 1
    exec "$@"
)

# builtins_gitleaks: run gitleaks stdin over standard input from scan_dir with its built-in rules alone: GITLEAKS_CONFIG
# is dropped, and GITLEAKS_CONFIG_TOML, which then decides the config, holds only the canonical defaults.
builtins_gitleaks() {
    in_scan_dir env -u GITLEAKS_CONFIG GITLEAKS_CONFIG_TOML=$'[extend]\nuseDefault = true\n' \
        gitleaks stdin --no-banner --redact --ignore-gitleaks-allow
}
