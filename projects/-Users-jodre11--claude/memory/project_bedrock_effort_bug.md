---
name: Bedrock effortLevel 400 bug
description: effortLevel in settings.json causes Bedrock 400 on Haiku subagents — reproduced and resolved 2026-04-16 by removing the setting (default is already "high")
type: project
originSessionId: 586e5ced-8c69-4c15-aca5-cb5e8d881872
---
When `effortLevel` is set in `settings.json` (e.g. `"high"`), Claude Code passes `output_config.effort` in API requests. Bedrock's Haiku endpoint rejects this with `400: output_config.effort: Extra inputs are not permitted`. Opus and Sonnet accept it without error.

**Why:** Haiku does not support the `effort` parameter. Bedrock validates strictly and rejects unknown fields.

**Status:** Reproduced and resolved 2026-04-16. Removed `effortLevel` from settings.json — the default is already `"high"`, so the setting was pointless. Additionally, the Bedrock model resolution bug (see `project_bedrock_subagent_bug.md`) already prevents Haiku subagents from spawning in practice, so this bug has no real-world impact under current workarounds.

**How to apply:**
- Do NOT re-add `effortLevel` to settings.json — it's redundant (default is "high") and breaks Haiku on Bedrock
- If the Bedrock model resolution bug is fixed and Haiku subagents become viable again, this effortLevel bug will resurface — Claude Code should strip `output_config.effort` for Haiku
