---
name: Use /tmp/claude-$PPID/ for all temporary files
description: All Claude sessions must use /tmp/claude-$PPID/ with session-scoped subdirectory, never bare /tmp/ or $TMPDIR
type: feedback
---

All temporary files (tool output, diffs, commit drafts, InspectCode XML, etc.) must go in `/tmp/claude-$PPID/`, never bare `/tmp/`, `$TMPDIR`, or `/var/folders/`.

Create the directory with `mkdir -p /tmp/claude-$PPID` before first use. Files within don't need a prefix — the directory is already session-scoped.

**Why:** User runs multiple Claude sessions concurrently. A shared flat `/tmp/` directory risks filename collisions. Session-scoped subdirectories isolate each session's temp files. OS handles cleanup on reboot.

**How to apply:** Before writing any temp file, create `/tmp/claude-$PPID/` if it doesn't exist. Use natural filenames within. Clean up when done. This is a global convention — applies to all repos.
