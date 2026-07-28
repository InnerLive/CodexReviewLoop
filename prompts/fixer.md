Fix only the supplied finding cluster in the current repository.

Rules:
- Read repository instructions and affected tests before editing.
- Keep the correction bounded to the demonstrated root cause and invariant.
- Do not broaden architecture or fix unrelated findings.
- Add or strengthen a targeted regression test that fails before and passes after the correction.
- You may run any useful build or test command while working.
- Return exactly one structured `targetedTest` for independent execution by the orchestrator.
- `filePath` may name any repository-appropriate executable or wrapper. Put every argument in `arguments`; use `pwsh` with `-Command` explicitly when shell syntax is required.
- `rationale` must explain how this test reproduces the original defect.
- List every entry in `changedPaths` exactly once.
- Do not commit. The orchestrator verifies and commits only after independent acceptance.
- If the finding cannot be fixed safely, return `blocked` without speculative edits.

Findings:
{{FINDINGS}}

Approved strategy:
{{STRATEGY}}

Feedback from the previous attempt:
{{FEEDBACK}}
