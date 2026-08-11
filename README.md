# Codex Review Loop

**Turn AI-generated branch changes into professionally reviewed, tested, and
verified code.**

Codex Review Loop uses Codex's native review function on the complete branch
diff, lets free Architect and Fixer roles choose the solution, asks a Verifier
to accept or reject it, runs the repository's quality gates, and commits only
accepted work. It repeats unattended until the branch is demonstrably clean.
After enough verified loop commits, it can also extract evidence-backed lessons
into repository guidance before declaring the run complete.

## What it does

1. Runs native Codex review without a positional reviewer prompt or JSON schema;
   optional supplemental developer instructions may come from the profile or CLI.
2. Recognizes clear results locally and asks a small Luna helper only when the
   review text is ambiguous.
3. Passes review output containing findings unchanged to an Architect.
4. Passes the Architect's advice unchanged to a Fixer.
5. Lets a Verifier directly accept the solution or return feedback to the Fixer.
6. Executes configured host gates and commits the exact accepted tree.
7. Starts a new native review instead of blocking when a Fixer round is
   exhausted.
8. Repeats until the configured number of reviews are clean on the same
   unchanged `HEAD` (two is the recommended default).
9. Before completion, conditionally analyzes verified loop commits for durable
   `AGENTS.md` or repository-skill guidance.
10. Sends any recommendations through the same Architect, Fixer, Verifier,
    host-gate, and commit path. An accepted solution is the final cycle by
    default; profiles may opt into clean native reviews after a real commit.

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

Use `ReviewerInstructions` in the profile for repository-specific guidance, or
pass `-ReviewerInstructions '<text>'` for one invocation. An explicitly passed
value wins, and `-ReviewerInstructions ''` disables the profile value.

The latest compatible checkpoint is resumed automatically. Use `-NewRun` only
when you deliberately want a fresh run; the finding ledger is retained.
Resume inherits the checkpoint's service tier unless `-Speed standard|fast` is
passed explicitly to change subsequent calls in that same run.

During unattended runs Windows is kept awake without keeping the display on or
changing update policy. Long-running roles and tests are limited by inactivity,
not by their total duration; the generated profile recommends 30 minutes.

Normal invocations print only the human dashboard. Automation can request one
machine-readable result document and no terminal dashboard with `-Json`.

## Learn more

- [How the loop works](docs/how-it-works.md)
- [Profiles and configuration](docs/configuration.md)
- [Running, monitoring, and recovery](docs/operations.md)

## Optional global working agreements

The repository includes a small set of reusable Codex working agreements in
[`docs/smallest-complete-work.md`](docs/smallest-complete-work.md). Install or
refresh them at the beginning of your global `AGENTS.md` with either script:

```powershell
pwsh -File .\install-global-agents.ps1
```

```bash
bash ./install-global-agents.sh
```

The installers use `$CODEX_HOME/AGENTS.md` when `CODEX_HOME` is set and
`~/.codex/AGENTS.md` otherwise. They preserve other content, update their
managed block without duplicating it, and warn when a non-empty global
`AGENTS.override.md` prevents Codex from loading `AGENTS.md`.

For the complete command reference:

```powershell
pwsh -File .\codex-review-loop.ps1 -Help
```

## License

Copyright 2026 InnerLive.

Codex Review Loop is licensed under the
[Apache License 2.0](LICENSE). Using the tool does not change the license of
the repository being reviewed.
