# Claude Settings Template

Fork-ready [Claude Code](https://docs.anthropic.com/en/docs/claude-code) harness configuration —
hooks, scripts, tools, and settings with a `config.env` placeholder strategy for keeping
sensitive values out of version control.

## What's Included

### Hooks (PreToolUse guards)

| Hook | Purpose |
|---|---|
| `_lib.sh` | Shared helpers for all hooks (input parsing, allow/deny decisions) |
| `agent-mode-guard.sh` | Prevents subagents inheriting `defaultMode: "plan"` |
| `api-failure-log.sh` | StopFailure/PostToolUseFailure: appends provider/tool errors to `telemetry/api-failures.jsonl` |
| `allow-permissions.sh` | Mirrors `settings.json` permission patterns for subagents |
| `allow-write-permissions.sh` | Mirrors Write/Edit permissions for subagents |
| `bash-guard.sh` | Enforces single-command-per-Bash-call discipline |
| `session-init.sh` | Creates session-scoped temp dir, renames the tmux session, injects context |
| `handover-detect.sh` | SessionStart: sweeps stale handovers, prompts `/rehydrate` when an active one exists for the cwd |
| `temp-path-guard.sh` | Enforces session-scoped temp directory convention |

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
| `handover-path.sh` | Resolves the handover-artifact path for the cwd (git root or cwd key); shared by the hook and commands |

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

### 1. Fork and clone

Fork this repo, then clone it as `~/.claude`:

```bash
# Back up existing ~/.claude if present
[ -d ~/.claude ] && mv ~/.claude ~/.claude.bak

git clone git@github.com:youruser/claude-settings.git ~/.claude
cd ~/.claude
```

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
are preserved across template updates.

The web-search plugin requires a reachable SearXNG instance; point `SEARXNG_URL` at it
(self-hosted Docker or a cloud deployment).

### 4. Run platform setup

```bash
bash scripts/setup-platform.sh
```

This writes the platform-specific `awsAuthRefresh` path into `settings.json` and applies
`skip-worktree` to hide the local modification from git.

### 5. Re-applying template changes later

After pulling new template changes, re-run the merge with platform settings preserved:

```bash
bash scripts/apply-settings.sh
```

This lifts `skip-worktree`, runs `hydrate.sh --force`, then re-runs `setup-platform.sh` to
re-inject the platform `awsAuthRefresh` and re-apply `skip-worktree`.

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
3. **On the fresh session**, the `handover-detect.sh` SessionStart hook spots the
   active handover and prompts `/rehydrate`. Rehydrate reads the artifact,
   recomputes the fingerprint, and **reconciles against the working tree**:
   - clean match → resume;
   - drift that's consistent with the handover → resume;
   - drift that contradicts it (work already done, tests now green) → stop and
     ask. It always discloses which reconciliation mode it used.

**Reconciliation modes.** Inside a git repo the key is the repo root and
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

Three layers of protection prevent leaking sensitive data:

1. **Pre-commit hook** (`.githooks/pre-commit`) — pattern-scans staged files for known sensitive values
2. **Gitleaks** (`.gitleaks.toml`) — comprehensive secret detection, locally and in CI
3. **GitHub secret scanning + push protection** — enabled at the repository level

Set `core.hooksPath = .githooks` to activate the local hook (done automatically on clone).

## Licence

[MIT](LICENSE)
