---
name: Code review — teammates vs subagents comparison (2026-04-02)
description: Side-by-side test of agent teams (tmux panes) vs code-review-team orchestrator on payroll feat/reactive-config; teammates found more actionable bugs, subagents had sharper DI/lifecycle analysis
type: project
---

## Test setup (2026-04-02)

Branch: `feat/reactive-config` in `app-haven-payroll-jml-windows`
Scope: 57 files, +2981 / -880 lines

- **Subagents**: code-review-team orchestrator via Agent tool (in-process)
- **Teammates**: 7 reviewers in tmux panes (security, correctness, consistency, style, archaeology, reuse, efficiency)

## Results

| | Subagents | Teammates |
|---|---|---|
| Findings | 12 (2 important, 1 contested, 9 suggestions) | 19 (4 important, 15 suggestions) |
| Bake time | not recorded | ~36s |
| Visibility | none | all 7 panes visible |

## Key differences

**Unique to teammates** — WPF BrowseButton not saving path (genuine bug), corrupt
appsettings.json crash (user-facing), TempConfigurationService duplication, more
reuse findings (EscapeCsvField, LogProcessAndRunTime).

**Unique to subagents** — singleton-to-scoped lifecycle change, static _transId
asymmetry, ConfigurationPoller untested, contested JSON trailing comma regression
(more precisely argued).

**Overlap** — missing final newline, double reload, silent DataSeeder failure.

## Conclusion

Complementary rather than redundant. Teammates found more actionable bugs;
subagents had sharper analysis on lifecycle/DI changes. Teammates also provide
real-time visibility.

**How to apply:** For thorough reviews, consider running both approaches or
preferring teammates for the visibility benefit. The prompt to trigger teammates
must explicitly say "create a team of teammates" and NOT mention code-review-team
or /pre-review, otherwise Claude dispatches subagents instead.
