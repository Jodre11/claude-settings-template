# Terminal Migration: iTerm2 → Ghostty

## Status: Complete — only iTerm2 font cosmetic issue remains (parked)

## Context
- iTerm2 has a flicker/strobe bug when Claude Code's status line is near the terminal bottom
- Caused by escape sequence race between content scrolling and status bar redraws
- Ghostty's synchronized rendering eliminates this

## Completed
- [x] Ghostty installed and running
- [x] Ghostty config created at `~/.config/ghostty/config`
  - Clipboard: allow read/write (needed for Hammerspoon voice-to-text)
  - Shell integration: zsh
  - macOS titlebar style: tabs
- [x] Hammerspoon voice-to-text updated: instant paste with clipboard restore (`~/.hammerspoon/init.lua`)
- [x] Added Ghostty, Hammerspoon, Karabiner, Starship to whisper-cpp prompt hints
- [x] Fixed font: `MesloLGS NF` (old p10k v1) → `MesloLGS Nerd Font Mono` (Nerd Fonts v3.4.0)
- [x] Nerd Font glyphs verified working in Ghostty (via `printf` in shell — confirmed 2026-03-25)
  - Claude Code strips Nerd Font PUA codepoints from its own output — CC limitation, not terminal/font
- [x] Claude Code flicker confirmed gone in Ghostty (2026-03-25)
  - Status line still updates visually (expected) but no full-screen strobe
- [x] Theme set: `Monokai Remastered` (dark) / `Monokai Pro Light Sun` (light)
  - Previously was `Gruvbox Dark Hard` / `Gruvbox Light`
  - iTerm2 was using Monokai Remastered — matched to keep colours consistent

## Still To Do
- [ ] iTerm2 font: staying on `MesloLGS NF` for now — `MesloLGS Nerd Font Mono` caused spacing issues in iTerm2
- [x] tmux fixed for Ghostty (2026-03-25)
  - Installed `xterm-ghostty` terminfo to `~/.terminfo/` (from Ghostty.app bundled binary)
  - Added `xterm-ghostty:RGB` to `terminal-overrides` and `terminal-features` in `~/.tmux.conf`
  - Removed `iTerm2*:RGB` override
  - Root cause: tmux didn't recognise `xterm-ghostty` → fell back to 256-color → theme colours were quantized
- [x] Mobile SSH truecolor verified (2026-03-25)
  - Termius and Blink Shell both send `xterm-256color` → already covered by `terminal-overrides`
  - Theme renders correctly over SSH; avoid mosh (strips truecolor)
  - Currently using Termius, may switch to Blink
- [x] Hammerspoon voice-to-text verified working in Ghostty (2026-03-25)
- [x] Starship prompt installed, replacing p10k (2026-03-25)
  - `brew install starship` (v1.24.2)
  - Config: `~/.config/starship.toml`
  - `.zshrc`: removed p10k instant prompt, set `ZSH_THEME=""`, added `eval "$(starship init zsh)"`
  - `~/.p10k.zsh` kept as backup
  - OMZ retained for plugins (autosuggestions, syntax-highlighting, etc.)
  - Style: clean 2-line, no frame, matches p10k segments (os, dir, git, cmd_duration, aws, terraform, kube, time)
  - Added `dotnet` and `terraform` OMZ plugins
  - Removed duplicate `aws` plugin entry

## Key Facts
- Ghostty config: `~/.config/ghostty/config`
- Old font `MesloLGS NF` was p10k-era (v1, 2013) — missing most Nerd Font v3 icons
- New font `MesloLGS Nerd Font Mono` is Nerd Fonts v3.4.0 — full icon set
- User's shell: zsh with OMZ + Starship + plugins (autosuggestions, syntax-highlighting, z, history-substring-search, aws, etc.)
- Starship config: `~/.config/starship.toml`
- `~/.p10k.zsh` kept as rollback backup
- tmux -CC (iTerm2 control mode) won't work in Ghostty — not needed
- `xterm-ghostty` terminfo not installed by default on macOS — must export from Ghostty.app and `tic -x` install
- tmux `terminal-overrides` and `terminal-features` must explicitly include `xterm-ghostty:RGB` for truecolor
- Voice-to-text: Hammerspoon + whisper-cpp + sox, triggered by Karabiner (PrintScreen → F19/F20)
- Whisper prompt hints in `~/.hammerspoon/init.lua` line 10-16
- Claude Code does not render Nerd Font PUA codepoints — use `printf`/`echo -e` in shell to verify font rendering
- Ghostty themes sourced from iterm2-color-schemes, browsable at iterm2colorschemes.com
