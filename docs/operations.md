# Running, monitoring, and recovery

[Back to the README](../README.md)

Loop-owned process starts are checked against the [Windows command-line limit](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-createprocessw):
32,767 UTF-16 characters, including the quoted executable, Windows argument
quoting and final NUL. An overlong command fails before starting. This check does
not intercept shell commands started internally by Codex. All six roles receive
the same short instruction to keep each shell call concise. Structured roles
receive it on stdin, including resume; native review appends it to the original
Reviewer guidance. This is guidance, without an artificial 200- or 500-character
limit. Use concise Reviewer
guidance; native review already uses
the pinned base and repository instructions. Shared state, ref inventories and
history are not Reviewer instructions. Structured roles receive the current
task and relevant open work once through stdin, without technical snapshots.
The adapter uses equivalent short flags and paths, retaining model, reasoning,
service tier, authentication, repository scope, schema and result identity.
Artifact basenames use a deterministic CallId digest and role; durable calls retain
the complete CallId and actual file paths, including paths saved before this change.
Changing Reviewer guidance on ordinary resume requalifies the existing run;
it does not turn previous failure or an old clean pass into review success.

## Explicit external ref-change requalification

Ordinary resume stops on a persisted Fixer repository-identity failure before
recovery or initialization writes. Repository identity checks and automatic ref
restoration exclude only `refs/codex/turn-diffs/**`, the Codex desktop's internal
turn snapshots. Branches, tags, and all other refs remain protected. Saved
identity failures remain failures; this exception does not acknowledge an old
failure or authorize rewriting its captured evidence.

An inactive retained candidate captured before this exclusion can resume normally.
The comparison first validates its complete captured ref inventory against its
original fingerprint, then compares the protected refs under the current policy.
The captured snapshot remains unchanged. An old hash without its inventory is
not reinterpreted. Changed protected refs, files, HEAD or index still stop continuation; existing recorded identity
failures still require their explicit recovery path.

When an operator has independently established and approved one exact external
ref delta, `-RequalifyExternalRefChange <package.json>` provides an explicit
requalification boundary. It supports only State 2.0 failed pending Fixers with
complete original Before/After inventories. It cannot reconstruct legacy rows,
acknowledge HEAD/HeadRef changes, restore refs, or make an old role successful.
Use an existing explicit `-ConfigPath`; `-NewRun` is incompatible.

The JSON package has these fields (SHA256 file bindings use uppercase hex):

| Field | Exact binding |
|---|---|
| `SchemaVersion` | `"1.0"` |
| `OperatorApproved` | Boolean `true`, approving only the literal delta |
| `RepoPath`, `RunId`, `CallId`, `ReviewBaseCommit` | Failed checkpoint identity and pinned base |
| `StateSha256` | SHA256 of the checkpoint before transition |
| `Failure` | `{ "Path": "...", "Sha256": "..." }` matching the checkpoint's public failure binding |
| `ApprovedRefDelta` | Complete ordered `{ "Change": "Removed" or "Added", "Row": "..." }` array from that failure, with exact spaces preserved |
| `ApprovedInterveningRefDelta` | Optional exact ordered delta from `Failure.After` to the approved current inventory; defaults to empty |
| `InterveningActorEvidence` | Nonempty independent file bindings required when approving an intervening delta |
| `ExternalActorEvidence` | Nonempty array of independently established actor/approval evidence file bindings |
| `RoleEvidence` | Nonempty array of closed role trace/result/raw-proof file bindings |
| `Ledger` | File binding for the run's shared `ledger-v2.json` |
| `Candidate` | Complete current snapshot: `Head`, `Fingerprint`, `Branch`, `HeadRef`, `RefsFingerprint`, `IndexFingerprint`, `Refs` |

The explicit operation is the operator's acknowledgement of those bound files
and rows. It does not infer causation from their names or automatically verify
a particular vendor's metadata format. The operator must review actual actor,
process-closure, role and candidate evidence before invoking it.

An intervening delta uses the same operation and requires its own independent
actor bindings and literal-row approval. The original failure and original
approved delta remain unchanged. Every current ref must match those two exact
transitions; missing approval means an empty intervening delta. This is not a
namespace exception or a general event-chain mechanism.

