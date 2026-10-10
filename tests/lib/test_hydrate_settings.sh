#!/usr/bin/env bash
# Tests for hydrate.sh. Every case runs a scratch copy of hydrate.sh beside fixture files, so the live
# settings.json is never read or written. Covers the text templates (render, preview, failed write), the
# settings.json merge (unions, __remove__, env filtering, precedence), the fresh-clone path and its preview, the
# atomic write and its failure paths, the key-order-insensitive preview, and the real settings.json.tmpl against a
# live-shaped existing file.

# _hy_fixture <dir>: copy hydrate.sh into <dir> beside a fixture config.env (AWS_PROFILE deliberately empty).
_hy_fixture() {
    mkdir -p "$1"
    cp "$REPO_ROOT/hydrate.sh" "$1/hydrate.sh"
    printf '%s\n' 'AWS_SSO_REFRESH_PATH=/fx/refresh.sh' 'AWS_PROFILE=' 'SEARXNG_URL=https://searx.test' \
        'SSO_START_URL=https://sso.test/start' 'DATADOG_SITE=datadoghq.test' 'DATADOG_EXAMPLE_SERVICE=svc' \
        'DOTFILES_REPO_URL=https://dotfiles.test' 'CLAUDE_SETTINGS_REPO_URL=https://settings.test' >"$1/config.env"
}

# _hy_run <dir> <flag> [VAR=value...]: run the scratch hydrate.sh with the given environment; sets HY_OUT (stdout
# and stderr) and HY_RC (exit status).
_hy_run() {
    HY_RC=0
    HY_OUT=$(env "${@:3}" bash "$1/hydrate.sh" "$2" 2>&1) || HY_RC=$?
}

# _hy_q <dir> <filter>: print jq -S -c <filter> over <dir>/settings.json (key-sorted, so comparisons ignore
# key order), or <missing> when there is none.
_hy_q() {
    if [[ -f "$1/settings.json" ]]; then
        jq -S -c "$2" "$1/settings.json"
    else
        printf '<missing>'
    fi
}

# _hy_stub <dir> <command>: write a stub <command> that always fails into <dir>/bin; print that directory.
_hy_stub() {
    mkdir -p "$1/bin"
    printf '#!/bin/sh\nexit 1\n' >"$1/bin/$2"
    chmod +x "$1/bin/$2"
    printf '%s' "$1/bin"
}

# _hy_temps <dir>: print each hydrate temp file left in <dir>, one per line.
_hy_temps() {
    find "$1" -maxdepth 1 -name '.settings.json.*' -print
}

