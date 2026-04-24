---
name: Haiku agents fail on Bedrock — use Sonnet override
description: Any agent type that defaults to Haiku returns 400 output_config.effort on Bedrock — set model to sonnet to avoid the error
type: feedback
originSessionId: 4e150787-3352-4765-a4ee-f7fd9e15058d
---
Agent tool calls that use the Haiku model fail on Bedrock with `400 output_config.effort: Extra inputs are not permitted`. Claude Code passes an effort parameter by default, and Bedrock Haiku does not accept it. Sonnet and Opus are unaffected.

**Why:** This is a Bedrock API problem — the Bedrock runtime rejects `output_config.effort` for Haiku but not for Sonnet or Opus. Haiku agents may work fine on the Anthropic API or other providers. There is an open issue on the Claude Code GitHub repo tracking this — the workaround may become unnecessary once it's fixed.

**How to apply:** When dispatching any agent type that defaults to Haiku (e.g. Explore), set `model: "sonnet"`. Agent types that already default to Sonnet or Opus need no override.
