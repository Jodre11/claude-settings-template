# ERPx PATCH API — Discovered Behaviour

## Summary

ERPx `PATCH /v1/projects/{id}` requires **RFC 6902 JSON Patch** with strict rules discovered through E2E testing.

## Requirements

1. **Content-Type**: Must be `application/json-patch+json` — rejects `application/json` (4025) and `application/json; charset=utf-8` (4025)
2. **Body format**: RFC 6902 array of `{ "op": "replace", "path": "/fieldName", "value": "..." }` — rejects plain JSON object (1010)
3. **Per-field paths**: Each field needs its own operation — `"/"` root path returns 422 with project body
4. **Only patchable fields**: `dateFrom`, `dateTo` rejected with 4020. Safe fields: `projectName`, `status`, `projectManagerId`, `costCentre`, `customFieldGroups/{group}/{field}`
5. **422 = success**: Both POST and PATCH return 422 with the full project object as body on success. Detect via `"projectId"` in body. Real errors have `"code"` + `"message"`.
6. **Exclude 422 from Polly retries** — not transient

## POST quirks

- `POST /v1/projects` silently ignores `customFieldGroups` — need follow-up PATCH
- Use `Content-Type: application/json` (strip charset suffix)
- Also returns 422 with project body on success

## Implementation

- `JsonPatchBuilder.cs` — converts `ErpxProjectPayload` → `List<JsonPatchOperation>`
- `JsonPatchOperation.cs` — RFC 6902 model with `JsonElement` value (AOT-compatible)
- `ErpxJsonSerializerContext` — registered `List<JsonPatchOperation>` and `string`
- `HandleResponseAsync` — treats 422 with `"projectId"` in body as success
- `ConfigureResilience` — 422 excluded from Polly retries alongside 401/404

## Full documentation

See `docs/erpx-patch-api-quirks.md` in the repo.
