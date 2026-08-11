# Codex Review Loop repository guidance

Use this file for repository-wide rules that must apply to every change. Keep
it practical and concise. Put detailed product behavior in the linked docs and
add new guidance here only for recurring mistakes or review feedback.

## Repository overview

Codex Review Loop is a Windows-first PowerShell 7 CLI that reviews a branch,
fixes findings, verifies the exact worktree, runs repository-owned gates, and
commits only accepted work. Its primary requirement is reliable unattended
operation: a developer should be able to start a run and walk away.

Optimize in this order:

1. Correctness and trustworthy completion.
2. Reliable unattended operation on real Windows repositories.
3. Simplicity and maintainability.
4. Model-decision quality.
5. Cost, elapsed time, and local compute.
6. Useful diagnostics without noisy default output.

## Repository layout

| Path | Purpose |
|---|---|
| `codex-review-loop.ps1` | Public CLI entry point |
| `CodexReviewLoop.psm1` | Module composition and exports |
| `src/Common.ps1` | Configuration, paths, and shared helpers |
| `src/Cli.ps1` | Central Codex CLI process adapter |
| `src/State.ps1` | Durable run state and finding ledger |
| `src/Roles.ps1` | Role orchestration and contracts |
| `src/Loop.ps1` | Review/fix/verify/commit state machine |
| `src/Console.ps1` | Terminal rendering and transcript selection |
| `prompts/` | Versioned role prompts |
| `schemas/` | Closed JSON schemas for structured roles |
| `tests/CodexReviewLoop.Tests.ps1` | Main behavior and integration suite |
| `tests/Reliability.Tests.ps1` | Process, recovery, and safety suite |
| `tests/FakeCodex.ps1` | Deterministic fake CLI for tests |
| `docs/how-it-works.md` | Canonical workflow explanation |
| `docs/configuration.md` | Profiles and live configuration |
| `docs/operations.md` | Operation, resume, and failure handling |
| `archive/` | Read-only historical implementation evidence |

## Read before editing

- Workflow, role, state, or completion changes: read
  `docs/how-it-works.md`, the owning source file, related prompt/schema, and
  matching tests.
- Profile or public-option changes: also read `docs/configuration.md`,
  `codex-review-loop.ps1`, and profile tests.
- Terminal, timeout, recovery, or process-lifecycle changes: also read
  `docs/operations.md` and `tests/Reliability.Tests.ps1`.
- When a reliability issue resembles behavior in `archive/`, inspect the
  archived implementation and tests, then reuse the invariant rather than the
  old monolith.

## Development commands

Run from the repository root with PowerShell 7.

Show public help without starting a run:

```powershell
pwsh -NoProfile -File .\codex-review-loop.ps1 -Help
```

Run the main suite:

```powershell
$result = Invoke-Pester -Script .\tests\CodexReviewLoop.Tests.ps1 -PassThru
if ($result.FailedCount -gt 0) { throw "Main Pester suite failed." }
```

Run the reliability suite:

```powershell
$result = Invoke-Pester -Script .\tests\Reliability.Tests.ps1 -PassThru
if ($result.FailedCount -gt 0) { throw "Reliability Pester suite failed." }
```

Parse active PowerShell files:

```powershell
$files = rg --files -g '*.ps1' -g '*.psm1' -g '*.psd1' -g '!archive/**' -g '!runs/**'
foreach ($file in $files) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        (Resolve-Path $file), [ref]$tokens, [ref]$errors)
    if ($errors) { throw "PowerShell parse failed: $file" }
}
```

Parse schemas and check the patch:

```powershell
Get-ChildItem .\schemas\*.json | ForEach-Object {
    Get-Content -Raw -LiteralPath $_.FullName | ConvertFrom-Json | Out-Null
}
git diff --check
```

Do not run a productive review loop against a real project while developing
this repository. Use `FakeCodex.ps1` and temporary Git repositories. A bounded
live CLI smoke test is appropriate only when fake-process evidence cannot prove
the behavior.

## Non-negotiable constraints

- All model interactions go through the locally installed and authenticated
  Codex CLI. Never add direct OpenAI HTTP/API access, credentials, or fallback.
- Keep the tool repository-agnostic. Reviewed repositories and their product
  knowledge must not become runtime dependencies.
- The modular root CLI is the only active implementation. Do not add a second
  execution path or legacy compatibility shim.
- Public repository content is English.
- Do not require interactive architecture approval, routine command approval,
  manual finding classification, or manual profile creation.
- Never silently change speed, model, reasoning effort, service tier, or CLI
  transport.
- Never weaken a failing invariant to keep the loop moving.
- Preserve unrelated user changes and never include them in a loop commit.

## Architecture and role contracts

Use one central CLI adapter for every structured `exec` and `resume` call. Pass
`--ignore-user-config`, `--ignore-rules`, unattended full access, and explicit
model, reasoning, and service-tier values on every call. The native Reviewer
uses `codex review --base`; it receives no positional prompt, schema, JSONL
switch, or output-file switch. Supplemental Reviewer guidance may only use its
supported developer-instructions setting.

