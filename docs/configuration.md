# Profiles and configuration

[Back to the README](../README.md)

Configuration is stored in a PowerShell data file (`.psd1`). A profile binds
the review base, logs, quality gates, and Codex roles to a repository.

## Profile discovery

Without `-ConfigPath`, the loop checks:

1. `<repository>\.codex-review-loop.psd1`
2. `<repository>\.codex\review-loop.psd1`
3. The tool's `profiles\` directory for a profile whose `RepositoryPath`
   matches the canonical Git root

If no profile matches, the loop creates and immediately uses a commented
profile such as `profiles\MyProject-001.psd1`. Repositories with the same folder
name receive separate numbered profiles.

An explicit missing `-ConfigPath` is also created automatically. A profile with
a `RepositoryPath` cannot be used for another repository.

## Important settings

| Setting | Generated value | Purpose |
|---|---:|---|
| `Name` | Repository name | Profile and run-directory name |
| `RepositoryPath` | Canonical Git root | Prevents profile collisions |
| `ReviewBase` | Detected Git revision | Revision reviewed against |
| `ReviewerInstructions` | Empty string | Optional supplemental native Reviewer developer instructions |
| `LogRoot` | `.\runs` | Ledger, checkpoints, and logs |
| `CleanPassesRequired` | `2` | Live-reloaded completion gate |
| `MaxReviewCycles` | `12` | Native review calls allowed per script invocation |
| `LessonsLearnedCommitThreshold` | `6` | Verified loop commits required for the conditional completion analysis; `0` disables it |
| `ReviewAfterLessonsLearnedCommit` | `$false` | Require normal clean native reviews after a real lessons-learned commit |
| `MaxFixAttempts` | `2` | Live-reloaded Fixer calls before returning to native review |
| `InactivityTimeoutMinutes` | `30` | Live-reloaded child-process inactivity limit; zero or less disables it |
| `TargetedTestRepositoryChanges` | `Fail` | Live-reloaded policy for repository changes made by model-selected targeted tests |
| `AutoCommit` | `$true` | Live-reloaded commit behavior |
| `CommitMessagePrefix` | `Review-Loop` | Live-reloaded prefix for future verified commits |
| `HostGates` | Detected checks | Required checks before every commit |
| `Roles` | Pinned model settings | Model and reasoning level per role; live-reloaded at role boundaries |

Relative `LogRoot` paths are resolved against the Codex Review Loop
installation, not the current shell directory or reviewed repository.

Generated numeric values are recommendations, not enforced policy. Useful
starting points are:

- `CleanPassesRequired`: 2-3
- `MaxReviewCycles`: 6-30
- `LessonsLearnedCommitThreshold`: 6 (`0` disables the phase)
- `MaxFixAttempts`: 2-5
- `InactivityTimeoutMinutes`: 15-120

The loop accepts integer values outside these ranges. The profile owner chooses
the tradeoff appropriate for the repository and run.

`MaxReviewCycles` is a user-controlled token and time budget for one script
invocation. Every new invocation resets this counter to zero while retaining
the existing checkpoint. Reaching the limit returns `limit_reached` without
blocking findings; running the same command continues with a fresh budget.

With `AutoCommit = $true`, the loop commits the exact verified tree after all
host gates pass. With `AutoCommit = $false`, it stages that verified tree and
stops at a resumable checkpoint. The user may create the prepared commit
manually, or enable `AutoCommit` and resume the same run.

The Architect assessment proposes a solution-oriented subject, rationale, and list of
changes for an accepted patch. The orchestrator redacts and normalizes that
content, prepends `CommitMessagePrefix`, and adds only the targeted-test and
host-gate evidence that it actually observed passing. Multiple findings are
listed when one accepted patch resolves them together. The complete message is
sealed in the pending-commit checkpoint before Git creates the commit.

## Changes during an active run

The loop reloads these settings from the active profile at safe role, review,
fix, and commit boundaries:

- `CleanPassesRequired`
- `MaxReviewCycles` applies before the next native review call.
- `LessonsLearnedCommitThreshold` applies when the clean-pass completion gate
  is reached.
- `ReviewAfterLessonsLearnedCommit` is captured when an eligible
  lessons-learned analysis starts. The default `$false` makes an accepted
  lessons-learned solution the final cycle. `$true` requires normal clean
  native reviews after a real commit; accepted no-op solutions still complete
  directly.
- `MaxFixAttempts` applies before the next Fixer call. Reaching it restores the
  rejected round and starts another native review; it never blocks a finding.
- `InactivityTimeoutMinutes` applies when the next role, targeted test, or host
  gate starts. It is not changed underneath an already running process.
- `TargetedTestRepositoryChanges` applies to the next targeted test and to
  recovery from an interrupted targeted test.
- `AutoCommit`
- `CommitMessagePrefix` applies to the next commit that has not yet entered
  commit preparation. A pending commit keeps its complete sealed subject and
  body.
- `HostGates` applies to future accepted patches.
- `Roles` applies to future role calls.

These settings are excluded from the execution fingerprint because changing
them does not invalidate review, test, or verification evidence.

Other settings remain fixed for an active invocation. In particular, changing
`Name`, `RepositoryPath`, `ReviewBase`, or `LogRoot` changes run identity. The
loop preserves its checkpoint and requires the same command to be run again so
that the change is applied with the normal resume checks.

