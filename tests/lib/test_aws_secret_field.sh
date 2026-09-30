#!/usr/bin/env bash
# Tests for tools/aws-secret-field against a stub aws CLI. Sourced by tests/run.sh.

# _asf_fixture <dir>: install a stub `aws` in <dir>/bin. It appends each argv to <dir>/argv.log (one argument per
# line), answers get-secret-value with a fixed JSON secret, and for put-secret-value copies a file:// payload to
# <dir>/payload.json, its mode string to <dir>/payload.mode and its path to <dir>/payload.path.
_asf_fixture() {
    mkdir -p "$1/bin"
    cat >"$1/bin/aws" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$ASF_DIR/argv.log"
if [[ "$2" == get-secret-value ]]; then
    printf '%s\n' '{"token":"old","keep":"1"}'
    exit 0
fi
prev=""
for a in "$@"; do
    if [[ "$prev" == --secret-string && "$a" == file://* ]]; then
        cp "${a#file://}" "$ASF_DIR/payload.json"
        ls -l "${a#file://}" | cut -c1-10 >"$ASF_DIR/payload.mode"
        printf '%s\n' "${a#file://}" >"$ASF_DIR/payload.path"
    fi
    prev="$a"
done
STUB
    chmod +x "$1/bin/aws"
}

# _asf_run <dir> <stdin> <args...>: run the tool against the stub; sets ASF_RC.
_asf_run() {
    local dir="$1" input="$2"
    shift 2
    ASF_RC=0
    printf '%s\n' "$input" | ASF_DIR="$dir" PATH="$dir/bin:$PATH" \
        bash "$REPO_ROOT/tools/aws-secret-field" "$@" >"$dir/out.txt" 2>&1 || ASF_RC=$?
}

test_aws_secret_field_reads_value_from_stdin() {
    local tmp payload gone
    tmp=$(mktemp -d)
    _asf_fixture "$tmp"
    _asf_run "$tmp" 'n3w-v4lue' token - --secret-id app/x
    assert_equals 0 "$ASF_RC" "aws-secret-field succeeds with - (value from stdin)"
    assert_equals '"n3w-v4lue"' "$(jq -c '.token' "$tmp/payload.json" 2>/dev/null)" "the stdin value is written"
    assert_equals '"1"' "$(jq -c '.keep' "$tmp/payload.json" 2>/dev/null)" "the other fields are kept"
    assert_equals '' "$(grep -F 'n3w-v4lue' "$tmp/argv.log" || true)" "the new value never reaches aws argv"
    assert_equals '-rw-------' "$(cat "$tmp/payload.mode" 2>/dev/null)" "the payload file is owner-only"
    payload=$(cat "$tmp/payload.path" 2>/dev/null || true)
    gone=no
    if [[ -n "$payload" && ! -e "$payload" ]]; then
        gone=yes
    fi
    assert_equals yes "$gone" "the payload file is removed on exit"
    rm -rf "$tmp"
}

test_aws_secret_field_keeps_secret_json_off_argv() {
    local tmp
    tmp=$(mktemp -d)
    _asf_fixture "$tmp"
    _asf_run "$tmp" '' token literal-value --secret-id app/x
    assert_equals 0 "$ASF_RC" "aws-secret-field still accepts the value as an argument"
    assert_equals '"literal-value"' "$(jq -c '.token' "$tmp/payload.json" 2>/dev/null)" "the argument value is written"
    assert_equals '' "$(grep -F '"keep"' "$tmp/argv.log" || true)" "the updated secret JSON never reaches aws argv"
    rm -rf "$tmp"
}
