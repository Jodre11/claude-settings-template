# Global Settings

This directory (`~/.claude`) is a git repo (`claude-settings`). Commit and push changes when
editing files here. The repo is cloned independently on each machine (macOS, Windows, WSL, Linux).

## Cross-Platform Architecture

- **`settings.json`** (tracked) — cross-platform settings. All paths use `~` (expanded by
  Claude Code for permissions, by bash for hooks/statusLine). Never put absolute or `$HOME`
  paths here — except `awsAuthRefresh` which is written by `setup-platform.sh` (see below).
- **`settings.local.json`** — Claude Code only reads this at the **project** level
  (`<project>/.claude/settings.local.json`), NOT at the user level (`~/.claude/settings.local.json`).
  Do not put user-level settings here — they will be silently ignored.
- **`awsAuthRefresh`** — written into `settings.json` by `scripts/setup-platform.sh` with a
  platform-specific absolute path. On Windows, Claude Code passes this to CMD (not bash), so `~`
  and `$HOME` do not expand — the script wraps it with Git Bash and uses absolute Windows paths.
  On macOS/Linux/WSL it goes through bash so absolute paths work directly. The local modification
  is hidden from git via `skip-worktree`.
- **Hook scripts** — use `#!/usr/bin/env bash` shebangs. Claude Code runs hook commands through
  bash on all platforms, so `~` and `$HOME` expand correctly in hook `command` values.
- After cloning on a new machine, always run: `bash ~/.claude/scripts/setup-platform.sh`

## Custom Tools

`~/.claude/tools/` contains source for custom CLI utilities. These are version-controlled but must
be compiled and installed on a new machine:

- `md2clip` — converts Markdown to Teams-compatible HTML and copies to macOS clipboard (used by
  `md-to-clipboard` skill). Install: `ln -sf ~/.claude/tools/md2clip ~/.local/bin/md2clip`
  (macOS only)

## Related Repositories