# _hy_mode <file>: print <file>'s permission bits in octal (GNU stat, else BSD stat).
_hy_mode() {
    stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

# _hy_same <description> <file> <copy>: pass when <file> is byte-identical to <copy>.
_hy_same() {
    if cmp -s "$2" "$3"; then
        pass "$1"
    else
        fail "$1" "$2 changed"
    fi
}

test_hydrate_settings_text_templates() {
    local tmp
    tmp=$(mktemp -d)
    _hy_fixture "$tmp"
    mkdir -p "$tmp/scripts" "$tmp/skills/datadog-log-link"
    printf '%s\n' '{"permissions":{"allow":[]}}' >"$tmp/settings.json.tmpl"
    printf '%s\n' 'dotfiles: __DOTFILES_REPO_URL__' >"$tmp/CLAUDE.md.tmpl"
    printf '%s\n' 'SSO_START_URL=__SSO_START_URL__' >"$tmp/scripts/_aws-sso-common.sh.tmpl"
    printf '%s\n' 'site: __DATADOG_SITE__' >"$tmp/skills/datadog-log-link/SKILL.md.tmpl"

    _hy_run "$tmp" --diff
    assert_matches "NEW $tmp/CLAUDE.md" "$HY_OUT" "--diff reports a missing text output NEW"
    assert_matches '\+dotfiles: https://dotfiles\.test' "$HY_OUT" "--diff prints the rendered text"
    if [[ ! -e "$tmp/CLAUDE.md" ]]; then
        pass "--diff writes no text output"
    else
        fail "--diff writes no text output" "CLAUDE.md was written"
    fi

    _hy_run "$tmp" --force
    assert_equals 0 "$HY_RC" "hydrate --force renders the text templates"
    assert_equals "dotfiles: https://dotfiles.test" "$(cat "$tmp/CLAUDE.md")" "CLAUDE.md is rendered"
    assert_equals "SSO_START_URL=https://sso.test/start" "$(cat "$tmp/scripts/_aws-sso-common.sh")" \
        "_aws-sso-common.sh is rendered"
    assert_equals "site: datadoghq.test" "$(cat "$tmp/skills/datadog-log-link/SKILL.md")" "SKILL.md is rendered"
    assert_equals 600 "$(_hy_mode "$tmp/CLAUDE.md")" "a rendered text output is 0600"

    _hy_run "$tmp" --force
    assert_matches "UNCHANGED $tmp/CLAUDE.md" "$HY_OUT" "a second run reports the text output UNCHANGED"

    printf '%s\n' 'dotfiles: stale' >"$tmp/CLAUDE.md"
    cp "$tmp/CLAUDE.md" "$tmp/before.md"
    _hy_run "$tmp" --diff
    assert_matches "CHANGED $tmp/CLAUDE.md" "$HY_OUT" "--diff reports an edited text output CHANGED"
    assert_matches '-dotfiles: stale' "$HY_OUT" "--diff prints the line the render replaces"
    _hy_same "--diff leaves the edited text output as it was" "$tmp/CLAUDE.md" "$tmp/before.md"

    rm "$tmp/CLAUDE.md"
    mkdir "$tmp/CLAUDE.md"
    _hy_run "$tmp" --force
    assert_equals 1 "$HY_RC" "a failed text-output write exits 1"
    assert_matches "FAIL $tmp/CLAUDE.md" "$HY_OUT" "a failed text-output write prints FAIL"
    rm -rf "$tmp"
}

test_hydrate_settings_unions_lists() {
    local tmp
    tmp=$(mktemp -d)
    _hy_fixture "$tmp"
    printf '%s\n' '{"permissions":{"allow":["B","C"],"ask":["Q"],"deny":["X"]},"enabledMcpjsonServers":["d","p"]}' \
        >"$tmp/settings.json.tmpl"
    printf '%s\n' '{"permissions":{"allow":["A","B"],"deny":["D"]},"enabledMcpjsonServers":["d","local"]}' \
        >"$tmp/settings.json"
    _hy_run "$tmp" --force
    assert_equals 0 "$HY_RC" "hydrate --force succeeds"
    assert_equals '["A","B","C"]' "$(_hy_q "$tmp" '.permissions.allow')" "allow: existing first, then new tmpl entries"
    assert_equals '["Q"]' "$(_hy_q "$tmp" '.permissions.ask')" "ask: unioned like allow"
    assert_equals '["D","X"]' "$(_hy_q "$tmp" '.permissions.deny')" "deny: unioned"
    assert_equals '["d","local","p"]' "$(_hy_q "$tmp" '.enabledMcpjsonServers')" "enabledMcpjsonServers: unioned"

    printf '%s\n' '{"permissions":{"allow":["A"]}}' >"$tmp/settings.json.tmpl"
    printf '%s\n' '{"permissions":{"allow":["A"]}}' >"$tmp/settings.json"
    _hy_run "$tmp" --force
    assert_equals 'false' "$(_hy_q "$tmp" '.permissions | has("ask")')" "no ask on either side: no empty ask array"
    assert_equals 'false' "$(_hy_q "$tmp" 'has("env")')" "no env on either side: no empty env object"
    rm -rf "$tmp"
}

test_hydrate_settings_remove_channel() {
    local tmp
    tmp=$(mktemp -d)
    _hy_fixture "$tmp"
    printf '%s\n' '{"permissions":{"allow":["B","RM"]},"enabledMcpjsonServers":["d"],
        "__remove__":{"keys":[["sandbox"],["env","OLD"],["enabledPlugins","p@m"],
            ["extraKnownMarketplaces","dead"],["absent","x"]],
          "entries":{"permissions.allow":["RM","LOCALRM"],"permissions.deny":["gone"],
            "enabledMcpjsonServers":["aspire"],"permissions.absent":["x"]}}}' >"$tmp/settings.json.tmpl"
    printf '%s\n' '{"env":{"OLD":"1","KEEP":"k"},"permissions":{"allow":["A","LOCALRM"],"deny":["D"]},
        "enabledMcpjsonServers":["d","aspire"],"sandbox":{"allowedDomains":["x"]},
        "enabledPlugins":{"p@m":true,"q@m":false},"extraKnownMarketplaces":{"dead":{},"live":{}}}' \
        >"$tmp/settings.json"
    _hy_run "$tmp" --force
    assert_equals 0 "$HY_RC" "hydrate --force succeeds with a __remove__ block"
    assert_equals '["A","B"]' "$(_hy_q "$tmp" '.permissions.allow')" "entries: removed from allow, tmpl and local alike"
    assert_equals '["D"]' "$(_hy_q "$tmp" '.permissions.deny')" "entries: absent value is a no-op"
    assert_equals '["d"]' "$(_hy_q "$tmp" '.enabledMcpjsonServers')" "entries: removed from enabledMcpjsonServers"
    assert_equals 'false' "$(_hy_q "$tmp" 'has("sandbox")')" "keys: a top-level key is deleted"
    assert_equals '{"KEEP":"k"}' "$(_hy_q "$tmp" '.env')" "keys: a nested env key is deleted"
    assert_equals '{"q@m":false}' "$(_hy_q "$tmp" '.enabledPlugins')" "keys: a plugin entry is deleted"
    assert_equals '{"live":{}}' "$(_hy_q "$tmp" '.extraKnownMarketplaces')" "keys: a marketplace entry is deleted"
    assert_equals 'false' "$(_hy_q "$tmp" 'has("__remove__") or has("absent")')" \
        "__remove__ is never written, and a missing target creates nothing"
    assert_equals 'false' "$(_hy_q "$tmp" '.permissions | has("absent")')" "a missing entries path creates nothing"
    rm -rf "$tmp"
}

