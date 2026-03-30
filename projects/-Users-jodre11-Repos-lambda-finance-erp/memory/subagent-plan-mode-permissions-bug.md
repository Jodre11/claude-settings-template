---
name: Subagent permission matching bug
description: Subagents don't match parent settings.json permission allowlists correctly — tracked in anthropics/claude-code#39834 (and related #10906)
type: reference
---

Subagents fail to match allowlisted permission globs from `settings.json`, prompting for pre-approved commands (e.g. `mkdir -p /tmp/claude-*`, `jb inspectcode *`). May be related to or worsened by `defaultMode: "plan"`.

Raised by user: https://github.com/anthropics/claude-code/issues/39834
Related: https://github.com/anthropics/claude-code/issues/10906 (plan agent ignores parent permissions)

**How to apply:** When launching subagents that need write-capable bash commands (e.g. `code-analysis`, `code-review-team`), be aware they may be blocked on permissions even if the command is allowlisted. Workaround: pass `mode: "bypassPermissions"` or `mode: "acceptEdits"` on the Agent call.
