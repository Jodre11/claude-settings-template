# Claude Settings Template

A GitHub template for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) harness configuration —
hooks, scripts, tools, and settings with a `config.env` placeholder strategy for keeping
sensitive values out of version control.

## What's Included

### Hooks

| Hook | Purpose |
|---|---|
| `_lib.sh` | Shared helpers for all hooks (input parsing, allow/ask/deny decisions, the quote-aware command scan) |
| `api-failure-log.sh` | StopFailure: appends one slim record per turn that ended on an API error to `telemetry/api-failures.jsonl` |
| `bash-guard.sh` | Enforces single-command-per-Bash-call discipline |
| `reviewer-guard.sh` | Denies mutating git commands to read-only code-review agents |
| `settings-edit-ask.sh` | Asks before a direct Edit/Write of `settings.json`, which is generated from `settings.json.tmpl` |
| `secret-bash-guard.sh` | Denies a Bash command that would print a secret into context; screens every pipeline stage |
| `git-signing-ask.sh` | Asks before a Bash command overrides or removes git signing, in any key spelling; reads of the setting pass |
| `secret-output-scrubber.sh` | Redacts secrets in tool output, keeping its shape, and raises the alarm; failed tool output: alarm only |
| `allow-permissions.sh`, `allow-write-permissions.sh`, `agent-mode-guard.sh` | Shims for an older `settings.json`; see [upgrading](#5-re-applying-template-changes-later) |
| `session-init.sh` | Creates session-scoped temp dir, renames the tmux session, injects context, exports `CLAUDE_TEMP_DIR`/`CLAUDE_SESSION_ID` to Bash |
| `handover-detect.sh` | SessionStart: sweeps consumed and stale handovers; injects nothing (you run `/rehydrate`) |
| `temp-path-guard.sh` | Enforces session-scoped temp directory convention |
| `tmpl-output-guard.sh` | Denies an Edit/Write of any file with a `<file>.tmpl` beside it (a hydrated output; edit the `.tmpl`, then run `hydrate.sh`). It is user-level, so it applies in every repo; `settings.json` is exempt |

### Tests

`bash tests/run.sh` runs every `tests/lib/test_*.sh` and `hooks/*.test.sh` suite, and fails if it finds none. It
needs bash 4 or later (macOS's `/bin/bash` 3.2 is too old; use Homebrew's), plus `jq` and `tmux`. The `tests`
workflow runs it on every push to `main`, every pull request into `main`, and on demand.

### Scripts

| Script | Purpose |
|---|---|
| `_aws-sso-common.sh` | Shared constants for AWS SSO (generated from `.tmpl`) |
| `aws-sso-preflight.sh` | Check SSO token validity before launching Claude Code |
| `aws-sso-refresh.sh` | Smart AWS SSO login for `awsAuthRefresh` |
| `setup-platform.sh` | Configure platform-specific settings (macOS/Linux/WSL/Windows) |
| `sso-cache-check.py` | AWS SSO cache walker for token validity checks |
| `statusline.sh` | Two-row status line renderer; segments self-hide when their payload data is absent |
| `tests/statusline-test.sh` | Fixture-driven tests for `statusline.sh` (run directly, no framework) |
| `handover-path.sh` | Resolves the handover-artifact path for the cwd (main-worktree root or cwd key); shared by `/handover` and `/rehydrate` |

### Skills

| Skill | Purpose |
|---|---|
| `datadog-log-link` | Generate Datadog Log Explorer URLs from natural language queries |

### Commands

| Command | Purpose |
|---|---|
| `/handover` | Write a phase-handover artifact so a fresh session can resume the work |
| `/rehydrate` | Resume from a handover, reconciling it against the repo before acting |

See [Handover workflow](#handover-workflow) for how these fit together.

### Tools

| Tool | Purpose |
|---|---|
| `md2clip` | Convert Markdown to Teams-compatible HTML and copy to macOS clipboard |

## Getting Started

### 1. Create a private copy and clone it

On GitHub, choose **Use this template → Create a new repository** and set its visibility to
**Private**. Do not fork: a fork of a public repository is public, and your copy will come to hold
your own organisation names, accounts and paths. Then clone it as `~/.claude`:

```bash
# Back up existing ~/.claude if present
[ -d ~/.claude ] && mv ~/.claude ~/.claude.bak

git clone git@github.com:youruser/claude-settings.git ~/.claude
cd ~/.claude
```

Claude Code's per-project memory (`projects/*/memory/`) names real organisations, repositories
and people, so `.gitignore` keeps it out of git. To version it, keep the repository private and
uncomment the opt-in line in `.gitignore`.

A template copy shares no history with this repository. To take later updates, add it as a
remote named `template` (the pre-push hook refuses pushes to it); the first merge needs
`--allow-unrelated-histories`.

### 2. Configure

```bash
cp config.env.example config.env
# Edit config.env with your values
```

### 3. Hydrate templates

```bash
./hydrate.sh           # interactive: preview diffs, confirm before writing
./hydrate.sh --diff    # preview only, write nothing
./hydrate.sh --force   # write without confirmation
```

This generates real config files from `.tmpl` templates using your `config.env` values.
For `settings.json`, `hydrate.sh` **merges** template defaults into the existing file rather
than overwriting — your local additions to `permissions.allow`, `enabledPlugins`, `env`, etc.
are preserved across template updates. A key or list entry the template lists under
`__remove__` is deleted instead (the header of `hydrate.sh` gives the format). `settings.json`
itself is generated and gitignored, so it never reaches git.

The web-search plugin requires a reachable SearXNG instance; point `SEARXNG_URL` at it
(self-hosted Docker or a cloud deployment).

### 4. Run platform setup

```bash
bash scripts/setup-platform.sh
```

This activates the repo's git hooks (a repo-local `core.hooksPath .githooks`), then writes the
platform-specific `awsAuthRefresh` path into the generated `settings.json`. It stops if
`settings.json` is missing, so run `hydrate.sh` first.

### 5. Re-applying template changes later

After pulling new template changes, preview them with `./hydrate.sh --diff`, then re-run the
merge with platform settings preserved:

```bash
bash scripts/apply-settings.sh
```

This runs `hydrate.sh --force`, then re-runs `setup-platform.sh` to re-inject the platform
`awsAuthRefresh`.

**After pulling hook or permission changes**, run `bash scripts/apply-settings.sh` so `settings.json` picks up
the new hook registrations and permission rules; hooks are template-wins, so the old registrations are replaced.
Until you do, `allow-permissions.sh` and `allow-write-permissions.sh` forward to their replacements, the retired
`agent-mode-guard.sh` does nothing, and a failed tool call's output is not scanned for secrets (the old
registration there now does nothing); the forwarders go in a later release. Subagents inherit the allow rules on
Claude Code 2.1.283 or later, so no hook re-implements them for subagents.

### 6. Install tools

```bash
# md2clip (macOS only)
mkdir -p ~/.local/bin
ln -sf ~/.claude/tools/md2clip ~/.local/bin/md2clip
```

## Handover workflow

For long pieces of work that pass through natural phase seams (brainstorm →
plan → implement), the cleanest context hygiene is to reset the session at each
seam rather than carry an ever-growing transcript. This harness supports that
with a write-once / verify-on-resume handover:

1. **At a phase seam**, run `/handover`. It writes an artifact to
   `~/.claude/handovers/<repo>-<hash>.md` recording what's done, what's next,
   and a **fingerprint** of the repo state it was written against (branch, HEAD,
   and `git status --porcelain` — the dirty tree matters, because a whole phase
   can pass with no commit). It then pauses for you to review the draft.
2. **Reset**: `/clear` for a clean context (the working tree is untouched), or
   restart Claude Code to also pick up an update.
3. **On the fresh session**, run `/rehydrate`. It reads the artifact,
   recomputes the fingerprint, and **reconciles against the working tree**:
   - clean match → resume;
   - drift that's consistent with the handover → resume;
   - drift that contradicts it (work already done, tests now green) → stop and
     ask. It always discloses which reconciliation mode it used.

**Reconciliation modes.** Inside a git repo the key is the main worktree's root,
so a subdirectory or a linked worktree shares the repo's one handover (a key on
a worktree's own path would be orphaned once the worktree is removed), and
reconciliation is the working-tree fingerprint check. Outside a repo (a parent
dir like `~/Repos`, or `$HOME`) the key is the cwd path and reconciliation
degrades to trust-the-file — rehydrate reads the files the handover names and
sanity-checks them, but can't give the strong guarantee.

**Cleanup.** The handovers directory is self-limiting: `/rehydrate` marks a
finished handover `consumed`, and the SessionStart hook sweeps consumed files
plus anything older than `HANDOVER_MAX_AGE_DAYS` (default 30) as a backstop for
handovers abandoned without an explicit retire.

## Local API-error telemetry

Main-inference API errors (Bedrock/Anthropic 429s, 500s, connection failures) are retried
inside the Claude Code client and **never** reach the `StopFailure`/`PostToolUseFailure`
hooks — so `api-failure-log.sh` alone cannot see them. The only reliable local source of the
status-code split is the OpenTelemetry `claude_code.api_error` event.

This harness captures that split locally, at **zero token/API cost** (telemetry sends nothing
extra to the model; the only cost is local disk), by exporting the event to a file via a local
OpenTelemetry collector. A `filter` processor keeps only `api_error`-class events so the file
stays small and greppable.

**1. Install the collector** (`otelcol-contrib` — the `file` exporter is contrib-only, not in
core `otelcol`; it is a single static binary, not a Homebrew formula):

```bash
# Pick the latest version and your platform's asset from:
#   https://github.com/open-telemetry/opentelemetry-collector-releases/releases
VER=0.155.0   # check for a newer release
mkdir -p ~/.claude/bin
curl -fsSL "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${VER}/otelcol-contrib_${VER}_darwin_arm64.tar.gz" \
  | tar -xz -C ~/.claude/bin otelcol-contrib
~/.claude/bin/otelcol-contrib --version
```

**2. Config** — ships at `telemetry/otelcol-config.yaml` (OTLP receiver on `localhost:4317`
→ `file` exporter to `~/.claude/telemetry/otel-api-errors.jsonl`, filtered to error events).
No edits needed; the output path uses `${env:HOME}`.

**3. Run it** — a macOS LaunchAgent (`launchagents/com.claude.otelcol.plist`) runs the
collector always-on (starts at login, restarts on crash). It uses a `$HOME` exec wrapper so it
carries no hardcoded username:

```bash
cp launchagents/com.claude.otelcol.plist ~/Library/LaunchAgents/
launchctl load -w ~/Library/LaunchAgents/com.claude.otelcol.plist
lsof -nP -iTCP:4317 -sTCP:LISTEN   # confirm it is listening
```

**4. Enable telemetry** — the OTEL env vars are already in `settings.json.tmpl`
(`CLAUDE_CODE_ENABLE_TELEMETRY`, `OTEL_LOGS_EXPORTER=otlp`, `OTEL_METRICS_EXPORTER=none`,
`OTEL_EXPORTER_OTLP_PROTOCOL=grpc`, `OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317`), so
`hydrate.sh` installs them. **Start the collector (step 3) before the next `claude` launch**,
or the exporter emits connection-refused noise. Env changes take effect on the next launch,
not the live session.

Inspect captured errors with `jq` over `~/.claude/telemetry/otel-api-errors.jsonl`.

## Template Strategy

Files with sensitive content use a `.tmpl` extension containing `__PLACEHOLDER__` tokens.
`hydrate.sh` reads `config.env` and produces the real files (without `.tmpl`). Generated files
are `.gitignore`d in the template repo.

| Template | Generated | Placeholders |
|---|---|---|
| `settings.json.tmpl` | `settings.json` | `__AWS_SSO_REFRESH_PATH__`, `__AWS_PROFILE__`, `__SEARXNG_URL__` |
| `CLAUDE.md.tmpl` | `CLAUDE.md` | `__DOTFILES_REPO_URL__`, `__CLAUDE_SETTINGS_REPO_URL__` |
| `scripts/_aws-sso-common.sh.tmpl` | `scripts/_aws-sso-common.sh` | `__AWS_PROFILE__`, `__SSO_START_URL__` |
| `skills/datadog-log-link/SKILL.md.tmpl` | `skills/datadog-log-link/SKILL.md` | `__DATADOG_SITE__`, `__DATADOG_EXAMPLE_SERVICE__` |

### C# language server

The template ships an `enabledPlugins` block that **disables** the official
`csharp-lsp@claude-plugins-official` plugin and enables `roslyn-lsp@jodre11-plugins` in its
place. Two reasons:

- The official plugin uses `csharp-ls` (deprecated SofusA/razzmatazz server) — it works on a
  per-file basis only, so `findReferences` and `goToDefinition` return file-scoped results on
  multi-project solutions.
- The replacement uses Microsoft's `Microsoft.CodeAnalysis.LanguageServer` (Roslyn) via the
  [`ClaudeCodeRoslynLspProxy`](https://github.com/unsafePtr/ClaudeCodeRoslynLspProxy) shim. The
  proxy injects the Roslyn-specific `solution/open` notification that Claude Code's built-in
  LSP client omits, returning solution-wide results.

Both plugins claim `.cs`. If both are enabled, whichever the LSP resolver picks first wins and
the other is silently inert — typically `csharp-ls` wins, which is the wrong default. Disabling
the official plugin removes the conflict.

`hydrate.sh` merges `enabledPlugins` with **existing wins** semantics, so this default only
takes effect on fresh clones. Existing machines need a one-time edit to flip
`csharp-lsp@claude-plugins-official` from `true` to `false` in their personal
`~/.claude/settings.json`.

To use the replacement on a new machine, install the proxy alongside the Roslyn server:

```bash
dotnet tool install --global roslyn-language-server --prerelease
dotnet tool install --global ClaudeCodeRoslynLspProxy
```

The plugin lives in [`Jodre11/claude-code-plugins`](https://github.com/Jodre11/claude-code-plugins);
register that marketplace via `extraKnownMarketplaces` in your personal `settings.json` (or
fork to your own marketplace and edit accordingly).

## Secret Scanning

Four layers keep sensitive data out of the repository:

1. **Pre-commit hook** (`.githooks/pre-commit`) — scans every added line for secret-shaped values and identity
   markers (the patterns are in `.githooks/guard-config.sh`), then runs gitleaks over the staged changes, including
   content gitleaks' own diff cannot read.
2. **Pre-push hook** (`.githooks/pre-push`) — repeats those scans over every commit a push would publish, so a commit
   made without the pre-commit (a rebase, a cherry-pick, `git am`, or the hooks turned off) is caught before it
   leaves the machine. It also scans each commit's message, author and committer, and each annotated tag's message,
   tagger and name, and refuses a ref that names a blob or a tree.
3. **CI** — gitleaks, a pattern-sync check (`tests/test-pattern-sync.sh`) and an output-ignore check
   (`tests/test-output-ignore.sh`) run on every push to `main` and every pull request into it.
4. **GitHub secret scanning and push protection** — enabled at the repository level.

`scripts/setup-platform.sh` activates both hooks by setting a repo-local `core.hooksPath .githooks`; git does not do
this on clone. The hooks use gitleaks 8.25.0 or later (8.30.1 is tested); without it they warn and run the pattern
scan only. So that no uncommitted edit decides a scan, a commit or push is refused while `.githooks/guard-config.sh`
is not exactly its staged copy, a commit while `.gitleaks.toml` or `.gitleaksignore` differs from its staged copy,
and a push of commits whose tip commits a different `guard-config.sh` from the one in use.

### Local pattern lists

To screen for names you must not publish without publishing the list, put them in `.githooks/identity-patterns.local`
(organisation and personal identity markers) and `.githooks/always-patterns.local` (secret-shaped literals such as
account IDs). Each holds one POSIX ERE per line, matched case-insensitively; blank lines and lines starting with `#`
are ignored. Both are gitignored, either may be a symlink to a list kept elsewhere, and the hooks refuse to commit or
push either one. A list that cannot be read, holds no pattern, or holds a pattern with leading or trailing
whitespace or one awk cannot match as written stops the commit rather than being skipped. The lists also apply to
`.githooks/guard-config.sh`, `.githooks/pre-commit` and `.gitleaks.toml`, which are exempt only from the tracked
patterns they define. In a linked worktree (`git worktree add`), the hooks also read the main worktree's lists, or
warn when git cannot name the main worktree (a git directory kept apart with `--separate-git-dir`).

A repository can disregard a local identity pattern that is its own public identity, such as the owner's handle in a
repository published under it: put the pattern's exact text in `LOCAL_IDENTITY_IGNORE` in `.githooks/guard-config.sh`.
An entry must equal a line of the list exactly, so a pattern that later changes bites again, and an ignored pattern
is still checked, so a malformed list still stops the commit. `always-patterns.local` and the tracked patterns cannot
be opted out of. The array is committed like any other guard setting, so every opt-out is a reviewed change.

### Bypasses

`SKIP_PATTERN_SCAN=1 git commit` (or `git push`) skips the pattern scan only, for a file that must carry a pattern;
say so in the commit body. gitleaks always runs and has no bypass: clear a false positive with a targeted
`[[allowlists]]` entry in `.gitleaks.toml`, committed with the change. gitleaks never reads `.gitleaks.toml` itself,
and its default allowlist keeps its custom rules out of some other paths (images, PDFs, lockfiles, `node_modules/`
and the like), so under the bypass only its built-in rules scan those files.

## Licence

[MIT](LICENSE)