test_hydrate_settings_env_values() {
    local tmp
    tmp=$(mktemp -d)
    _hy_fixture "$tmp"
    printf '%s\n' '{"env":{"A":"1","FILL":"tmplval","PROFILE":"__AWS_PROFILE__"},"permissions":{"allow":[]}}' \
        >"$tmp/settings.json.tmpl"
    printf '%s\n' '{"env":{"FILL":"","LOCAL":"l","NULLED":null},"permissions":{"allow":[]}}' >"$tmp/settings.json"
    _hy_run "$tmp" --force
    assert_equals '{"A":"1","FILL":"tmplval","LOCAL":"l"}' "$(_hy_q "$tmp" '.env')" \
        "env: empty and null values dropped on both sides; an empty local value falls back to the tmpl"
    rm -rf "$tmp"
}

test_hydrate_settings_empty_env_not_written() {
    local tmp
    tmp=$(mktemp -d)
    _hy_fixture "$tmp"
    printf '%s\n' '{"env":{"P":"__AWS_PROFILE__"},"permissions":{"allow":[]}}' >"$tmp/settings.json.tmpl"
    _hy_run "$tmp" --force
    assert_equals 'false' "$(_hy_q "$tmp" 'has("env")')" "a fresh clone gets no env when every tmpl value is empty"
    printf '%s\n' '{"env":{"X":""},"permissions":{"allow":[]}}' >"$tmp/settings.json"
    _hy_run "$tmp" --force
    assert_equals 'false' "$(_hy_q "$tmp" 'has("env")')" "an env left empty after filtering is not written"
    rm -rf "$tmp"
}

test_hydrate_settings_empty_existing_file() {
    local tmp content
    tmp=$(mktemp -d)
    _hy_fixture "$tmp"
    printf '%s\n' '{"permissions":{"allow":["A"]}}' >"$tmp/settings.json.tmpl"
    for content in '' '   ' 'null'; do
        printf '%s' "$content" >"$tmp/settings.json"
        _hy_run "$tmp" --force
        assert_equals 0 "$HY_RC" "a settings.json holding '$content' is regenerated"
        assert_equals '["A"]' "$(_hy_q "$tmp" '.permissions.allow')" "a settings.json holding '$content' gets the tmpl"
    done
    rm -rf "$tmp"
}

test_hydrate_settings_remove_empties_env_in_one_run() {
    local tmp
    tmp=$(mktemp -d)
    _hy_fixture "$tmp"
    printf '%s\n' '{"permissions":{"allow":[]},"__remove__":{"keys":[["env","X"]]}}' >"$tmp/settings.json.tmpl"
    printf '%s\n' '{"env":{"X":"old"},"permissions":{"allow":[]}}' >"$tmp/settings.json"
    _hy_run "$tmp" --force
    assert_equals 'false' "$(_hy_q "$tmp" 'has("env")')" "removing the last env key leaves no env object"
    _hy_run "$tmp" --force
    assert_matches 'UNCHANGED' "$HY_OUT" "a second run finds nothing to change"
    rm -rf "$tmp"
}

test_hydrate_settings_preview_refuses_non_regular() {
    local tmp
    tmp=$(mktemp -d)
    _hy_fixture "$tmp"
    printf '%s\n' '{"permissions":{"allow":["NEW"]}}' >"$tmp/settings.json.tmpl"
    printf '%s\n' '{"permissions":{"allow":["A"]}}' >"$tmp/real.json"
    ln -s real.json "$tmp/settings.json"
    _hy_run "$tmp" --diff
    assert_equals 1 "$HY_RC" "--diff on a symlinked settings.json exits 1"
    assert_matches "FAIL $tmp/settings.json .*not a regular file" "$HY_OUT" "--diff refuses a symlink before previewing"
    rm "$tmp/settings.json"
    mkdir "$tmp/settings.json"
    _hy_run "$tmp" --diff
    assert_equals 1 "$HY_RC" "--diff on a directory named settings.json exits 1"
    rm -rf "$tmp"
}

