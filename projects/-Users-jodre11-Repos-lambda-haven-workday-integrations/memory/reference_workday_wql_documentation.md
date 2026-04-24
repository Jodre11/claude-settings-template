---
name: Workday WQL Documentation Reference
description: Official WQL syntax, REST API endpoints, security model, pagination, field discovery, and known limitations from Workday admin docs (behind auth)
type: reference
originSessionId: 600d8b8d-a9d5-4ab7-936a-e343e6ded197
---
Source: https://doc.workday.com/admin-guide/en-us/reporting-and-analytics/custom-reports-and-analytics/workday-query-language-wql-/ (requires Workday Community auth)

## Security Model

- Requires **Workday Query Language** domain in the **System** functional area
- OAuth API client must have **System** scope selected
- "You can only view and use data sources and fields that you have security access to within a WQL query"
- Dual-layer: OAuth functional area scopes AND ISU/ISSG domain security policies must both permit access
- **S22 error** (403 "permission denied") = missing scope or domain security grant
- **Important**: changing API client scopes or "Include Workday Owned Scope" requires generating a NEW refresh token — existing tokens retain old scopes

## REST API Endpoints

Base URL: `https://{hostname}/api/wql/{version}/{tenant}` (or `https://api.workday.com/wql/{version}` for WCP)

| Endpoint | Purpose |
|---|---|
| `GET /data?query={wql}` | Execute WQL (queries <2048 chars) |
| `POST /data` | Execute WQL (queries 2048-16000 chars), body: `{"query":"..."}` |
| `GET /dataSources` | List all data sources with WQL aliases |
| `GET /dataSources/{ID}` | Data source details (alias, parameters, effective/entry date support) |
| `GET /dataSources/{ID}/fields` | List all fields with aliases and related business objects |
| `GET /dataSources/{ID}/dataSourceFilters` | List data source filters |

Use `?alias=xxx` to filter dataSources by alias. Use `?SourceIndexType=Indexed` for indexed sources only.

## WQL Syntax Reference

### Clauses (in order)
`PARAMETERS` → `SELECT` → `FROM` → `WHERE ON` → `WHERE` → `GROUP BY` → `HAVING` → `ORDER BY` → `LIMIT`

### SELECT
- `SELECT field1 AS alias, function(field2), field1{rboField1} FROM dataSource`
- `SELECT *` NOT supported
- Aggregation: `AVG()`, `COUNT()`, `COUNT(DISTINCT)`, `MAX()`, `MIN()`, `SUM()`
- RBO fields: `dependents{legalName_FirstName, age}` — curly bracket notation
- Example: `SELECT worker, fullName, location FROM allWorkers`

### FROM
- `FROM dataSourceAlias`
- `FROM dataSourceAlias(effectiveAsOfDate="2018-01-01", entryMoment="2019-01-01 12:30:00Z")`
- `FROM dataSourceAlias(dataSourceFilter=filterAlias, prompt1=value1)`
- **effectiveAsOfDate/effectiveAsOfMoment**: point-in-time snapshot of effective-dated data
- **entryDate/entryMoment**: filter by entry date (when data was entered into Workday)
- These are FROM parameters, NOT WHERE fields
- **No `lastModified` field exists** — use `entryMoment` for incremental queries or SOAP Transaction Log

### WHERE
- `WHERE field1 = value1 AND field2 IN (instance1, instance2)`
- Operators: `=`, `>`, `>=`, `<`, `<=`, `!=`, `contains`, `not contains`, `startswith`, `endswith`, `in`, `not in`, `is empty`, `is not empty`
- Dates: `YYYY-MM-DD`, Datetimes: `YYYY-MM-DD HH:MM:SSZ` (UTC) or `YYYY-MM-DD HH:MM:SS` (PST)
- Instance matching: `field IN (Workday_ID)` or `field IN (ref_id_type = ref_id_value)`
- WHERE ON clauses must precede WHERE clauses

### Related Business Objects (RBO)
- Access via `{}` notation: `SELECT dependents{age} FROM allWorkers`
- Limit: 500 values per multi-instance RBO field
- Cannot use in GROUP BY or outside SELECT/WHERE ON
- URL-encode `{}` when using third-party clients

### PARAMETERS
- `PARAMETERS param1 = value1, param2 = value2 SELECT ... FROM ...`
- For data source prompts, report field prompts, and data source filter prompts

## Pagination & Limits

- Max 1M rows total per query (fails if >1M without LIMIT clause)
- 10,000 rows per page
- `?limit=1000&offset=0` on GET requests
- Cache: 30 minutes, clear with `offset=0`
- Timeout: 30 min (tenanted host), 5 min (WCP Gateway)

## Known Valid Data Sources and Fields

From official examples:
- `allWorkers`: `worker`, `fullName`, `firstName`, `location`, `yearsOfService`
- `allActiveEmployees`: referenced in Visier docs — active employees only (excludes contingent/terminated/future)
- Field aliases are discovered via `GET /dataSources/{ID}/fields`

## Key Gotchas

1. `provisioningGroup` is NOT a standard WQL field — provisioning data is only accessible via SOAP `Get_Workers` or `Get_Provisioning_Group_Assignments`
2. `lastModified` is NOT a valid WQL filter — use `entryMoment` in FROM clause instead
3. `fullName` IS a valid field (confirmed in official SELECT example)
4. WQL returns 403 for invalid field names, not a helpful error message
5. Refresh tokens must be regenerated after changing API client scopes
6. "Include Workday Owned Scope" must be Yes for WQL access
7. `Convert Report to WQL` task in Workday GUI generates valid WQL from existing reports — useful for discovering correct field aliases
8. **GET works, POST may not** — confirmed 2026-04-23 that `GET /data?query=...` returns 200 while `POST /data` returns 403 S22 with the same query and token. POST may require View and Modify (not just View Only) on the Workday Query Language domain. Use GET for queries under 2,048 characters.
9. WQL ISU setup requires **Workday Query Language** domain plus potentially **Manage: All Custom Reports** and **Custom Report Administration** domains in the System functional area (from Workday docs AI-generated answer — official docs only explicitly require WQL domain)
