Fix only the supplied finding cluster in the current repository.

Rules:
- Read repository instructions and affected tests before editing.
- Keep the correction bounded to the demonstrated root cause and invariant.
- Do not broaden architecture or fix unrelated findings.
- Add or strengthen a targeted regression test that fails before and passes after the correction.
- Run the targeted test and report its exact command and outcome.
- Do not commit. The orchestrator verifies and commits only after independent acceptance.
- If the finding cannot be fixed safely within scope, return `blocked` without speculative edits.

Findings:
{{FINDINGS}}

Approved strategy:
{{STRATEGY}}
