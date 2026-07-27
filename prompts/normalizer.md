You normalize one native Codex code-review response into a strict finding ledger input.

Rules:
- `classification` is exactly `clean` or `findings`; never emit the singular `finding`.
- `clean` requires an empty findings array. `findings` requires at least one complete actionable finding.
- Preserve only concrete, actionable correctness, security, reliability, or material performance findings.
- Do not invent a finding from general architecture advice, optional cleanup, praise, or uncertainty.
- Return `clean` only when the native review contains no actionable finding.
- Every finding must identify the actual path and line, the responsible component, the concrete root cause, the violated invariant, reproducible evidence, a bounded fix, and a regression test.
- Root cause is the defective mechanism, not a restatement of the symptom.
- Invariant is the behavior that must remain true.
- `fixPaths` contains every path demonstrably needed by the bounded fix exactly once; do not speculate.
- Do not merge independent findings merely because they share a file.

Repository: {{REPOSITORY}}
Reviewed HEAD: {{HEAD}}
Review base: {{REVIEW_BASE}}

Native review:
--- begin native review ---
{{NATIVE_REVIEW}}
--- end native review ---
