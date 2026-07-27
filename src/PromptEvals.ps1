function Invoke-ReviewLoopPromptEvalSuite {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][string]$Role,
        [Parameter(Mandatory = $true)][string]$Suite,
        [Parameter(Mandatory = $true)][string]$Rubric,
        [Parameter(Mandatory = $true)][string[]]$AllowedVerdicts,
        [Parameter(Mandatory = $true)][object[]]$Cases,
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$LogRoot,
        [string]$CodexPath = ""
    )

    $casePayload = @($Cases | ForEach-Object {
        [pscustomobject]@{
            caseId = [string]$_.CaseId
            evidence = [string]$_.Description
        }
    })
    $prompt = @"
Apply the following production rubric independently to every supplied historical case.
Return exactly one result per case, preserving caseId and using the production verdict vocabulary.
The only allowed verdicts for this suite are: $($AllowedVerdicts -join ', ').
Do not invent aliases, singular/plural variants, or new labels.
Do not edit files and do not run build or test commands during this read-only qualification.
Inspect the current repository with read-only operations when a case asks for current-code verification.
Treat supplied historical test results as evidence only when the case binds them to the relevant code state.

Production rubric:
--- begin rubric ---
$Rubric
--- end rubric ---

Cases:
$(ConvertTo-ReviewLoopJsonCompact $casePayload)
"@
    $call = Invoke-ConfiguredCodexRole `
        -Config $Config -Role $Role -RepoPath $RepoPath -Speed "standard" `
        -Prompt $prompt -LogRoot $LogRoot -SchemaName "prompt-eval-suite-v1.schema.json" `
        -CodexPath $CodexPath -CallId "eval-$($Suite.ToLowerInvariant())"
    Assert-ReviewLoopRoleSuccess $call

    $actualById = @{}
    foreach ($result in @($call.StructuredResult.cases)) {
        $actualById[[string]$result.caseId] = $result
    }
    $caseResults = foreach ($case in $Cases) {
        $id = [string]$case.CaseId
        $actual = $actualById[$id]
        [pscustomobject]@{
            CaseId = $id
            Expected = [string]$case.Expected
            Actual = if ($null -eq $actual) { "<missing>" } else { [string]$actual.verdict }
            Confidence = if ($null -eq $actual) { "<missing>" } else { [string]$actual.confidence }
            Passed = $null -ne $actual -and [string]$actual.verdict -eq [string]$case.Expected
            Rationale = if ($null -eq $actual) { "Kein Ergebnis." } else { [string]$actual.rationale }
        }
    }
    return [pscustomobject]@{
        Suite = $Suite
        Role = $Role
        Passed = @($caseResults | Where-Object { -not $_.Passed }).Count -eq 0
        Cases = @($caseResults)
        Usage = $call.Usage
        Call = $call
    }
}

function Test-CodexReviewLoopPrompts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [string]$ConfigPath = "",
        [string]$HistoricalLogRoot = "",
        [string]$CodexPath = ""
    )

    $repo = Resolve-ReviewLoopPath -Path $RepoPath -MustExist
    $resolvedConfigPath = Resolve-ReviewLoopConfigPath -RepoPath $repo -ConfigPath $ConfigPath
    $config = Import-ReviewLoopConfig -ConfigPath $resolvedConfigPath
    $casesPath = Join-Path $script:ModuleRoot "evals\historical-cases.psd1"
    $cases = Import-PowerShellDataFile -LiteralPath $casesPath
    $requiresHistoricalLogs = @($cases.Normalizer | Where-Object {
        $_.ContainsKey("HistoricalNativePath")
    }).Count -gt 0
    if ($requiresHistoricalLogs -and [string]::IsNullOrWhiteSpace($HistoricalLogRoot)) {
        throw "HistoricalLogRoot ist für Eval-Fälle mit HistoricalNativePath erforderlich."
    }
    $history = if ([string]::IsNullOrWhiteSpace($HistoricalLogRoot)) {
        ""
    }
    else {
        Resolve-ReviewLoopPath -Path $HistoricalLogRoot -MustExist
    }
    $beforeHead = Get-ReviewLoopGitValue -RepoPath $repo -Arguments @("rev-parse", "HEAD")
    $beforeStatus = Get-ReviewLoopGitValue -RepoPath $repo -Arguments @("status", "--porcelain=v1", "--untracked-files=all")
    $evalRoot = Join-Path $script:ModuleRoot ("eval-results\{0}" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
    [System.IO.Directory]::CreateDirectory($evalRoot) | Out-Null

    foreach ($normalizerCase in $cases.Normalizer) {
        if ($normalizerCase.ContainsKey("HistoricalNativePath")) {
            $nativePath = Join-Path $history ([string]$normalizerCase.HistoricalNativePath)
            $normalizerCase["Description"] = Get-Content -Raw -LiteralPath $nativePath
        }
    }

    $suites = [System.Collections.Generic.List[object]]::new()
    [void]$suites.Add((Invoke-ReviewLoopPromptEvalSuite `
        -Config $config -Role "TriggerJudge" -Suite "Trigger" `
        -Rubric (Get-Content -Raw -LiteralPath (Get-ReviewLoopResourcePath -Kind prompts -Name "trigger-judge.md")) `
        -AllowedVerdicts @("same_root_cause", "same_contract_different_edge", "regression_from_fix", "independent_same_file", "resolved_or_obsolete", "insufficient_evidence") `
        -Cases @($cases.Trigger) -RepoPath $repo -LogRoot $evalRoot -CodexPath $CodexPath))
    [void]$suites.Add((Invoke-ReviewLoopPromptEvalSuite `
        -Config $config -Role "ArchitectureCritic" -Suite "Critic" `
        -Rubric (Get-Content -Raw -LiteralPath (Get-ReviewLoopResourcePath -Kind prompts -Name "architecture-critic.md")) `
        -AllowedVerdicts @("approve", "revise", "reject_to_point_fix") `
        -Cases @($cases.Critic) -RepoPath $repo -LogRoot $evalRoot -CodexPath $CodexPath))
    [void]$suites.Add((Invoke-ReviewLoopPromptEvalSuite `
        -Config $config -Role "FindingVerifier" -Suite "Verifier" `
        -Rubric (Get-Content -Raw -LiteralPath (Get-ReviewLoopResourcePath -Kind prompts -Name "verifier.md")) `
        -AllowedVerdicts @("reproduced", "resolved", "obsolete", "insufficient_evidence") `
        -Cases @($cases.Verifier) -RepoPath $repo -LogRoot $evalRoot -CodexPath $CodexPath))
    [void]$suites.Add((Invoke-ReviewLoopPromptEvalSuite `
        -Config $config -Role "Normalizer" -Suite "Normalizer" `
        -Rubric (Get-Content -Raw -LiteralPath (Get-ReviewLoopResourcePath -Kind prompts -Name "normalizer.md")) `
        -AllowedVerdicts @("clean", "findings") `
        -Cases @($cases.Normalizer) -RepoPath $repo -LogRoot $evalRoot -CodexPath $CodexPath))

    $afterHead = Get-ReviewLoopGitValue -RepoPath $repo -Arguments @("rev-parse", "HEAD")
    $afterStatus = Get-ReviewLoopGitValue -RepoPath $repo -Arguments @("status", "--porcelain=v1", "--untracked-files=all")
    $repoUnchanged = $beforeHead -eq $afterHead -and $beforeStatus -eq $afterStatus
    $summary = [pscustomobject][ordered]@{
        SchemaVersion = "1.0"
        Speed = "standard"
        RepoPath = $repo
        RepoUnchanged = $repoUnchanged
        Passed = $repoUnchanged -and @($suites | Where-Object { -not $_.Passed }).Count -eq 0
        Suites = $suites.ToArray()
        CreatedAt = [DateTimeOffset]::UtcNow.ToString("O")
    }
    Write-ReviewLoopAtomicJson -Path (Join-Path $evalRoot "summary.json") -Value $summary
    return $summary
}
