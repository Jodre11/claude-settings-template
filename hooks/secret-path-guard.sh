#!/usr/bin/env bash
# secret-path-guard.sh — PreToolUse hook for Read|Grep. Denies reads of secret-bearing paths, and a content-mode Grep
# whose directory holds a secret file (the directory probe in _lib.sh), so a secret value is never pulled into context.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/_lib.sh"
source "$DIR/secret-patterns.sh"
# Fail SAFE: any unexpected error, or a crash the ERR trap misses, forces a manual permission prompt.
hook_backstop ask "secret-path-guard failed to evaluate; approve manually."
trap 'hook_ask "secret-path-guard failed to evaluate; approve manually."' ERR
hook_read_input

if [[ "${CLAUDE_ALLOW_SECRET_READ:-0}" == "1" ]]; then
    hook_pass
fi

# Read uses file_path; Grep uses path (the directory it searches).
path=$(hook_field '.tool_input.file_path')
if [[ -z "$path" ]]; then
    path=$(hook_field '.tool_input.path')
fi

name_fold "$path"
if [[ -n "$path" ]] && path_is_secret "$NAME_FOLD"; then
    hook_deny "SECRET-PATH BLOCK: '$path' matches a secret-bearing path (e.g. **/secrets/**, .env, *.pem, .strongbox-keyid). Reading it would pull a secret into context. Have a script write the value to \$CLAUDE_TEMP_DIR and consume it there, or set CLAUDE_ALLOW_SECRET_READ=1 for a deliberate one-off."
fi
# A content-mode Grep prints the matching lines of every file it searches; files_with_matches and count print names or
# counts only. Its root is the Grep's path, or the payload's cwd; the Grep tool honours .gitignore, so git lists it.
if [[ "$(hook_field '.tool_name')" == Grep && "$(hook_field '.tool_input.output_mode')" == content ]]; then
    cwd=$(hook_field '.cwd')
    cwd="${cwd:-$PWD}"
    if ! norm_path "${path:-$cwd}" "$cwd" literal; then
        msg="SECRET-PROBE ASK: a content-mode Grep of '$path' names a directory the hook cannot resolve. Approve it"
        msg+=" only if no secret-bearing file is under it."
        hook_hold_ask "$msg"
    elif [[ -d "$NORM_PATH" ]]; then
        root="$NORM_PATH"
        if probe_root_too_wide "$root"; then
            msg="SECRET-PROBE BLOCK: a content-mode Grep of '$root' reads every file at or above \$HOME or the secret"
            msg+=" vault (~/.aws, ~/.ssh and the vault sit below it). Search a narrower path."
            hook_deny "$msg"
        fi
        glob=$(hook_field '.tool_input.glob')
        inc=""
        exc=""
        # Narrow only by a plain name glob (ASCII letters, digits and . _ - * ?, with an optional leading !). The Grep
        # tool may split a glob on separators, and rg's /, **, braces and brackets differ from bash's, so a bash match
        # could drop a file rg reads; any other glob fails closed and leaves the root unnarrowed.
        body="${glob#!}"
        if probe_glob_plain "$body"; then
            if [[ "$glob" == '!'* ]]; then
                exc="$body"
            else
                inc="$glob"
            fi
        fi
        probe_add git "$root" Grep "$inc" "$exc" "" || :
        rc=0
        dir_holds_secret || rc=$?
        if (( rc == 0 )); then
            msg="SECRET-PROBE BLOCK: a content-mode Grep of '$root' prints the contents of secret-bearing files there"
            msg+=" ($DHS_HITS). Search a narrower path, leave them out with glob, or use output_mode"
            msg+=" files_with_matches or count."
            hook_deny "$msg"
        elif (( rc == 2 )); then
            msg="SECRET-PROBE ASK: a content-mode Grep of '$root' could not be checked for secret-bearing files:"
            msg+=" $DHS_WHY. Approve it only if none is under that directory."
            hook_hold_ask "$msg"
        fi
    fi
fi
hook_pass
