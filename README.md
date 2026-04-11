# claude-settings

Cross-platform Claude Code configuration stored as a git repository at `~/.claude`.
Tested on macOS, Linux, WSL, and Windows.

## What's Tracked

| Path | Purpose |
|---|---|
| `CLAUDE.md` | Global instructions: code style, preferences, tool behaviour |
| `settings.json` | Permissions, hooks, environment variables (cross-platform) |
| `commands/` | Custom slash commands |
| `hooks/` | Shell scripts triggered by Claude Code events |
| `agents/` | Agent configurations |
| `skills/` | Custom skills |
| `scripts/` | Setup and utility scripts |
| `projects/` | Per-project CLAUDE.md files and memory |
| `.gitignore` | Excludes ephemeral data (sessions, history, cache, etc.) |

### Not Tracked (per-machine)

| Path | Purpose |
|---|---|
| `settings.local.json` | Machine-specific overrides (e.g. `awsAuthRefresh`) |

## Setup on a New Machine

### Prerequisites

- Git (with SSH access to GitHub)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code/overview)
- `jq` (used by hooks and the setup script)
- Bitwarden Desktop running and unlocked (provides SSH agent for auth and
  commit signing — no private key files on disk)

### 1. Clone into `~/.claude`

Back up any existing directory first:

```bash
mv ~/.claude ~/.claude.bak
git clone git@github.com:Jodre11/claude-settings.git ~/.claude
```

### 2. Run platform setup

Detects your OS and writes the correct `awsAuthRefresh` command into
`settings.local.json`:

```bash
bash ~/.claude/scripts/setup-platform.sh
```

### 3. Configure Bedrock credentials

Create `~/.claudeenv` with your org's AWS Bedrock inference profile ARNs
(not tracked — contains org-specific values). See the
[Claude Code Setup Guide](https://github.com/HavenEngineering/sre/wiki/Claude-Code-Setup-Guide)
for the template and current ARNs.

### 4. Launch Claude Code

It picks up the configuration automatically from `~/.claude/settings.json`
merged with `~/.claude/settings.local.json`.

## Platform Notes

### macOS

Primary development machine. Full dotfiles setup via
[dotfiles](https://github.com/Jodre11/dotfiles) repo and `bootstrap.sh`.

### Windows

Claude Code runs natively. `awsAuthRefresh` is wrapped with Git Bash
(`setup-platform.sh` handles this automatically) because Claude Code
invokes it via CMD, which cannot execute `.sh` files directly.

Hooks work cross-platform — Claude Code runs hook commands through bash
on all platforms. The shared `settings.json` uses `~` paths which bash
expands correctly everywhere.

### WSL

Runs as a separate environment with its own `~/.claude` clone, AWS
credentials, and `settings.local.json`. The WSL `aws` CLI and SSO cache
are independent from the Windows host.

### Linux

Same as macOS/WSL. Run `setup-platform.sh` after cloning.

## Cross-Platform Design

- **`settings.json`** (tracked) contains only platform-agnostic settings.
  Paths use `~` which Claude Code and bash expand on all platforms.
- **`settings.local.json`** (gitignored) contains per-machine overrides
  like `awsAuthRefresh`. Written by `scripts/setup-platform.sh`.
- **Hook scripts** use `#!/usr/bin/env bash` shebangs and avoid
  platform-specific paths.
- **`awsAuthRefresh`** must be a command that the system shell can execute.
  On macOS/Linux/WSL this is the script path directly. On Windows it is
  wrapped as `"<git-bash-path>" "<script-path>"`.

## Related Repositories

- [dotfiles](https://github.com/Jodre11/dotfiles) (`~/dotfiles`) — macOS
  dotfiles managed with GNU Stow (shell, git, tmux, Ghostty, Hammerspoon,
  Starship, gh CLI)
