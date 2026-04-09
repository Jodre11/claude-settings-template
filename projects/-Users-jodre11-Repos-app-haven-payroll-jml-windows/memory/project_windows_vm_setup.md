---
name: Windows VM terminal colours
description: Windows Terminal Monokai Remastered scheme needs updating to match Ghostty's actual theme values from /Applications/Ghostty.app
type: project
---

Windows VM (VMware Fusion, Win11 ARM64, WSL1 Ubuntu 24.04) terminal colour scheme needs fixing.

The initial Monokai Remastered colours applied to Windows Terminal were wrong (generic Monokai, greenish background #272822). The correct values are from Ghostty's theme file at `/Applications/Ghostty.app/Contents/Resources/ghostty/themes/Monokai Remastered` — background should be `#0C0C0C` (near-black), and all palette colours differ from the generic version.

**Why:** User wants the Windows VM terminal to match their macOS Ghostty setup.

**How to apply:** Replace the Windows Terminal colour scheme JSON with the correct values extracted from the Ghostty theme file. User will come back to this after the main setup is complete.
