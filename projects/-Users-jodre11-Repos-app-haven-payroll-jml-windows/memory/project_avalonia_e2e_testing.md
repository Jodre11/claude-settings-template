---
name: Avalonia E2E Testing
description: In-progress E2E testing initiative for Avalonia GUI — design spec done, implementation plan pending
type: project
---

## Status (2026-04-04)

- **Branch:** `feat/avalonia-e2e-testing` at `3f85b00`
- **Appium smoke tests:** IMPLEMENTED — 3 tests (app launch, admin update, file generation)
- **Appium tests skip gracefully** when Appium server unavailable (`IsAvailable` flag in `AppFixture`)
- **CI:** Appium tests excluded from GH-hosted runners via `--filter "Category!=Appium"`
- **Blocker:** macOS Automation Mode is disabled — `mac2` driver crashes without it
  - `automationmodetool enable-automationmode` fails silently or requires reboot/SIP config
  - Also need Ghostty in System Settings → Privacy & Security → Accessibility
  - Once resolved, tests should pass: publish works, Appium server responds, `mac2` driver installed

## What We're Building

Two-tier E2E testing for the Avalonia cross-platform GUI:

### Tier 1: Headless Tests (high priority)
- Project: `PayrollWorkdayGenerateImportFile.Avalonia.Tests`
- Avalonia.Headless (base package, NOT `Avalonia.Headless.XUnit` — incompatible with xUnit v3 on 11.3.x)
- Manual headless bootstrap with custom `IAsyncLifetime` base class
- Target: >=80% line coverage of all Avalonia code-behind (~1920 lines in MainWindow.axaml.cs)
- ~65-80 tests across 13 test classes
- Runs on GH-hosted macOS + Windows runners (existing CI jobs)

### Tier 2: Appium Smoke Tests (lower priority)
- Project: `PayrollWorkdayGenerateImportFile.Appium.Tests`
- 3 tests: app launch, admin tab update employees, file generation
- Requires self-hosted runners (WinAppDriver + mac2 driver)
- CI integration deferred — tests written but not wired into workflow

### DI Refactor (prerequisite)
- New interfaces: `IDialogService`, `IStorageService` in `PayrollWorkdayGenerateImportFile.Avalonia/Services/`
- Production implementations: `DialogService`, `StorageService`
- Test doubles: `FakeDialogService`, `FakeStorageService`
- MainWindow constructor gains two new parameters
- All direct `MessageBoxManager`, `StorageProvider`, `ImportOptionsDialog` calls replaced

## Key Design Decisions
- xUnit v3 3.2.2 (matching existing test project)
- Non-parallel test collection (Avalonia single UI thread constraint)
- Isolated temp data root per test via `DataRootProvider(["--data-root", tempDir])` + `DataSeeder`
- Appium file picker bypass: pre-configure appsettings.json with paths
- AutomationProperties.AutomationId on key AXAML controls
- Appium tests filtered via `[Trait("Category", "Appium")]` and `--filter "Category!=Appium"` in CI
- Both new test projects added to both solution files

## Why
- Avalonia code-behind has zero test coverage and contains significant business logic
- Most complex/risky code: admin employee update (~170-line lambda), file generation orchestration
- Cross-platform assurance needed — whoever is developing should have confidence on both platforms

## How to Apply
- Appium tests are implemented but blocked on macOS Automation Mode — resolve permissions before running
- Tier 1 headless tests are still pending (the main coverage effort)
- The spec at `docs/superpowers/specs/2026-04-02-avalonia-e2e-testing-design.md` is the source of truth for design decisions
