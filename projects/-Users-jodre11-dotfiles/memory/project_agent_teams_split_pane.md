---
name: Agent teams vs Agent tool — two different mechanisms
description: Claude Code teammates (tmux panes) vs subagents (Agent tool) are distinct systems; code-review-team uses subagents, not teammates
type: project
---

## Two distinct mechanisms

1. **Agent Teams (teammates)** — separate Claude Code processes in tmux panes. Triggered
   by asking Claude to "create a team". Controlled by `teammateMode` and
   `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`. These spawn visible tmux panes.

2. **Subagents (Agent tool)** — child processes within the same session. Dispatched by
   the model via the Agent tool. `background: true` in agent definitions means in-process
   background task, NOT tmux pane spawning. The code-review-team agent and pre-review
   skill use this mechanism.

## Ghostty env var fix (2026-04-02, commit d01c62f)

Ghostty env vars leaked into the tmux server environment, blocking teammate pane
spawning. Fixed by adding `set-environment -g -u` directives to `tmux/.tmux.conf`
for `GHOSTTY_BIN_DIR`, `GHOSTTY_RESOURCES_DIR`, `GHOSTTY_SHELL_FEATURES`,
`__CFBundleIdentifier`, and overriding `TERM_PROGRAM` to `tmux`.

## Config

- `~/.claude.json`: `"teammateMode": "auto"`, `"teammateDefaultModel": "opus"`
- `~/.claude/settings.json` env: `"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"`

**How to apply:** To get tmux pane fan-out for code reviews, ask Claude to "create a
team" rather than using `/pre-review` or the code-review-team agent (which dispatch
subagents in-process). If pane spawning breaks, check `tmux show-environment -g` for
leaked Ghostty vars.
