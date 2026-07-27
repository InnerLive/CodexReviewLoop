@{
    Trigger = @(
        @{
            CaseId = "trigger-same-contract"
            Expected = "same_root_cause"
            Description = "A previously fixed representation cache/watch contract failed again through the same missing dependency mechanism. Both findings concern stale cached output after a declared context value changes, and the current code follows the same dependency snapshot and cache fingerprint path."
        },
        @{
            CaseId = "trigger-independent-same-file"
            Expected = "independent_same_file"
            Description = "Two findings are in RepresentationExecutionContract.cs. One is a selector authorization defect; the other is a decision-backflow validation defect. They share a file but use different mechanisms, inputs, invariants, and corrections."
        },
        @{
            CaseId = "trigger-regression-from-fix"
            Expected = "regression_from_fix"
            Description = "Commit 1c6497f0 corrected one projection ordering path but directly introduced a sort regression in the direct projection path. The new defect is causally introduced by that specific fix rather than evidence for a broad architecture consolidation."
        }
    )
    Critic = @(
        @{
            CaseId = "critic-artificial-catalog"
            Expected = "reject_to_point_fix"
            Description = "Proposal groups an old catalog performance finding, a telemetry finding, and a current metadata-read finding into one catalog/cache architecture strategy. The findings have different causes and invariants; the proposal is broader than three bounded fixes."
        },
        @{
            CaseId = "critic-missing-fragment-path"
            Expected = "revise"
            Description = "Proposal groups five related representation acceptance findings and claims one acceptance-gate root cause, but omits the RepresentationFragmentCache path required to preserve transactional fragment state. The shared mechanism may be real, but the executable path and regression coverage are incomplete."
        }
    )
    Verifier = @(
        @{
            CaseId = "verifier-f48"
            Expected = "resolved"
            Description = "F48 alleged that tools/ModuleScaffold.ps1 declared EventTime in the runner descriptor but omitted it from the generated manifest. On current HEAD both generated contracts include EventTime, and tests/DevEnv.Tests/ModuleScaffoldTests.cs asserts both generated outputs. Historical verification after this correction on the code state carried into current HEAD ran dotnet test .\PKonf.sln successfully (2,550 passed, one unrelated planned skip), including the DevEnv.Tests project. Verify that the relevant lines and regression assertions are still present; do not rerun tests in this read-only eval."
        },
        @{
            CaseId = "verifier-f27"
            Expected = "reproduced"
            Description = "F27 alleged O(N) cloning in the representation fragment cache. On current HEAD Begin copies the complete fragment dictionary and Commit copies it again. Verify the implementation rather than relying on this statement."
        },
        @{
            CaseId = "verifier-f38"
            Expected = "reproduced"
            Description = "F38 alleged culture-sensitive geometry benchmark payloads. Trace benchmarks/RuntimeScalability.Benchmarks/ExperienceScaleV2RepresentationModules.cs: FormatGeometryContext passes RepresentationViewport to FormatValue; RepresentationViewport is a record that does not implement IFormattable, so the IFormattable arm is skipped and the fallback invokes the record's culture-sensitive ToString() for decimal fields. Do not substitute the separate RepresentationCacheProvenance canonical writer for this benchmark payload path."
        },
        @{
            CaseId = "verifier-f11"
            Expected = "reproduced"
            Description = "F11 alleged loss of requested-module invalidation after failed regeneration. CaptureDeferredInvalidations removes requested modules, normal capture does not preserve their invalidation, and a failed execution can leave the prior baseline/version matching. Trace the failure path in current code."
        }
    )
    Normalizer = @(
        @{
            CaseId = "normalizer-clean"
            Expected = "clean"
            Description = "No actionable correctness, security, reliability, or material performance issue was found. The reviewed change preserves the existing contract and its regression tests."
        },
        @{
            CaseId = "normalizer-finding"
            Expected = "findings"
            HistoricalNativePath = "20260726-220013\review-16.native.txt"
        }
    )
}
