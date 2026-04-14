---
name: Avalonia E2E Testing
description: Avalonia headless E2E tests and Appium smoke tests — PR #17 merged
type: project
originSessionId: 8b514b77-da20-4051-841f-ceb1e0f9150f
---
## Status (2026-04-13)

- **PR #17** merged (2026-04-10)
- **Tests:** 87 headless Avalonia tests + 3 Appium smoke tests, all passing on macOS and Windows CI
- **Coverage gate:** 80% line coverage, enforced in CI

## What Was Built

Two-tier E2E testing for the Avalonia cross-platform GUI:

### Tier 1: Headless Tests (87 tests)
- Project: `PayrollWorkdayGenerateImportFile.Avalonia.Tests`
- Avalonia.Headless with `HeadlessUnitTestSession` (PerAssembly isolation, dedicated dispatcher thread)
- Covers: DefaultValues, Admin, PayRatesCrud, TaxCodesCrud, PayRatesImportExport, TaxCodesImportExport, Reprocess, Browse, GenerateValidation, Employees, ViewLocator, ImportOptionsDialog, MainWindowStartup, and more
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
- `HeadlessUnitTestSession` creates a dedicated dispatcher thread with `ManagedDispatcherImpl` that enforces thread affinity — all UI control access must be marshalled via `DispatchOnUiThread()`
- `await Task.Delay` deadlocks in Avalonia headless tests — posts continuation to Avalonia SynchronizationContext, but the test thread IS the only dispatcher pump. Use `Thread.Sleep` + `Dispatcher.UIThread.RunJobs()` instead.
- `WaitUntil(Func<bool>)` helper in `AvaloniaTestBase` — pumps dispatcher in a loop with `Thread.Sleep(50)`, using `DialogService.Calls.Count > 0` as completion signal for async void handlers.

## Why
- Avalonia code-behind had zero test coverage with significant business logic
- Cross-platform assurance needed for macOS + Windows
