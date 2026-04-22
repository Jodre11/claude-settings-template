---
name: Bedrock effortLevel 400 bug
description: Claude Code sends output_config.effort to Haiku subagents on Bedrock causing 400; upstream issues #51377, #51059 elevated 2026-04-21
type: project
originSessionId: 586e5ced-8c69-4c15-aca5-cb5e8d881872
---
Claude Code sends `output_config.effort` unconditionally in API requests. Haiku on Bedrock rejects this with `400: output_config.effort: Extra inputs are not permitted`. Opus and Sonnet accept it.

**Why:** Haiku does not support the `effort` parameter. Bedrock validates strictly. This hits subagents dispatched with `model: haiku` — the parent Opus session works fine, but effort leaks through to the subagent's API call.

**Upstream issues (elevated 2026-04-21):**
- **#51377** — the broadest open bug (effort sent unconditionally, breaks Bedrock). Commented with subagent reproduction path and upvoted.
- **#51059** — feature request for `modelEffort` block in settings.json (per-model effort config). Upvoted.
- **#30795** — older closed precedent (v2.1.68, Sonnet 4.5 on GovCloud).

**How to apply:**
- Do NOT add `effortLevel` to settings.json — it's redundant (default is "high") and worsens the problem
- Avoid `model: haiku` in agent definitions until upstream fix ships; use `model: "sonnet"` as the cost-optimised alternative (confirmed working for built-in agent types like `claude-code-guide`, `Explore`, etc.)
- Monitor #51377 and #51059 for resolution
