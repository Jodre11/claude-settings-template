# tmux Claude Wrapper

## What
A zsh function in `~/.zshrc` that wraps every interactive `claude` invocation in a tmux session for detach/reattach support (especially useful for remote access via SSH/Mosh/Termius).

## Files
- `~/.zshrc` — contains the `claude()` function, `tls` and `ta` aliases
- `~/.claude/hooks/check-aws-credentials.sh` — AWS SSO auth hook, adapted for remote sessions

## Current State (2026-03-23)
- Sessions named `claude-HHMM` (timestamp), with `-$$` PID suffix if same-minute collision
- tmux `pane-title-changed` hook syncs Claude's `/name` to tmux session name
- Hook ignores default titles (`claude`, `Claude Code`, `✳ Claude Code`) to preserve the timestamp name
- Non-session CLI invocations (`--version`, `--help`, subcommands like `auth`, `mcp`, `update`, etc.) pass through to the binary directly
- Auth hook detects SSH sessions and uses `--no-browser` flow instead of `--use-device-code`
- Name sanitisation extracted to `~/.claude/hooks/tmux-sanitise-name.sh` (requires bash 5+ from Homebrew: `/opt/homebrew/bin/bash`)
- Sanitiser abbreviates common programming terms (e.g. authentication→auth, infrastructure→infra, kubernetes→k8s) and strips stopwords (the, a, for, with, etc.)
- Collision guard: if abbreviated name clashes with an existing tmux session, appends last 2 digits of session id
- Truncation limit: 25 chars (down from 30)

## Known Issue / Next Steps
- The `/rename` command inside Claude should trigger the pane-title-changed hook and update the tmux session name — needs end-to-end verification
- May want to test that the default-title filter correctly catches all variants (e.g. with/without `✳` prefix)
- Abbreviation map can be extended in `~/.claude/hooks/tmux-sanitise-name.sh` as needed
