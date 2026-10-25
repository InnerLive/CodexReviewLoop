---
name: review-loop
description: Explain, prepare, run, or resume CodexReviewLoop with shared task context. Use when the user mentions ReviewLoop or asks to use it.
---

# Review Loop

Use `codex-review-loop.ps1` with PowerShell 7. Read `installation.json` beside
this skill; `repositoryPath` records the primary tool checkout. Infer the target
repository from the conversation. Resolve paths and routine configuration yourself.

Start or resume only when asked. The loop can edit and auto-commit; new runs
require a clean dedicated branch. Preserve unrelated changes.

## Shared task and resume

For a new run, pass the goal, acceptance criteria and user constraints neutrally
in `-TaskContext`, applying [prompting](../prompting/SKILL.md). Implementation
choices and previous checks are evidence, not requirements. Without a supplied
task the Architect reconstructs the goal from the branch and project sources.

```powershell
& (Join-Path $reviewLoopRoot 'codex-review-loop.ps1') -RepoPath $repoPath
```

Add `-TaskContext $taskContext` for a new supplied task. Profiles and review bases
are discovered automatically. Repeating the compatible command resumes its checkpoint;
`-NewRun` starts another run and is unnecessary to refresh an exhausted repair round.

On resume, omit TaskContext to inherit the saved assignment. Replace it only for a
user-authorized assignment change; an explicit empty value requests reconstruction.
Keep ReviewerInstructions for Reviewer-specific guidance, preserving profile guidance.
When supplied, retain its exact text on resume; only its fingerprint is checkpointed.

MaxFixAttempts returns the preserved candidate to native review. MaxReviewCycles
bounds one invocation and resets on resume. Assess progress at `limit_reached`;
repeated defects or growing scope need causal diagnosis before continuing.
Architect acceptance, current tests and configured gates remain required.

## Supervise the normal output

Continue following the normal loop output. Send only new evidence or a specific
intervention; do not repeatedly transfer the task, summarize the run, or request
separate acknowledgment or evaluation summaries.

Use the exact reported RunRoot containing `run-v1.json` for every intervention:

| Need | Action |
| --- | --- |
| A hint for the next matching role call | Message with explicit recipients |
| New product evidence requires revisiting a decision before more fixing or acceptance | Architect reassessment |
| Evidenced recurring working-process problems | One-time Critic request |
| A necessary investigation or handover | Controlled pause |
| Re-entry after context loss or unclear pending interventions | Read-only status |

Already live-changeable profile settings use the existing profile/configuration
reload path in [configuration](../../docs/configuration.md); do not send them as
operator requests. Detailed boundaries and recovery rules belong to
[operations](../../docs/operations.md) in the tool checkout. See also
[workflow](../../docs/how-it-works.md). Resolve these documents from repositoryPath
when using an installed copy of this skill.

## Messages and reassessment

```powershell
& (Join-Path $reviewLoopRoot 'operator-message.ps1') $runRoot -To Architect -Message 'Check the new evidence: check.log.'
& (Join-Path $reviewLoopRoot 'operator-message.ps1') $runRoot -To Reviewer,Fixer -Message 'Recheck cancellation recovery.' -RequireDelivery
& (Join-Path $reviewLoopRoot 'operator-message.ps1') $runRoot -ReassessArchitect -Message 'Reason: assumption X failed. Evidence: check.log.'
```

Choose Reviewer for native review evidence, Architect for advice/assessment and
Fixer for implementation evidence. Ordinary messages reach the next regular call
once per recipient, including resume. Running calls are never interrupted.
Use RequireDelivery sparingly: it can force additional review, fixing or assessment
before the next unsealed commit or completion, within existing budgets.

ReassessArchitect uses the existing Architect session and normal decision contract.
It remains effective during commit/completion gates before atomic HEAD advancement
or completion. It preserves the candidate and still-matching test evidence.
It has no To, RequireDelivery or PauseAt. Inspect the normal Architect result.

Publication returns an ID, not proof of delivery or a reached halt. Keep it;
retry an uncertain publication with identical arguments and `-Id $messageId`.
Changed content needs a new ID. Normal output reports delivery, evaluation or
rejection briefly. Requests never replace the assignment or grant acceptance.
Never edit checkpoints/mailboxes or silently forward requests to a different run.

## One-time Critic

```powershell
& (Join-Path $reviewLoopRoot 'operator-message.ps1') $runRoot -RequestCritic -Message 'Repeated repairs assume X. Evidence: assessment-3.json.'
```

Check existing criticism and the participants' response first. Do not repeat
requests without new evidence or infer poor work from elapsed time alone.
The advisory Critic handles selected requests at the next legal cycle boundary,
even with automatic critiques disabled; a due automatic call handles them too.
It interrupts no work. Pending requests survive pause, budget exhaustion and
resume. Completion takes precedence and supersedes remaining requests.
This mode excludes To, RequireDelivery, PauseAt and ReassessArchitect.

## Controlled pause and handover

```powershell
& (Join-Path $reviewLoopRoot 'operator-message.ps1') $runRoot -PauseAt AfterRole -Message 'Inspect the current result.'
& (Join-Path $reviewLoopRoot 'operator-message.ps1') $runRoot -PauseAt AfterRound -Message 'Investigate repeated repairs.'
& (Join-Path $reviewLoopRoot 'operator-message.ps1') $runRoot -PauseAt BeforeCommit -Message 'Check an external prerequisite.'
& (Join-Path $reviewLoopRoot 'operator-message.ps1') $runRoot -PauseAt BeforeCompletion -Message 'Check final operational evidence.'
```

AfterRole selects the earliest safe transition after the current call. AfterRound
finishes the current review/repair round, including its commit or candidate
preservation. BeforeCommit stops before gates/preparation, including no-ops;
BeforeCompletion stops after final assessment/gates. A missed boundary stops at
the next safe point and is reported explicitly. Active tests, gates and transactions
finish their required checks/recovery; no model process is cancelled.

Wait for `paused` (exit 5), the requested/reached boundary, and confirmation that
the loop process has exited and released its repository lease before takeover.
A saved status or published request alone is insufficient. Preserve HEAD, refs,
index, candidate and recovery artifacts. Address the cause, then explicitly repeat
the compatible start command. Do not restart automatically while the cause remains.
Reached requests are consumed; other pending requests survive resume.

## Status only when needed

```powershell
$status = & (Join-Path $reviewLoopRoot 'operator-status.ps1') $runRoot | ConvertFrom-Json
& (Join-Path $reviewLoopRoot 'operator-status.ps1') $runRoot -Since $status.Cursor
```

Saved contains checkpoint facts; Observed contains separately sourced observations.
Neither a saved active role nor recent terminal output proves a running process.
A held repository lease identifies no process or run. Missing facts are omitted;
the invocation counter is available, but its unrecorded budget limit is not.

Status reads open checkpoint and published mailbox requests without importing them
or changing the run. Since returns up to 50 complete new terminal.log lines,
a new Cursor and Changes.HasMore. Continue with that cursor for remaining pages.
Foreign/reset cursors are rejected; obtain a fresh status deliberately.
No polling or second dashboard is needed.
