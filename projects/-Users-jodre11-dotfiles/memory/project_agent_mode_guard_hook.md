---
name: Agent mode guard hook — two guards for subagent dispatches
description: PreToolUse hook on Agent tool: (1) denies calls without autonomous mode, (2) in plan mode blocks writing agents via read-only allowlist
type: project
---

A PreToolUse hook (`~/.claude/hooks/agent-mode-guard.sh`) has two guards:

1. **Guard 1**: Denies Agent tool calls that don't set an autonomous mode
   (`auto`, `bypassPermissions`, `dontAsk`, or `acceptEdits`). Prevents
   subagents from inheriting `defaultMode: "plan"` from settings.json.

2. **Guard 2**: In plan mode (`permission_mode: "plan"`), only allows
   read-only agent types. Current allowlist: `Explore`, `Plan`,
   `claude-code-guide`, `statusline-setup`. All others are denied with
   instructions to exit plan mode or extend the allowlist.

**Why:** Upstream bug anthropics/claude-code#4462 — `defaultMode: "plan"` leaks
into subagents regardless of the `mode` parameter. Writing agents inherit plan
mode and stall on Write/Edit/Bash. Guard 2 prevents dispatching them in the
first place.

**How to apply:** When #4462 is resolved, remove:
1. `~/.claude/hooks/agent-mode-guard.sh`
2. The `"matcher": "Agent"` block in `~/.claude/settings.json` hooks
3. This memory file

To extend the read-only allowlist, add agent types to the `case` statement in
`agent-mode-guard.sh`.
