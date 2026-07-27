function Get-ReviewLoopResourcePath {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("prompts", "schemas")][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Name
    )

    return Join-Path (Join-Path $script:ModuleRoot $Kind) $Name
}

function Get-ReviewLoopPrompt {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][hashtable]$Values
    )

    $path = Get-ReviewLoopResourcePath -Kind prompts -Name $Name
    $prompt = Get-Content -Raw -LiteralPath $path
    foreach ($entry in $Values.GetEnumerator()) {
        $prompt = $prompt.Replace("{{{0}}}" -f $entry.Key, [string]$entry.Value)
    }
    if ($prompt -match "\{\{[A-Z0-9_]+\}\}") {
        throw "Prompt '$Name' contains unreplaced placeholders."
    }
    return $prompt
}

function Invoke-ConfiguredCodexRole {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][string]$Role,
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$Speed,
        [Parameter(Mandatory = $true)][string]$Prompt,
        [Parameter(Mandatory = $true)][string]$LogRoot,
        [string]$SchemaName = "",
        [ValidateSet("Exec", "Review", "Resume")][string]$Mode = "Exec",
        [string]$ReviewBase = "",
        [string]$ThreadId = "",
        [string]$CodexPath = "",
        [string]$CallId = "",
        [object]$State = $null,
        [string]$StatePath = ""
    )

    $roleConfig = Get-ReviewLoopRoleConfig -Config $Config -Role $Role
    $schemaPath = if ([string]::IsNullOrWhiteSpace($SchemaName)) {
        ""
    }
    else {
        Get-ReviewLoopResourcePath -Kind schemas -Name $SchemaName
    }
    $arguments = @{
        Role = $Role
        RepoPath = $RepoPath
        Model = [string]$roleConfig.Model
        Thinking = [string]$roleConfig.Thinking
        Speed = $Speed
        Sandbox = [string]$roleConfig.Sandbox
        Prompt = $Prompt
        LogRoot = $LogRoot
        SchemaPath = $schemaPath
        Mode = $Mode
        ReviewBase = $ReviewBase
        ThreadId = $ThreadId
        CallId = $CallId
    }
    if (-not [string]::IsNullOrWhiteSpace($CodexPath)) {
        $arguments.CodexPath = $CodexPath
    }
    $call = Invoke-CodexCliRole @arguments

    if ($null -ne $State) {
        Add-ReviewLoopRoleCall -State $State -Call $call | Out-Null
        if (-not [string]::IsNullOrWhiteSpace($StatePath)) {
            Write-ReviewLoopState -Path $StatePath -State $State | Out-Null
        }
    }
    return $call
}

function Assert-ReviewLoopRoleSuccess {
    param([Parameter(Mandatory = $true)][object]$Call)

    if (-not $Call.Success) {
        throw "Codex role '$($Call.Role)' failed ($($Call.FailureKind)): $($Call.FailureReason)"
    }
}

function Invoke-ReviewLoopReview {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$Speed,
        [Parameter(Mandatory = $true)][string]$RunRoot,
        [string]$CodexPath = ""
    )

    $cycle = [int]$State.ReviewCycle
    $nativePrompt = @"
