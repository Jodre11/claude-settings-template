---
name: Middle-click cross-clipboard paste fix
description: Clipboard bridging between Ghostty and tmux — Hammerspoon event tap intercepts middle-click in Ghostty, tmux-yank writes to both pasteboard and Ghostty selection via OSC 52
type: project
---

Middle-click in Ghostty reads from a private app-local `selection` clipboard (`com.mitchellh.ghostty.selection` NSPasteboard), not the macOS system clipboard. This is hardcoded — no config option to change it.

## Solution

1. **Hammerspoon middle-click event tap** (`hammerspoon/.hammerspoon/init.lua`): intercepts `otherMouseDown` button 2 when the cursor is over a Ghostty window and synthesises Cmd+V. Uses `mouseEventWindowUnderMousePointer` with geometry fallback (Hammerspoon issue #2848).
2. **`tmux-yank` script** (`tmux/.local/bin/tmux-yank`): writes to macOS pasteboard via `pbcopy` AND emits `\033]52;s;BASE64\a` to `#{client_tty}` (Ghostty's selection clipboard).
3. **tmux copy bindings** pipe through `tmux-yank #{client_tty}` on both `y` and `MouseDragEnd1Pane`.
4. **tmux `MouseDown2Pane`** binding reads from `pbpaste` directly — works independently of the Hammerspoon tap.

## Superseded

- **Karabiner middle-click → Cmd+V rule** — removed 2026-04-02. Unreliable for mouse button interception; replaced by Hammerspoon event tap.

## Dead ends

- OSC 52 target `p` (primary) — silently dropped by Ghostty macOS bridge
- Ghostty keybind for mouse buttons — not supported
- tmux `MouseDown3Pane` — unreliable when Karabiner intercepted button3

**Why:** Ghostty's native middle-click reads from a private pasteboard, not the system clipboard. Copy from any app → middle-click in Ghostty must route through Cmd+V.

**How to apply:** Changes span `hammerspoon/.hammerspoon/init.lua`, `tmux/.tmux.conf`, and `tmux/.local/bin/tmux-yank`.
