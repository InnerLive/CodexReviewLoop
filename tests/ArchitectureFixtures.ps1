$script:OwnedTestLogCases = @()

function New-TestLogRoot {
    param([Parameter(Mandatory = $true)][string]$ToolRoot)
    $casePath = [IO.Path]::GetFullPath((Join-Path $ToolRoot ('eval-results/test-' + [Guid]::NewGuid().ToString('N'))))
    $script:OwnedTestLogCases = @($script:OwnedTestLogCases) + $casePath
    $logs = Join-Path $casePath 'logs'
    New-Item -ItemType Directory -Path $logs -Force | Out-Null
    return $logs
}

function Clear-TestLogRoots {
    param([Parameter(Mandatory = $true)][string]$ToolRoot)
    $parent = [IO.Path]::GetFullPath((Join-Path $ToolRoot 'eval-results'))
    foreach ($path in @($script:OwnedTestLogCases)) {
        $absolute = [IO.Path]::GetFullPath($path)
        if ([IO.Path]::GetDirectoryName($absolute) -ne $parent -or
            [IO.Path]::GetFileName($absolute) -notmatch '^test-[a-f0-9]{32}$') {
            throw "Test log cleanup escaped its owned case: $absolute"
        }
        if (Test-Path -LiteralPath $absolute) {
            foreach ($checkpoint in @(Get-ChildItem -LiteralPath $absolute -Filter run-v1.json -Recurse -File)) {
                try {
                    $mailbox = & (Get-Module CodexReviewLoop) {
                        param($path)
                        Get-ReviewLoopOperatorMailbox (Read-ReviewLoopState $path)
                    } $checkpoint.FullName
                }
                catch { continue } # Deliberately invalid state fixtures have no mailbox.
                if (Test-Path -LiteralPath $mailbox) { Remove-Item -LiteralPath $mailbox -Recurse -Force }
            }
            Remove-Item -LiteralPath $absolute -Recurse -Force
        }
    }
    $script:OwnedTestLogCases = @()
}

function Get-TestArchitecturePhase {
    param([string]$SchemaName, [string]$Prompt)
    if ($SchemaName -eq "architecture-orientation-v1.schema.json") { return "orientation" }
    $completionTask = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'prompts/architect-completion.md') -TotalCount 1
    if ($Prompt.Contains($completionTask)) { return "completion" }
    return ""
}

function Test-TestArchitectureDefaultPhase {
    param([string]$Phase, [string]$PlanPath)
    if ([string]::IsNullOrEmpty($Phase)) { return $false }
    if (-not [string]::IsNullOrWhiteSpace($PlanPath) -and (Test-Path -LiteralPath $PlanPath)) {
        $plans = @(Get-Content -Raw -LiteralPath $PlanPath | ConvertFrom-Json)
        if ($plans.Count -gt 0 -and $null -ne $plans[0] -and $plans[0].PSObject.Properties.Name -contains "phase" -and
            $plans[0].phase -eq $Phase) { return $false }
    }
    return $true
}

function Get-TestArchitecturePhaseResult {
    param([string]$Phase)
    if ($Phase -eq "orientation") {
        return '{"schemaVersion":"1.0","goal":{"statement":"Meet the repository contract.","sources":["README.txt and branch commits"],"uncertainties":[]},"orders":[]}'
    }
    return '{"schemaVersion":"2.0","accept":true,"summary":"The overall task is fulfilled.","feedback":[],"commitMessage":{"subject":"","rationale":"","changes":[]},"newOrders":[],"workOutcomes":[],"goalComplete":true}'
}

function Convert-TestArchitectureResult {
    param([string]$SchemaName, [string]$Text)
    try { $value = $Text | ConvertFrom-Json } catch { return $Text }
    if ($null -eq $value -or $value.PSObject.Properties.Name -notcontains "schemaVersion") { return $Text }
    if ($SchemaName -eq "architecture-advice-v3.schema.json" -and $value.schemaVersion -eq "2.0") {
        $value.schemaVersion = "3.0"
        $value | Add-Member -NotePropertyName orders -NotePropertyValue @()
        $value | Add-Member -NotePropertyName selectedWorkIds -NotePropertyValue @()
    }
    elseif ($SchemaName -eq "architecture-assessment-v2.schema.json" -and $value.schemaVersion -eq "1.0") {
        $value.schemaVersion = "2.0"
        $value | Add-Member -NotePropertyName newOrders -NotePropertyValue @()
        $value | Add-Member -NotePropertyName workOutcomes -NotePropertyValue @()
        $value | Add-Member -NotePropertyName goalComplete -NotePropertyValue ([bool]$value.accept)
    }
    return ConvertTo-Json -InputObject $value -Depth 30 -Compress
}
