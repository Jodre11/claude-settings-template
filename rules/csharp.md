---
paths:
  - "**/*.{cs,csproj,props,targets,sln,slnx}"
---

# C#

- Doc comments: the C# form of the global comment policy is a one-line `/// <summary>` on public APIs.
- Logging: source-generated `[LoggerMessage]`, never string interpolation.
- JSON: System.Text.Json with source-generated serialisation (AOT-compatible).
- Tests: Verify.XunitV3 for snapshots; WireMock.Net for HTTP mocking.
- After editing C# files, run JetBrains InspectCode and fix every `<Issue>` in the XML before finishing:
  `jb inspectcode <solution> --output=${CLAUDE_TEMP_DIR}/inspectcode-output.xml --format=Xml --severity=WARNING`
