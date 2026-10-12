---
name: review-loop
description: Explain, prepare, run, or resume CodexReviewLoop with shared task context. Use when the user mentions ReviewLoop or asks to use it.
---

# Review Loop

Use `codex-review-loop.ps1` with PowerShell 7. Read `installation.json` beside
this skill; `repositoryPath` records the tool checkout. Infer the target
repository from the conversation. Do not ask the user for paths or routine
configuration you can resolve yourself.

Start or resume when asked, including "Run ReviewLoop for your changes".
The loop can edit and auto-commit. New runs require a clean dedicated branch;
preserve unrelated user changes.

## Shared task

For a new run, pass the original goal, acceptance criteria and relevant user
constraints neutrally in `-TaskContext`, applying [prompting](../prompting/SKILL.md).
Implementation choices and prior successful checks are evidence, not requirements.
No supplied task is also valid: the Architect reconstructs the goal from source,
branch changes, commit messages and project documentation before the first review.
The shared goal and necessary architecture work reach every participant and persist
across cycles.

On resume, omit `TaskContext` to inherit the saved task. Replace it only when the
user changes the assignment; an explicit empty value requests reconstruction.
Such changes requalify prior decisions without silently deleting open work.
Keep optional `ReviewerInstructions` for guidance specific to the Reviewer,
preserving applicable profile guidance. It does not define the shared task.
When supplied, retain its exact text on resume; the checkpoint stores only its fingerprint.

## Run and resume

Resolve the tool, target and any task text, then invoke:

```powershell
& (Join-Path $reviewLoopRoot 'codex-review-loop.ps1') -RepoPath $repoPath
```

Add `-TaskContext $taskContext` when supplying a new task. Profiles and review
bases are discovered automatically; use overrides when required by the project.
Repeating the command resumes a compatible checkpoint. `-NewRun` starts a fresh
run and is not needed to refresh an exhausted repair round.

`MaxFixAttempts` returns a preserved candidate to native review;
`MaxReviewCycles` bounds one invocation and resets on resume. At `limit_reached`,
assess progress before continuing. Repeated defects without progress or growing
scope require causal diagnosis, not blindly restarting. Architect acceptance,
configured gates and current completion evidence remain required.

Consult the tool's `docs/how-it-works.md` for workflow,
`docs/configuration.md` for settings, and `docs/operations.md` for recovery.
