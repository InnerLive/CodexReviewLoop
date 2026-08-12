function Test-ReviewLoopStateCanResume {
    param([Parameter(Mandatory = $true)][object]$State)

    if ([string]$State.Status -eq "running") {
        return $true
    }
    if ([string]$State.Status -eq "limit_reached") {
        return $true
    }
    return (
        [string]$State.Status -eq "failed" -and
        (
            [string]$State.Stage -ne "stopped" -or
            @($State.ActiveFindingIds).Count -gt 0 -or
            $null -ne (Get-ReviewLoopObjectProperty -Object $State -Name "ActiveRoleCall")
        )
    )
}

function Get-ReviewLoopLatestActiveStatePath {
    param([Parameter(Mandatory = $true)][string]$ProfileRoot)

    if (-not (Test-Path -LiteralPath $ProfileRoot)) {
        return ""
    }
    $runs = @(Get-ChildItem -LiteralPath $ProfileRoot -Directory | ForEach-Object {
        $path = Join-Path $_.FullName "run-v1.json"
        if (Test-Path -LiteralPath $path) {
            $state = Read-ReviewLoopState -Path $path
            $createdAt = [DateTimeOffset]::MinValue
            if ($state.PSObject.Properties.Name -contains "CreatedAt") {
                [DateTimeOffset]::TryParse([string]$state.CreatedAt, [ref]$createdAt) | Out-Null
            }
            [pscustomobject]@{
                Path = $path
                State = $state
                CreatedAt = $createdAt
            }
        }
    } | Sort-Object CreatedAt, Path -Descending)
    if ($runs.Count -eq 0 -or
        -not (Test-ReviewLoopStateCanResume -State $runs[0].State)) {
        return ""
    }
    return [string]$runs[0].Path
}

function New-ReviewLoopRunPaths {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [string]$Branch = "",
        [string]$ReviewBaseCommit = ""
    )

    $canonicalRepo = Get-ReviewLoopRepositoryRoot -RepoPath $RepoPath
    $logRoot = Resolve-ReviewLoopPath -Path ([string]$Config.LogRoot)
    if ([string]::IsNullOrWhiteSpace($Branch)) {
        $Branch = Get-ReviewLoopGitValue -RepoPath $canonicalRepo -Arguments @(
            "branch", "--show-current"
        )
    }
    if ([string]::IsNullOrWhiteSpace($ReviewBaseCommit)) {
        $ReviewBaseCommit = Get-ReviewLoopGitValue -RepoPath $canonicalRepo -Arguments @(
            "rev-parse", "--verify", "$($Config.ReviewBase)^{commit}"
        )
    }
    $safeBranch = [regex]::Replace($Branch, "[^A-Za-z0-9._-]+", "-").Trim("-", ".", "_")
    if ([string]::IsNullOrWhiteSpace($safeBranch)) {
        $safeBranch = "detached"
    }
    if ($safeBranch.Length -gt 40) {
        $safeBranch = $safeBranch.Substring(0, 40).TrimEnd("-", ".", "_")
    }
    $repositoryKey = (Get-ReviewLoopSha256 (
        ConvertTo-ReviewLoopCanonicalText $canonicalRepo
    )).Substring(0, 8)
    $baseKey = (Get-ReviewLoopSha256 (
        ConvertTo-ReviewLoopCanonicalText ([string]$Config.ReviewBase)
    )).Substring(0, 8)
    $profileRoot = Join-Path $logRoot "$($Config.Name)-$repositoryKey-$safeBranch-$baseKey"
    [System.IO.Directory]::CreateDirectory($profileRoot) | Out-Null
    $legacyRoots = @(
        Get-ChildItem -LiteralPath $logRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object {
                $_.FullName -ne $profileRoot -and
                $_.Name.StartsWith("$($Config.Name)-$repositoryKey-$safeBranch-")
            } |
            Sort-Object LastWriteTime -Descending |
            ForEach-Object { $_.FullName }
    )
    return [pscustomobject]@{
        StableProfileRoot = $profileRoot
        ProfileRoot = $profileRoot
        RunRoot = ""
        StatePath = ""
        LedgerPath = Join-Path $profileRoot "ledger-v2.json"
        LegacyProfileRoots = $legacyRoots
    }
}

function Import-ReviewLoopLegacyLedgers {
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$Branch,
        [Parameter(Mandatory = $true)][string]$ReviewBase
    )

    if (Test-Path -LiteralPath $Paths.LedgerPath) {
        return
    }
    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($root in @($Paths.LegacyProfileRoots)) {
        $matchingState = @(Get-ChildItem -LiteralPath $root -Recurse -Filter "run-v1.json" -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | ForEach-Object {
                try { Read-ReviewLoopState -Path $_.FullName } catch { $null }
            } | Where-Object {
                $null -ne $_ -and [string]$_.RepoPath -eq $RepoPath -and
                [string]$_.Branch -eq $Branch -and [string]$_.ReviewBase -eq $ReviewBase
            } | Select-Object -First 1)
        if ($matchingState.Count -eq 0) {
            continue
        }
        $legacyPath = @(
            Join-Path $root "ledger-v2.json"
            Join-Path $root "ledger-v1.json"
        ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if ([string]::IsNullOrWhiteSpace([string]$legacyPath)) {
            continue
        }
        $legacy = Read-ReviewLoopLedger -Path $legacyPath -RepoPath $RepoPath
        foreach ($finding in @($legacy.Findings)) {
            [void]$records.Add($finding)
        }
    }
    if ($records.Count -eq 0) {
        return
    }
    $ledger = New-ReviewLoopLedger -RepoPath $RepoPath
    $ledger.Findings = @($records | Group-Object Id | ForEach-Object {
        $ordered = @($_.Group | Sort-Object UpdatedAt)
        $selected = $ordered[-1]
        $selected.CreatedAt = [string]($ordered | Sort-Object CreatedAt | Select-Object -First 1).CreatedAt
        $selected.RecurrenceCount = [int](($ordered | Measure-Object RecurrenceCount -Maximum).Maximum)
        if ([string]$selected.Status -in @("fixing", "blocked")) {
            $selected.Status = "open"
            $selected.FixAttempts = 0
            $selected.FixerThreadId = ""
            $selected.BlockedReason = ""
            $selected.LastBlockedHead = ""
            $selected.Verification = $null
        }
        $selected
    } | Sort-Object Id)
    Write-ReviewLoopLedger -Path $Paths.LedgerPath -Ledger $ledger | Out-Null
    Write-ReviewLoopStatus -Message "Imported $($ledger.Findings.Count) finding(s) into the stable ledger: $($Paths.LedgerPath)" -Kind Info
}

function Initialize-ReviewLoopRunPaths {
    param([Parameter(Mandatory = $true)][object]$Paths)

    $runName = "{0}-{1}" -f (Get-Date -Format "yyyyMMdd-HHmmss"), ([Guid]::NewGuid().ToString("N").Substring(0, 6))
    $Paths.RunRoot = Join-Path $Paths.ProfileRoot $runName
    [System.IO.Directory]::CreateDirectory($Paths.RunRoot) | Out-Null
    $Paths.StatePath = Join-Path $Paths.RunRoot "run-v1.json"
    return $Paths
}

function Assert-ReviewLoopResumeInvariant {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$ReviewBase,
        [switch]$SkipHead
    )

    if (-not (Test-ReviewLoopSamePath -Left ([string]$State.RepoPath) -Right $RepoPath)) {
        throw (New-ReviewLoopFailureException `
            -Message "The saved checkpoint belongs to repository '$($State.RepoPath)', but this command selected '$RepoPath'." `
            -NextSteps @(
                "Run the command for the repository stored in the checkpoint: '$($State.RepoPath)'."
                "If '$RepoPath' is intentional, make its worktree clean and start it with -NewRun."
            ))
    }
    $branch = Get-ReviewLoopGitValue -RepoPath $RepoPath -Arguments @("branch", "--show-current")
    if ([string]$State.Branch -ne $branch) {
        throw (New-ReviewLoopFailureException `
            -Message "The saved checkpoint is for branch '$($State.Branch)', but the repository is currently on '$branch'." `
            -NextSteps @(
                "To resume the checkpoint, switch back to '$($State.Branch)' and run the same command again."
                "To review '$branch' instead, make its worktree clean and start with -NewRun."
            ))
    }
    if ([string]$State.ReviewBase -ne $ReviewBase) {
        throw (New-ReviewLoopFailureException `
            -Message "The saved checkpoint uses review base '$($State.ReviewBase)', but the selected profile now uses '$ReviewBase'." `
            -NextSteps @(
                "To resume the checkpoint, restore ReviewBase='$($State.ReviewBase)' in the profile and run the same command again."
                "To use ReviewBase='$ReviewBase', make the worktree clean and start with -NewRun."
            ))
    }
    if (-not $SkipHead) {
        $head = Get-ReviewLoopGitValue -RepoPath $RepoPath -Arguments @("rev-parse", "HEAD")
        if ([string]$State.CurrentHead -ne $head) {
            throw (New-ReviewLoopFailureException `
                -Message "The repository moved after the checkpoint: saved HEAD is '$($State.CurrentHead)', current HEAD is '$head'. A commit, checkout, rebase, or another tool changed the branch." `
                -NextSteps @(
                    "If the current HEAD is intentional, make the worktree clean and start with -NewRun."
                    "If the checkpoint should be resumed, restore the branch to '$($State.CurrentHead)' using your normal Git workflow, then run the same command again."
                ))
        }
    }
}

function Initialize-ReviewLoopCommitHistory {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][string]$RepoPath
    )

    if ([bool](Get-ReviewLoopObjectProperty `
        -Object $State -Name "LoopCommitsInitialized" -Default $false)) {
        return
    }

    $startHead = [string]$State.StartHead
    $currentHead = [string]$State.CurrentHead
    if ([string]::IsNullOrWhiteSpace($startHead) -or
        [string]::IsNullOrWhiteSpace($currentHead)) {
        throw "Legacy checkpoint cannot reconstruct loop commits because its HEAD range is incomplete."
    }

    & git -C $RepoPath merge-base --is-ancestor $startHead $currentHead 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Legacy checkpoint cannot reconstruct loop commits because saved HEAD is not descended from StartHead."
    }
    $history = Get-ReviewLoopGitValue -RepoPath $RepoPath -Arguments @(
        "rev-list", "--reverse", "--first-parent", "$startHead..$currentHead"
    )
    $commits = @($history -split "\r?\n" |
        ForEach-Object { $_.Trim().ToLowerInvariant() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique)
    $State.LoopCommits = $commits
    $State.LoopCommitsInitialized = $true
    Write-ReviewLoopState -Path $StatePath -State $State | Out-Null
}

function Add-ReviewLoopVerifiedCommit {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$Commit
    )

    $normalized = $Commit.Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        throw "A verified loop commit cannot be empty."
    }
    $existing = @((Get-ReviewLoopObjectProperty `
        -Object $State -Name "LoopCommits" -Default @()) |
        ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($normalized -notin $existing) {
        $State.LoopCommits = @($existing) + @($normalized)
    }
    $State.LoopCommitsInitialized = $true
}

function Resolve-ReviewLoopHostExecutable {
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$FilePath
    )

    $expanded = [Environment]::ExpandEnvironmentVariables($FilePath)
    if ([System.IO.Path]::IsPathRooted($expanded) -or
        $expanded.Contains("\") -or $expanded.Contains("/")) {
        $candidate = if ([System.IO.Path]::IsPathRooted($expanded)) {
            $expanded
        }
        else {
            Join-Path $RepoPath $expanded
        }
        return Resolve-ReviewLoopPath -Path $candidate -MustExist
    }
    $command = Get-Command $expanded -CommandType Application,ExternalScript -ErrorAction Stop |
        Select-Object -First 1
    return $command.Source
}

function Assert-ReviewLoopHostGatePreflight {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][string]$RepoPath
    )

    foreach ($gate in @($Config.HostGates)) {
        try {
            Resolve-ReviewLoopHostExecutable `
                -RepoPath $RepoPath -FilePath ([string]$gate.FilePath) | Out-Null
        }
        catch {
            throw (New-ReviewLoopFailureException `
                -Message "Host gate '$($gate.Name)' cannot start because executable '$($gate.FilePath)' could not be resolved: $($_.Exception.Message)" `
                -NextSteps @(
                    "Install the required executable or correct this host gate's FilePath in the selected profile."
                    "Confirm the executable can be started from the repository, then run the same command again."
                ))
        }
    }
}

function Get-ReviewLoopRepositorySnapshot {
    param([Parameter(Mandatory = $true)][string]$RepoPath)

    $headRef = (& git -C $RepoPath symbolic-ref --quiet HEAD 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -notin @(0, 1)) {
        throw "Git could not inspect the symbolic HEAD reference."
    }
    return [pscustomobject]@{
        Head = Get-ReviewLoopGitValue -RepoPath $RepoPath -Arguments @("rev-parse", "HEAD")
        Fingerprint = Get-ReviewLoopWorktreeFingerprint -RepoPath $RepoPath
        Branch = Get-ReviewLoopGitValue -RepoPath $RepoPath -Arguments @(
            "branch", "--show-current"
        )
        HeadRef = $headRef
    }
}

function Get-ReviewLoopReviewerRecoveryLocatorPath {
    param([Parameter(Mandatory = $true)][string]$RepoPath)

    $path = Get-ReviewLoopGitValue -RepoPath $RepoPath -Arguments @(
        "rev-parse", "--git-path", "codex-review-loop-reviewer-recovery.json"
    )
    if (-not [System.IO.Path]::IsPathRooted($path)) {
        $path = Join-Path $RepoPath $path
    }
    return [System.IO.Path]::GetFullPath($path)
}

function Set-ReviewLoopReviewerRecoveryLocator {
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$StatePath
    )

    Write-ReviewLoopAtomicJson `
        -Path (Get-ReviewLoopReviewerRecoveryLocatorPath -RepoPath $RepoPath) `
        -Value ([pscustomobject][ordered]@{
            SchemaVersion = "1.0"
            RepoPath = [System.IO.Path]::GetFullPath($RepoPath)
            StatePath = [System.IO.Path]::GetFullPath($StatePath)
        })
}

function Clear-ReviewLoopReviewerRecoveryLocator {
    param([Parameter(Mandatory = $true)][string]$RepoPath)

    $path = Get-ReviewLoopReviewerRecoveryLocatorPath -RepoPath $RepoPath
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        [System.IO.File]::Delete($path)
    }
}

function Get-ReviewLoopReviewerRecoveryStatePath {
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$LogRoot,
        [Parameter(Mandatory = $true)][string]$ReviewBase
    )

    $locatorPath = Get-ReviewLoopReviewerRecoveryLocatorPath -RepoPath $RepoPath
    if (-not (Test-Path -LiteralPath $locatorPath -PathType Leaf)) {
        return ""
    }
    $locator = Read-ReviewLoopJson -Path $locatorPath
    if ([string](Get-ReviewLoopObjectProperty `
            -Object $locator -Name "SchemaVersion" -Default "") -ne "1.0") {
        throw "Reviewer recovery locator has an unsupported schema version."
    }
    if (-not (Test-ReviewLoopSamePath `
            -Left ([string](Get-ReviewLoopObjectProperty `
                -Object $locator -Name "RepoPath" -Default "")) `
            -Right $RepoPath)) {
        throw "Reviewer recovery locator belongs to another repository."
    }

    $statePath = [string](Get-ReviewLoopObjectProperty `
        -Object $locator -Name "StatePath" -Default "")
    if ([string]::IsNullOrWhiteSpace($statePath) -or
        -not [System.IO.Path]::IsPathRooted($statePath)) {
        throw "Reviewer recovery locator contains an invalid checkpoint path."
    }
    $resolvedLogRoot = [System.IO.Path]::GetFullPath($LogRoot).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar)
    $resolvedStatePath = [System.IO.Path]::GetFullPath($statePath)
    $logPrefix = $resolvedLogRoot + [System.IO.Path]::DirectorySeparatorChar
    if (-not $resolvedStatePath.StartsWith(
            $logPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Reviewer recovery checkpoint is outside the configured LogRoot."
    }
    if (-not (Test-Path -LiteralPath $resolvedStatePath -PathType Leaf)) {
        Clear-ReviewLoopReviewerRecoveryLocator -RepoPath $RepoPath
        return ""
    }

    $state = Read-ReviewLoopState -Path $resolvedStatePath
    $active = Get-ReviewLoopObjectProperty -Object $state -Name "ActiveRoleCall"
    if (-not (Test-ReviewLoopSamePath -Left ([string]$state.RepoPath) -Right $RepoPath) -or
        [string]$state.ReviewBase -ne $ReviewBase) {
        throw "Reviewer recovery checkpoint does not match this repository invocation."
    }
    if ($null -eq $active -or [string]$active.Role -ne "Reviewer" -or
        -not (Test-ReviewLoopStateCanResume -State $state)) {
        Clear-ReviewLoopReviewerRecoveryLocator -RepoPath $RepoPath
        return ""
    }
    return $resolvedStatePath
}

