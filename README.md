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
| `allow-permissions.sh` | Mirrors `settings.json` permission patterns for subagents |
| `allow-write-permissions.sh` | Mirrors Write/Edit permissions for subagents |
| `bash-guard.sh` | Enforces single-command-per-Bash-call discipline |
| `temp-path-guard.sh` | Enforces session-scoped temp directory convention |
| `tmux-sanitise-name.sh` | Auto-abbreviates tmux session names |

### Scripts

| Script | Purpose |
|---|---|
| `_aws-sso-common.sh` | Shared constants for AWS SSO (generated from `.tmpl`) |
| `aws-sso-preflight.sh` | Check SSO token validity before launching Claude Code |
| `aws-sso-refresh.sh` | Smart AWS SSO login for `awsAuthRefresh` |
| `setup-platform.sh` | Configure platform-specific settings (macOS/Linux/WSL/Windows) |
| `sso-cache-check.py` | AWS SSO cache walker for token validity checks |
| `statusline.sh` | ANSI-coloured status line renderer |

### Skills

| Skill | Purpose |
|---|---|
| `datadog-log-link` | Generate Datadog Log Explorer URLs from natural language queries |

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
./hydrate.sh
```

This generates real config files from `.tmpl` templates using your `config.env` values.

### 4. Run platform setup

```bash
bash scripts/setup-platform.sh
```

This writes the platform-specific `awsAuthRefresh` path into `settings.json` and applies
`skip-worktree` to hide the local modification from git.

### 5. Install tools

```bash
# md2clip (macOS only)
mkdir -p ~/.local/bin
ln -sf ~/.claude/tools/md2clip ~/.local/bin/md2clip
```

## Template Strategy

Files with sensitive content use a `.tmpl` extension containing `__PLACEHOLDER__` tokens.
`hydrate.sh` reads `config.env` and produces the real files (without `.tmpl`). Generated files
are `.gitignore`d in the template repo.

| Template | Generated | Placeholders |
|---|---|---|
| `settings.json.tmpl` | `settings.json` | `__AWS_SSO_REFRESH_PATH__`, `__AWS_PROFILE__` |
| `CLAUDE.md.tmpl` | `CLAUDE.md` | `__DOTFILES_REPO_URL__`, `__CLAUDE_SETTINGS_REPO_URL__` |
| `scripts/_aws-sso-common.sh.tmpl` | `scripts/_aws-sso-common.sh` | `__AWS_PROFILE__`, `__SSO_START_URL__` |
| `skills/datadog-log-link/SKILL.md.tmpl` | `skills/datadog-log-link/SKILL.md` | `__DATADOG_SITE__`, `__DATADOG_EXAMPLE_SERVICE__` |

## Secret Scanning

Three layers of protection prevent leaking sensitive data:

1. **Pre-commit hook** (`.githooks/pre-commit`) — pattern-scans staged files for known sensitive values
2. **Gitleaks** (`.gitleaks.toml`) — comprehensive secret detection, locally and in CI
3. **GitHub secret scanning + push protection** — enabled at the repository level

Set `core.hooksPath = .githooks` to activate the local hook (done automatically on clone).

## Licence

[MIT](LICENSE)