test_hydrate_settings_null_is_a_gap() {
    local tmp
    tmp=$(mktemp -d)
    _hy_fixture "$tmp"
    printf '%s\n' '{"model":"opus","permissions":{"allow":[]}}' >"$tmp/settings.json.tmpl"
    printf '%s\n' '{"model":null,"permissions":{"allow":[]}}' >"$tmp/settings.json"
    _hy_run "$tmp" --force
    assert_equals '"opus"' "$(_hy_q "$tmp" '.model')" "a null top-level value in settings.json is a gap the tmpl fills"
    printf '%s\n' '{"gone":null,"permissions":{"allow":[]}}' >"$tmp/settings.json.tmpl"
    printf '%s\n' '{"permissions":{"allow":[]}}' >"$tmp/settings.json"
    _hy_run "$tmp" --force
    assert_equals 'false' "$(_hy_q "$tmp" 'has("gone")')" "a null in the tmpl writes nothing"
    rm -rf "$tmp"
}

test_hydrate_settings_precedence() {
    local tmp
    tmp=$(mktemp -d)
    _hy_fixture "$tmp"
    printf '%s\n' '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"tmpl-hook"}]}]},
        "showThinkingSummaries":true,"outputStyle":"Concise","permissions":{"allow":[],"defaultMode":"auto"},
        "statusLine":{"type":"command","command":"tmpl-line","refreshInterval":10}}' >"$tmp/settings.json.tmpl"
    printf '%s\n' '{"hooks":{"PostToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"injected"}]}]},
        "showThinkingSummaries":false,"modelOverrides":{"m":"v"},"permissions":{"allow":["A"]},
        "statusLine":{"type":"command","command":"mine"}}' >"$tmp/settings.json"
    _hy_run "$tmp" --force
    assert_equals '{"Stop":[{"hooks":[{"command":"tmpl-hook","type":"command"}]}]}' "$(_hy_q "$tmp" '.hooks')" \
        "hooks: template wins, an injected local hook is dropped"
    assert_equals 'false' "$(_hy_q "$tmp" '.showThinkingSummaries')" "a local false survives a tmpl true"
    assert_equals '"Concise"' "$(_hy_q "$tmp" '.outputStyle')" "a tmpl-only key lands"
    assert_equals '{"m":"v"}' "$(_hy_q "$tmp" '.modelOverrides')" "a live-only key is kept"
    assert_equals '"auto"' "$(_hy_q "$tmp" '.permissions.defaultMode')" "a tmpl-only permissions key lands"
    assert_equals '{"command":"mine","type":"command"}' "$(_hy_q "$tmp" '.statusLine')" \
        "an existing object key wins whole"
    rm -rf "$tmp"
}

test_hydrate_settings_fresh_clone() {
    local tmp
    tmp=$(mktemp -d)
    _hy_fixture "$tmp"
    printf '%s\n' '{"awsAuthRefresh":"__AWS_SSO_REFRESH_PATH__","env":{"P":"__AWS_PROFILE__","S":"__SEARXNG_URL__"},
        "permissions":{"allow":["A","gone"]},
        "__remove__":{"keys":[["sandbox"]],"entries":{"permissions.allow":["gone"]}}}' >"$tmp/settings.json.tmpl"
    _hy_run "$tmp" --force
    assert_equals 0 "$HY_RC" "hydrate --force succeeds with no settings.json"
    assert_matches 'NEW ' "$HY_OUT" "a missing settings.json is reported NEW"
    assert_equals '"/fx/refresh.sh"' "$(_hy_q "$tmp" '.awsAuthRefresh')" "placeholders are substituted"
    assert_equals '{"S":"https://searx.test"}' "$(_hy_q "$tmp" '.env')" "an unset placeholder leaves no empty env value"
    assert_equals '["A"]' "$(_hy_q "$tmp" '.permissions.allow')" "__remove__ applies on a fresh clone"
    assert_equals 'false' "$(_hy_q "$tmp" 'has("__remove__")')" "__remove__ is not written on a fresh clone"
    rm -rf "$tmp"
}

test_hydrate_settings_preview_ignores_key_order() {
    local tmp
    tmp=$(mktemp -d)
    _hy_fixture "$tmp"
    printf '%s\n' '{"b":1,"a":"x/y","permissions":{"allow":[]}}' >"$tmp/settings.json.tmpl"

    printf '%s\n' '{"permissions":{"allow":[]},"b":1,"a":"x/y"}' >"$tmp/settings.json"
    cp "$tmp/settings.json" "$tmp/before.json"
    _hy_run "$tmp" --force
    assert_matches 'UNCHANGED' "$HY_OUT" "a reordered equivalent file is UNCHANGED"
    _hy_same "a reordered equivalent settings.json is not rewritten" "$tmp/settings.json" "$tmp/before.json"

    printf '%s\n' '{"a":"x\/y","b":1,"permissions":{"allow":[]}}' >"$tmp/settings.json"
    cp "$tmp/settings.json" "$tmp/before.json"
    _hy_run "$tmp" --force
    assert_matches 'UNCHANGED' "$HY_OUT" "a re-escaped, compactly formatted equivalent file is UNCHANGED"
    _hy_same "a re-escaped equivalent settings.json is not rewritten" "$tmp/settings.json" "$tmp/before.json"
    rm -rf "$tmp"
}

