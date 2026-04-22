---
name: Agent Haiku model — effort flag API error workaround
description: CRITICAL — Haiku-based agents fail with effort flag API error; always override to Sonnet
type: feedback
originSessionId: 13da88f6-8c51-4731-95fd-ab22240ca0cb
---
**ALWAYS override Haiku agents to Sonnet.** When spawning any Agent that would default to the
Haiku model (e.g. `Explore` subagent type), you MUST set `model: "sonnet"` explicitly. This
applies to ALL agent dispatches where the default model is Haiku.

**Why:** There is a known issue where the `reasoning_effort` parameter is passed through to
agents, but the Haiku model does not support it. This causes an API error:
`400 output_config.effort: Extra inputs are not permitted` — and the agent fails to start
entirely, wasting the tool call.

**How to apply:** On every `Agent` tool call, consider whether the agent type defaults to Haiku.
If it does (or if you're unsure), add `model: "sonnet"` to the call. This is a temporary
workaround until the effort flag propagation bug is fixed. Err on the side of always setting
`model: "sonnet"` for built-in agent types like `Explore`.
