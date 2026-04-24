---
name: Try features before dismissing them
description: Don't assume a language feature won't work — try it and let the compiler decide
type: feedback
originSessionId: 2bdca696-e9f1-46f3-a928-13f5199b13de
---
Don't assume a language feature requires preview or won't compile. Try it first and let the
build tell you.

**Why:** Dismissed C# 14 extension blocks as "preview only" without trying. User challenged
this — the feature compiled and worked on .NET 10 GA without any LangVersion override.

**How to apply:** When InspectCode or an analyser suggests a newer language feature, attempt the
conversion and build. If it fails, revert. Don't speculate about availability.
