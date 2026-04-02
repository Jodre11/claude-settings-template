---
name: Agent teams split-pane fixed by stripping Ghostty env vars
description: Claude Code split-pane teammate mode works in Ghostty+tmux after stripping Ghostty env vars in tmux.conf
type: project
---

Claude Code agent teams split-pane mode didn't work in Ghostty+tmux because Ghostty
environment variables leaked into the tmux server environment. Claude Code detected
these and applied its Ghostty exclusion, even though tmux handles the pane splitting.

**Fix (2026-04-02):** Added `set-environment -g -u` directives to `tmux/.tmux.conf`
to strip `GHOSTTY_BIN_DIR`, `GHOSTTY_RESOURCES_DIR`, `GHOSTTY_SHELL_FEATURES`,
`__CFBundleIdentifier`, and override `TERM_PROGRAM` to `tmux`. Confirmed working.

**Config:** `~/.claude.json` has `"teammateMode": "auto"`, `"teammateDefaultModel": "opus"`.
`~/.claude/settings.json` has `"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"`.

**How to apply:** If split-pane breaks again, check `tmux show-environment -g` for
leaked Ghostty vars. The `set-environment -g -u` lines in tmux.conf should strip them
on server start. If tmux is started from a non-Ghostty terminal the lines are harmless
no-ops.
