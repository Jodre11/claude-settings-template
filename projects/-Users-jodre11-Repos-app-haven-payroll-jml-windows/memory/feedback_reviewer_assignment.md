---
name: reviewer-assignment
description: Only add MarlonGillWork (or any reviewer) to PRs when explicitly asked
type: feedback
---

Do not add reviewers to PRs unless the user explicitly requests it.

**Why:** User was surprised by unsolicited reviewer assignment on PR #16. Reviewer additions are a visible action that notifies the reviewer — should only happen on request.

**How to apply:** When creating PRs, omit the `--reviewer` flag unless the user specifically asks to add a reviewer.