Review the complete branch diff against $($Config.ReviewBase).
Report only discrete, actionable correctness, security, reliability, or material performance defects.
Ignore style-only cleanup and optional architecture ideas. Verify each finding against current code.
Do not run build or test commands in this read-only review role. Inspect relevant tests instead; executable host gates run separately.
Keep investigation scoped to changed hunks, their direct dependencies, and relevant tests. Avoid repeated broad searches and full-file dumps.
Prefer narrow line ranges and capped search results. On Windows, discover wildcard matches with rg --files -g or Get-ChildItem instead of passing wildcard path literals to rg or Get-Content.
"@
    $native = Invoke-ConfiguredCodexRole `
        -Config $Config `
        -Role "Reviewer" `
        -RepoPath $RepoPath `
        -Speed $Speed `
        -Prompt $nativePrompt `
        -LogRoot $RunRoot `
        -Mode Review `
        -ReviewBase ([string]$Config.ReviewBase) `
        -CodexPath $CodexPath `
        -CallId ("review-{0:d2}-native" -f $cycle) `
        -State $State `
        -StatePath $StatePath
    Assert-ReviewLoopRoleSuccess $native

    $head = Get-ReviewLoopGitValue -RepoPath $RepoPath -Arguments @("rev-parse", "HEAD")
    $normalizerPrompt = Get-ReviewLoopPrompt -Name "normalizer.md" -Values @{
        REPOSITORY = $RepoPath
        HEAD = $head
        REVIEW_BASE = [string]$Config.ReviewBase
        NATIVE_REVIEW = $native.FinalMessage
    }
    $normalized = Invoke-ConfiguredCodexRole `
        -Config $Config `
        -Role "Normalizer" `
        -RepoPath $RepoPath `
        -Speed $Speed `
        -Prompt $normalizerPrompt `
        -LogRoot $RunRoot `
        -SchemaName "review-result-v1.schema.json" `
        -CodexPath $CodexPath `
        -CallId ("review-{0:d2}-normalized" -f $cycle) `
        -State $State `
        -StatePath $StatePath
    Assert-ReviewLoopRoleSuccess $normalized

    $result = $normalized.StructuredResult
    $findingCount = @($result.findings).Count
    if ([string]$result.classification -eq "clean" -and $findingCount -ne 0) {
        throw "Normalizer reported clean but returned $findingCount findings."
    }
    if ([string]$result.classification -eq "findings" -and $findingCount -eq 0) {
        throw "Normalizer reported findings but returned no finding."
    }

    if ([string]$result.classification -eq "clean") {
        Write-ReviewLoopStatus -Message "Review is clean: $($result.summary)" -Kind Success
    }
    else {
        Write-ReviewLoopStatus -Message "$findingCount Finding(s): $($result.summary)" -Kind Review
        foreach ($finding in @($result.findings)) {
            $location = [string]$finding.path
            if ($null -ne $finding.line -and [int]$finding.line -gt 0) {
                $location += ":$($finding.line)"
            }
            Write-ReviewLoopStatus -Message "$($finding.priority) · $($finding.title) · $location" -Kind Review -Indent 1
            if (Test-ReviewLoopOutputLevel -Minimum balanced) {
                Write-ReviewLoopStatus -Message "Root cause: $($finding.rootCause)" -Kind Muted -Indent 2
            }
        }
    }

    return [pscustomobject]@{
        ReviewId = "review-{0:d2}" -f $cycle
        Head = $head
        Native = $native
        NormalizedCall = $normalized
        Result = $result
    }
}

function Test-ReviewLoopArchitectureRelation {
    param([Parameter(Mandatory = $true)][object]$Decision)

    return [bool]$Decision.architectureRecommended -and
        [string]$Decision.relation -in @("same_root_cause", "same_contract_different_edge")
}

function Test-ReviewLoopDecisionsAgree {
    param(
        [Parameter(Mandatory = $true)][object]$Left,
        [Parameter(Mandatory = $true)][object]$Right
    )

    return [string]$Left.relation -eq [string]$Right.relation -and
        [bool]$Left.architectureRecommended -eq [bool]$Right.architectureRecommended
}

function Invoke-ReviewLoopTriggerJudge {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$Speed,
        [Parameter(Mandatory = $true)][string]$RunRoot,
        [Parameter(Mandatory = $true)][object]$Finding,
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()][object[]]$Candidates,
        [string]$CodexPath = ""
    )

    $Candidates = @($Candidates)
    if ($Candidates.Count -eq 0) {
        return [pscustomobject]@{
            ArchitectureRecommended = $false
            Relation = "insufficient_evidence"
            Confidence = "high"
            Rationale = "No semantic candidates in the ledger."
            Decision = $null
            Calls = @()
        }
    }

    $candidatePayload = @($Candidates | ForEach-Object {
        [pscustomobject]@{
            finding = $_.Finding
            semanticSignals = [pscustomobject]@{
                sameComponent = $_.SameComponent
                sameRootCause = $_.SameRootCause
                sameInvariant = $_.SameInvariant
                sameCluster = $_.SameCluster
                overlappingFixPaths = $_.OverlappingFixPaths
            }
        }
    })
    $prompt = Get-ReviewLoopPrompt -Name "trigger-judge.md" -Values @{
        CURRENT_FINDING = ConvertTo-ReviewLoopJsonCompact $Finding
        CANDIDATES = ConvertTo-ReviewLoopJsonCompact $candidatePayload
    }
    $calls = [System.Collections.Generic.List[object]]::new()
    $primary = Invoke-ConfiguredCodexRole `
        -Config $Config -Role "TriggerJudge" -RepoPath $RepoPath -Speed $Speed `
        -Prompt $prompt -LogRoot $RunRoot -SchemaName "trigger-decision-v1.schema.json" `
        -CodexPath $CodexPath -CallId "$($Finding.Id)-trigger-primary" -State $State -StatePath $StatePath
    Assert-ReviewLoopRoleSuccess $primary
    [void]$calls.Add($primary)
    $decision = $primary.StructuredResult

    $needsConfirmation = (Test-ReviewLoopArchitectureRelation $decision) -or
        [string]$decision.confidence -ne "high" -or
        [string]$decision.relation -eq "insufficient_evidence"
    if (-not $needsConfirmation) {
        return [pscustomobject]@{
            ArchitectureRecommended = $false
            Relation = [string]$decision.relation
            Confidence = [string]$decision.confidence
            Rationale = [string]$decision.rationale
            Decision = $decision
            Calls = $calls.ToArray()
        }
    }

    $confirm = Invoke-ConfiguredCodexRole `
        -Config $Config -Role "TriggerConfirm" -RepoPath $RepoPath -Speed $Speed `
        -Prompt $prompt -LogRoot $RunRoot -SchemaName "trigger-decision-v1.schema.json" `
        -CodexPath $CodexPath -CallId "$($Finding.Id)-trigger-confirm" -State $State -StatePath $StatePath
    Assert-ReviewLoopRoleSuccess $confirm
    [void]$calls.Add($confirm)

    if (Test-ReviewLoopDecisionsAgree $decision $confirm.StructuredResult) {
        $confirmed = $confirm.StructuredResult
        return [pscustomobject]@{
            ArchitectureRecommended = Test-ReviewLoopArchitectureRelation $confirmed
            Relation = [string]$confirmed.relation
            Confidence = [string]$confirmed.confidence
            Rationale = [string]$confirmed.rationale
            Decision = $confirmed
            Calls = $calls.ToArray()
        }
    }

    $tiePrompt = "$prompt`n`nPrimary decision:`n$(ConvertTo-ReviewLoopJsonCompact $decision)`n`nIndependent decision:`n$(ConvertTo-ReviewLoopJsonCompact $confirm.StructuredResult)`n`nAdjudicate the disagreement from repository evidence."
    $tie = Invoke-ConfiguredCodexRole `
        -Config $Config -Role "TriggerTieBreak" -RepoPath $RepoPath -Speed $Speed `
        -Prompt $tiePrompt -LogRoot $RunRoot -SchemaName "trigger-decision-v1.schema.json" `
        -CodexPath $CodexPath -CallId "$($Finding.Id)-trigger-tie" -State $State -StatePath $StatePath
    Assert-ReviewLoopRoleSuccess $tie
    [void]$calls.Add($tie)
    $final = $tie.StructuredResult
    if ([string]$final.confidence -ne "high" -or [string]$final.relation -eq "insufficient_evidence") {
        throw "blocked/model_disagreement: Trigger decision remains unclear after adjudication."
    }

    return [pscustomobject]@{
        ArchitectureRecommended = Test-ReviewLoopArchitectureRelation $final
        Relation = [string]$final.relation
        Confidence = [string]$final.confidence
        Rationale = [string]$final.rationale
        Decision = $final
        Calls = $calls.ToArray()
    }
}

