#!/usr/bin/env bash
# Lint the repository's shell files as CI does: one file set, one shellcheck run at warning severity, with no rc file
# and no SHELLCHECK_OPTS, so a personal ~/.shellcheckrc cannot pass locally what CI fails. Exits 1 when the set is
# empty, 127 when shellcheck is not installed, else with shellcheck's status. (No comment here may start with the
# tool's name: shellcheck reads such a line as a directive.)
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
files=()
while IFS= read -r -d '' f; do
    files+=("$f")
done < <(find . -type f \( -name '*.sh' -path './hooks/*' \
    -o -name '*.sh' -path './scripts/*' \
    -o -name 'hydrate.sh' \
    -o -path './tests/*.sh' \
    -o -path './tests/lib/*' \
    -o -path './.githooks/pre-commit' \
    -o -path './.githooks/pre-push' \
    -o -path './.githooks/*.sh' \
    -o -path './tools/aws-secret-field' \
    -o -path './tools/md2clip' \) -print0)
if (( ${#files[@]} == 0 )); then
    echo "shellcheck.sh: no files to lint" >&2
    exit 1
fi
if ! command -v shellcheck >/dev/null 2>&1; then
    echo "shellcheck is not installed" >&2
    exit 127
fi
unset SHELLCHECK_OPTS
exec shellcheck --norc --severity=warning -f gcc "${files[@]}"
