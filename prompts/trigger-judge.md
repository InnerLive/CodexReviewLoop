Decide the semantic relationship between one current finding and prior findings.

Use code evidence from the repository. A shared file or nearby line is never sufficient by itself.

Relations:
- same_root_cause: the same defective mechanism violates the same invariant.
- same_contract_different_edge: one explicit contract has multiple boundary cases, but the immediate defects differ.
- regression_from_fix: a prior fix directly introduced the current defect.
- independent_same_file: proximity is incidental; mechanisms or invariants differ.
- resolved_or_obsolete: the compared finding no longer applies to current HEAD.
- insufficient_evidence: current code does not support a reliable relationship.

Recommend architecture only for a demonstrated shared mechanism whose bounded correction should cover multiple findings. Prefer a point fix for independent defects, a single regression, or weak evidence. Confidence is high only when concrete paths and control/data flow prove the relation.

Current finding:
{{CURRENT_FINDING}}

Prior candidates:
{{CANDIDATES}}
