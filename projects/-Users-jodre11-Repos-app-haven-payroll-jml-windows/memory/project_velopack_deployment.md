---
name: Velopack deployment strategy
description: Avalonia app distribution plan — self-contained single-file publish first, then Velopack for installers and auto-updates
type: project
originSessionId: 372872d5-4ec4-4803-9094-d05ae969a770
---
For the cross-platform Avalonia desktop app, **Velopack** is the chosen distribution and update
framework. It is free, MIT-licensed, and actively maintained — it replaced the now-deprecated
Squirrel.Windows.

**Why:** Velopack handles cross-platform installers (Windows, macOS, Linux) from a single
`dotnet publish` output, delta updates, silent background updates, no runtime dependency (works
with self-contained publishes), and simple C# integration.

**How to apply:** Two-phase approach:

1. **Phase 1 — self-contained single-file publish** (starting point):
   ```bash
   dotnet publish -c Release -r win-x64 --self-contained -p:PublishSingleFile=true
   ```
   Produces a single executable with all dependencies bundled. No installer, no .NET runtime
   required on the target machine — user extracts and runs the .exe.

2. **Phase 2 — Velopack wrapper** (when ready for installers + auto-updates):
   Wrap the same publish output with Velopack to get native installers and delta update
   infrastructure. No change to the build, just an additional packaging step.
