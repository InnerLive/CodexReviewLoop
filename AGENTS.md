# Agent Instructions

This file is the repository-wide source of intent for future development of
Codex Review Loop. Read it completely before changing code, prompts, schemas,
tests, profiles, documentation, or release behavior.

## Product mission

Codex Review Loop exists so a developer can start a review/fix cycle and walk
away. It must review a branch, identify real defects, make bounded fixes,
independently verify them, run repository-owned quality gates, commit only
verified work, and stop only at a trustworthy completion or a useful
checkpoint.

The scarce resource is the user's attention. Requiring the user to inspect
architecture proposals, classify findings, approve routine commands, repair
state, or repeatedly restart the tool defeats the product. "Unattended" is not
an optional mode; it is the primary requirement.

A long loop is not evidence of diligence by itself. Twenty iterations that
rediscover, rename, regress, or ambiguously close the same defects are a product
failure. Progress must be measured through stable finding identity, verified
state transitions, bounded attempts, passing evidence, and clean reviews on an
unchanged HEAD.

## What the user is optimizing for

Apply these priorities in order:

1. Correctness and trustworthy completion.
2. Reliable unattended operation on real Windows repositories.
3. Simplicity and maintainability of the orchestrator.
4. High model-decision quality.
5. Efficient use of Codex credits, elapsed time, and local compute.
6. Rich diagnostics for maintainers without noisy default terminal output.

Quality takes precedence when a cheaper model is materially worse. When two
choices provide the same quality, prefer the cheaper one. `standard` is the
cost-conscious default. `fast` remains an explicit global option for situations
where elapsed time matters more, and it must apply to every role and resume call
without changing model or reasoning effort.

Do not solve reliability problems by continually adding special cases. Prefer
removing obsolete logic, consolidating duplicate paths, strengthening a small
number of invariants, and fixing root causes. A change that adds substantial
orchestration complexity needs evidence that a simpler correction cannot meet
the requirement.

## Non-negotiable boundaries

- All model interactions go through the locally installed and authenticated
  Codex CLI.
- Never add a direct OpenAI HTTP/API path, an API credential dependency, or an
  API fallback.
- The tool must remain repository-agnostic. Do not add product knowledge, files
  from a reviewed repository, or any reviewed repository as a runtime dependency.
- Historical external logs and findings may be used only as read-only regression
  and prompt-evaluation evidence.
- Public repository content is written in English.
- The canonical implementation is the modular root CLI. Do not create a second
  execution path or a legacy compatibility shim.
- Do not require interactive architecture approval, routine command approval,
  manual finding classification, or manual profile creation.
- Never silently fall back from `fast` to `standard`, from one model to another,
  or from the CLI to an API.
- Never close a finding because a fixer edited code or a commit exists.
  Resolution requires current verification evidence.
- Never weaken a failing invariant merely to keep the loop moving.

## Design philosophy: freedom plus postconditions

LLMs are non-deterministic. They need enough command freedom to investigate
unfamiliar repositories, discover paths, use repository-specific tooling, and
recover from ordinary exploratory mistakes.

Do not build a second command-policy engine, path allowlist, shell parser, or
per-role sandbox matrix into this tool. Every role uses the same central Codex
CLI process path with:

- `--ignore-user-config`
- `--ignore-rules`
- `--dangerously-bypass-approvals-and-sandbox`
- an explicit model
- an explicit reasoning effort
- an explicit service tier

Control model behavior through clear role contracts and enforce outcomes with
postconditions:

- analysis roles must leave HEAD, index, tracked files, and untracked files
  unchanged;
- fixers may edit the worktree but may not own commits or Git refs;
- tests and verification must not introduce unrelated mutations;
- the orchestrator owns authoritative test execution, verification, staging,
  and commits;
- every accepted commit must correspond to the exact verified tree.

Ordinary internal agent-command failures belong to the active model turn. The
model receives their output and can correct them. They are not equivalent to a
Codex process failure or an invalid role result. Conversely, do not hide a real
process failure, `turn.failed`, invalid structured result, unsafe mutation, or
broken process lifecycle behind an advisory classification.

Model-run tests are exploratory evidence only. Configured host gates and the
fixer's structured targeted test are authoritative. Avoid redundant full-suite
tests inside Reviewer, Judge, Critic, or Verifier turns by supplying useful
evidence and clear instructions, but do not reintroduce a general command
allowlist. Long-running commands must not leave orphaned Windows child
processes.

## Public interface invariants

The normal invocation stays simple:

```powershell
pwsh -File .\codex-review-loop.ps1 -RepoPath C:\dev\Project
```

- `RepoPath` may be positional.
- `ConfigPath` is optional.
- `-Help` must work without creating a profile or starting a run.
- `-Speed` accepts `standard|fast` and defaults to `standard`.
- `-OutputMode` accepts `compact|balanced|detailed` and defaults to `compact`.
- `-HeartbeatSeconds` defaults to 30; zero disables heartbeats.
- `-ColorMode` accepts `Host|Ansi|Always|Auto|Never` and defaults to `Host`.
- The default log root is relative to the review-loop installation, never the
  caller's current directory or the reviewed repository.