| Role | Model | Reasoning |
|---|---|---|
| Reviewer | `gpt-5.6-sol` | `high` |
| LessonsLearned | `gpt-5.6-sol` | `high` |
| Architect | `gpt-5.6-sol` | `high` |
| Fixer | `gpt-5.6-sol` | `high` |
| Verifier | `gpt-5.6-sol` | `low` |
| ReviewClassifier | `gpt-5.6-luna` | `low` |

- Analysis roles must leave HEAD, index, tracked files, and untracked files
  unchanged.
- Fixers own worktree edits but never commits or Git refs.
- The orchestrator owns authoritative tests, verification, staging, and
  commits. Every accepted commit must represent the exact verified tree.
- Architect, Fixer, and Verifier make their existing decisions directly. Do
  not add approval, critic, judge, veto, tie-break, or fallback roles.
- Prompts and schemas remain versioned resources, not large inline strings.
- Structured output is mandatory where a schema exists. A process failure,
  `turn.failed`, invalid structured result, or unsafe mutation is technical
  failure, not advisory output.

## Workflow invariants

- The current native review is authoritative. History supplies context only
  and never suppresses current findings.
- Findings remain active until the Verifier accepts a solution or a later
  native review reports clean. An edit or commit alone never resolves them.
- Verifier rejection returns to the Fixer. Exhausting `MaxFixAttempts`
  preserves the rejected patch, restores the clean checkpoint, and starts a
  new native review; it does not create a blocked finding.
- Configured host gates run after verification and before every commit. Recheck
  the patch, stage the exact tree, and advance HEAD with an old-value check.
- Completion normally requires the configured clean passes on unchanged HEAD.
  Every ordinary fix commit resets them.
- Lessons learned runs once at an eligible clean gate. Its recommendations use
  the normal Architect/Fixer/Verifier/gate/commit path. An accepted result is
  final unless the captured `ReviewAfterLessonsLearnedCommit` setting requires
  clean reviews after a real lessons commit. Accepted no-ops finish directly.
- `MaxReviewCycles` limits native reviews per invocation, not the durable run.
  A new invocation resumes with a fresh budget.
- Durable transitions are atomic and idempotent. Resume must validate the
  repository, branch, review base, HEAD, and execution fingerprint. It inherits
  checkpoint speed unless the user explicitly changes it.

## Process and terminal rules

- Stream and flush stdout/stderr; capture a thread ID as soon as it appears.
- Bound inactivity, not total productive runtime. On cancellation or timeout,
  terminate the complete owned Windows process tree and keep the last valid
  checkpoint.
- Do not leave test, fake-Codex, or descendant processes running.
- `compact` is a supervisory dashboard. Show phases, findings, decisions,
  authoritative tests, commits, actionable failures, and completion. Hide
  internal command chatter, exploratory failures, and model reasoning.
- Keep full redacted JSONL/stderr diagnostics and a timestamped, ANSI-free
  `terminal.log`. Never expose secrets or internal reasoning.

## Engineering conventions

- Use Windows-native PowerShell and Windows paths.
- Use `rg`/`rg --files` for discovery and `apply_patch` for hand-written edits.
- Put future directory-specific guidance in the closest nested `AGENTS.md`
  instead of expanding this root file with local rules.
- Change the existing responsibility owner instead of adding another layer.
- Prefer deleting or consolidating obsolete logic over adding special cases.
- Do not build a shell parser, command allowlist, or per-role sandbox matrix.
- Use structured values at boundaries and migrate only explicitly supported
  durable data; do not add a generic migration framework.
- Add profile flags only for genuine policy choices, not behavior that should
  be a reliable default.

## Code Review Rules

- Flag any direct API/model call outside `src/Cli.ps1`; the safe path is the
  central authenticated Codex CLI adapter.
- Flag reviewer positional prompts or schemas; the safe path is native
  `codex review --base` plus optional supported developer instructions.
- Flag resolution without current Verifier or clean-review evidence.
- Flag commits that can include concurrent/unrelated changes or a tree that was
  not independently gated and identity-checked.
- Flag mutating retries without a durable recovery checkpoint and complete
  patch preservation.
- Flag fixed wall-clock limits for productive roles, incomplete Windows process
  cleanup, compact-mode transcript noise, or unredacted diagnostics.
- Reserve formatting checks for automated tooling; review semantic invariants
  and safe recovery behavior.

## Definition of done

Before handing off a change:

1. Run focused tests for the changed responsibility.
2. Run both full Pester suites for orchestration, persistence, process,
   profile, or CLI-adapter changes.
3. Parse all active `.ps1`, `.psm1`, and `.psd1` files.
4. Parse all JSON schemas and run their positive/negative validation tests.
5. Run the CLI-only negative scan and `git diff --check`.
6. Verify `-Help` when public behavior or options change.
7. Confirm the worktree contains only intended changes and no test/Codex child
   process or repository lock remains.
8. State exactly what was tested and what was deliberately not run.

Do not archive, commit, push, publish, or run against a real product repository
unless the user requested that action.
