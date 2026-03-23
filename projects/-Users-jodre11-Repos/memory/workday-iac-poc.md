# Workday IaC PoC

## Goal
Bring IaC principles to Workday API client configuration: read config via API, store in source control, sync changes back via CI (GitHub Actions).

## Tenant Details
- **Sandbox GUI**: `https://impl.wd107.myworkday.com/havenleisureltd`
- **Sandbox SOAP endpoint**: `https://impl-services1.wd107.myworkday.com/ccx/service/havenleisureltd/Integrations/v45.2`
- **Production SOAP endpoint**: `https://services1.wd107.myworkday.com/ccx/service/havenleisureltd/Integrations/v45.2` (NOT tested — do not use without explicit intent)
- **Tenant name**: `havenleisureltd`
- Sandbox refreshes weekly from production (every weekend)
- Key: services host uses `impl-services1` prefix for sandbox, NOT `impl`

## ISU Setup (Sandbox)
- **Integration System User**: `ISU_IaC_PoC`
  - "Do Not Allow UI Sessions" enabled
  - Password set manually by user
- **Integration System Security Group (Unconstrained)**: `ISSG_IaC_PoC`
  - Member: `ISU_IaC_PoC`
- **Domain Security Policy Permissions** on `ISSG_IaC_PoC` — **all 4 active**:
  - Get and Put → Integration Build (Functional Area: Integration)
  - Get Only → Workday Query Language (Functional Area: System)
  - Get and Put → Integration Security (Functional Area: Integration)
  - Get and Put → Integration Configure (Functional Area: Integration)

## OAuth API Client (Sandbox)
- **Type**: API Client for Integrations (Authorization Code Grant)
- **Client ID**: `MGJiODZkMjMtYzU2NC00MzdjLWIxMzMtZjlmMjlhYThmMzQz`
- **Scopes**: System, Integration (Tenant Non-Configurable removed on 2026-03-05)
- **Include Workday Owned Scope**: No (changed from Yes on 2026-03-05)
- **Token endpoint**: `https://impl-services1.wd107.myworkday.com/ccx/oauth2/havenleisureltd/token`
- **Grant type**: refresh_token → access_token
- Credentials stored in dotnet user-secrets: `Workday:ClientId`, `Workday:ClientSecret`, `Workday:RefreshToken`
- Refresh token regenerated on 2026-03-05 with ISU_IaC_PoC explicitly linked

## PoC Validation (2026-03-05) — PASSED
- Successfully called `Get_Integration_Systems` — returned 51 integration systems
- Used raw SOAP/HttpClient (not WCF client) due to svcutil codegen bug with `RoleObjectType[]` in Workday WSDL
- Authentication: WS-Security UsernameToken with PasswordText over HTTPS
- Repo: `/Users/jodre11/Repos/workday-iac/WorkdayIaC.PoC/`

## Technical Notes
- `dotnet-svcutil` generates 28k line Reference.cs from Workday WSDL but the WCF client has serialization bugs
- Raw SOAP envelope + `HttpClient` + `XDocument` parsing is the reliable approach
- WSDL for a tenant available via: Public Web Services report → Related Actions → Web Service
- Password stored in .NET user secrets: `dotnet user-secrets set "Workday:Password" "..."`

## SOAP API Operations (Integrations Service)
- `Get_Integration_Systems` — read integration system config (services, attributes, maps, launch params)
- `Put_Integration_System` — create/update integration system config
- `Get_Integration_System_Users` / `Put_Integration_System_User` — manage ISU accounts

## REST API — BLOCKED (act.sub empty in JWT)
- All REST API calls return HTTP 403 (S22 permission denied) — not just WQL
- JWT `act.sub` claim is always `""` (empty string) despite ISU being linked
- `sub` claim contains `02eeda75cc001001a968bda130170000` (Christian Haddrell's human user WID)
- The empty `act.sub` means Workday can't identify which ISU is acting, so all REST access fails
- **Ruled out**: domain permissions (all active, SOAP works), scope changes, token regeneration, Include Workday Owned Scope toggle
- **Working comparison**: Inploi and Fabric API Clients for Integrations use REST successfully
- **Disproven**: ISU doesn't need an Integration System association — working ISUs don't have one either
- ISU_IaC_PoC does not appear in Workday global search (0 results) — possibly relevant
- Root cause unknown — need to compare ISU_IaC_PoC account properties with a working ISU
- Program.cs has debug output (JWT decoding lines 132-140, token response line 192) — remove when fixed

### REST API Limitations (general)
- OAuth Client (v1): read-only, limited to OCFR clients only
- WQL (v1): query language for reading data, no write capability
- No public API for Register_API_Client or Tenant_Management operations

## API Client Types to Manage
1. OAuth API Clients
2. API Clients for Integrations (initial priority)
3. Integration Systems

## Technology Decision (Pending)
- **Option A**: Terraform custom provider (Go) — aligns with existing infra, but Go SOAP ecosystem is dead
- **Option B**: Pulumi provider (C#) — open source, free with self-managed backend, native SOAP support
- **Option C**: Standalone C# CLI tool — simplest, declarative YAML/JSON config

## Next Steps
1. ~~Wait for security policy activation~~ Done — all 4 active
2. ~~Build C# PoC to call Get_Integration_Systems~~ Done — SOAP API is viable
3. ~~Add domain permissions for ISU mgmt, config, WQL~~ Done — all active
4. **Fix REST API / WQL** — resolve empty `act.sub` in JWT (see "REST API — BLOCKED" section above)
   - Next thing to try: compare ISU_IaC_PoC account properties with a working ISU (e.g. ISU_INT013_Indeed) via GUI
   - Consider recreating ISU + API Client from scratch following pattern of working clients
5. Test `users` subcommand (needs Integration Security domain)
6. Test `Put_Integration_System` to validate write capability
7. Remove debug output from Program.cs (lines 132-140, 192) when REST is fixed
8. Design full IaC solution
