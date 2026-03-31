# Global Settings

This directory (`~/.claude`) is a git repo (`claude-settings`). Commit and push changes when editing files here.

## Custom Tools

`~/.claude/tools/` contains source for custom CLI utilities. These are version-controlled but must
be compiled and installed on a new machine:

- `html2clip.swift` — copies HTML to macOS clipboard as rich text (used by `md-to-clipboard` skill).
  Install: `swiftc ~/.claude/tools/html2clip.swift -o ~/.local/bin/html2clip`

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
- Don't guess. If unsure, search using MCPs or ask the user
- Suggest adding tests for core functionality
- Suggest keeping .md files up to date

## Temporary Files
- Use `/tmp/claude-{session_id}/` for all temporary files (tool output, diffs, commit drafts, etc.)
- The session ID is available from conversation context (transcript path). Resolve it once at first
  use and reuse the same path throughout, including in subagent prompts
- Create the directory with `mkdir -p /tmp/claude-{session_id}` before first use
- Files within don't need a session prefix — the directory is already session-scoped
- This convention works in subagents (unlike `$PPID`, which resolves to a different PID per process)
- Clean up your temp files when no longer needed (OS also cleans on reboot)
- NEVER use `/var/folders/`, `$TMPDIR`, or bare `/tmp/` without the `claude-{session_id}` subdirectory

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
  jb inspectcode <solution> --output=/tmp/claude-{session_id}/inspectcode-output.xml --format=Xml --severity=WARNING
  ```
- Parse the XML output; fix any `<Issue>` elements before finishing

## C#
- Use source-generated logging (`[LoggerMessage]` attribute) instead of string interpolation for all logging calls
- Use **System.Text.Json** with source-generated serialization (AOT compatible)

### Testing
- Use **Verify.XunitV3** for snapshot testing
- Use **WireMock.Net** for API/HTTP mocking
