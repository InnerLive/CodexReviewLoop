# Codex Review Loop

**Turn AI-generated branch changes into professionally reviewed, tested, and
verified code.**

Codex Review Loop reviews the complete branch diff, fixes evidence-backed
defects, independently verifies each patch, runs the repository's quality
gates, and commits only accepted work. It repeats this process unattended until
the branch is demonstrably clean or reaches a useful checkpoint.

## What it does

1. Reviews the branch for correctness, security, reliability, and material
   performance defects.
2. Tracks findings across review cycles and groups only semantically related
   defects.
3. Applies a bounded fix and requires a targeted regression test.
4. Independently runs the test, verifies the patch, and executes configured host
   gates before committing the exact verified tree.
5. Repeats until two reviews are clean on the same unchanged `HEAD`.

Architecture work is considered only when the evidence supports it. A focused
point fix remains the default.

## Requirements

- Windows with PowerShell 7
- Git
- A locally installed and authenticated Codex CLI
- A clean Git worktree when starting a new run

## Quick start

> [!WARNING]
> Codex runs unattended with approval and sandbox checks bypassed. The loop may
> edit and commit the target repository. Use a dedicated branch with a clean
> worktree, and make sure the profile's `HostGates` cover the checks your project
> requires.

```powershell
git clone https://github.com/InnerLive/CodexReviewLoop.git C:\Tools\CodexReviewLoop
Set-Location C:\Tools\CodexReviewLoop

pwsh -File .\codex-review-loop.ps1 -RepoPath C:\dev\MyProject
```

The first invocation finds an existing profile or creates a commented one and
starts the run. By default, the loop uses the cost-conscious `standard` speed
and compact terminal output.

The latest compatible checkpoint is resumed automatically. Use `-NewRun` only
when you deliberately want a fresh run; the finding ledger is retained.

## Learn more

- [How the loop works](docs/how-it-works.md)
- [Profiles and configuration](docs/configuration.md)
- [Running, monitoring, and recovery](docs/operations.md)

For the complete command reference:

```powershell
pwsh -File .\codex-review-loop.ps1 -Help
```

## License

Copyright 2026 InnerLive.

Codex Review Loop is licensed under the
[Apache License 2.0](LICENSE). Using the tool does not change the license of
the repository being reviewed.
