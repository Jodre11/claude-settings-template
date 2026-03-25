# claude-settings

Claude Code configuration for macOS, stored as a git repository at `~/.claude`.

## What's Tracked

| Path | Purpose |
|---|---|
| `CLAUDE.md` | Global instructions: code style, preferences, tool behaviour |
| `settings.json` | Permissions, hooks, and environment variables |
| `settings.local.json` | Machine-specific settings (not synced across machines) |
| `commands/` | Custom slash commands |
| `hooks/` | Shell scripts triggered by Claude Code events |
| `agents/` | Agent configurations |
| `skills/` | Custom skills |
| `projects/` | Per-project CLAUDE.md files and memory |
| `.gitignore` | Excludes ephemeral data (sessions, history, cache, etc.) |

## Setup on a New Machine

1. Install [Claude Code](https://docs.anthropic.com/en/docs/claude-code/overview)

2. Clone into `~/.claude` (back up any existing directory first):

    ```bash
    mv ~/.claude ~/.claude.bak
    git clone git@github.com:Jodre11/claude-settings.git ~/.claude
    ```

3. Launch Claude Code — it will pick up the configuration automatically.

## Related Repositories

- [dotfiles](https://github.com/Jodre11/dotfiles) (`~/dotfiles`) — macOS dotfiles managed with GNU Stow (shell, git, tmux, Ghostty, Hammerspoon, Starship, gh CLI)
