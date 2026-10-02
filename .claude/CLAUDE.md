# claude-settings

If `origin` is the upstream `claude-settings-template` repository rather than your private copy, this checkout is the
public seed: change it by PR only and land nothing personal, organisation-specific or machine-specific.

This repo is cloned to `~/.claude` independently on each machine (macOS, Windows, WSL, Linux): commit and push changes
when you edit files there. Run the tests with `bash tests/run.sh`; on macOS use Homebrew's bash, as the suite needs
bash 4 or later.

## Cross-Platform Architecture

- **`settings.json`** (untracked; generated per machine by `hydrate.sh` from `settings.json.tmpl`) — cross-platform
  settings. All paths use `~` (expanded by Claude Code for permissions, by the shell for hooks and the status line).
  Never put absolute or `$HOME` paths here — except `awsAuthRefresh`, which `scripts/setup-platform.sh` writes (below).
- **`settings.local.json`** — Claude Code reads it only as a project's local settings
  (`<project>/.claude/settings.local.json`). `~/.claude/settings.local.json` is never a user-level layer, though it is
  read as project-local settings when cwd is `$HOME`.
- **`awsAuthRefresh`** — written into `settings.json` by `scripts/setup-platform.sh` with a platform-specific absolute
  path. On Windows, Claude Code passes this to CMD (not bash), so `~` and `$HOME` do not expand — the script wraps it
  with Git Bash and uses absolute Windows paths. On macOS/Linux/WSL it runs through the shell, so absolute paths work
  directly. `settings.json` is gitignored, so the per-machine value never reaches git.
- **Hooks** — hook commands run via `sh -c`, where `~` and `$HOME` expand in `command` values; the hook scripts use
  `#!/usr/bin/env bash` shebangs.

## Custom Tools

`~/.claude/tools/` holds custom CLI utilities. They are version-controlled; install each one per machine.

- `md2clip` (macOS only) — converts Markdown to rich-text HTML and copies it to the clipboard. Install:
  `ln -sf ~/.claude/tools/md2clip ~/.local/bin/md2clip`. The default target is Teams; `--outlook` keeps `<p>` spacing
  and adds table borders, which Teams strips and Outlook requires; `--debug` prints the HTML instead of copying.
