---
name: Subagent permission propagation — workaround applied
description: Subagents don't inherit permissions.allow but do inherit hooks — allow-permissions hooks now mirror the allowlist for subagent use
type: feedback
---

Subagents do not inherit `permissions.allow` patterns from `settings.json`. They *do* inherit
PreToolUse hooks. Upstream bug: anthropics/claude-code#18950.

**Workaround applied 2026-03-30:** Two allow hooks mirror the permission allowlist:
- `~/.claude/hooks/allow-permissions.sh` — auto-allows Bash commands matching the same base
  commands in `permissions.allow` (gh, git, dotnet, aws, etc.)
- `~/.claude/hooks/allow-write-permissions.sh` — auto-allows Write/Edit to `/tmp/claude-*` paths

Hooks run in parallel with existing deny hooks. Most restrictive decision wins, so `bash-guard.sh`
and `temp-path-guard.sh` denials still override allows. Tested and confirmed working with a
background agent running `mkdir`, `Write`, and `gh issue view`.

**Why:** Observed 2026-03-27 when a background agent wasted ~80s and 16k tokens failing to run
`gh issue edit` and `mkdir` because deny hooks fired with no corresponding allow mechanism.

**How to apply:**
- Subagents should now work for `gh`, `git`, `dotnet`, `aws`, and other allowlisted commands
- The `$PPID` issue is resolved: temp convention now uses `/tmp/claude-{session_id}/` which is stable
  across parent and all child subagents. Pass the resolved temp path in the subagent prompt.
- When adding new commands to `permissions.allow` in `settings.json`, also add them to the `case`
  statement in `allow-permissions.sh` (two places to maintain until upstream fix lands)
- Still verify work is needed before spawning agents — the original agent was unnecessary