First use `-RequalificationDryRun -Json` with the package. During preparation
only, `Candidate` may be null and `StateSha256` empty: the dry run reports exact
prospective pins, not approval of them. Review and fill those pins, then repeat
the dry run with the final package. A dry run performs no checkpoint, ledger,
candidate or ref transition and invokes no model or repository gate.
It opens only an existing lease, exclusively and read-only. A missing lease is
refused without creating a file.

```powershell
pwsh -NoProfile -File .\codex-review-loop.ps1 -RepoPath C:\dev\Project `
    -ConfigPath C:\profiles\Project.psd1 -RequalifyExternalRefChange C:\proof\package.json `
    -RequalificationDryRun -Json
```

Omit only `-RequalificationDryRun` to acknowledge the approved package. Under the
exclusive lease, the operation checks every current ref against the captured
After inventory plus the explicitly approved intervening delta, the original
pending role and failure, candidate bytes/index,
checkpoint, finding ledger, all supplied evidence, branch and base. It rechecks
before the single atomic state transition. Failed checks preserve the candidate
and checkpoint; unconsumed public receipts/backups after an interruption are
not acknowledgement. Repeating an acknowledged package at the unchanged fresh
review boundary is a no-op. Any further ref, file, index or proof change stops.

The successful operation exits `requalified`/0 without models, gates, staging
or commits. It keeps original failed-role evidence, finding/work identities and
candidate backup; resets clean passes and previous assessment/review evidence;
and places that candidate at the existing fresh native-review boundary. Run the
ordinary command separately to obtain fresh native review, current Architect
acceptance, configured host gates and unchanged-HEAD clean passes. Old tests or
the acknowledgement itself are never completion evidence. Prevent further
external ref writers; each later boundary continues to protect repository refs
outside the internal turn-snapshot namespace.

## Before starting

Use a dedicated branch and verify that:

- the target is a Git repository with a clean worktree;
- its configured `ReviewBase` exists;
- the Codex CLI is installed and authenticated;
- every configured host-gate executable is available.

Only one review loop can own a repository at a time.

## Command reference

```powershell
pwsh -File C:\Tools\CodexReviewLoop\codex-review-loop.ps1 `
    -RepoPath C:\dev\MyProject
```

| Option | Values and default | Purpose |
|---|---|---|
| `-RepoPath` | Required | Repository to review and fix; may be positional |
| `-ConfigPath` | Auto-discovered | Select or create a specific profile |
| `-ReviewBase` | Profile or checkpoint value | Override with a Git revision or use conservative `Auto` detection |
| `-TaskContext` | Optional; inherited on resume | Shared original assignment; without one, the Architect reconstructs it from repository evidence |
| `-ReviewerInstructions` | Profile value or empty | Override supplemental native Reviewer developer instructions; an explicit empty string disables the profile value |
| `-Speed` | `standard` (default), `fast` | Global Codex service tier |
| `-CodexPath` | Auto-detected | Use a specific Codex CLI executable |
| `-NewRun` | Off | Start a new run while retaining the finding ledger |
| `-OutputMode` | `compact` (default), `balanced`, `detailed` | Terminal detail |
| `-HeartbeatSeconds` | `30`; `0` disables | Progress refresh interval |
| `-ColorMode` | `Host` (default), `Ansi`, `Always`, `Auto`, `Never` | Terminal colors |
| `-Json` | Off | Emit one JSON result document and no human dashboard |
| `-Help`, `-h` | Off | Show help without creating a profile or run |

`standard` is cost-conscious. `fast` changes the service tier without changing
the configured model or reasoning effort. A resumed checkpoint inherits its
recorded speed when `-Speed` is omitted, so there is no silent fallback. Passing
`-Speed` explicitly changes the same checkpoint for subsequent role and
thread-resume calls.

## Unattended access

All model calls use the locally installed Codex CLI. They run with personal
Codex configuration and command rules ignored, and with approvals and sandbox
checks bypassed. Repository instructions such as `AGENTS.md` still apply.

The fixer may edit the worktree. Analysis roles receive the same command
freedom but are required to leave repository state unchanged; the orchestrator
enforces that postcondition. The orchestrator alone runs authoritative tests,
stages files, and commits.

## Terminal output

| Mode | Shows |
|---|---|
| `compact` | One-line start, relevant progress, and one actionable completion or failure summary |
| `balanced` | Compact output plus repository/run metadata and concise internal failures |
| `detailed` | Full run metadata, diagnostic paths, successful commands, and no-result searches |

Raw model reasoning is never printed. Long-running roles and host gates update
one in-place heartbeat line instead of flooding the terminal.
When the clean gate is reached, compact and balanced output also state whether
the retrospective was triggered or skipped, how many guidance changes were
returned, and whether they entered the normal implementation workflow.

Normal invocations do not append a JSON copy of the result. For automation:

```powershell
$result = pwsh -File C:\Tools\CodexReviewLoop\codex-review-loop.ps1 `
    -RepoPath C:\dev\MyProject `
    -Json | ConvertFrom-Json
