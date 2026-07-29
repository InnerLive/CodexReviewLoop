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
| `-Speed` | `standard` (default), `fast` | Global Codex service tier |
| `-CodexPath` | Auto-detected | Use a specific Codex CLI executable |
| `-NewRun` | Off | Start a new run while retaining the finding ledger |
| `-OutputMode` | `compact` (default), `balanced`, `detailed` | Terminal detail |
| `-HeartbeatSeconds` | `30`; `0` disables | Progress refresh interval |
| `-ColorMode` | `Host` (default), `Ansi`, `Always`, `Auto`, `Never` | Terminal colors |
| `-Json` | Off | Emit one JSON result document and no human dashboard |
| `-Help`, `-h` | Off | Show help without creating a profile or run |

`standard` is cost-conscious. `fast` applies to every role and resumed call
without changing the configured model or reasoning effort. There is no silent
fallback between speeds.

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
Resume requires the same repository, branch, symbolic review base, `HEAD`, and
speed. The base commit recorded at run start remains pinned and must still
exist.

Interrupted fixer work can resume from its recorded thread and remaining
attempt. A changed tool or execution-affecting profile fingerprint resets
clean-pass evidence and forces completed model work to be requalified before
commit. `MaxReviewCycles` and `CommitMessagePrefix` are live profile settings;
they are reloaded at safe boundaries without invalidating the checkpoint.

Use `-NewRun` when a blocked or interrupted finding should receive a fresh
two-attempt budget. It still requires a clean worktree, respects the repository
lock, and keeps compatible finding history. It is not a way to discard the
ledger or bypass safety checks.

## Outcomes

| Status | Exit code | Meaning |
|---|---:|---|
| `completed` | `0` | Two clean passes on unchanged `HEAD`; no open or blocked findings |
| Invocation error | `1` | Validation or preflight failed before a run checkpoint was created |
| `failed` | `2` | An initialized run failed; its latest checkpoint is preserved |
| `blocked` | `3` | The loop cannot safely claim completion; checkpoint preserved |

Independent clusters continue after one cluster is blocked. The run stops as
blocked only after useful independent work is exhausted or a hard invariant
requires it.

After the second unsuccessful fix attempt, the loop writes a binary Git patch,
copies untracked files, and records hashes under
`<RunRoot>\blocked\<ClusterId>-attempt-<n>`. It then restores only the exact
captured fixer changes, verifies a clean worktree, and continues independent
clusters. Cleanup can resume after a crash. A changed `HEAD`, unexpected paths
or contents, damaged artifacts, submodules, or reparse points stop cleanup
without deleting the uncertain state.

Each Codex process attempt has a 45-minute timeout; technical retries can make a
complete role take longer. Each targeted test and host gate has a 30-minute
timeout. On timeout or cancellation, the loop terminates its owned Windows
process tree and preserves the latest valid checkpoint.

## Where to look when a run stops

1. Read the reported problem, `Recommended` action, and safe `Alternative`.
2. Open the single reported detail path when more diagnosis is needed.
3. Fix external prerequisites or repository state without editing the
   checkpoint.
4. Run the same command to resume, or use `-NewRun` only when a fresh semantic
   attempt budget is intentional.

Old dirty `cluster_blocked` checkpoints are not cleaned automatically because
they cannot prove which changes belong to the fixer. Their failure guidance
provides a concrete `git stash push --include-untracked` and `-NewRun` route,
plus the alternative of deliberately inspecting, committing, or reverting the
changes.
