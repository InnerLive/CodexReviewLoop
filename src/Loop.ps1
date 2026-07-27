function Get-ReviewLoopLatestActiveStatePath {
    param([Parameter(Mandatory = $true)][string]$ProfileRoot)

    if (-not (Test-Path -LiteralPath $ProfileRoot)) {
        return ""
    }
    $candidate = Get-ChildItem -LiteralPath $ProfileRoot -Directory |
        Sort-Object Name -Descending |
        ForEach-Object {
            $path = Join-Path $_.FullName "run-v1.json"
            if (Test-Path -LiteralPath $path) {
                $state = Read-ReviewLoopState -Path $path
                if ([string]$state.Status -eq "running") {
                    return $path
                }
            }
        } |
        Select-Object -First 1
    return [string]$candidate
}

function New-ReviewLoopRunPaths {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][string]$RepoPath
    )

    $profileRoot = Join-Path (Resolve-ReviewLoopPath -Path ([string]$Config.LogRoot)) ([string]$Config.Name)
    [System.IO.Directory]::CreateDirectory($profileRoot) | Out-Null
    return [pscustomobject]@{
        ProfileRoot = $profileRoot
        RunRoot = ""
        StatePath = ""
        LedgerPath = Join-Path $profileRoot "ledger-v1.json"
    }
}

function Initialize-ReviewLoopRunPaths {
    param([Parameter(Mandatory = $true)][object]$Paths)

    $runName = "{0}-v3-{1}" -f (Get-Date -Format "yyyyMMdd-HHmmss"), ([Guid]::NewGuid().ToString("N").Substring(0, 6))
    $Paths.RunRoot = Join-Path $Paths.ProfileRoot $runName
    [System.IO.Directory]::CreateDirectory($Paths.RunRoot) | Out-Null
    $Paths.StatePath = Join-Path $Paths.RunRoot "run-v1.json"
    return $Paths
}

function Invoke-ReviewLoopHostGate {
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][hashtable]$Gate,
        [Parameter(Mandatory = $true)][string]$RunRoot,
        [Parameter(Mandatory = $true)][string]$ClusterId
    )

    $name = [string]$Gate.Name
    $filePath = [string]$Gate.FilePath
    $arguments = @($Gate.Arguments | ForEach-Object { [string]$_ })
    $safeName = [regex]::Replace($name.ToLowerInvariant(), "[^a-z0-9-]+", "-").Trim("-")
    $logPath = Join-Path $RunRoot "$ClusterId-gate-$safeName.txt"

    Write-ReviewLoopStatus -Message "Host-Gate: $name" -Kind Progress
    $command = Get-Command $filePath -ErrorAction Stop | Select-Object -First 1
    $startInfo = New-CodexProcessStartInfo -CodexExecutable $command.Source -Arguments $arguments
    $startInfo.WorkingDirectory = $RepoPath
    $stderrPath = "$logPath.stderr.txt"
    try {
        $observed = Invoke-ReviewLoopObservedProcess `
            -StartInfo $startInfo `
            -DisplayName "Host-Gate $name" `
            -StdoutPath $logPath `
            -StderrPath $stderrPath `
            -EventKind HostGate
        $exitCode = $observed.ExitCode
        $text = "$($observed.Stdout)`n$($observed.Stderr)"
        $duration = Format-ReviewLoopDuration -Duration $observed.Duration
        if ($exitCode -eq 0) {
            Write-ReviewLoopStatus -Message "$name passed · $duration" -Kind Success -Indent 1
        }
        else {
            Write-ReviewLoopStatus -Message "$name failed · exit code $exitCode · $duration" -Kind Error -Indent 1
            foreach ($excerpt in @(Get-ReviewLoopTextExcerpt -Text $text -MaxLines 8)) {
                Write-ReviewLoopStatus -Message $excerpt -Kind Muted -Indent 2
            }
        }
    }
    catch {
        $exitCode = -1
        $text = $_.Exception.Message
        Write-ReviewLoopUtf8File -Path $stderrPath -Content (ConvertTo-ReviewLoopRedactedText $text)
        Write-ReviewLoopStatus -Message "$name could not be executed: $text" -Kind Error -Indent 1
    }
    return [pscustomobject]@{
        Name = $name
        FilePath = $filePath
        Arguments = $arguments
        ExitCode = $exitCode
        Success = $exitCode -eq 0
        LogPath = $logPath
        StderrPath = $stderrPath
    }
}

