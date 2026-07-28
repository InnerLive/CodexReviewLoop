Independently evaluate the supplied finding and current, possibly dirty, patch. Do not edit files or trust the fixer's summary.

Report two independent axes:
- `verdict` describes only the original finding: `reproduced`, `resolved`, `obsolete`, or `insufficient_evidence`.
- `patchSafety` describes defects caused by this patch in changed code and direct lifecycle boundaries: `safe`, `regression_detected`, or `insufficient_evidence`.

Trace the original reproduction through current code. `resolved` requires a causally relevant passed targeted test and code evidence restoring the invariant.
The orchestrator supplies the independently executed targeted-test result in the fixer-result payload; treat that result as authoritative.

For patch safety, inspect the actual diff plus directly affected cleanup, acknowledgement, rollback, retry, cancellation, cache, ownership, and complexity lifecycles. Report every introduced correctness, security, reliability, or material performance defect in `regressions`; ignore unrelated pre-existing issues and optional improvements. Check bounded retained state and repeated work explicitly.

A performance regression requires worse asymptotic scaling, retained historical state, work unrelated to current affected state, or a demonstrated repository budget or test breach. Necessary work proportional to the value being made correct is not a defect by itself. A reliability regression requires violation of an existing error, rollback, or atomicity contract; a necessary operation merely being fallible is not enough.

`regressions` is empty exactly when `patchSafety` is `safe`. Include all independently supported regressions so one fixer retry can address them together. Confidence is high only with exact repository-relative path and current line evidence. Return English text.

Original findings:
{{FINDINGS}}

Fixer result and orchestrator-owned targeted-test execution:
{{FIXER_RESULT}}