test_hydrate_settings_diff_writes_nothing() {
    local tmp
    tmp=$(mktemp -d)
    _hy_fixture "$tmp"
    printf '%s\n' '{"permissions":{"allow":["NEW"]}}' >"$tmp/settings.json.tmpl"
    printf '%s\n' '{"permissions":{"allow":["A"]}}' >"$tmp/settings.json"
    cp "$tmp/settings.json" "$tmp/before.json"
    _hy_run "$tmp" --diff
    assert_equals 0 "$HY_RC" "hydrate --diff succeeds"
    assert_matches 'CHANGED' "$HY_OUT" "--diff reports CHANGED"
    assert_matches '\+ +"NEW"' "$HY_OUT" "--diff prints the added entry"
    if cmp -s "$tmp/settings.json" "$tmp/before.json"; then
        pass "--diff writes nothing"
    else
        fail "--diff writes nothing" "settings.json changed"
    fi
    rm -rf "$tmp"
}

test_hydrate_settings_new_file_preview() {
    local tmp
    tmp=$(mktemp -d)
    _hy_fixture "$tmp"
    printf '%s\n' '{"permissions":{"allow":["FRESH"]}}' >"$tmp/settings.json.tmpl"
    _hy_run "$tmp" --diff
    assert_equals 0 "$HY_RC" "--diff succeeds on a fresh clone"
    assert_matches "NEW $tmp/settings.json" "$HY_OUT" "--diff reports NEW on a fresh clone"
    assert_matches '\+ +"FRESH"' "$HY_OUT" "--diff prints the new file's content"
    assert_equals '<missing>' "$(_hy_q "$tmp" '.')" "--diff writes nothing on a fresh clone"
    rm -rf "$tmp"
}

test_hydrate_settings_atomic_write() {
    local tmp
    tmp=$(mktemp -d)
    _hy_fixture "$tmp"
    printf '%s\n' '{"permissions":{"allow":["A"]}}' >"$tmp/settings.json.tmpl"
    printf '%s\n' '{"permissions":{"allow":[]}}' >"$tmp/settings.json"
    chmod 644 "$tmp/settings.json"
    _hy_run "$tmp" --force
    assert_equals 0 "$HY_RC" "hydrate --force succeeds"
    assert_equals '["A"]' "$(_hy_q "$tmp" '.permissions.allow')" "the merged file is written"
    assert_equals 600 "$(_hy_mode "$tmp/settings.json")" "a temp file moved over settings.json leaves it 0600"
    assert_equals "" "$(_hy_temps "$tmp")" "no temp file is left beside settings.json"
    rm -rf "$tmp"
}

test_hydrate_settings_failed_write() {
    local tmp bin
    tmp=$(mktemp -d)
    _hy_fixture "$tmp"
    printf '%s\n' '{"permissions":{"allow":["NEW"]}}' >"$tmp/settings.json.tmpl"
    printf '%s\n' '{"permissions":{"allow":["A"]}}' >"$tmp/settings.json"
    cp "$tmp/settings.json" "$tmp/before.json"

    bin=$(_hy_stub "$tmp/mv-fails" mv)
    _hy_run "$tmp" --force "PATH=$bin:$PATH"
    assert_equals 1 "$HY_RC" "a failed move exits 1"
    assert_matches "FAIL $tmp/settings.json" "$HY_OUT" "a failed move prints FAIL"
    assert_not_matches "OK $tmp/settings.json" "$HY_OUT" "a failed move prints no OK"
    _hy_same "a failed move leaves settings.json as it was" "$tmp/settings.json" "$tmp/before.json"
    assert_equals "" "$(_hy_temps "$tmp")" "a failed move leaves no temp file behind"

    bin=$(_hy_stub "$tmp/mktemp-fails" mktemp)
    _hy_run "$tmp" --force "PATH=$bin:$PATH"
    assert_equals 1 "$HY_RC" "a failed temp-file creation exits 1"
    assert_matches "FAIL $tmp/settings.json" "$HY_OUT" "a failed temp-file creation prints FAIL"
    _hy_same "a failed temp-file creation leaves settings.json as it was" "$tmp/settings.json" "$tmp/before.json"

    rm "$tmp/settings.json"
    mkdir "$tmp/settings.json"
    _hy_run "$tmp" --force
    assert_equals 1 "$HY_RC" "a directory named settings.json exits 1"
    assert_matches "FAIL $tmp/settings.json .*not a regular file" "$HY_OUT" \
        "a directory is refused as not a regular file"
    assert_equals "" "$(ls -A "$tmp/settings.json")" "nothing is moved into the directory"
    assert_equals "" "$(_hy_temps "$tmp")" "no temp file is left beside the directory"
    rm -rf "$tmp/settings.json"

    cp "$tmp/before.json" "$tmp/real.json"
    ln -s real.json "$tmp/settings.json"
    _hy_run "$tmp" --force
    assert_equals 1 "$HY_RC" "a symlinked settings.json exits 1"
    assert_matches "FAIL $tmp/settings.json .*not a regular file" "$HY_OUT" "a symlink is refused as not a regular file"
    if [[ -L "$tmp/settings.json" ]]; then
        pass "the symlink is left in place"
    else
        fail "the symlink is left in place" "settings.json is no longer a symlink"
    fi
    _hy_same "the symlink's target is unchanged" "$tmp/real.json" "$tmp/before.json"
    rm -rf "$tmp"
}

