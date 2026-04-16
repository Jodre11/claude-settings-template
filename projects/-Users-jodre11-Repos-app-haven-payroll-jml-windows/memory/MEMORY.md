# Haven Payroll JML Windows - Project Memory

## Current State (2026-04-14)
- **Latest release:** v0.0.4 — tested on macOS (ARM64) and Windows x64
- **All PRs merged**, no open issues, no open PRs
- **Branch protection:** enabled on `main` (enforcement: everyone) with merge queue
- **CI:** passing on `main`
- **Release workflow:** `.github/workflows/release.yml`, `workflow_dispatch`, input `bump-level` (patch/minor/major)

## Project Skills
- `.claude/commands/jbinspect.md` — runs `jb inspectcode`, parses XML, presents findings, offers to fix
- Also at `.claude/skills/jbinspect.md` (duplicate — commands/ is the correct location for slash commands)
- `/jbinspect` skill confirmed working after session restart

## Identified Tech Debt
- **InspectCode issues** — resolved to zero in PR #19
- **Source-generated logging** — CA1848, CA1873, CA2254 addressed in PR #19 (warning suppressions removed, IsEnabled guards + local variables added)
- **Simplify review** — completed in PR #19: ColumnNames constants (78 fields, 13 service files), DataLineDefinitions cached as static readonly fields, [RelayCommand] source gen, DI scope dedup, TOCTOU removal, TextBox bounding, HashSet for validEmployeeIds
- **Avalonia test coverage** — 87 headless tests, 80% line coverage gate passing

## Project Structure
- `payroll-workday-generate-import-file/` — Core library + console app (net10.0)
- `PayrollWorkdayGenerateImportFile.Avalonia/` — Cross-platform GUI (net10.0)
- `PayrollWorkdayGenerateImportFile.Tests/` — xUnit v3 test project (693 tests)
- `PayrollWorkdayGenerateImportFile.Avalonia.Tests/` — Avalonia headless E2E tests (87 tests)
- `PayrollWorkdayGenerateImportFile.Appium.Tests/` — Appium smoke tests (3, CI-excluded)

## Key Technical Facts
- Avalonia 11.3.12, Fluent theme, DataGrid via Avalonia.Controls.DataGrid
- `MsgIcon` type alias for `MsBox.Avalonia.Enums.Icon` vs `Avalonia.Controls.WindowIcon` conflict
- `StorageProvider` API for file/folder pickers; `Dispatcher.UIThread.InvokeAsync()` for UI thread
- NLog config: `NLog.avalonia.config` with `AvaloniaTextBoxTarget`
- NLog `internalLogFile` must use built-in renderers only (e.g. `${tempdir}`), not custom `${dataroot}`
- CI runs SDK 10.0.201 (rollForward: latestFeature from pinned 10.0.100)
- `WorkingDirectoryTests` collection eliminated — tests now use explicit paths via `IDataRootProvider` for full parallelism
- .NET 10 requires Visual Studio 2026 v18.0+ (NOT VS2022 17.x)
- Self-contained publish: `IncludeAllContentForSelfExtract=true` + `DebugType=embedded` in Directory.Build.props
- `Host.CreateDefaultBuilder` calls `GetCwd()` internally — must `SetCurrentDirectory` before calling it on macOS

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

## Security
- [PII in user data directory](project_pii_in_user_data.md) — ~/.jml-payroll contains employee PII; never claim app stores no sensitive data

## References
- [IT service desk ticket #403868](reference_it_service_desk_ticket.md) — PayrollJML deployment, release info, awaiting IT response
- [Enterprise Integrations board](reference_enterprise_integrations_board.md) — project #135, deep-link URL format for issues

## Active Initiatives
- [Avalonia E2E Testing](project_avalonia_e2e_testing.md) — PR #17 merged 2026-04-10, 87 headless + 3 Appium tests
- [Velopack deployment strategy](project_velopack_deployment.md) — self-contained single-file first, then Velopack for installers + auto-updates
- [Disable merge queue](project_disable_merge_queue.md) — keep required checks, remove queue; change in platform-github Terraform

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
- [TransId static is intentional](feedback_transid_static.md) — _transId is deliberately static; real bugs are double-increment and redundant LoadReferenceData
- [Issue content inline](feedback_issue_content_inline.md) — put full spec content on the issue body, don't link to a repo file
