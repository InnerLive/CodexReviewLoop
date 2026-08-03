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
Execution context:
This role is one Codex CLI process in an unattended Windows PowerShell repository workflow.
The repository root, local tools, and repository instructions are available to the role.
The orchestrator is deterministic PowerShell code, not an LLM or conversational participant.
It does not interpret prose as instructions; it reacts to implemented workflow transitions and structured result fields.
The orchestrator records repository state, owns Git refs and commits, executes configured host gates, and manages the Codex process.
The role returns its result through the supplied structured format.
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

Configured host gates:
$hostGateText
The orchestrator executes these gates after verification.
"@
    if ($Role -eq "ReviewClassifier") {
        return @"
$instructions
The ReviewClassifier's hasFindings field is the classification consumed by the orchestrator.
This role classifies the supplied review text; the orchestrator compares repository state before and after the call.
"@
    }
    $handoff = switch ($Role) {
        "Architect" {
            @"
The complete Architect result is passed unchanged to the Fixer as advice and is later shown to the Verifier.
The Fixer acts on described repository changes; the orchestrator does not execute steps from architecture prose.
"@
        }
        "Fixer" {
            @"
The Architect result is advice to this role. This role owns worktree edits but not commits or Git refs.
The targetedTest fields are the interface for asking the orchestrator to run one targeted test after this role returns; the summary is descriptive.
The fixer workspace is the worktree observed by the orchestrator.
"@
        }
        "Verifier" {
            @"
The accept field selects the implemented workflow transition. Rejection feedback is passed to the Fixer; an accepted commitMessage proposal is used after configured host gates pass.
The orchestrator does not infer additional actions from the summary or feedback prose.
"@
        }
        default {
            "This role contributes analysis; the orchestrator compares repository state before and after the call."
        }
    }
    return "$instructions$testOwnership`n$handoff"
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
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Prompt,
        [Parameter(Mandatory = $true)][string]$LogRoot,
        [string]$SchemaName = "",
        [ValidateSet("Exec", "Resume", "Review")][string]$Mode = "Exec",
        [string]$ThreadId = "",
        [string]$ReviewBase = "",
        [string]$CodexPath = "",
        [string]$CallId = "",
        [object]$State = $null,
        [string]$StatePath = ""
    )

    if ($Role -eq "Reviewer" -and
        ($Mode -ne "Review" -or -not [string]::IsNullOrWhiteSpace($Prompt) -or
         -not [string]::IsNullOrWhiteSpace($SchemaName))) {
        throw "Reviewer must use native Codex review without a prompt or output schema."
    }

    Update-ReviewLoopLiveConfig -Config $Config
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
                if (Test-ReviewLoopGitClean -RepoPath $RepoPath) {
                    Write-ReviewLoopStatus `
                        -Message "$Role checkpoint '$CallId' is stale; starting the role again." `
                        -Kind Info
                }
                else {
                    Stop-ReviewLoopBlocked -Message "Completed role call '$CallId' no longer matches the repository checkpoint."
                }
            }
            else {
                Write-ReviewLoopStatus -Message "$Role reused completed checkpoint '$CallId'." -Kind Info
                return ConvertFrom-ReviewLoopRoleCallRecord -Record $record
            }
        }
    }

    $mayEditRepository = $Role -eq "Fixer"
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
            if (Test-ReviewLoopGitClean -RepoPath $RepoPath) {
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
        elseif ($Mode -eq "Review" -and $Role -eq "Reviewer") {
            $State.ActiveRoleCall = $null
            Write-ReviewLoopState -Path $StatePath -State $State | Out-Null
            $pending = $null
            Write-ReviewLoopStatus `
                -Message "Interrupted native review will start again from the current clean checkpoint." `
                -Kind Info
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
            if ($pendingHead -ne [string]$currentSnapshot.Head) {
                Stop-ReviewLoopBlocked -Message "Interrupted mutating role '$Role' changed HEAD without a resumable thread."
            }
            if ($pendingFingerprint -ne [string]$currentSnapshot.Fingerprint -and
                -not ($Role -eq "Fixer" -and
                    $null -ne (Get-ReviewLoopObjectProperty `
                        -Object $State -Name "PartialFixRecovery"))) {
                Stop-ReviewLoopBlocked -Message "Interrupted mutating role '$Role' has no resumable thread."
            }
            $State.ActiveRoleCall = $null
            Write-ReviewLoopState -Path $StatePath -State $State | Out-Null
            $pending = $null
        }
        else {
            $effectiveMode = "Resume"
            $effectivePrompt = @"
Continue the interrupted $Role work from the current repository state and return the role result in the supplied structured format.
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
        ReviewBase = $ReviewBase
        CallId = $CallId
        InactivityTimeoutSeconds = Get-ReviewLoopInactivityTimeoutSeconds -Config $Config
    }
    if (-not [string]::IsNullOrWhiteSpace($CodexPath)) {
        $arguments.CodexPath = $CodexPath
    }
    $operationalInstructions = if ($Mode -eq "Review" -and $Role -eq "Reviewer") {
        ""
    }
    else {
        Get-ReviewLoopOperationalInstructions -Role $Role -Config $Config
    }
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
        $exception = New-ReviewLoopFailureException `
            -Message "Codex role '$($Call.Role)' failed after its automatic recovery attempts ($($Call.FailureKind)): $($Call.FailureReason)" `
            -NextSteps @(
                "Check the role logs in the run directory and correct the reported Codex, environment, or repository problem."
                "Run the same command again to resume from the saved checkpoint."
                "If the failure repeats, verify that the local Codex CLI is signed in and can complete a simple command."
            )
        if ([string]$Call.FailureKind -eq "timeout") {
            $exception.Data["ReviewLoopRestartReview"] = $true
        }
        throw $exception
    }
}

function Get-ReviewLoopRecentHistory {
    param(
        [Parameter(Mandatory = $true)][object]$Ledger,
        [ValidateRange(0, 50)][int]$Limit = 50
    )

    if ($Limit -eq 0) {
        return @()
    }
    return @($Ledger.Findings |
        Sort-Object UpdatedAt -Descending |
        Select-Object -First $Limit |
        ForEach-Object {
            [pscustomobject][ordered]@{
                id = [string]$_.Id
                status = [string]$_.Status
                title = [string]$_.Title
                description = [string](Get-ReviewLoopObjectProperty `
                    -Object $_ -Name "Description" -Default (
                        Get-ReviewLoopObjectProperty -Object $_ -Name "Evidence" -Default ""))
                locations = @((Get-ReviewLoopObjectProperty `
                    -Object $_ -Name "Locations" -Default @([pscustomobject]@{
                        path = [string]$_.Path
                        line = [int]$_.Line
                    })))
                resolutionCommit = [string]$_.ResolutionCommit
                updatedAt = [string]$_.UpdatedAt
            }
        })
}

function Get-ReviewLoopRepositoryContext {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$RepoPath
    )

    $head = Get-ReviewLoopGitValue -RepoPath $RepoPath -Arguments @("rev-parse", "HEAD")
    $changed = Get-ReviewLoopGitValue -RepoPath $RepoPath -Arguments @(
        "diff", "--name-only", "$($State.ReviewBaseCommit)...$head", "--"
    )
    return [pscustomobject][ordered]@{
        repositoryRoot = $RepoPath
        branch = [string]$State.Branch
        reviewBase = [string]$State.ReviewBase
        reviewBaseCommit = [string]$State.ReviewBaseCommit
        head = $head
        changedPaths = @($changed -split "\r?\n" | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        })
    }
}

function Get-ReviewLoopLocalReviewClassification {
    param([AllowEmptyString()][string]$ReviewText)

    if ([string]::IsNullOrWhiteSpace($ReviewText)) {
        return [pscustomobject]@{
            Classification = "invalid"
            Reason = "The native Reviewer returned an empty result."
        }
    }

    $trimmed = $ReviewText.Trim()
    if ($trimmed -in @(
        "Reviewer failed to output a response.",
        "Review interrupted.",
        "Review cancelled.",
        "Review canceled."
    )) {
        return [pscustomobject]@{
            Classification = "invalid"
            Reason = "The native Reviewer returned a technical failure result."
        }
    }

    $findingPatterns = @(
        "(?ims)^\s*(?:full review comments?|review comments?|review comment)\s*:\s*$.*?^\s*-\s*\[[A-Z]+\d+\]\s+",
        "(?im)^\s*findings?\s*:\s*$",
        "(?im)^\s*-\s*\[[A-Z]+\d+\]\s+",
        "(?im)\bshould be fixed\b"
    )
    foreach ($pattern in $findingPatterns) {
        if ($ReviewText -match $pattern) {
            return [pscustomobject]@{
                Classification = "finding"
                Reason = "The native review contains a deterministic finding signal."
            }
        }
    }

    $cleanPatterns = @(
        "(?im)^\s*(no findings|no issues|no problems|nothing to report)\b",
        "(?im)^\s*keine\s+(funde|probleme|beanstandungen|regressionen)\b",
        "(?im)\bno\s+(discrete,?\s+)?((newly\s+)?introduced\s+)?(actionable\s+)?((correctness|runtime|test-breaking)\s+)?(issues?|regressions?|defects?|bugs?|problems?)(\s+or\s+(blocking\s+)?(issues?|regressions?|defects?|bugs?|problems?))?\s+(were\s+)?(found|identified)\b",
        "(?im)\bno actionable ((correctness|runtime|test-breaking)\s+)?(regressions|findings|issues)\b",
        "(?im)\bi did not (identify|find)\s+(any|a)\s+(clear,?\s+)?(discrete,?\s+)?((newly\s+)?introduced\s+)?(actionable\s+)?((correctness|runtime|test-breaking)\s+or\s+)+((correctness|runtime|test-breaking)\s+)?(issues?|issue|regressions?|regression|defects?|defect|bugs?|bug|problems?|problem)\b",
        "(?im)\bi did not (identify|find)\s+(any|a)\s+(clear,?\s+)?(discrete,?\s+)?((newly\s+)?introduced\s+)?(actionable\s+)?((correctness|runtime|test-breaking)\s+)?(issues?|issue|regressions?|regression|defects?|defect|bugs?|bug|problems?|problem)\b",
        "(?im)\bi found no\b",
        "(?im)\bno discrete,\s*actionable\b",
        "(?im)\bwithout introducing a clear\s+(functional\s+)?(correctness\s+)?regression\b",
        "(?im)\bdo(es)? not introduce a clear,?\s+actionable correctness issue\b",
        "(?im)\bkeine diskreten,\s*umsetzbaren\b",
        "(?im)\bkeine umsetzbaren (regressionen|funde|probleme)\b"
    )
    foreach ($pattern in $cleanPatterns) {
        if ($ReviewText -match $pattern) {
            return [pscustomobject]@{
                Classification = "clean"
                Reason = "The native review contains a deterministic clean signal."
            }
        }
    }

    return [pscustomobject]@{
        Classification = "ambiguous"
        Reason = "The native review contains no deterministic finding or clean signal."
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
    $context = Get-ReviewLoopRepositoryContext -State $State -RepoPath $RepoPath
    $head = [string]$context.head
    if (-not (Test-ReviewLoopGitClean -RepoPath $RepoPath)) {
        throw "The worktree changed before the reviewer started."
    }
    $call = Invoke-ConfiguredCodexRole `
        -Config $Config -Role "Reviewer" -RepoPath $RepoPath -Speed $Speed `
        -Prompt "" -LogRoot $RunRoot `
        -Mode Review -ReviewBase ([string]$State.ReviewBase) `
        -CodexPath $CodexPath -CallId ("review-{0:d2}" -f $cycle) `
        -State $State -StatePath $StatePath
    Assert-ReviewLoopRoleSuccess $call

    $headAfter = Get-ReviewLoopGitValue -RepoPath $RepoPath -Arguments @("rev-parse", "HEAD")
    if ($headAfter -ne $head -or -not (Test-ReviewLoopGitClean -RepoPath $RepoPath)) {
        Stop-ReviewLoopBlocked -Message "Repository HEAD or worktree changed during the reviewer role."
    }

    $reviewText = [string]$call.FinalMessage
    $State | Add-Member -Force -NotePropertyName ActiveReviewText -NotePropertyValue $reviewText
    Write-ReviewLoopState -Path $StatePath -State $State | Out-Null

    $classification = Get-ReviewLoopLocalReviewClassification -ReviewText $reviewText
    if ([string]$classification.Classification -eq "invalid") {
        $reviewRecord = @($State.RoleCalls | Where-Object {
            [string](Get-ReviewLoopObjectProperty -Object $_ -Name "CallId" -Default "") -eq
                ("review-{0:d2}" -f $cycle) -and
            [string](Get-ReviewLoopObjectProperty -Object $_ -Name "Role" -Default "") -eq
                "Reviewer"
        } | Select-Object -Last 1)
        if ($reviewRecord.Count -gt 0) {
            $reviewRecord[0].Success = $false
            $reviewRecord[0].FailureKind = "invalid_output"
            $reviewRecord[0].FailureReason = [string]$classification.Reason
            Write-ReviewLoopState -Path $StatePath -State $State | Out-Null
        }
        throw (New-ReviewLoopFailureException `
            -Message ([string]$classification.Reason) `
            -NextSteps @(
                "Check the native Reviewer stdout and stderr logs in the run directory."
                "Run the same command again to retry the native review from the saved checkpoint."
                "If the failure repeats, verify that the local Codex CLI can complete a native review."
            ))
    }

    $classificationSource = "deterministic"
    if ([string]$classification.Classification -eq "ambiguous") {
        $classifierPrompt = Get-ReviewLoopPrompt -Name "review-classifier.md" -Values @{
            REVIEW_OUTPUT = $reviewText
        }
        $classifierCall = Invoke-ConfiguredCodexRole `
            -Config $Config -Role "ReviewClassifier" -RepoPath $RepoPath -Speed $Speed `
            -Prompt $classifierPrompt -LogRoot $RunRoot `
            -SchemaName "review-classification-v1.schema.json" `
            -CodexPath $CodexPath `
            -CallId ("review-{0:d2}-classify" -f $cycle) `
            -State $State -StatePath $StatePath
        Assert-ReviewLoopRoleSuccess $classifierCall
        $classification = [pscustomobject]@{
            Classification = if ([bool]$classifierCall.StructuredResult.hasFindings) {
                "finding"
            }
            else {
                "clean"
            }
            Reason = "The mechanical ReviewClassifier evaluated ambiguous native review text."
        }
        $classificationSource = "ReviewClassifier"
    }

    $headAfterClassification = Get-ReviewLoopGitValue `
        -RepoPath $RepoPath -Arguments @("rev-parse", "HEAD")
    if ($headAfterClassification -ne $head -or -not (Test-ReviewLoopGitClean -RepoPath $RepoPath)) {
        Stop-ReviewLoopBlocked -Message "Repository HEAD or worktree changed while the review result was classified."
    }

    $isClean = [string]$classification.Classification -eq "clean"
    $summary = @($reviewText -split "\r?\n" | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    } | Select-Object -First 1) -join ""
    $findings = if ($isClean) {
        @()
    }
    else {
        @([pscustomobject]@{
            title = "Codex review cycle $cycle"
            description = $reviewText
            locations = @()
        })
    }
    if ($isClean) {
        Write-ReviewLoopStatus `
            -Message "Review is clean ($classificationSource): $summary" `
            -Kind Success
    }
    else {
        Write-ReviewLoopStatus `
            -Message "Reviewer returned findings ($classificationSource): $summary" `
            -Kind Review
    }
    $result = [pscustomobject]@{
        summary = $summary
        findings = $findings
        text = $reviewText
        clean = $isClean
        classificationSource = $classificationSource
    }

    return [pscustomobject]@{
        ReviewId = "review-{0:d2}" -f $cycle
        Head = $head
        Call = $call
        Result = $result
    }
}

function Invoke-ReviewLoopArchitect {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][object]$Ledger,
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$Speed,
        [Parameter(Mandatory = $true)][string]$RunRoot,
        [Parameter(Mandatory = $true)][object[]]$Findings,
        [string]$CodexPath = ""
    )

    $prompt = Get-ReviewLoopPrompt -Name "architect.md" -Values @{
        FINDINGS = [string]$State.ActiveReviewText
        REPOSITORY_CONTEXT = ConvertTo-ReviewLoopJsonCompact (
            Get-ReviewLoopRepositoryContext -State $State -RepoPath $RepoPath)
        HISTORY = ConvertTo-ReviewLoopJsonCompact @(
            Get-ReviewLoopRecentHistory -Ledger $Ledger -Limit 50)
    }
    $call = Invoke-ConfiguredCodexRole `
        -Config $Config -Role "Architect" -RepoPath $RepoPath -Speed $Speed `
        -Prompt $prompt -LogRoot $RunRoot -SchemaName "architecture-advice-v2.schema.json" `
        -CodexPath $CodexPath `
        -CallId "$($State.ActiveClusterId)-c$($State.ReviewCycle)-architect" `
        -State $State -StatePath $StatePath
    Assert-ReviewLoopRoleSuccess $call
    Write-ReviewLoopStatus `
        -Message "Architect: $($call.StructuredResult.summary)" `
        -Kind Architecture
    return $call
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
        [int]$Correction = 0,
        [string]$CallId = "",
        [string]$ThreadId = "",
        [string]$CodexPath = "",
        [string]$Feedback = "None."
    )

    $prompt = Get-ReviewLoopPrompt -Name "fixer.md" -Values @{
        FINDINGS = [string]$State.ActiveReviewText
        ARCHITECT_ADVICE = ConvertTo-ReviewLoopJsonCompact $Strategy
        FEEDBACK = $Feedback
    }
    $mode = if ([string]::IsNullOrWhiteSpace($ThreadId)) { "Exec" } else { "Resume" }
    $stableCallId = if (-not [string]::IsNullOrWhiteSpace($CallId)) {
        $CallId
    }
    else {
        "$($State.ActiveClusterId)-c$($State.ReviewCycle)-fix-a$Attempt-c$Correction"
    }
    return Invoke-ConfiguredCodexRole `
        -Config $Config -Role "Fixer" -RepoPath $RepoPath -Speed $Speed `
        -Prompt $prompt -LogRoot $RunRoot -SchemaName "fixer-result-v3.schema.json" `
        -Mode $mode -ThreadId $ThreadId -CodexPath $CodexPath `
        -CallId $stableCallId -State $State -StatePath $StatePath
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
        FINDINGS = [string]$State.ActiveReviewText
        ARCHITECT_ADVICE = ConvertTo-ReviewLoopJsonCompact $State.ActiveStrategy
        FIXER_RESULT = ConvertTo-ReviewLoopJsonCompact $FixerCall.StructuredResult
    }
    $fixerCallId = [string](Get-ReviewLoopObjectProperty `
        -Object $FixerCall -Name "CallId" -Default "")
    if ([string]::IsNullOrWhiteSpace($fixerCallId)) {
        $fixerCallId = "a$Attempt-c$([int](Get-ReviewLoopObjectProperty `
            -Object $State.LastFixerResult -Name "Correction" -Default 0))"
    }
    $verificationKey = (Get-ReviewLoopSha256 $fixerCallId).Substring(0, 12)
    $call = Invoke-ConfiguredCodexRole `
        -Config $Config -Role "Verifier" -RepoPath $RepoPath -Speed $Speed `
        -Prompt $prompt -LogRoot $RunRoot -SchemaName "verifier-result-v4.schema.json" `
        -CodexPath $CodexPath `
        -CallId "$($State.ActiveClusterId)-c$($State.ReviewCycle)-verify-$verificationKey" `
        -State $State -StatePath $StatePath
    Assert-ReviewLoopRoleSuccess $call
    return [pscustomobject]@{
        Accepted = [bool]$call.StructuredResult.accept
        Result = $call.StructuredResult
        Calls = @($call)
        Basis = "Verifier decision"
    }
}
