function Get-ReviewLoopResourcePath {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("prompts", "schemas")][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Name
    )

    return Join-Path (Join-Path $script:ModuleRoot $Kind) $Name
}

function Get-ReviewLoopOperationalInstructions {
    param([Parameter(Mandatory = $true)][string]$Role)

    $instructions = @"
This is an unattended Windows PowerShell run.
Work only inside the supplied repository and prefer repository-relative paths.
Do not inspect credentials or external URLs.
Do not stop processes or change Git refs, the index, or the worktree. The orchestrator owns process lifetime, tests, retries, and commits.
"@
    if ($Role -eq "TriggerJudge") {
        return "$instructions`nDo not run shell commands or inspect the repository; classify only the supplied ledger evidence. Any possible architecture decision will be checked independently against the repository."
    }
    if ($Role -in @("PointFixer", "ArchitectureFixer")) {
        return "$instructions`nEdit only the repository files needed for the supplied findings. Point-fix production changes must stay within the supplied path/fixPaths; regression tests may use conventional test/spec paths. Do not run builds or tests; return one targeted test command for the orchestrator to execute."
    }
    return "$instructions`nThis role is read-only. Do not edit files or run builds or tests."
}

function Get-ReviewLoopPrompt {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][hashtable]$Values
    )

    $path = Get-ReviewLoopResourcePath -Kind prompts -Name $Name
    $template = Get-Content -Raw -LiteralPath $path
    $placeholderPattern = "\{\{([A-Z0-9_]+)\}\}"
    $placeholders = @(
        [regex]::Matches($template, $placeholderPattern) |
            ForEach-Object { $_.Groups[1].Value } |
            Select-Object -Unique
    )
    $missing = @($placeholders | Where-Object { -not $Values.ContainsKey($_) })
    if ($missing.Count -gt 0) {
        throw "Prompt '$Name' is missing values for placeholder(s): $($missing -join ', ')."
    }

    $evaluator = [System.Text.RegularExpressions.MatchEvaluator]{
        param([System.Text.RegularExpressions.Match]$match)
        return [string]$Values[$match.Groups[1].Value]
    }
    return [regex]::Replace($template, $placeholderPattern, $evaluator)
}

