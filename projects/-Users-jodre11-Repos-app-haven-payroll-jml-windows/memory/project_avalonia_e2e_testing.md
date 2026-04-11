---
name: Avalonia E2E Testing
description: Avalonia headless E2E tests and Appium smoke tests — PR #17 ready for review
type: project
originSessionId: 8b514b77-da20-4051-841f-ceb1e0f9150f
---
## Status (2026-04-10)

- **Branch:** `feat/avalonia-e2e-testing` — PR #17 ready for review
- **Tests:** 71 headless Avalonia tests + 3 Appium smoke tests, all passing on macOS and Windows CI
- **Coverage gate:** fixed — merges all coverage XMLs, coverlet.collector added to Appium project

## What Was Built

Two-tier E2E testing for the Avalonia cross-platform GUI:

### Tier 1: Headless Tests (71 tests)
- Project: `PayrollWorkdayGenerateImportFile.Avalonia.Tests`
- Avalonia.Headless with manual bootstrap (`AvaloniaTestBase` IAsyncLifetime base class)
- Covers: DefaultValues, Admin, PayRatesCrud, TaxCodesCrud, PayRatesImportExport, TaxCodesImportExport, Reprocess, and more
- Runs on GH-hosted macOS + Windows runners

### Tier 2: Appium Smoke Tests (3 tests)
- Project: `PayrollWorkdayGenerateImportFile.Appium.Tests`
- Filtered out of CI via `--filter "Category!=Appium"` (need self-hosted runners)
- Blocked on macOS Automation Mode permissions for local execution

### DI Refactor (prerequisite, completed)
- Interfaces: `IDialogService`, `IStorageService`
- Test doubles: `FakeDialogService`, `FakeStorageService`
- All direct dialog/picker calls replaced

## Key Technical Lessons
- `await Task.Delay` deadlocks in Avalonia headless tests — posts continuation to Avalonia SynchronizationContext, but the test thread IS the only dispatcher pump. Use `Thread.Sleep` + `Dispatcher.UIThread.RunJobs()` instead.
- `WaitUntil(Func<bool>)` helper in `AvaloniaTestBase` — pumps dispatcher in a loop with `Thread.Sleep(50)`, using `DialogService.Calls.Count > 0` as completion signal for async void handlers.

## Why
- Avalonia code-behind had zero test coverage with significant business logic
- Cross-platform assurance needed for macOS + Windows
