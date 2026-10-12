# Shared task and architecture work: validation

Validated in an isolated tool worktree on 2026-10-12, based on `dc788c1`.
The productive loop and its tool checkout were left unchanged during development.

## Deterministic verification

The final partitioned suite covers both existing Pester suites and
`tests/ArchitectureWork.Tests.ps1`. The new cases cover omitted and changed
tasks, persistent orders, independent acceptance, clean reviews with open work,
preserved candidates and split index state, interrupted assessments and prepared
commits, concurrent edits, failed gates, no-op completion, and state migration.
Schema tests include valid results and rejected extra fields and invalid statuses.
The complete partition passed: 173 main tests, 111 reliability tests and
19 architecture-work tests (303/303, no skips). All 20 active PowerShell files
parsed; all 10 JSON schemas parsed; positive/negative schema tests, the CLI-only
negative scan, public help, skill validation and `git diff --check` passed.
No owned test/probe process or Git lock remained. No productive loop was started
for verification.

## Bounded real CLI probes

All four scenarios used the production role composition and central authenticated
Codex CLI adapter, with `gpt-6.1-sol`, high reasoning and standard service.
They ran only in temporary Git repositories. Sessions received normal repository
tasks, without evaluation instructions or suggested answers.

| Scenario | Observed result |
|---|---|
| No original task | Architect reconstructed the public percentage contract from commits, documentation and source; preserved the completed export and identified the remaining calculation error. It recorded sources and uncertainty instead of treating current code as the specification. |
| Explicit task contradicts old documentation; review has no findings | Architect honored the fractional-input requirement, recognized that calculation and export were already correct, and selected only the necessary documentation order. |
| Finished implementation | Architect inspected the public entry point, matching documentation and checks, accepted the overall task and created no additional orders. |
| Preserved, uncommitted candidate | Native `review --base` reported the remaining average-calculation defect and the percentage defect in a new untracked file. It did not re-report the addition defect repaired only in the worktree. HEAD, refs, index and file fingerprints were unchanged. |

The last case satisfies the release condition for reviewing owned dirty candidates
with the tested CLI and prompt composition. It is evidence for this fixture,
not a guarantee that any model will discover every future defect. No alternate
review transport was introduced.

Local outputs and CLI diagnostics are retained under ignored `eval-results/`
and the temporary probe directories.

## Operational qualification

Follow the authoritative [upgrade and recovery rules](operations.md) before
switching an active run. State 2.0 preserves the same run references; old tools
must not process the upgraded state. Requalify wrapper bindings and resume the
same run only after the operator confirms a complete inactive round.

The implementation does not claim shorter productive runs or lower token use.
Those effects, and the Critic's influence on real collaboration, still require
comparison of actual runs. Previously discarded repairs remain historical
evidence and are not retroactively described as preserved progress.