Configuration discovery is bound to the canonical repository root:

1. `<repo>\.codex-review-loop.psd1`
2. `<repo>\.codex\review-loop.psd1`
3. a tool-local profile whose `RepositoryPath` exactly matches the repository

If none exists, create and use a commented profile automatically. Tool-local
automatic profile names use the repository name plus the next number, such as
`Project-001.psd1`. Comments must explain accepted values. The user must not
have to author a file before the first run.

## Role policy

The current quality/cost allocation is intentional:

| Role | Model | Reasoning |
|---|---|---|
| Reviewer | `gpt-5.6-sol` | `high` |
| Trigger Judge | `gpt-5.6-luna` | `low` |
| Trigger Confirmation | `gpt-5.6-sol` | `low` |
| Trigger Tie-Break | `gpt-5.6-terra` | `medium` |
| Architect | `gpt-5.6-sol` | `high` |
| Architecture Critic | `gpt-5.6-terra` | `medium` |
| Architecture Veto | `gpt-5.6-sol` | `medium` |
| Architecture Tie-Break | `gpt-5.6-terra` | `high` |
| Point Fixer | `gpt-5.6-sol` | `high` |
| Architecture Fixer | `gpt-5.6-sol` | `high` |
| Finding Verifier | `gpt-5.6-luna` | `low` |
| Verifier Confirmation | `gpt-5.6-sol` | `low` |
| Verifier Tie-Break | `gpt-5.6-terra` | `medium` |

The Reviewer emits the versioned review schema directly. Do not add a separate
normalization model call without measured evidence that the additional cost
improves correctness.

Luna handles well-structured classification. A supported high-confidence
independent trigger result is accepted without another model call. Sol confirms
related, uncertain, or structurally invalid trigger decisions and verifier
results that lack sufficient direct evidence. Terra resolves one disagreement.
Persistent disagreement becomes a useful blocked checkpoint rather than an
arbitrary decision or an endless debate.

## Review and finding invariants

- Findings have stable identities based on path, component, root cause, and
  violated invariant, not title wording alone.
- Recurrences reuse an existing identity only after semantic adjudication.
- Same-file findings are not automatically related.
- Findings remain separate when their causes or invariants differ.
- Durable statuses are `pending`, `open`, `fixing`, `resolved`, `superseded`,
  `duplicate`, and `blocked`.
- A finding is `resolved` only after verification against the current
  repository state.
- Each durable role transition writes an atomic, idempotent checkpoint.
- Resume must not duplicate findings or feed one cluster into another cluster's
  fixer thread.
- Legacy checkpoints are evidence, not executable state. Import compatible
  findings into the current ledger, reset stale attempt/thread state, and start
  current orchestration code.
- Repository, branch, symbolic review base, resolved base commit, HEAD, speed,
  and execution fingerprint must be checked before resuming relevant work.

Completion requires the configured clean-pass gate, with two consecutive clean
reviews on an unchanged HEAD as the recommended default, and no open or blocked
findings. Every commit or other HEAD change resets the counter.

## Architecture behavior

Architecture is optional remediation, not a mandatory ceremony.

- Trigger decisions keep semantic relation and prior-finding lifecycle status
  separate. Relations are shared root cause, shared contract with a different
  edge, regression from a fix, independent, or insufficient evidence. Prior
  status is active, resolved, obsolete, or unknown.
- A shared path alone never justifies architecture.
- Related resolved history and explicit recurrence may trigger an architecture
  assessment for one active finding; they never force an architecture change.
- `point_fix/no_architecture` is a valid and often preferable result.
- Proposals compare the minimal fix with consolidation and trace every proposed
  step to evidence, affected paths, and regression tests.
- Critics check coherence, complete finding/path coverage, minimality, risk, and
  artificial bundling.
- Approval receives an independent veto and at most one tie-break.
- Proposal revisions use the profile's budget; one is the recommended default.
- Scope limits are pre-change gates, not targets to fill.
- Rejected, excessive, or uncertain architecture normally falls back to a
  bounded point fix rather than blocking unrelated progress.

Do not reintroduce path-hotspot triggers, forced architecture, auto-apply-all,
epochs, or interactive proposal review.

## Fixing, tests, and commits

- Each semantic finding cluster gets a fresh fixer thread.
- Only a later attempt or a technical correction for that same cluster may
  resume the thread.
- Semantic fix attempts use the profile's budget; two is the recommended
  default.
- A fixer returns a structured executable plus argument array for one targeted
  regression test. Do not require fragile shell-string parsing.
- Repository wrappers and arbitrary executables are valid targeted-test
  commands when they resolve from the repository or environment.
- The orchestrator executes the targeted test independently and records its
  real exit code and log.