function Restore-ReviewLoopReviewerRepository {
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][object]$Recovery,
        [AllowNull()][object]$State = $null
    )

    $expectedCleanFingerprint = Get-ReviewLoopSha256 ""
    $baselineFingerprint = [string](Get-ReviewLoopObjectProperty `
        -Object $Recovery -Name "WorktreeFingerprint" -Default "")
    if ($baselineFingerprint -ne $expectedCleanFingerprint) {
        throw "Reviewer cleanup requires a checkpoint captured from a clean worktree."
    }
    $baselineHead = [string](Get-ReviewLoopObjectProperty `
        -Object $Recovery -Name "RepositoryHead" -Default "")
    $verifiedHead = Get-ReviewLoopGitValue -RepoPath $RepoPath -Arguments @(
        "rev-parse", "--verify", "$baselineHead^{commit}"
    )
    if ($verifiedHead -ne $baselineHead) {
        throw "Reviewer cleanup baseline commit could not be verified."
    }

    $baselineHeadRef = [string](Get-ReviewLoopObjectProperty `
        -Object $Recovery -Name "RepositoryHeadRef" -Default "")
    $baselineBranch = [string](Get-ReviewLoopObjectProperty `
        -Object $Recovery -Name "RepositoryBranch" -Default "")
    if ([string]::IsNullOrWhiteSpace($baselineHeadRef) -and
        -not [string]::IsNullOrWhiteSpace($baselineBranch)) {
        $baselineHeadRef = "refs/heads/$baselineBranch"
    }
    if ([string]::IsNullOrWhiteSpace($baselineHeadRef) -and $null -ne $State) {
        $legacyBranch = [string](Get-ReviewLoopObjectProperty `
            -Object $State -Name "Branch" -Default "")
        if (-not [string]::IsNullOrWhiteSpace($legacyBranch)) {
            $baselineHeadRef = "refs/heads/$legacyBranch"
            $baselineBranch = $legacyBranch
        }
    }

    $current = Get-ReviewLoopRepositorySnapshot -RepoPath $RepoPath
    if ([string]$current.Head -eq $baselineHead -and
        [string]$current.Fingerprint -eq $baselineFingerprint -and
        [string]$current.HeadRef -eq $baselineHeadRef) {
        return
    }

    if (-not [string]::IsNullOrWhiteSpace($baselineHeadRef)) {
        & git -C $RepoPath check-ref-format $baselineHeadRef 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw "Reviewer cleanup baseline HEAD reference is invalid: $baselineHeadRef"
        }
        $currentRefValue = (& git -C $RepoPath show-ref --verify --hash $baselineHeadRef `
            2>$null | Out-String).Trim()
        if ($LASTEXITCODE -notin @(0, 1)) {
            throw "Git could not inspect the Reviewer cleanup branch reference."
        }
        if ($currentRefValue -ne $baselineHead) {
            $oldValue = if ([string]::IsNullOrWhiteSpace($currentRefValue)) {
                "0" * $baselineHead.Length
            }
            else {
                $currentRefValue
            }
            $output = @(& git -C $RepoPath update-ref $baselineHeadRef `
                $baselineHead $oldValue 2>&1)
            if ($LASTEXITCODE -ne 0) {
                throw "Git could not restore the Reviewer branch reference: $($output -join ' ')"
            }
        }
        $output = @(& git -C $RepoPath symbolic-ref HEAD $baselineHeadRef 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "Git could not restore the Reviewer symbolic HEAD: $($output -join ' ')"
        }
    }
    else {
        $output = @(& git -C $RepoPath checkout --detach --force $baselineHead 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "Git could not restore the detached Reviewer HEAD: $($output -join ' ')"
        }
    }

    $output = @(& git -C $RepoPath reset --hard $baselineHead 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Git could not restore Reviewer tracked or staged changes: $($output -join ' ')"
    }
    $output = @(& git -C $RepoPath clean -ffd 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Git could not remove Reviewer untracked paths: $($output -join ' ')"
    }

    $restored = Get-ReviewLoopRepositorySnapshot -RepoPath $RepoPath
    if ([string]$restored.Head -ne $baselineHead -or
        [string]$restored.HeadRef -ne $baselineHeadRef -or
        [string]$restored.Fingerprint -ne $baselineFingerprint) {
        throw "Reviewer cleanup did not restore the exact repository checkpoint."
    }
}

function Invoke-ReviewLoopReviewerRepositoryRecovery {
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][object]$Recovery,
        [AllowNull()][object]$State = $null
    )

    try {
        Restore-ReviewLoopReviewerRepository `
            -RepoPath $RepoPath -Recovery $Recovery -State $State
    }
    catch {
        throw (New-ReviewLoopFailureException `
            -Message "Automatic Reviewer cleanup could not restore the saved repository checkpoint: $($_.Exception.Message)" `
            -NextSteps @(
                "Inspect the repository and Reviewer logs without editing the checkpoint or recovery locator."
                "Correct the reported Git or filesystem problem, then run the same command again."
                "If recovery remains impossible, preserve the run directory before restoring the repository manually."
            ))
    }
}

function Complete-ReviewLoopInterruptedReviewerRecovery {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][string]$RepoPath
    )

    $active = Get-ReviewLoopObjectProperty -Object $State -Name "ActiveRoleCall"
    if ($null -eq $active -or [string]$active.Role -ne "Reviewer") {
        return $false
    }
    Invoke-ReviewLoopReviewerRepositoryRecovery `
        -RepoPath $RepoPath -Recovery $active -State $State
    $checkpointStage = [string](Get-ReviewLoopObjectProperty `
        -Object $active -Name "CheckpointStage" -Default "reviewing")
    if ([string]$State.Stage -eq "stopped") {
        $State.Stage = $checkpointStage
    }
    $State.ActiveRoleCall = $null
    Write-ReviewLoopState -Path $StatePath -State $State | Out-Null
    Clear-ReviewLoopReviewerRecoveryLocator -RepoPath $RepoPath
    return $true
}

function Assert-ReviewLoopRepositoryUnchanged {
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][object]$Snapshot,
        [Parameter(Mandatory = $true)][string]$Operation
    )

    $current = Get-ReviewLoopRepositorySnapshot -RepoPath $RepoPath
    if ([string]$current.Head -ne [string]$Snapshot.Head -or
        [string]$current.Fingerprint -ne [string]$Snapshot.Fingerprint) {
        Stop-ReviewLoopBlocked -Message "$Operation changed repository state; refusing to continue or commit it."
    }
}

function Invoke-ReviewLoopHostGate {
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][hashtable]$Gate,
        [Parameter(Mandatory = $true)][string]$RunRoot,
        [Parameter(Mandatory = $true)][string]$ClusterId,
        [Alias("TimeoutSeconds")][long]$InactivityTimeoutSeconds = 1800,
        [long]$AbsoluteTimeoutSeconds = 0
    )

    $name = [string]$Gate.Name
    $filePath = [string]$Gate.FilePath
    $arguments = @($Gate.Arguments | ForEach-Object { [string]$_ })
    $safeName = [regex]::Replace($name.ToLowerInvariant(), "[^a-z0-9-]+", "-").Trim("-")
    $logPath = Join-Path $RunRoot "$ClusterId-gate-$safeName.txt"

    Write-ReviewLoopStatus -Message "Host-Gate: $name" -Kind Progress
    $executable = Resolve-ReviewLoopHostExecutable -RepoPath $RepoPath -FilePath $filePath
    $startInfo = New-CodexProcessStartInfo -CodexExecutable $executable -Arguments $arguments
    $startInfo.WorkingDirectory = $RepoPath
    $stderrPath = "$logPath.stderr.txt"
    try {
        $observed = Invoke-ReviewLoopObservedProcess `
            -StartInfo $startInfo `
            -DisplayName "Host-Gate $name" `
            -StdoutPath $logPath `
            -StderrPath $stderrPath `
            -EventKind HostGate `
            -InactivityTimeoutSeconds $InactivityTimeoutSeconds `
            -AbsoluteTimeoutSeconds $AbsoluteTimeoutSeconds
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
        Output = $text
    }
}

function Invoke-ReviewLoopHostGates {
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$HostGates,
        [Parameter(Mandatory = $true)][string]$RunRoot,
        [Parameter(Mandatory = $true)][string]$ClusterId,
        [long]$InactivityTimeoutSeconds = 1800,
        [AllowNull()][hashtable]$Config = $null
    )

    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($gate in $HostGates) {
        if ($null -ne $Config) {
            Update-ReviewLoopLiveConfig -Config $Config
            Assert-ReviewLoopExecutionUnchanged -Config $Config
            $InactivityTimeoutSeconds =
                Get-ReviewLoopInactivityTimeoutSeconds -Config $Config
        }
        $snapshot = Get-ReviewLoopRepositorySnapshot -RepoPath $RepoPath
        $result = Invoke-ReviewLoopHostGate `
            -RepoPath $RepoPath -Gate $gate -RunRoot $RunRoot -ClusterId $ClusterId `
            -InactivityTimeoutSeconds $InactivityTimeoutSeconds
        Assert-ReviewLoopRepositoryUnchanged `
            -RepoPath $RepoPath -Snapshot $snapshot -Operation "Host gate '$($gate.Name)'"
        [void]$results.Add($result)
        if (-not $result.Success) {
            return [pscustomobject]@{ Success = $false; Results = $results.ToArray(); Failure = $result }
        }
    }
    return [pscustomobject]@{ Success = $true; Results = $results.ToArray(); Failure = $null }
}

