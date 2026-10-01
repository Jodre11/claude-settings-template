#!/usr/bin/env bash
# Verifies that the git guards' pattern sources and .gitleaks.toml carry the same custom patterns, that those patterns
# suit awk's ERE, and that the gitleaks allowlists are well formed. The sources are the NAME_PATTERNS=( ... ) arrays of
# .githooks/pre-commit or .githooks/guard-config.sh, and the lists .githooks/always-patterns.txt and
# .githooks/identity-patterns.txt, each where present. Gitignored *.local lists are machine-local and not checked.
# Run locally or in CI: bash tests/test-pattern-sync.sh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
gitleaks_toml="$repo_root/.gitleaks.toml"
array_files=(.githooks/pre-commit .githooks/guard-config.sh)
list_files=(.githooks/always-patterns.txt .githooks/identity-patterns.txt)
errors=0
precommit_atoms=()
gitleaks_atoms=()
rule_ids=()
sources=()

# fail <message>: report one failed check.
fail() {
    echo "  FAIL: $1"
    errors=$((errors + 1))
}

# collect_array_atoms <file>: add every entry of <file>'s NAME_PATTERNS=( ... ) arrays, each of which must be a
# single-quoted literal, to precommit_atoms; return 1 when <file> holds no entry.
collect_array_atoms() {
    local line in_array=0 found=1
    while IFS= read -r line; do
        if [[ "$line" =~ ^[A-Z_]+_PATTERNS=\($ ]]; then
            in_array=1
        elif [[ $in_array -eq 1 && "$line" == ")" ]]; then
            in_array=0
        elif [[ $in_array -eq 1 ]]; then
            line="${line#"${line%%[![:space:]]*}"}"
            if [[ -z "$line" || "$line" == \#* ]]; then
                continue
            fi
            if [[ "$line" =~ ^\'([^\']*)\'$ ]]; then
                precommit_atoms+=("${BASH_REMATCH[1]}")
                found=0
            else
                fail "pattern is not a single-quoted literal in $1: $line"
            fi
        fi
    done <"$repo_root/$1"
    return "$found"
}

# collect_list_atoms <file>: add every pattern line of <file> to precommit_atoms, skipping blank and # lines; return 1
# when <file> holds no pattern.
collect_list_atoms() {
    local line found=1
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ -z "$line" || "$line" == \#* ]]; then
            continue
        fi
        if [[ "$line" =~ ^[[:space:]] || "$line" =~ [[:space:]]$ ]]; then
            fail "pattern has leading or trailing whitespace in $1: '$line'"
        fi
        precommit_atoms+=("$line")
        found=0
    done <"$repo_root/$1"
    return "$found"
}

# collect_precommit_atoms: gather the atoms of every source present, and record each source that holds one in sources.
collect_precommit_atoms() {
    local f
    for f in "${array_files[@]}"; do
        if [[ -f "$repo_root/$f" ]] && collect_array_atoms "$f"; then
            sources+=("$f")
        fi
    done
    for f in "${list_files[@]}"; do
        if [[ -f "$repo_root/$f" ]] && collect_list_atoms "$f"; then
            sources+=("$f")
        fi
    done
    if [[ ${#sources[@]} -eq 0 ]]; then
        fail "no pattern source found: expected ${array_files[*]} or ${list_files[*]}"
    fi
}

# collect_gitleaks_atoms: add each custom rule's regex to gitleaks_atoms, minus its leading (?i) and split on | when
# what remains is one group of plain alternatives; add each rule id to rule_ids. Every regex must start (?i): the
# pre-commit lowercases both the line and its patterns, and gitleaks has no bypass, so it must match at least as much.
collect_gitleaks_atoms() {
    local line body id=""
    local -a parts
    while IFS= read -r line; do
        if [[ "$line" =~ ^id\ =\ \"(.+)\"$ ]]; then
            id="${BASH_REMATCH[1]}"
            rule_ids+=("$id")
        elif [[ "$line" =~ ^regex\ =\ \'\'\'(.*)\'\'\'$ ]]; then
            body="${BASH_REMATCH[1]}"
            if [[ "$body" != '(?i)'* ]]; then
                fail "custom rule is case-sensitive, unlike the pre-commit: $id"
            fi
            body="${body#'(?i)'}"
            if [[ "$body" =~ ^\(([^()]*)\)$ ]]; then
                IFS='|' read -r -a parts <<<"${BASH_REMATCH[1]}"
                gitleaks_atoms+=("${parts[@]}")
            else
                gitleaks_atoms+=("$body")
            fi
        fi
    done <"$gitleaks_toml"
}

# check_sync: every custom pattern must appear in both a pattern source and .gitleaks.toml.
check_sync() {
    local atom
    while IFS= read -r atom; do
        fail "only in the pre-commit: $atom"
    done < <(LC_ALL=C comm -23 <(printf '%s\n' "${precommit_atoms[@]}" | LC_ALL=C sort -u) \
        <(printf '%s\n' "${gitleaks_atoms[@]}" | LC_ALL=C sort -u))
    while IFS= read -r atom; do
        fail "only in .gitleaks.toml: $atom"
    done < <(LC_ALL=C comm -13 <(printf '%s\n' "${precommit_atoms[@]}" | LC_ALL=C sort -u) \
        <(printf '%s\n' "${gitleaks_atoms[@]}" | LC_ALL=C sort -u))
}

# check_awk_syntax: the pre-commit matches with awk's ERE, where \s, \d, \w, \b and (?: never match.
check_awk_syntax() {
    local atom
    for atom in "${precommit_atoms[@]}"; do
        if [[ "$atom" =~ \\[sdwb]|\(\?: ]]; then
            fail "PCRE-only syntax in a pre-commit pattern: $atom"
        fi
    done
}

# check_allowlists: every pattern source and .gitleaks.toml sit in an allowlist, targetRules is the only spelling, and
# every rule it names is defined.
check_allowlists() {
    local guard id
    local -a guards=('\.gitleaks\.toml')
    for guard in "${sources[@]}"; do
        guards+=("${guard//./\\.}")
    done
    for guard in "${guards[@]}"; do
        if ! grep -q -F "$guard" "$gitleaks_toml"; then
            fail "guard file is not in a .gitleaks.toml allowlist: $guard"
        fi
    done
    if grep -q '^target_rules' "$gitleaks_toml"; then
        fail "use targetRules, not target_rules"
    fi
    while IFS= read -r id; do
        if ! printf '%s\n' "${rule_ids[@]}" | grep -q -x -F "$id"; then
            fail "targetRules names an unknown rule: $id"
        fi
    done < <(awk '/^targetRules = \[/ { s = $0; while (s !~ /\]/ && (getline l) > 0) s = s l; print s }' \
        "$gitleaks_toml" | grep -o -E '"[^"]+"' | tr -d '"')
}

collect_precommit_atoms
collect_gitleaks_atoms
check_sync
check_awk_syntax
check_allowlists

if [[ $errors -gt 0 ]]; then
    echo "FAILED: $errors error(s)"
    exit 1
fi
echo "PASSED: pattern sync checks OK"
