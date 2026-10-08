---
name: review-loop
description: Explain, prepare, run, or resume CodexReviewLoop with task-specific reviewer context. Use when the user mentions ReviewLoop or asks to use it.
---

# Review Loop

Use `codex-review-loop.ps1` with PowerShell 7. Read `installation.json` beside
this skill's `SKILL.md`; its `repositoryPath` is the tool checkout recorded by
the installer. Use it as `$reviewLoopRoot`. Infer the repository to review and
the relevant task context from the current conversation, not from the tool's
location. Do not ask the user to supply paths or routine configuration that
you can resolve yourself.

It reviews the branch diff against a pinned base, routes findings through
Architect and Fixer, and runs configured gates before committing accepted work.
Start or resume only when the user asks to run it. A new run requires a clean
worktree and can edit and auto-commit.
A request such as "Run ReviewLoop for your changes" is a request to run it,
not merely to explain the command. Preserve unrelated user changes.

## Reviewer context

Before launching, consider which task goal, acceptance criterion, or deliberate
tradeoff the fresh Reviewer would otherwise miss. Supply this context neutrally
in brief `ReviewerInstructions`, applying [prompting](../prompting/SKILL.md).
Do not present your implementation choices as requirements or prior checks
as proof of correctness. Keep the review focused on concrete defects relevant
to the requested implementation and its correctness, security, and compatibility
requirements; intentional choices remain open to contrary evidence.

## Run and resume

With the tool checkout, target repository, and prepared text resolved:

```powershell
& (Join-Path $reviewLoopRoot 'codex-review-loop.ps1') -RepoPath $repoPath -ReviewerInstructions $reviewerInstructions
```

The CLI discovers or generates a profile. Use `-ConfigPath` or `-ReviewBase`
when needed. `-ReviewerInstructions` replaces the profile value, so retain
applicable profile guidance. It reaches only the Reviewer; Architect and Fixer
receive findings and advice.

Repeating the command resumes a compatible checkpoint; `-NewRun` starts a
fresh run. Retain the exact reviewer text for resume: the checkpoint stores
its fingerprint, not the text. Changing it requalifies prior review evidence.

`MaxFixAttempts` limits a fix round before another review;
`MaxReviewCycles` limits one invocation and resets on resume. At `limit_reached`,
assess progress before continuing. Repeated findings without progress or growing
scope require diagnosing the cause, not blindly restarting. Finish when the
configured completion condition is met.

Consult documentation in the resolved tool checkout as needed:
`docs/how-it-works.md` for workflow and completion, `docs/configuration.md` for
profiles and options, and `docs/operations.md` for operation and recovery.
