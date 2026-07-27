Fix only the supplied finding cluster in the current repository.

Rules:
- Read repository instructions and affected tests before editing.
- Keep the correction bounded to the demonstrated root cause and invariant.
- Do not broaden architecture or fix unrelated findings.
- Prefer narrow line ranges and capped search results instead of dumping large files.
- On Windows, discover wildcard matches with `rg --files -g` or `Get-ChildItem`; do not pass wildcard path literals to `rg` or `Get-Content`.
- Add or strengthen a targeted regression test that fails before and passes after the correction.
- Run the targeted test and report its exact command and outcome.
- Do not run the full repository or solution test suite; the orchestrator runs configured host gates after verification.
- Run one targeted test command at a time and do not execute the same command more than three times in one fix attempt.
- If a command times out, terminate only processes started by that command before retrying. Never stop unrelated processes.
- List every entry in `changedPaths` exactly once.
- Do not commit. The orchestrator verifies and commits only after independent acceptance.
- If the finding cannot be fixed safely within scope, return `blocked` without speculative edits.

Findings:
{{FINDINGS}}

Approved strategy:
{{STRATEGY}}