- A verifier reads the current repository and receives actual test evidence.
- Verification separates resolution of the original finding from patch safety.
  A direct high-confidence resolution needs matching passing test evidence,
  current path/line evidence, a safe patch verdict, and no reported regressions;
  otherwise use confirmation/adjudication or the remaining fixer attempt.
- Send every supported patch regression back to the same fixer thread together.
- If two attempts fail, block that cluster and continue independent clusters.
- Run configured host gates after verification and before every commit.
- Recheck the patch after gates, stage the exact tree, create the commit from
  that tree, and advance HEAD with an old-value check.
- Never include unrelated concurrent changes in a loop commit.
- A failed gate, unexpected mutation, or changed HEAD must not be committed.

## Terminal and logging intent

The default terminal is a supervisory dashboard, not a transcript of the
agent's shell.

`compact` must show enough for a person to answer:

- What phase is running?
- Is it making progress?
- What findings and decisions exist?
- What is being fixed or verified?
- Did authoritative tests pass?
- Was anything committed?
- Is intervention or aborting necessary?

Do not show internal agent-command starts, successful searches, exploratory
failures, policy declines, long command output, or model reasoning in
`compact`. These events remain in redacted JSONL/stderr logs for diagnosis.
Actual role failures, blocked states, targeted-test failures, host-gate
failures, and commit outcomes stay visible.

`balanced` may show concise internal command activity and failures. `detailed`
may show successful command completion and no-result searches. Heartbeats
update one terminal line rather than flooding the screen. `terminal.log` is
timestamped, ANSI-free, and contains only messages selected for terminal
rendering. Raw JSONL and stderr are flushed while the process is running.

Never expose secrets or internal reasoning. Usage reporting separates new
input, cached input, and output tokens.

## Reliability and process lifecycle

- Use one central CLI adapter for Exec and Resume.
- Pass speed, model, reasoning, output schema, and developer instructions on
  every call, including resumed threads.
- Capture thread ID as soon as it appears.
- Retry only classified technical failures and resume the same thread whenever
  possible.
- Do not start a fresh automatic mutating retry after an uncheckpointed partial
  mutation.
- Structured output is mandatory where a schema exists; invalid output is not a
  successful role.
- Stream and flush stdout/stderr rather than waiting for process completion.
- Bound role, targeted-test, and host-gate lifetimes.
- On cancellation or timeout, terminate the complete owned Windows process
  tree and preserve the last valid checkpoint.
- Test delayed output, partial JSONL, malformed auxiliary events, stderr,
  timeouts, Ctrl+C, and descendant cleanup.
- Never treat an unchanged external state as proof that a process is healthy;
  use activity timestamps, process state, and bounded deadlines.

## Simplicity rules for contributors

- Prefer changing an existing responsibility owner over adding a new layer.
- Keep CLI process management, console rendering, state/ledger operations,
  role logic, and orchestration separated.
- Prompts and JSON schemas remain versioned resources, not large inline
  strings.
- Avoid parsing general PowerShell or shell syntax. Use structured values at
  boundaries.
- Avoid generic migration frameworks for historical state. Migrate only
  explicitly supported durable data.
- Do not add flags for behavior that should be a reliable default.
- Do not retain dead compatibility paths after the replacement is proven.
- When a reliability regression resembles one solved by the archived script,
  inspect the archived implementation and its tests before inventing new
  behavior. Reuse the proven invariant, not the old monolith.
- Explain any meaningful increase in active source complexity and look for an
  offsetting deletion or consolidation.

## Development workflow

Before editing:

1. Check for an active review-loop process and active run.
2. Do not change tool code, prompts, schemas, or an active profile while a run
   is executing; the execution fingerprint is designed to invalidate that work.
3. Read the relevant source, prompt, schema, tests, and any archived behavior
   that previously solved the same class of problem.
4. Preserve unrelated user changes.

While developing:

- Use Windows-native PowerShell and Windows paths.
- Use `rg`/`rg --files` for discovery.
- Use `apply_patch` for source edits.
- Keep changes scoped to this tool repository.
- Use fake Codex and temporary Git repositories for deterministic integration
  tests.
- Do not run a productive loop or modify a user's reviewed repository as part
  of tool development.
- A bounded live Codex CLI smoke test is appropriate only when CLI behavior
  cannot be proven with the fake process. Use `standard`, the cheapest role
  that can prove the behavior, and a non-product fixture.

Before handing off:

1. Run the relevant focused tests.
2. Run both full Pester suites for behavior that affects orchestration,
   persistence, process management, profiles, or the CLI adapter.
3. Parse all active `.ps1`, `.psm1`, and `.psd1` files.
4. Parse every JSON schema.
5. Run the CLI-only negative scan.
6. Run `git diff --check`.
7. Verify `-Help` for public-option changes.
8. Confirm no test or Codex child process remains.
9. State exactly what was tested and what was deliberately not run.

Do not archive, commit, push, publish, or run against a real product repository
unless the user requested that action.
