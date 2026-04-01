---
name: Subagent plan-mode stall bug
description: Subagents inherit defaultMode "plan" from settings.json, blocking Write/Edit tools and causing indefinite hangs. Fix applied 2026-04-01 in CLAUDE.md.
type: project
---

Subagents inherit `defaultMode: "plan"` from `settings.json`. In plan mode, tools like Write and
Edit are unavailable. When a subagent (e.g. a Plan agent) needs to write output, it stalls
indefinitely — no error, no timeout, just silence.

**Observed 2026-04-01:** A Plan subagent (`plan-agent-naming-hook`) completed its research phase,
then tried `ToolSearch("select:Write")` to fetch the Write tool schema. Got "No matching deferred
tools found" and went silent for 5+ minutes until manually interrupted. The subagent log
(`subagents/agent-a47b0fbe803ac238d.jsonl`) confirmed the stall.

**Why:** `settings.json` sets `defaultMode: "plan"` for the interactive session. Subagents
inherit this and cannot use Write/Edit, which plan mode restricts.

**Fix applied (2026-04-01, commit 8accbf7):** Added a CLAUDE.md directive requiring
`mode: "auto"` on all Agent tool dispatches. This lets subagents execute autonomously while the
parent session retains plan-mode control.

**How to apply:**
- All Agent tool calls must include `mode: "auto"`
- This is enforced by CLAUDE.md directive only (no hook yet)
- A programmatic hook (`agent-name-guard.sh`) to enforce agent naming and mode was planned but
  not yet implemented — could be a future enhancement
