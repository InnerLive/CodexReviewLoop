@{
    RootModule = "CodexReviewLoop.psm1"
    ModuleVersion = "3.0.0"
    GUID = "22caaf8b-bbde-4a3f-9b7e-84137e5a7b92"
    Author = "InnerLive"
    CompanyName = "InnerLive"
    Copyright = "(c) InnerLive"
    Description = "Unattended, CLI-only Codex review loop with semantic architecture gates and verified fixes."
    PowerShellVersion = "7.0"
    FunctionsToExport = @(
        "Invoke-CodexReviewLoop",
        "Invoke-CodexCliRole",
        "New-ReviewLoopLedger",
        "Read-ReviewLoopLedger",
        "Write-ReviewLoopLedger",
        "Merge-ReviewLoopFindings",
        "Get-ReviewLoopFindingId",
        "Get-ReviewLoopTriggerCandidates",
        "New-ReviewLoopState",
        "Read-ReviewLoopState",
        "Write-ReviewLoopState",
        "Get-CodexRoleArguments"
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{
            Tags = @("Codex", "Review", "Automation")
        }
    }
}
