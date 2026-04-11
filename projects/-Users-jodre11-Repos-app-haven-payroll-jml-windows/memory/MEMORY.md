# Haven Payroll JML Windows - Project Memory

## Current State (2026-04-10)
- **PR #17** — Avalonia E2E testing — **merged** (2026-04-10)
- **PR #5** — cross-platform Avalonia UI — **merged**
- **PR #6** — absence processor — **merged** (2026-03-26)
- **PR #15** — externalise config and reference data — **merged**
- **Branch protection:** enabled on `main` (enforcement: everyone)
- **CI:** passing on `main`

## Project Skills
- `.claude/commands/jbinspect.md` — runs `jb inspectcode`, parses XML, presents findings, offers to fix
- Also at `.claude/skills/jbinspect.md` (duplicate — commands/ is the correct location for slash commands)
- `/jbinspect` skill confirmed working after session restart

## Identified Tech Debt
- **InspectCode 68 issues** — pre-existing across all projects; needs follow-up PR to fix (naming, nullability, redundant usings, namespace mismatches)
- **Source-generated logging** — CA1848, CA1873, CA2254 all deferred to suggestion; significant perf win when addressed
- **Avalonia test coverage** — being addressed by E2E testing initiative (see below)

## Project Structure
- `payroll-workday-generate-import-file/` — Core library + console app (net10.0)
- `PayrollWorkdayGenerateImportFile.WPF/` — Windows-only GUI (net10.0-windows)
- `PayrollWorkdayGenerateImportFile.Avalonia/` — Cross-platform GUI (net10.0)
- `PayrollWorkdayGenerateImportFile.Tests/` — xUnit v3 test project (693 tests)

## Key Technical Facts
- Avalonia 11.3.12, Fluent theme, DataGrid via Avalonia.Controls.DataGrid
- `MsgIcon` type alias for `MsBox.Avalonia.Enums.Icon` vs `Avalonia.Controls.WindowIcon` conflict
- `StorageProvider` API for file/folder pickers; `Dispatcher.UIThread.InvokeAsync()` for UI thread
- NLog config: `NLog.avalonia.config` with `AvaloniaTextBoxTarget`
- CI runs SDK 10.0.201 (rollForward: latestFeature from pinned 10.0.100)
- `WorkingDirectoryTests` collection eliminated — tests now use explicit paths via `IDataRootProvider` for full parallelism

## User Preferences
- Prefers being asked before large actions
- Experienced engineer — be terse
- Favours free OSS packages
- Wants CI to enforce quality gates
- .NET 10 target framework
- Training data can be outdated — validate via web

## Terminal & Dev Environment
- Ghostty terminal (migrated from iTerm2) — see `terminal-migration.md`
- Hammerspoon voice-to-text: whisper-cpp + sox, Karabiner (PrintScreen → F19/F20)
  - Updated to instant paste with clipboard restore
- Shell: zsh + OMZ + Starship (migrated from p10k 2026-03-25)
  - Starship config: `~/.config/starship.toml`
  - OMZ plugins: git, autosuggestions, syntax-highlighting, z, history-substring-search, aws, web-search, extract, sudo, colored-man-pages, dotnet, terraform
- tmux wrapper for Claude Code sessions (claude() function in .zshrc)

## PR #6 Context
- [PR #6 absence processor details](project_pr6_absence_processor.md) — merged 2026-03-26, key context for rebase conflicts

## Active Initiatives
- [Avalonia E2E Testing](project_avalonia_e2e_testing.md) — PR #17 merged 2026-04-10, 71 headless + 3 Appium tests

## Research
- [Personal AI Agent Costs](research_personal_ai_agent_costs.md) — OpenClaw/NanoClaw + Opus 4.6 cost analysis, model routing strategies, subscription vs API comparison

## Windows VM Setup
- [Terminal colours TODO](project_windows_vm_setup.md) — Windows Terminal Monokai Remastered scheme needs correcting to match Ghostty

## Conventions
- [Temp directory convention](feedback_temp_directory.md) — use /tmp/claude-{session_name}/, never bare /tmp/ or $TMPDIR
- [Re-review scope rules](feedback_re_review_scope.md) — re-reviews: only our unfixed bugs + new bugs from fix commits; approve if non-blocking
- [Reviewer assignment](feedback_reviewer_assignment.md) — never add PR reviewers unless explicitly asked
- [SSH signing via Bitwarden](feedback_ssh_signing.md) — ssh-add -l won't show the signing key; just commit, it works
- [Install FOSS tools](feedback_install_foss_tools.md) — use brew install rather than workarounds; remind to regenerate Brewfile
