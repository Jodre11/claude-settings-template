# Identity

I am a contractor (Product Engineer) working across Finance, HRIS, and platform tooling at Haven.
I am an experienced expert software engineer. Be terse, formal, direct.

# Code Conventions

## Style
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

## C#
- Use source-generated logging (`[LoggerMessage]` attribute) instead of string interpolation for all logging calls
- Use **System.Text.Json** with source-generated serialization (AOT compatible)
- After editing C# files, run JetBrains InspectCode to check for issues beyond build warnings:
  ```bash
  jb inspectcode <solution> --output=${CLAUDE_TEMP_DIR}/inspectcode-output.xml --format=Xml --severity=WARNING
  ```
- Parse the XML output; fix any `<Issue>` elements before finishing

### Testing (C#)
- Use **Verify.XunitV3** for snapshot testing
- Use **WireMock.Net** for API/HTTP mocking

## Terraform (Haven)
- The Platform team applies a PR via a single `/apply` comment — fires once, applies all Terraform changes in the PR
- A PR must not include dependent modules (no ordering within a single apply); use separate PRs for ordered changes
- Independent modules may coexist in one PR; avoid combining CI workflow changes with Terraform changes

# Behaviour

- Don't guess. If unsure, search using MCPs, the `web-search` skill, or ask the user
- When you need URLs, documentation, or current information: use the `web-search` skill rather
  than guessing or declining. It queries a SearXNG instance — no API key, no tracking.
- Suggest adding tests for core functionality
- Suggest keeping .md files up to date

# Tool Directives

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

# Process

## Temporary Files
- A `SessionStart` hook injects `CLAUDE_TEMP_DIR` into conversation context — use this path for
  all temporary files (tool output, diffs, commit drafts, etc.)
- The path is `/tmp/claude-<session_id>/` where `session_id` is the stable UUID for this session
- The directory is created automatically by the hook — no need to `mkdir -p`
- When spawning subagents, pass the resolved `CLAUDE_TEMP_DIR` value in the prompt
  (e.g. `"use /tmp/claude-5bf0f026-ba82-43b7-8c4d-4c116b4bebf7/ for temp files"`)
- Files within don't need a session prefix — the directory is already session-scoped
- Clean up your temp files when no longer needed (OS also cleans on reboot)
- NEVER use `/var/folders/`, `$TMPDIR`, or bare `/tmp/` without the `claude-<session_id>` subdirectory

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

# Repo Context

This directory (`~/.claude`) is a git repo (`claude-settings`). Commit and push changes when
editing files here.

## Custom Tools

`~/.claude/tools/` contains custom CLI utilities (version-controlled, must be installed per machine):

- `md2clip` — converts Markdown to Teams-compatible HTML and copies to macOS clipboard (used by
  `md-to-clipboard` skill). Install: `ln -sf ~/.claude/tools/md2clip ~/.local/bin/md2clip`
- `aws-secret-field` — updates a single field in a JSON secret in AWS Secrets Manager. Optionally
  writes the value to a local file (e.g. a Strongbox-encrypted `.secret` file). Requires
  `--secret-id` or `AWS_SECRET_ID`; uses `--profile` or `AWS_PROFILE`. When providing the command
  to the user, use `PASTE_VALUE_HERE` as the value placeholder — the user pastes the real value
  in a separate terminal to keep secrets out of the conversation.
  Usage: `aws-secret-field <field_name> "PASTE_VALUE_HERE" --secret-id <id> [--profile <p>] [--file <path>]`

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
