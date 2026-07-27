$script:ModuleRoot = $PSScriptRoot

$sourceFiles = @(
    "src\Common.ps1",
    "src\Console.ps1",
    "src\Cli.ps1",
    "src\State.ps1",
    "src\Roles.ps1",
    "src\Loop.ps1",
    "src\PromptEvals.ps1"
)

foreach ($sourceFile in $sourceFiles) {
    . (Join-Path $PSScriptRoot $sourceFile)
}

Export-ModuleMember -Function @(
    "Invoke-CodexReviewLoop",
    "Test-CodexReviewLoopPrompts",
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