function Invoke-ReviewLoopHostGates {
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$HostGates,
        [Parameter(Mandatory = $true)][string]$RunRoot,
        [Parameter(Mandatory = $true)][string]$ClusterId
    )

    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($gate in $HostGates) {
        $result = Invoke-ReviewLoopHostGate -RepoPath $RepoPath -Gate $gate -RunRoot $RunRoot -ClusterId $ClusterId
        [void]$results.Add($result)
        if (-not $result.Success) {
            return [pscustomobject]@{ Success = $false; Results = $results.ToArray(); Failure = $result }
        }
    }
    return [pscustomobject]@{ Success = $true; Results = $results.ToArray(); Failure = $null }
}

function Get-ReviewLoopOpenFindings {
    param([Parameter(Mandatory = $true)][object]$Ledger)
    return @($Ledger.Findings | Where-Object { [string]$_.Status -in @("pending", "open", "fixing") } | Sort-Object Priority, Id)
}

function Set-ReviewLoopFindingsStatus {
    param(
        [Parameter(Mandatory = $true)][object[]]$Findings,
        [Parameter(Mandatory = $true)][string]$Status,
        [string]$Reason = ""
    )

    foreach ($finding in $Findings) {
        $finding.Status = $Status
        $finding.UpdatedAt = [DateTimeOffset]::UtcNow.ToString("O")
        if ($Status -eq "blocked") {
            $finding.BlockedReason = $Reason
        }
    }
}

function Complete-ReviewLoopFix {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][object]$Ledger,
        [Parameter(Mandatory = $true)][string]$LedgerPath,
        [Parameter(Mandatory = $true)][object[]]$Findings,
        [Parameter(Mandatory = $true)][object]$Verification,
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$RunRoot
    )

    $gates = Invoke-ReviewLoopHostGates `
        -RepoPath $RepoPath `
        -HostGates @($Config.HostGates) `
        -RunRoot $RunRoot `
        -ClusterId $State.ActiveClusterId
    if (-not $gates.Success) {
        throw "Host gate '$($gates.Failure.Name)' failed. Log: $($gates.Failure.LogPath)"
    }

    $commit = ""
    if ([bool]$Config.AutoCommit) {
        Write-ReviewLoopStatus -Message "Preparing commit: verification and all host gates passed." -Kind Progress
        & git -C $RepoPath add -A
        if ($LASTEXITCODE -ne 0) {
            throw "git add failed."
        }
        $title = @($Findings | Select-Object -First 1).Title
        $message = "$($Config.CommitMessagePrefix): $title"
        $commitOutput = & git -C $RepoPath commit -m $message 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "git commit failed: $($commitOutput -join [Environment]::NewLine)"
        }
        $commit = Get-ReviewLoopGitValue -RepoPath $RepoPath -Arguments @("rev-parse", "HEAD")
        $shortCommit = if ($commit.Length -gt 10) { $commit.Substring(0, 10) } else { $commit }
        Write-ReviewLoopStatus -Message "Committed $shortCommit · $message" -Kind Success
    }

    foreach ($finding in $Findings) {
        $finding.Status = "resolved"
        $finding.Verification = $Verification.Result
        $finding.ResolutionCommit = $commit
        $finding.FixerThreadId = ""
        $finding.UpdatedAt = [DateTimeOffset]::UtcNow.ToString("O")
    }
    Write-ReviewLoopLedger -Path $LedgerPath -Ledger $Ledger | Out-Null

    $State.CurrentHead = Get-ReviewLoopGitValue -RepoPath $RepoPath -Arguments @("rev-parse", "HEAD")
    $State.CleanPasses = 0
    $State.CleanHead = ""
    $State.ActiveClusterId = ""
    $State.ActiveFindingIds = @()
    $State.ActiveStrategy = $null
    $State.LastFixerResult = $null
    $State.ArchitectureRevision = 0
    Set-ReviewLoopCheckpoint -State $State -StatePath $StatePath -Stage "fix_committed"
    Write-ReviewLoopStatus -Message "Verified finding(s) resolved; clean-pass count reset to 0." -Kind Success
}

