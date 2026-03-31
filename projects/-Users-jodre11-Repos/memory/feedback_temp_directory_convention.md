---
name: Temp directory convention — session ID not $PPID
description: Use /tmp/claude-{session_name}/ for temp files — $PPID differs across subagents and is not portable cross-platform
type: feedback
---

Temp directory convention changed from `/tmp/claude-$PPID/` to `/tmp/claude-{session_name}/`
(CLAUDE.md updated 2026-03-30).

**Why:**
- `$PPID` resolves to a different PID in subagents vs the main conversation, so subagents create
  a different temp directory and can't share files with the parent
- `$PPID` is a Unix-ism — not available on Windows (PowerShell has `$PID` but not `$PPID`)
- Session ID is stable across parent and all child subagents within one conversation

**How to resolve the session ID:**
- The session ID is a UUID available from conversation context (e.g. the transcript path in system
  reminders, which contains the session ID as the filename stem)
- It is NOT exposed as an environment variable — resolve it once from context and reuse throughout
- When spawning subagents, pass the resolved temp path in the prompt (e.g.
  `"use /tmp/claude-a37e4dd1-ee76-48c0-a77a-5502e05e59cf/ for temp files"`)

**Hook compatibility:**
- All hooks (`allow-permissions.sh`, `bash-guard.sh`, `temp-path-guard.sh`, `allow-write-permissions.sh`)
  match `/tmp/claude-*` — they don't care whether the suffix is a PID or a UUID
- No hook changes were needed for this convention switch

**Cross-platform note:**
- `/tmp/` is Unix-specific. On Windows the equivalent would be `$env:TEMP\claude-{session_name}\`
- The current hooks and CLAUDE.md are macOS/Linux only. If Windows support is added later, the
  hooks would need platform-aware path matching
