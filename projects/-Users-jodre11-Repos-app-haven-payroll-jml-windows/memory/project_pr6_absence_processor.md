---
name: PR #6 Absence Processor Merged
description: Absence processor feature merged to main on 2026-03-26 — new services, WPF tab, txTime fixes across all processors, CSV escaping helper
type: project
---

PR #6 (`feat/add-absence-processor`) merged to main on 2026-03-26 by marlongillwork.

**Key additions:**
- `AbsenceProcessorService` / `AbsenceReasonService` with interfaces
- `AbsenceReasonRow` model (INotifyPropertyChanged)
- `EscapeCSVText.cs` helper (partial class on `Helpers`)
- `AbsenceReasons.csv` seed data (6 UK absence types)
- WPF "Absence Reasons" management tab (add/delete/edit/import/export)
- `DataLineDefinitions`: Absence/101 line definition
- `ImportGeneratorFactory`: "Absence" file type routing
- DI registration in `Program.cs` and `App.xaml.cs`
- 70+ new tests across 3 test files
- `ImportReference.txt` bumped from 15062 to 16000

**Bug fixes included in PR #6 (affect all processor services):**
- txTime format: `HHmm` changed to `HH:mm` with single `DateTime.Now` capture — touched all 6 existing processor services
- `LeaverProcessorService.GetSourceData()`: sort column corrected to `"Employee ID"`
- `StarterProcessorService.CreateImportFile()`: zip filename pattern matching modernised

**Known residual issues (reviewed, approved with comments):**
- Dead `Errors` filter in `AbsenceProcessorService.CreateImportFile:363` — `.Contains("unmapped absence type encountered")` doesn't match because `ProcessInputData` overwrites `Errors` with a different string. Rows still excluded by `ExportRecord` check, so no data corruption.
- `EscapeCsvText` only quotes on comma — fields with embedded `"` but no comma produce malformed CSV.

**Why:** This context is needed when rebasing `code/cross-platform-ui` onto main — expect conflicts in ImportGeneratorFactory, ImportGeneratorService, MainWindow, App.xaml.cs, Program.cs, DataLineDefinitions, .gitignore, .csproj, and all 6 processor services.

**How to apply:** During rebase, accept the new absence processor additions from main and re-apply the cross-platform (Avalonia) changes on top. The Avalonia branch does not have an absence processor equivalent yet — that will need adding post-rebase.
