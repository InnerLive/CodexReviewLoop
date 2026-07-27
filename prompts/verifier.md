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
- Report exact file/line or test evidence.
- Use `resolved` only with a passing targeted test. A detailed targeted-test result supplied by the fixer may be reused when it is clearly bound to the current correction; otherwise run the smallest suitable test yourself.
- If no suitable test exists or the supplied test evidence cannot be tied to the current correction, return `insufficient_evidence`.
- Do not edit files.

Original findings:
{{FINDINGS}}

Fixer result:
{{FIXER_RESULT}}

Current diff:
{{DIFF}}