function Get-ReviewLoopArchitectureScope {
    param([Parameter(Mandatory = $true)][object]$Proposal)

    $paths = @($Proposal.steps | ForEach-Object { [string]$_.path } | Sort-Object -Unique)
    $productionPaths = @($Proposal.steps | Where-Object { [bool]$_.productionCode } | ForEach-Object { [string]$_.path } | Sort-Object -Unique)
    return [pscustomobject]@{
        Paths = $paths
        ProductionPaths = $productionPaths
        PathCount = $paths.Count
        ProductionPathCount = $productionPaths.Count
        BreaksPublicContract = [bool]$Proposal.breaksPublicContract
    }
}

function Test-ReviewLoopCritiquesAgree {
    param(
        [Parameter(Mandatory = $true)][object]$Left,
        [Parameter(Mandatory = $true)][object]$Right
    )
    return [string]$Left.decision -eq [string]$Right.decision
}

function Invoke-ReviewLoopArchitectureGate {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$Speed,
        [Parameter(Mandatory = $true)][string]$RunRoot,
        [Parameter(Mandatory = $true)][object[]]$Findings,
        [Parameter(Mandatory = $true)][object]$Trigger,
        [string]$CodexPath = ""
    )

    $findingJson = ConvertTo-ReviewLoopJsonCompact $Findings
    $architectPrompt = Get-ReviewLoopPrompt -Name "architect.md" -Values @{
        FINDINGS = $findingJson
        TRIGGER = ConvertTo-ReviewLoopJsonCompact $Trigger
        EVIDENCE = "Inspect current repository code and tests directly. Treat this supplied cluster as the complete allowed scope."
    }
    $revision = 0
    while ($true) {
        $architect = Invoke-ConfiguredCodexRole `
            -Config $Config -Role "Architect" -RepoPath $RepoPath -Speed $Speed `
            -Prompt $architectPrompt -LogRoot $RunRoot -SchemaName "architecture-proposal-v1.schema.json" `
            -CodexPath $CodexPath -CallId ("$($State.ActiveClusterId)-architecture-r$revision") -State $State -StatePath $StatePath
        Assert-ReviewLoopRoleSuccess $architect
        $proposal = $architect.StructuredResult
        Write-ReviewLoopStatus -Message "Proposal r${revision}: $($proposal.recommendation) · $($proposal.summary)" -Kind Architecture
        if ([string]$proposal.recommendation -in @("point_fix", "no_architecture")) {
            Write-ReviewLoopStatus -Message "Architect limited the cluster to a point fix." -Kind Warning -Indent 1
            return [pscustomobject]@{ Approved = $false; PointFix = $true; Proposal = $proposal; Critique = $null }
        }

        $scope = Get-ReviewLoopArchitectureScope $proposal
        Write-ReviewLoopStatus -Message "Scope: $($scope.PathCount) paths, $($scope.ProductionPathCount) production" -Kind Architecture -Indent 1
        if ($scope.BreaksPublicContract) {
            throw "Architecture proposal breaks a public contract."
        }
        if ($scope.PathCount -gt [int]$Config.MaxArchitecturePaths) {
            throw "Architecture proposal covers $($scope.PathCount) paths; the limit is $($Config.MaxArchitecturePaths)."
        }
        if ($scope.ProductionPathCount -gt [int]$Config.MaxProductionPaths) {
            throw "Architecture proposal covers $($scope.ProductionPathCount) production paths; the limit is $($Config.MaxProductionPaths)."
        }

        $criticPrompt = Get-ReviewLoopPrompt -Name "architecture-critic.md" -Values @{
            FINDINGS = $findingJson
            PROPOSAL = ConvertTo-ReviewLoopJsonCompact $proposal
            EVIDENCE = "Inspect current repository code and tests directly. Fail closed on missing paths or unsupported causal links."
        }
        $critic = Invoke-ConfiguredCodexRole `
            -Config $Config -Role "ArchitectureCritic" -RepoPath $RepoPath -Speed $Speed `
            -Prompt $criticPrompt -LogRoot $RunRoot -SchemaName "architecture-critique-v1.schema.json" `
            -CodexPath $CodexPath -CallId ("$($State.ActiveClusterId)-critic-r$revision") -State $State -StatePath $StatePath
        Assert-ReviewLoopRoleSuccess $critic
        $decision = $critic.StructuredResult
        Write-ReviewLoopStatus -Message "Terra-Critic: $($decision.decision) · Confidence $($decision.confidence)" -Kind Architecture

        if ([string]$decision.decision -eq "approve") {
            $veto = Invoke-ConfiguredCodexRole `
                -Config $Config -Role "ArchitectureVeto" -RepoPath $RepoPath -Speed $Speed `
                -Prompt $criticPrompt -LogRoot $RunRoot -SchemaName "architecture-critique-v1.schema.json" `
                -CodexPath $CodexPath -CallId ("$($State.ActiveClusterId)-critic-veto-r$revision") -State $State -StatePath $StatePath
            Assert-ReviewLoopRoleSuccess $veto
            Write-ReviewLoopStatus -Message "Sol-Veto: $($veto.StructuredResult.decision) · Confidence $($veto.StructuredResult.confidence)" -Kind Architecture
            if (Test-ReviewLoopCritiquesAgree $decision $veto.StructuredResult) {
                return [pscustomobject]@{ Approved = $true; PointFix = $false; Proposal = $proposal; Critique = $veto.StructuredResult }
            }

            $tiePrompt = "$criticPrompt`n`nTerra critique:`n$(ConvertTo-ReviewLoopJsonCompact $decision)`n`nSol veto:`n$(ConvertTo-ReviewLoopJsonCompact $veto.StructuredResult)`n`nAdjudicate once, fail closed."
            $tie = Invoke-ConfiguredCodexRole `
                -Config $Config -Role "ArchitectureTieBreak" -RepoPath $RepoPath -Speed $Speed `
                -Prompt $tiePrompt -LogRoot $RunRoot -SchemaName "architecture-critique-v1.schema.json" `
                -CodexPath $CodexPath -CallId ("$($State.ActiveClusterId)-critic-tie-r$revision") -State $State -StatePath $StatePath
            Assert-ReviewLoopRoleSuccess $tie
            $decision = $tie.StructuredResult
            Write-ReviewLoopStatus -Message "Terra-Tie-Break: $($decision.decision) · Confidence $($decision.confidence)" -Kind Architecture
            if ([string]$decision.confidence -ne "high") {
                throw "blocked/model_disagreement: Architecture critique remains unclear after adjudication."
            }
            if ([string]$decision.decision -eq "approve") {
                return [pscustomobject]@{ Approved = $true; PointFix = $false; Proposal = $proposal; Critique = $decision }
            }
        }

        if ([string]$decision.decision -eq "reject_to_point_fix") {
            return [pscustomobject]@{ Approved = $false; PointFix = $true; Proposal = $proposal; Critique = $decision }
        }
        if ([string]$decision.decision -eq "blocked") {
            throw "Architecture proposal was blocked: $($decision.rationale)"
        }
        if ([string]$decision.decision -ne "revise") {
            throw "Unsupported architecture decision: $($decision.decision)"
        }
        if ($revision -ge [int]$Config.MaxArchitectureRevisions) {
            throw "Architecture proposal requires more than the single allowed revision."
        }
        $revision++
        Write-ReviewLoopStatus -Message "Requesting the single allowed architecture-proposal revision." -Kind Warning
        $State.ArchitectureRevision = $revision
        Write-ReviewLoopState -Path $StatePath -State $State | Out-Null
        $architectPrompt += "`n`nRequired critic changes for the single allowed revision:`n$(ConvertTo-ReviewLoopJsonCompact $decision)"
    }
}

