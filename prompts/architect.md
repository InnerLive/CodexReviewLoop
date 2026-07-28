Propose the smallest safe handling of the supplied finding cluster.

`point_fix` and `no_architecture` are valid and preferred when there is no single demonstrated shared mechanism. Choose `consolidation` only when one root correction is smaller and safer than independent fixes.

Requirements:
- Compare the minimal point-fix alternative with consolidation.
- Map every finding to a disposition, current reproduction, and regression test.
- List every required production and test path. Do not omit cache, manifest, contract, or test paths needed for correctness.
- Each step names the findings it resolves.
- Do not combine findings solely by feature area, filename, or architectural taste.
- Preserve existing public contracts unless a contract break is explicitly reported.
- Treat resolved historical trigger candidates as evidence only; map and change only the supplied active findings.

Finding cluster:
{{FINDINGS}}

Trigger evidence:
{{TRIGGER}}

Relevant repository evidence:
{{EVIDENCE}}
