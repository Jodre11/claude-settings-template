# Global Settings

This directory (`~/.claude`) is a git repo (`claude-settings`). Commit and push changes when editing files here.

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
- Use `/tmp/claude-$PPID/` for all temporary files (tool output, diffs, commit drafts, etc.)
- Create the directory with `mkdir -p /tmp/claude-$PPID` before first use
- Files within don't need a session prefix — the directory is already session-scoped
- Clean up your temp files when no longer needed (OS also cleans on reboot)
- NEVER use `/var/folders/`, `$TMPDIR`, or bare `/tmp/` without the `claude-$PPID` subdirectory

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
- PR descriptions must begin with a brief contextual summary (1–3 sentences) explaining
  why the change is being made and what it achieves, written for a non-technical audience.
  Follow this with the detailed technical list of changes.

## Terraform (Haven)
- Each Terraform module directory requires its own PR — the Platform team applies PRs individually via `/apply` comment
- Never combine changes to multiple modules in a single PR
- If changes span multiple modules, create separate branches and PRs for each

## Code Inspection (C#)
- After editing C# files, run JetBrains InspectCode to check for issues beyond build warnings:
  ```bash
  jb inspectcode <solution> --output=/tmp/claude-$PPID/inspectcode-output.xml --format=Xml --severity=WARNING
  ```
- Parse the XML output; fix any `<Issue>` elements before finishing

## C#
- Use source-generated logging (`[LoggerMessage]` attribute) instead of string interpolation for all logging calls
- Use **System.Text.Json** with source-generated serialization (AOT compatible)

### Testing
- Use **Verify.XunitV3** for snapshot testing
- Use **WireMock.Net** for API/HTTP mocking