function Invoke-ReviewLoopCluster {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][object]$Ledger,
        [Parameter(Mandatory = $true)][string]$LedgerPath,
        [Parameter(Mandatory = $true)][object[]]$Findings,
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$Speed,
        [Parameter(Mandatory = $true)][string]$RunRoot,
        [string]$CodexPath = ""
    )

    $State.ActiveClusterId = [string]$Findings[0].ClusterId
    $State.ActiveFindingIds = @($Findings | ForEach-Object { [string]$_.Id })
    $State.ArchitectureRevision = 0
    Set-ReviewLoopCheckpoint -State $State -StatePath $StatePath -Stage "cluster_selected"
    Write-ReviewLoopRule -Title "Finding-Cluster $($State.ActiveClusterId)" -Kind Review
    Write-ReviewLoopStatus -Message "$($Findings.Count) Finding(s): $(@($Findings | ForEach-Object { $_.Title }) -join '; ')" -Kind Review

    $primary = $Findings[0]
    $candidates = @(Get-ReviewLoopTriggerCandidates -Finding $primary -Ledger $Ledger)
    $trigger = Invoke-ReviewLoopTriggerJudge `
        -Config $Config -State $State -StatePath $StatePath -RepoPath $RepoPath `
        -Speed $Speed -RunRoot $RunRoot -Finding $primary -Candidates $candidates -CodexPath $CodexPath
    $adjudication = switch (@($trigger.Calls).Count) {
        0 { "without a model call" }
        1 { "Luna" }
        2 { "Luna + Sol confirmation" }
        default { "Luna + Sol + Terra-Tie-Break" }
    }
    $triggerKind = if ($trigger.ArchitectureRecommended) { "Architecture" } elseif ($trigger.Confidence -eq "high") { "Info" } else { "Warning" }
    Write-ReviewLoopStatus `
        -Message "Trigger: $($trigger.Relation) · Confidence $($trigger.Confidence) · $adjudication" `
        -Kind $triggerKind
    $strategy = $null
    if ($trigger.ArchitectureRecommended) {
        Write-ReviewLoopStatus -Message "Semantic architecture trigger confirmed; creating a proposal and independent critique." -Kind Architecture
        $architectureFindings = @($Findings)
        foreach ($candidate in $candidates) {
            if ([string]$candidate.Finding.Status -in @("open", "pending") -and
                [string]$candidate.Finding.Id -notin $State.ActiveFindingIds) {
                $architectureFindings += $candidate.Finding
            }
        }
        $strategy = Invoke-ReviewLoopArchitectureGate `
            -Config $Config -State $State -StatePath $StatePath -RepoPath $RepoPath `
            -Speed $Speed -RunRoot $RunRoot -Findings $architectureFindings -Trigger $trigger -CodexPath $CodexPath
        $scope = Get-ReviewLoopArchitectureScope $strategy.Proposal
        $strategyKind = if ($strategy.Approved) { "Architecture" } else { "Warning" }
        Write-ReviewLoopStatus `
            -Message "Architecture: $($strategy.Proposal.recommendation) · $($scope.PathCount) paths ($($scope.ProductionPathCount) production) · $(if ($strategy.Approved) { 'approved' } else { 'limited to point fix' })" `
            -Kind $strategyKind
        if ($null -ne $strategy.Critique) {
            Write-ReviewLoopStatus -Message "Critic: $($strategy.Critique.decision) · Confidence $($strategy.Critique.confidence)" -Kind Architecture -Indent 1
        }
        if ($strategy.Approved) {
            $Findings = $architectureFindings
            $State.ActiveFindingIds = @($Findings | ForEach-Object { [string]$_.Id })
        }
    }
    $State.ActiveStrategy = $strategy
    Set-ReviewLoopCheckpoint -State $State -StatePath $StatePath -Stage "strategy_ready"

    $threadId = ""
    for ($attempt = 1; $attempt -le [int]$Config.MaxFixAttempts; $attempt++) {
        Set-ReviewLoopFindingsStatus -Findings $Findings -Status "fixing"
        foreach ($finding in $Findings) {
            $finding.FixAttempts = [int]$finding.FixAttempts + 1
        }
        Write-ReviewLoopLedger -Path $LedgerPath -Ledger $Ledger | Out-Null
        Set-ReviewLoopCheckpoint -State $State -StatePath $StatePath -Stage "fixing"
        $threadMode = if ($attempt -eq 1) { "new thread" } else { "resuming thread" }
        Write-ReviewLoopStatus -Message "Fixer · attempt $attempt/$($Config.MaxFixAttempts) · $threadMode" -Kind Progress

        $fixer = Invoke-ReviewLoopFixer `
            -Config $Config -State $State -StatePath $StatePath -RepoPath $RepoPath `
            -Speed $Speed -RunRoot $RunRoot -Findings $Findings -Strategy $strategy `
            -Attempt $attempt -ThreadId $threadId -CodexPath $CodexPath
        Assert-ReviewLoopRoleSuccess $fixer
        $changedPaths = @($fixer.StructuredResult.changedPaths |
            ForEach-Object { ([string]$_).Replace("\", "/") } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique)
        $fixer.StructuredResult.changedPaths = $changedPaths
        Write-ReviewLoopStatus `
            -Message "Fixer: $($fixer.StructuredResult.outcome) · $($changedPaths.Count) changed paths$(if ($changedPaths.Count -gt 0) { ': ' + ($changedPaths -join ', ') } else { '' })" `
            -Kind $(if ([string]$fixer.StructuredResult.outcome -eq "changed") { "Success" } else { "Warning" })
        if ($attempt -eq 1) {
            if ([string]::IsNullOrWhiteSpace([string]$fixer.ThreadId)) {
                throw "Fixer did not return a thread ID for a possible second attempt."
            }
            $threadId = [string]$fixer.ThreadId
            foreach ($finding in $Findings) {
                $finding.FixerThreadId = $threadId
            }
        }
        $State.LastFixerResult = [pscustomobject]@{
            StructuredResult = $fixer.StructuredResult
            ThreadId = $threadId
            Attempt = $attempt
        }
        Write-ReviewLoopLedger -Path $LedgerPath -Ledger $Ledger | Out-Null
        Set-ReviewLoopCheckpoint -State $State -StatePath $StatePath -Stage "fix_attempted"

        if ([string]$fixer.StructuredResult.outcome -eq "blocked") {
            if ($attempt -ge [int]$Config.MaxFixAttempts) {
                break
            }
            continue
        }

        $verification = Invoke-ReviewLoopVerifier `
            -Config $Config -State $State -StatePath $StatePath -RepoPath $RepoPath `
            -Speed $Speed -RunRoot $RunRoot -Findings $Findings -FixerCall $fixer -CodexPath $CodexPath
        $targetedCommand = [string]$verification.Result.targetedTest.command
        $targetedState = if ([bool]$verification.Result.targetedTest.passed) { "passed" } else { "failed" }
        Write-ReviewLoopStatus `
            -Message "Verifier: $($verification.Result.verdict) · Confidence $($verification.Result.confidence) · Test $targetedState$(if (-not [string]::IsNullOrWhiteSpace($targetedCommand)) { ': ' + $targetedCommand } else { '' })" `
            -Kind $(if ($verification.Accepted) { "Success" } else { "Warning" })
        Set-ReviewLoopCheckpoint -State $State -StatePath $StatePath -Stage "verified"

        if ($verification.Accepted) {
            Complete-ReviewLoopFix `
                -Config $Config -State $State -StatePath $StatePath `
                -Ledger $Ledger -LedgerPath $LedgerPath -Findings $Findings `
                -Verification $verification -RepoPath $RepoPath -RunRoot $RunRoot
            return
        }
        if ([string]$verification.Result.verdict -eq "obsolete") {
            Set-ReviewLoopFindingsStatus -Findings $Findings -Status "superseded"
            foreach ($finding in $Findings) {
                $finding.Verification = $verification.Result
            }
            Write-ReviewLoopLedger -Path $LedgerPath -Ledger $Ledger | Out-Null
            return
        }
    }

    $reason = "Finding cluster remained open after $($Config.MaxFixAttempts) fix attempts."
    Set-ReviewLoopFindingsStatus -Findings $Findings -Status "blocked" -Reason $reason
    Write-ReviewLoopLedger -Path $LedgerPath -Ledger $Ledger | Out-Null
    throw $reason
}

