---
name: Bedrock subagent model resolution bug
description: Known Claude Code bug where subagents send normalised model IDs instead of Bedrock inference profile ARNs — causes instant 400 failures. Workaround applied 2026-04-01; monitor upstream for fix.
type: project
---

Subagents (Agent tool, agent teams) fail on Bedrock with `400 The provided model identifier is invalid` when their agent definition frontmatter contains `model: sonnet` (or `opus`/`haiku`). Claude Code sends a normalised ID like `claude-sonnet-4-6` instead of resolving to the `ANTHROPIC_DEFAULT_SONNET_MODEL` inference profile ARN. The parent process resolves correctly; subagents do not.

**Why:** Known Claude Code bug — open issues #25193, #29660, #32987. Present from at least v2.1.70 through v2.1.89.

**Workaround applied (2026-04-01):** Removed all `model:` lines from the 10 agent definitions in `~/.claude/agents/*.md`. Subagents now inherit the parent's model, which is already correctly resolved to the Bedrock ARN.

**Trade-off:** All subagents run on the parent model (currently Opus). Cost optimisation of running review agents on Sonnet is lost until the upstream bug is fixed.

**How to apply:**
- Monitor issues #25193, #29660, #32987 for a fix in a future Claude Code release
- When fixed, restore `model: sonnet` to the review agents (archaeology, code-analysis, consistency, correctness, efficiency, jbinspect, reuse, security, style) and `model: opus` to code-review-team
- Do NOT hard-code Bedrock ARNs in `settings.json` — this would break the planned Bedrock/first-party API switching setup

**Verification (next session):** Trigger a subagent (any Agent tool call or code review) and confirm it completes instead of dying instantly.

**Not the cause:** Plan mode inheritance and permission settings are not involved — the subagent fails at the API layer on its very first call, before any tool use or mode selection occurs.

**Debug logs:** `~/.claude/debug/` contains session logs (note: may have stopped writing after v2.1.70 upgrade). The Statsig failed logs at `~/.claude/statsig/statsig.failed_logs.*` also capture API errors.
