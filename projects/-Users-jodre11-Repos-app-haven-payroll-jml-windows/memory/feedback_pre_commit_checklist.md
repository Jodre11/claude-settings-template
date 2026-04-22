---
name: Pre-commit checklist — InspectCode and CLAUDE.md counts
description: Always run InspectCode after editing C# files and update CLAUDE.md test/project counts before committing
type: feedback
originSessionId: 13da88f6-8c51-4731-95fd-ab22240ca0cb
---
**Run InspectCode and update CLAUDE.md counts before committing.**

**Why:** Missed both on PR #29 — InspectCode is required by CLAUDE.md after editing C# files,
and the test count in CLAUDE.md went stale (693 → 737) without being updated. Both should have
been done before the commit, not caught in review.

**How to apply:** Before every commit that touches C# files:
1. Run `jb inspectcode` and fix any issues
2. If test count changed, update CLAUDE.md
3. If project structure changed, update CLAUDE.md
