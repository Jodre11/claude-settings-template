---
name: Fixterms/CSI u key bindings for Ghostty
description: Ghostty sends fixterms CSI u sequences for modified keys; zsh needs explicit bindkey entries in bare shells, tmux handles translation via extended-keys
type: feedback
---

Ghostty sends fixterms/CSI u encoded sequences for modified keys (Shift+Enter, Ctrl+Enter, etc.).
zsh has no native CSI u support, so unrecognised sequences print as garbage in bare Ghostty shells.

**Why:** tmux with `extended-keys on` + `extkeys` in terminal-features translates these sequences,
so the problem only manifests in bare shells (no tmux). The Ghostty keybinding approach
(`keybind = shift+enter=text:\x1b[13;2u`) was tried but is redundant — Ghostty already sends
CSI u by default. Remapping to plain `\r` would destroy key disambiguation.

**How to apply:**
1. zsh bindkeys in `.zshrc` handle the sequences Ghostty sends (xterm-modifyOtherKeys format
   `\e[27;modifier;codepoint~` for Enter/Backspace)
2. tmux `extended-keys on` + `extkeys` in terminal-features handles translation inside tmux
3. If new modified keys produce garbage in bare shells, add more bindkey entries to `.zshrc`
4. No Ghostty keybinding overrides needed — let Ghostty send its native fixterms encoding
