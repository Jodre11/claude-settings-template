---
name: Code review — teammates vs subagents comparison (2026-04-02)
description: Three-way test on payroll feat/reactive-config; updated /pre-review with teammate orchestration produces the best output — proper synthesis, contested findings, Opus-only findings, JBInspect integration
type: project
---

## Test setup (2026-04-02)

Branch: `feat/reactive-config` in `app-haven-payroll-jml-windows`
Scope: 55-57 files, +2981 / -880 lines

Three runs compared:
1. **Subagents**: code-review-team orchestrator via Agent tool (in-process)
2. **Teammates (raw)**: 7 reviewers in tmux panes, basic collation only
3. **Teammates (orchestrated)**: 8 reviewers in tmux panes (7 + jbinspect),
   base session does independent analysis + full synthesis per updated `/pre-review`

## Results

| | Subagents | Teammates (raw) | Teammates (orchestrated) |
|---|---|---|---|
| Findings | 12 | 19 | 13 |
| Important | 2 | 4 | 5 |
| Contested | 1 | 0 | 2 |
| Opus-only | 0 | 0 | 2 |
| Dismissed | 0 | 0 | 3 |
| JBInspect | no | no | yes (new vs pre-existing distinguished) |
| Effort ratings | no | no | yes |
| Visibility | none | all panes | all panes |

## Conclusion

The orchestrated teammate approach (run 3) is the clear winner:
- Best synthesis quality — Opus assessment, contested findings with positions,
  dismissed findings with reasoning, effort ratings
- JBInspect properly integrated with new-vs-pre-existing distinction
- Real-time visibility via tmux panes
- Opus-only findings caught issues no specialist found (unhandled Reload()
  at UI call sites, ConfigurationPoller test gap)

**How to apply:** `/pre-review` and `/review-pr` now route large diffs to
the teammate approach by default. The `code-review-team` subagent orchestrator
is still available but no longer the default path.
