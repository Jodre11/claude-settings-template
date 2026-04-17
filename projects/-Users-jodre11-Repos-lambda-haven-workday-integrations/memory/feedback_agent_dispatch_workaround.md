---
name: Agent tool fails on Bedrock — use TeamCreate instead
description: The Agent tool returns 400 errors on Bedrock due to output_config.effort — use TeamCreate for parallel agent dispatch
type: feedback
originSessionId: 4e150787-3352-4765-a4ee-f7fd9e15058d
---
The Agent tool fails on Bedrock with a 400 error related to `output_config.effort` / `effortLevel`. Use TeamCreate to dispatch parallel agents instead.

**Why:** Bedrock runtime does not support the effort parameter that Claude Code sends with Agent tool calls.

**How to apply:** Whenever parallel agents are needed, use TeamCreate rather than the Agent tool. This applies to all sessions on this Bedrock-backed environment.
