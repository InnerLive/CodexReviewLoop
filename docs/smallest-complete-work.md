<!-- codex-smallest-complete-work:start -->
# Smallest Complete Work

These rules are global defaults. Explicit user requirements and more specific project, security, and compatibility rules take precedence.

- Optimize for the smallest complete overall solution that satisfies all explicit requirements for correctness, security, and maintainability. Less code, fewer artifacts, and fewer decision paths are a quality improvement when the result remains equivalent.
- Before substantial work, derive the goal, constraints, non-goals, and acceptance criteria from the request and context. State them explicitly only when needed for execution or alignment. Stop once they are satisfied, and ask for approval before a substantial scope expansion that is not required to complete the request.
- Give each rule and decision exactly one authoritative source. Enforce it at every necessary trust and failure boundary without creating competing sources or independent decision logic.
- While a change is active, later evidence may correct earlier assumptions. Update the earliest authoritative point, rederive the consequences, and remove special cases made obsolete by the correction. Preserve required compatibility, migration, and security boundaries.
- Do not reopen work that has been completed and accepted or merged solely for further optimization. Valid reasons are a demonstrated defect, a security issue, or an explicit new request.
- Before final verification, perform a subtractive review of your own change scope. Remove or consolidate anything not required for the requirements, correctness, security, or maintainability. Do not add speculative extensibility or work for hypothetical future needs.
<!-- codex-smallest-complete-work:end -->