function Resume-ReviewLoopInterruptedFix {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][object]$Ledger,
        [Parameter(Mandatory = $true)][string]$LedgerPath,
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$Speed,
        [Parameter(Mandatory = $true)][string]$RunRoot,
        [string]$CodexPath = ""
    )

    if ([string]$State.Stage -notin @("fixing", "fix_attempted", "verified") -or
        @($State.ActiveFindingIds).Count -eq 0) {
        return $false
    }

    $ids = @($State.ActiveFindingIds | ForEach-Object { [string]$_ })
    $findings = @($Ledger.Findings | Where-Object { [string]$_.Id -in $ids })
    if ($findings.Count -ne $ids.Count) {
        throw "Interrupted fix cannot be resumed: active findings are missing from the ledger."
    }

    Write-ReviewLoopStatus -Message "Resuming interrupted fix cluster $($State.ActiveClusterId)." -Kind Warning
    $lastFixer = if ($null -ne $State.LastFixerResult -and $null -ne $State.LastFixerResult.StructuredResult) {
        [pscustomobject]@{
            StructuredResult = $State.LastFixerResult.StructuredResult
            ThreadId = [string]$State.LastFixerResult.ThreadId
        }
    }
    else {
        [pscustomobject]@{
            StructuredResult = [pscustomobject]@{
                schemaVersion = "1.0"
                outcome = "changed"
                summary = "Interrupted fix; the current worktree will be verified independently."
                changedPaths = @()
                targetedTests = @()
                remainingRisk = "Fixer completion is missing because the process was interrupted."
            }
            ThreadId = [string]$findings[0].FixerThreadId
        }
    }

    $verification = Invoke-ReviewLoopVerifier `
        -Config $Config -State $State -StatePath $StatePath -RepoPath $RepoPath `
        -Speed $Speed -RunRoot $RunRoot -Findings $findings -FixerCall $lastFixer -CodexPath $CodexPath
    if ($verification.Accepted) {
        Complete-ReviewLoopFix `
            -Config $Config -State $State -StatePath $StatePath `
            -Ledger $Ledger -LedgerPath $LedgerPath -Findings $findings `
            -Verification $verification -RepoPath $RepoPath -RunRoot $RunRoot
        return $true
    }

    $attempt = (@($findings | ForEach-Object { [int]$_.FixAttempts } | Measure-Object -Maximum).Maximum)
    if ($attempt -ge [int]$Config.MaxFixAttempts) {
        $reason = "Interrupted cluster remained open after $attempt fix attempts."
        Set-ReviewLoopFindingsStatus -Findings $findings -Status "blocked" -Reason $reason
        Write-ReviewLoopLedger -Path $LedgerPath -Ledger $Ledger | Out-Null
        throw $reason
    }

    $threadId = [string]$lastFixer.ThreadId
    if ([string]::IsNullOrWhiteSpace($threadId)) {
        $threadId = [string]$findings[0].FixerThreadId
    }
    if ([string]::IsNullOrWhiteSpace($threadId)) {
        throw "Interrupted fix requires a stored fixer thread ID for the final attempt."
    }

    $nextAttempt = $attempt + 1
    foreach ($finding in $findings) {
        $finding.Status = "fixing"
        $finding.FixAttempts = [int]$finding.FixAttempts + 1
    }
    Write-ReviewLoopLedger -Path $LedgerPath -Ledger $Ledger | Out-Null
    $fixer = Invoke-ReviewLoopFixer `
        -Config $Config -State $State -StatePath $StatePath -RepoPath $RepoPath `
        -Speed $Speed -RunRoot $RunRoot -Findings $findings -Strategy $State.ActiveStrategy `
        -Attempt $nextAttempt -ThreadId $threadId -CodexPath $CodexPath
    Assert-ReviewLoopRoleSuccess $fixer
    $State.LastFixerResult = [pscustomobject]@{
        StructuredResult = $fixer.StructuredResult
        ThreadId = $threadId
        Attempt = $nextAttempt
    }
    Set-ReviewLoopCheckpoint -State $State -StatePath $StatePath -Stage "fix_attempted"
    $finalVerification = Invoke-ReviewLoopVerifier `
        -Config $Config -State $State -StatePath $StatePath -RepoPath $RepoPath `
        -Speed $Speed -RunRoot $RunRoot -Findings $findings -FixerCall $fixer -CodexPath $CodexPath
    if (-not $finalVerification.Accepted) {
        $reason = "Interrupted cluster remained open after $nextAttempt fix attempts."
        Set-ReviewLoopFindingsStatus -Findings $findings -Status "blocked" -Reason $reason
        Write-ReviewLoopLedger -Path $LedgerPath -Ledger $Ledger | Out-Null
        throw $reason
    }

    Complete-ReviewLoopFix `
        -Config $Config -State $State -StatePath $StatePath `
        -Ledger $Ledger -LedgerPath $LedgerPath -Findings $findings `
        -Verification $finalVerification -RepoPath $RepoPath -RunRoot $RunRoot
    return $true
}

function Invoke-CodexReviewLoop {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [string]$ConfigPath = "",
        [ValidateSet("standard", "fast")][string]$Speed = "standard",
        [string]$CodexPath = "",
        [switch]$NewRun,
        [ValidateSet("compact", "balanced", "detailed")][string]$OutputMode = "compact",
        [ValidateRange(0, 3600)][int]$HeartbeatSeconds = 30,
        [ValidateSet("Host", "Ansi", "Always", "Auto", "Never")][string]$ColorMode = "Host"
    )

    Initialize-ReviewLoopConsole `
        -OutputMode $OutputMode `
        -HeartbeatSeconds $HeartbeatSeconds `
        -ColorMode $ColorMode `
        -TranscriptPath ""
    $repo = Get-ReviewLoopRepositoryRoot -RepoPath $RepoPath
    $resolvedConfigPath = Resolve-ReviewLoopConfigPath -RepoPath $repo -ConfigPath $ConfigPath
    $config = Import-ReviewLoopConfig -ConfigPath $resolvedConfigPath -RepoPath $repo
    $paths = New-ReviewLoopRunPaths -Config $config -RepoPath $repo
    $statePath = ""
    $state = $null
    $resumed = $false
    if (-not $NewRun) {
        $active = Get-ReviewLoopLatestActiveStatePath -ProfileRoot $paths.ProfileRoot
        if (-not [string]::IsNullOrWhiteSpace($active)) {
            $statePath = $active
            $state = Read-ReviewLoopState -Path $statePath
            $paths.RunRoot = Split-Path -Parent $statePath
            $resumed = $true
        }
    }

    if ($null -eq $state) {
        if (-not (Test-ReviewLoopGitClean -RepoPath $repo)) {
            throw "A new review loop requires a clean worktree."
        }
        Initialize-ReviewLoopRunPaths -Paths $paths | Out-Null
        $statePath = $paths.StatePath
        $state = New-ReviewLoopState -RepoPath $repo -ReviewBase ([string]$config.ReviewBase) -Speed $Speed -RunRoot $paths.RunRoot
        Write-ReviewLoopState -Path $statePath -State $state | Out-Null
    }
    elseif ([string]$state.Speed -ne $Speed) {
        throw "A resumed run keeps its global speed '$($state.Speed)'; requested speed was '$Speed'."
    }

    $terminalPath = Join-Path $paths.RunRoot "terminal.log"
    Initialize-ReviewLoopConsole `
        -OutputMode $OutputMode `
        -HeartbeatSeconds $HeartbeatSeconds `
        -ColorMode $ColorMode `
        -TranscriptPath $terminalPath

    $ledger = Read-ReviewLoopLedger -Path $paths.LedgerPath -RepoPath $repo
    Write-ReviewLoopLedger -Path $paths.LedgerPath -Ledger $ledger | Out-Null
    $head = Get-ReviewLoopGitValue -RepoPath $repo -Arguments @("rev-parse", "HEAD")
    $shortHead = if ($head.Length -gt 10) { $head.Substring(0, 10) } else { $head }
    Write-ReviewLoopRule -Title "Codex Review Loop" -Kind Progress
    Write-ReviewLoopKeyValue -Name "Repository" -Value $repo
    Write-ReviewLoopKeyValue -Name "Branch" -Value ([string]$state.Branch)
    Write-ReviewLoopKeyValue -Name "Review-Base" -Value ([string]$config.ReviewBase)
    Write-ReviewLoopKeyValue -Name "HEAD" -Value $shortHead
    Write-ReviewLoopKeyValue -Name "Speed" -Value $Speed
    Write-ReviewLoopKeyValue -Name "Output" -Value "$OutputMode · heartbeat ${HeartbeatSeconds}s · $ColorMode"
    Write-ReviewLoopKeyValue -Name "Profile" -Value "$($config.Name) · $resolvedConfigPath"
    Write-ReviewLoopKeyValue -Name "Run" -Value "$($state.RunId) ($(if ($resumed) { 'resumed' } else { 'new' }))"
    Write-ReviewLoopKeyValue -Name "Checkpoint" -Value $statePath
    Write-ReviewLoopKeyValue -Name "Ledger" -Value $paths.LedgerPath
    Write-ReviewLoopKeyValue -Name "Terminal-Log" -Value $terminalPath

    try {
        Get-ReviewLoopGitValue -RepoPath $repo -Arguments @("rev-parse", "--verify", "$($config.ReviewBase)^{commit}") | Out-Null
        Resume-ReviewLoopInterruptedFix `
            -Config $config -State $state -StatePath $statePath `
            -Ledger $ledger -LedgerPath $paths.LedgerPath `
            -RepoPath $repo -Speed $Speed -RunRoot $paths.RunRoot -CodexPath $CodexPath | Out-Null
        while ([int]$state.ReviewCycle -lt [int]$config.MaxReviewCycles) {
            if (-not (Test-ReviewLoopGitClean -RepoPath $repo)) {
                throw "Worktree is not clean outside a resumable fix step."
            }

            $state.ReviewCycle = [int]$state.ReviewCycle + 1
            $state.CurrentHead = Get-ReviewLoopGitValue -RepoPath $repo -Arguments @("rev-parse", "HEAD")
            Set-ReviewLoopCheckpoint -State $state -StatePath $statePath -Stage "reviewing"
            Write-ReviewLoopRule -Title ("Review cycle {0}/{1}" -f $state.ReviewCycle, $config.MaxReviewCycles) -Kind Review
            $review = Invoke-ReviewLoopReview `
                -Config $config -State $state -StatePath $statePath -RepoPath $repo `
                -Speed $Speed -RunRoot $paths.RunRoot -CodexPath $CodexPath
            Merge-ReviewLoopFindings `
                -Ledger $ledger -Findings @($review.Result.findings) `
                -ReviewId $review.ReviewId -Head $review.Head | Out-Null
            Write-ReviewLoopLedger -Path $paths.LedgerPath -Ledger $ledger | Out-Null
            Set-ReviewLoopCheckpoint -State $state -StatePath $statePath -Stage "reviewed"

            $blocked = @($ledger.Findings | Where-Object { [string]$_.Status -eq "blocked" })
            if ($blocked.Count -gt 0) {
                throw "Ledger contains $($blocked.Count) blocked findings."
            }
            $open = @(Get-ReviewLoopOpenFindings -Ledger $ledger)
            if ($open.Count -eq 0 -and [string]$review.Result.classification -eq "clean") {
                if ([string]$state.CleanHead -eq [string]$review.Head) {
                    $state.CleanPasses = [int]$state.CleanPasses + 1
                }
                else {
                    $state.CleanHead = [string]$review.Head
                    $state.CleanPasses = 1
                }
                Set-ReviewLoopCheckpoint -State $state -StatePath $statePath -Stage "clean_review"
                $reviewHead = [string]$review.Head
                $cleanShortHead = if ($reviewHead.Length -gt 10) { $reviewHead.Substring(0, 10) } else { $reviewHead }
                Write-ReviewLoopStatus -Message "Clean pass $($state.CleanPasses)/$($config.CleanPassesRequired) on unchanged HEAD $cleanShortHead" -Kind Success
                if ([int]$state.CleanPasses -ge [int]$config.CleanPassesRequired) {
                    $state.Status = "completed"
                    $state.ExitCode = 0
                    Set-ReviewLoopCheckpoint -State $state -StatePath $statePath -Stage "completed" -Status "completed"
                    Write-ReviewLoopResultBlock -Title "Review Loop completed" -Kind Success -Values ([ordered]@{
                        Status = "completed"
                        Cycles = $state.ReviewCycle
                        "Clean passes" = "$($state.CleanPasses)/$($config.CleanPassesRequired)"
                        "Open findings" = 0
                        "Blocked findings" = 0
                        Run = $paths.RunRoot
                        Ledger = $paths.LedgerPath
                        Transcript = $terminalPath
                    })
                    return [pscustomobject]@{
                        Status = $state.Status
                        ExitCode = 0
                        RunRoot = $paths.RunRoot
                        StatePath = $statePath
                        LedgerPath = $paths.LedgerPath
                        ReviewCycles = $state.ReviewCycle
                        CleanPasses = $state.CleanPasses
                    }
                }
                continue
            }

            $state.CleanPasses = 0
            $state.CleanHead = ""
            Write-ReviewLoopStatus -Message "Clean-pass count reset; processing $($open.Count) open findings." -Kind Warning
            $groups = @($open | Group-Object ClusterId | Sort-Object Name)
            foreach ($group in $groups) {
                $activeGroup = @($group.Group | Where-Object { [string]$_.Status -in @("pending", "open", "fixing") })
                if ($activeGroup.Count -eq 0) {
                    continue
                }
                Invoke-ReviewLoopCluster `
                    -Config $config -State $state -StatePath $statePath `
                    -Ledger $ledger -LedgerPath $paths.LedgerPath `
                    -Findings $activeGroup -RepoPath $repo -Speed $Speed `
                    -RunRoot $paths.RunRoot -CodexPath $CodexPath
            }
        }
        throw "Maximum review cycle count $($config.MaxReviewCycles) reached."
    }
    catch {
        $message = $_.Exception.Message
        $state.Status = if ($message -match "(?i)blocked|unclear|host gate|fix attempt|maximum|revision|architecture proposal") { "blocked" } else { "failed" }
        $state.ExitCode = if ($state.Status -eq "blocked") { 3 } else { 2 }
        $state.BlockedReason = $message
        Set-ReviewLoopCheckpoint -State $state -StatePath $statePath -Stage "stopped" -Status $state.Status
        Write-ReviewLoopStatus -Message $message -Kind Error
        $openCount = @($ledger.Findings | Where-Object { [string]$_.Status -in @("pending", "open", "fixing") }).Count
        $blockedCount = @($ledger.Findings | Where-Object { [string]$_.Status -eq "blocked" }).Count
        Write-ReviewLoopResultBlock -Title "Review Loop stopped" -Kind Error -Values ([ordered]@{
            Status = $state.Status
            Reason = $message
            Cycles = $state.ReviewCycle
            "Clean passes" = "$($state.CleanPasses)/$($config.CleanPassesRequired)"
            "Open findings" = $openCount
            "Blocked findings" = $blockedCount
            Run = $paths.RunRoot
            Ledger = $paths.LedgerPath
            Transcript = $terminalPath
        })
        return [pscustomobject]@{
            Status = $state.Status
            ExitCode = $state.ExitCode
            Reason = $message
            RunRoot = $paths.RunRoot
            StatePath = $statePath
            LedgerPath = $paths.LedgerPath
            ReviewCycles = $state.ReviewCycle
            CleanPasses = $state.CleanPasses
        }
    }
}
