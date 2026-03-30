---
name: Subagent permission and hook limitations
description: Background agents with bypassPermissions still get blocked by PreToolUse hooks (temp-path-guard, bash-guard) — hooks override permission modes
type: feedback
---

Background/subagents launched with `mode: "bypassPermissions"` are still subject to PreToolUse hooks.
The `temp-path-guard.sh` hook blocks Write calls to bare `/tmp/` paths, and `bash-guard.sh` blocks
compound commands. These hooks issue hard denials that `bypassPermissions` does not override.

Additionally, `$PPID` in subagent Bash calls expands to the subagent's parent PID, not the main
session PID — so `/tmp/claude-$PPID` resolves to a different directory than the main conversation's
temp directory.

**Why:** Observed 2026-03-27 when a background agent wasted ~80s and 16k tokens failing to update
a GitHub issue body because every Bash and Write call was denied by hooks.

**How to apply:**
- Do not spawn background agents for tasks that require writing temp files or running `gh issue edit`
  via Bash — do these in the main conversation where permissions are already granted.
- Before spawning an agent to fix something, verify whether the fix is actually needed (the issue
  body was already correct — the agent was unnecessary).
- For `gh` operations in agents, the read-only `gh issue view --json body` worked fine; the write
  (`gh issue edit`) did not.
