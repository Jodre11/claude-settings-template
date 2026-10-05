#!/usr/bin/env bash
# Hermetic tests for session-init.sh: session-ID validation, the CLAUDE_ENV_FILE export and the context JSON.
#
# Runs the hook with TMUX unset and a scratch CLAUDE_ENV_FILE. Every non-empty test ID starts with $PREFIX, so any
# directory the hook could create falls under one glob, which is removed before each hook run and on exit.
#
# Usage: session-init.test.sh [path-to-hook]   (defaults to the sibling hook)
# Exit 0 iff every case passes.
set -u

HOOK="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/session-init.sh}"
# Per process, so concurrent runs never clean up or observe each other's directories.
PREFIX="5e5e0000-$$-"
VALID_ID="${PREFIX}0000-4000-8000-000000000001"
VAULT="/tmp/claude-${VALID_ID}-vault"
EXPORT_LINE="export CLAUDE_SESSION_ID=${VALID_ID} CLAUDE_TEMP_DIR=/tmp/claude-${VALID_ID}"
EXPORT_LINE+=" CLAUDE_SECRET_DIR=${VAULT}/secrets"
SEED_LINE="export UNRELATED=kept"
pass=0; fail=0
ok()  { printf 'PASS: %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); }

scratch=$(mktemp -d "${CLAUDE_TEMP_DIR:-/tmp}/si-test.XXXX") || { printf 'FAIL: mktemp -d\n'; exit 1; }
clean_ids() { rm -rf /tmp/claude-"$PREFIX"*; }
trap 'clean_ids; rm -rf "$scratch"' EXIT

# invoke_hook <id> [env-arg...]: feeds {"session_id": <id>} to the hook under `env -u TMUX <env-arg...>`, leaving any
# existing test directory in place. Sets $out (stdout) and $rc (exit status); stderr goes to $scratch/err.
invoke_hook() {
    local id="$1"; shift
    out=$(jq -n --arg id "$id" '{session_id: $id}' | env -u TMUX "$@" "$HOOK" 2> "$scratch/err")
    rc=$?
}

# run_hook <id> [env-arg...]: invoke_hook on a clean slate.
run_hook() {
    clean_ids
    invoke_hook "$@"
}

check_exit_zero() {
    if [[ $rc -eq 0 ]]; then ok "$1: exit 0"; else bad "$1: exit $rc ($(cat "$scratch/err"))"; fi
}

# The shared "context JSON intact" assertion, against the last run_hook.
assert_context() {
    local id="$1" label="$2"
    local want="CLAUDE_SESSION_ID=${id} CLAUDE_TEMP_DIR=/tmp/claude-${id}"
    want+=" CLAUDE_SECRET_DIR=/tmp/claude-${id}-vault/secrets"
    if jq -e --arg want "$want" '
        .hookSpecificOutput.hookEventName == "SessionStart"
        and .hookSpecificOutput.additionalContext == $want
        and (.hookSpecificOutput.sessionTitle | type == "string" and length > 0)' <<< "$out" > /dev/null 2>&1; then
        ok "$label: context JSON intact"
    else
        bad "$label: context JSON broken: '$out'"
    fi
}

# assert_sourced <env-file> <label>: sourcing the file in a clean shell yields the valid ID's values, and the sourced
# vault lies beside the sourced session directory, not inside it.
assert_sourced() {
    local sourced temp_dir secret_dir
    # shellcheck disable=SC2016 # $1 and the variables expand in the child shell
    sourced=$(env -i "$BASH" -c 'source "$1"; printf "%s %s %s" "$CLAUDE_SESSION_ID" "$CLAUDE_TEMP_DIR" \
        "$CLAUDE_SECRET_DIR"' _ "$1")
    if [[ "$sourced" == "$VALID_ID /tmp/claude-$VALID_ID $VAULT/secrets" ]]; then
        ok "$2: sourcing the env file in a clean shell yields all three values"
    else
        bad "$2: sourced values are '$sourced'"
    fi
    read -r _ temp_dir secret_dir <<< "$sourced"
    if [[ -n "$temp_dir" && -n "$secret_dir" && "$secret_dir" != "$temp_dir"/* ]]; then
        ok "$2: the sourced vault is outside the sourced session directory"
    else
        bad "$2: the sourced vault '$secret_dir' is missing or inside '$temp_dir'"
    fi
}

seed_env_file() {
    printf '%s\n' "$SEED_LINE" > "$1"
}

# The env file sits under a directory name with a space, as a CLAUDE_CONFIG_DIR path may.
case_valid_id() {
    local label="valid ID" env_file="$scratch/dir with space/c1.env" want="$scratch/c1.want"
    mkdir "$scratch/dir with space"
    seed_env_file "$env_file"
    run_hook "$VALID_ID" CLAUDE_ENV_FILE="$env_file"
    check_exit_zero "$label"
    printf '%s\n%s\n' "$SEED_LINE" "$EXPORT_LINE" > "$want"
    if cmp -s "$env_file" "$want"; then
        ok "$label: seed line kept, exactly one export line appended"
    else
        bad "$label: env file is '$(cat "$env_file")'"
    fi
    assert_sourced "$env_file" "$label"
    if [[ -d "/tmp/claude-$VALID_ID" ]]; then ok "$label: temp dir exists"; else bad "$label: temp dir missing"; fi
    assert_vault "$label"
    assert_context "$VALID_ID" "$label"
}

# assert_vault <label>: the vault and its secrets/ exist with mode 0700.
assert_vault() {
    local d
    for d in "$VAULT" "$VAULT/secrets"; do
        if [[ -d "$d" && -n "$(find "$d" -maxdepth 0 -perm 0700)" ]]; then
            ok "$1: ${d##*/} exists with mode 0700"
        else
            bad "$1: ${d##*/} missing or not mode 0700"
        fi
    done
}

# A repeat run restores mode 0700 on a vault something has opened up.
case_vault_mode_restored() {
    local label="vault mode restored"
    run_hook "$VALID_ID" -u CLAUDE_ENV_FILE
    chmod 0755 "$VAULT" "$VAULT/secrets"
    invoke_hook "$VALID_ID" -u CLAUDE_ENV_FILE
    check_exit_zero "$label"
    assert_vault "$label"
}

# assert_no_vault_export <label> <env-file>: the last hook run exited 0 and exported the session values, but no vault.
assert_no_vault_export() {
    local want="CLAUDE_SESSION_ID=${VALID_ID} CLAUDE_TEMP_DIR=/tmp/claude-${VALID_ID}"
    check_exit_zero "$1"
    printf '%s\n%s\n' "$SEED_LINE" "${EXPORT_LINE% CLAUDE_SECRET_DIR=*}" > "$scratch/novault.want"
    if cmp -s "$2" "$scratch/novault.want"; then
        ok "$1: the env line carries the session values and no CLAUDE_SECRET_DIR"
    else
        bad "$1: env file is '$(cat "$2")'"
    fi
    if jq -e --arg want "$want" '.hookSpecificOutput.additionalContext == $want' <<< "$out" > /dev/null 2>&1; then
        ok "$1: the context carries the session values and no CLAUDE_SECRET_DIR"
    else
        bad "$1: context is '$out'"
    fi
    if [[ -d "/tmp/claude-$VALID_ID" ]]; then ok "$1: temp dir exists"; else bad "$1: temp dir missing"; fi
}

# A vault path that is a symlink is not used, and the hook does not act through it.
case_vault_symlink() {
    local label="vault path is a symlink" env_file="$scratch/c6.env" target="$scratch/symlink-target"
    mkdir "$target"
    chmod 0755 "$target"
    seed_env_file "$env_file"
    clean_ids
    ln -s "$target" "$VAULT"
    invoke_hook "$VALID_ID" CLAUDE_ENV_FILE="$env_file"
    assert_no_vault_export "$label" "$env_file"
    if [[ -z "$(find "$target" -mindepth 1)" && -n "$(find "$target" -maxdepth 0 -perm 0755)" ]]; then
        ok "$label: the symlink's target is untouched"
    else
        bad "$label: the hook created or changed something through the symlink"
    fi
}

# A regular file at the vault path must not abort the hook.
case_vault_regular_file() {
    local label="vault path is a regular file" env_file="$scratch/c7.env"
    seed_env_file "$env_file"
    clean_ids
    printf 'x\n' > "$VAULT"
    invoke_hook "$VALID_ID" CLAUDE_ENV_FILE="$env_file"
    assert_no_vault_export "$label" "$env_file"
}

case_no_env_file() {
    run_hook "$VALID_ID" -u CLAUDE_ENV_FILE
    check_exit_zero "CLAUDE_ENV_FILE unset"
    assert_context "$VALID_ID" "CLAUDE_ENV_FILE unset"
    run_hook "$VALID_ID" CLAUDE_ENV_FILE=
    check_exit_zero "CLAUDE_ENV_FILE empty"
    assert_context "$VALID_ID" "CLAUDE_ENV_FILE empty"
}

case_malformed_ids() {
    local env_file="$scratch/c3.env" want="$scratch/c3.want" i label leaked
    local ids=("" "${PREFIX}a/b" "${PREFIX}a b" "${PREFIX}\$(id)" "${PREFIX}a"$'\n'"id")
    local labels=("empty" "slash" "space" "literal \$(id)" "embedded newline")
    seed_env_file "$want"
    for i in "${!ids[@]}"; do
        label="malformed ID (${labels[$i]})"
        seed_env_file "$env_file"
        run_hook "${ids[$i]}" CLAUDE_ENV_FILE="$env_file"
        leaked=$(compgen -G "/tmp/claude-${PREFIX}*")
        if [[ $rc -eq 0 && -z "$out" && -z "$leaked" ]] && cmp -s "$env_file" "$want"; then
            ok "$label: exit 0, no output, env file unchanged, no directory"
        else
            bad "$label: rc=$rc out='$out' env='$(cat "$env_file")' dirs='$leaked'"
        fi
    done
}

case_unwritable_env_file() {
    local label="unwritable CLAUDE_ENV_FILE"
    # A path beneath a regular file fails with ENOTDIR for every user, root included.
    printf 'x\n' > "$scratch/not-a-dir"
    run_hook "$VALID_ID" CLAUDE_ENV_FILE="$scratch/not-a-dir/env.sh"
    check_exit_zero "$label"
    assert_context "$VALID_ID" "$label"
}

# A repeat SessionStart for one session (resume, compact) appends an identical line; the values must not change.
case_repeat_run() {
    local label="repeat run" env_file="$scratch/c5.env" want="$scratch/c5.want"
    seed_env_file "$env_file"
    run_hook "$VALID_ID" CLAUDE_ENV_FILE="$env_file"
    run_hook "$VALID_ID" CLAUDE_ENV_FILE="$env_file"
    check_exit_zero "$label"
    printf '%s\n%s\n%s\n' "$SEED_LINE" "$EXPORT_LINE" "$EXPORT_LINE" > "$want"
    if cmp -s "$env_file" "$want"; then
        ok "$label: one more identical export line appended"
    else
        bad "$label: env file is '$(cat "$env_file")'"
    fi
    assert_sourced "$env_file" "$label"
}

case_valid_id
case_no_env_file
case_malformed_ids
case_unwritable_env_file
case_repeat_run
case_vault_mode_restored
case_vault_symlink
case_vault_regular_file
echo "-----"
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
