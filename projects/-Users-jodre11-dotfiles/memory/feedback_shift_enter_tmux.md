---
name: Shift+Enter newline requires tmux extkeys
description: Shift+Enter in Claude Code fails without extkeys in tmux terminal-features — tmux strips CSI u sequences
type: feedback
---

Shift+Enter stopped inserting newlines in Claude Code when running inside tmux in Ghostty.
Root cause: tmux was stripping the CSI u / Kitty keyboard protocol sequences before they
reached Claude Code.

**Why:** tmux needs `extkeys` in `terminal-features` and `extended-keys on` to pass extended
key sequences through to applications. Without these, Shift+Enter is indistinguishable from
Enter.

**How to apply:** If Shift+Enter breaks again in Claude Code under tmux, check:
1. `terminal-features` includes `extkeys` for the Ghostty terminal type
2. `extended-keys on` is set in `.tmux.conf`
3. Claude Code v2.1.85+ handles Shift+Enter natively for Ghostty — no explicit Ghostty
   keybinding is needed (tested and confirmed 2026-03-27, keybinding removed)