- [dotfiles](https://github.com/Jodre11/dotfiles) (`~/dotfiles`) — macOS dotfiles managed with
  GNU Stow. Config files are symlinked into `~`, so edits to e.g. `~/.zshrc` modify the dotfiles
  repo. After changing any dotfile, remind the user to commit and push in `~/dotfiles`. After
  installing or removing a Homebrew package, remind the user to regenerate the Brewfile:
  `brew bundle dump --file=~/dotfiles/Brewfile --force`
  **Important:** `brew bundle dump` only includes packages currently installed via Homebrew. It
  silently drops entries for packages installed by other means (e.g. Docker Desktop, Chrome,
  JetBrains Toolbox). After regenerating, diff the Brewfile and restore any removed entries that
  were intentionally kept for new-machine provisioning.

# Preferences

## Code Style
- Indentation: 4 spaces
- Max line length: 120 characters
- Add .gitignore for build artifacts and IDE files
- Add .gitattributes to control line endings cross-platform
- Add .editorconfig for cross-IDE consistency
- Follow SOLID design principles
- Add header comments to public/exported functions
- Add comments to cognitively complex code

## Argument/Parameter Formatting
- All arguments/parameters on same line, OR each on its own line (including first)
- If list has more than 3 items: each on its own line
- If list exceeds 120 characters: each on its own line
- Example (inline):
  ```
  DoSomething(arg1, arg2, arg3);
  ```
- Example (wrapped):
  ```
  DoSomething(
      arg1,
      arg2,
      arg3,
      arg4);
  ```

## Communication
- Be terse, formal, direct
- I am an experienced expert software engineer

## Behavior
- Don't guess. If unsure, search using MCPs, the `web-search` skill (`ddgr`), or ask the user
- When you need URLs, documentation, or current information: use the `web-search` skill rather
  than guessing or declining. It uses `ddgr` (DuckDuckGo CLI) — no API key, no tracking.
- Suggest adding tests for core functionality
- Suggest keeping .md files up to date

## Temporary Files
- Use `/tmp/claude-{session_name}/` for all temporary files (tool output, diffs, commit drafts, etc.)
- The session name is a three-word slug (e.g. `modular-napping-aho`) visible in system context such
  as plan file paths. It is NOT an environment variable — extract it from context once, then use it
  as a literal string in all commands. When spawning subagents, pass the resolved path in the prompt
  (e.g. `"use /tmp/claude-modular-napping-aho/ for temp files"`)
- Create the directory with `mkdir -p /tmp/claude-{session_name}` before first use
- Files within don't need a session prefix — the directory is already session-scoped
- This convention works in subagents (unlike `$PPID`, which resolves to a different PID per process)
- Clean up your temp files when no longer needed (OS also cleans on reboot)
- NEVER use `/var/folders/`, `$TMPDIR`, or bare `/tmp/` without the `claude-{session_name}` subdirectory

## Agents
- Always set `mode: "auto"` when dispatching agents — the interactive session uses plan mode
  (`defaultMode: "plan"` in settings.json), but subagents inherit this and stall when they need
  Write/Edit tools. `"auto"` lets subagents execute autonomously while the parent retains
  plan-mode control
- Always set the `name` parameter when dispatching agents via the Agent tool
- Names must be kebab-case, descriptive, and unique within a session
- For predefined agents with definition files: use the agent definition name
  (e.g., `security-reviewer`, `code-analysis`)
- For built-in agent types: use `{type}-{scope}` (e.g., `explore-auth-flow`,
  `plan-api-redesign`)
- For task-scoped agents: use `{role}-task-{n}` (e.g., `implementer-task-3`,
  `spec-reviewer-task-3`)
- This enables `SendMessage({to: name})` for diagnosing agent failures or
  assessing results while agents run

## Bash
- Never use compound shell commands (`&&`, `||`, `;`) — execute each command as a separate Bash call
- Never use command substitution (`$(...)`, backticks) — capture output from one Bash call and pass it to the next
- Never use subshells or grouping (`(...)`, `{ ...; }`) — use separate Bash calls
- Prefer dedicated tools or separate Bash calls over piping (`|`) where possible
- Prefer dedicated tools or separate Bash calls over redirection (`>`, `>>`) where possible; `2>&1` is acceptable when capturing stderr

## LSP
- Prefer LSP (`goToDefinition`, `findReferences`, `goToImplementation`, `incomingCalls`, `outgoingCalls`) over Grep when positioned at a specific symbol and need semantic precision
- Fall back to Grep/Glob for discovery, broad text searches, config files, and non-code files
- If LSP calls fail or no language server is available for the current language, inform the user and suggest installing one (e.g. `dotnet tool install --global csharp-ls` for .NET)

## Playwright
- Prefer the `playwright-cli` skill over `mcp__playwright__*` tools — it is less token expensive
- The Playwright Chrome extension is installed, enabling the CLI to connect to an existing Chrome browser instance

## Git
- Do not add Co-Authored-By trailers to commits
- Do not add Claude Code advertising to PR descriptions
- PR descriptions must begin with a brief contextual summary (1–3 sentences) that orients
  the reader: what broader initiative or goal this PR contributes to, where it fits in any
  sequence of related PRs, and why the change is needed now. Write this for a non-technical
  audience. Follow this with the detailed technical list of changes, including links to
  related PRs where informative or clarifying.

## Terraform (Haven)
- Each Terraform module directory requires its own PR — the Platform team applies PRs individually via `/apply` comment
- Never combine changes to multiple modules in a single PR
- If changes span multiple modules, create separate branches and PRs for each

## Code Inspection (C#)
- After editing C# files, run JetBrains InspectCode to check for issues beyond build warnings:
  ```bash
  jb inspectcode <solution> --output=/tmp/claude-{session_name}/inspectcode-output.xml --format=Xml --severity=WARNING
  ```
- Parse the XML output; fix any `<Issue>` elements before finishing

## C#
- Use source-generated logging (`[LoggerMessage]` attribute) instead of string interpolation for all logging calls
- Use **System.Text.Json** with source-generated serialization (AOT compatible)

### Testing
- Use **Verify.XunitV3** for snapshot testing
- Use **WireMock.Net** for API/HTTP mocking
