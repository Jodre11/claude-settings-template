---
name: Claude Code optimisation session (2026-04-15)
description: Session adding CLI tools, LSP servers, and env vars to maximise Claude Code on Bedrock; capability vars not yet verified working
type: project
originSessionId: ce5c527e-8326-43c1-b0de-927e3a2a21a0
---
## What was done

### CLI tools (committed, pushed)
- Installed and added to Brewfile: `fd`, `fzf`, `bat`, `git-delta`, `yq`
- Commit: `5222739`

### LSP servers (committed, pushed)
- Installed all 11 Claude Code LSP servers globally
- Brewfile: added `jdtls`, `kotlin-language-server`, `lua-language-server`
- `.zshrc`: added `$HOME/.dotnet/tools` to PATH for `csharp-ls`
- `bootstrap.sh`: added `csharp-ls` to dotnet tools, `rust-analyzer` to rustup
  components, new npm global tools section (pyright, typescript-language-server,
  intelephense, typescript)
- Commit: `5b65118`, `22e3a9d`

### Env vars added to ~/.claudeenv (not tracked)
- `ENABLE_TOOL_SEARCH=1` — MCP tool discovery
- `ANTHROPIC_DEFAULT_OPUS_MODEL_SUPPORTED_CAPABILITIES` — effort, max_effort, thinking, adaptive_thinking, interleaved_thinking
- `ANTHROPIC_DEFAULT_SONNET_MODEL_SUPPORTED_CAPABILITIES` — effort, thinking, adaptive_thinking, interleaved_thinking
- `ANTHROPIC_DEFAULT_HAIKU_MODEL_SUPPORTED_CAPABILITIES` — effort, thinking, adaptive_thinking
- `ANTHROPIC_CUSTOM_MODEL_OPTION_SUPPORTED_CAPABILITIES` — same as Opus (covers the "Custom model" entry in /model picker)
- `ENABLE_PROMPT_CACHING_1H=1` — 1-hour cache TTL
- `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1` — credential stripping from subprocesses

## Blocked: capability vars not taking effect

The `SUPPORTED_CAPABILITIES` vars were added but `/model` still shows "Effort not
supported" for the custom model entry. The vars ARE in `~/.claudeenv` and the file
IS sourced by `.zshrc`, but `env | grep SUPPORTED_CAPABILITIES` returned nothing in
the session that was tested. Need to verify in a fresh session whether:

1. The vars are actually in the environment (`env | grep SUPPORTED_CAPABILITIES`)
2. If yes, whether Claude Code reads them (might need a different var name or format)
3. If no, debug why `.zshrc` → `.claudeenv` sourcing isn't exporting them

**How to apply:** Resume debugging from step 1 above in the next session.
