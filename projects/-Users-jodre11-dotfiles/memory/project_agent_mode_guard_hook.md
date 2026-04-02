---
name: Agent mode guard hook — workaround for subagent plan mode inheritance
description: PreToolUse hook on Agent tool denies calls without mode:"auto", working around upstream bug where subagents inherit defaultMode:"plan"
type: project
---

A PreToolUse hook (`~/.claude/hooks/agent-mode-guard.sh`) denies Agent tool calls
that don't set an autonomous mode (`auto`, `bypassPermissions`, `dontAsk`, or
`acceptEdits`). This prevents subagents from silently inheriting `defaultMode: "plan"`
from `settings.json` and stalling on Write/Edit/Bash.

**Why:** Upstream bug anthropics/claude-code#4462 — `defaultMode: "plan"` in
settings.json leaks into subagents regardless of the `mode` parameter on the Agent
tool call. The hook forces the model to always set `mode` explicitly.

**How to apply:** When anthropics/claude-code#4462 is resolved, remove:
1. `~/.claude/hooks/agent-mode-guard.sh`
2. The `"matcher": "Agent"` block in `~/.claude/settings.json` hooks
3. This memory file