function Invoke-ReviewLoopFixer {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$Speed,
        [Parameter(Mandatory = $true)][string]$RunRoot,
        [Parameter(Mandatory = $true)][object[]]$Findings,
        [Parameter(Mandatory = $true)][AllowNull()][object]$Strategy,
        [Parameter(Mandatory = $true)][int]$Attempt,
        [string]$ThreadId = "",
        [string]$CodexPath = ""
    )

    $role = if ($null -ne $Strategy -and [bool]$Strategy.Approved) { "ArchitectureFixer" } else { "PointFixer" }
    $strategyPayload = if ($null -eq $Strategy) { "Bounded point fix." } else { ConvertTo-ReviewLoopJsonCompact $Strategy }
    $prompt = Get-ReviewLoopPrompt -Name "fixer.md" -Values @{
        FINDINGS = ConvertTo-ReviewLoopJsonCompact $Findings
        STRATEGY = $strategyPayload
    }
    $mode = if ($Attempt -eq 1) { "Exec" } else { "Resume" }
    return Invoke-ConfiguredCodexRole `
        -Config $Config -Role $role -RepoPath $RepoPath -Speed $Speed `
        -Prompt $prompt -LogRoot $RunRoot -SchemaName "fixer-result-v1.schema.json" `
        -Mode $mode -ThreadId $ThreadId -CodexPath $CodexPath `
        -CallId ("$($State.ActiveClusterId)-fix-$Attempt") -State $State -StatePath $StatePath
}