`ReviewerInstructions` is also fixed for the invocation and participates in
the execution fingerprint. `-ReviewerInstructions <text>` overrides the profile
when explicitly bound; an explicitly empty value disables the profile value.
The same override must be passed again when resuming. A shadowed profile value
does not affect the fingerprint. The instruction text is not written to the
terminal or checkpoint; only its effect on the execution fingerprint is kept.

## Targeted tests

Model-selected targeted tests fail safely when they change the repository by
default. Repositories whose test tooling has disposable file side effects may
opt into restoring every regular change made during the targeted-test window:

```powershell
TargetedTestRepositoryChanges = @{
    Mode = 'RestoreAll'
}
```

Only `Fail` and `RestoreAll` are supported here, so no path pattern has to be
guessed for a command selected dynamically by the Fixer. Existing profiles use
`Fail` implicitly. `RestoreAll` assumes the loop has exclusive use of the
repository while the targeted test runs. It restores the exact saved Fixer
worktree before the test result is evaluated; a successful test may continue,
while a failed test remains a normal targeted-test failure after cleanup.

Changes to Git identity, refs, the index, or special filesystem entries are
never restored automatically. When `Fail` detects a regular file mutation, the
message names every changed path and the absolute profile path and provides the
complete top-level `TargetedTestRepositoryChanges` block to copy. After changing
the profile, run the same command again; the saved checkpoint performs cleanup
before rerunning the targeted test.

## Host gates

Every gate has a display name, an executable, and an argument array:

```powershell
HostGates = @(
    @{
        Name = 'Unit tests'
        FilePath = 'dotnet'
        Arguments = @('test', '.\tests\Project.Tests.csproj', '--no-restore')
    }
    @{
        Name = 'Git diff check'
        FilePath = 'git'
        Arguments = @('diff', '--check')
    }
)
```

Executables may be normal commands or repository wrappers. Relative executable
paths resolve from the reviewed repository root. Gates are validated before the
first Reviewer starts and use the configured inactivity timeout.

Repository changes made by a gate fail safely by default. A gate may opt into
restoring known disposable side effects without changing the reviewed
repository:

```powershell
@{
    Name = 'Generator tests'
    FilePath = 'dotnet'
    Arguments = @('test', '.\tests\Generator.Tests.csproj')
    RepositoryChanges = @{
        Mode = 'RestoreMatching'
        PathRegex = @(
            '^Source/Framework/PrimeFact5\.SourceGenerator/packages\.lock\.json$'
        )
    }
}
```

`RepositoryChanges` supports three modes:

- `Fail` is the default for existing and new gate entries. Any repository
  change stops the loop and leaves every path untouched.
- `RestoreMatching` requires at least one `PathRegex`. Every path changed by
  the gate must match at least one expression; otherwise nothing is restored.
- `RestoreAll` restores every regular tracked or non-ignored untracked file
  change observed during the gate. This is substantially riskier: it assumes
  the loop has exclusive use of the repository for the complete gate window.

Paths are repository-relative and use `/`. Matching is case-insensitive and
culture-invariant on Windows and has a finite timeout. Expressions should be
exactly anchored whenever possible. `Fail` and `RestoreAll` do not accept
`PathRegex`. Invalid modes, value types, empty lists, and invalid expressions
are rejected when the profile loads.

Before each host gate, the loop durably saves the exact verified patch and its
regular non-ignored untracked files. An allowed side effect is restored to that
snapshot and can never enter the commit. Changes to `HEAD`, branches, refs, or
the index, and submodules, symlinks, reparse points, or other non-regular paths
are never restored automatically.

The generated profile always includes `git diff --check`. When exactly one
`.sln` or `.slnx` exists at the repository root, it also includes `dotnet test`
for that solution. Add every project-specific check needed to trust a commit.

The loop creates commits through Git plumbing, so normal porcelain commit hooks
do not run. Required unattended checks belong in `HostGates`.

## Review base

The generated profile tries `origin/HEAD`, common `main` or `master` references,
then `HEAD^` and `HEAD`. The selected symbolic revision is resolved to a commit
when the run starts and remains pinned for that run.

Change `ReviewBase` when the branch should be compared with a different
integration point.

## Role and speed settings

New profiles contain these workflow and analysis roles:

- `Reviewer`
- `LessonsLearned`
- `Architect`
- `Fixer`

They also contain `ReviewClassifier`, a mechanical helper used only for
ambiguous native review text. Its generated setting is `gpt-5.6-luna` with
`low` reasoning. Existing profiles without this entry use that same default
automatically.

`LessonsLearned` uses `gpt-5.6-sol` with `high` reasoning. It runs only at the
conditional completion gate and is read-only. Existing profiles without this
entry use the same default automatically.

Each entry contains:

- `Model`: a model ID supported by the installed Codex CLI
- `Thinking`: `low`, `medium`, `high`, `xhigh`, or `max`

`-Speed standard|fast` controls the service tier without changing models or
reasoning levels. When resuming, omitting the parameter inherits the speed from
the checkpoint. Passing it explicitly changes the speed for subsequent role
and thread-resume calls while retaining the same checkpoint and ledger.

Existing profiles remain usable during the transition: `PointFixer` supplies
the `Fixer` configuration when `Fixer` is absent. Old `Verifier` and
`FindingVerifier` entries are ignored alongside removed judge, confirmation,
critic, veto, and tie-break entries.

Tool, prompt, schema, and execution-affecting profile settings are
fingerprinted. If they change between invocations, completed model work is
requalified before any commit. The live settings described above are excluded.