function Invoke-ReviewLoopTargetedTests {
    param(
        [Parameter(Mandatory = $true)][object]$FixerResult,
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$RunRoot,
        [Parameter(Mandatory = $true)][string]$ClusterId,
        [Parameter(Mandatory = $true)][int]$Attempt,
        [long]$InactivityTimeoutSeconds = 1800
    )

    $test = $FixerResult.targetedTest
    $available = if ($null -ne $test -and
        $test.PSObject.Properties.Name -contains "available") {
        [bool]$test.available
    }
    else {
        $null -ne $test -and -not [string]::IsNullOrWhiteSpace([string]$test.executable)
    }
    if ($null -ne $test -and -not $available) {
        $FixerResult | Add-Member -Force -NotePropertyName testExecution -NotePropertyValue ([pscustomobject]@{
            Available = $false
            FilePath = ""
            Arguments = @()
            Passed = $true
            ExitCode = 0
            Evidence = "The fixer did not provide a targeted test."
            LogPath = ""
        })
        return [pscustomobject]@{
            Success = $true
            Correctable = $false
            Feedback = ""
            Results = @()
        }
    }
    if ($null -eq $test -or
        [string]::IsNullOrWhiteSpace([string]$test.executable) -or
        $test.arguments -is [string]) {
        return [pscustomobject]@{
            Success = $false
            Correctable = $true
            Feedback = "The available targeted test has no executable or argument list."
            Results = @()
        }
    }

    $arguments = @($test.arguments | ForEach-Object { [string]$_ })
    try {
        Resolve-ReviewLoopHostExecutable -RepoPath $RepoPath -FilePath ([string]$test.executable) | Out-Null
    }
    catch {
        return [pscustomobject]@{
            Success = $false
            Correctable = $true
            Feedback = "The targeted test executable '$($test.executable)' could not be resolved: $($_.Exception.Message)"
            Results = @()
        }
    }

    $gate = @{
        Name = "Targeted regression test"
        FilePath = [string]$test.executable
        Arguments = $arguments
    }
    $result = Invoke-ReviewLoopHostGate `
        -RepoPath $RepoPath `
        -Gate $gate `
        -RunRoot $RunRoot `
        -ClusterId "$ClusterId-fix-$Attempt" `
        -InactivityTimeoutSeconds $InactivityTimeoutSeconds
    $FixerResult | Add-Member -Force -NotePropertyName testExecution -NotePropertyValue ([pscustomobject]@{
        FilePath = [string]$result.FilePath
        Arguments = @($result.Arguments)
        Passed = [bool]$result.Success
        ExitCode = [int]$result.ExitCode
        Evidence = "Executed independently by the orchestrator. Log: $($result.LogPath)"
        LogPath = [string]$result.LogPath
    })
    return [pscustomobject]@{
        Success = [bool]$result.Success
        Correctable = [int]$result.ExitCode -eq -1
        Feedback = if ($result.Success) { "" } else {
            $excerpt = @(Get-ReviewLoopTextExcerpt -Text $result.Output -MaxLines 6) -join " "
            "Targeted regression test failed: $($test.executable) $($arguments -join ' '). Exit code $($result.ExitCode). $excerpt"
        }
        Results = @($result)
    }
}

function Get-ReviewLoopChangedPaths {
    param([Parameter(Mandatory = $true)][string]$RepoPath)

    $tracked = @(& git -C $RepoPath diff --name-only HEAD -- 2>$null)
    if ($LASTEXITCODE -ne 0) {
        throw "git diff --name-only failed."
    }
    $staged = @(& git -C $RepoPath diff --cached --name-only HEAD -- 2>$null)
    if ($LASTEXITCODE -ne 0) {
        throw "git diff --cached --name-only failed."
    }
    $unstaged = @(& git -C $RepoPath diff --name-only -- 2>$null)
    if ($LASTEXITCODE -ne 0) {
        throw "git diff --name-only for unstaged changes failed."
    }
    $untracked = @(& git -C $RepoPath ls-files --others --exclude-standard 2>$null)
    if ($LASTEXITCODE -ne 0) {
        throw "git ls-files --others failed."
    }
    return @(
        (@($tracked) + @($staged) + @($unstaged) + @($untracked)) |
            ForEach-Object { ([string]$_).Trim().Replace("\", "/") } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )
}

function Resolve-ReviewLoopRepositoryRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    if ([System.IO.Path]::IsPathRooted($RelativePath)) {
        throw "Repository change path must be relative: $RelativePath"
    }
    $root = [System.IO.Path]::GetFullPath($RepoPath).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar)
    $full = [System.IO.Path]::GetFullPath((Join-Path $root $RelativePath))
    $prefix = $root + [System.IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Repository change path escapes the repository: $RelativePath"
    }
    return $full
}

function Assert-ReviewLoopPathWithoutReparsePoints {
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $absolute = Resolve-ReviewLoopRepositoryRelativePath `
        -RepoPath $RootPath `
        -RelativePath $RelativePath
    $current = [System.IO.Path]::GetFullPath($RootPath)
    foreach ($segment in @($RelativePath -split '[\\/]')) {
        if ([string]::IsNullOrWhiteSpace($segment)) {
            continue
        }
        $current = Join-Path $current $segment
        if (-not (Test-Path -LiteralPath $current)) {
            continue
        }
        $item = Get-Item -LiteralPath $current -Force
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Description contains a reparse point: $RelativePath"
        }
    }
    return $absolute
}

function Get-ReviewLoopTrackedPathPatchHash {
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$Head,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $lines = @(& git -C $RepoPath diff --binary --full-index $Head -- $Path 2>$null)
    if ($LASTEXITCODE -ne 0) {
        throw "Git could not capture the blocked patch for '$Path'."
    }
    return Get-ReviewLoopSha256 ($lines -join [Environment]::NewLine)
}

function Test-ReviewLoopGitDiffPresent {
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    & git -C $RepoPath diff --quiet @Arguments 2>$null
    if ($LASTEXITCODE -eq 0) {
        return $false
    }
    if ($LASTEXITCODE -eq 1) {
        return $true
    }
    throw "Git could not compare the blocked fixer path."
}

function Write-ReviewLoopGitBinaryPatch {
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$Head,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = "git"
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @(
        "-C", $RepoPath, "diff", "--binary", "--full-index",
        "--no-ext-diff", "--no-textconv", $Head, "--"
    )) {
        [void]$startInfo.ArgumentList.Add([string]$argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $stream = $null
    $started = $false
    try {
        if (-not $process.Start()) {
            throw "Git could not start while creating the blocked fixer patch."
        }
        $started = $true
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $stream = [System.IO.File]::Create($Path)
        $process.StandardOutput.BaseStream.CopyTo($stream)
        $stream.Flush($true)
        $stream.Dispose()
        $stream = $null
        $process.WaitForExit()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            $detail = (ConvertTo-ReviewLoopRedactedText $stderr).Trim()
            throw "Git could not create the blocked fixer patch$(if ($detail) { ": $detail" })."
        }
    }
    finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
        if ($started -and -not $process.HasExited) {
            try {
                $process.Kill($true)
                [void]$process.WaitForExit(5000)
            }
            catch {
                # Preserve the original artifact error.
            }
        }
        $process.Dispose()
    }
}

function Get-ReviewLoopBlockedArtifact {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$RunRoot,
        [Parameter(Mandatory = $true)][string]$ClusterId,
        [Parameter(Mandatory = $true)][int]$Attempt
    )

    $snapshot = Get-ReviewLoopRepositorySnapshot -RepoPath $RepoPath
    if ([string]$snapshot.Head -ne [string]$State.CurrentHead) {
        throw "HEAD changed before the blocked fixer patch could be preserved."
    }
    $expectedFingerprint = [string](Get-ReviewLoopObjectProperty `
        -Object $State.LastFixerResult -Name "WorktreeFingerprint" -Default "")
    if ([string]::IsNullOrWhiteSpace($expectedFingerprint) -or
        [string]$snapshot.Fingerprint -ne $expectedFingerprint) {
        throw "The worktree no longer matches the final recorded fixer result; automatic cleanup is unsafe."
    }

    $changedPaths = @(Get-ReviewLoopChangedPaths -RepoPath $RepoPath)
    if ($changedPaths.Count -eq 0) {
        return $null
    }
    $artifactParent = Join-Path $RunRoot "blocked"
    $artifactRoot = Join-Path $artifactParent "$ClusterId-attempt-$Attempt"
    $manifestPath = Join-Path $artifactRoot "manifest.json"
    if (Test-Path -LiteralPath $manifestPath) {
        $existing = Read-ReviewLoopJson -Path $manifestPath
        if ([string]$existing.Head -ne [string]$snapshot.Head -or
            [string]$existing.WorktreeFingerprint -ne [string]$snapshot.Fingerprint) {
            throw "An existing blocked-patch artifact does not match the current fixer result: $artifactRoot"
        }
        return [pscustomobject]@{
            ArtifactRoot = $artifactRoot
            ManifestPath = $manifestPath
            Head = [string]$existing.Head
            WorktreeFingerprint = [string]$existing.WorktreeFingerprint
            ChangedPaths = @($existing.ChangedPaths)
            ClusterId = $ClusterId
            FindingIds = @($State.ActiveFindingIds)
            Attempt = $Attempt
        }
    }

    [System.IO.Directory]::CreateDirectory($artifactParent) | Out-Null
    $temporaryRoot = Join-Path $artifactParent (
        ".$ClusterId-attempt-$Attempt.$([Guid]::NewGuid().ToString('N')).tmp")
    [System.IO.Directory]::CreateDirectory($temporaryRoot) | Out-Null
    try {
        $trackedEntries = [System.Collections.Generic.List[object]]::new()
        $untrackedEntries = [System.Collections.Generic.List[object]]::new()
        foreach ($path in $changedPaths) {
            $absolute = Assert-ReviewLoopPathWithoutReparsePoints `
                -RootPath $RepoPath `
                -RelativePath $path `
                -Description "Automatic blocked-patch cleanup"

            $stage = @(& git -C $RepoPath ls-files --stage -- $path 2>$null)
            if ($LASTEXITCODE -ne 0) {
                throw "Git could not classify blocked-patch path '$path'."
            }
            $headEntry = @(& git -C $RepoPath ls-tree ([string]$snapshot.Head) -- $path 2>$null)
            if ($LASTEXITCODE -ne 0) {
                throw "Git could not inspect the saved HEAD entry for '$path'."
            }
            $trackedGitEntries = @($stage) + @($headEntry)
            if ($trackedGitEntries.Count -gt 0) {
                if (@($trackedGitEntries -match '^\s*160000(?:\s|$)').Count -gt 0) {
                    throw "Automatic blocked-patch cleanup does not support submodule changes: $path"
                }
                $finalDiff = Test-ReviewLoopGitDiffPresent `
                    -RepoPath $RepoPath `
                    -Arguments @(([string]$snapshot.Head), "--", $path)
                $indexDiff = Test-ReviewLoopGitDiffPresent `
                    -RepoPath $RepoPath `
                    -Arguments @("--cached", ([string]$snapshot.Head), "--", $path)
                $unstagedDiff = Test-ReviewLoopGitDiffPresent `
                    -RepoPath $RepoPath `
                    -Arguments @("--", $path)
                if (-not $finalDiff -and ($indexDiff -or $unstagedDiff)) {
                    throw "The staged and unstaged changes for '$path' cancel each other. Automatic blocked-patch cleanup cannot preserve that split state safely."
                }
                [void]$trackedEntries.Add([pscustomobject][ordered]@{
                    Path = $path
                    FileType = if (Test-Path -LiteralPath $absolute -PathType Leaf) {
                        "tracked_file"
                    }
                    else {
                        "tracked_deletion"
                    }
                    PatchHash = Get-ReviewLoopTrackedPathPatchHash `
                        -RepoPath $RepoPath -Head ([string]$snapshot.Head) -Path $path
                })
                continue
            }

            if (-not (Test-Path -LiteralPath $absolute -PathType Leaf)) {
                throw "Untracked blocked-patch path is not a regular file: $path"
            }
            $destination = Join-Path (Join-Path $temporaryRoot "untracked") $path
            [System.IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
            [System.IO.File]::Copy($absolute, $destination, $false)
            $sourceHash = (Get-FileHash -LiteralPath $absolute -Algorithm SHA256).Hash.ToLowerInvariant()
            $copyHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($sourceHash -ne $copyHash) {
                throw "Untracked blocked-patch file could not be copied reliably: $path"
            }
            [void]$untrackedEntries.Add([pscustomobject][ordered]@{
                Path = $path
                FileType = "untracked_file"
                Sha256 = $sourceHash
                Length = [int64](Get-Item -LiteralPath $absolute).Length
            })
        }

        $patchPath = Join-Path $temporaryRoot "tracked.patch"
        Write-ReviewLoopGitBinaryPatch `
            -RepoPath $RepoPath `
            -Head ([string]$snapshot.Head) `
            -Path $patchPath
        $manifest = [pscustomobject][ordered]@{
            SchemaVersion = "1.0"
            ClusterId = $ClusterId
            Attempt = $Attempt
            Head = [string]$snapshot.Head
            WorktreeFingerprint = [string]$snapshot.Fingerprint
            ChangedPaths = @($changedPaths)
            Tracked = @($trackedEntries)
            Untracked = @($untrackedEntries)
            PatchFile = "tracked.patch"
            PatchSha256 = (Get-FileHash -LiteralPath $patchPath -Algorithm SHA256).Hash.ToLowerInvariant()
            CreatedAt = [DateTimeOffset]::UtcNow.ToString("O")
        }
        Write-ReviewLoopAtomicJson `
            -Path (Join-Path $temporaryRoot "manifest.json") `
            -Value $manifest
        Move-Item -LiteralPath $temporaryRoot -Destination $artifactRoot
    }
    finally {
        if (Test-Path -LiteralPath $temporaryRoot) {
            $resolvedTemporary = [System.IO.Path]::GetFullPath($temporaryRoot)
            $resolvedParent = [System.IO.Path]::GetFullPath($artifactParent)
            if ($resolvedTemporary.StartsWith(
                $resolvedParent + [System.IO.Path]::DirectorySeparatorChar,
                [StringComparison]::OrdinalIgnoreCase)) {
                Remove-Item -LiteralPath $resolvedTemporary -Recurse -Force
            }
        }
    }

    return [pscustomobject]@{
        ArtifactRoot = $artifactRoot
        ManifestPath = Join-Path $artifactRoot "manifest.json"
        Head = [string]$snapshot.Head
        WorktreeFingerprint = [string]$snapshot.Fingerprint
        ChangedPaths = @($changedPaths)
        ClusterId = $ClusterId
        FindingIds = @($State.ActiveFindingIds)
        Attempt = $Attempt
    }
}

function Restore-ReviewLoopBlockedWorktree {
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][object]$Cleanup
    )

    $manifest = Read-ReviewLoopJson -Path ([string]$Cleanup.ManifestPath)
    $head = Get-ReviewLoopGitValue -RepoPath $RepoPath -Arguments @("rev-parse", "HEAD")
    if ($head -ne [string]$manifest.Head) {
        throw "HEAD changed after the blocked fixer patch was preserved; automatic cleanup was not attempted."
    }

    $artifactRoot = Split-Path -Parent ([string]$Cleanup.ManifestPath)
    $patchPath = Assert-ReviewLoopPathWithoutReparsePoints `
        -RootPath $artifactRoot `
        -RelativePath ([string]$manifest.PatchFile) `
        -Description "The preserved blocked fixer artifact"
    if (-not (Test-Path -LiteralPath $patchPath -PathType Leaf)) {
        throw "The preserved blocked fixer patch is missing; automatic cleanup was not attempted."
    }
    $patchHash = (Get-FileHash -LiteralPath $patchPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($patchHash -ne [string]$manifest.PatchSha256) {
        throw "The preserved blocked fixer patch failed its integrity check; automatic cleanup was not attempted."
    }

    $trackedByPath = @{}
    foreach ($entry in @($manifest.Tracked)) {
        $trackedByPath[[string]$entry.Path] = $entry
    }
    $untrackedByPath = @{}
    $artifactUntrackedRoot = Join-Path $artifactRoot "untracked"
    foreach ($entry in @($manifest.Untracked)) {
        $path = [string]$entry.Path
        $untrackedByPath[$path] = $entry
        $savedPath = Assert-ReviewLoopPathWithoutReparsePoints `
            -RootPath $artifactUntrackedRoot `
            -RelativePath $path `
            -Description "The preserved blocked fixer artifact"
        if (-not (Test-Path -LiteralPath $savedPath -PathType Leaf)) {
            throw "A preserved untracked fixer file is missing: $path"
        }
        $savedItem = Get-Item -LiteralPath $savedPath -Force
        if (($savedItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "A preserved untracked fixer file became a reparse point: $path"
        }
        $savedHash = (Get-FileHash -LiteralPath $savedPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($savedHash -ne [string]$entry.Sha256) {
            throw "A preserved untracked fixer file failed its integrity check: $path"
        }
        $currentPath = Assert-ReviewLoopPathWithoutReparsePoints `
            -RootPath $RepoPath `
            -RelativePath $path `
            -Description "The current blocked fixer worktree"
        if (Test-Path -LiteralPath $currentPath) {
            if (-not (Test-Path -LiteralPath $currentPath -PathType Leaf)) {
                throw "Untracked blocked-patch file is no longer a regular file: $path"
            }
            $currentItem = Get-Item -LiteralPath $currentPath -Force
            if (($currentItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Untracked blocked-patch file became a reparse point: $path"
            }
            $currentHash = (Get-FileHash -LiteralPath $currentPath -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($currentHash -ne [string]$entry.Sha256) {
                throw "Untracked path changed after the blocked patch was captured: $path"
            }
        }
    }

    $currentPaths = @(Get-ReviewLoopChangedPaths -RepoPath $RepoPath)
    if ($currentPaths.Count -eq 0) {
        return
    }

    $allowed = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($manifestPath in @($manifest.ChangedPaths)) {
        $null = $allowed.Add([string]$manifestPath)
    }
    foreach ($path in $currentPaths) {
        if (-not $allowed.Contains([string]$path)) {
            throw "Unexpected path appeared during blocked-patch cleanup: $path"
        }
    }

    foreach ($path in $currentPaths) {
        if ($trackedByPath.ContainsKey($path)) {
            $actualHash = Get-ReviewLoopTrackedPathPatchHash `
                -RepoPath $RepoPath -Head $head -Path $path
            if ($actualHash -ne [string]$trackedByPath[$path].PatchHash) {
                throw "Tracked path changed after the blocked patch was captured: $path"
            }
            continue
        }
        if (-not $untrackedByPath.ContainsKey($path)) {
            throw "Path changed classification during blocked-patch cleanup: $path"
        }
    }

    $trackedPaths = @($manifest.Tracked | ForEach-Object { [string]$_.Path })
    if ($trackedPaths.Count -gt 0) {
        $output = @(& git -C $RepoPath restore "--source=$head" --staged --worktree -- @trackedPaths 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "Git could not restore the tracked blocked-patch paths: $($output -join ' ')"
        }
    }
    foreach ($entry in @($manifest.Untracked)) {
        $absolute = Resolve-ReviewLoopRepositoryRelativePath `
            -RepoPath $RepoPath -RelativePath ([string]$entry.Path)
        if (Test-Path -LiteralPath $absolute) {
            Remove-Item -LiteralPath $absolute -Force
        }
    }
    if (-not (Test-ReviewLoopGitClean -RepoPath $RepoPath)) {
        throw "The blocked fixer patch was preserved, but the worktree could not be restored completely."
    }
}

function Complete-ReviewLoopBlockedCluster {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][object]$Ledger,
        [Parameter(Mandatory = $true)][string]$LedgerPath,
        [Parameter(Mandatory = $true)][object[]]$Findings,
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$RunRoot,
        [Parameter(Mandatory = $true)][int]$Attempt,
        [Parameter(Mandatory = $true)][string]$Reason
    )

    $cleanup = Get-ReviewLoopObjectProperty -Object $State -Name "BlockedCleanup"
    try {
        if ($null -eq $cleanup) {
            $cleanup = Get-ReviewLoopBlockedArtifact `
                -State $State `
                -RepoPath $RepoPath `
                -RunRoot $RunRoot `
                -ClusterId ([string]$State.ActiveClusterId) `
                -Attempt $Attempt
            if ($null -ne $cleanup) {
                $cleanup | Add-Member -Force -NotePropertyName Reason -NotePropertyValue $Reason
                $cleanup | Add-Member -Force -NotePropertyName FindingIds `
                    -NotePropertyValue @($Findings | ForEach-Object { [string]$_.Id })
                $State | Add-Member -Force -NotePropertyName BlockedCleanup -NotePropertyValue $cleanup
                Set-ReviewLoopCheckpoint `
                    -State $State `
                    -StatePath $StatePath `
                    -Stage "blocked_patch_captured"
            }
        }
        if ($null -ne $cleanup) {
            Restore-ReviewLoopBlockedWorktree -RepoPath $RepoPath -Cleanup $cleanup
        }
    }
    catch {
        throw (New-ReviewLoopFailureException `
            -Message "Automatic cleanup of the blocked fixer patch stopped safely: $($_.Exception.Message) No further cleanup will be attempted until this is resolved." `
            -NextSteps @(
                "Leave the current worktree unchanged, repair the reported artifact or concurrent-change mismatch, then run the same command again to resume cleanup."
                "If safe resume is no longer possible, preserve the current changes manually, make the worktree clean, and start with -NewRun."
            ))
    }

    Set-ReviewLoopFindingsStatus -Findings $Findings -Status "blocked" -Reason $Reason
    foreach ($finding in $Findings) {
        $finding.LastBlockedHead = [string]$State.CurrentHead
        if ($null -ne $cleanup) {
            $finding | Add-Member -Force -NotePropertyName BlockedArtifactRoot `
                -NotePropertyValue ([string]$cleanup.ArtifactRoot)
        }
    }
    Write-ReviewLoopLedger -Path $LedgerPath -Ledger $Ledger | Out-Null
    if ($State.PSObject.Properties.Name -contains "BlockedCleanup") {
        $State.BlockedCleanup = $null
    }
    if ($null -ne $cleanup) {
        Write-ReviewLoopStatus `
            -Message "$Reason Unverified work was preserved at '$($cleanup.ArtifactRoot)' and the clean worktree was restored. Independent clusters will continue." `
            -Kind Warning
    }
    else {
        Write-ReviewLoopStatus -Message "$Reason Independent clusters will continue." -Kind Warning
    }
    Clear-ReviewLoopActiveCluster -State $State -StatePath $StatePath -Stage "cluster_blocked"
    return $false
}

function Resume-ReviewLoopBlockedCleanup {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][object]$Ledger,
        [Parameter(Mandatory = $true)][string]$LedgerPath,
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$RunRoot
    )

    if ([string]$State.Stage -ne "blocked_patch_captured") {
        return $false
    }
    $cleanup = Get-ReviewLoopObjectProperty -Object $State -Name "BlockedCleanup"
    if ($null -eq $cleanup) {
        throw "Blocked-patch cleanup checkpoint is missing its cleanup record."
    }
    $ids = @($cleanup.FindingIds | ForEach-Object { [string]$_ })
    $findings = @($Ledger.Findings | Where-Object { [string]$_.Id -in $ids })
    if ($findings.Count -ne $ids.Count -or $findings.Count -eq 0) {
        throw "Blocked-patch cleanup cannot resume because its findings are missing from the ledger."
    }
    Write-ReviewLoopStatus `
        -Message "Resuming cleanup of preserved blocked fixer work." `
        -Kind Progress
    Complete-ReviewLoopBlockedCluster `
        -State $State `
        -StatePath $StatePath `
        -Ledger $Ledger `
        -LedgerPath $LedgerPath `
        -Findings $findings `
        -RepoPath $RepoPath `
        -RunRoot $RunRoot `
        -Attempt ([int]$cleanup.Attempt) `
        -Reason ([string]$cleanup.Reason) | Out-Null
    return $true
}

function Update-ReviewLoopFixerResultFromWorktree {
    param(
        [Parameter(Mandatory = $true)][object]$FixerResult,
        [Parameter(Mandatory = $true)][string]$RepoPath
    )

    return @(Get-ReviewLoopChangedPaths -RepoPath $RepoPath)
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

function Clear-ReviewLoopActiveCluster {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][string]$Stage
    )

    $State.CleanPasses = 0
    $State.CleanHead = ""
    $State.ActiveClusterId = ""
    $State.ActiveFindingIds = @()
    $State.ActiveFindingSource = ""
    $State.ActiveReviewText = ""
    $State.ActiveStrategy = $null
    $State.LastFixerResult = $null
    if ($State.PSObject.Properties.Name -contains "PartialFixRecovery") {
        $State.PartialFixRecovery = $null
    }
    else {
        $State | Add-Member -NotePropertyName PartialFixRecovery -NotePropertyValue $null
    }
    if ($State.PSObject.Properties.Name -contains "PendingCommit") {
        $State.PendingCommit = $null
    }
    else {
        $State | Add-Member -NotePropertyName PendingCommit -NotePropertyValue $null
    }
    Set-ReviewLoopCheckpoint -State $State -StatePath $StatePath -Stage $Stage
}

function Complete-ReviewLoopResolution {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][object]$Ledger,
        [Parameter(Mandatory = $true)][string]$LedgerPath,
        [Parameter(Mandatory = $true)][object[]]$Findings,
        [Parameter(Mandatory = $true)][object]$VerificationResult,
        [Parameter(Mandatory = $true)][string]$Commit
    )

    $createdCommit = [string]$State.CurrentHead -ne $Commit
    $isLessonsLearned = [string](Get-ReviewLoopObjectProperty `
        -Object $State -Name "ActiveFindingSource" -Default "") -eq "lessons_learned"
    foreach ($finding in $Findings) {
        $finding.Status = "resolved"
        $finding.Verification = $VerificationResult
        $finding.ResolutionCommit = $Commit
        $finding.FixerThreadId = ""
        $finding.UpdatedAt = [DateTimeOffset]::UtcNow.ToString("O")
    }
    Write-ReviewLoopLedger -Path $LedgerPath -Ledger $Ledger | Out-Null
    if ($createdCommit) {
        Add-ReviewLoopVerifiedCommit -State $State -Commit $Commit
    }
    $State.CurrentHead = $Commit
    if ($isLessonsLearned) {
        $State.LessonsLearned.Status = "completed"
        $State.LessonsLearned.CompletedHead = $Commit
    }
    Clear-ReviewLoopActiveCluster -State $State -StatePath $StatePath -Stage "fix_committed"
    Write-ReviewLoopStatus -Message "Verified finding(s) resolved; clean-pass count reset to 0." -Kind Success
}

function Invoke-ReviewLoopGitStep {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$RunRoot,
        [Parameter(Mandatory = $true)][string]$ClusterId
    )

    $result = Invoke-ReviewLoopHostGate -RepoPath $RepoPath -Gate @{
        Name = $Name
        FilePath = "git"
        Arguments = $Arguments
    } -RunRoot $RunRoot -ClusterId $ClusterId `
        -InactivityTimeoutSeconds 0 -AbsoluteTimeoutSeconds 300
    if (-not $result.Success) {
        $excerpt = @(Get-ReviewLoopTextExcerpt -Text $result.Output -MaxLines 6) -join " "
        throw "$Name failed with exit code $($result.ExitCode): $excerpt"
    }
    return $result
}

function Assert-ReviewLoopVerifiedWorktreeIsFullyStaged {
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$PreHead,
        [Parameter(Mandatory = $true)][string]$PatchFingerprint,
        [Parameter(Mandatory = $true)][string]$StagedTree
    )

    & git -C $RepoPath diff --quiet --ignore-submodules=none -- 2>$null
    if ($LASTEXITCODE -gt 1) {
        throw "Git could not verify whether the worktree is fully staged."
    }
    if ($LASTEXITCODE -eq 1) {
        Stop-ReviewLoopBlocked -Message "The verified worktree contains changes that Git cannot stage completely, such as a dirty submodule."
    }
    $untrackedText = Get-ReviewLoopGitValue -RepoPath $RepoPath -Arguments @(
        "ls-files", "--others", "--exclude-standard"
    )
    $untracked = @(([string]$untrackedText) -split "\r?\n" | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    })
    if ($untracked.Count -gt 0) {
        Stop-ReviewLoopBlocked -Message "The verified worktree still contains untracked paths after staging: $($untracked -join ', ')."
    }
    $headTree = Get-ReviewLoopGitValue -RepoPath $RepoPath -Arguments @(
        "rev-parse", "$PreHead^{tree}"
    )
    if ($PatchFingerprint -ne (Get-ReviewLoopSha256 "") -and
        $StagedTree -eq $headTree) {
        Stop-ReviewLoopBlocked -Message "The verified patch produced no staged tree change; refusing an empty or partial commit."
    }
}

function ConvertTo-ReviewLoopCommitLine {
    param(
        [AllowNull()][string]$Text,
        [ValidateRange(1, 4000)][int]$MaxLength
    )

    $line = ConvertTo-ReviewLoopRedactedText ([string]$Text)
    $line = [regex]::Replace($line, "[\u0000-\u001f\u007f]+", " ")
    $line = [regex]::Replace($line, "\s+", " ").Trim()
    if ($line.Length -gt $MaxLength) {
        $line = $line.Substring(0, $MaxLength).TrimEnd()
    }
    return $line
}

function Get-ReviewLoopCanonicalCommitMessage {
    param([AllowNull()][string]$Message)

    return ([string]$Message).
        Replace("`r`n", "`n").
        Replace("`r", "`n").
        Trim()
}