function ConvertTo-ReviewLoopComparableCommand {
    param([AllowNull()][string]$Command)

    return ([regex]::Replace(($Command ?? "").Trim(), "\s+", " ")).ToLowerInvariant()
}

function Test-ReviewLoopFixerTestEvidence {
    param(
        [Parameter(Mandatory = $true)][object]$FixerResult,
        [Parameter(Mandatory = $true)][object]$VerificationResult
    )

    if (-not [bool]$VerificationResult.targetedTest.passed) {
        return $false
    }
    $verificationCommand = ConvertTo-ReviewLoopComparableCommand `
        -Command ([string]$VerificationResult.targetedTest.command)
    if ([string]::IsNullOrWhiteSpace($verificationCommand)) {
        return $false
    }
    foreach ($test in @($FixerResult.targetedTests)) {
        if ([bool]$test.passed -and
            (ConvertTo-ReviewLoopComparableCommand -Command ([string]$test.command)) -eq $verificationCommand) {
            return $true
        }
    }
    return $false
}

function Invoke-ReviewLoopVerifier {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$Speed,
        [Parameter(Mandatory = $true)][string]$RunRoot,
        [Parameter(Mandatory = $true)][object[]]$Findings,
        [Parameter(Mandatory = $true)][object]$FixerCall,
        [string]$CodexPath = ""
    )

    $diff = Get-ReviewLoopGitValue -RepoPath $RepoPath -Arguments @("diff", "--no-ext-diff", "--unified=80")
    if ($diff.Length -gt 120000) {
        $diff = $diff.Substring(0, 120000) + "`n[diff truncated by orchestrator]"
    }
    $prompt = Get-ReviewLoopPrompt -Name "verifier.md" -Values @{
        FINDINGS = ConvertTo-ReviewLoopJsonCompact $Findings
        FIXER_RESULT = ConvertTo-ReviewLoopJsonCompact $FixerCall.StructuredResult
        DIFF = $diff
    }
    $primary = Invoke-ConfiguredCodexRole `
        -Config $Config -Role "FindingVerifier" -RepoPath $RepoPath -Speed $Speed `
        -Prompt $prompt -LogRoot $RunRoot -SchemaName "verifier-result-v1.schema.json" `
        -CodexPath $CodexPath -CallId "$($State.ActiveClusterId)-verify-primary" -State $State -StatePath $StatePath
    Assert-ReviewLoopRoleSuccess $primary
    $result = $primary.StructuredResult
    $hasFixerTestEvidence = Test-ReviewLoopFixerTestEvidence `
        -FixerResult $FixerCall.StructuredResult `
        -VerificationResult $result
    if ([string]$result.verdict -eq "resolved" -and
        [string]$result.confidence -eq "high" -and
        $hasFixerTestEvidence) {
        return [pscustomobject]@{
            Accepted = $true
            Result = $result
            Calls = @($primary)
            Basis = "Luna + matching fixer test evidence"
        }
    }
    if ([string]$result.verdict -in @("reproduced", "obsolete") -and [string]$result.confidence -eq "high") {
        return [pscustomobject]@{
            Accepted = $false
            Result = $result
            Calls = @($primary)
            Basis = "Luna"
        }
    }

    $confirm = Invoke-ConfiguredCodexRole `
        -Config $Config -Role "VerifierConfirm" -RepoPath $RepoPath -Speed $Speed `
        -Prompt $prompt -LogRoot $RunRoot -SchemaName "verifier-result-v1.schema.json" `
        -CodexPath $CodexPath -CallId "$($State.ActiveClusterId)-verify-confirm" -State $State -StatePath $StatePath
    Assert-ReviewLoopRoleSuccess $confirm
    $confirmed = $confirm.StructuredResult
    if ([string]$confirmed.verdict -eq [string]$result.verdict -and [string]$confirmed.confidence -eq "high") {
        return [pscustomobject]@{
            Accepted = [string]$confirmed.verdict -eq "resolved"
            Result = $confirmed
            Calls = @($primary, $confirm)
            Basis = "Luna + Sol confirmation"
        }
    }

    $tiePrompt = "$prompt`n`nLuna verification:`n$(ConvertTo-ReviewLoopJsonCompact $result)`n`nSol verification:`n$(ConvertTo-ReviewLoopJsonCompact $confirmed)`n`nAdjudicate the disagreement once."
    $tie = Invoke-ConfiguredCodexRole `
        -Config $Config -Role "VerifierTieBreak" -RepoPath $RepoPath -Speed $Speed `
        -Prompt $tiePrompt -LogRoot $RunRoot -SchemaName "verifier-result-v1.schema.json" `
        -CodexPath $CodexPath -CallId "$($State.ActiveClusterId)-verify-tie" -State $State -StatePath $StatePath
    Assert-ReviewLoopRoleSuccess $tie
    $final = $tie.StructuredResult
    if ([string]$final.confidence -ne "high" -or [string]$final.verdict -eq "insufficient_evidence") {
        throw "blocked/model_disagreement: Finding verification remains unclear after adjudication."
    }
    return [pscustomobject]@{
        Accepted = [string]$final.verdict -eq "resolved"
        Result = $final
        Calls = @($primary, $confirm, $tie)
        Basis = "Terra adjudication"
    }
}
