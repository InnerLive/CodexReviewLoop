Fix only the supplied finding cluster in the current repository.

Rules:
- Read repository instructions and affected tests before editing.
- Keep the correction bounded to the demonstrated root cause and invariant.
- Do not broaden architecture or fix unrelated findings.
- Add or strengthen a targeted regression test that fails before and passes after the correction.
- Do not run builds or tests. Return exactly one targeted test command for the orchestrator to execute.
- Use a direct test runner (`dotnet test`/`vstest`, pytest, common package-manager `test` commands, Cargo/Go/Swift tests, Maven/Gradle test tasks, CTest, or PHPUnit) without shell operators or redirection.
- Set its `passed` field to `false` and its evidence to `not run; orchestrator-owned`.
- List every entry in `changedPaths` exactly once.
- Do not commit. The orchestrator verifies and commits only after independent acceptance.
- If the finding cannot be fixed safely within scope, return `blocked` without speculative edits.

Findings:
{{FINDINGS}}

Approved strategy:
{{STRATEGY}}

Feedback from the previous attempt:
{{FEEDBACK}}