test_hydrate_settings_full_disk() {
    local tmp big
    tmp=$(mktemp -d)
    _hy_fixture "$tmp"
    big=$(printf 'x%.0s' {1..6000})
    printf '%s\n' "{\"permissions\":{\"allow\":[\"$big\"]}}" >"$tmp/settings.json.tmpl"
    printf '%s\n' '{"permissions":{"allow":["A"]}}' >"$tmp/settings.json"
    cp "$tmp/settings.json" "$tmp/before.json"
    HY_RC=0
    HY_OUT=$(trap '' XFSZ; ulimit -f 2; bash "$tmp/hydrate.sh" --force 2>&1) || HY_RC=$?
    assert_equals 1 "$HY_RC" "a write that fills the disk exits 1"
    assert_matches "FAIL $tmp/settings.json" "$HY_OUT" "a write that fills the disk prints FAIL"
    assert_not_matches "OK $tmp/settings.json" "$HY_OUT" "a write that fills the disk prints no OK"
    _hy_same "a write that fills the disk leaves settings.json as it was" "$tmp/settings.json" "$tmp/before.json"
    assert_equals "" "$(_hy_temps "$tmp")" "a write that fills the disk leaves no temp file behind"
    rm -rf "$tmp"
}

test_hydrate_settings_temp_name_is_gitignored() {
    local tmp name
    tmp=$(mktemp -d)
    _hy_fixture "$tmp"
    printf '%s\n' '{"permissions":{"allow":["NEW"]}}' >"$tmp/settings.json.tmpl"
    mkdir -p "$tmp/bin"
    printf '#!/bin/sh\nprintf "%%s\\n" "$3" >"%s/mv-arg"\nexit 1\n' "$tmp" >"$tmp/bin/mv"
    chmod +x "$tmp/bin/mv"
    _hy_run "$tmp" --force "PATH=$tmp/bin:$PATH"
    name=$(basename "$(cat "$tmp/mv-arg" 2>/dev/null || printf 'none')")
    assert_matches '^\.settings\.json\.hydrate\.' "$name" "the temp file is named .settings.json.hydrate.*"
    if git -C "$REPO_ROOT" check-ignore -q -- "$name"; then
        pass "the temp file's name is gitignored"
    else
        fail "the temp file's name is gitignored" "$name is not ignored"
    fi
    rm -rf "$tmp"
}

test_hydrate_settings_ampersand_value() {
    local tmp
    tmp=$(mktemp -d)
    _hy_fixture "$tmp"
    printf '%s\n' "SEARXNG_URL='https://s.test/?a=1&b=2'" >"$tmp/config.env"
    printf '%s\n' '{"env":{"S":"__SEARXNG_URL__"},"permissions":{"allow":[]}}' >"$tmp/settings.json.tmpl"
    _hy_run "$tmp" --force
    assert_equals '"https://s.test/?a=1&b=2"' "$(_hy_q "$tmp" '.env.S')" "an & in a config.env value is kept literally"
    rm -rf "$tmp"
}

