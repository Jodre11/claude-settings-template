---
name: NO ACCESS bug report from Jon White
description: RESOLVED — four workers were re-assigned via /set-group, Jon confirmed AD integration reads provisioning groups correctly (2026-04-28)
type: project
originSessionId: f67a9b29-1f83-46f4-a293-de7325c3dd86
---
Jon White reported on 2026-04-24 that four workers were showing "NO ACCESS" in Workday:

- 175601 — Linda Tanswell
- 175088 — Shannon Bartley
- 177222 — Jamie Jordan
- 177839 — Fran Cooper

**Resolution:** Re-assigned via `/set-group` Harness endpoint on 2026-04-25. Jon confirmed on
2026-04-28 that provisioning groups are readable from the AD integration — end-to-end chain working.

**Root cause:** These workers were likely missed during the initial bulk run or had stale assignments.
The `/set-group` ad-hoc endpoint proved useful for targeted corrections.
