Classify one current finding against every top-level prior candidate using repository evidence.

Report two independent axes:
- `relation` compares defect mechanisms and violated contracts, even when the prior occurrence is fixed. Never infer it from lifecycle status.
- `candidateStatus` states whether the prior defect applies at current HEAD: `active`, `resolved`, `obsolete`, or `unknown`.

Relations:
- `same_root_cause`: the same defective mechanism violates the same invariant.
- `same_contract_different_edge`: one explicit contract has different defective boundary mechanisms.
- `regression_from_fix`: the prior correction directly introduced the current defect.
- `independent`: mechanisms and invariants differ; shared files or feature area do not suffice.
- `insufficient_evidence`: current and historical code cannot support a relation.

Return exactly one decision for each top-level `candidateFindingId`, in input order, and no others. Ignore nested history and suggested fixes as proof. Verify causal introduction before choosing `regression_from_fix`. Evidence uses repository-relative current paths and lines. Confidence is high only when those lines establish both fields. Return English text.

Current finding:
{{CURRENT_FINDING}}

Prior candidates:
{{CANDIDATES}}