test_hydrate_settings_malformed_remove_aborts() {
    local tmp shape desc
    local -a shapes=(
        '{"keys":"sandbox"}'
        '{"keys":["sandbox"]}'
        '{"keys":[[]]}'
        '{"keys":{"sandbox":true}}'
        '{"entries":["permissions.allow"]}'
        '{"entries":[]}'
        '{"entries":{"permissions.allow":"A"}}'
        '{"key":[["sandbox"]]}'
        '[["sandbox"]]'
        '"sandbox"'
        '{"keys":false}'
        '{"entries":false}'
        '{"keys":[[null]]}'
        '{"keys":[["env",{"a":1}]]}'
    )
    tmp=$(mktemp -d)
    _hy_fixture "$tmp"
    printf '%s\n' '{"permissions":{"allow":["A"]},"sandbox":{}}' >"$tmp/settings.json"
    cp "$tmp/settings.json" "$tmp/before.json"
    for shape in "${shapes[@]}"; do
        printf '%s\n' "{\"permissions\":{\"allow\":[]},\"__remove__\":$shape}" >"$tmp/settings.json.tmpl"
        _hy_run "$tmp" --force
        desc="__remove__ $shape aborts hydrate, names __remove__ and leaves settings.json untouched"
        if [[ "$HY_RC" -ne 0 && "$HY_OUT" == *__remove__* ]] && cmp -s "$tmp/settings.json" "$tmp/before.json"; then
            pass "$desc"
        else
            fail "$desc" "rc=$HY_RC: $HY_OUT"
        fi
    done
    printf '%s\n' '{"permissions":{"allow":[]},"__remove__":{"keys":[],"entries":{}}}' >"$tmp/settings.json.tmpl"
    _hy_run "$tmp" --force
    assert_equals 0 "$HY_RC" "an empty but well-formed __remove__ is accepted"
    rm -rf "$tmp"
}