function Get-ReviewLoopPendingCommitCheck {
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][object]$Pending
    )

    $head = Get-ReviewLoopGitValue -RepoPath $RepoPath -Arguments @(
        "rev-parse", "HEAD"
    )
    $parent = Get-ReviewLoopGitValue -RepoPath $RepoPath -Arguments @(
        "rev-parse", "HEAD^"
    )
    $tree = Get-ReviewLoopGitValue -RepoPath $RepoPath -Arguments @(
        "rev-parse", "HEAD^{tree}"
    )
    $subject = Get-ReviewLoopGitValue -RepoPath $RepoPath -Arguments @(
        "show", "-s", "--format=%s", "HEAD"
    )
    $message = Get-ReviewLoopGitValue -RepoPath $RepoPath -Arguments @(
        "show", "-s", "--format=%B", "HEAD"
    )
    $status = Get-ReviewLoopGitValue -RepoPath $RepoPath -Arguments @(
        "status", "--porcelain=v1", "--untracked-files=all"
    )

    $expectedParent = [string]$Pending.PreHead
    $expectedTree = [string]$Pending.ExpectedTree
    $expectedCommit = [string](Get-ReviewLoopObjectProperty `
        -Object $Pending -Name "ExpectedCommit" -Default "")
    $commitMatches = [string]::IsNullOrWhiteSpace($expectedCommit) -or
        $head -eq $expectedCommit
    $parentMatches = $parent -eq $expectedParent
    $treeMatches = $tree -eq $expectedTree
    $actualMessage = Get-ReviewLoopCanonicalCommitMessage -Message $message
    $expectedMessage = Get-ReviewLoopCanonicalCommitMessage `
        -Message ([string]$Pending.Message)
    $messageMatches = $actualMessage -eq $expectedMessage
    $messageMatchRequired = [string]::IsNullOrWhiteSpace($expectedCommit)
    $worktreeClean = [string]::IsNullOrWhiteSpace($status)
    $mismatches = [System.Collections.Generic.List[string]]::new()
    if (-not $commitMatches) {
        [void]$mismatches.Add("commit expected $expectedCommit but HEAD is $head")
    }
    if (-not $parentMatches) {
        [void]$mismatches.Add("parent expected $expectedParent but found $parent")
    }
    if (-not $treeMatches) {
        [void]$mismatches.Add("tree expected $expectedTree but found $tree")
    }
    if ($messageMatchRequired -and -not $messageMatches) {
        $expectedMessageHash = Get-ReviewLoopSha256 $expectedMessage
        $actualMessageHash = Get-ReviewLoopSha256 $actualMessage
        [void]$mismatches.Add(
            "commit message differs from the sealed message: expected sha256 $expectedMessageHash length $($expectedMessage.Length), actual sha256 $actualMessageHash length $($actualMessage.Length)")
    }
    if (-not $worktreeClean) {
        $statusExcerpt = @(Get-ReviewLoopTextExcerpt -Text $status -MaxLines 8) -join " | "
        [void]$mismatches.Add("worktree or index is not clean: $statusExcerpt")
    }

    return [pscustomobject]@{
        Matches = $mismatches.Count -eq 0
        CommitMatches = $commitMatches
        ParentMatches = $parentMatches
        TreeMatches = $treeMatches
        MessageMatches = $messageMatches
        MessageMatchRequired = $messageMatchRequired
        WorktreeClean = $worktreeClean
        Subject = $subject
        Status = $status
        Mismatches = @($mismatches)
    }
}

function New-ReviewLoopCommitMessage {
    param(
        [Parameter(Mandatory = $true)][string]$Prefix,
        [Parameter(Mandatory = $true)][object[]]$Findings,
        [AllowNull()][object]$FixerResult,
        [AllowNull()][object]$VerificationResult,
        [AllowEmptyCollection()][object[]]$GateResults = @()
    )

    $proposal = Get-ReviewLoopObjectProperty `
        -Object $VerificationResult -Name "commitMessage"
    $proposedSubject = [string](Get-ReviewLoopObjectProperty `
        -Object $proposal -Name "subject" -Default "")
    $subject = ConvertTo-ReviewLoopCommitLine -Text $proposedSubject -MaxLength 120
    if ([string]::IsNullOrWhiteSpace($subject)) {
        $fixerSummary = [string](Get-ReviewLoopObjectProperty `
            -Object $FixerResult -Name "summary" -Default "")
        $subject = ConvertTo-ReviewLoopCommitLine -Text $fixerSummary -MaxLength 120
    }
    if ([string]::IsNullOrWhiteSpace($subject) -and $Findings.Count -gt 0) {
        $subject = ConvertTo-ReviewLoopCommitLine `
            -Text ([string]$Findings[0].Title) -MaxLength 120
    }
    if ([string]::IsNullOrWhiteSpace($subject)) {
        $subject = "Resolve verified review findings"
    }

    $safePrefix = ConvertTo-ReviewLoopCommitLine -Text $Prefix -MaxLength 200
    $fullSubject = ConvertTo-ReviewLoopCommitLine `
        -Text "$safePrefix`: $subject" -MaxLength 200

    $rationale = ConvertTo-ReviewLoopCommitLine `
        -Text ([string](Get-ReviewLoopObjectProperty `
            -Object $proposal -Name "rationale" -Default "")) `
        -MaxLength 1000
    if ([string]::IsNullOrWhiteSpace($rationale)) {
        $description = if ($Findings.Count -eq 1) {
            [string](Get-ReviewLoopObjectProperty `
                -Object $Findings[0] -Name "Description" -Default "")
        }
        else {
            ""
        }
        $rationale = ConvertTo-ReviewLoopCommitLine -Text $description -MaxLength 1000
    }
    if ([string]::IsNullOrWhiteSpace($rationale)) {
        $rationale = if ($Findings.Count -eq 1) {
            "Address the verified review finding."
        }
        else {
            "Address the verified review findings."
        }
    }

    $changes = [System.Collections.Generic.List[string]]::new()
    $seenChanges = [System.Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    foreach ($change in @((Get-ReviewLoopObjectProperty `
        -Object $proposal -Name "changes" -Default @()))) {
        if ($changes.Count -ge 8) {
            break
        }
        $line = ConvertTo-ReviewLoopCommitLine -Text ([string]$change) -MaxLength 300
        if (-not [string]::IsNullOrWhiteSpace($line) -and $seenChanges.Add($line)) {
            [void]$changes.Add($line)
        }
    }
    if ($changes.Count -eq 0) {
        $fallbackChange = ConvertTo-ReviewLoopCommitLine `
            -Text ([string](Get-ReviewLoopObjectProperty `
                -Object $FixerResult -Name "summary" -Default "")) `
            -MaxLength 300
        if (-not [string]::IsNullOrWhiteSpace($fallbackChange)) {
            [void]$changes.Add($fallbackChange)
        }
    }

    $sections = [System.Collections.Generic.List[string]]::new()
    [void]$sections.Add($fullSubject)
    [void]$sections.Add($rationale)
    if ($changes.Count -gt 0) {
        [void]$sections.Add("Changes:`n- $($changes -join "`n- ")")
    }

    if ($Findings.Count -gt 1) {
        $findingTitles = @($Findings | ForEach-Object {
            ConvertTo-ReviewLoopCommitLine -Text ([string]$_.Title) -MaxLength 300
        } | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        } | Select-Object -Unique)
        if ($findingTitles.Count -gt 0) {
            [void]$sections.Add(
                "Findings addressed:`n- $($findingTitles -join "`n- ")")
        }
    }

    $verified = [System.Collections.Generic.List[string]]::new()
    $seenVerified = [System.Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    $testExecution = Get-ReviewLoopObjectProperty `
        -Object $FixerResult -Name "testExecution"
    if ($null -ne $testExecution -and
        [bool](Get-ReviewLoopObjectProperty `
            -Object $testExecution -Name "Passed" -Default $false) -and
        -not [string]::IsNullOrWhiteSpace([string](Get-ReviewLoopObjectProperty `
            -Object $testExecution -Name "FilePath" -Default ""))) {
        [void]$seenVerified.Add("Targeted regression test")
        [void]$verified.Add("Targeted regression test")
    }
    foreach ($gate in @($GateResults)) {
        if (-not [bool](Get-ReviewLoopObjectProperty `
            -Object $gate -Name "Success" -Default $false)) {
            continue
        }
        $name = ConvertTo-ReviewLoopCommitLine `
            -Text ([string](Get-ReviewLoopObjectProperty `
                -Object $gate -Name "Name" -Default "")) `
            -MaxLength 300
        if (-not [string]::IsNullOrWhiteSpace($name) -and $seenVerified.Add($name)) {
            [void]$verified.Add($name)
        }
    }
    if ($verified.Count -gt 0) {
        [void]$sections.Add("Verified:`n- $($verified -join "`n- ")")
    }

    $message = $sections -join "`n`n"
    if ($message.Length -gt 4000) {
        $message = $message.Substring(0, 4000).TrimEnd()
    }
    return Get-ReviewLoopCanonicalCommitMessage -Message $message
}

function Complete-ReviewLoopPendingCommit {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][object]$Ledger,
        [Parameter(Mandatory = $true)][string]$LedgerPath,
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$RunRoot
    )

    Assert-ReviewLoopExecutionUnchanged -Config $Config
    $pending = Get-ReviewLoopObjectProperty -Object $State -Name "PendingCommit"
    if ($null -eq $pending) {
        return $false
    }
    $ids = @($State.ActiveFindingIds | ForEach-Object { [string]$_ })
    $findings = @($Ledger.Findings | Where-Object { [string]$_.Id -in $ids })
    if ($findings.Count -ne $ids.Count -or $findings.Count -eq 0) {
        throw "Pending commit cannot be completed because active findings are missing."
    }

    $head = Get-ReviewLoopGitValue -RepoPath $RepoPath -Arguments @("rev-parse", "HEAD")
    $preHead = [string]$pending.PreHead
    $expectedFingerprint = [string]$pending.PatchFingerprint
    if ($head -eq $preHead) {
        if ((Get-ReviewLoopWorktreeFingerprint -RepoPath $RepoPath) -ne $expectedFingerprint) {
            throw "The worktree changed after verification; refusing the pending commit."
        }
        Invoke-ReviewLoopGitStep -Name "Commit preparation" -Arguments @("add", "-A") `
            -RepoPath $RepoPath -RunRoot $RunRoot -ClusterId $State.ActiveClusterId | Out-Null
        $tree = Get-ReviewLoopGitValue -RepoPath $RepoPath -Arguments @("write-tree")
        if ((Get-ReviewLoopWorktreeFingerprint -RepoPath $RepoPath) -ne $expectedFingerprint) {
            throw "The worktree changed while preparing the verified commit."
        }
        $sealedTree = Get-ReviewLoopGitValue -RepoPath $RepoPath -Arguments @("write-tree")
        if ($tree -ne $sealedTree) {
            throw "The Git index changed while preparing the verified commit."
        }
        $tree = $sealedTree
        Assert-ReviewLoopVerifiedWorktreeIsFullyStaged `
            -RepoPath $RepoPath `
            -PreHead $preHead `
            -PatchFingerprint $expectedFingerprint `
            -StagedTree $tree
        if (-not [string]::IsNullOrWhiteSpace([string]$pending.ExpectedTree) -and
            [string]$pending.ExpectedTree -ne $tree) {
            throw "The staged tree does not match the verified pending commit."
        }
        $pending.ExpectedTree = $tree
        $pending | Add-Member -Force -NotePropertyName ExpectedCommit -NotePropertyValue ""
        Set-ReviewLoopCheckpoint -State $State -StatePath $StatePath -Stage "commit_pending"
        $autoCommit = if ($Config.ContainsKey("AutoCommit")) {
            [bool]$Config.AutoCommit
        }
        else {
            $true
        }
        if (-not $autoCommit) {
            Stop-ReviewLoopBlocked `
                -Message "Verified changes are staged and ready to commit, but AutoCommit is disabled." `
                -NextSteps @(
                    "Commit the staged tree with the exact prepared message stored in '$StatePath' under PendingCommit.Message, then run the same command again."
                    "Or set AutoCommit = `$true in the active profile and run the same command again so the loop creates the verified commit."
                )
        }
        $commitObject = Invoke-ReviewLoopGitStep -Name "Commit object" -Arguments @(
            "commit-tree", $tree, "-p", $preHead, "-m", [string]$pending.Message
        ) -RepoPath $RepoPath -RunRoot $RunRoot -ClusterId $State.ActiveClusterId
        $candidate = @(
            ([string]$commitObject.Output) -split "\r?\n" |
                ForEach-Object { $_.Trim() } |
                Where-Object { $_ -match "^[0-9a-fA-F]{40,64}$" }
        )
        if ($candidate.Count -ne 1) {
            throw "Git did not return exactly one commit object ID."
        }
        $candidateCommit = $candidate[0].ToLowerInvariant()
        $pending.ExpectedCommit = $candidateCommit
        Set-ReviewLoopCheckpoint -State $State -StatePath $StatePath -Stage "commit_pending"
        Invoke-ReviewLoopGitStep -Name "Commit" -Arguments @(
            "update-ref", "HEAD", $candidateCommit, $preHead
        ) -RepoPath $RepoPath -RunRoot $RunRoot -ClusterId $State.ActiveClusterId | Out-Null
        $head = Get-ReviewLoopGitValue -RepoPath $RepoPath -Arguments @("rev-parse", "HEAD")
    }

    $commitCheck = Get-ReviewLoopPendingCommitCheck `
        -RepoPath $RepoPath -Pending $pending
    if (-not $commitCheck.Matches) {
        $details = @($commitCheck.Mismatches) -join "; "
        throw "The resulting commit does not match the verified pending commit. Failed checks: $details."
    }
    $subject = [string]$commitCheck.Subject
    if ([bool](Get-ReviewLoopObjectProperty -Object $pending -Name "NeedsCurrentGates" -Default $false)) {
        Update-ReviewLoopLiveConfig -Config $Config
        Assert-ReviewLoopExecutionUnchanged -Config $Config
        $snapshot = Get-ReviewLoopRepositorySnapshot -RepoPath $RepoPath
        $gates = Invoke-ReviewLoopHostGates `
            -RepoPath $RepoPath -HostGates @($Config.HostGates) `
            -RunRoot $RunRoot -ClusterId $State.ActiveClusterId `
            -InactivityTimeoutSeconds (Get-ReviewLoopInactivityTimeoutSeconds -Config $Config) `
            -Config $Config
        Assert-ReviewLoopRepositoryUnchanged `
            -RepoPath $RepoPath -Snapshot $snapshot -Operation "A requalification host gate"
        if (-not $gates.Success) {
            throw "Committed transaction failed current host gate '$($gates.Failure.Name)'."
        }
        $pending.NeedsCurrentGates = $false
        Set-ReviewLoopCheckpoint -State $State -StatePath $StatePath -Stage "commit_pending"
    }

    $shortCommit = if ($head.Length -gt 10) { $head.Substring(0, 10) } else { $head }
    Write-ReviewLoopStatus -Message "Committed $shortCommit · $subject" -Kind Success
    Complete-ReviewLoopResolution -State $State -StatePath $StatePath `
        -Ledger $Ledger -LedgerPath $LedgerPath -Findings $findings `
        -VerificationResult $findings[0].Verification -Commit $head
    return $true
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
        [AllowNull()][object]$FixerResult = $null,
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$RunRoot,
        [Parameter(Mandatory = $true)][object]$ExpectedSnapshot
    )

    Update-ReviewLoopLiveConfig -Config $Config
    Assert-ReviewLoopExecutionUnchanged -Config $Config
    $gates = Invoke-ReviewLoopHostGates `
        -RepoPath $RepoPath `
        -HostGates @($Config.HostGates) `
        -RunRoot $RunRoot `
        -ClusterId $State.ActiveClusterId `
        -InactivityTimeoutSeconds (Get-ReviewLoopInactivityTimeoutSeconds -Config $Config) `
        -Config $Config
    Assert-ReviewLoopRepositoryUnchanged `
        -RepoPath $RepoPath -Snapshot $ExpectedSnapshot -Operation "A host gate"
    if (-not $gates.Success) {
        $excerpt = @(Get-ReviewLoopTextExcerpt -Text $gates.Failure.Output -MaxLines 6) -join " "
        return [pscustomobject]@{
            Success = $false
            Retryable = [int]$gates.Failure.ExitCode -ne -1
            Feedback = "Host gate '$($gates.Failure.Name)' failed with exit code $($gates.Failure.ExitCode): $excerpt"
        }
    }

    $head = Get-ReviewLoopGitValue -RepoPath $RepoPath -Arguments @("rev-parse", "HEAD")
    if (Test-ReviewLoopGitClean -RepoPath $RepoPath) {
        Complete-ReviewLoopResolution -State $State -StatePath $StatePath `
            -Ledger $Ledger -LedgerPath $LedgerPath -Findings $Findings `
            -VerificationResult $Verification.Result -Commit $head
        Write-ReviewLoopStatus -Message "No commit was needed; the finding is resolved on the current HEAD." -Kind Success
        return [pscustomobject]@{ Success = $true; Retryable = $false; Feedback = "" }
    }
    $message = New-ReviewLoopCommitMessage `
        -Prefix ([string]$Config.CommitMessagePrefix) `
        -Findings $Findings `
        -FixerResult $FixerResult `
        -VerificationResult $Verification.Result `
        -GateResults @($gates.Results)
    foreach ($finding in $Findings) {
        $finding.Verification = $Verification.Result
    }
    Write-ReviewLoopLedger -Path $LedgerPath -Ledger $Ledger | Out-Null
    $State | Add-Member -Force -NotePropertyName PendingCommit -NotePropertyValue ([pscustomobject]@{
        PreHead = $head
        PatchFingerprint = [string]$ExpectedSnapshot.Fingerprint
        ExpectedTree = ""
        ExpectedCommit = ""
        Message = $message
        NeedsCurrentGates = $false
    })
    Set-ReviewLoopCheckpoint -State $State -StatePath $StatePath -Stage "commit_preparing"
    Write-ReviewLoopStatus -Message "Preparing the verified commit." -Kind Progress
    Complete-ReviewLoopPendingCommit -Config $Config -State $State -StatePath $StatePath `
        -Ledger $Ledger -LedgerPath $LedgerPath -RepoPath $RepoPath -RunRoot $RunRoot | Out-Null
    return [pscustomobject]@{ Success = $true; Retryable = $false; Feedback = "" }
}

function Invoke-ReviewLoopAttemptAssessment {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][object]$Ledger,
        [Parameter(Mandatory = $true)][string]$LedgerPath,
        [Parameter(Mandatory = $true)][object[]]$Findings,
        [Parameter(Mandatory = $true)][object]$FixerCall,
        [Parameter(Mandatory = $true)][int]$Attempt,
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$Speed,
        [Parameter(Mandatory = $true)][string]$RunRoot,
        [string]$CodexPath = ""
    )

    $changedPaths = @(Update-ReviewLoopFixerResultFromWorktree `
        -FixerResult $FixerCall.StructuredResult `
        -RepoPath $RepoPath)
    $worktreeSnapshot = Get-ReviewLoopRepositorySnapshot -RepoPath $RepoPath
    if ([string]$worktreeSnapshot.Head -ne [string]$State.CurrentHead) {
        Stop-ReviewLoopBlocked -Message "Repository HEAD changed during the fixer role."
    }
    if ($null -ne $State.LastFixerResult) {
        $State.LastFixerResult | Add-Member -Force -NotePropertyName WorktreeFingerprint `
            -NotePropertyValue ([string]$worktreeSnapshot.Fingerprint)
        $State.LastFixerResult | Add-Member -Force -NotePropertyName WorktreeHead `
            -NotePropertyValue ([string]$worktreeSnapshot.Head)
        Write-ReviewLoopState -Path $StatePath -State $State | Out-Null
    }
    Write-ReviewLoopStatus `
        -Message "Fixer: $($FixerCall.StructuredResult.summary) · $($changedPaths.Count) changed paths$(if ($changedPaths.Count -gt 0) { ': ' + ($changedPaths -join ', ') } else { '' })" `
        -Kind $(if ($changedPaths.Count -gt 0) { "Success" } else { "Warning" })

    Set-ReviewLoopCheckpoint -State $State -StatePath $StatePath -Stage "testing"
    Update-ReviewLoopLiveConfig -Config $Config
    Assert-ReviewLoopExecutionUnchanged -Config $Config
    $tests = Invoke-ReviewLoopTargetedTests `
        -FixerResult $FixerCall.StructuredResult `
        -RepoPath $RepoPath `
        -RunRoot $RunRoot `
        -ClusterId $State.ActiveClusterId `
        -Attempt $Attempt `
        -InactivityTimeoutSeconds (Get-ReviewLoopInactivityTimeoutSeconds -Config $Config)
    Assert-ReviewLoopRepositoryUnchanged `
        -RepoPath $RepoPath -Snapshot $worktreeSnapshot -Operation "The targeted test"
    if (-not $tests.Success) {
        Set-ReviewLoopCheckpoint -State $State -StatePath $StatePath -Stage "test_failed"
        return [pscustomobject]@{
            Completed = $false
            Feedback = $tests.Feedback
            RetrySameAttempt = [bool]$tests.Correctable
        }
    }
    Set-ReviewLoopCheckpoint -State $State -StatePath $StatePath -Stage "tested"

    $verification = Invoke-ReviewLoopVerifier `
        -Config $Config -State $State -StatePath $StatePath -RepoPath $RepoPath `
        -Speed $Speed -RunRoot $RunRoot -Findings $Findings -FixerCall $FixerCall `
        -Attempt $Attempt -CodexPath $CodexPath
    $targetedTest = $FixerCall.StructuredResult.targetedTest
    $targetedCommand = "$($targetedTest.executable) $(@($targetedTest.arguments) -join ' ')".Trim()
    $targetedAvailable = if ($targetedTest.PSObject.Properties.Name -contains "available") {
        [bool]$targetedTest.available
    }
    else {
        -not [string]::IsNullOrWhiteSpace([string]$targetedTest.executable)
    }
    $targetedState = if (-not $targetedAvailable) {
        "not available"
    }
    elseif ([bool]$FixerCall.StructuredResult.testExecution.Passed) {
        "passed"
    }
    else {
        "failed"
    }
    Write-ReviewLoopStatus `
        -Message "Verifier: $(if ($verification.Accepted) { 'accepted' } else { 'changes requested' }) · $($verification.Result.summary) · Test $targetedState$(if (-not [string]::IsNullOrWhiteSpace($targetedCommand)) { ': ' + $targetedCommand } else { '' })" `
        -Kind $(if ($verification.Accepted) { "Success" } else { "Warning" })
    Set-ReviewLoopCheckpoint -State $State -StatePath $StatePath -Stage "verified"
    Assert-ReviewLoopRepositoryUnchanged `
        -RepoPath $RepoPath -Snapshot $worktreeSnapshot -Operation "Read-only verification"

    if ($verification.Accepted) {
        $completion = Complete-ReviewLoopFix `
            -Config $Config -State $State -StatePath $StatePath `
            -Ledger $Ledger -LedgerPath $LedgerPath -Findings $Findings `
            -Verification $verification -FixerResult $FixerCall.StructuredResult `
            -RepoPath $RepoPath -RunRoot $RunRoot `
            -ExpectedSnapshot $worktreeSnapshot
        if ($completion.Success) {
            return [pscustomobject]@{ Completed = $true; Feedback = "" }
        }
        if (-not $completion.Retryable) {
            throw $completion.Feedback
        }
        Set-ReviewLoopCheckpoint -State $State -StatePath $StatePath -Stage "gate_failed"
        return [pscustomobject]@{ Completed = $false; Feedback = $completion.Feedback; RetrySameAttempt = $false }
    }

    return [pscustomobject]@{
        Completed = $false
        RetrySameAttempt = $false
        Feedback = @(
            [string]$verification.Result.summary
            @($verification.Result.feedback | ForEach-Object { [string]$_ })
        ) -join [Environment]::NewLine
    }
}

function Restart-ReviewLoopReviewRound {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][object]$Ledger,
        [Parameter(Mandatory = $true)][string]$LedgerPath,
        [Parameter(Mandatory = $true)][object[]]$Findings,
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$RunRoot,
        [Parameter(Mandatory = $true)][int]$Attempt,
        [string]$Reason = ""
    )

    try {
        if (-not (Test-ReviewLoopGitClean -RepoPath $RepoPath)) {
            $snapshot = Get-ReviewLoopRepositorySnapshot -RepoPath $RepoPath
            if ($null -eq $State.LastFixerResult) {
                $State.LastFixerResult = [pscustomobject]@{}
            }
            $State.LastFixerResult | Add-Member -Force -NotePropertyName WorktreeFingerprint `
                -NotePropertyValue ([string]$snapshot.Fingerprint)
            $State.LastFixerResult | Add-Member -Force -NotePropertyName WorktreeHead `
                -NotePropertyValue ([string]$snapshot.Head)
            Write-ReviewLoopState -Path $StatePath -State $State | Out-Null
            $artifact = Get-ReviewLoopBlockedArtifact `
                -State $State -RepoPath $RepoPath -RunRoot $RunRoot `
                -ClusterId "$($State.ActiveClusterId)-c$($State.ReviewCycle)-restart" `
                -Attempt $Attempt
            if ($null -ne $artifact) {
                Restore-ReviewLoopBlockedWorktree -RepoPath $RepoPath -Cleanup $artifact
            }
        }
    }
    catch {
        throw (New-ReviewLoopFailureException `
            -Message "The rejected fixer round could not be reset to its saved Git checkpoint: $($_.Exception.Message)" `
            -NextSteps @(
                "Inspect the current Git state and the preserved round artifact before changing either one."
                "Restore a clean repository state, then run the same command again."
            ))
    }

    if ([string](Get-ReviewLoopObjectProperty `
        -Object $State -Name "ActiveFindingSource" -Default "") -eq "lessons_learned") {
        $State.LessonsLearned.Status = "pending"
    }
    foreach ($finding in $Findings) {
        $finding.Status = "open"
        $finding.FixAttempts = 0
        $finding.FixerThreadId = ""
        $finding.Verification = $null
        $finding.ResolutionCommit = ""
        $finding.BlockedReason = ""
        $finding.UpdatedAt = [DateTimeOffset]::UtcNow.ToString("O")
    }
    Write-ReviewLoopLedger -Path $LedgerPath -Ledger $Ledger | Out-Null
    $restartMessage = if ([string]::IsNullOrWhiteSpace($Reason)) {
        "Fixer round reached $Attempt calls without acceptance; restarting with the native Reviewer."
    }
    else {
        "$Reason Restarting with the native Reviewer."
    }
    Write-ReviewLoopStatus `
        -Message $restartMessage `
        -Kind Info
    Clear-ReviewLoopActiveCluster `
        -State $State -StatePath $StatePath -Stage "review_round_requested"
    return $false
}

function Save-ReviewLoopPartialFixRecovery {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$RunRoot,
        [Parameter(Mandatory = $true)][int]$Attempt,
        [Parameter(Mandatory = $true)][string]$FailureReason,
        [Parameter(Mandatory = $true)][int]$Correction
    )

    $snapshot = Get-ReviewLoopRepositorySnapshot -RepoPath $RepoPath
    if ([string]$snapshot.Head -ne [string]$State.CurrentHead) {
        Stop-ReviewLoopBlocked -Message "HEAD changed before partial Fixer work could be preserved."
    }
    if ($null -eq $State.LastFixerResult) {
        $State.LastFixerResult = [pscustomobject]@{}
    }
    $State.LastFixerResult | Add-Member -Force -NotePropertyName WorktreeFingerprint `
        -NotePropertyValue ([string]$snapshot.Fingerprint)
    $State.LastFixerResult | Add-Member -Force -NotePropertyName WorktreeHead `
        -NotePropertyValue ([string]$snapshot.Head)
    Write-ReviewLoopState -Path $StatePath -State $State | Out-Null

    $artifact = Get-ReviewLoopBlockedArtifact `
        -State $State -RepoPath $RepoPath -RunRoot $RunRoot `
        -ClusterId "$($State.ActiveClusterId)-c$($State.ReviewCycle)-partial" `
        -Attempt $Attempt
    if ($null -eq $artifact) {
        throw "The Fixer reported partial mutation, but Git exposed no worktree change to preserve."
    }
    $recovery = [pscustomobject][ordered]@{
        SchemaVersion = "1.0"
        Attempt = $Attempt
        Correction = $Correction
        Head = [string]$artifact.Head
        WorktreeFingerprint = [string]$artifact.WorktreeFingerprint
        ArtifactRoot = [string]$artifact.ArtifactRoot
        ManifestPath = [string]$artifact.ManifestPath
        ChangedPaths = @($artifact.ChangedPaths)
        FailureReason = $FailureReason
        CreatedAt = [DateTimeOffset]::UtcNow.ToString("O")
    }
    $State | Add-Member -Force -NotePropertyName PartialFixRecovery -NotePropertyValue $recovery
    Set-ReviewLoopCheckpoint `
        -State $State -StatePath $StatePath -Stage "fixer_partial_captured"
    Write-ReviewLoopStatus `
        -Message "Partial Fixer work was preserved at '$($artifact.ArtifactRoot)'; starting one fresh recovery thread." `
        -Kind Warning
    return $recovery
}

