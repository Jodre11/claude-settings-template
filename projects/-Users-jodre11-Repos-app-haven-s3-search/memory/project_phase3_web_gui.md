---
name: Phase 3 — Web-based GUI
description: Planned future work to build a web GUI for S3Search; blocked on deployment decisions
type: project
---

Phase 3 is a web-based GUI for S3Search.

**Why:** The service layer (IS3ObjectEnumerator, IContentSearcher) was designed for reuse outside the CLI — the design spec for --tree explicitly mentions "lays groundwork for a future web-based GUI."

**Status:** Blocked. The user needs to answer deployment questions (hosting, auth, infrastructure) while working on a different project. Do not start this work until the user returns with deployment decisions.

**How to apply:** When the user revisits this, ask about deployment constraints before planning the implementation.
