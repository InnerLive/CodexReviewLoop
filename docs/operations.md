# Running, monitoring, and recovery

[Back to the README](../README.md)

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
lessons learned were triggered or skipped, how many recommendations were
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

Running the same command resumes the latest compatible checkpoint by default.
Resume requires the same repository, branch, symbolic review base, and `HEAD`.
The base commit recorded at run start remains pinned and must still exist. The
recorded speed is inherited unless an explicit `-Speed standard|fast` selects a
new speed for subsequent calls in the same checkpoint. If the invocation used
`-ReviewerInstructions`, pass the same value again
when resuming. Changing or omitting it requalifies existing review and
clean-pass evidence before the loop can complete.

Architect, Fixer, Verifier, ReviewClassifier, and LessonsLearned each keep a
separate durable Codex thread across invocations of the same run. Older
checkpoints without the role-session map reconstruct it from the latest
successful recorded call for each role. The native Reviewer always starts a
fresh review and is excluded from this migration.

Interrupted fixer work resumes from its recorded thread when possible. If a
Fixer changed files before a resumable thread ID was available, the loop first
preserves that complete Git diff and gives one fresh Fixer the same semantic
attempt. If that recovery also fails, the latest diff is retained as evidence,
the clean checkpoint is restored, and native review starts again. A changed
tool or execution-affecting profile fingerprint resets
clean-pass evidence and starts a fresh native review when the repository is
clean. `MaxReviewCycles`, `MaxFixAttempts`, role settings, host gates, and
commit settings are reloaded at safe boundaries. An interrupted
lessons-learned analysis uses the same role-call checkpoint and repository
postconditions. A changed execution fingerprint requalifies unfinished
analysis, while a successfully completed lessons-learned phase remains
complete. The captured `ReviewAfterLessonsLearnedCommit` value also survives
resume, so an interruption after the final commit cannot change whether
post-commit native reviews are required.

Use `-NewRun` when you deliberately want a new run checkpoint. It still
requires a clean worktree, respects the repository lock, and keeps compatible
finding history. It is not needed to refresh an exhausted Fixer round because
that happens automatically.

## Outcomes

| Status | Exit code | Meaning |
|---|---:|---|
| `completed` | `0` | The clean gate was reached and any eligible lessons-learned phase completed; configured post-commit reviews also passed when required |
| Invocation error | `1` | Validation or preflight failed before a run checkpoint was created |
| `failed` | `2` | An initialized run failed; its latest checkpoint is preserved |
| `limit_reached` | `4` | The configured per-invocation review budget was used; run the same command to continue |

Rejected solutions and exhausted Fixer rounds are not terminal outcomes. After
`MaxFixAttempts` unsuccessful Fixer calls, the loop writes a binary Git patch,
copies untracked files, and records hashes under the run directory. It then
restores only the exact captured Fixer changes, verifies a clean worktree, and
starts another native review. A changed `HEAD`, unexpected paths or contents,
damaged artifacts, submodules, or reparse points are genuine technical failures
and stop cleanup without deleting uncertain state.

`MaxReviewCycles` is deliberately different: it lets a user cap one unattended
script invocation for token or time control. Every new invocation resets only
that cycle counter and retains the checkpoint. Reaching the limit leaves the
checkpoint resumable, does not mark any finding blocked, and the same command
continues with a fresh budget.

The lessons-learned phase does not consume `MaxReviewCycles`. If its Fixer
round reaches `MaxFixAttempts`, the rejected patch is preserved and restored
through the normal cleanup path, the phase stays open, and native review
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