function Invoke-ReviewLoopFixWorkflow {
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
        [string]$CodexPath = "",
        [switch]$Recover
    )

    $attempt = [int](@($Findings | ForEach-Object { [int]$_.FixAttempts } |
        Measure-Object -Maximum).Maximum)
    $threadId = [string]$Findings[0].FixerThreadId
    if ([string]::IsNullOrWhiteSpace($threadId)) {
        $threadId = Get-ReviewLoopRoleSessionThreadId -State $State -Role "Fixer"
    }
    $partialRecovery = Get-ReviewLoopObjectProperty -Object $State -Name "PartialFixRecovery"
    if ($Recover -and [string]::IsNullOrWhiteSpace($threadId) -and $attempt -gt 0 -and
        $null -eq (Get-ReviewLoopObjectProperty -Object $State -Name "ActiveRoleCall") -and
        -not (Test-ReviewLoopGitClean -RepoPath $RepoPath) -and
        $null -eq $partialRecovery) {
        Stop-ReviewLoopBlocked -Message "Interrupted legacy fixer checkpoint has no resumable role thread."
    }
    if (-not [string]::IsNullOrWhiteSpace($threadId)) {
        foreach ($finding in $Findings) { $finding.FixerThreadId = $threadId }
        Write-ReviewLoopLedger -Path $LedgerPath -Ledger $Ledger | Out-Null
    }

    $feedback = "None."
    $retryCurrentAttempt = $Recover -and $attempt -gt 0
    $technicalCorrections = if ($Recover) {
        [int](Get-ReviewLoopObjectProperty `
            -Object $State.LastFixerResult -Name "Correction" -Default 0)
    }
    else {
        0
    }
    if ($null -ne $partialRecovery) {
        $threadId = ""
        foreach ($finding in $Findings) { $finding.FixerThreadId = "" }
        $technicalCorrections = [Math]::Max(
            $technicalCorrections,
            [int](Get-ReviewLoopObjectProperty `
                -Object $partialRecovery -Name "Correction" -Default 1))
        $retryCurrentAttempt = $true
        $feedback = @(
            "The previous Fixer process ended after changing the worktree without producing a resumable thread."
            "Inspect the current diff, preserve correct partial work, and complete the same finding."
            "Technical failure: $([string](Get-ReviewLoopObjectProperty -Object $partialRecovery -Name 'FailureReason' -Default 'unknown'))"
        ) -join [Environment]::NewLine
    }
    $storedAttempt = [int](Get-ReviewLoopObjectProperty `
        -Object $State.LastFixerResult -Name "Attempt" -Default -1)
    $storedSuccess = [bool](Get-ReviewLoopObjectProperty `
        -Object $State.LastFixerResult -Name "Success" -Default $true)
    $storedFailureKind = [string](Get-ReviewLoopObjectProperty `
        -Object $State.LastFixerResult -Name "FailureKind" -Default "")
    $storedFingerprint = [string](Get-ReviewLoopObjectProperty `
        -Object $State.LastFixerResult -Name "WorktreeFingerprint" -Default "")
    $storedHead = [string](Get-ReviewLoopObjectProperty `
        -Object $State.LastFixerResult -Name "WorktreeHead" -Default ([string]$State.CurrentHead))
    if ($Recover -and $storedSuccess -and $storedAttempt -eq $attempt -and
        $null -ne $State.LastFixerResult -and $null -ne $State.LastFixerResult.StructuredResult) {
        $currentSnapshot = Get-ReviewLoopRepositorySnapshot -RepoPath $RepoPath
        if ((-not [string]::IsNullOrWhiteSpace($storedFingerprint) -and
                [string]$currentSnapshot.Fingerprint -ne $storedFingerprint) -or
            (-not [string]::IsNullOrWhiteSpace($storedHead) -and
                [string]$currentSnapshot.Head -ne $storedHead)) {
            if ([string]$State.Stage -notin @("testing", "test_failed", "gate_failed")) {
                Stop-ReviewLoopBlocked -Message "The active worktree changed outside the recorded fixer attempt."
            }
            $feedback = "A test or gate changed the worktree after the previous fixer result. Remove unintended generated changes."
            $retryCurrentAttempt = $false
        }
        else {
            $lastFixer = [pscustomobject]@{
                Success = $true
                StructuredResult = $State.LastFixerResult.StructuredResult
                ThreadId = $threadId
            }
            $assessment = Invoke-ReviewLoopAttemptAssessment `
                -Config $Config -State $State -StatePath $StatePath `
                -Ledger $Ledger -LedgerPath $LedgerPath -Findings $Findings `
                -FixerCall $lastFixer -Attempt $attempt -RepoPath $RepoPath `
                -Speed $Speed -RunRoot $RunRoot -CodexPath $CodexPath
            if ($assessment.Completed) { return $true }
            $feedback = [string]$assessment.Feedback
            if ([bool](Get-ReviewLoopObjectProperty -Object $assessment -Name "RetrySameAttempt" -Default $false) -and
                $technicalCorrections -lt 2) {
                $technicalCorrections++
                $retryCurrentAttempt = $true
            }
            else {
                $retryCurrentAttempt = $false
            }
        }
    }
    elseif ($retryCurrentAttempt) {
        if ($storedFailureKind -eq "unsafe_partial_mutation" -and
            [string]::IsNullOrWhiteSpace($threadId)) {
            if ($null -eq $partialRecovery) {
                Stop-ReviewLoopBlocked -Message "Interrupted legacy Fixer work has no preserved recovery artifact."
            }
        }
        if ($null -eq $partialRecovery) {
            $feedback = "The previous fixer process was interrupted. Inspect and preserve correct partial work before completing the same attempt."
        }
    }

    while ($true) {
        if (-not $retryCurrentAttempt) {
            Update-ReviewLoopLiveConfig -Config $Config
            $roundLimit = [Math]::Max(1, [Math]::Abs([int]$Config.MaxFixAttempts))
            if ($attempt -ge $roundLimit) {
                return Restart-ReviewLoopReviewRound `
                    -State $State -StatePath $StatePath `
                    -Ledger $Ledger -LedgerPath $LedgerPath -Findings $Findings `
                    -RepoPath $RepoPath -RunRoot $RunRoot -Attempt $attempt
            }
            $attempt++
            $technicalCorrections = 0
            foreach ($finding in $Findings) {
                $finding.Status = "fixing"
                $finding.FixAttempts = [int]$finding.FixAttempts + 1
            }
            Write-ReviewLoopLedger -Path $LedgerPath -Ledger $Ledger | Out-Null
        }
        $retryCurrentAttempt = $false
        Set-ReviewLoopCheckpoint -State $State -StatePath $StatePath -Stage "fixing"
        $threadMode = if ([string]::IsNullOrWhiteSpace($threadId)) { "new thread" } else { "resuming thread" }
        Write-ReviewLoopStatus -Message "Fixer · call $attempt · $threadMode" -Kind Progress
        $activeRoleCall = Get-ReviewLoopObjectProperty -Object $State -Name "ActiveRoleCall"
        $fixerCallId = if ($null -ne $activeRoleCall) {
            [string](Get-ReviewLoopObjectProperty -Object $activeRoleCall -Name "CallId" -Default "")
        }
        else {
            ""
        }
        $fixer = Invoke-ReviewLoopFixer `
            -Config $Config -State $State -StatePath $StatePath -RepoPath $RepoPath `
            -Speed $Speed -RunRoot $RunRoot -Findings $Findings -Strategy $State.ActiveStrategy `
            -Attempt $attempt -Correction $technicalCorrections -CallId $fixerCallId `
            -ThreadId $threadId -CodexPath $CodexPath -Feedback $feedback
        if (-not [string]::IsNullOrWhiteSpace([string]$fixer.ThreadId)) {
            $threadId = [string]$fixer.ThreadId
            foreach ($finding in $Findings) { $finding.FixerThreadId = $threadId }
        }
        $State.LastFixerResult = [pscustomobject]@{
            Success = [bool]$fixer.Success
            FailureKind = [string]$fixer.FailureKind
            StructuredResult = $fixer.StructuredResult
            ThreadId = $threadId
            Attempt = $attempt
            Correction = $technicalCorrections
        }
        $fixerSnapshot = Get-ReviewLoopRepositorySnapshot -RepoPath $RepoPath
        $State.LastFixerResult | Add-Member -Force -NotePropertyName WorktreeFingerprint `
            -NotePropertyValue ([string]$fixerSnapshot.Fingerprint)
        $State.LastFixerResult | Add-Member -Force -NotePropertyName WorktreeHead `
            -NotePropertyValue ([string]$fixerSnapshot.Head)
        Write-ReviewLoopLedger -Path $LedgerPath -Ledger $Ledger | Out-Null
        Set-ReviewLoopCheckpoint -State $State -StatePath $StatePath -Stage $(if ($fixer.Success) {
            "fix_attempted"
        } else { "fixing" })
        if (-not $fixer.Success) {
            if ($null -ne $partialRecovery) {
                return Restart-ReviewLoopReviewRound `
                    -State $State -StatePath $StatePath `
                    -Ledger $Ledger -LedgerPath $LedgerPath -Findings $Findings `
                    -RepoPath $RepoPath -RunRoot $RunRoot -Attempt $attempt `
                    -Reason "The fresh partial-work recovery Fixer also failed technically."
            }
            if ([string]$fixer.FailureKind -eq "unsafe_partial_mutation" -and
                [string]::IsNullOrWhiteSpace([string]$fixer.ThreadId)) {
                $technicalCorrections++
                $partialRecovery = Save-ReviewLoopPartialFixRecovery `
                    -State $State -StatePath $StatePath -RepoPath $RepoPath `
                    -RunRoot $RunRoot -Attempt $attempt `
                    -FailureReason ([string]$fixer.FailureReason) `
                    -Correction $technicalCorrections
                $threadId = ""
                foreach ($finding in $Findings) { $finding.FixerThreadId = "" }
                $feedback = @(
                    "The previous Fixer process ended after changing the worktree without producing a resumable thread."
                    "Inspect the current diff, preserve correct partial work, and complete the same finding."
                    "Technical failure: $($fixer.FailureReason)"
                ) -join [Environment]::NewLine
                $retryCurrentAttempt = $true
                continue
            }
            if ([string]$fixer.FailureKind -eq "timeout") {
                return Restart-ReviewLoopReviewRound `
                    -State $State -StatePath $StatePath `
                    -Ledger $Ledger -LedgerPath $LedgerPath -Findings $Findings `
                    -RepoPath $RepoPath -RunRoot $RunRoot -Attempt $attempt `
                    -Reason "The Fixer remained inactive after its technical recovery attempts."
            }
        }
        Assert-ReviewLoopRoleSuccess $fixer
        $assessment = Invoke-ReviewLoopAttemptAssessment `
            -Config $Config -State $State -StatePath $StatePath `
            -Ledger $Ledger -LedgerPath $LedgerPath -Findings $Findings `
            -FixerCall $fixer -Attempt $attempt -RepoPath $RepoPath `
            -Speed $Speed -RunRoot $RunRoot -CodexPath $CodexPath
        if ($assessment.Completed) { return $true }
        $feedback = [string]$assessment.Feedback
        if ([bool](Get-ReviewLoopObjectProperty -Object $assessment -Name "RetrySameAttempt" -Default $false) -and
            $technicalCorrections -lt 2) {
            $technicalCorrections++
            $retryCurrentAttempt = $true
        }
        Update-ReviewLoopLiveConfig -Config $Config
    }
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

    $clusterKey = @($Findings | ForEach-Object { [string]$_.Id } | Sort-Object) -join "`n"
    $State.ActiveClusterId = "C-" + (Get-ReviewLoopSha256 $clusterKey).Substring(0, 16)
    $State.ActiveFindingIds = @($Findings | ForEach-Object { [string]$_.Id })
    Set-ReviewLoopCheckpoint -State $State -StatePath $StatePath -Stage "cluster_selected"
    Write-ReviewLoopRule -Title "Finding-Cluster $($State.ActiveClusterId)" -Kind Review
    Write-ReviewLoopStatus -Message "$($Findings.Count) Finding(s): $(@($Findings | ForEach-Object { $_.Title }) -join '; ')" -Kind Review

    $architect = Invoke-ReviewLoopArchitect `
        -Config $Config -State $State -StatePath $StatePath -Ledger $Ledger `
        -RepoPath $RepoPath -Speed $Speed -RunRoot $RunRoot `
        -Findings $Findings -CodexPath $CodexPath
    $State.ActiveStrategy = $architect.StructuredResult
    Set-ReviewLoopCheckpoint -State $State -StatePath $StatePath -Stage "strategy_ready"

    Invoke-ReviewLoopFixWorkflow `
        -Config $Config -State $State -StatePath $StatePath `
        -Ledger $Ledger -LedgerPath $LedgerPath -Findings $Findings `
        -RepoPath $RepoPath -Speed $Speed -RunRoot $RunRoot -CodexPath $CodexPath | Out-Null
}

