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

## Operator messages

While supervising an existing run, use its reported `RunRoot` (the directory
containing `run-v1.json`). Publish short new evidence through the tool; never edit
checkpoints or mailbox files:

```powershell
& (Join-Path $reviewLoopRoot 'operator-message.ps1') $runRoot -To Architect -Message 'Check the new counter-evidence.'
& (Join-Path $reviewLoopRoot 'operator-message.ps1') $runRoot -To Reviewer,Fixer -Message 'Recheck cancellation recovery.' -RequireDelivery
```

Explicitly select one or more recipients: Reviewer for native review evidence,
Architect for advice or assessment, Fixer for implementation evidence. The
supervising Operator chooses recipients from the normal flow; no routing model
or acknowledgment evaluation runs. Messages do not replace the assignment or
grant acceptance. Use `TaskContext` on resume for an authorized assignment change.

Choose a normal message for evidence that can wait for the recipient's next
regular call. Choose Architect reassessment when new evidence challenges a
decision that must be reconsidered before further implementation or acceptance:

```powershell
& (Join-Path $reviewLoopRoot 'operator-message.ps1') $runRoot -ReassessArchitect -Message 'Reason: the counter-check contradicts assumption X. Evidence: counter-check.log.'
```

Supply a short reason, observation and evidence or artifact reference. The
existing Architect uses its normal session, advice and assessment contracts;
evaluate that normal result without asking for an extra acknowledgment. This
mode has no `-To`, `-RequireDelivery` or `-PauseAt`. It preserves the current
assignment, open work and findings, and cannot replace required tests.
Only a user-authorized assignment change replaces `TaskContext` on resume;
omit it to inherit the assignment, or pass an explicit empty value to reconstruct
it. That existing revision path requalifies prior decisions and completion.

Reassessment also applies during commit gates or a prepared commit. A request
published before the atomic HEAD update prevents that commit until the Architect
has evaluated it. The owned candidate and matching test evidence are preserved;
current gates still run before commit. After HEAD advances, the request applies
to subsequent work. During final assessment or gates, reassessment remains
available until the run is atomically completed. Completed runs reject new
requests. Publication returns only the ID; `evaluated by Architect` means its
normal validated result was applied, not that the Operator granted acceptance.

The command returns a message ID, meaning published, not delivered. Keep that ID;
retry an uncertain publication with the identical recipients, text and switch
plus `-Id $messageId`. A changed request needs a new ID. The loop reports only
the ID and a short delivery or rejection reason. Infer substantive handling from
normal role results; do not request a separate summary or read receipt.

Ordinary messages reach each selected role's next regular call, including resume.
Already-running calls are not interrupted. Messages are delivered once per
recipient and are not repeatedly appended to later calls. A new addressed message
prevents reuse of an older decision at that role's next call.

Use `-RequireDelivery` sparingly and deliberately: it can **force additional
Reviewer, Architect or Fixer work** before the next unsealed commit or completion.
It can restart native review of a preserved candidate or repeat fixing and
assessment. Existing budgets, tests, gates and acceptance responsibilities still
apply. Exhausted budgets leave the delivery pending for resume.

For ordinary messages the loop seals a durable request boundary before commit
gates and final assessment. Messages published after a commit boundary apply to
the next phase,
even with `-RequireDelivery`; they cannot alter the sealed transaction on resume.
After completion is sealed, new ordinary messages are rejected. Messages with no
remaining matching call are rejected at completion. Mailboxes live outside the
reviewed worktree under `%LOCALAPPDATA%\CodexReviewLoop\operator`.

For a stale/wrong run or rejected request, inspect the short reason and the normal
run output. Correct the cause and publish a new message only if still relevant.
Never silently carry old requests into another run, change an existing message,
or edit the checkpoint to mark it delivered. `-Help` shows the command interface.

## One-time Critic requests

Send concrete product counter-evidence to the Architect; use
`-ReassessArchitect` when an existing decision must be reconsidered before more
implementation or acceptance. For evidenced recurring problems in the working
process, request the existing advisory Critic when needed:

```powershell
& (Join-Path $reviewLoopRoot 'operator-message.ps1') $runRoot -RequestCritic -Message 'Repeated repairs still assume X. Evidence: assessment-3.json, test-4.log.'
```

Give a short reason and optional evidence references, not another run summary.
Consider existing criticism and the participants' response first. Do not repeat
the same request without new evidence. Elapsed time alone does not justify
negative criticism; the Critic judges the reason independently.

This requests one call at the next legal cycle boundary before a native review,
even with automatic critiques disabled. A regularly due call handles the request
too. It changes no configuration and interrupts no Fixer, assessment, test, gate
or commit. Multiple selected requests share one call; later arrivals remain
pending. Publication is not handling: `handled by Critic` follows a validated
result. Pending and interrupted requests survive resume; completed calls are not
repeated. Existing review budgets still apply. Completion takes precedence and
marks pending requests `superseded: run completed`; completed runs reject new
requests. Keep the ID for identical retries. This mode has no `-To`,
`-RequireDelivery`, `-PauseAt` or `-ReassessArchitect`.

## Controlled pauses

Use the same run-scoped publisher with a reason and one boundary:

```powershell
& (Join-Path $reviewLoopRoot 'operator-message.ps1') $runRoot -PauseAt AfterRole -Message 'Inspect the current result.'
& (Join-Path $reviewLoopRoot 'operator-message.ps1') $runRoot -PauseAt AfterRound -Message 'Investigate repeated repair failures.'
& (Join-Path $reviewLoopRoot 'operator-message.ps1') $runRoot -PauseAt BeforeCommit -Message 'Check an external prerequisite.'
& (Join-Path $reviewLoopRoot 'operator-message.ps1') $runRoot -PauseAt BeforeCompletion -Message 'Check final operational evidence.'
```

Choose `AfterRole` for the earliest safe intervention after the current call;
`AfterRound` lets the current review and repair round finish, including tests,
assessment and any accepted commit, or preservation of a rejected candidate.
Outside a review/fix round, `AfterRound` stops at the next safe transition;
an active retrospective finishes its current call before new repair work.
`BeforeCommit` stops before commit gates and preparation, including the no-op
path. `BeforeCompletion` lets final assessment and gates finish before completion.
An already-running test or gate finishes its recovery first. A begun commit can
stop at its durable recovery checkpoint. No model process is cancelled.

Publication confirms only the request. Wait for `paused` (exit code `5`) and the
reported requested/reached boundary. A missed boundary is reported explicitly;
the loop then stops at its next safe point. Keep the ID and retry uncertain
publication with identical arguments and `-Id`. Reached requests are consumed;
other pending pause IDs remain effective after resume.

Take over the checkout only after the loop process has exited and its repository
lease is released. A request or a saved `paused` status alone is insufficient.
Preserve HEAD, refs, index, the saved candidate and recovery artifacts; this pause
does not authorize adopting external code changes into the run. Repair external
prerequisites or investigate the reason, then explicitly repeat the compatible
start command. Keep the saved task, review base and Reviewer instructions as
described above. Do not restart automatically while the reason still exists;
routine user approval is unnecessary within the authorized task.
