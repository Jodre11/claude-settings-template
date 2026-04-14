---
name: IT service desk ticket for PayrollJML deployment
description: ManageEngine ServiceDesk Plus ticket #403868 requesting deployment of PayrollJML to payroll team machines
type: reference
originSessionId: 675fc1f8-006f-447d-9b0a-b1f7938317bf
---
IT service desk ticket requesting deployment of the Payroll Workday Import File Generator to
payroll team machines (2–5 users).

- **Ticket:** #403868
- **URL:** https://bourneleisureltd.sdpondemand.manageengine.eu/app/itdesk/ui/requests/5132000158722784/details
- **Portal:** ManageEngine ServiceDesk Plus (Bourne Leisure LTD instance)
- **Template used:** Software Installation Request (under Hardware, software, network, printing)
- **Status:** Open (as of 2026-04-14)
- **Awaiting:** IT response on distribution mechanism (SCCM/Intune/other) and code signing requirements
- **Related GitHub issue:** HavenEngineering/integrations#744

## Release Information (updated 2026-04-14)

Releases are published as GitHub Releases at:
https://github.com/HavenEngineering/app-haven-payroll-jml-windows/releases

Each release contains three zip artefacts — one per platform:

| Platform | Artefact | Executable |
|---|---|---|
| Windows x64 | `PayrollJML-vX.Y.Z-win-x64.zip` | `PayrollWorkdayImportGenerator.Avalonia.exe` |
| macOS Intel x64 | `PayrollJML-vX.Y.Z-osx-x64.zip` | `PayrollWorkdayImportGenerator.Avalonia` |
| macOS Apple Silicon | `PayrollJML-vX.Y.Z-osx-arm64.zip` | `PayrollWorkdayImportGenerator.Avalonia` |

Each zip contains a single self-contained executable — no .NET runtime installation required,
no installer, no admin rights needed. Extract and run.

Latest release: **v0.0.4** (2026-04-14) — tested and verified on macOS (Apple Silicon) and Windows x64.

Deployment guide: `docs/deployment-guide.md` in the repo.
