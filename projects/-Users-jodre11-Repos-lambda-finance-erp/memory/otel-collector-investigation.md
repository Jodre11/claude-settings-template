# OTLP Collector Investigation — PR #93

## PR

- PR #93: `feat/otel-datadog-collector` on `lambda-finance-erp`
- URL: https://github.com/HavenEngineering/lambda-finance-erp/pull/93
- Branch: `feat/otel-datadog-collector`
- CI is green. All 178 tests pass.

## Current status (2026-02-27)

### All three OTLP signals CONFIRMED WORKING in Datadog

**Traces** — Full distributed traces in Datadog APM
- Spans: `timer.invoke`, `HandleAsync`, HTTP client spans for ERPx/Coupa/SSM
- Custom tags: `projectcodesync.companies_processed`, `total_accounts_upserted`, etc.
- Source: `apm`, language: `dotnet`, SDK: `opentelemetry 1.15.0`

**Structured OTLP logs** — Tagged `source:otlp_log_ingestion`
- Structured attributes preserved (`CompanyId`, `Duration`, `Synced`, `Total`, etc.)
- Trace correlation via `otel.trace_id` and `otel.span_id`

**Metrics** — `http.client.request.duration` in Datadog
- Broken down by `http.request.method` and `server.address`
- ERPx GET (~122ms), Coupa GET (~533ms), Coupa PUT (~580ms), SSM POST (~273ms)
- `otel.datadog_exporter.metrics.running` confirms exporter is active

### SHUTDOWN forwarder errors are COSMETIC
- "Too many errors for endpoint" and "context deadline exceeded" at SHUTDOWN are from DD
  metadata/host reporting (API key validation, host metadata, usage metrics) only
- NOT from OTLP data export — OTLP metrics use synchronous `PushMetricsData` (Path A,
  feature gate OFF), not the DD Agent `DefaultForwarder`
- `disablequeuedretryconverter` sets `sending_queue::enabled = false` for the DD exporter,
  making `PushMetricsData` run synchronously inline with batch processor flush

### False alarm: "metrics not working"
- Was querying wrong metric names (`runtime.dotnet.gc.count.gen0`, `process.runtime.dotnet.gc.collections.count`)
- Correct .NET OTLP metrics use `http.client.request.duration` (from `System.Net.Http`)

## Collector version history

### v0.3.1 (current, otel-datadog-collector PR #9, merged)
- Fixed init-timeout detection: moved from `Run()` to first INVOKE handler in `processEvents()`
  - `Run()` check was dead code — `collector.Start()` returns at ~6s (below 9s threshold),
    before Lambda freezes at 10s
  - First INVOKE (post-thaw) correctly measures elapsed time including freeze duration
- Fixed version ldflags: `-X main.Version=${VERSION}` in Dockerfile, `--build-arg VERSION`
  in build-and-release.yml
- Binary now reports `"version":"v0.3.1"` in logs

### v0.3.0
- Parallelised Secrets Manager resolution (~500ms savings)
- Init-timeout detection (broken — check in wrong place, see v0.3.1)

### v0.2.1
- `collector.yaml`: `timeout: 200ms`, `send_batch_size: 1` (was 5s/256)
- Ensures batch processor flushes within Lambda's post-runtime window (~300ms)

## lambda-finance-erp commits on PR #93

- `e38eed7` — LoggerProvider flush: moved logging to `.WithLogging()`, added `ForceFlush()`
- `500c649` — Bumped collector to v0.2.1
- `7bc967e` — Bumped collector to v0.2.0 (APM stats via Datadog connector)
- Latest — Bumped collector to v0.3.1

## API gotchas

`.WithLogging()` takes two callbacks: `Action<LoggerProviderBuilder>` for exporter config, and
`Action<OpenTelemetryLoggerOptions>` for `IncludeFormattedMessage`/`IncludeScopes`. These properties
do NOT exist on `LoggerProviderBuilder`.

## Environment details

| Account | ID | Profile | Purpose |
|---------|-----|---------|---------|
| finance-dev | 815359208046 | haven-dev | Development — test here |
| finance-staging | 471112640844 | (not used) | Staging — ignore for now |
| tooling | 745662293263 | — | ECR registry |

- Dev Lambda function name: `finance-aot-project-code-sync`
- Collector version: `otel-datadog-collector:v0.3.1` (datadogexporter v0.145.0)
- Collector config: `/opt/collector-config/config.yaml` (`collector.yaml` in otel-datadog-collector repo)

### CI/CD notes
- `build-and-publish-image.yml` builds and deploys pre-release images to dev on push to PR branches
- Image tags use `sha-${GITHUB_SHA::12}` — for PR pushes, `GITHUB_SHA` is GitHub's ephemeral merge commit
- Dev profile (`haven-dev`) does NOT have `lambda:UpdateFunctionCode` — must deploy via CI

## Remaining observations
- Datadog traces show `env:none` — may need `OTEL_RESOURCE_ATTRIBUTES=deployment.environment=dev`
  or `DD_ENV=dev` in Lambda env vars (Terraform)
- Cold start: Lambda restarts the extension process entirely after init timeout (not freeze/thaw),
  giving a clean start — the `firstInvoke` restart logic was not triggered in testing
