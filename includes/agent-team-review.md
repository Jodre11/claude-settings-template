## Agent Team Review

### Routing thresholds

**Use `code-analysis` agent (lightweight)** when ALL of these are true:
- 5 or fewer files changed
- 150 or fewer total lines changed (insertions + deletions)
- No deletions of non-trivial code blocks (10+ contiguous deleted lines in a single hunk)

**Use agent team review (full specialist team in tmux panes)** when ANY of these are true:
- More than 5 files changed
- More than 150 total lines changed
- Significant deletions detected (10+ contiguous deleted lines in any hunk)
- The diff touches security-sensitive areas (auth, crypto, input validation, SQL, API endpoints)

Announce which approach you're using and why before starting, e.g.:
> 3 files, 47 lines changed — using lightweight review (code-analysis)

or:

> 12 files, 340 lines changed with significant deletions — using full review team (agent team)

### Lightweight path

Dispatch the `code-analysis` agent with the base branch as its argument.

### Full review team path (agent team)

Do NOT use the `code-review-team` agent or the Agent tool for this. Create a team of
teammates in separate tmux panes using the existing reviewer agent definitions.

#### Step 1: Prepare the diff for teammates

Before creating the team, save the diff to a temp file that teammates can read:

```bash
mkdir -p /tmp/claude-{session_name}
```

For `/pre-review`: write the git diff to the temp file:
```bash
git diff {base}...HEAD > /tmp/claude-{session_name}/pr-diff.txt
```

For `/review-pr`: fetch the PR diff to the temp file:
```bash
gh pr diff {pr_number} > /tmp/claude-{session_name}/pr-diff.txt
```

**IMPORTANT:** Do NOT reference internal `tool-results/` paths or copy files from
Claude Code's internal directories. Always re-fetch the diff using the commands
above. Teammates cannot access tool-results paths and the permission prompts
disrupt the review flow.

#### Step 2: Create the team

Create a team and spawn these teammates:
- `security-reviewer`
- `correctness-reviewer`
- `consistency-reviewer`
- `style-reviewer`
- `archaeology-reviewer`
- `reuse-reviewer`
- `efficiency-reviewer`

If any changed files end with `.cs`, also spawn `jbinspect-reviewer`.

Each teammate runs autonomously using its standalone mode — it determines the base
branch, gathers the diff, and writes findings in its defined output format.

Instruct each teammate to write its findings to a temp file:
`/tmp/claude-{session_name}/review-{reviewer-name}.md`

#### Step 3: Conduct your own analysis (while teammates are working)

While the teammates are running, perform your own independent deep analysis of the
changes. Read the diff and changed files. Think through:
- What is the overall intent of these changes? Does the implementation achieve it?
- What are the subtle interactions between changed files?
- Are there systemic issues that a file-by-file review would miss?
- What would break in production that looks fine in a diff?
- Are there architectural concerns or design smells?
- What edge cases has the author likely not considered?

Record your own findings before reading teammate results.

#### Step 4: Collate and synthesize

Wait for ALL teammates to finish before starting synthesis — jbinspect-reviewer
takes longer than the others because `jb inspectcode` must load and analyse the
full .NET solution. Do not begin aggregation until its report is available.

Read each report from `/tmp/claude-{session_name}/review-*.md`.

JetBrains InspectCode findings are 100% confidence (they come from static
analysis tooling, not heuristic review). Classify their severity based on the
InspectCode output: ERROR → Critical, WARNING → Important, SUGGESTION → Suggestion.

Cross-reference teammate findings with your own analysis and classify into tiers:

**Consensus** — reported by one or more teammates, and your own analysis agrees.
Or multiple teammates agree on the same issue.

**Contested** — disagreement exists between teammates, or between you and a teammate,
or the same issue flagged with significantly different severity/confidence (>30 point
gap). Present all positions including yours. Pay special attention to cross-reviewer
conflicts:
- Archaeology vs correctness/style — a deletion endorsed as cleanup may be a risky
  removal of an undocumented workaround
- Reuse vs style — flagged code may be clear and self-contained
- Efficiency vs correctness — a suggested optimisation may introduce a subtle bug

**Dismissed** — a teammate flagged it but you believe it's a false positive after deep
analysis. Include your detailed reasoning so the user can override.

**Opus-only** — issues you identified that no teammate caught. These are often the most
valuable: cross-cutting concerns, subtle interaction bugs, architectural issues, or
problems requiring holistic understanding.

#### Step 5: Format output

Number all findings sequentially. Tag each with its source: `[security]`,
`[correctness]`, `[consistency]`, `[style]`, `[archaeology]`, `[reuse]`,
`[efficiency]`, `[jbinspect]`, `[opus]`.

```
## Summary
X file(s) changed | Y finding(s) | Z contested

## Opus Assessment
> High-level analysis: intent, risk profile, areas of concern, overall impression.
> This is your independent expert assessment before diving into individual findings.

## Consensus Findings

### Critical
#### Finding #1 — [short title] [source]
- **File:** path/to/file:42
- **Confidence:** 95
- **Description:** What is wrong and why it matters
- **Suggested fix:** Concrete code change or approach
- **Opus:** Your assessment — agree/amplify with additional context

### Important
...

### Suggestions
...

## Opus Findings
> Issues you identified that no teammate caught.

### Finding #N — [short title] [opus]
- **File:** path/to/file:42
- **Confidence:** 0-100
- **Severity:** Critical | Important | Suggestion
- **Description:** What you found and why it matters
- **Suggested fix:** Concrete code change or approach
- **Why teammates missed it:** Brief explanation

## Contested Findings
> Disagreement between reviewers. Your judgment is needed.

### Finding #N — [short title]
- **File:** path/to/file:42
- **Positions:**
  - [source] (confidence X): Believes A because...
  - [source] (confidence Y): Disagrees because...
- **Opus:** Your substantive analysis of who is right and why.

## Dismissed Findings
> Flagged by a teammate but believed to be false positives.

### Finding #M — [short title] [source]
- **File:** path/to/file:42
- **Original confidence:** 65
- **Dismissed because:** Detailed reasoning
```

If a tier has no findings, omit that section (except Opus Assessment — always present).

If no findings at all:
```
## Summary
X file(s) changed | 0 findings — LGTM

## Opus Assessment
> Still provide your assessment. Note what you looked at and why it's clean.
```

#### Step 6: Clean up

After producing the final output, close all remaining teammate tmux panes that
were created for this review. Do not leave orphaned panes running.

#### Rules
- Do NOT use the Agent tool or code-review-team agent. Use the teammate mechanism.
- Every finding MUST have an **Opus:** assessment.
- Do not pre-filter findings before synthesis. Let teammates report everything.
- Be precise. Preserve file paths and line numbers from teammate reports.
- Number findings sequentially so the user can reference "finding #3".
- Attribute every finding to its source teammate(s) or `[opus]` for your own.
- Do not silently drop or merge findings.
