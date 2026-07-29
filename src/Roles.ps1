function Get-ReviewLoopResourcePath {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("prompts", "schemas")][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Name
    )

    return Join-Path (Join-Path $script:ModuleRoot $Kind) $Name
}

function Get-ReviewLoopOperationalInstructions {
    param(
        [Parameter(Mandatory = $true)][string]$Role,
        [Parameter(Mandatory = $true)][hashtable]$Config
    )

    $instructions = @"
This is an unattended Windows PowerShell run.
Prefer repository-relative paths. Do not inspect credentials or stop unrelated processes.
Do not change Git refs or the index. The orchestrator owns process lifetime, retries, verification, and commits.
You have unattended command access. Use any repository-specific tool needed to finish the role without asking for approval.
Before naming an uncertain path, discover it with rg --files, rg, or Get-ChildItem. Prefer direct PowerShell commands over nested shell quoting.
If an exploratory command fails, correct it and continue; do not treat the miss as a blocker.
"@
    $hostGateCommands = @($Config.HostGates | ForEach-Object {
        $arguments = @($_.Arguments | ForEach-Object { [string]$_ }) -join " "
        "- $($_.Name): $($_.FilePath) $arguments".TrimEnd()
    })
    $hostGateText = if ($hostGateCommands.Count -eq 0) {
        "- None configured."
    }
    else {
        $hostGateCommands -join [Environment]::NewLine
    }
    $testOwnership = @"

The following full repository gates are authoritative and owned by the orchestrator:
$hostGateText
Do not execute these configured gate commands inside this role. The orchestrator runs them after independent verification.
"@
    if ($Role -in @("PointFixer", "ArchitectureFixer")) {
        return "$instructions$testOwnership`nEdit the repository files needed for the supplied findings. While iterating, run only the narrowest useful project or filtered regression tests. If no narrower durable regression command exists, return the full command as the structured targeted test without running it yourself. Return one structured targeted regression test for the orchestrator to execute independently."
    }
    return "$instructions$testOwnership`nPreserve tracked and untracked repository state. Use supplied test evidence and narrow investigative commands; do not run a full repository or solution test suite. You must not edit repository files."
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

    Update-ReviewLoopLiveConfig -Config $Config
    if ($Config.ContainsKey("__ExecutionFingerprint") -and
        $Config.ContainsKey("__ConfigPath") -and
        (Get-ReviewLoopExecutionFingerprint -ConfigPath ([string]$Config.__ConfigPath)) -ne
            [string]$Config.__ExecutionFingerprint) {
        throw (New-ReviewLoopFailureException `
            -Message "The review-loop code, prompts, schemas, or active profile changed while this run was executing." `
            -NextSteps @(
                "Finish the intended tool or profile edits and do not change them again while the loop is running."
                "Run the same command again; completed model work will be requalified before any commit."
            ))
    }
}

