---
name: Bedrock subagent model resolution bug
description: Known Claude Code bug where subagents send normalised model IDs instead of Bedrock inference profile ARNs — causes instant 400 failures. Workaround applied 2026-04-01; monitor upstream for fix.
type: project
---

Subagents on Bedrock failed with `400 The provided model identifier is invalid` when agent definitions contained `model: sonnet`. Issues #25193, #29660, #32987 — all closed (as inactive, not with explicit fix confirmation).

**Workaround applied 2026-04-01:** Removed `model:` lines from agent definitions so subagents inherited the parent model (Opus).

**Model overrides restored 2026-04-21 (v2.1.116):** `model: sonnet` restored to 9 reviewer agents, `model: opus` to code-review-team, in `/Users/jodre11/Repos/claude-code-plugins/plugins/code-review/agents/`. Not yet verified with a live test — if subagents fail with 400 errors, revert by removing the `model:` lines again.

**How to apply:** On next code review run, confirm subagents complete successfully on Sonnet. If they fail, revert and reopen an issue.