function Assert-ReviewLoopExecutionUnchanged {
    param([Parameter(Mandatory = $true)][hashtable]$Config)

    if ($Config.ContainsKey("__ExecutionFingerprint") -and
        $Config.ContainsKey("__ConfigPath") -and
        (Get-ReviewLoopExecutionFingerprint -ConfigPath ([string]$Config.__ConfigPath)) -ne
            [string]$Config.__ExecutionFingerprint) {
        throw "Tool prompts, schemas, code, or the active profile changed during the run."
    }
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

    Assert-ReviewLoopExecutionUnchanged -Config $Config
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
        Sandbox = if ($Role -in @("PointFixer", "ArchitectureFixer")) {
            "workspace-write"
        }
        else {
            "read-only"
        }
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
    $operationalInstructions = Get-ReviewLoopOperationalInstructions -Role $Role
    $arguments.DeveloperInstructions = if ($Mode -eq "Review") {
        "$operationalInstructions`n`n$Prompt"
    }
    else {
        $operationalInstructions
    }
    $call = Invoke-CodexCliRole @arguments
    Assert-ReviewLoopExecutionUnchanged -Config $Config

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

function Assert-ReviewLoopReviewResult {
    param([Parameter(Mandatory = $true)][object]$Result)

    $findings = @($Result.findings)
    if ([string]$Result.classification -eq "clean" -and $findings.Count -ne 0) {
        throw "Reviewer reported clean but returned $($findings.Count) findings."
    }
    if ([string]$Result.classification -eq "findings" -and $findings.Count -eq 0) {
        throw "Reviewer reported findings but returned no finding."
    }
    if ($findings.Count -gt 12) {
        Stop-ReviewLoopBlocked -Message "Reviewer returned $($findings.Count) findings; the unattended per-review limit is 12."
    }
    foreach ($finding in $findings) {
        foreach ($name in @(
            "title", "path", "component", "rootCause", "invariant",
            "evidence", "reproduction", "suggestedFix", "suggestedTest"
        )) {
            if ([string]::IsNullOrWhiteSpace([string]$finding.$name)) {
                throw "Reviewer finding contains an empty '$name' field."
            }
        }
        if (-not (Test-ReviewLoopRepositoryRelativePath -Path ([string]$finding.path))) {
            throw "Reviewer finding path must be repository-relative: $($finding.path)"
        }
        $fixPaths = @($finding.fixPaths)
        if ($fixPaths.Count -eq 0 -or $fixPaths.Count -gt 20) {
            throw "Reviewer finding must contain 1..20 bounded fixPaths."
        }
        foreach ($path in $fixPaths) {
            if ([string]::IsNullOrWhiteSpace([string]$path) -or
                -not (Test-ReviewLoopRepositoryRelativePath -Path ([string]$path))) {
                throw "Reviewer finding contains an invalid fix path: $path"
            }
        }
        $canonicalPath = ConvertTo-ReviewLoopCanonicalText ([string]$finding.path)
        if ($canonicalPath -notin @($fixPaths | ForEach-Object {
            ConvertTo-ReviewLoopCanonicalText ([string]$_)
        })) {
            throw "Reviewer finding fixPaths must include its primary path '$($finding.path)'."
        }
    }
}

function Invoke-ReviewLoopReview {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][object]$Ledger,
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$Speed,
        [Parameter(Mandatory = $true)][string]$RunRoot,
        [string]$CodexPath = ""
    )

    $cycle = [int]$State.ReviewCycle
    $head = Get-ReviewLoopGitValue -RepoPath $RepoPath -Arguments @("rev-parse", "HEAD")
    if (-not (Test-ReviewLoopGitClean -RepoPath $RepoPath)) {
        throw "The worktree changed before the read-only review started."
    }
    $changedPathText = Get-ReviewLoopGitValue -RepoPath $RepoPath -Arguments @(
        "diff", "--name-only", "$($State.ReviewBaseCommit)...$head", "--"
    )
    $changedPaths = @($changedPathText -split "\r?\n" | ForEach-Object {
        ConvertTo-ReviewLoopCanonicalText $_
    } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $identityCatalog = @($Ledger.Findings | Where-Object {
        if ([string]$_.Status -in @("duplicate", "superseded")) {
            return $false
        }
        if ([string]$_.Status -in @("pending", "open", "fixing")) {
            return $true
        }
        return @($_.FixPaths | Where-Object {
            (ConvertTo-ReviewLoopCanonicalText $_) -in $changedPaths
        }).Count -gt 0
    } | Sort-Object UpdatedAt -Descending | Select-Object -First 200 | ForEach-Object {
        [pscustomobject]@{
            id = $_.Id
            status = $_.Status
            path = $_.Path
            component = $_.Component
            rootCause = $_.RootCause
            invariant = $_.Invariant
        }
    })
    $nativePrompt = @"
Review the complete branch diff against commit $($State.ReviewBaseCommit).
Report only discrete, actionable correctness, security, reliability, or material performance defects.
Ignore style-only cleanup and optional architecture ideas. Verify each finding against current code.
Keep investigation scoped to changed hunks, their direct dependencies, and relevant tests.
For a recurrence of an existing defect, reuse its path, component, rootCause, and invariant text verbatim
so its ledger identity remains stable. Existing identity catalog:
$(ConvertTo-ReviewLoopJsonCompact $identityCatalog)
"@
    $native = Invoke-ConfiguredCodexRole `
        -Config $Config `
        -Role "Reviewer" `
        -RepoPath $RepoPath `
        -Speed $Speed `
        -Prompt $nativePrompt `
        -LogRoot $RunRoot `
        -SchemaName "review-result-v1.schema.json" `
        -Mode Review `
        -ReviewBase ([string]$State.ReviewBaseCommit) `
        -CodexPath $CodexPath `
        -CallId ("review-{0:d2}-native" -f $cycle) `
        -State $State `
        -StatePath $StatePath
    Assert-ReviewLoopRoleSuccess $native

    $headAfter = Get-ReviewLoopGitValue -RepoPath $RepoPath -Arguments @("rev-parse", "HEAD")
    if ($headAfter -ne $head -or -not (Test-ReviewLoopGitClean -RepoPath $RepoPath)) {
        Stop-ReviewLoopBlocked -Message "Repository HEAD or worktree changed during the read-only review."
    }
    $result = $native.StructuredResult
    Assert-ReviewLoopReviewResult -Result $result
    $findingCount = @($result.findings).Count

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
        Call = $native
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

function Test-ReviewLoopPathLineEvidence {
    param(
        [Parameter(Mandatory = $true)][object]$Decision,
        [Parameter(Mandatory = $true)][string]$RepoPath
    )

    foreach ($item in @($Decision.evidence)) {
        $text = ([string]$item).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) {
            continue
        }
        $matches = @(
            [regex]::Matches(
                $text,
                '(?i)(?:^|\s|[\(\[])(?<path>[a-z0-9_@.+()-]+(?:[\\/][a-z0-9_@.+()-]+)*\.[a-z0-9_-]{1,12}):(?<line>\d+)\b'
            )
            [regex]::Matches(
                $text,
                '(?i)["''](?<path>[^"'']+\.[a-z0-9_-]{1,12}):(?<line>\d+)["'']'
            )
        )
        foreach ($match in $matches) {
            $path = [string]$match.Groups["path"].Value
            $line = [int]$match.Groups["line"].Value
            if ($line -lt 1 -or
                -not (Test-ReviewLoopRepositoryRelativePath -Path $path)) {
                continue
            }
            $fullPath = [System.IO.Path]::GetFullPath((Join-Path $RepoPath $path))
            $relative = [System.IO.Path]::GetRelativePath($RepoPath, $fullPath)
            if ($relative -eq ".." -or $relative.StartsWith("..\") -or
                -not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
                continue
            }
            $reader = $null
            try {
                $reader = [System.IO.File]::OpenText($fullPath)
                $currentLine = 0
                while ($currentLine -lt $line -and $null -ne $reader.ReadLine()) {
                    $currentLine++
                }
                if ($currentLine -ge $line) {
                    return $true
                }
            }
            finally {
                if ($null -ne $reader) {
                    $reader.Dispose()
                }
            }
        }
    }
    return $false
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
        -CodexPath $CodexPath -CallId "$($Finding.Id)-c$($State.ReviewCycle)-trigger-primary" -State $State -StatePath $StatePath
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

    $confirmPrompt = @"
$prompt

This is an independent confirmation. Inspect the current repository with bounded
read-only searches and reads. Evidence must cite concrete path:line locations
that prove or disprove the relationship.
"@
    $confirm = Invoke-ConfiguredCodexRole `
        -Config $Config -Role "TriggerConfirm" -RepoPath $RepoPath -Speed $Speed `
        -Prompt $confirmPrompt -LogRoot $RunRoot -SchemaName "trigger-decision-v1.schema.json" `
        -CodexPath $CodexPath -CallId "$($Finding.Id)-c$($State.ReviewCycle)-trigger-confirm" -State $State -StatePath $StatePath
    Assert-ReviewLoopRoleSuccess $confirm
    [void]$calls.Add($confirm)

    if ((Test-ReviewLoopDecisionsAgree $decision $confirm.StructuredResult) -and
        [string]$confirm.StructuredResult.confidence -eq "high" -and
        [string]$confirm.StructuredResult.relation -ne "insufficient_evidence" -and
        (Test-ReviewLoopPathLineEvidence -Decision $confirm.StructuredResult -RepoPath $RepoPath)) {
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

    $tiePrompt = "$confirmPrompt`n`nPrimary decision:`n$(ConvertTo-ReviewLoopJsonCompact $decision)`n`nIndependent decision:`n$(ConvertTo-ReviewLoopJsonCompact $confirm.StructuredResult)`n`nAdjudicate the disagreement from repository evidence."
    $tie = Invoke-ConfiguredCodexRole `
        -Config $Config -Role "TriggerTieBreak" -RepoPath $RepoPath -Speed $Speed `
        -Prompt $tiePrompt -LogRoot $RunRoot -SchemaName "trigger-decision-v1.schema.json" `
        -CodexPath $CodexPath -CallId "$($Finding.Id)-c$($State.ReviewCycle)-trigger-tie" -State $State -StatePath $StatePath
    Assert-ReviewLoopRoleSuccess $tie
    [void]$calls.Add($tie)
    $final = $tie.StructuredResult
    if ([string]$final.confidence -ne "high" -or
        [string]$final.relation -eq "insufficient_evidence" -or
        -not (Test-ReviewLoopPathLineEvidence -Decision $final -RepoPath $RepoPath)) {
        Stop-ReviewLoopBlocked -Message "blocked/model_disagreement: Trigger decision remains unclear after adjudication."
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
    $productionPaths = @($Proposal.steps | Where-Object {
        $path = ConvertTo-ReviewLoopCanonicalText ([string]$_.path)
        $clearlyNonProduction = $path -match '(^|/)(tests?|specs?|__tests__|docs?)(/|$)' -or
            $path -match '\.(md|markdown|rst|adoc)$'
        [bool]$_.productionCode -or -not $clearlyNonProduction
    } | ForEach-Object { [string]$_.path } | Sort-Object -Unique)
    return [pscustomobject]@{
        Paths = $paths
        ProductionPaths = $productionPaths
        PathCount = $paths.Count
        ProductionPathCount = $productionPaths.Count
        BreaksPublicContract = [bool]$Proposal.breaksPublicContract
    }
}

function Assert-ReviewLoopArchitectureProposal {
    param(
        [Parameter(Mandatory = $true)][object]$Proposal,
        [Parameter(Mandatory = $true)][object[]]$Findings
    )

    if ([string]$Proposal.recommendation -ne "consolidation") {
        return
    }
    $activeIds = @($Findings | ForEach-Object { [string]$_.Id } | Sort-Object -Unique)
    $proposalFindings = @($Proposal.findings)
    $proposalIds = @($proposalFindings | ForEach-Object {
        [string]$_.findingId
    } | Sort-Object -Unique)
    if ($proposalFindings.Count -ne $activeIds.Count -or
        $proposalIds.Count -ne $activeIds.Count -or
        @($activeIds | Where-Object { $_ -notin $proposalIds }).Count -gt 0 -or
        @($proposalIds | Where-Object { $_ -notin $activeIds }).Count -gt 0) {
        throw "Architecture proposal must cover exactly the active finding IDs."
    }
    foreach ($finding in $proposalFindings) {
        if ([string]$finding.disposition -eq "out_of_scope" -or
            [string]::IsNullOrWhiteSpace([string]$finding.reproduction) -or
            [string]::IsNullOrWhiteSpace([string]$finding.regressionTest)) {
            throw "Architecture proposal contains an incomplete finding disposition."
        }
    }
    $steps = @($Proposal.steps)
    if ($steps.Count -eq 0) {
        throw "A consolidation proposal must contain at least one bounded change step."
    }
    $coveredIds = [System.Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal)
    foreach ($step in $steps) {
        if ([string]::IsNullOrWhiteSpace([string]$step.path) -or
            -not (Test-ReviewLoopRepositoryRelativePath -Path ([string]$step.path)) -or
            [string]::IsNullOrWhiteSpace([string]$step.change) -or
            [string]::IsNullOrWhiteSpace([string]$step.regressionTest)) {
            throw "Architecture proposal contains an invalid or incomplete change step."
        }
        $stepIds = @($step.findingIds | ForEach-Object { [string]$_ })
        if ($stepIds.Count -eq 0 -or
            @($stepIds | Where-Object { $_ -notin $activeIds }).Count -gt 0) {
            throw "Every architecture step must reference active finding IDs only."
        }
        foreach ($id in $stepIds) {
            [void]$coveredIds.Add($id)
        }
    }
    if (@($activeIds | Where-Object { -not $coveredIds.Contains($_) }).Count -gt 0) {
        throw "Architecture proposal does not connect every finding to a change step."
    }
}

function Test-ReviewLoopCritiquesAgree {
    param(
        [Parameter(Mandatory = $true)][object]$Left,
        [Parameter(Mandatory = $true)][object]$Right
    )
    return [string]$Left.decision -eq [string]$Right.decision
}

function Test-ReviewLoopArchitectureApproval {
    param([Parameter(Mandatory = $true)][object]$Decision)

    return [string]$Decision.decision -eq "approve" -and
        [string]$Decision.confidence -eq "high" -and
        [bool]$Decision.coherentRootCause -and
        [bool]$Decision.allFindingsCovered -and
        [bool]$Decision.allRequiredPathsCovered -and
        [bool]$Decision.minimalEnough -and
        @($Decision.missingPaths).Count -eq 0 -and
        @($Decision.requiredChanges).Count -eq 0
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
            -CodexPath $CodexPath -CallId ("$($State.ActiveClusterId)-c$($State.ReviewCycle)-architecture-r$revision") -State $State -StatePath $StatePath
        Assert-ReviewLoopRoleSuccess $architect
        $proposal = $architect.StructuredResult
        Assert-ReviewLoopArchitectureProposal -Proposal $proposal -Findings $Findings
        Write-ReviewLoopStatus -Message "Proposal r${revision}: $($proposal.recommendation) · $($proposal.summary)" -Kind Architecture
        if ([string]$proposal.recommendation -in @("point_fix", "no_architecture")) {
            Write-ReviewLoopStatus -Message "Architect limited the cluster to a point fix." -Kind Warning -Indent 1
            return [pscustomobject]@{ Approved = $false; PointFix = $true; Proposal = $proposal; Critique = $null }
        }

        $scope = Get-ReviewLoopArchitectureScope $proposal
        Write-ReviewLoopStatus -Message "Scope: $($scope.PathCount) paths, $($scope.ProductionPathCount) production" -Kind Architecture -Indent 1
        if ($scope.BreaksPublicContract) {
            Stop-ReviewLoopBlocked -Message "Architecture proposal breaks a public contract."
        }
        if ($scope.PathCount -gt [int]$Config.MaxArchitecturePaths) {
            Stop-ReviewLoopBlocked -Message "Architecture proposal covers $($scope.PathCount) paths; the limit is $($Config.MaxArchitecturePaths)."
        }
        if ($scope.ProductionPathCount -gt [int]$Config.MaxProductionPaths) {
            Stop-ReviewLoopBlocked -Message "Architecture proposal covers $($scope.ProductionPathCount) production paths; the limit is $($Config.MaxProductionPaths)."
        }

        $criticPrompt = Get-ReviewLoopPrompt -Name "architecture-critic.md" -Values @{
            FINDINGS = $findingJson
            PROPOSAL = ConvertTo-ReviewLoopJsonCompact $proposal
            EVIDENCE = "Inspect current repository code and tests directly. Fail closed on missing paths or unsupported causal links."
        }
        $critic = Invoke-ConfiguredCodexRole `
            -Config $Config -Role "ArchitectureCritic" -RepoPath $RepoPath -Speed $Speed `
            -Prompt $criticPrompt -LogRoot $RunRoot -SchemaName "architecture-critique-v1.schema.json" `
            -CodexPath $CodexPath -CallId ("$($State.ActiveClusterId)-c$($State.ReviewCycle)-critic-r$revision") -State $State -StatePath $StatePath
        Assert-ReviewLoopRoleSuccess $critic
        $decision = $critic.StructuredResult
        Write-ReviewLoopStatus -Message "Terra-Critic: $($decision.decision) · Confidence $($decision.confidence)" -Kind Architecture

        if ([string]$decision.decision -eq "approve") {
            $veto = Invoke-ConfiguredCodexRole `
                -Config $Config -Role "ArchitectureVeto" -RepoPath $RepoPath -Speed $Speed `
                -Prompt $criticPrompt -LogRoot $RunRoot -SchemaName "architecture-critique-v1.schema.json" `
                -CodexPath $CodexPath -CallId ("$($State.ActiveClusterId)-c$($State.ReviewCycle)-critic-veto-r$revision") -State $State -StatePath $StatePath
            Assert-ReviewLoopRoleSuccess $veto
            Write-ReviewLoopStatus -Message "Sol-Veto: $($veto.StructuredResult.decision) · Confidence $($veto.StructuredResult.confidence)" -Kind Architecture
            if ((Test-ReviewLoopCritiquesAgree $decision $veto.StructuredResult) -and
                (Test-ReviewLoopArchitectureApproval $decision) -and
                (Test-ReviewLoopArchitectureApproval $veto.StructuredResult)) {
                return [pscustomobject]@{ Approved = $true; PointFix = $false; Proposal = $proposal; Critique = $veto.StructuredResult }
            }

            $tiePrompt = "$criticPrompt`n`nTerra critique:`n$(ConvertTo-ReviewLoopJsonCompact $decision)`n`nSol veto:`n$(ConvertTo-ReviewLoopJsonCompact $veto.StructuredResult)`n`nAdjudicate once, fail closed."
            $tie = Invoke-ConfiguredCodexRole `
                -Config $Config -Role "ArchitectureTieBreak" -RepoPath $RepoPath -Speed $Speed `
                -Prompt $tiePrompt -LogRoot $RunRoot -SchemaName "architecture-critique-v1.schema.json" `
                -CodexPath $CodexPath -CallId ("$($State.ActiveClusterId)-c$($State.ReviewCycle)-critic-tie-r$revision") -State $State -StatePath $StatePath
            Assert-ReviewLoopRoleSuccess $tie
            $decision = $tie.StructuredResult
            Write-ReviewLoopStatus -Message "Terra-Tie-Break: $($decision.decision) · Confidence $($decision.confidence)" -Kind Architecture
            if ([string]$decision.confidence -ne "high") {
                Stop-ReviewLoopBlocked -Message "blocked/model_disagreement: Architecture critique remains unclear after adjudication."
            }
            if (Test-ReviewLoopArchitectureApproval $decision) {
                return [pscustomobject]@{ Approved = $true; PointFix = $false; Proposal = $proposal; Critique = $decision }
            }
            if ([string]$decision.decision -eq "approve") {
                Stop-ReviewLoopBlocked -Message "blocked/model_disagreement: Architecture approval is incomplete after adjudication."
            }
        }

        if ([string]$decision.decision -eq "reject_to_point_fix") {
            return [pscustomobject]@{ Approved = $false; PointFix = $true; Proposal = $proposal; Critique = $decision }
        }
        if ([string]$decision.decision -eq "blocked") {
            Stop-ReviewLoopBlocked -Message "Architecture proposal was blocked: $($decision.rationale)"
        }
        if ([string]$decision.decision -ne "revise") {
            throw "Unsupported architecture decision: $($decision.decision)"
        }
        if ($revision -ge [int]$Config.MaxArchitectureRevisions) {
            Stop-ReviewLoopBlocked -Message "Architecture proposal requires more than the single allowed revision."
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
        [string]$CodexPath = "",
        [string]$Feedback = "None."
    )

    $role = if ($null -ne $Strategy -and [bool]$Strategy.Approved) { "ArchitectureFixer" } else { "PointFixer" }
    $strategyPayload = if ($null -eq $Strategy) { "Bounded point fix." } else { ConvertTo-ReviewLoopJsonCompact $Strategy }
    $prompt = Get-ReviewLoopPrompt -Name "fixer.md" -Values @{
        FINDINGS = ConvertTo-ReviewLoopJsonCompact $Findings
        STRATEGY = $strategyPayload
        FEEDBACK = $Feedback
    }
    $mode = if ([string]::IsNullOrWhiteSpace($ThreadId)) { "Exec" } else { "Resume" }
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
    if ([string]::IsNullOrWhiteSpace(
        ([string]$VerificationResult.targetedTest.evidence).Trim()
    )) {
        return $false
    }
    foreach ($test in @($FixerResult.targetedTests)) {
        if ([bool]$test.passed -and
            (ConvertTo-ReviewLoopComparableCommand -Command ([string]$test.command)) -eq $verificationCommand -and
            -not [string]::IsNullOrWhiteSpace(([string]$test.evidence).Trim())) {
            return $true
        }
    }
    return $false
}

function Test-ReviewLoopResolvedWithTestEvidence {
    param(
        [Parameter(Mandatory = $true)][object]$FixerResult,
        [Parameter(Mandatory = $true)][object]$VerificationResult,
        [Parameter(Mandatory = $true)][string]$RepoPath
    )

    return [string]$VerificationResult.verdict -eq "resolved" -and
        [string]$VerificationResult.confidence -eq "high" -and
        (Test-ReviewLoopPathLineEvidence -Decision $VerificationResult -RepoPath $RepoPath) -and
        (Test-ReviewLoopFixerTestEvidence `
            -FixerResult $FixerResult `
            -VerificationResult $VerificationResult)
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
        [Parameter(Mandatory = $true)][int]$Attempt,
        [string]$CodexPath = ""
    )

    $diff = Get-ReviewLoopWorktreePatch -RepoPath $RepoPath
    if ($diff.Length -gt 120000) {
        Stop-ReviewLoopBlocked -Message "The fix patch contains $($diff.Length) characters; the verifier limit is 120000. Split the finding into a smaller fix."
    }
    $prompt = Get-ReviewLoopPrompt -Name "verifier.md" -Values @{
        FINDINGS = ConvertTo-ReviewLoopJsonCompact $Findings
        FIXER_RESULT = ConvertTo-ReviewLoopJsonCompact $FixerCall.StructuredResult
        DIFF = $diff
    }
    $primary = Invoke-ConfiguredCodexRole `
        -Config $Config -Role "FindingVerifier" -RepoPath $RepoPath -Speed $Speed `
        -Prompt $prompt -LogRoot $RunRoot -SchemaName "verifier-result-v1.schema.json" `
        -CodexPath $CodexPath -CallId "$($State.ActiveClusterId)-verify-a$Attempt-primary" -State $State -StatePath $StatePath
    Assert-ReviewLoopRoleSuccess $primary
    $result = $primary.StructuredResult
    if (Test-ReviewLoopResolvedWithTestEvidence `
        -FixerResult $FixerCall.StructuredResult `
        -VerificationResult $result `
        -RepoPath $RepoPath) {
        return [pscustomobject]@{
            Accepted = $true
            Result = $result
            Calls = @($primary)
            Basis = "Luna + matching fixer test evidence"
        }
    }
    if ([string]$result.verdict -eq "reproduced" -and
        [string]$result.confidence -eq "high" -and
        (Test-ReviewLoopPathLineEvidence -Decision $result -RepoPath $RepoPath)) {
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
        -CodexPath $CodexPath -CallId "$($State.ActiveClusterId)-verify-a$Attempt-confirm" -State $State -StatePath $StatePath
    Assert-ReviewLoopRoleSuccess $confirm
    $confirmed = $confirm.StructuredResult
    if ([string]$confirmed.verdict -eq [string]$result.verdict -and
        [string]$confirmed.confidence -eq "high" -and
        (([string]$confirmed.verdict -in @("reproduced", "obsolete") -and
            (Test-ReviewLoopPathLineEvidence -Decision $confirmed -RepoPath $RepoPath)) -or
            (Test-ReviewLoopResolvedWithTestEvidence `
                -FixerResult $FixerCall.StructuredResult `
                -VerificationResult $confirmed `
                -RepoPath $RepoPath))) {
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
        -CodexPath $CodexPath -CallId "$($State.ActiveClusterId)-verify-a$Attempt-tie" -State $State -StatePath $StatePath
    Assert-ReviewLoopRoleSuccess $tie
    $final = $tie.StructuredResult
    if ([string]$final.confidence -ne "high" -or
        [string]$final.verdict -eq "insufficient_evidence" -or
        -not (Test-ReviewLoopPathLineEvidence -Decision $final -RepoPath $RepoPath)) {
        Stop-ReviewLoopBlocked -Message "blocked/model_disagreement: Finding verification remains unclear after adjudication."
    }
    if ([string]$final.verdict -eq "resolved" -and
        -not (Test-ReviewLoopResolvedWithTestEvidence `
            -FixerResult $FixerCall.StructuredResult `
            -VerificationResult $final `
            -RepoPath $RepoPath)) {
        Stop-ReviewLoopBlocked -Message "blocked/verifier_evidence_mismatch: Resolved verdict does not match the orchestrator-owned targeted test."
    }
    return [pscustomobject]@{
        Accepted = [string]$final.verdict -eq "resolved"
        Result = $final
        Calls = @($primary, $confirm, $tie)
        Basis = "Terra adjudication"
    }
}
