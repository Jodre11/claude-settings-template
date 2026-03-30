---
name: Middle-click cross-clipboard paste fix
description: Clipboard bridging between Ghostty and tmux — tmux-yank script writes to both macOS pasteboard and Ghostty selection clipboard via OSC 52
type: project
---

Middle-click in Ghostty reads from the `selection` clipboard (`ghosttySelection` NSPasteboard). The `copy-on-select` default (`true`) writes native selections there. To update it programmatically, use OSC 52 with target `s` (selection) — **not `p` (primary)**, which Ghostty's macOS C bridge silently drops (no `GHOSTTY_CLIPBOARD_PRIMARY` in `ghostty_clipboard_e`).

## Solution (applied 2026-03-30)

1. **`tmux-yank` script** (`tmux/.local/bin/tmux-yank`): writes to macOS pasteboard via `pbcopy` AND emits `\033]52;s;BASE64\a` to `#{client_tty}` (bypasses tmux, writes directly to Ghostty's selection clipboard).
2. **tmux copy bindings** pipe through `tmux-yank #{client_tty}` on both `y` and `MouseDragEnd1Pane`.
3. **Karabiner middle-click → Cmd+V rule** for Ghostty kept as belt-and-suspenders fallback.

## Dead ends

- OSC 52 target `p` (primary) — silently dropped by Ghostty macOS bridge
- Ghostty keybind for mouse buttons — not supported
- tmux `MouseDown3Pane` — Karabiner intercepts button3 before tmux

**Why:** Cross-window copy-paste (e.g. Claude Code in tmux → plain Ghostty shell) requires both the macOS pasteboard (for Cmd+V) and Ghostty's selection clipboard (for middle-click) to be updated.

**How to apply:** Changes span `tmux/.tmux.conf`, `tmux/.local/bin/tmux-yank`, and `karabiner/.config/karabiner/karabiner.json`.