test_hydrate_settings_real_tmpl() {
    local tmp
    tmp=$(mktemp -d)
    _hy_fixture "$tmp"
    cp "$REPO_ROOT/settings.json.tmpl" "$tmp/settings.json.tmpl"

    _hy_run "$tmp" --force
    assert_equals 0 "$HY_RC" "the real tmpl hydrates on a fresh clone"
    assert_equals 'false' "$(_hy_q "$tmp" 'has("sandbox") or has("__remove__")')" \
        "a fresh clone gets no sandbox block and no __remove__"
    assert_equals 'false' "$(_hy_q "$tmp" '.env | has("AWS_PROFILE")')" "settings.json carries no AWS_PROFILE"
    assert_equals '"https://searx.test"' "$(_hy_q "$tmp" '.env.SEARXNG_URL')" "SEARXNG_URL is substituted"
    assert_equals '{"CLAUDE_CODE_SUBPROCESS_ENV_SCRUB":"1","ENABLE_PROMPT_CACHING_1H":"1","ENABLE_TOOL_SEARCH":"true"}' \
        "$(_hy_q "$tmp" '.env | {CLAUDE_CODE_SUBPROCESS_ENV_SCRUB, ENABLE_PROMPT_CACHING_1H, ENABLE_TOOL_SEARCH}')" \
        "the provider-neutral flags are set in settings env"

    printf '%s\n' '{"env":{"API_TIMEOUT_MS":"1200000","AWS_PROFILE":"live-profile"},
        "modelOverrides":{"m":"v"},
        "permissions":{"allow":["Bash(git *)","Bash(local-only *)"]},
        "sandbox":{"enabled":true,"allowedDomains":["pypi.org"]},"enabledPlugins":{"x@live-mkt":true},"model":"sonnet",
        "hooks":{"PostToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"injected"}]}]}}' \
        >"$tmp/settings.json"
    _hy_run "$tmp" --force
    assert_equals 0 "$HY_RC" "the real tmpl hydrates over a live-shaped settings.json"
    assert_equals '{"enabled":true}' "$(_hy_q "$tmp" '.sandbox')" \
        "the dead sandbox.allowedDomains key is removed, and a fork's own sandbox setting is kept"
    assert_equals 'false' "$(_hy_q "$tmp" 'has("modelOverrides")')" "the live modelOverrides leave"
    assert_equals 'false' "$(_hy_q "$tmp" '.env | has("AWS_PROFILE")')" "the live env.AWS_PROFILE leaves"
    assert_equals '"/fx/refresh.sh"' "$(_hy_q "$tmp" '.awsAuthRefresh')" "awsAuthRefresh stays shared"
    assert_equals 'true' "$(_hy_q "$tmp" '.permissions.allow | index("Bash(local-only *)") != null')" \
        "a local-only allow rule is kept"
    assert_equals '"sonnet"' "$(_hy_q "$tmp" '.model')" "a local model choice is kept"
    assert_equals '{"x@live-mkt":true}' "$(_hy_q "$tmp" '.enabledPlugins')" "local plugin state is kept"
    assert_equals '0' "$(_hy_q "$tmp" '[.hooks | .. | strings | select(. == "injected")] | length')" \
        "an injected local hook is dropped"
    rm -rf "$tmp"
}

# Work-only values live in settings.work.json; the shared template carries no provider-specific env key.
test_settings_tmpl_env_is_provider_neutral() {
    assert_equals '[]' "$(jq -c '[.env | keys[] | select(test("^(AWS_|ANTHROPIC_|BEDROCK_)|_NUGET_PAT$"))]' \
        "$REPO_ROOT/settings.json.tmpl")" "settings.json.tmpl env holds no AWS, Anthropic, Bedrock or PAT key"
}

# _hy_work <dir> <config-line...>: a hydrate fixture holding the real settings.work.json.tmpl, a minimal
# settings.json.tmpl and a config.env made of the given lines.
_hy_work() {
    local d=$1
    shift
    _hy_fixture "$d"
    printf '%s\n' "$@" >"$d/config.env"
    printf '%s\n' '{"permissions":{"allow":[]}}' >"$d/settings.json.tmpl"
    cp "$REPO_ROOT/settings.work.json.tmpl" "$d/settings.work.json.tmpl"
}

# _hy_wq <dir> <filter>: print jq -S -c <filter> over <dir>/settings.work.json, or <missing> when there is none.
_hy_wq() {
    if [[ -f "$1/settings.work.json" ]]; then
        jq -S -c "$2" "$1/settings.work.json"
    else
        printf '<missing>'
    fi
}

test_hydrate_settings_work_layer() {
    local tmp
    tmp=$(mktemp -d)
    _hy_work "$tmp" 'AWS_PROFILE=work-profile' 'MODEL_OVERRIDE_OPUS_4_6=o46' 'MODEL_OVERRIDE_OPUS_4_7=' \
        'MODEL_OVERRIDE_OPUS_5_5=o55'
    _hy_run "$tmp" --force
    assert_equals 0 "$HY_RC" "hydrate --force writes the work layer"
    assert_equals '{"AWS_PROFILE":"work-profile"}' "$(_hy_wq "$tmp" '.env')" "the work layer carries AWS_PROFILE"
    assert_equals '{"claude-opus-4-6":"o46","claude-opus-5-5":"o55"}' "$(_hy_wq "$tmp" '.modelOverrides')" \
        "an empty override value drops that entry"
    assert_equals '[]' "$(_hy_wq "$tmp" '[.. | strings | select(test("__[A-Z0-9_]+__"))]')" \
        "every work-layer placeholder is substituted"
    assert_equals 600 "$(_hy_mode "$tmp/settings.work.json")" "the work layer is mode 0600"
    _hy_run "$tmp" --force
    assert_matches "UNCHANGED $tmp/settings.work.json" "$HY_OUT" "a second run leaves the work layer unchanged"
    printf '%s\n' '{"env":{"AWS_PROFILE":"hand-edit"},"extra":true}' >"$tmp/settings.work.json"
    _hy_run "$tmp" --force
    assert_equals '["env","modelOverrides"]' "$(_hy_wq "$tmp" 'keys')" "hydrate is the work layer's only writer"
    assert_equals '"work-profile"' "$(_hy_wq "$tmp" '.env.AWS_PROFILE')" "a hand edit is overwritten"
    rm -rf "$tmp"
}

test_hydrate_settings_work_layer_all_empty() {
    local tmp
    tmp=$(mktemp -d)
    _hy_work "$tmp" 'AWS_PROFILE=' 'MODEL_OVERRIDE_OPUS_4_6=' 'MODEL_OVERRIDE_OPUS_4_7=' 'MODEL_OVERRIDE_OPUS_5_5='
    _hy_run "$tmp" --force
    assert_equals 0 "$HY_RC" "hydrate --force succeeds with every work value empty"
    assert_equals '{}' "$(_hy_wq "$tmp" '.')" "an all-empty config writes {}"
    rm -rf "$tmp"
}

test_hydrate_settings_work_layer_preview() {
    local tmp
    tmp=$(mktemp -d)
    _hy_work "$tmp" 'AWS_PROFILE=work-profile'
    _hy_run "$tmp" --diff
    assert_equals 0 "$HY_RC" "--diff succeeds with no work layer yet"
    assert_matches "NEW $tmp/settings.work.json" "$HY_OUT" "--diff reports the work layer NEW"
    assert_equals '<missing>' "$(_hy_wq "$tmp" '.')" "--diff writes no work layer"
    rm -rf "$tmp"
}

test_hydrate_settings_work_layer_ignore_rules() {
    if git -C "$REPO_ROOT" check-ignore -q -- settings.work.json; then
        pass "settings.work.json is gitignored"
    else
        fail "settings.work.json is gitignored" "no .gitignore rule matches it"
    fi
    if git -C "$REPO_ROOT" check-ignore -q -- settings.work.json.tmpl; then
        fail "settings.work.json.tmpl is tracked" "a .gitignore rule matches it"
    else
        pass "settings.work.json.tmpl is tracked"
    fi
}