```

`-Json` suppresses host rendering and writes exactly one JSON document to
stdout. `-OutputMode` still controls the contents of `terminal.log`.

`terminal.log` contains the selected terminal messages with timestamps and no
color codes. Role JSONL, stderr, structured results, targeted-test logs, and
host-gate logs remain available in the run directory for diagnosis. Common
credential patterns are redacted before persistence, but arbitrary secrets
should never be placed in model-visible command output.

## Resume and `-NewRun`

Resume finishes an interrupted review/fix round, including assessment, gates,
and commit recovery, before starting a new critique. At a completed cycle
boundary, overdue criticism precedes the next review. Old profiles and runs
need no manual conversion: a ready run with 41 completed native reviews and no
prior critique receives one critique of the whole run, then another at 42.
Missed critiques are not replayed individually, and immediately resuming again
does not repeat successful criticism.

An interrupted Fixer with a resumable thread keeps its unfinished patch after a
tool update. Its resumed result must pass the current Architect assessment,
tests, and commit gates before it can be accepted.
Before resuming that thread, its recorded HEAD, symbolic HEAD ref, and complete
ref fingerprint must still match. A known unresolved Fixer identity violation
stops again without changing the candidate, even after a tool update. The
public `*-repository-identity-failure.json` records the changed identity fields,
exact captured ref inventories, and their added/removed rows; the checkpoint
binds this evidence by SHA256. Older calls without captured inventory rows
report that inventory as unavailable rather than reconstructing it. Changing
the execution fingerprint does not authorize rebasing an unknown old ref state.

Use the same resume command and existing Reviewer-instruction override as
before. No special Critic switch or `-NewRun` is needed. An already interrupted
Critic call is recovered independently, even if a legacy checkpoint holds
unfinished Fixer work alongside it. That patch remains incomplete evidence and
is preserved. A tool update requalifies the pending critique under the current
three-recipient contract. Unknown changes and violated repository invariants still prevent unsafe
resume outside the Critic transaction. Critic changes are discarded before
feedback is consumed, including index-only changes. Interrupted calls restore
their saved repository state before the normal resume checks and continue in
the same Critic thread. Critic failures retain both checkpoints and never discard Fixer work;
after the existing technical retries, the run stops with diagnostics rather
than silently skipping the due critique.

Running the same command resumes the latest compatible checkpoint by default.
Checkpoint generations are selected before their status is considered. A newer
completed run supersedes older interrupted calls, including a stale recovery
locator. On its unchanged `HEAD`, the completed checkpoint remains selected;
changed Reviewer instructions or execution settings requalify its clean-pass
evidence in the same run. An unchanged invocation retains completion. A completed
run whose `HEAD` has moved does not revive an older generation.
Resume requires the same repository, branch, recorded symbolic review base,
and `HEAD`. When `-ReviewBase` is omitted, the newest resumable checkpoint for
that repository, profile, and branch supplies its saved base even if the
profile currently contains another value. An explicit `-ReviewBase` resumes
only a checkpoint with that same setting; `-NewRun` always resolves a fresh
base. The base commit recorded at run start remains pinned and must still
exist. The recorded speed is inherited unless an explicit `-Speed
standard|fast` selects a new speed for subsequent calls in the same checkpoint.
If the invocation used `-ReviewerInstructions`, pass the same value again
when resuming. Changing or omitting it requalifies existing review and
clean-pass evidence before the loop can complete.

Architect, Fixer, ReviewClassifier, and LessonsLearned each keep a separate
durable Codex thread across invocations of the same run. Architect advice and
assessment share the Architect thread. Older
checkpoints without the role-session map reconstruct it from the latest
successful recorded call for each role. The native Reviewer always starts a
fresh review and is excluded from this migration.
Resume prompts carry only the new findings, result, or feedback needed for the
next decision. When no valid role session exists, the role receives complete
standalone context instead.
The stable role, goal, workflow, and safety contract is not a session delta:
it is supplied as developer instructions on every role call. Prompts carry the
current phase and evidence, while schemas constrain only the result shape.

Interrupted fixer work resumes from its recorded thread when possible. If a
Fixer changed files before a resumable thread ID was available, the loop first
preserves that complete Git diff and gives one fresh Fixer the same semantic
attempt. If that recovery also fails, the latest diff is retained as evidence,
the owned candidate is retained, and native review starts again. A changed
tool or execution-affecting profile fingerprint resets
clean-pass evidence and starts a fresh native review when the repository is
clean. `MaxReviewCycles`, `MaxFixAttempts`, role settings, targeted-test
repository policy, host gates, and commit settings are reloaded at safe
boundaries. If interrupted commit preparation left the exact recorded fixer
patch staged, requalification first restores a clean index without changing
the verified worktree. An interrupted
lessons-learned analysis uses the same role-call checkpoint and repository
postconditions. A changed execution fingerprint requalifies unfinished
analysis, while a successfully completed lessons-learned phase remains
complete. The captured `ReviewAfterLessonsLearnedCommit` value also survives
resume, so an interruption after the final commit cannot change whether
post-commit native reviews are required.

An interrupted host gate is recovered before the normal resume checks. Its
checkpoint records the gate command, `HEAD`, refs, clean index, exact verified
patch, path classifications, hashes, and regular non-ignored untracked files.
If the gate changed files under the default `Fail` policy, the failure output
lists every path, the absolute active-profile path, and copyable
`RestoreMatching` and `RestoreAll` blocks. After the profile owner selects a
policy and runs the same command again, the saved checkpoint performs the
cleanup and the host gates run again. Cleanup is idempotent across interruption
and refuses concurrent worktree, index, ref, submodule, symlink, reparse-point,
or other non-regular changes. `RestoreAll` requires exclusive repository use
for the gate window.

Targeted tests use the same durable recovery before normal resume checks.
Their profile-wide policy supports only `Fail` and `RestoreAll`. Under `Fail`,
the output gives the absolute profile path and a complete copyable
`TargetedTestRepositoryChanges` block. After changing the profile and rerunning
the same command, cleanup completes and the targeted test is run again. A
configured `RestoreAll` cleans regular file side effects before either a pass
or failure is handled and likewise requires exclusive repository use for the
targeted-test window.

An interrupted native Reviewer is recovered before normal branch, `HEAD`, and
worktree resume checks. Its durable checkpoint restores the branch or detached
`HEAD`, commit, index, tracked files, and non-ignored untracked paths, then a
fresh native review starts. A small locator in the repository's Git directory
allows this checkpoint to be found even if the Reviewer switched branches.
Successful cleanup is intentionally absent from terminal output. A cleanup
that cannot reproduce the exact checkpoint stops safely and remains
idempotently resumable. Other local refs, ignored files, and modified submodule
worktrees are not cleaned automatically.

Critic calls use the same recovery locator, including when a Critic switches
branches. Their additional backup restores local refs, the original index,
and unfinished Fixer files. Older Critic checkpoints without a file backup
can restore a clean worktree or an index-only change while preserving matching
Fixer file contents. Without a backup, `HEAD`, its symbolic ref, and the complete
ref fingerprint must match before any repository cleanup. Dirty file contents
must also match. Index reconstruction is verified in a temporary index before
the real index is changed. If these checks fail, recovery stops without changing
repository refs, the index, or files because the missing original state cannot be
reconstructed safely.
Ignored files and modified submodule worktrees remain outside automatic cleanup.

Use `-NewRun` when you deliberately want a new run checkpoint. It still
requires a clean worktree, respects the repository lock, and keeps compatible
finding history. It is not needed to refresh an exhausted Fixer round because
that happens automatically.

## State upgrade and coordinated tool updates

State version 2.0 keeps the existing `run-v1.json` filename and run references.
A version 1.0 run can upgrade only at a clean, inactive cycle boundary, after
the previous process has actually exited. No active role, Critic, gate recovery,
partial recovery, cleanup, or commit transaction may remain. The old state is
backed up as `run-v1.json.before-work-state-2.0.json`; run identity, review base,
findings, history, and sessions survive. Initial goal clarification runs again
and old completion evidence is invalidated. Older tools cannot read version 2.0.

For a running productive loop, let its operator limit the live review budget and
finish the entire active round with the old tool. Confirm process exit, exit
code, repository cleanliness, locks, and transaction state before changing the
tool checkout. Requalify wrapper bindings while preserving the profile, base,
Reviewer instructions, role settings, and service tier, then resume the same run.
Archived patches are evidence, not automatically accepted work. A completed and
integrated task must not be reopened for the upgrade.

## Outcomes

| Status | Exit code | Meaning |
|---|---:|---|
| `completed` | `0` | The clean gate was reached and any eligible lessons-learned phase completed; configured post-commit reviews also passed when required |
| Invocation error | `1` | Validation or preflight failed before a run checkpoint was created |
| `failed` | `2` | An initialized run failed; its latest checkpoint is preserved |
| `limit_reached` | `4` | The configured per-invocation review budget was used; run the same command to continue |

Rejected solutions and exhausted Fixer rounds are not terminal outcomes. After
`MaxFixAttempts` unsuccessful Fixer calls, the loop saves file contents, new files,
the complete index and provenance in a repository backup with a manifest.
It retains the full owned candidate, verifies its file, index, and ref fingerprints, and starts
another native review against the same base. A changed `HEAD`, unexpected paths or contents,
damaged artifacts, submodules, or reparse points are genuine technical failures
and stop the run without deleting uncertain state.

`MaxReviewCycles` is deliberately different: it lets a user cap one unattended
script invocation for token or time control. Every new invocation resets only
that cycle counter and retains the checkpoint. Reaching the limit leaves the
checkpoint resumable, does not mark any finding blocked, and the same command
continues with a fresh budget.

The lessons-learned phase does not consume `MaxReviewCycles`. If its Fixer
round reaches `MaxFixAttempts`, the candidate is preserved for review,
the phase stays open, and native review
continues. By default, an accepted lessons-learned solution is the final cycle.
With `ReviewAfterLessonsLearnedCommit = $true`, a real lessons-learned commit
resets clean passes and requires the configured native clean reviews again.
An accepted no-op completes immediately in either mode.

`InactivityTimeoutMinutes` defaults to 30. Codex roles, targeted tests, and host
gates may run for any total duration while they continue producing real output.
Heartbeats do not reset the inactivity clock. When the limit is reached, the
loop terminates the owned Windows process tree, uses the normal technical
recovery, and eventually returns to a new native review round instead of
stopping on a finding. Short Git control operations retain separate technical
deadlines.

While the repository lock is held, Windows receives a process-scoped
system-awake signal. It does not keep the display on, change update policy, or
cancel shutdown. The signal is released when the loop exits.

Pressing Ctrl+C writes a final interruption entry to `terminal.log` before the
console process exits whenever Windows delivers the console cancellation
event. The current checkpoint remains available for the next invocation.
Forced process termination and machine crashes cannot guarantee this final log
entry.

## Where to look when a run stops

1. Read the reported problem, `Recommended` action, and safe `Alternative`.
2. Open the single reported detail path when more diagnosis is needed.
3. Fix external prerequisites or repository state without editing the
   checkpoint.
4. Run the same command to resume after repairing the technical problem.

Old dirty `cluster_blocked` checkpoints are not cleaned automatically because
they cannot prove which changes belong to the Fixer. This is legacy recovery,
not an outcome produced by the current workflow.
