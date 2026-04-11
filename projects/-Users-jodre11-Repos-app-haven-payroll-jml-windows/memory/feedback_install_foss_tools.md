---
name: Install FOSS tools as needed
description: Install open-source CLI tools via Homebrew rather than building workarounds
type: feedback
originSessionId: 8b514b77-da20-4051-841f-ceb1e0f9150f
---
Install FOSS tools via Homebrew when needed rather than hacking around missing tools (e.g. Python venvs for image conversion).

**Why:** User prefers pragmatic tool installation over convoluted workarounds. Faster and cleaner.

**How to apply:** When a CLI tool (ImageMagick, icotool, etc.) would simplify a task, install it with `brew install <pkg>` and remind the user to regenerate their Brewfile.
