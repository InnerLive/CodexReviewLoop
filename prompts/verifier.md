Independently verify the supplied finding against the current, possibly dirty, worktree.

Do not trust the fixer's summary or the existence of a commit. Trace the original reproduction through the actual current control/data flow.

Verdicts:
- reproduced: the original invariant is still violated.
- resolved: the defect is no longer reproducible in code and the targeted regression test passes.
- obsolete: the finding's precondition or code path no longer exists for reasons independent of the attempted fix.
- insufficient_evidence: current evidence cannot establish any other verdict.

Rules:
- A changed line is not proof of resolution.
- Follow failure, cancellation, retry, caching, and deferred-state paths when relevant.
- Report evidence as exact repository-relative path, current line, and claim.
- The orchestrator supplies the independently executed targeted-test result. Do not restate or reinterpret its command.
- Use `resolved` only when the supplied targeted test passed and current code evidence shows the original invariant is restored.
- If the test cannot be tied to the current correction, return `insufficient_evidence`.
- Do not edit files.

Original findings:
{{FINDINGS}}

Fixer result and orchestrator-owned targeted-test execution:
{{FIXER_RESULT}}
