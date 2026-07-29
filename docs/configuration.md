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
| `LogRoot` | `.\runs` | Ledger, checkpoints, and logs |
| `MaxReviewCycles` | `12` | Live-reloaded hard bound for review cycles |
| `CommitMessagePrefix` | `Review-Loop` | Live-reloaded prefix for future verified commits |
| `HostGates` | Detected checks | Required checks before every commit |
| `Roles` | Pinned model settings | Model and reasoning level per role |

Relative `LogRoot` paths are resolved against the Codex Review Loop
installation, not the current shell directory or reviewed repository.

Several values are deliberate invariants rather than tuning knobs:

- `CleanPassesRequired = 2`
- `MaxFixAttempts = 2`
- `MaxArchitectureRevisions = 1`
- `AutoCommit = $true`

Profiles that weaken these values are rejected.

## Changes during an active run

The loop reloads two settings from the active profile at role and review-cycle
boundaries:

- `MaxReviewCycles` applies before the next review cycle. Increasing it lets the
  current checkpoint continue without stopping. Lowering it below the number of
  cycles already used stops at the normal maximum-cycle checkpoint.
- `CommitMessagePrefix` applies to the next commit that has not yet entered
  commit preparation. A pending commit keeps its sealed message.

These settings are excluded from the execution fingerprint because changing
them does not invalidate review, test, or verification evidence.

Other settings remain fixed for an active invocation. In particular, changing
`Name`, `RepositoryPath`, `ReviewBase`, `LogRoot`, `HostGates`, or `Roles`
changes run identity or execution evidence. The loop preserves its checkpoint
and requires the same command to be run again so that the change is applied
with the normal resume checks.

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
first Reviewer starts, must finish within 30 minutes, and must not mutate the
verified patch or Git state.

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

Each entry under `Roles` contains:

- `Model`: a model ID supported by the installed Codex CLI
- `Thinking`: `low`, `medium`, `high`, `xhigh`, or `max`

`-Speed standard|fast` controls the service tier globally. It does not silently
change models or reasoning levels, and a resumed run must keep its original
speed.

Tool, prompt, schema, and execution-affecting profile settings are
fingerprinted. If they change between invocations, completed model work is
requalified before any commit. The live settings described above are excluded.
