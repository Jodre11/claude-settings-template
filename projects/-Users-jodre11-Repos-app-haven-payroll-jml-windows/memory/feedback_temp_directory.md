---
name: Use /tmp/claude-{session_name}/ for all temporary files
description: All Claude sessions must use /tmp/claude-{session_name}/ with session-scoped subdirectory, never bare /tmp/ or $TMPDIR
type: feedback
---

All temporary files (tool output, diffs, commit drafts, InspectCode XML, etc.) must go in `/tmp/claude-{session_name}/`, never bare `/tmp/`, `$TMPDIR`, or `/var/folders/`.

The session ID is a UUID available from conversation context (e.g. the transcript path). Resolve it once and reuse throughout. When spawning subagents, pass the resolved temp path in the prompt.

Create the directory with `mkdir -p /tmp/claude-{session_name}` before first use. Files within don't need a prefix — the directory is already session-scoped.

**Why:** User runs multiple Claude sessions concurrently. A shared flat `/tmp/` directory risks filename collisions. Session-scoped subdirectories isolate each session's temp files. OS handles cleanup on reboot. Unlike `$PPID`, the session ID is stable across parent and all child subagents.

**How to apply:** Before writing any temp file, create `/tmp/claude-{session_name}/` if it doesn't exist. Use natural filenames within. Clean up when done. This is a global convention — applies to all repos.