function Invoke-ReviewLoopOpenClusters {
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

    $findings = @(Get-ReviewLoopOpenFindings -Ledger $Ledger)
    if ($findings.Count -gt 0) {
        Invoke-ReviewLoopCluster `
            -Config $Config -State $State -StatePath $StatePath `
            -Ledger $Ledger -LedgerPath $LedgerPath `
            -Findings $findings -RepoPath $RepoPath -Speed $Speed `
            -RunRoot $RunRoot -CodexPath $CodexPath
    }
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

    if ([string]$State.Stage -notin @(
        "cluster_selected", "strategy_ready", "fixing", "fix_attempted",
        "fixer_partial_captured", "testing", "tested", "test_failed", "verified", "gate_failed"
    ) -or
        @($State.ActiveFindingIds).Count -eq 0) {
        return $false
    }

    $ids = @($State.ActiveFindingIds | ForEach-Object { [string]$_ })
    $findings = @($Ledger.Findings | Where-Object { [string]$_.Id -in $ids })
    if ($findings.Count -ne $ids.Count) {
        throw "Interrupted fix cannot be resumed: active findings are missing from the ledger."
    }

    Write-ReviewLoopStatus -Message "Resuming interrupted fix cluster $($State.ActiveClusterId)." -Kind Warning
    if ([string]$State.Stage -eq "cluster_selected") {
        Invoke-ReviewLoopCluster `
            -Config $Config -State $State -StatePath $StatePath `
            -Ledger $Ledger -LedgerPath $LedgerPath -Findings $findings `
            -RepoPath $RepoPath -Speed $Speed -RunRoot $RunRoot -CodexPath $CodexPath
        return $true
    }
    Invoke-ReviewLoopFixWorkflow `
        -Config $Config -State $State -StatePath $StatePath `
        -Ledger $Ledger -LedgerPath $LedgerPath -Findings $findings `
        -RepoPath $RepoPath -Speed $Speed -RunRoot $RunRoot `
        -CodexPath $CodexPath -Recover | Out-Null
    return $true
}

function Test-ReviewLoopRestartReviewException {
    param([Parameter(Mandatory = $true)][System.Exception]$Exception)
    return $Exception.Data.Contains("ReviewLoopRestartReview") -and
        [bool]$Exception.Data["ReviewLoopRestartReview"]
}

function Restart-ReviewLoopAfterInactivity {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][object]$Ledger,
        [Parameter(Mandatory = $true)][string]$LedgerPath,
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$RunRoot,
        [Parameter(Mandatory = $true)][string]$Reason
    )

    $ids = @($State.ActiveFindingIds | ForEach-Object { [string]$_ })
    $findings = if ($ids.Count -eq 0) {
        @()
    }
    else {
        @($Ledger.Findings | Where-Object { [string]$_.Id -in $ids })
    }
    if ($findings.Count -gt 0) {
        $attempt = [int](@($findings | ForEach-Object { [int]$_.FixAttempts } |
            Measure-Object -Maximum).Maximum)
        Restart-ReviewLoopReviewRound `
            -State $State -StatePath $StatePath `
            -Ledger $Ledger -LedgerPath $LedgerPath -Findings $findings `
            -RepoPath $RepoPath -RunRoot $RunRoot -Attempt $attempt `
            -Reason $Reason | Out-Null
        return
    }
    if (-not (Test-ReviewLoopGitClean -RepoPath $RepoPath)) {
        Stop-ReviewLoopBlocked -Message "$Reason The worktree changed without an active Fixer finding."
    }
    if ([string]$State.LessonsLearned.Status -eq "analyzing") {
        $State.LessonsLearned.Status = "pending"
    }
    $State.ActiveRoleCall = $null
    $State.ActiveReviewText = ""
    $State.CleanPasses = 0
    $State.CleanHead = ""
    Set-ReviewLoopCheckpoint `
        -State $State -StatePath $StatePath -Stage "review_round_requested"
    Write-ReviewLoopStatus -Message "$Reason Starting a new native Reviewer round." -Kind Warning
}

function Get-ReviewLoopLessonsLearnedEligibility {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$RepoPath
    )

    if ([string]$State.LessonsLearned.Status -eq "completed") {
        return [pscustomobject]@{
            Eligible = $false
            CompletionAllowed = $true
            Reason = "the lessons-learned phase already completed"
        }
    }
    $threshold = [int]$Config.LessonsLearnedCommitThreshold
    if ($threshold -le 0) {
        return [pscustomobject]@{
            Eligible = $false
            CompletionAllowed = $true
            Reason = "LessonsLearnedCommitThreshold is disabled"
        }
    }
    $commitCount = @($State.LoopCommits | Select-Object -Unique).Count
    if ($commitCount -lt $threshold) {
        return [pscustomobject]@{
            Eligible = $false
            CompletionAllowed = $true
            Reason = "only $commitCount of $threshold verified loop commits exist"
        }
    }
    $head = Get-ReviewLoopGitValue -RepoPath $RepoPath -Arguments @("rev-parse", "HEAD")
    & git -C $RepoPath cat-file -e "$head`:AGENTS.md" 2>$null
    if ($LASTEXITCODE -ne 0) {
        return [pscustomobject]@{
            Eligible = $false
            CompletionAllowed = $true
            Reason = "root AGENTS.md is not tracked in the current HEAD"
        }
    }
    return [pscustomobject]@{
        Eligible = $true
        CompletionAllowed = $false
        Reason = "$commitCount verified loop commits reached the threshold of $threshold"
    }
}

function Get-ReviewLoopLessonsLearnedFinalCompletion {
    param([Parameter(Mandatory = $true)][object]$State)

    if ([string]$State.LessonsLearned.Status -ne "completed") {
        return [pscustomobject]@{
            CompletionAllowed = $false
            Evidence = ""
        }
    }
    $completedHead = [string]$State.LessonsLearned.CompletedHead
    if ([string]::IsNullOrWhiteSpace($completedHead) -or
        [string]$State.CurrentHead -ne $completedHead) {
        return [pscustomobject]@{
            CompletionAllowed = $false
            Evidence = ""
        }
    }

    $createdCommit = [string]$State.LessonsLearned.TriggerHead -ne $completedHead
    $reviewAfterCommit = [bool](Get-ReviewLoopObjectProperty `
        -Object $State.LessonsLearned -Name "ReviewAfterCommit" -Default $false)
    if ($createdCommit -and $reviewAfterCommit) {
        return [pscustomobject]@{
            CompletionAllowed = $false
            Evidence = ""
        }
    }

    return [pscustomobject]@{
        CompletionAllowed = $true
        Evidence = if ($createdCommit) {
            "final lessons-learned change verified"
        }
        else {
            "lessons-learned recommendations accepted without a commit"
        }
    }
}

function Get-ReviewLoopLessonsLearnedCommitText {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$RepoPath
    )

    $lines = foreach ($commit in @($State.LoopCommits | Select-Object -Unique)) {
        $sha = [string]$commit
        $subject = Get-ReviewLoopGitValue `
            -RepoPath $RepoPath -Arguments @("show", "-s", "--format=%s", $sha)
        "- $sha $subject"
    }
    return $lines -join [Environment]::NewLine
}

function Invoke-ReviewLoopLessonsLearnedGate {
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

    Update-ReviewLoopLiveConfig -Config $Config
    $eligibility = Get-ReviewLoopLessonsLearnedEligibility `
        -Config $Config -State $State -RepoPath $RepoPath
    if (-not $eligibility.Eligible) {
        Write-ReviewLoopStatus `
            -Message "Lessons learned skipped: $($eligibility.Reason)." `
            -Kind Info
        return $eligibility
    }
    if (-not (Test-ReviewLoopGitClean -RepoPath $RepoPath)) {
        Stop-ReviewLoopBlocked -Message "The repository changed before lessons-learned analysis started."
    }

    $head = Get-ReviewLoopGitValue -RepoPath $RepoPath -Arguments @("rev-parse", "HEAD")
    if ([string]$State.LessonsLearned.Status -ne "analyzing") {
        $State.LessonsLearned.Attempt = [int]$State.LessonsLearned.Attempt + 1
        $State.LessonsLearned.TriggerHead = $head
        $State.LessonsLearned.TriggerCommitCount = @(
            $State.LoopCommits | Select-Object -Unique).Count
        $State.LessonsLearned.ReviewAfterCommit =
            [bool]$Config.ReviewAfterLessonsLearnedCommit
        $State.LessonsLearned.Status = "analyzing"
    }
    Set-ReviewLoopCheckpoint `
        -State $State -StatePath $StatePath -Stage "lessons_learned_analyzing"
    Write-ReviewLoopStatus `
        -Message "Lessons learned triggered: $($eligibility.Reason)." `
        -Kind Review

    $prompt = Get-ReviewLoopPrompt -Name "lessons-learned.md" -Values @{
        REVIEW_CYCLE_COUNT = [string]$State.ReviewCycle
        COMMIT_COUNT = [string](@($State.LoopCommits | Select-Object -Unique).Count)
        START_HEAD = [string]$State.StartHead
        CURRENT_HEAD = $head
        LOOP_COMMITS = Get-ReviewLoopLessonsLearnedCommitText `
            -State $State -RepoPath $RepoPath
    }
    $headKey = if ($head.Length -gt 10) { $head.Substring(0, 10) } else { $head }
    $call = Invoke-ReviewLoopRoleCall `
        -Config $Config -Role "LessonsLearned" -RepoPath $RepoPath -Speed $Speed `
        -Prompt $prompt -LogRoot $RunRoot `
        -SchemaName "lessons-learned-v1.schema.json" `
        -CodexPath $CodexPath `
        -CallId ("lessons-learned-a{0:d2}-{1}" -f
            [int]$State.LessonsLearned.Attempt, $headKey) `
        -State $State -StatePath $StatePath
    Assert-ReviewLoopRoleSuccess $call

    $recommendations = @($call.StructuredResult.recommendations)
    Write-ReviewLoopStatus `
        -Message "Lessons learned: $($call.StructuredResult.summary) · $($recommendations.Count) recommendation(s)." `
        -Kind $(if ($recommendations.Count -eq 0) { "Success" } else { "Review" })
    if ($recommendations.Count -eq 0) {
        $State.LessonsLearned.Status = "completed"
        $State.LessonsLearned.CompletedHead = $head
        Set-ReviewLoopCheckpoint `
            -State $State -StatePath $StatePath -Stage "lessons_learned_completed"
        return [pscustomobject]@{
            Eligible = $true
            CompletionAllowed = $true
            Reason = "the analysis returned no recommendations"
        }
    }

    $analysisText = ConvertTo-ReviewLoopJsonCompact $call.StructuredResult
    $findings = foreach ($recommendation in $recommendations) {
        [pscustomobject]@{
            title = [string]$recommendation.title
            description = ConvertTo-ReviewLoopJsonCompact $recommendation
            locations = @()
        }
    }
    $reviewId = "lessons-learned-{0:d2}" -f [int]$State.LessonsLearned.Attempt
    $State.ActiveFindingSource = "lessons_learned"
    $State.ActiveReviewText = $analysisText
    $State.LessonsLearned.Status = "implementing"
    Merge-ReviewLoopFindings `
        -Ledger $Ledger -Findings @($findings) -ReviewId $reviewId -Head $head | Out-Null
    Write-ReviewLoopLedger -Path $LedgerPath -Ledger $Ledger | Out-Null
    Set-ReviewLoopCheckpoint -State $State -StatePath $StatePath -Stage "reviewed"
    Write-ReviewLoopStatus `
        -Message "Implementing $($recommendations.Count) lessons-learned recommendation(s) through the normal fix workflow." `
        -Kind Progress
    Invoke-ReviewLoopOpenClusters `
        -Config $Config -State $State -StatePath $StatePath `
        -Ledger $Ledger -LedgerPath $LedgerPath `
        -RepoPath $RepoPath -Speed $Speed -RunRoot $RunRoot -CodexPath $CodexPath
    $finalCompletion = Get-ReviewLoopLessonsLearnedFinalCompletion -State $State
    return [pscustomobject]@{
        Eligible = $true
        CompletionAllowed = $finalCompletion.CompletionAllowed
        CompletionEvidence = $finalCompletion.Evidence
        Reason = if ($finalCompletion.CompletionAllowed) {
            "the accepted lessons-learned solution is the final cycle"
        }
        else {
            "post-commit native reviews are configured"
        }
    }
}

