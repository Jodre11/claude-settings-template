# Plan Amendments (apply to distributed-purring-widget.md during implementation)

Full details in `~/.claude/plans/happy-snacking-flamingo.md`.

## Phase 0 — expand to 5 production fixes
1. 3x logger type bugs (already in plan)
2. Gender bug: `PersonalInformationProcessorService.cs:79` — remove `'` prefix from SafeLeft
3. Static list mutation: `CompensationProcessorService.CreateImportRecord` — copy list before `.Add()`
4. JB InspectCode sweep: fix ALL warnings across entire solution
5. All production code changes itemised in PR for developer sign-off

## Phase 3c — FakeConfigurationService
- Signature: `T GetDefault<T>(string key, T defaultValue = default!)` (two params)
- Must also implement: `TryGetDefault<T>(string key, out T value)`, `LoggerType` property

## Phase 4 — processor tests
- `RemoveExtraneousData` is public — test directly
- V1 `PositionCodeAndServiceConditions`: exact `== "Annualised"` vs V2 `Contains("annualised")`
- `FilterSourceDataByEmployeeIds` is private — test through `ImportData`

## Phase 5a — EmployeeService
- Constructor needs `IConfigurationService` (missing from plan)
- `ProcessLeaver` returns `(true, "")` when employee not found — test this

## Phase 5b — PayRatesService
- DELETE `ImportPayRates` and `ExportPayRates` — don't exist
- Actual API: `LoadPayRates()` returns `ObservableCollection<PayRateRow>`, `SavePayRates(ObservableCollection<PayRateRow>)`, `GetPayRateCode(decimal, string, DateTime, DateTime)` returns `(string?, string)`

## Phase 5c — TaxCodeService
- `LoadTaxCodes()` returns void; `LoadTaxCodesAsCollection()` returns collection
- `SaveTaxCodes` takes `ObservableCollection<TaxCodeRow>`
- Lookup via `ToUpperInvariant()` on tuple key

## Phase 6 — ImportGeneratorFactory
- `CallProcessorService` calls `LoadReferenceData()` first — must mock filesystem reads
- Filename validation: 3 parts, dd-mm-yyyy date, 4-char time

## Targets
- Coverage: >80% (was 60%+)
- JB InspectCode: zero warnings across entire solution
