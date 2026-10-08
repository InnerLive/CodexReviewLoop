# Codex Review Loop

**Ask Codex to review its changes, fix the problems, and verify the result.**

Codex Review Loop checks the changes on your branch, corrects findings, and
runs your project's quality checks before committing accepted work. It repeats
the process until the required reviews are clean. A Critic helps the roles
improve their working practices; longer runs can also turn lessons learned
into useful project guidance.

## Set up once

You need Windows, PowerShell 7, Git, and an installed Codex CLI that you have
signed in to.

Clone this repository wherever you want to keep it, open PowerShell in that
folder, and run:

```powershell
pwsh -File .\install-skills.ps1
```

This installs both skills and remembers where the ReviewLoop repository is.
Keep that folder available. After updating or moving it, run the installer
again. Restart Codex if the skills do not appear.

## Use it naturally

In the project where Codex has been working, just say:

> Run ReviewLoop for your changes.

Codex uses the current task to prepare the review and finds the tool through
the installed skill. You do not need to provide a path, name the skill, or
write a command. Existing compatible runs resume automatically.

> [!WARNING]
> The loop runs unattended with approval and sandbox checks bypassed. It can
> change files and create commits. Start a new run on a dedicated branch with
> a clean working tree, and make sure your project's quality checks are configured.

The included [prompting skill](skills/prompting/SKILL.md) is used automatically
when you ask Codex to write or improve prompts, skills, or agent instructions.
No special invocation is needed. The [review-loop skill](skills/review-loop/SKILL.md)
handles preparing and running reviews when you ask for them.

## Optional working agreements

You can also give Codex a small set of general working agreements: preserve
your goals, keep solutions as small as they can reasonably be, and avoid
unnecessary work. Install them with:

```powershell
pwsh -File .\install-global-agents.ps1
```

The installer preserves your other instructions. Read the
[working agreements](docs/smallest-complete-work.md) before installing them.

## More detail when you need it

- [How reviews, fixes, and verification work](docs/how-it-works.md)
- [Project settings and quality checks](docs/configuration.md)
- [Running, resuming, and troubleshooting](docs/operations.md)
- [How Codex discovers skills](https://learn.chatgpt.com/docs/build-skills#where-codex-loads-local-skills)

For direct command-line use:

```powershell
pwsh -File .\codex-review-loop.ps1 -Help
```

## License

Copyright 2026 InnerLive.

Codex Review Loop is licensed under the
[Apache License 2.0](LICENSE). Using the tool does not change the license of
the repository being reviewed.
