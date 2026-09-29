#!/usr/bin/env bash
# Tests for scripts/setup-platform.sh and scripts/apply-settings.sh on a clone whose settings.json is
# untracked and gitignored. Each case runs the real scripts under a scratch $HOME whose
# .claude is a fresh git repo, so neither the live settings.json nor the live git config is touched.

# _sp_fixture <home>: build <home>/.claude as a git repo holding copies of the two scripts and hydrate.sh,
# a stub aws-sso-refresh.sh, a fixture config.env and a minimal settings.json.tmpl.
_sp_fixture() {
    local c="$1/.claude"
    mkdir -p "$c/scripts"
    git -C "$c" init -q -b main
    cp "$REPO_ROOT/scripts/setup-platform.sh" "$REPO_ROOT/scripts/apply-settings.sh" "$c/scripts/"
    cp "$REPO_ROOT/hydrate.sh" "$c/hydrate.sh"
    printf '#!/usr/bin/env bash\n' >"$c/scripts/aws-sso-refresh.sh"
    printf '%s\n' 'AWS_SSO_REFRESH_PATH=' 'AWS_PROFILE=' 'SEARXNG_URL=' >"$c/config.env"
    printf '%s\n' '{"permissions":{"allow":["A"]}}' >"$c/settings.json.tmpl"
}

# _sp_run <home> <script>: run <home>/.claude/scripts/<script> with HOME=<home>; sets SP_OUT and SP_RC.
_sp_run() {
    SP_RC=0
    SP_OUT=$(HOME="$1" bash "$1/.claude/scripts/$2" 2>&1) || SP_RC=$?
}

test_setup_platform_requires_settings_json() {
    local home
    home=$(mktemp -d)
    _sp_fixture "$home"
    _sp_run "$home" setup-platform.sh
    assert_equals 1 "$SP_RC" "setup-platform exits 1 when settings.json is missing"
    assert_matches "settings.json not found. Run $home/.claude/hydrate.sh first." "$SP_OUT" \
        "the error names hydrate.sh as the missing step"
    assert_equals ".githooks" "$(git -C "$home/.claude" config core.hooksPath || true)" \
        "core.hooksPath is set before the settings.json check"
    rm -rf "$home"
}

test_setup_platform_untracked_settings_json() {
    local home
    home=$(mktemp -d)
    _sp_fixture "$home"
    printf '%s\n' '{"permissions":{"allow":["A"]}}' >"$home/.claude/settings.json"
    _sp_run "$home" setup-platform.sh
    assert_equals 0 "$SP_RC" "setup-platform succeeds on an untracked settings.json"
    assert_equals "\"$home/.claude/scripts/aws-sso-refresh.sh\"" \
        "$(jq -c '.awsAuthRefresh' "$home/.claude/settings.json")" \
        "awsAuthRefresh is the absolute refresh-script path"
    assert_equals ".githooks" "$(git -C "$home/.claude" config core.hooksPath || true)" "core.hooksPath is set"
    assert_equals "" "$(git -C "$home/.claude" ls-files settings.json)" "settings.json is still untracked"
    rm -rf "$home"
}

test_apply_settings_untracked_settings_json() {
    local home
    home=$(mktemp -d)
    _sp_fixture "$home"
    _sp_run "$home" apply-settings.sh
    assert_equals 0 "$SP_RC" "apply-settings succeeds on a clone with no settings.json"
    assert_equals '["A"]' "$(jq -c '.permissions.allow' "$home/.claude/settings.json" 2>/dev/null || true)" \
        "apply-settings hydrates settings.json from the tmpl"
    assert_equals "\"$home/.claude/scripts/aws-sso-refresh.sh\"" \
        "$(jq -c '.awsAuthRefresh' "$home/.claude/settings.json" 2>/dev/null || true)" \
        "apply-settings then runs setup-platform"
    rm -rf "$home"
}

test_setup_platform_leaves_enclosing_repo_hooks_alone() {
    local home
    home=$(mktemp -d)
    _sp_fixture "$home"
    rm -rf "$home/.claude/.git"
    git -C "$home" init -q
    printf '%s\n' '{"permissions":{"allow":["A"]}}' >"$home/.claude/settings.json"
    _sp_run "$home" setup-platform.sh
    assert_equals 0 "$SP_RC" "setup-platform succeeds when ~/.claude is not its own repository"
    assert_equals "" "$(git -C "$home" config core.hooksPath || true)" \
        "setup-platform leaves the enclosing repository's hooks path alone"
    assert_matches 'not activating git hooks' "$SP_OUT" "setup-platform says why it skipped activation"
    rm -rf "$home"
}

test_setup_platform_follows_a_symlinked_claude_dir() {
    local home
    home=$(mktemp -d)
    _sp_fixture "$home/real"
    ln -s "$home/real/.claude" "$home/.claude"
    printf '%s\n' '{"permissions":{"allow":["A"]}}' >"$home/.claude/settings.json"
    _sp_run "$home" setup-platform.sh
    assert_equals ".githooks" "$(git -C "$home/real/.claude" config core.hooksPath || true)" \
        "setup-platform activates the hooks through a symlinked ~/.claude"
    rm -rf "$home"
}