function Complete-ReviewLoopRun {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][string]$RunRoot,
        [Parameter(Mandatory = $true)][string]$LedgerPath,
        [Parameter(Mandatory = $true)][string]$TranscriptPath,
        [Parameter(Mandatory = $true)][int]$CleanPassesRequired,
        [string]$CompletionEvidence = ""
    )

    $State.Status = "completed"
    $State.ExitCode = 0
    Set-ReviewLoopCheckpoint `
        -State $State -StatePath $StatePath -Stage "completed" -Status "completed"
    Write-ReviewLoopCompletionSummary `
        -Cycles $State.ReviewCycle `
        -CleanPasses "$($State.CleanPasses)/$CleanPassesRequired" `
        -RunRoot $RunRoot -LedgerPath $LedgerPath -TranscriptPath $TranscriptPath `
        -CompletionEvidence $CompletionEvidence
    return [pscustomobject]@{
        Status = $State.Status
        ExitCode = 0
        Reason = ""
        NextSteps = @()
        RunRoot = $RunRoot
        StatePath = $StatePath
        LedgerPath = $LedgerPath
        ReviewCycles = $State.ReviewCycle
        CleanPasses = $State.CleanPasses
    }
}

function Invoke-ReviewLoopCore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [string]$ConfigPath = "",
        [AllowEmptyString()][string]$ReviewerInstructions = "",
        [ValidateSet("standard", "fast")][string]$Speed = "standard",
        [string]$CodexPath = "",
        [switch]$NewRun,
        [ValidateSet("compact", "balanced", "detailed")][string]$OutputMode = "compact",
        [ValidateRange(0, 3600)][int]$HeartbeatSeconds = 30,
        [ValidateSet("Host", "Ansi", "Always", "Auto", "Never")][string]$ColorMode = "Host",
        [switch]$Json
    )

    $speedExplicitlyBound = $PSBoundParameters.ContainsKey("Speed")
    $previousSpeed = ""
    Initialize-ReviewLoopConsole `
        -OutputMode $OutputMode `
        -HeartbeatSeconds $HeartbeatSeconds `
        -ColorMode $ColorMode `
        -HostOutputEnabled (-not $Json) `
        -TranscriptPath ""
    $repo = Get-ReviewLoopRepositoryRoot -RepoPath $RepoPath
    $resolvedConfigPath = Resolve-ReviewLoopConfigPath -RepoPath $repo -ConfigPath $ConfigPath
    try {
        $config = Import-ReviewLoopConfig -ConfigPath $resolvedConfigPath -RepoPath $repo
        Assert-ReviewLoopConfigValues -Config $config
        $reviewerInstructionsOverrideBound =
            $PSBoundParameters.ContainsKey("ReviewerInstructions")
        if ($reviewerInstructionsOverrideBound) {
            $config.ReviewerInstructions = $ReviewerInstructions
        }
        $config["__ReviewerInstructionsOverrideBound"] =
            $reviewerInstructionsOverrideBound
        Assert-ReviewLoopHostGatePreflight -Config $config -RepoPath $repo
    }
    catch {
        if ($_.Exception.Data.Contains("ReviewLoopNextSteps")) {
            throw
        }
        throw (New-ReviewLoopFailureException `
            -Message "$($_.Exception.Message) Selected profile: $resolvedConfigPath" `
            -NextSteps @(
                "Correct the reported value in '$resolvedConfigPath'."
                "Run the same command again, or select another profile with -ConfigPath."
            ))
    }
    try {
        $resolvedReviewBase = Get-ReviewLoopGitValue `
            -RepoPath $repo -Arguments @("rev-parse", "--verify", "$($config.ReviewBase)^{commit}")
    }
    catch {
        throw (New-ReviewLoopFailureException `
            -Message "ReviewBase '$($config.ReviewBase)' from profile '$resolvedConfigPath' does not resolve to a commit: $($_.Exception.Message)" `
            -NextSteps @(
                "Fetch or create the configured review-base ref, or correct ReviewBase in the profile."
                "Confirm git rev-parse --verify `"$($config.ReviewBase)^{commit}`" succeeds in the repository, then run the same command again."
            ))
    }
    $fingerprintArguments = @{ ConfigPath = $resolvedConfigPath }
    if ($reviewerInstructionsOverrideBound) {
        $fingerprintArguments.ReviewerInstructions = [string]$config.ReviewerInstructions
    }
    $executionFingerprint = Get-ReviewLoopExecutionFingerprint @fingerprintArguments
    $config["__ConfigPath"] = $resolvedConfigPath
    $config["__ExecutionFingerprint"] = $executionFingerprint
    $branch = Get-ReviewLoopGitValue -RepoPath $repo -Arguments @(
        "branch", "--show-current"
    )
    $paths = New-ReviewLoopRunPaths -Config $config -RepoPath $repo `
        -Branch $branch -ReviewBaseCommit $resolvedReviewBase
    $statePath = ""
    $state = $null
    $resumed = $false
    $resumedFromFailure = $false
    $resumedWithFreshReviewBudget = $false
    if (-not $NewRun) {
        $active = Get-ReviewLoopReviewerRecoveryStatePath `
            -RepoPath $repo `
            -LogRoot ([string]$config.LogRoot) `
            -ReviewBase ([string]$config.ReviewBase)
        if ([string]::IsNullOrWhiteSpace($active)) {
            $active = Get-ReviewLoopLatestActiveStatePath `
                -ProfileRoot $paths.StableProfileRoot
        }
        if (-not [string]::IsNullOrWhiteSpace($active)) {
            $statePath = $active
            $state = Read-ReviewLoopState -Path $statePath
            $paths = New-ReviewLoopRunPaths `
                -Config $config `
                -RepoPath $repo `
                -Branch ([string]$state.Branch) `
                -ReviewBaseCommit $resolvedReviewBase
            $paths.RunRoot = Split-Path -Parent $statePath
            $resumed = $true
        }
    }

    if ($null -eq $state) {
        if (-not (Test-ReviewLoopGitClean -RepoPath $repo)) {
            throw (New-ReviewLoopFailureException `
                -Message "A new review loop cannot start because the repository has staged, unstaged, or untracked changes." `
                -NextSteps @(
                    "Run git status in '$repo' and decide whether to commit, stash, or revert each existing change."
                    "When the worktree is clean, run the same command again."
                ))
        }
        Initialize-ReviewLoopRunPaths -Paths $paths | Out-Null
        $statePath = $paths.StatePath
        $state = New-ReviewLoopState `
            -RepoPath $repo `
            -ReviewBase ([string]$config.ReviewBase) `
            -ReviewBaseCommit $resolvedReviewBase `
            -ExecutionFingerprint $executionFingerprint `
            -Speed $Speed `
            -RunRoot $paths.RunRoot
        Write-ReviewLoopState -Path $statePath -State $state | Out-Null
    }
    else {
        Complete-ReviewLoopInterruptedReviewerRecovery `
            -State $state -StatePath $statePath -RepoPath $repo | Out-Null
        $branch = [string]$state.Branch
        Assert-ReviewLoopResumeInvariant `
            -State $state `
            -RepoPath $repo `
            -ReviewBase ([string]$config.ReviewBase) `
            -SkipHead
        $checkpointSpeed = [string]$state.Speed
        if (-not $speedExplicitlyBound) {
            $Speed = $checkpointSpeed
        }
        elseif ($checkpointSpeed -ne $Speed) {
            $previousSpeed = $checkpointSpeed
            $state.Speed = $Speed
            Write-ReviewLoopState -Path $statePath -State $state | Out-Null
        }
    }
    Initialize-ReviewLoopCommitHistory `
        -State $state -StatePath $statePath -RepoPath $repo
    $executionChanged = $false
    if ($resumed) {
        $storedBaseCommit = [string](Get-ReviewLoopObjectProperty `
            -Object $state -Name "ReviewBaseCommit" -Default "")
        if ([string]::IsNullOrWhiteSpace($storedBaseCommit)) {
            $state | Add-Member -Force -NotePropertyName ReviewBaseCommit -NotePropertyValue $resolvedReviewBase
        }
        $storedFingerprint = [string](Get-ReviewLoopObjectProperty `
            -Object $state -Name "ExecutionFingerprint" -Default "")
        $executionChanged = $storedFingerprint -ne $executionFingerprint
        if ($executionChanged) {
            $state.CleanPasses = 0
            $state.CleanHead = ""
            if ([string]$state.LessonsLearned.Status -eq "analyzing") {
                $state.LessonsLearned.Status = "pending"
            }
            if (Test-ReviewLoopGitClean -RepoPath $repo) {
                $state.ActiveRoleCall = $null
                $state.ActiveClusterId = ""
                $state.ActiveFindingIds = @()
                $state.ActiveFindingSource = ""
                $state.ActiveReviewText = ""
                $state.ActiveStrategy = $null
                $state.LastFixerResult = $null
                $state.PendingCommit = $null
                $state.Stage = "initialized"
            }
        }
        $state | Add-Member -Force -NotePropertyName ExecutionFingerprint `
            -NotePropertyValue $executionFingerprint
        if ($executionChanged -and @($state.ActiveFindingIds).Count -gt 0) {
            $pendingCommit = Get-ReviewLoopObjectProperty -Object $state -Name "PendingCommit"
            $hadPendingCommit = $null -ne $pendingCommit
            $hasCompletedFixer = $null -ne $state.LastFixerResult -and
                $null -ne $state.LastFixerResult.StructuredResult
            $commitAlreadyExists = $hadPendingCommit -and
                (Get-ReviewLoopGitValue -RepoPath $repo -Arguments @("rev-parse", "HEAD")) -ne
                [string]$pendingCommit.PreHead
            if ($commitAlreadyExists) {
                $pendingCommit | Add-Member -Force -NotePropertyName NeedsCurrentGates -NotePropertyValue $true
            }
            else {
                $state | Add-Member -Force -NotePropertyName PendingCommit -NotePropertyValue $null
            }
            if (($hadPendingCommit -and -not $commitAlreadyExists) -or
                (-not $hadPendingCommit -and $hasCompletedFixer)) {
                $state.Stage = "fix_attempted"
            }
            elseif (-not $hadPendingCommit -and -not $hasCompletedFixer -and
                [string]$state.Stage -in @("cluster_selected", "strategy_ready")) {
                $state.ActiveStrategy = $null
                $state.Stage = "cluster_selected"
            }
        }
        Write-ReviewLoopState -Path $statePath -State $state | Out-Null
    }
    if ($resumed -and [string]$state.Status -eq "failed") {
        $resumedFromFailure = $true
        $activeRoleCall = Get-ReviewLoopObjectProperty -Object $state -Name "ActiveRoleCall"
        if ([string]$state.Stage -eq "stopped" -and $null -ne $activeRoleCall) {
            $state.Stage = [string](Get-ReviewLoopObjectProperty `
                -Object $activeRoleCall -Name "CheckpointStage" -Default "reviewing")
        }
        elseif ([string]$state.Stage -eq "stopped" -and @($state.ActiveFindingIds).Count -gt 0) {
            $state.Stage = if (
                $null -ne $state.LastFixerResult -and
                $null -ne $state.LastFixerResult.StructuredResult
            ) {
                "fix_attempted"
            }
            else {
                "fixing"
            }
        }
        elseif ([string]$state.Stage -eq "stopped" -and
            [string]$state.LessonsLearned.Status -eq "analyzing") {
            $state.Stage = "lessons_learned_analyzing"
        }
        $state.Status = "running"
        $state.ExitCode = 0
        $state.BlockedReason = ""
        Write-ReviewLoopState -Path $statePath -State $state | Out-Null
    }
    elseif ($resumed -and [string]$state.Status -eq "limit_reached") {
        $state.Status = "running"
        $state.ExitCode = 0
        $state.BlockedReason = ""
        Write-ReviewLoopState -Path $statePath -State $state | Out-Null
    }
    if ($resumed) {
        $continuesNativeReviewCycle = [string]$state.Stage -eq "reviewing"
        $state.ReviewCyclesThisInvocation = if ($continuesNativeReviewCycle) { 1 } else { 0 }
        $resumedWithFreshReviewBudget = $true
        Write-ReviewLoopState -Path $statePath -State $state | Out-Null
    }

    $terminalPath = Join-Path $paths.RunRoot "terminal.log"
    Initialize-ReviewLoopConsole `
        -OutputMode $OutputMode `
        -HeartbeatSeconds $HeartbeatSeconds `
        -ColorMode $ColorMode `
        -HostOutputEnabled (-not $Json) `
        -TranscriptPath $terminalPath

    Import-ReviewLoopLegacyLedgers `
        -Paths $paths -RepoPath $repo -Branch $branch `
        -ReviewBase ([string]$config.ReviewBase)
    $ledger = Read-ReviewLoopLedger -Path $paths.LedgerPath -RepoPath $repo
    if ($NewRun) {
        foreach ($finding in @($ledger.Findings | Where-Object {
            [string]$_.Status -in @("fixing", "blocked")
        })) {
            $finding.Status = "open"
            $finding.FixAttempts = 0
            $finding.FixerThreadId = ""
            $finding.BlockedReason = ""
            $finding.Verification = $null
            $finding.ResolutionCommit = ""
            $finding.UpdatedAt = [DateTimeOffset]::UtcNow.ToString("O")
        }
    }
    Write-ReviewLoopLedger -Path $paths.LedgerPath -Ledger $ledger | Out-Null
    $head = Get-ReviewLoopGitValue -RepoPath $repo -Arguments @("rev-parse", "HEAD")
    $shortHead = if ($head.Length -gt 10) { $head.Substring(0, 10) } else { $head }
    $baseCommitText = [string]$state.ReviewBaseCommit
    $baseShort = if ($baseCommitText.Length -gt 10) {
        $baseCommitText.Substring(0, 10)
    }
    else {
        $baseCommitText
    }
    $runMode = if ($resumed) { "resumed" } else { "new" }
    if (Test-ReviewLoopOutputLevel -Minimum detailed) {
        Write-ReviewLoopRule -Title "Codex Review Loop" -Kind Progress
        Write-ReviewLoopKeyValue -Name "Repository" -Value $repo
        Write-ReviewLoopKeyValue -Name "Branch" -Value ([string]$state.Branch)
        Write-ReviewLoopKeyValue -Name "Review-Base" -Value ([string]$config.ReviewBase)
        Write-ReviewLoopKeyValue -Name "Base commit" -Value $baseShort
        Write-ReviewLoopKeyValue -Name "HEAD" -Value $shortHead
        Write-ReviewLoopKeyValue -Name "Speed" -Value $Speed
        Write-ReviewLoopKeyValue -Name "Output" -Value "$OutputMode · heartbeat ${HeartbeatSeconds}s · $ColorMode"
        Write-ReviewLoopKeyValue -Name "Profile" -Value "$($config.Name) · $resolvedConfigPath"
        Write-ReviewLoopKeyValue -Name "Run" -Value "$($state.RunId) ($runMode)"
        Write-ReviewLoopKeyValue -Name "Checkpoint" -Value $statePath
        Write-ReviewLoopKeyValue -Name "Ledger" -Value $paths.LedgerPath
        Write-ReviewLoopKeyValue -Name "Terminal-Log" -Value $terminalPath
    }
    elseif (Test-ReviewLoopOutputLevel -Minimum balanced) {
        Write-ReviewLoopRule -Title "Codex Review Loop" -Kind Progress
        Write-ReviewLoopKeyValue -Name "Repository" -Value $repo
        Write-ReviewLoopKeyValue -Name "Branch" -Value ([string]$state.Branch)
        Write-ReviewLoopKeyValue -Name "Review-Base" -Value ([string]$config.ReviewBase)
        Write-ReviewLoopKeyValue -Name "HEAD" -Value $shortHead
        Write-ReviewLoopKeyValue -Name "Speed" -Value $Speed
        Write-ReviewLoopKeyValue -Name "Output" -Value "$OutputMode · heartbeat ${HeartbeatSeconds}s · $ColorMode"
        Write-ReviewLoopKeyValue -Name "Run" -Value "$($state.RunId) ($runMode)"
    }
    else {
        Write-ReviewLoopStatus `
            -Message "$($config.Name) · $($state.Branch) · $runMode · $Speed · HEAD $shortHead" `
            -Kind Progress
    }
    if (-not [string]::IsNullOrWhiteSpace($previousSpeed)) {
        Write-ReviewLoopStatus `
            -Message "Checkpoint speed changed: $previousSpeed -> $Speed. Subsequent role and thread-resume calls use $Speed." `
            -Kind Warning
    }
    if ($resumedFromFailure -and (Test-ReviewLoopOutputLevel -Minimum balanced)) {
        Write-ReviewLoopStatus -Message "Resuming the previous failed checkpoint at stage '$($state.Stage)'." -Kind Warning
    }
    if ($resumedWithFreshReviewBudget -and (Test-ReviewLoopOutputLevel -Minimum balanced)) {
        Write-ReviewLoopStatus -Message "Resuming the review-cycle checkpoint with a fresh MaxReviewCycles budget of $($config.MaxReviewCycles)." -Kind Warning
    }
    if ($executionChanged -and (Test-ReviewLoopOutputLevel -Minimum balanced)) {
        Write-ReviewLoopStatus -Message "Tool or profile changed; completed model work will be requalified before any commit." -Kind Warning
    }

    try {
        $resumedBlockedCleanup = $false
        if ($resumed) {
            Complete-ReviewLoopPendingCommit `
                -Config $config -State $state -StatePath $statePath -Ledger $ledger `
                -LedgerPath $paths.LedgerPath -RepoPath $repo -RunRoot $paths.RunRoot | Out-Null
            Assert-ReviewLoopResumeInvariant `
                -State $state -RepoPath $repo -ReviewBase ([string]$config.ReviewBase)
            $resumedBlockedCleanup = Resume-ReviewLoopBlockedCleanup `
                -State $state `
                -StatePath $statePath `
                -Ledger $ledger `
                -LedgerPath $paths.LedgerPath `
                -RepoPath $repo `
                -RunRoot $paths.RunRoot
        }
        Get-ReviewLoopGitValue -RepoPath $repo -Arguments @(
            "rev-parse", "--verify", "$($state.ReviewBaseCommit)^{commit}"
        ) | Out-Null
        $resumedCluster = Resume-ReviewLoopInterruptedFix `
            -Config $config -State $state -StatePath $statePath `
            -Ledger $ledger -LedgerPath $paths.LedgerPath `
            -RepoPath $repo -Speed $Speed -RunRoot $paths.RunRoot -CodexPath $CodexPath
        if (-not $resumedBlockedCleanup -and -not $resumedCluster -and $resumed -and
            [string]$state.Stage -eq "reviewed" -and
            @(Get-ReviewLoopOpenFindings -Ledger $ledger).Count -gt 0) {
            Write-ReviewLoopStatus -Message "Continuing the reviewed findings without spending another review call." -Kind Warning
            Invoke-ReviewLoopOpenClusters `
                -Config $config -State $state -StatePath $statePath `
                -Ledger $ledger -LedgerPath $paths.LedgerPath `
                -RepoPath $repo -Speed $Speed -RunRoot $paths.RunRoot -CodexPath $CodexPath
        }
        while ($true) {
            Assert-ReviewLoopExecutionUnchanged -Config $config
            $finalLessonsCompletion =
                Get-ReviewLoopLessonsLearnedFinalCompletion -State $state
            if ($finalLessonsCompletion.CompletionAllowed) {
                return Complete-ReviewLoopRun `
                    -State $state -StatePath $statePath -RunRoot $paths.RunRoot `
                    -LedgerPath $paths.LedgerPath -TranscriptPath $terminalPath `
                    -CleanPassesRequired ([int]$config.CleanPassesRequired) `
                    -CompletionEvidence $finalLessonsCompletion.Evidence
            }
            if ([string]$state.Stage -in @(
                "lessons_learned_analyzing", "lessons_learned_completed"
            )) {
                try {
                    $lessonsGate = Invoke-ReviewLoopLessonsLearnedGate `
                        -Config $config -State $state -StatePath $statePath `
                        -Ledger $ledger -LedgerPath $paths.LedgerPath `
                        -RepoPath $repo -Speed $Speed -RunRoot $paths.RunRoot `
                        -CodexPath $CodexPath
                }
                catch {
                    if (Test-ReviewLoopRestartReviewException -Exception $_.Exception) {
                        Restart-ReviewLoopAfterInactivity `
                            -State $state -StatePath $statePath `
                            -Ledger $ledger -LedgerPath $paths.LedgerPath `
                            -RepoPath $repo -RunRoot $paths.RunRoot `
                            -Reason "The lessons-learned role remained inactive after its technical recovery attempts."
                        continue
                    }
                    throw
                }
                if ($lessonsGate.CompletionAllowed) {
                    return Complete-ReviewLoopRun `
                        -State $state -StatePath $statePath -RunRoot $paths.RunRoot `
                        -LedgerPath $paths.LedgerPath -TranscriptPath $terminalPath `
                        -CleanPassesRequired ([int]$config.CleanPassesRequired) `
                        -CompletionEvidence ([string](Get-ReviewLoopObjectProperty `
                            -Object $lessonsGate -Name "CompletionEvidence" -Default ""))
                }
                continue
            }
            if (
                [int]$state.ReviewCyclesThisInvocation -ge [int]$config.MaxReviewCycles -and
                [string]$state.Stage -ne "reviewing"
            ) {
                $state.Status = "limit_reached"
                $state.ExitCode = 4
                Set-ReviewLoopCheckpoint `
                    -State $state `
                    -StatePath $statePath `
                    -Stage "limit_reached" `
                    -Status "limit_reached"
                $reason = "The configured review-cycle limit $($config.MaxReviewCycles) was reached before clean completion."
                Write-ReviewLoopStatus -Message "Review Loop paused: $reason" -Kind Warning
                Write-ReviewLoopStatus `
                    -Message "Run the same command again to continue with a fresh review-cycle budget." `
                    -Kind Info
                Write-ReviewLoopStatus -Message "Details: $terminalPath" -Kind Muted
                return [pscustomobject]@{
                    Status = "limit_reached"
                    ExitCode = 4
                    Reason = $reason
                    NextSteps = @(
                        "Run the same command again to continue this checkpoint with a fresh review-cycle budget."
                    )
                    RunRoot = $paths.RunRoot
                    StatePath = $statePath
                    LedgerPath = $paths.LedgerPath
                    ReviewCycles = $state.ReviewCycle
                    CleanPasses = $state.CleanPasses
                }
            }
            if (-not (Test-ReviewLoopGitClean -RepoPath $repo)) {
                if ($resumed -and [string]$state.Stage -eq "cluster_blocked") {
                    $changedPathCount = @(Get-ReviewLoopChangedPaths -RepoPath $repo).Count
                    $repoLiteral = ConvertTo-ReviewLoopPowerShellLiteral $repo
                    $entryLiteral = ConvertTo-ReviewLoopPowerShellLiteral (
                        Join-Path $script:ModuleRoot "codex-review-loop.ps1")
                    $configLiteral = ConvertTo-ReviewLoopPowerShellLiteral $resolvedConfigPath
                    throw (New-ReviewLoopFailureException `
                        -Message "The previous blocked fixer attempt left unverified changes in $changedPathCount file(s). This legacy checkpoint cannot prove their ownership well enough to clean them automatically." `
                        -NextSteps @(
                            "git -C $repoLiteral stash push -u -m 'Blocked Codex Review Loop attempt'"
                            "& $entryLiteral $repoLiteral -ConfigPath $configLiteral -Speed $Speed -NewRun"
                            "Inspect the current git diff and deliberately commit or revert it instead of stashing it."
                        ) `
                        -RecommendedStepCount 2)
                }
                throw (New-ReviewLoopFailureException `
                    -Message "The repository contains changes that are not part of a resumable fixer checkpoint." `
                    -NextSteps @(
                        "Inspect git status and git diff, and preserve or revert the changes deliberately."
                        "After restoring the saved checkpoint state, run the same command again."
                        "If the changes are intentional, commit or otherwise preserve them, make the worktree clean, and start with -NewRun."
                    ))
            }

            if ([string]$state.Stage -ne "reviewing") {
                $state.ReviewCycle = [int]$state.ReviewCycle + 1
                $state.ReviewCyclesThisInvocation =
                    [int]$state.ReviewCyclesThisInvocation + 1
            }
            $state.CurrentHead = Get-ReviewLoopGitValue -RepoPath $repo -Arguments @("rev-parse", "HEAD")
            Set-ReviewLoopCheckpoint -State $state -StatePath $statePath -Stage "reviewing"
            Write-ReviewLoopRule -Title (
                "Review cycle {0} ({1}/{2} this invocation)" -f
                $state.ReviewCycle,
                $state.ReviewCyclesThisInvocation,
                $config.MaxReviewCycles
            ) -Kind Review
            try {
            $review = Invoke-ReviewLoopReview `
                    -Config $config -State $state -StatePath $statePath -Ledger $ledger -RepoPath $repo `
                    -Speed $Speed -RunRoot $paths.RunRoot -CodexPath $CodexPath
            }
            catch {
                if (Test-ReviewLoopRestartReviewException -Exception $_.Exception) {
                    Restart-ReviewLoopAfterInactivity `
                        -State $state -StatePath $statePath `
                        -Ledger $ledger -LedgerPath $paths.LedgerPath `
                        -RepoPath $repo -RunRoot $paths.RunRoot `
                        -Reason "The active review role remained inactive after its technical recovery attempts."
                    continue
                }
                throw
            }
            $state.ActiveFindingSource = if (@($review.Result.findings).Count -gt 0) {
                "native"
            }
            else {
                ""
            }
            Merge-ReviewLoopFindings `
                -Ledger $ledger -Findings @($review.Result.findings) `
                -ReviewId $review.ReviewId -Head $review.Head | Out-Null
            Write-ReviewLoopLedger -Path $paths.LedgerPath -Ledger $ledger | Out-Null
            Set-ReviewLoopCheckpoint -State $state -StatePath $statePath -Stage "reviewed"
            Update-ReviewLoopLiveConfig -Config $config
            if ((Get-ReviewLoopGitValue -RepoPath $repo -Arguments @("rev-parse", "HEAD")) -ne
                [string]$review.Head -or -not (Test-ReviewLoopGitClean -RepoPath $repo)) {
                Stop-ReviewLoopBlocked -Message "Repository state changed after review and before its result could be applied."
            }

            $open = @(Get-ReviewLoopOpenFindings -Ledger $ledger)
            if ($open.Count -eq 0 -and @($review.Result.findings).Count -eq 0) {
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
                    try {
                        $lessonsGate = Invoke-ReviewLoopLessonsLearnedGate `
                            -Config $config -State $state -StatePath $statePath `
                            -Ledger $ledger -LedgerPath $paths.LedgerPath `
                            -RepoPath $repo -Speed $Speed -RunRoot $paths.RunRoot `
                            -CodexPath $CodexPath
                    }
                    catch {
                        if (Test-ReviewLoopRestartReviewException -Exception $_.Exception) {
                            Restart-ReviewLoopAfterInactivity `
                                -State $state -StatePath $statePath `
                                -Ledger $ledger -LedgerPath $paths.LedgerPath `
                                -RepoPath $repo -RunRoot $paths.RunRoot `
                                -Reason "The lessons-learned role remained inactive after its technical recovery attempts."
                            continue
                        }
                        throw
                    }
                    if ($lessonsGate.CompletionAllowed) {
                        return Complete-ReviewLoopRun `
                            -State $state -StatePath $statePath -RunRoot $paths.RunRoot `
                            -LedgerPath $paths.LedgerPath -TranscriptPath $terminalPath `
                            -CleanPassesRequired ([int]$config.CleanPassesRequired) `
                            -CompletionEvidence ([string](Get-ReviewLoopObjectProperty `
                                -Object $lessonsGate -Name "CompletionEvidence" -Default ""))
                    }
                    continue
                }
                continue
            }

            $state.CleanPasses = 0
            $state.CleanHead = ""
            Write-ReviewLoopStatus -Message "Clean-pass count reset; processing $($open.Count) open findings." -Kind Warning
            try {
                Invoke-ReviewLoopOpenClusters `
                    -Config $config -State $state -StatePath $statePath `
                    -Ledger $ledger -LedgerPath $paths.LedgerPath `
                    -RepoPath $repo -Speed $Speed -RunRoot $paths.RunRoot -CodexPath $CodexPath
            }
            catch {
                if (Test-ReviewLoopRestartReviewException -Exception $_.Exception) {
                    Restart-ReviewLoopAfterInactivity `
                        -State $state -StatePath $statePath `
                        -Ledger $ledger -LedgerPath $paths.LedgerPath `
                        -RepoPath $repo -RunRoot $paths.RunRoot `
                        -Reason "The active finding role remained inactive after its technical recovery attempts."
                    continue
                }
                throw
            }
        }
    }
    catch {
        $message = ConvertTo-ReviewLoopRedactedText $_.Exception.Message
        $failureStage = [string]$state.Stage
        $state.Status = if (
            $_.Exception.Data.Contains("ReviewLoopStatus") -and
            [string]$_.Exception.Data["ReviewLoopStatus"] -eq "blocked"
        ) {
            "blocked"
        }
        else {
            "failed"
        }
        $state.ExitCode = if ($state.Status -eq "blocked") { 3 } else { 2 }
        $nextSteps = @(Get-ReviewLoopFailureNextSteps `
            -Exception $_.Exception `
            -Context $state.Status)
        $recommendedStepCount = Get-ReviewLoopRecommendedStepCount `
            -Exception $_.Exception `
            -Steps $nextSteps
        $state.BlockedReason = $message
        if ($state.Status -eq "blocked" -and @($state.ActiveFindingIds).Count -gt 0) {
            $activeIds = @($state.ActiveFindingIds | ForEach-Object { [string]$_ })
            $activeFindings = @($ledger.Findings | Where-Object {
                [string]$_.Id -in $activeIds
            })
            if ($activeFindings.Count -gt 0) {
                Set-ReviewLoopFindingsStatus `
                    -Findings $activeFindings -Status "blocked" -Reason $message
                Write-ReviewLoopLedger -Path $paths.LedgerPath -Ledger $ledger | Out-Null
            }
        }
        $checkpointStage = if ($state.Status -eq "failed") {
            $failureStage
        }
        else {
            "stopped"
        }
        Set-ReviewLoopCheckpoint -State $state -StatePath $statePath -Stage $checkpointStage -Status $state.Status
        $openCount = @($ledger.Findings | Where-Object { [string]$_.Status -in @("pending", "open", "fixing") }).Count
        $blockedCount = @($ledger.Findings | Where-Object { [string]$_.Status -eq "blocked" }).Count
        $cleanupAtFailure = Get-ReviewLoopObjectProperty `
            -Object $state `
            -Name "BlockedCleanup"
        $blockedArtifactRoot = if (
            $null -ne $cleanupAtFailure -and
            $cleanupAtFailure.PSObject.Properties.Name -contains "ArtifactRoot" -and
            -not [string]::IsNullOrWhiteSpace([string]$cleanupAtFailure.ArtifactRoot)
        ) {
            [string]$cleanupAtFailure.ArtifactRoot
        }
        else {
            [string](@(
            $ledger.Findings |
                Where-Object {
                    [string]$_.Status -eq "blocked" -and
                    $_.PSObject.Properties.Name -contains "BlockedArtifactRoot" -and
                    -not [string]::IsNullOrWhiteSpace([string]$_.BlockedArtifactRoot)
                } |
                Select-Object -Last 1 |
                ForEach-Object { [string]$_.BlockedArtifactRoot }
            ) | Select-Object -First 1)
        }
        $detailPath = if ([string]::IsNullOrWhiteSpace($blockedArtifactRoot)) {
            $terminalPath
        }
        else {
            $blockedArtifactRoot
        }
        Write-ReviewLoopFailureSummary `
            -Title "Review Loop stopped" `
            -Problem $message `
            -Status $state.Status `
            -NextSteps $nextSteps `
            -RecommendedStepCount $recommendedStepCount `
            -Cycles $state.ReviewCycle `
            -CleanPasses "$($state.CleanPasses)/$($config.CleanPassesRequired)" `
            -OpenFindings $openCount `
            -BlockedFindings $blockedCount `
            -RunRoot $paths.RunRoot `
            -LedgerPath $paths.LedgerPath `
            -TranscriptPath $detailPath
        $failureResult = [pscustomobject]@{
            Status = $state.Status
            ExitCode = $state.ExitCode
            Reason = $message
            NextSteps = $nextSteps
            RunRoot = $paths.RunRoot
            StatePath = $statePath
            LedgerPath = $paths.LedgerPath
            ReviewCycles = $state.ReviewCycle
            CleanPasses = $state.CleanPasses
        }
        if (-not [string]::IsNullOrWhiteSpace($blockedArtifactRoot)) {
            $failureResult | Add-Member -NotePropertyName BlockedArtifactRoot `
                -NotePropertyValue $blockedArtifactRoot
        }
        return $failureResult
    }
}

function Invoke-CodexReviewLoop {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [string]$ConfigPath = "",
        [AllowEmptyString()][string]$ReviewerInstructions = "",
        [ValidateSet("standard", "fast")][string]$Speed = "standard",
        [string]$CodexPath = "",
        [switch]$NewRun,
        [ValidateSet("compact", "balanced", "detailed")][string]$OutputMode = "compact",
        [ValidateRange(0, 3600)][int]$HeartbeatSeconds = 30,
        [ValidateSet("Host", "Ansi", "Always", "Auto", "Never")][string]$ColorMode = "Host",
        [switch]$Json
    )

    Initialize-ReviewLoopConsole `
        -OutputMode $OutputMode `
        -HeartbeatSeconds $HeartbeatSeconds `
        -ColorMode $ColorMode `
        -HostOutputEnabled (-not $Json) `
        -TranscriptPath ""
    [CodexReviewLoopCancellationLog]::Install()
    $lock = $null
    $awakeGuardActive = $false
    try {
        $repo = Get-ReviewLoopRepositoryRoot -RepoPath $RepoPath
        $lockPath = Get-ReviewLoopGitValue -RepoPath $repo -Arguments @(
            "rev-parse", "--git-path", "codex-review-loop.lock"
        )
        if (-not [System.IO.Path]::IsPathRooted($lockPath)) {
            $lockPath = Join-Path $repo $lockPath
        }
        try {
            $lock = [System.IO.FileStream]::new(
                $lockPath,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None)
        }
        catch {
            throw (New-ReviewLoopFailureException `
                -Message "Another review loop is already running for '$repo'." `
                -NextSteps @(
                    "Let the existing loop finish, or stop it normally from the terminal that started it."
                    "After that process exits, run this command again. Do not delete the lock file manually."
                ))
        }
        $awakeGuardActive = Start-ReviewLoopAwakeGuard
        return Invoke-ReviewLoopCore @PSBoundParameters
    }
    catch {
        $message = ConvertTo-ReviewLoopRedactedText $_.Exception.Message
        $transcriptPath = [string](Get-ReviewLoopConsoleOption -Name "TranscriptPath")
        $failureContext = if ([string]::IsNullOrWhiteSpace($transcriptPath)) {
            "startup"
        }
        else {
            "failed"
        }
        $nextSteps = @(Get-ReviewLoopFailureNextSteps `
            -Exception $_.Exception `
            -Context $failureContext)
        $recommendedStepCount = Get-ReviewLoopRecommendedStepCount `
            -Exception $_.Exception `
            -Steps $nextSteps
        $runRoot = if ([string]::IsNullOrWhiteSpace($transcriptPath)) {
            ""
        }
        else {
            Split-Path -Parent $transcriptPath
        }
        $statePath = if ([string]::IsNullOrWhiteSpace($runRoot)) {
            ""
        }
        else {
            Join-Path $runRoot "run-v1.json"
        }
        $ledgerPath = if ([string]::IsNullOrWhiteSpace($runRoot)) {
            ""
        }
        else {
            Join-Path (Split-Path -Parent $runRoot) "ledger-v2.json"
        }

        $title = if ([string]::IsNullOrWhiteSpace($transcriptPath)) {
            "Review Loop could not start"
        }
        else {
            "Review Loop stopped during initialization"
        }
        Write-ReviewLoopFailureSummary `
            -Title $title `
            -Problem $message `
            -Status "failed" `
            -NextSteps $nextSteps `
            -RecommendedStepCount $recommendedStepCount `
            -TranscriptPath $transcriptPath
        return [pscustomobject]@{
            Status = "failed"
            ExitCode = 2
            Reason = $message
            NextSteps = $nextSteps
            RunRoot = $runRoot
            StatePath = $statePath
            LedgerPath = $ledgerPath
            ReviewCycles = 0
            CleanPasses = 0
        }
    }
    finally {
        Stop-ReviewLoopAwakeGuard -WasActive $awakeGuardActive
        if ($null -ne $lock) {
            $lock.Dispose()
        }
        [CodexReviewLoopCancellationLog]::Remove()
    }
}
