# How Codex Review Loop works

[Back to the README](../README.md)

The loop reviews and improves the complete branch diff from a pinned
`ReviewBase` commit, including a retained, uncommitted Fixer candidate.

A persisted Fixer ref-identity failure remains fail-closed on ordinary resume.
An independently evidenced external delta can only be acknowledged by the
[explicit public requalification operation](operations.md#explicit-external-ref-change-requalification).
It preserves the failed role and candidate and requests fresh native review;
it never converts old role/test evidence into acceptance or ignores a ref class.

`ReviewBase = 'Auto'` resolves only when a new durable run starts. It first
uses branch-creation reflog evidence, then a unique nearest ancestor branch,
and otherwise falls back to the normal `origin/HEAD`, main/master, `HEAD^`, or
`HEAD` selection. A resumed run keeps the symbolic base and commit recorded in
its checkpoint.

An external supervising Operator can send one-time evidence to explicitly
selected working roles through the [durable operator channel](operations.md#operator-messages).
It uses the existing role contexts and acceptance path. Optional required
delivery can return the workflow to those roles before a sealed transaction;
the Operator never writes authoritative checkpoints or grants acceptance.

The same channel supports controlled pauses after a role, after a complete
review/fix round, before commit preparation, and before final completion.
Publication is distinct from reaching the halt. Completed results and the exact
continuation are checkpointed, dirty candidates are backed up, and active
transactions finish or remain at their durable recovery point. Normal pause
requests never cancel a model process. See [pause operation and resume](operations.md#controlled-operator-pauses).

## Periodic Critic

Starting after five successfully completed, distinct native reviews by default,
an independent Critic examines the evidenced run after every finished review/fix
round and returns separate free-form feedback to the Reviewer, Architect, and
Fixer. It receives the retrospective, role timings and reported token usage,
result artifact paths, loop commits, available
task guidance, and all recipients' previous critiques. Each critique starts a
fresh thread; only an interrupted critique resumes its own thread.

The Critic is an impatient, technically grounded adviser. It receives no
diagnostic checklist or prescribed investigation method. It judges working
practices and collaboration, not code as an additional Reviewer. It cannot edit
the repository, create or resolve findings, accept patches, or veto decisions.
Each recipient receives only its own latest
feedback. Existing role instructions and Architect advice remain in force.
Evidence-backed praise is valid feedback. The Critic need not recommend changes
when the current approach works well and must not demand optimization for its own sake.
An accepted patch or green suite does not by itself show that a recurring
working-practice failure has been corrected. Unresolved criticism remains direct
until the evidence supports recovery; it calls for change at the next relevant
decision, not only after another defect appears.

The Critic knows that its feedback persists across subsequent recipient calls
until replaced. Delivery identifies the completed-review count on which the
critique was based. Recipients must reconcile applicable criticism with current
evidence and explain the resulting change in their existing output, or give a
concrete reason the concern is resolved or inapplicable. Agreement or a promise
alone is insufficient. Their independent judgment, output contracts, and decision
responsibilities remain unchanged. This context also accompanies critiques saved
before the tool update; their original text remains unchanged.

Critiques run between review/fix rounds, before the next review. Completion
takes precedence, and an exhausted invocation budget leaves overdue criticism
for resume. The durable count ignores failed calls and repeated attempts of
the same native review. Feedback does not reset clean passes or consume the
review budget. New criticism never interrupts a Fixer attempt, Architect
assessment, gate, or commit, including on resume. `CriticStartAfterReviews = 0`
disables new critiques; saved feedback remains available and an interrupted
critique is still recovered.

Critic output and its covered review count are saved atomically with the role
result. Its own active-call checkpoint preserves an interrupted work role.
Each Critic call is a repository transaction: the loop backs up the index,
local refs, and any unfinished Fixer files before the call, then discards Critic
mutations and verifies the original state before accepting feedback. Cleanup
also runs on technical failure and before resuming an interrupted critique.
Successful cleanup is silent and preserves the critique's thread and all
pre-existing Fixer work. An unverifiable restoration stops with the recovery
checkpoint intact.
All three addressed feedback texts appear in the terminal, without internal model
reasoning. Lessons Learned remains the separate completion-time analysis for
durable repository guidance. Historical schema 1.0 critiques retain their two
original texts; they supply no Fixer feedback. New schema 2.0 critiques require
all three texts and replace the feedback delivered on subsequent role calls.
Existing session history is not rewritten. Each recipient call records the
critique ID actually delivered; old results are not relabeled as new decisions.

## Shared goal and architecture work

Before the first native review, the existing Architect reconstructs the intended
behavior from the branch diff, commit messages, source, tests, and documentation.
Optional `TaskContext` supplies the original assignment. Explicit requirements,
repository evidence, and remaining uncertainties stay distinguishable; existing
code is not automatically the specification.

The versioned run state stores this goal and architecture orders with stable IDs,
rationale, evidence, completion criteria, and status. The Architect may create
necessary work without a native finding, but must justify its connection to the
goal or a defect cause. Omitting an order never closes it. Every working role,
including resumed sessions, receives the compact current goal and open orders.
Larger artifacts are referenced instead of replayed.

## The cycle

```mermaid
flowchart LR
    orient[Architect clarifies goal] --> review[Native review of full candidate]
    review --> parse{Clear result?}
    parse -- Ambiguous --> classify[ReviewClassifier]
    parse -- Clear --> work{Findings or open work?}
    classify --> work
    work -- Yes --> architect[Architect bundles necessary work]
    architect --> fix[Fixer]
    fix --> test[Targeted test]
    test --> verify[Independent Architect assessment]
    verify -- Reject within budget --> fix
    verify -- Attempt limit --> retained[Preserve complete candidate]
    retained --> review
    verify -- Accept --> gates[Host gates and exact-tree commit]
    gates --> clean{Completion evidence sufficient?}
    work -- No, retained candidate --> verify
    work -- No, clean accepted tree --> clean
    clean -- No --> review
    clean -- Yes --> lessons[Eligible lessons-learned phase]
    lessons -- Necessary guidance work --> architect
    lessons -- Done or ineligible --> goal[Architect judges overall goal]
    goal -- Necessary work --> architect
    goal -- Fulfilled, gates pass --> done[Complete]
```

## 1. Native review

The Reviewer is Codex's native review function. The loop supplies the
repository and configured review base, but no positional reviewer prompt or
output schema. Optional `ReviewerInstructions` are supplied as supplemental
developer instructions without replacing the native `review --base` workflow.
Every native review starts fresh; Reviewer threads are deliberately not reused.

The native Reviewer is treated as a repository transaction. Each call starts
from a clean checkpoint or the exact owned, retained Fixer candidate. Dirty
candidates receive a backup of files, index, and refs before the native review. If the Reviewer changes the active branch or
`HEAD`, the index, tracked files, or non-ignored untracked paths, the loop
silently restores that exact checkpoint before consuming the review text. A
successful review remains usable after cleanup. If exact restoration cannot be
verified, the call is not accepted and the run stops with its recovery
checkpoint intact. Analysis roles other than Reviewer and Critic retain their strict no-mutation
failure behavior.

The loop first recognizes established finding and clean signals locally. If
the text is ambiguous, the mechanical `ReviewClassifier` helper uses the
configured Luna model to return one boolean. It has no confidence threshold,
confirmation, tie-break, or Architect fallback. A helper failure is reported
as a technical failure.

Review text classified as containing findings is passed unchanged to the
Architect. The ledger stores a history copy, but historical states never
suppress findings from the current native review. A clean native review
advances the clean-pass counter only when no architecture work or unaccepted
candidate remains. It cannot substitute for Architect acceptance.

## 2. Free architecture advice

The Architect receives the current findings text, repository context, and up
to 50 recent history entries. The findings text is unchanged native review
output during ordinary cycles and the complete structured analysis during the
lessons-learned phase. Its developer instructions define the role and decision
contract without prescribing a point fix, redesign, or scope.
The Architect keeps one dedicated Codex thread for the durable run, so later
cycles retain its architectural reasoning in addition to the explicit history.
The first call supplies recent ledger history. Later calls send only the new
findings and current repository context; if no Architect thread is available,
the complete bootstrap context is supplied again.

Role context has three distinct owners. Developer instructions sent on every
call define the durable role, goal, workflow, decision criteria, and ownership
boundaries. The prompt identifies the current phase and carries new evidence.
The JSON schema defines only the shape and required fields of the result. This
keeps the quality contract current even in long or compacted threads while
avoiding repeated findings, history, advice, and results.
All fixed developer-instruction, phase, and technical-recovery prompt text is
versioned as Markdown under `prompts/`; PowerShell only selects templates and
supplies dynamic values.

The structured Architect response is passed unchanged to the Fixer. After each
Fixer result, the same Architect thread assesses the resulting repository state.
The periodic Critic supplies advice only; there is no judge, confirmation,
veto, or tie-break role in the acceptance path.

## 3. Fixing without a blocked finding state

The Fixer receives the current findings, the Architect response, and any
feedback from the previous Architect assessment. It chooses the changes and exploratory tests.
Git determines which files actually changed.
Its dedicated Codex thread is reused across attempts and finding clusters in
the same durable run.
The first call for each cluster supplies the findings and Architect advice.
Corrections in the same thread send only new feedback. A fresh recovery thread
receives the complete context again.

`MaxFixAttempts` limits Fixer calls in one review round. At the limit, the loop
archives and fingerprints the full candidate, including new files and index,
and retains it for the next native review against the same base. The limit
alone never discards progress. Unexpected changes stop the run. A clean review
of this candidate leads to independent Architect assessment, tests, gates, and
commit before ordinary clean passes can count.

If a Fixer process leaves partial changes before a resumable thread ID is
available, those changes are preserved and one fresh Fixer completes the same
semantic attempt. A second technical failure preserves the latest evidence,
retains the owned candidate, and returns to native review.

The Fixer may provide one targeted test through `targetedTest.executable` and
`targetedTest.arguments`. The executable is the program started by the
orchestrator, such as `dotnet`, `pwsh`, or a repository wrapper. Project,
script, test, and filter paths are arguments. The Fixer may also report that no
targeted test is available. The loop durably snapshots the Fixer worktree
before an available test. Repository mutations fail by default. With
`TargetedTestRepositoryChanges.Mode = 'RestoreAll'`, regular test side effects
are discarded and the exact Fixer worktree is restored before the test result
is processed. Git identity, index, and special-filesystem mutations remain
technical failures.

## 4. Architect assessment

The orchestrator runs an available targeted test and records the actual result.
The Architect inspects the current repository and receives the Fixer response
and test evidence in its existing durable thread, where the findings and
earlier advice are already available.
The advice is context, not a conformance requirement: a better Fixer deviation
may be accepted when the repository state satisfactorily resolves the findings.
Normal assessment resumes send only the Fixer and test result. Without a
durable Architect thread, recovery repeats the findings, advice, and current
repository context so the assessment remains self-contained.

The Architect selects existing orders with its advice and explicitly assesses
selected orders after implementation. New necessary orders may arise during
assessment. Accepted or justified withdrawn orders become durable only after
gates and any required exact-tree commit. An accepted no-op follows the same
gate path. Results are bound to the repository snapshot and goal revision.

The Architect decides directly:

- `accept = true` continues to host gates and commit.
- `accept = false` sends its feedback back to the Fixer.

For an accepted patch, it also proposes the semantic commit subject, rationale,
and key changes. It does not own test claims or Git metadata.

There are no confidence thresholds, majority decisions, or adjudication roles.

All other structured roles likewise retain their own independent thread for
the durable run. Threads are never shared between roles.

## 5. Gates and commit

Configured `HostGates` run after acceptance and before every commit. The loop
durably snapshots the verified worktree before each gate. The default policy
rejects any gate mutation. A gate configured with `RestoreMatching` or
`RestoreAll` may discard only regular file side effects covered by that policy;
the loop restores and fingerprints the complete pre-gate tree before
continuing. Gate changes to Git identity or special filesystem entries always
fail without cleanup. The loop then rechecks the patch, stages the exact
verified worktree, seals that Git tree, and advances `HEAD` only if the expected
old value still matches.

After the gates pass, the orchestrator builds the final commit message from the
Architect assessment proposal and the test and gate results it directly observed. It
redacts secrets, records all findings handled by a multi-finding patch, seals
the complete message in the checkpoint, and verifies the full committed
message during crash recovery.

The orchestrator owns authoritative tests, staging, and commits. Analysis roles
must leave the repository unchanged, and the Fixer may edit the worktree but
may not create commits or change refs.
One ref capture supplies both the complete native inventory and the existing
ref fingerprint. Fixer identity failures publish both snapshots and their ref
delta, and remain unresolved across resume. Resuming a pending Fixer checks its
recorded identity before taking a new role-start snapshot; uncertain refs never
become a new accepted baseline. Candidate files remain intact on this failure.

## Completion and genuine failures

Completion also requires no current findings, open architecture orders,
unaccepted candidate, or pending transaction, and an explicit Architect judgment
of the overall goal on the exact current tree and context revision. A valid
judgment is reused. No additional approval role is introduced.

Completion requires the configured number of consecutive clean native reviews
on an unchanged `HEAD`; two is the recommended default. Every commit or other
`HEAD` change resets the clean-pass count.

At that clean gate, `LessonsLearnedCommitThreshold` is reloaded. When the run
has created at least that many verified, non-empty commits and the current
`HEAD` tracks an exact root `AGENTS.md`, one read-only `LessonsLearned` call
reviews a compact retrospective of the complete evidenced run. It receives
per-cycle review results, findings, Architect summaries and assessments, Fixer attempts,
resolution commits, technical-failure counts, and diff
growth alongside the verified loop commit SHAs and subjects. Raw JSONL,
stderr, internal reasoning, and prior retrospective results are excluded.
Zero disables the phase.

The analyst diagnoses why repeated work was needed, assesses the effectiveness
of existing repository guidance, and selects the smallest broadly reusable net
change. It can add, update, consolidate, or delete guidance in an applicable
`AGENTS.md` or repository skill under `.agents/skills/<name>/`. Process-only
diagnoses remain visible but do not become cross-repository work. The prompt is
self-contained and does not depend on plugins, network access, personal skills,
or global Codex configuration.

An empty `changes` list completes the phase without another role call.
Otherwise, each guidance change becomes a normal ledger finding and the full
diagnosis is passed to the Architect. Architect advice, Fixer, targeted test, assessment,
host gates, and commit behavior remain unchanged. An accepted no-op solution
completes the phase without increasing the commit count. A real accepted
commit is recorded as another verified loop commit. By default, the accepted
solution is the final cycle and the run completes immediately. Setting
`ReviewAfterLessonsLearnedCommit = $true` before analysis starts instead resets
clean passes and requires native clean reviews again after a real commit.
Accepted no-op solutions always complete directly. A completed lessons-learned
phase is not repeated for the durable run.

There is no semantic blocked outcome. Rejected fixes, old blocked ledger
entries, and stale clean checkpoints cause another native review rather than
stopping the run.

`MaxReviewCycles` remains an explicit per-invocation token and time budget.
Every new script invocation resets that counter while retaining the checkpoint.
Reaching it returns a resumable `limit_reached` result without changing finding
status. Running the same command again therefore continues with a fresh budget.
The supplemental lessons-learned call is not a native review cycle and does not
consume this budget.

The run may still fail when continuing would risk the repository or make the
result technically untrustworthy, for example a changed `HEAD`, an unexpected
dirty worktree, a broken Git repository, a failed Codex process lifecycle, or
an invalid structured response from a role that has a schema. These failures
preserve diagnostic state instead of claiming success or silently discarding
unknown work.