function ConvertFrom-ReviewLoopRoleCallRecord {
    param([Parameter(Mandatory = $true)][object]$Record)

    return [pscustomobject]@{
        Success = [bool]$Record.Success
        CallId = [string]$Record.CallId
        Role = [string]$Record.Role
        Model = [string]$Record.Model
        Thinking = [string]$Record.Thinking
        Speed = [string]$Record.Speed
        ExitCode = [int]$Record.ExitCode
        FailureKind = [string]$Record.FailureKind
        FailureReason = [string]$Record.FailureReason
        ThreadId = [string]$Record.ThreadId
        Usage = $Record.Usage
        FinalMessage = [string]$Record.FinalMessage
        StructuredResult = $Record.StructuredResult
        Arguments = @()
        JsonlPath = [string]$Record.JsonlPath
        ResultPath = [string]$Record.ResultPath
        Attempts = @($Record.Attempts)
        StartedAt = [string]$Record.StartedAt
        FinishedAt = [string]$Record.FinishedAt
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
        [ValidateSet("Exec", "Resume")][string]$Mode = "Exec",
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
    if ($null -ne $State -and [string]::IsNullOrWhiteSpace($CallId)) {
        throw "State-backed role calls require a stable CallId."
    }

    $executionFingerprint = if ($Config.ContainsKey("__ExecutionFingerprint")) {
        [string]$Config["__ExecutionFingerprint"]
    }
    else {
        ""
    }
    if ($null -ne $State) {
        $completed = @($State.RoleCalls | Where-Object {
            [bool](Get-ReviewLoopObjectProperty -Object $_ -Name "Success" -Default $false) -and
            [string](Get-ReviewLoopObjectProperty -Object $_ -Name "CallId" -Default "") -eq $CallId -and
            [string](Get-ReviewLoopObjectProperty -Object $_ -Name "Role" -Default "") -eq $Role -and
            [string](Get-ReviewLoopObjectProperty `
                -Object $_ -Name "ExecutionFingerprint" -Default "") -eq $executionFingerprint
        } | Select-Object -Last 1)
        if ($completed.Count -gt 0) {
            $record = $completed[0]
            $current = Get-ReviewLoopRepositorySnapshot -RepoPath $RepoPath
            if ([string]$record.RepositoryHead -ne [string]$current.Head -or
                [string]$record.WorktreeFingerprint -ne [string]$current.Fingerprint) {
                Stop-ReviewLoopBlocked -Message "Completed role call '$CallId' no longer matches the repository checkpoint."
            }
            Write-ReviewLoopStatus -Message "$Role reused completed checkpoint '$CallId'." -Kind Info
            return ConvertFrom-ReviewLoopRoleCallRecord -Record $record
        }
    }

    $mayEditRepository = $Role -in @("PointFixer", "ArchitectureFixer")
    $pending = if ($null -ne $State) {
        Get-ReviewLoopObjectProperty -Object $State -Name "ActiveRoleCall"
    }
    else {
        $null
    }
    if ($null -ne $pending) {
        $pendingSnapshot = [pscustomobject]@{
            Head = [string](Get-ReviewLoopObjectProperty `
                -Object $pending -Name "RepositoryHead" -Default "")
            Fingerprint = [string](Get-ReviewLoopObjectProperty `
                -Object $pending -Name "WorktreeFingerprint" -Default "")
        }
        $currentSnapshot = Get-ReviewLoopRepositorySnapshot -RepoPath $RepoPath
        $pendingExecution = [string](Get-ReviewLoopObjectProperty `
            -Object $pending -Name "ExecutionFingerprint" -Default "")
        if ($pendingExecution -ne $executionFingerprint) {
            if ([string]$pendingSnapshot.Head -eq [string]$currentSnapshot.Head -and
                [string]$pendingSnapshot.Fingerprint -eq [string]$currentSnapshot.Fingerprint) {
                $State.ActiveRoleCall = $null
                Write-ReviewLoopState -Path $StatePath -State $State | Out-Null
                $pending = $null
            }
            else {
                Stop-ReviewLoopBlocked -Message "Interrupted role call cannot be resumed after the execution fingerprint changed."
            }
        }
        elseif ([string]$pending.CallId -ne $CallId -or [string]$pending.Role -ne $Role) {
            Stop-ReviewLoopBlocked -Message "Expected role call '$CallId' but checkpoint contains interrupted call '$($pending.CallId)'."
        }
        elseif ([string]$pendingSnapshot.Head -ne [string]$currentSnapshot.Head) {
            Stop-ReviewLoopBlocked -Message "Repository HEAD changed during interrupted role call '$CallId'."
        }
        elseif (-not $mayEditRepository -and
            [string]$pendingSnapshot.Fingerprint -ne [string]$currentSnapshot.Fingerprint) {
            Stop-ReviewLoopBlocked -Message "Read-only role '$Role' changed the repository before interruption."
        }
    }

    $effectiveMode = $Mode
    $effectiveThreadId = $ThreadId
    $effectivePrompt = $Prompt
    if ($null -ne $pending) {
        $effectiveThreadId = [string](Get-ReviewLoopObjectProperty `
            -Object $pending -Name "ThreadId" -Default "")
        if ([string]::IsNullOrWhiteSpace($effectiveThreadId)) {
            $pendingHead = [string](Get-ReviewLoopObjectProperty `
                -Object $pending -Name "RepositoryHead" -Default "")
            $pendingFingerprint = [string](Get-ReviewLoopObjectProperty `
                -Object $pending -Name "WorktreeFingerprint" -Default "")
            $currentSnapshot = Get-ReviewLoopRepositorySnapshot -RepoPath $RepoPath
            if ($pendingHead -ne [string]$currentSnapshot.Head -or
                $pendingFingerprint -ne [string]$currentSnapshot.Fingerprint) {
                Stop-ReviewLoopBlocked -Message "Interrupted mutating role '$Role' has no resumable thread."
            }
            $State.ActiveRoleCall = $null
            Write-ReviewLoopState -Path $StatePath -State $State | Out-Null
            $pending = $null
        }
        else {
            $effectiveMode = "Resume"
            $effectivePrompt = @"
Resume the interrupted $Role role. Do not repeat completed investigation or edits.
Inspect current repository state only as needed and return the required final structured result for the original role task.
"@
        }
    }

    $roleStartSnapshot = Get-ReviewLoopRepositorySnapshot -RepoPath $RepoPath
    if ($null -ne $State -and $null -eq $pending) {
        $State.ActiveRoleCall = [pscustomobject][ordered]@{
            CallId = $CallId
            Role = $Role
            Model = [string]$roleConfig.Model
            Thinking = [string]$roleConfig.Thinking
            Speed = $Speed
            SchemaName = $SchemaName
            Mode = $effectiveMode
            ThreadId = $effectiveThreadId
            ExecutionFingerprint = $executionFingerprint
            CheckpointStage = [string]$State.Stage
            RepositoryHead = [string]$roleStartSnapshot.Head
            WorktreeFingerprint = [string]$roleStartSnapshot.Fingerprint
            StartedAt = [DateTimeOffset]::UtcNow.ToString("O")
            ThreadStartedAt = ""
        }
        Write-ReviewLoopState -Path $StatePath -State $State | Out-Null
    }

    $arguments = @{
        Role = $Role
        RepoPath = $RepoPath
        Model = [string]$roleConfig.Model
        Thinking = [string]$roleConfig.Thinking
        Speed = $Speed
        Prompt = $effectivePrompt
        LogRoot = $LogRoot
        SchemaPath = $schemaPath
        Mode = $effectiveMode
        ThreadId = $effectiveThreadId
        CallId = $CallId
    }
    if (-not [string]::IsNullOrWhiteSpace($CodexPath)) {
        $arguments.CodexPath = $CodexPath
    }
    $operationalInstructions = Get-ReviewLoopOperationalInstructions -Role $Role -Config $Config
    $arguments.DeveloperInstructions = $operationalInstructions
    $worktreeBefore = if ($mayEditRepository) {
        ""
    }
    else {
        Get-ReviewLoopWorktreeFingerprint -RepoPath $RepoPath
    }
    if ($null -ne $State) {
        $onThreadStarted = {
            param([string]$ObservedThreadId)

            $active = $State.ActiveRoleCall
            if ($null -eq $active -or [string]$active.CallId -ne $CallId) {
                throw "Role thread '$ObservedThreadId' does not match the active role checkpoint."
            }
            $active | Add-Member -Force -NotePropertyName ThreadId `
                -NotePropertyValue $ObservedThreadId
            $active | Add-Member -Force -NotePropertyName ThreadStartedAt `
                -NotePropertyValue ([DateTimeOffset]::UtcNow.ToString("O"))
            Write-ReviewLoopState -Path $StatePath -State $State | Out-Null
        }
        $arguments.OnThreadStarted = $onThreadStarted
    }
    $call = Invoke-CodexCliRole @arguments
    Assert-ReviewLoopExecutionUnchanged -Config $Config

    if (-not $mayEditRepository -and
        $worktreeBefore -ne (Get-ReviewLoopWorktreeFingerprint -RepoPath $RepoPath)) {
        throw "Read-only role '$Role' changed the repository worktree despite its role contract."
    }
    if ($null -ne $State) {
        $roleEndSnapshot = Get-ReviewLoopRepositorySnapshot -RepoPath $RepoPath
        $call | Add-Member -Force -NotePropertyName ExecutionFingerprint `
            -NotePropertyValue $executionFingerprint
        $call | Add-Member -Force -NotePropertyName RepositoryHead `
            -NotePropertyValue ([string]$roleEndSnapshot.Head)
        $call | Add-Member -Force -NotePropertyName WorktreeFingerprint `
            -NotePropertyValue ([string]$roleEndSnapshot.Fingerprint)
        Add-ReviewLoopRoleCall -State $State -Call $call | Out-Null
        $State.ActiveRoleCall = $null
        Write-ReviewLoopState -Path $StatePath -State $State | Out-Null
    }
    return $call
}

function Assert-ReviewLoopRoleSuccess {
    param([Parameter(Mandatory = $true)][object]$Call)

    if (-not $Call.Success) {
        throw (New-ReviewLoopFailureException `
            -Message "Codex role '$($Call.Role)' failed after its automatic recovery attempts ($($Call.FailureKind)): $($Call.FailureReason)" `
            -NextSteps @(
                "Check the role logs in the run directory and correct the reported Codex, environment, or repository problem."
                "Run the same command again to resume from the saved checkpoint."
                "If the failure repeats, verify that the local Codex CLI is signed in and can complete a simple command."
            ))
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
        if ($fixPaths.Count -eq 0) {
            throw "Reviewer finding must contain at least one fixPath."
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

function Normalize-ReviewLoopReviewResult {
    param([Parameter(Mandatory = $true)][object]$Result)

    $findings = @($Result.findings)
    $Result.classification = if ($findings.Count -eq 0) { "clean" } else { "findings" }
    foreach ($finding in $findings) {
        $paths = @(
            [string]$finding.path
            @($finding.fixPaths | ForEach-Object { [string]$_ })
        ) | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_) -and
            (Test-ReviewLoopRepositoryRelativePath -Path $_)
        } | ForEach-Object { $_.Replace("\", "/") } | Sort-Object -Unique
        $finding.fixPaths = $paths
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
    $reviewPrompt = @"
Review the complete branch diff against commit $($State.ReviewBaseCommit).
Report only discrete, actionable correctness, security, reliability, or material performance defects.
Ignore style-only cleanup and optional architecture ideas. Verify each finding against current code.
Keep investigation scoped to changed hunks, their direct dependencies, and relevant tests.
For a recurrence of an existing defect, reuse its path, component, rootCause, and invariant text verbatim
so its ledger identity remains stable. Existing identity catalog:
$(ConvertTo-ReviewLoopJsonCompact $identityCatalog)
Return the final review only in the supplied structured schema. Do not emit a native review summary as the final answer.
"@
    $reviewCall = Invoke-ConfiguredCodexRole `
        -Config $Config `
        -Role "Reviewer" `
        -RepoPath $RepoPath `
        -Speed $Speed `
        -Prompt $reviewPrompt `
        -LogRoot $RunRoot `
        -SchemaName "review-result-v1.schema.json" `
        -Mode Exec `
        -CodexPath $CodexPath `
        -CallId ("review-{0:d2}" -f $cycle) `
        -State $State `
        -StatePath $StatePath
    Assert-ReviewLoopRoleSuccess $reviewCall
    for ($validationAttempt = 1; $validationAttempt -le 3; $validationAttempt++) {
        $validationError = $null
        try {
            Normalize-ReviewLoopReviewResult -Result $reviewCall.StructuredResult
            Assert-ReviewLoopReviewResult -Result $reviewCall.StructuredResult
        }
        catch {
            $validationError = $_.Exception.Message
        }
        if ($null -eq $validationError) {
            break
        }
        if ($validationAttempt -ge 3 -or
            [string]::IsNullOrWhiteSpace([string]$reviewCall.ThreadId)) {
            throw "Reviewer result remained semantically invalid after correction: $validationError"
        }
        Write-ReviewLoopStatus -Message "Reviewer result needs a structural correction: $validationError" -Kind Warning
        $reviewCall = Invoke-ConfiguredCodexRole `
            -Config $Config -Role "Reviewer" -RepoPath $RepoPath -Speed $Speed `
            -Prompt "Correct only the structured review result: $validationError. Preserve the completed review and return the full corrected result." `
            -LogRoot $RunRoot -SchemaName "review-result-v1.schema.json" `
            -Mode Resume -ThreadId ([string]$reviewCall.ThreadId) -CodexPath $CodexPath `
            -CallId ("review-{0:d2}-correction-{1}" -f $cycle, $validationAttempt) `
            -State $State -StatePath $StatePath
        Assert-ReviewLoopRoleSuccess $reviewCall
    }

    $headAfter = Get-ReviewLoopGitValue -RepoPath $RepoPath -Arguments @("rev-parse", "HEAD")
    if ($headAfter -ne $head -or -not (Test-ReviewLoopGitClean -RepoPath $RepoPath)) {
        Stop-ReviewLoopBlocked -Message "Repository HEAD or worktree changed during the read-only review."
    }
    $result = $reviewCall.StructuredResult
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
        Call = $reviewCall
        Result = $result
    }
}

function Test-ReviewLoopPathLineEvidence {
    param(
        [Parameter(Mandatory = $true)][object]$Decision,
        [Parameter(Mandatory = $true)][string]$RepoPath
    )

    foreach ($item in @($Decision.evidence)) {
        $path = [string](Get-ReviewLoopObjectProperty -Object $item -Name "path" -Default "")
        $line = [int](Get-ReviewLoopObjectProperty -Object $item -Name "line" -Default 0)
        $claim = [string](Get-ReviewLoopObjectProperty -Object $item -Name "claim" -Default "")
        if ([string]::IsNullOrWhiteSpace($path) -or
            [string]::IsNullOrWhiteSpace($claim) -or
            $line -lt 1 -or
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
    return $false
}

function ConvertTo-ReviewLoopRelationFindingPayload {
    param([Parameter(Mandatory = $true)][object]$Finding)

    return [pscustomobject][ordered]@{
        id = [string](Get-ReviewLoopObjectProperty -Object $Finding -Name "Id" -Default "")
        status = [string](Get-ReviewLoopObjectProperty -Object $Finding -Name "Status" -Default "unknown")
        resolutionCommit = [string](Get-ReviewLoopObjectProperty -Object $Finding -Name "ResolutionCommit" -Default "")
        path = [string](Get-ReviewLoopObjectProperty -Object $Finding -Name "Path" -Default "")
        line = [int](Get-ReviewLoopObjectProperty -Object $Finding -Name "Line" -Default 0)
        component = [string](Get-ReviewLoopObjectProperty -Object $Finding -Name "Component" -Default "")
        rootCause = [string](Get-ReviewLoopObjectProperty -Object $Finding -Name "RootCause" -Default "")
        invariant = [string](Get-ReviewLoopObjectProperty -Object $Finding -Name "Invariant" -Default "")
        evidence = [string](Get-ReviewLoopObjectProperty -Object $Finding -Name "Evidence" -Default "")
        reproduction = [string](Get-ReviewLoopObjectProperty -Object $Finding -Name "Reproduction" -Default "")
        fixPaths = @((Get-ReviewLoopObjectProperty -Object $Finding -Name "FixPaths" -Default @()))
    }
}

function Get-ReviewLoopTriggerDecision {
    param(
        [Parameter(Mandatory = $true)][object]$Result,
        [Parameter(Mandatory = $true)][string]$CandidateId
    )

    $matches = @($Result.decisions | Where-Object {
        [string]$_.candidateFindingId -eq $CandidateId
    })
    if ($matches.Count -ne 1) {
        return $null
    }
    return $matches[0]
}

function Test-ReviewLoopTriggerResultShape {
    param(
        [Parameter(Mandatory = $true)][object]$Result,
        [Parameter(Mandatory = $true)][string[]]$CandidateIds
    )

    $decisions = @($Result.decisions)
    $actualIds = @($decisions | ForEach-Object {
        [string]$_.candidateFindingId
    })
    return $decisions.Count -eq $CandidateIds.Count -and
        @($actualIds | Sort-Object -Unique).Count -eq $CandidateIds.Count -and
        @($actualIds | Where-Object { $_ -notin $CandidateIds }).Count -eq 0 -and
        @($CandidateIds | Where-Object { $_ -notin $actualIds }).Count -eq 0
}

function Test-ReviewLoopTriggerDecisionSupported {
    param(
        [AllowNull()][object]$Decision,
        [Parameter(Mandatory = $true)][string]$RepoPath
    )

    return $null -ne $Decision -and
        [string]$Decision.confidence -eq "high" -and
        ([string]$Decision.relation -eq "insufficient_evidence" -or
            (Test-ReviewLoopPathLineEvidence -Decision $Decision -RepoPath $RepoPath))
}

function New-ReviewLoopUnsupportedTriggerDecision {
    param([Parameter(Mandatory = $true)][string]$CandidateId)

    return [pscustomobject][ordered]@{
        candidateFindingId = $CandidateId
        relation = "insufficient_evidence"
        candidateStatus = "unknown"
        confidence = "low"
        rationale = "Independent judges did not produce one supported high-confidence decision."
        evidence = @()
    }
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

    $candidateList = @($Candidates)
    if ($candidateList.Count -eq 0) {
        return [pscustomobject]@{
            ArchitectureRecommended = $false
            Relation = "insufficient_evidence"
            Confidence = "high"
            Rationale = "No semantic candidates in the ledger."
            Decision = [pscustomobject]@{ schemaVersion = "2.0"; decisions = @() }
            Relations = @()
            Calls = @()
        }
    }

    $relatedRelations = @(
        "same_root_cause",
        "same_contract_different_edge",
        "regression_from_fix"
    )
    $calls = [System.Collections.Generic.List[object]]::new()
    $relations = [System.Collections.Generic.List[object]]::new()
    $currentPayload = ConvertTo-ReviewLoopRelationFindingPayload -Finding $Finding
    for ($offset = 0; $offset -lt $candidateList.Count; $offset += 20) {
        $batch = @($candidateList | Select-Object -Skip $offset -First 20)
        $candidatePayload = @($batch | ForEach-Object {
            [pscustomobject]@{
                candidateFindingId = [string]$_.Finding.Id
                finding = ConvertTo-ReviewLoopRelationFindingPayload -Finding $_.Finding
                semanticSignals = [pscustomobject]@{
                    sameComponent = $_.SameComponent
                    sameRootCause = $_.SameRootCause
                    sameInvariant = $_.SameInvariant
                    sameCluster = $_.SameCluster
                    overlappingFixPaths = $_.OverlappingFixPaths
                }
            }
        })
        $batchIds = @($candidatePayload | ForEach-Object {
            [string]$_.candidateFindingId
        })
        $prompt = Get-ReviewLoopPrompt -Name "trigger-judge.md" -Values @{
            CURRENT_FINDING = ConvertTo-ReviewLoopJsonCompact $currentPayload
            CANDIDATES = ConvertTo-ReviewLoopJsonCompact $candidatePayload
        }
        $primary = Invoke-ConfiguredCodexRole `
            -Config $Config -Role "TriggerJudge" -RepoPath $RepoPath -Speed $Speed `
            -Prompt $prompt -LogRoot $RunRoot -SchemaName "trigger-decision-v2.schema.json" `
            -CodexPath $CodexPath -CallId "$($Finding.Id)-c$($State.ReviewCycle)-relation-$offset-primary" -State $State -StatePath $StatePath
        Assert-ReviewLoopRoleSuccess $primary
        [void]$calls.Add($primary)

        $primaryShapeValid = Test-ReviewLoopTriggerResultShape `
            -Result $primary.StructuredResult -CandidateIds $batchIds
        $confirmIds = [System.Collections.Generic.List[string]]::new()
        foreach ($id in $batchIds) {
            $decision = if ($primaryShapeValid) {
                Get-ReviewLoopTriggerDecision -Result $primary.StructuredResult -CandidateId $id
            }
            else {
                $null
            }
            $supported = Test-ReviewLoopTriggerDecisionSupported `
                -Decision $decision -RepoPath $RepoPath
            if ($supported -and [string]$decision.relation -eq "independent" -and
                [string]$decision.candidateStatus -ne "unknown") {
                [void]$relations.Add($decision)
            }
            else {
                [void]$confirmIds.Add($id)
            }
        }
        if ($confirmIds.Count -eq 0) {
            continue
        }

        $confirmPayload = @($candidatePayload | Where-Object {
            [string]$_.candidateFindingId -in $confirmIds
        })
        $confirmPrompt = @"
$(Get-ReviewLoopPrompt -Name "trigger-judge.md" -Values @{
    CURRENT_FINDING = ConvertTo-ReviewLoopJsonCompact $currentPayload
    CANDIDATES = ConvertTo-ReviewLoopJsonCompact $confirmPayload
})

Independently classify these related, uncertain, or structurally invalid primary cases. Do not copy the first judge.
"@
        $confirm = Invoke-ConfiguredCodexRole `
            -Config $Config -Role "TriggerConfirm" -RepoPath $RepoPath -Speed $Speed `
            -Prompt $confirmPrompt -LogRoot $RunRoot -SchemaName "trigger-decision-v2.schema.json" `
            -CodexPath $CodexPath -CallId "$($Finding.Id)-c$($State.ReviewCycle)-relation-$offset-confirm" -State $State -StatePath $StatePath
        Assert-ReviewLoopRoleSuccess $confirm
        [void]$calls.Add($confirm)

        $confirmShapeValid = Test-ReviewLoopTriggerResultShape `
            -Result $confirm.StructuredResult -CandidateIds $confirmIds.ToArray()
        $unresolvedIds = [System.Collections.Generic.List[string]]::new()
        foreach ($id in $confirmIds) {
            $left = if ($primaryShapeValid) {
                Get-ReviewLoopTriggerDecision -Result $primary.StructuredResult -CandidateId $id
            }
            else {
                $null
            }
            $right = if ($confirmShapeValid) {
                Get-ReviewLoopTriggerDecision -Result $confirm.StructuredResult -CandidateId $id
            }
            else {
                $null
            }
            $leftSupported = Test-ReviewLoopTriggerDecisionSupported `
                -Decision $left -RepoPath $RepoPath
            $rightSupported = Test-ReviewLoopTriggerDecisionSupported `
                -Decision $right -RepoPath $RepoPath
            if ($leftSupported -and $rightSupported -and
                [string]$left.relation -eq [string]$right.relation -and
                [string]$left.candidateStatus -eq [string]$right.candidateStatus) {
                [void]$relations.Add($right)
            }
            elseif (-not $leftSupported -and $rightSupported -and
                [string]$right.relation -eq "independent") {
                [void]$relations.Add($right)
            }
            else {
                [void]$unresolvedIds.Add($id)
            }
        }
        if ($unresolvedIds.Count -eq 0) {
            continue
        }

        $tiePayload = @($candidatePayload | Where-Object {
            [string]$_.candidateFindingId -in $unresolvedIds
        })
        $tiePrompt = @"
$(Get-ReviewLoopPrompt -Name "trigger-judge.md" -Values @{
    CURRENT_FINDING = ConvertTo-ReviewLoopJsonCompact $currentPayload
    CANDIDATES = ConvertTo-ReviewLoopJsonCompact $tiePayload
})

Luna decisions:
$(ConvertTo-ReviewLoopJsonCompact $primary.StructuredResult)

Sol decisions:
$(ConvertTo-ReviewLoopJsonCompact $confirm.StructuredResult)

Adjudicate every supplied disagreement once. Keep relation and candidate status independent.
"@
        $tie = Invoke-ConfiguredCodexRole `
            -Config $Config -Role "TriggerTieBreak" -RepoPath $RepoPath -Speed $Speed `
            -Prompt $tiePrompt -LogRoot $RunRoot -SchemaName "trigger-decision-v2.schema.json" `
            -CodexPath $CodexPath -CallId "$($Finding.Id)-c$($State.ReviewCycle)-relation-$offset-tie" -State $State -StatePath $StatePath
        Assert-ReviewLoopRoleSuccess $tie
        [void]$calls.Add($tie)
        $tieShapeValid = Test-ReviewLoopTriggerResultShape `
            -Result $tie.StructuredResult -CandidateIds $unresolvedIds.ToArray()
        foreach ($id in $unresolvedIds) {
            $final = if ($tieShapeValid) {
                Get-ReviewLoopTriggerDecision -Result $tie.StructuredResult -CandidateId $id
            }
            else {
                $null
            }
            if (Test-ReviewLoopTriggerDecisionSupported -Decision $final -RepoPath $RepoPath) {
                [void]$relations.Add($final)
            }
            else {
                [void]$relations.Add((New-ReviewLoopUnsupportedTriggerDecision -CandidateId $id))
            }
        }
    }

    $architecture = @($relations | Where-Object {
        [string]$_.relation -in $relatedRelations -and
        [string]$_.candidateStatus -in @("active", "resolved")
    }).Count -gt 0
    $summary = @($relations | Group-Object relation | ForEach-Object {
        "$($_.Name)=$($_.Count)"
    }) -join ", "
    return [pscustomobject]@{
        ArchitectureRecommended = $architecture
        Relation = if ($architecture) {
            [string](@($relations | Where-Object {
                [string]$_.relation -in $relatedRelations
            } | Select-Object -First 1).relation)
        }
        else { "independent" }
        Confidence = if (@($relations | Where-Object {
            [string]$_.confidence -ne "high"
        }).Count -eq 0) { "high" } else { "low" }
        Rationale = $summary
        Decision = [pscustomobject]@{
            schemaVersion = "2.0"
            decisions = $relations.ToArray()
        }
        Relations = $relations.ToArray()
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
        try {
            Assert-ReviewLoopArchitectureProposal -Proposal $proposal -Findings $Findings
        }
        catch {
            Write-ReviewLoopStatus -Message "Architecture proposal is structurally incomplete; falling back to point fixing: $($_.Exception.Message)" -Kind Warning
            return [pscustomobject]@{ Approved = $false; PointFix = $true; Proposal = $proposal; Critique = $null }
        }
        Write-ReviewLoopStatus -Message "Proposal r${revision}: $($proposal.recommendation) · $($proposal.summary)" -Kind Architecture
        if ([string]$proposal.recommendation -in @("point_fix", "no_architecture")) {
            Write-ReviewLoopStatus -Message "Architect limited the cluster to a point fix." -Kind Warning -Indent 1
            return [pscustomobject]@{ Approved = $false; PointFix = $true; Proposal = $proposal; Critique = $null }
        }

        $scope = Get-ReviewLoopArchitectureScope $proposal
        Write-ReviewLoopStatus -Message "Scope: $($scope.PathCount) paths, $($scope.ProductionPathCount) production" -Kind Architecture -Indent 1
        if ($scope.BreaksPublicContract) {
            Write-ReviewLoopStatus -Message "Architecture proposal may break a public contract; falling back to point fixing." -Kind Warning
            return [pscustomobject]@{ Approved = $false; PointFix = $true; Proposal = $proposal; Critique = $null }
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
                Write-ReviewLoopStatus -Message "Architecture critique remains unclear; falling back to point fixing." -Kind Warning
                return [pscustomobject]@{ Approved = $false; PointFix = $true; Proposal = $proposal; Critique = $decision }
            }
            if (Test-ReviewLoopArchitectureApproval $decision) {
                return [pscustomobject]@{ Approved = $true; PointFix = $false; Proposal = $proposal; Critique = $decision }
            }
            if ([string]$decision.decision -eq "approve") {
                Write-ReviewLoopStatus -Message "Architecture approval remained incomplete; falling back to point fixing." -Kind Warning
                return [pscustomobject]@{ Approved = $false; PointFix = $true; Proposal = $proposal; Critique = $decision }
            }
        }

        if ([string]$decision.decision -eq "reject_to_point_fix") {
            return [pscustomobject]@{ Approved = $false; PointFix = $true; Proposal = $proposal; Critique = $decision }
        }
        if ([string]$decision.decision -eq "blocked") {
            Write-ReviewLoopStatus -Message "Architecture critic blocked consolidation; falling back to point fixing." -Kind Warning
            return [pscustomobject]@{ Approved = $false; PointFix = $true; Proposal = $proposal; Critique = $decision }
        }
        if ([string]$decision.decision -ne "revise") {
            throw "Unsupported architecture decision: $($decision.decision)"
        }
        Update-ReviewLoopLiveConfig -Config $Config
        if ($revision -ge [int]$Config.MaxArchitectureRevisions) {
            Write-ReviewLoopStatus -Message "Architecture revision budget exhausted; falling back to point fixing." -Kind Warning
            return [pscustomobject]@{ Approved = $false; PointFix = $true; Proposal = $proposal; Critique = $decision }
        }
        $revision++
        Write-ReviewLoopStatus `
            -Message "Requesting architecture-proposal revision $revision/$($Config.MaxArchitectureRevisions)." `
            -Kind Warning
        $State.ArchitectureRevision = $revision
        Write-ReviewLoopState -Path $StatePath -State $State | Out-Null
        $architectPrompt += "`n`nRequired critic changes for revision ${revision}:`n$(ConvertTo-ReviewLoopJsonCompact $decision)"
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
        [ValidateRange(0, 2)][int]$Correction = 0,
        [string]$CallId = "",
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
    $stableCallId = if (-not [string]::IsNullOrWhiteSpace($CallId)) {
        $CallId
    }
    elseif ($Correction -gt 0) {
        "$($State.ActiveClusterId)-fix-$Attempt-correction-$Correction"
    }
    else {
        "$($State.ActiveClusterId)-fix-$Attempt"
    }
    return Invoke-ConfiguredCodexRole `
        -Config $Config -Role $role -RepoPath $RepoPath -Speed $Speed `
        -Prompt $prompt -LogRoot $RunRoot -SchemaName "fixer-result-v1.schema.json" `
        -Mode $mode -ThreadId $ThreadId -CodexPath $CodexPath `
        -CallId $stableCallId -State $State -StatePath $StatePath
}

function Test-ReviewLoopResolvedWithTestEvidence {
    param(
        [Parameter(Mandatory = $true)][object]$FixerResult,
        [Parameter(Mandatory = $true)][object]$VerificationResult,
        [Parameter(Mandatory = $true)][string]$RepoPath
    )

    return [string]$VerificationResult.verdict -eq "resolved" -and
        [string]$VerificationResult.patchSafety -eq "safe" -and
        @($VerificationResult.regressions).Count -eq 0 -and
        [string]$VerificationResult.confidence -eq "high" -and
        (Test-ReviewLoopPathLineEvidence -Decision $VerificationResult -RepoPath $RepoPath) -and
        [bool](Get-ReviewLoopObjectProperty `
            -Object $FixerResult.testExecution -Name "Passed" -Default $false)
}

function Test-ReviewLoopRejectedVerification {
    param(
        [Parameter(Mandatory = $true)][object]$VerificationResult,
        [Parameter(Mandatory = $true)][string]$RepoPath
    )

    $regressions = @($VerificationResult.regressions)
    $patchRegression = [string]$VerificationResult.patchSafety -eq "regression_detected" -and
        $regressions.Count -gt 0
    return [string]$VerificationResult.confidence -eq "high" -and
        (Test-ReviewLoopPathLineEvidence -Decision $VerificationResult -RepoPath $RepoPath) -and
        ([string]$VerificationResult.verdict -eq "reproduced" -or $patchRegression)
}

function Test-ReviewLoopSafeObsoleteVerification {
    param(
        [Parameter(Mandatory = $true)][object]$VerificationResult,
        [Parameter(Mandatory = $true)][string]$RepoPath
    )

    return [string]$VerificationResult.verdict -eq "obsolete" -and
        [string]$VerificationResult.patchSafety -eq "safe" -and
        @($VerificationResult.regressions).Count -eq 0 -and
        [string]$VerificationResult.confidence -eq "high" -and
        (Test-ReviewLoopPathLineEvidence -Decision $VerificationResult -RepoPath $RepoPath)
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

    $prompt = Get-ReviewLoopPrompt -Name "verifier.md" -Values @{
        FINDINGS = ConvertTo-ReviewLoopJsonCompact $Findings
        FIXER_RESULT = ConvertTo-ReviewLoopJsonCompact $FixerCall.StructuredResult
    }
    $primary = Invoke-ConfiguredCodexRole `
        -Config $Config -Role "FindingVerifier" -RepoPath $RepoPath -Speed $Speed `
        -Prompt $prompt -LogRoot $RunRoot -SchemaName "verifier-result-v2.schema.json" `
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
    if (Test-ReviewLoopRejectedVerification -VerificationResult $result -RepoPath $RepoPath) {
        return [pscustomobject]@{
            Accepted = $false
            Result = $result
            Calls = @($primary)
            Basis = "Luna"
        }
    }

    $confirm = Invoke-ConfiguredCodexRole `
        -Config $Config -Role "VerifierConfirm" -RepoPath $RepoPath -Speed $Speed `
        -Prompt $prompt -LogRoot $RunRoot -SchemaName "verifier-result-v2.schema.json" `
        -CodexPath $CodexPath -CallId "$($State.ActiveClusterId)-verify-a$Attempt-confirm" -State $State -StatePath $StatePath
    Assert-ReviewLoopRoleSuccess $confirm
    $confirmed = $confirm.StructuredResult
    if ([string]$confirmed.verdict -eq [string]$result.verdict -and
        [string]$confirmed.patchSafety -eq [string]$result.patchSafety -and
        [string]$confirmed.confidence -eq "high" -and
        ((Test-ReviewLoopRejectedVerification `
                -VerificationResult $confirmed -RepoPath $RepoPath) -or
            (Test-ReviewLoopSafeObsoleteVerification `
                -VerificationResult $confirmed -RepoPath $RepoPath) -or
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
        -Prompt $tiePrompt -LogRoot $RunRoot -SchemaName "verifier-result-v2.schema.json" `
        -CodexPath $CodexPath -CallId "$($State.ActiveClusterId)-verify-a$Attempt-tie" -State $State -StatePath $StatePath
    Assert-ReviewLoopRoleSuccess $tie
    $final = $tie.StructuredResult
    $finalSupported = (Test-ReviewLoopResolvedWithTestEvidence `
            -FixerResult $FixerCall.StructuredResult `
            -VerificationResult $final `
            -RepoPath $RepoPath) -or
        (Test-ReviewLoopRejectedVerification `
            -VerificationResult $final -RepoPath $RepoPath) -or
        (Test-ReviewLoopSafeObsoleteVerification `
            -VerificationResult $final -RepoPath $RepoPath)
    if (-not $finalSupported) {
        $inconclusiveBasis = if ([string]$final.verdict -eq "resolved") {
            "Resolved verdict lacked orchestrator-owned test evidence or a safe patch"
        }
        else {
            "Terra adjudication remained inconclusive"
        }
        return [pscustomobject]@{
            Accepted = $false
            Result = $final
            Calls = @($primary, $confirm, $tie)
            Basis = $inconclusiveBasis
        }
    }
    $finalAccepted = Test-ReviewLoopResolvedWithTestEvidence `
        -FixerResult $FixerCall.StructuredResult `
        -VerificationResult $final `
        -RepoPath $RepoPath
    return [pscustomobject]@{
        Accepted = $finalAccepted
        Result = $final
        Calls = @($primary, $confirm, $tie)
        Basis = "Terra adjudication"
    }
}
