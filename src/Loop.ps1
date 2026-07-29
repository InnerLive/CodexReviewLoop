function Test-ReviewLoopStateCanResume {
    param([Parameter(Mandatory = $true)][object]$State)

    if ([string]$State.Status -eq "running") {
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
            $gate.FilePath = Resolve-ReviewLoopHostExecutable `
                -RepoPath $RepoPath -FilePath ([string]$gate.FilePath)
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

    return [pscustomobject]@{
        Head = Get-ReviewLoopGitValue -RepoPath $RepoPath -Arguments @("rev-parse", "HEAD")
        Fingerprint = Get-ReviewLoopWorktreeFingerprint -RepoPath $RepoPath
    }
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
        [ValidateRange(1, 86400)][int]$TimeoutSeconds = 1800
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
            -TimeoutSeconds $TimeoutSeconds
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
        [Parameter(Mandatory = $true)][string]$ClusterId
    )

    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($gate in $HostGates) {
        $snapshot = Get-ReviewLoopRepositorySnapshot -RepoPath $RepoPath
        $result = Invoke-ReviewLoopHostGate -RepoPath $RepoPath -Gate $gate -RunRoot $RunRoot -ClusterId $ClusterId
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
        [Parameter(Mandatory = $true)][int]$Attempt
    )

    $test = $FixerResult.targetedTest
    if ($null -eq $test -or
        [string]::IsNullOrWhiteSpace([string]$test.filePath) -or
        $test.arguments -is [string]) {
        return [pscustomobject]@{
            Success = $false
            Correctable = $true
            Feedback = "The fixer must return one structured targetedTest with filePath and an arguments list."
            Results = @()
        }
    }

    $arguments = @($test.arguments | ForEach-Object { [string]$_ })
    try {
        Resolve-ReviewLoopHostExecutable -RepoPath $RepoPath -FilePath ([string]$test.filePath) | Out-Null
    }
    catch {
        return [pscustomobject]@{
            Success = $false
            Correctable = $true
            Feedback = "The targeted test executable '$($test.filePath)' could not be resolved: $($_.Exception.Message)"
            Results = @()
        }
    }

    $gate = @{
        Name = "Targeted regression test"
        FilePath = [string]$test.filePath
        Arguments = $arguments
    }
    $result = Invoke-ReviewLoopHostGate `
        -RepoPath $RepoPath `
        -Gate $gate `
        -RunRoot $RunRoot `
        -ClusterId "$ClusterId-fix-$Attempt"
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
        Correctable = $false
        Feedback = if ($result.Success) { "" } else {
            $excerpt = @(Get-ReviewLoopTextExcerpt -Text $result.Output -MaxLines 6) -join " "
            "Targeted regression test failed: $($test.filePath) $($arguments -join ' '). Exit code $($result.ExitCode). $excerpt"
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

    $changedPaths = @(Get-ReviewLoopChangedPaths -RepoPath $RepoPath)
    $FixerResult.changedPaths = $changedPaths
    $FixerResult.outcome = if ($changedPaths.Count -gt 0) { "changed" } elseif (
        [string]$FixerResult.outcome -eq "blocked"
    ) { "blocked" } else { "no_change" }
    return $changedPaths
}

function Resolve-ReviewLoopFindingRelations {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][object]$Ledger,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Findings,
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$Speed,
        [Parameter(Mandatory = $true)][string]$RunRoot,
        [string]$CodexPath = ""
    )

    $resolved = [System.Collections.Generic.List[object]]::new()
    $candidateLedger = [pscustomobject]@{ Findings = @($Ledger.Findings) }
    foreach ($finding in @($Findings)) {
        $incoming = ConvertTo-ReviewLoopFindingRecord `
            -Finding $finding -ReviewId "incoming" -Head ([string]$State.CurrentHead)
        $incoming.Id = "incoming-" + (Get-ReviewLoopSha256 (
            "$($incoming.Path)`n$($incoming.Component)`n$($incoming.RootCause)`n$($incoming.Invariant)"
        )).Substring(0, 20)
        $candidates = @(Get-ReviewLoopTriggerCandidates -Finding $incoming -Ledger $candidateLedger)
        $decision = Invoke-ReviewLoopTriggerJudge `
            -Config $Config -State $State -StatePath $StatePath `
            -RepoPath $RepoPath -Speed $Speed -RunRoot $RunRoot `
            -Finding $incoming -Candidates $candidates -CodexPath $CodexPath
        $sameRoot = @($decision.Relations | Where-Object {
            [string]$_.relation -eq "same_root_cause" -and [string]$_.confidence -eq "high"
        })
        $matchedId = ""
        if ($sameRoot.Count -gt 0) {
            $sameIds = @($sameRoot | ForEach-Object { [string]$_.candidateFindingId })
            $matches = @($candidateLedger.Findings | Where-Object {
                [string]$_.Id -in $sameIds
            } | Sort-Object CreatedAt, Id)
            if ($matches.Count -gt 0) {
                $matchedId = [string]$matches[0].Id
                foreach ($duplicate in @($matches | Select-Object -Skip 1)) {
                    if ([string]$duplicate.Status -notin @("duplicate", "superseded")) {
                        $duplicate.Status = "duplicate"
                        $duplicate.BlockedReason = "Semantically identical to $matchedId."
                        $duplicate.UpdatedAt = [DateTimeOffset]::UtcNow.ToString("O")
                    }
                }
            }
        }
        $relations = @($decision.Relations | Where-Object {
            [string]$_.candidateFindingId -ne $matchedId
        })
        $finding | Add-Member -Force -NotePropertyName matchedFindingId -NotePropertyValue $matchedId
        $finding | Add-Member -Force -NotePropertyName relations -NotePropertyValue $relations
        [void]$resolved.Add($finding)
        $provisional = ConvertTo-ReviewLoopFindingRecord `
            -Finding $finding -ReviewId "incoming" -Head ([string]$State.CurrentHead)
        if (@($candidateLedger.Findings | Where-Object {
            [string]$_.Id -eq [string]$provisional.Id
        }).Count -eq 0) {
            $candidateLedger.Findings = @($candidateLedger.Findings) + $provisional
        }
    }
    return $resolved.ToArray()
}

function Add-ReviewLoopReciprocalRelations {
    param(
        [Parameter(Mandatory = $true)][object]$Ledger,
        [Parameter(Mandatory = $true)][object[]]$Findings
    )

    foreach ($finding in @($Findings)) {
        $recordId = [string](Get-ReviewLoopObjectProperty `
            -Object $finding -Name "matchedFindingId" -Default "")
        if ([string]::IsNullOrWhiteSpace($recordId)) {
            $recordId = Get-ReviewLoopFindingId `
                -Path ([string]$finding.path) -Component ([string]$finding.component) `
                -RootCause ([string]$finding.rootCause) -Invariant ([string]$finding.invariant)
        }
        $record = $Ledger.Findings | Where-Object {
            [string]$_.Id -eq $recordId
        } | Select-Object -First 1
        $recordStatus = if ($null -eq $record) { "unknown" } else {
            switch ([string]$record.Status) {
                { $_ -in @("pending", "open", "fixing", "blocked") } { "active"; break }
                "resolved" { "resolved"; break }
                { $_ -in @("superseded", "duplicate") } { "obsolete"; break }
                default { "unknown" }
            }
        }
        foreach ($relation in @($finding.relations)) {
            $candidate = $Ledger.Findings | Where-Object {
                [string]$_.Id -eq [string]$relation.candidateFindingId
            } | Select-Object -First 1
            if ($null -eq $candidate -or [string]$candidate.Id -eq $recordId) {
                continue
            }
            if ($candidate.PSObject.Properties.Name -notcontains "Relations") {
                $candidate | Add-Member -NotePropertyName Relations -NotePropertyValue @()
            }
            $reverse = [pscustomobject]@{
                candidateFindingId = $recordId
                relation = [string]$relation.relation
                candidateStatus = $recordStatus
                confidence = [string]$relation.confidence
                rationale = [string]$relation.rationale
                evidence = @($relation.evidence)
            }
            $candidate.Relations = @(
                @($candidate.Relations | Where-Object {
                    [string]$_.candidateFindingId -ne $recordId
                }) + $reverse
            )
        }
    }
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
    $State.ActiveStrategy = $null
    $State.LastFixerResult = $null
    if ($State.PSObject.Properties.Name -contains "PendingCommit") {
        $State.PendingCommit = $null
    }
    else {
        $State | Add-Member -NotePropertyName PendingCommit -NotePropertyValue $null
    }
    $State.ArchitectureRevision = 0
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

    foreach ($finding in $Findings) {
        $finding.Status = "resolved"
        $finding.Verification = $VerificationResult
        $finding.ResolutionCommit = $Commit
        $finding.FixerThreadId = ""
        $finding.UpdatedAt = [DateTimeOffset]::UtcNow.ToString("O")
    }
    Write-ReviewLoopLedger -Path $LedgerPath -Ledger $Ledger | Out-Null
    $State.CurrentHead = $Commit
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
    } -RunRoot $RunRoot -ClusterId $ClusterId -TimeoutSeconds 300
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
        Set-ReviewLoopCheckpoint -State $State -StatePath $StatePath -Stage "commit_pending"
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
        Invoke-ReviewLoopGitStep -Name "Commit" -Arguments @(
            "update-ref", "HEAD", $candidate[0].ToLowerInvariant(), $preHead
        ) -RepoPath $RepoPath -RunRoot $RunRoot -ClusterId $State.ActiveClusterId | Out-Null
        $head = Get-ReviewLoopGitValue -RepoPath $RepoPath -Arguments @("rev-parse", "HEAD")
    }

    $parent = Get-ReviewLoopGitValue -RepoPath $RepoPath -Arguments @("rev-parse", "HEAD^")
    $tree = Get-ReviewLoopGitValue -RepoPath $RepoPath -Arguments @("rev-parse", "HEAD^{tree}")
    $subject = Get-ReviewLoopGitValue -RepoPath $RepoPath -Arguments @("show", "-s", "--format=%s", "HEAD")
    if ($parent -ne $preHead -or $tree -ne [string]$pending.ExpectedTree -or
        $subject -ne [string]$pending.Message -or -not (Test-ReviewLoopGitClean -RepoPath $RepoPath)) {
        throw "The resulting commit does not match the verified pending commit."
    }
    if ([bool](Get-ReviewLoopObjectProperty -Object $pending -Name "NeedsCurrentGates" -Default $false)) {
        $snapshot = Get-ReviewLoopRepositorySnapshot -RepoPath $RepoPath
        $gates = Invoke-ReviewLoopHostGates `
            -RepoPath $RepoPath -HostGates @($Config.HostGates) `
            -RunRoot $RunRoot -ClusterId $State.ActiveClusterId
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
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$RunRoot,
        [Parameter(Mandatory = $true)][object]$ExpectedSnapshot
    )

    Assert-ReviewLoopExecutionUnchanged -Config $Config
    $gates = Invoke-ReviewLoopHostGates `
        -RepoPath $RepoPath `
        -HostGates @($Config.HostGates) `
        -RunRoot $RunRoot `
        -ClusterId $State.ActiveClusterId
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
    $title = [regex]::Replace([string]$Findings[0].Title, "\s+", " ").Trim()
    $message = "$($Config.CommitMessagePrefix): $title"
    if ($message.Length -gt 200) { $message = $message.Substring(0, 200).TrimEnd() }
    foreach ($finding in $Findings) {
        $finding.Verification = $Verification.Result
    }
    Write-ReviewLoopLedger -Path $LedgerPath -Ledger $Ledger | Out-Null
    $State | Add-Member -Force -NotePropertyName PendingCommit -NotePropertyValue ([pscustomobject]@{
        PreHead = $head
        PatchFingerprint = [string]$ExpectedSnapshot.Fingerprint
        ExpectedTree = ""
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
        -Message "Fixer: $($FixerCall.StructuredResult.outcome) · $($changedPaths.Count) changed paths$(if ($changedPaths.Count -gt 0) { ': ' + ($changedPaths -join ', ') } else { '' })" `
        -Kind $(if ([string]$FixerCall.StructuredResult.outcome -eq "changed") { "Success" } else { "Warning" })

    if ([string]$FixerCall.StructuredResult.outcome -eq "blocked") {
        return [pscustomobject]@{
            Completed = $false
            Feedback = "The previous fixer reported blocked: $($FixerCall.StructuredResult.summary)"
        }
    }

    Set-ReviewLoopCheckpoint -State $State -StatePath $StatePath -Stage "testing"
    $tests = Invoke-ReviewLoopTargetedTests `
        -FixerResult $FixerCall.StructuredResult `
        -RepoPath $RepoPath `
        -RunRoot $RunRoot `
        -ClusterId $State.ActiveClusterId `
        -Attempt $Attempt
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
    $targetedCommand = "$($targetedTest.filePath) $(@($targetedTest.arguments) -join ' ')".Trim()
    $targetedState = if ([bool]$FixerCall.StructuredResult.testExecution.Passed) { "passed" } else { "failed" }
    $regressionCount = @($verification.Result.regressions).Count
    Write-ReviewLoopStatus `
        -Message "Verifier: $($verification.Result.verdict) · Patch $($verification.Result.patchSafety) ($regressionCount regressions) · Confidence $($verification.Result.confidence) · $($verification.Basis) · Test $targetedState$(if (-not [string]::IsNullOrWhiteSpace($targetedCommand)) { ': ' + $targetedCommand } else { '' })" `
        -Kind $(if ($verification.Accepted) { "Success" } else { "Warning" })
    Set-ReviewLoopCheckpoint -State $State -StatePath $StatePath -Stage "verified"
    Assert-ReviewLoopRepositoryUnchanged `
        -RepoPath $RepoPath -Snapshot $worktreeSnapshot -Operation "Read-only verification"

    if ($verification.Accepted) {
        $completion = Complete-ReviewLoopFix `
            -Config $Config -State $State -StatePath $StatePath `
            -Ledger $Ledger -LedgerPath $LedgerPath -Findings $Findings `
            -Verification $verification -RepoPath $RepoPath -RunRoot $RunRoot `
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

    if ([string]$verification.Result.verdict -eq "obsolete" -and
        [string]$verification.Result.patchSafety -eq "safe" -and
        (Test-ReviewLoopGitClean -RepoPath $RepoPath)) {
        Set-ReviewLoopFindingsStatus -Findings $Findings -Status "superseded"
        foreach ($finding in $Findings) {
            $finding.Verification = $verification.Result
        }
        Write-ReviewLoopLedger -Path $LedgerPath -Ledger $Ledger | Out-Null
        Clear-ReviewLoopActiveCluster -State $State -StatePath $StatePath -Stage "finding_obsolete"
        return [pscustomobject]@{ Completed = $true; Feedback = "" }
    }

    return [pscustomobject]@{
        Completed = $false
        RetrySameAttempt = $false
        Feedback = "Verifier returned a non-accepted result. Address every supported issue together. Structured result: $(ConvertTo-ReviewLoopJsonCompact $verification.Result)"
    }
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
    if ($Recover -and [string]::IsNullOrWhiteSpace($threadId) -and $attempt -gt 0 -and
        $null -eq (Get-ReviewLoopObjectProperty -Object $State -Name "ActiveRoleCall") -and
        -not (Test-ReviewLoopGitClean -RepoPath $RepoPath)) {
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
            Stop-ReviewLoopBlocked -Message "The interrupted fixer changed the worktree without a resumable Codex thread."
        }
        $feedback = "The previous fixer process was interrupted. Inspect and preserve correct partial work before completing the same attempt."
    }

    while ($retryCurrentAttempt -or $attempt -lt [int]$Config.MaxFixAttempts) {
        if (-not $retryCurrentAttempt) {
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
        Write-ReviewLoopStatus -Message "Fixer · attempt $attempt/$($Config.MaxFixAttempts) · $threadMode" -Kind Progress
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
        Write-ReviewLoopLedger -Path $LedgerPath -Ledger $Ledger | Out-Null
        Set-ReviewLoopCheckpoint -State $State -StatePath $StatePath -Stage $(if ($fixer.Success) {
            "fix_attempted"
        } else { "fixing" })
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
    }

    $reason = "Finding cluster remained open after $attempt fix attempts."
    return Complete-ReviewLoopBlockedCluster `
        -State $State `
        -StatePath $StatePath `
        -Ledger $Ledger `
        -LedgerPath $LedgerPath `
        -Findings $Findings `
        -RepoPath $RepoPath `
        -RunRoot $RunRoot `
        -Attempt $attempt `
        -Reason $reason
}

function Get-ReviewLoopArchitectureTrigger {
    param([Parameter(Mandatory = $true)][object[]]$Findings)

    $relations = @($Findings | ForEach-Object { @($_.Relations) } | Where-Object {
        [string]$_.confidence -eq "high"
    })
    $regressions = @($relations | Where-Object {
        [string]$_.relation -eq "regression_from_fix" -and
        [string]$_.candidateStatus -in @("active", "resolved")
    })
    $relatedRelations = @($relations | Where-Object {
        [string]$_.relation -in @(
            "same_root_cause",
            "same_contract_different_edge",
            "regression_from_fix"
        ) -and
        [string]$_.candidateStatus -in @("active", "resolved")
    })
    $verifiedRecurrence = @($Findings | Where-Object {
        [int](Get-ReviewLoopObjectProperty `
            -Object $_ -Name "VerifiedRecurrenceCount" -Default 0) -gt 0
    }).Count -gt 0
    $multipleActive = $Findings.Count -gt 1
    $recommended = $multipleActive -or $regressions.Count -gt 0 -or $verifiedRecurrence
    $reason = if ($multipleActive) {
        "multiple_active_findings"
    }
    elseif ($regressions.Count -gt 0) {
        "regression_from_fix"
    }
    elseif ($verifiedRecurrence) {
        "verified_recurrence"
    }
    else {
        "bounded_point_fix"
    }
    $relation = if ($regressions.Count -gt 0) {
        "regression_from_fix"
    }
    elseif ($multipleActive -and $relatedRelations.Count -gt 0) {
        [string]$relatedRelations[0].relation
    }
    elseif ($multipleActive -or $verifiedRecurrence) {
        "same_root_cause"
    }
    else {
        "independent"
    }

    return [pscustomobject]@{
        ArchitectureRecommended = $recommended
        Relation = $relation
        Reason = $reason
        Confidence = "high"
        Rationale = if ($recommended) {
            "Architecture pre-gate matched '$reason'."
        }
        else {
            "One active finding has no verified recurrence or regression from a prior fix."
        }
        Relations = $relations
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
    $State.ArchitectureRevision = 0
    Set-ReviewLoopCheckpoint -State $State -StatePath $StatePath -Stage "cluster_selected"
    Write-ReviewLoopRule -Title "Finding-Cluster $($State.ActiveClusterId)" -Kind Review
    Write-ReviewLoopStatus -Message "$($Findings.Count) Finding(s): $(@($Findings | ForEach-Object { $_.Title }) -join '; ')" -Kind Review

    $trigger = Get-ReviewLoopArchitectureTrigger -Findings $Findings
    $relations = @($trigger.Relations)
    $adjudication = "reused Luna + Sol$(if (@($relations | Where-Object { [string]$_.rationale -match 'adjudicat' }).Count -gt 0) { ' + Terra' } else { '' })"
    $triggerKind = if ($trigger.ArchitectureRecommended) { "Architecture" } elseif ($trigger.Confidence -eq "high") { "Info" } else { "Warning" }
    Write-ReviewLoopStatus `
        -Message "Trigger: $($trigger.Relation) · $($trigger.Reason) · Confidence $($trigger.Confidence) · $adjudication" `
        -Kind $triggerKind
    $strategy = $null
    if ($trigger.ArchitectureRecommended) {
        Write-ReviewLoopStatus -Message "Semantic architecture trigger confirmed; creating a proposal and independent critique." -Kind Architecture
        $strategy = Invoke-ReviewLoopArchitectureGate `
            -Config $Config -State $State -StatePath $StatePath -RepoPath $RepoPath `
            -Speed $Speed -RunRoot $RunRoot -Findings $Findings -Trigger $trigger -CodexPath $CodexPath
        $scope = Get-ReviewLoopArchitectureScope $strategy.Proposal
        $strategyKind = if ($strategy.Approved) { "Architecture" } else { "Warning" }
        Write-ReviewLoopStatus `
            -Message "Architecture: $($strategy.Proposal.recommendation) · $($scope.PathCount) paths ($($scope.ProductionPathCount) production) · $(if ($strategy.Approved) { 'approved' } else { 'limited to point fix' })" `
            -Kind $strategyKind
        if ($null -ne $strategy.Critique) {
            Write-ReviewLoopStatus -Message "Critic: $($strategy.Critique.decision) · Confidence $($strategy.Critique.confidence)" -Kind Architecture -Indent 1
        }
    }
    $State.ActiveStrategy = $strategy
    Set-ReviewLoopCheckpoint -State $State -StatePath $StatePath -Stage "strategy_ready"

    Invoke-ReviewLoopFixWorkflow `
        -Config $Config -State $State -StatePath $StatePath `
        -Ledger $Ledger -LedgerPath $LedgerPath -Findings $Findings `
        -RepoPath $RepoPath -Speed $Speed -RunRoot $RunRoot -CodexPath $CodexPath | Out-Null
}

function Get-ReviewLoopSemanticFindingGroups {
    param([Parameter(Mandatory = $true)][object]$Ledger)

    $open = @(Get-ReviewLoopOpenFindings -Ledger $Ledger)
    $byId = @{}
    foreach ($finding in $open) {
        $byId[[string]$finding.Id] = $finding
    }
    $visited = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $groups = [System.Collections.Generic.List[object]]::new()
    foreach ($seed in $open) {
        if (-not $visited.Add([string]$seed.Id)) {
            continue
        }
        $queue = [System.Collections.Generic.Queue[object]]::new()
        $group = [System.Collections.Generic.List[object]]::new()
        $queue.Enqueue($seed)
        while ($queue.Count -gt 0) {
            $current = $queue.Dequeue()
            [void]$group.Add($current)
            $neighborIds = @(
                @($open | Where-Object {
                    [string]$_.ClusterId -eq [string]$current.ClusterId
                } | ForEach-Object { [string]$_.Id })
                @($current.Relations | Where-Object {
                    [string]$_.confidence -eq "high" -and
                    [string]$_.relation -in @(
                        "same_root_cause",
                        "same_contract_different_edge",
                        "regression_from_fix"
                    )
                } | ForEach-Object { [string]$_.candidateFindingId })
            ) | Sort-Object -Unique
            foreach ($neighborId in $neighborIds) {
                if ($byId.ContainsKey($neighborId) -and $visited.Add($neighborId)) {
                    $queue.Enqueue($byId[$neighborId])
                }
            }
        }
        [void]$groups.Add([pscustomobject]@{ Findings = $group.ToArray() })
    }
    return $groups.ToArray()
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

    foreach ($group in @(Get-ReviewLoopSemanticFindingGroups -Ledger $Ledger)) {
        $activeGroup = @($group.Findings | Where-Object {
            [string]$_.Status -in @("pending", "open", "fixing")
        })
        if ($activeGroup.Count -eq 0) {
            continue
        }
        Invoke-ReviewLoopCluster `
            -Config $Config -State $State -StatePath $StatePath `
            -Ledger $Ledger -LedgerPath $LedgerPath `
            -Findings $activeGroup -RepoPath $RepoPath -Speed $Speed `
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
        "testing", "tested", "test_failed", "verified", "gate_failed"
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

function Invoke-ReviewLoopCore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [string]$ConfigPath = "",
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
    $repo = Get-ReviewLoopRepositoryRoot -RepoPath $RepoPath
    $resolvedConfigPath = Resolve-ReviewLoopConfigPath -RepoPath $repo -ConfigPath $ConfigPath
    try {
        $config = Import-ReviewLoopConfig -ConfigPath $resolvedConfigPath -RepoPath $repo
        Assert-ReviewLoopConfigValues -Config $config
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
    $executionFingerprint = Get-ReviewLoopExecutionFingerprint -ConfigPath $resolvedConfigPath
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
    if (-not $NewRun) {
        $active = Get-ReviewLoopLatestActiveStatePath -ProfileRoot $paths.StableProfileRoot
        if (-not [string]::IsNullOrWhiteSpace($active)) {
            $statePath = $active
            $state = Read-ReviewLoopState -Path $statePath
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
    elseif ([string]$state.Speed -ne $Speed) {
        throw (New-ReviewLoopFailureException `
            -Message "The existing checkpoint was started with speed '$($state.Speed)', but this command selected '$Speed'. A run cannot change speed while it is being resumed." `
            -NextSteps @(
                "Resume the existing checkpoint by running the same command with -Speed $($state.Speed)."
                "To use -Speed $Speed instead, make the worktree clean and start with -Speed $Speed -NewRun."
            ))
    }

    if ($resumed) {
        Assert-ReviewLoopResumeInvariant `
            -State $state `
            -RepoPath $repo `
            -ReviewBase ([string]$config.ReviewBase) `
            -SkipHead
    }
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
        $state.Status = "running"
        $state.ExitCode = 0
        $state.BlockedReason = ""
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
    if ($resumedFromFailure -and (Test-ReviewLoopOutputLevel -Minimum balanced)) {
        Write-ReviewLoopStatus -Message "Resuming the previous failed checkpoint at stage '$($state.Stage)'." -Kind Warning
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
            if (
                [int]$state.ReviewCycle -ge [int]$config.MaxReviewCycles -and
                [string]$state.Stage -ne "reviewing"
            ) {
                break
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
            }
            $state.CurrentHead = Get-ReviewLoopGitValue -RepoPath $repo -Arguments @("rev-parse", "HEAD")
            Set-ReviewLoopCheckpoint -State $state -StatePath $statePath -Stage "reviewing"
            Write-ReviewLoopRule -Title ("Review cycle {0}/{1}" -f $state.ReviewCycle, $config.MaxReviewCycles) -Kind Review
            $review = Invoke-ReviewLoopReview `
                -Config $config -State $state -StatePath $statePath -Ledger $ledger -RepoPath $repo `
                -Speed $Speed -RunRoot $paths.RunRoot -CodexPath $CodexPath
            $adjudicatedFindings = @()
            if (@($review.Result.findings).Count -gt 0) {
                $adjudicatedFindings = @(Resolve-ReviewLoopFindingRelations `
                    -Config $config -State $state -StatePath $statePath -Ledger $ledger `
                    -Findings @($review.Result.findings) -RepoPath $repo -Speed $Speed `
                    -RunRoot $paths.RunRoot -CodexPath $CodexPath)
            }
            if ($adjudicatedFindings.Count -gt 0) {
                Merge-ReviewLoopFindings `
                    -Ledger $ledger -Findings $adjudicatedFindings `
                    -ReviewId $review.ReviewId -Head $review.Head | Out-Null
                Add-ReviewLoopReciprocalRelations -Ledger $ledger -Findings $adjudicatedFindings
            }
            Write-ReviewLoopLedger -Path $paths.LedgerPath -Ledger $ledger | Out-Null
            Set-ReviewLoopCheckpoint -State $state -StatePath $statePath -Stage "reviewed"
            if ((Get-ReviewLoopGitValue -RepoPath $repo -Arguments @("rev-parse", "HEAD")) -ne
                [string]$review.Head -or -not (Test-ReviewLoopGitClean -RepoPath $repo)) {
                Stop-ReviewLoopBlocked -Message "Repository state changed after review and before its result could be applied."
            }

            $blocked = @($ledger.Findings | Where-Object { [string]$_.Status -eq "blocked" })
            $open = @(Get-ReviewLoopOpenFindings -Ledger $ledger)
            if ([string]$review.Result.classification -eq "findings" -and $open.Count -eq 0) {
                Stop-ReviewLoopBlocked -Message "Reviewer returned findings, but the ledger exposed none as open; refusing a zero-progress review loop."
            }
            if ($open.Count -eq 0 -and [string]$review.Result.classification -eq "clean") {
                if ($blocked.Count -gt 0) {
                    Stop-ReviewLoopBlocked -Message "All independent work completed, but $($blocked.Count) finding(s) remain blocked on the current HEAD."
                }
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
                    Write-ReviewLoopCompletionSummary `
                        -Cycles $state.ReviewCycle `
                        -CleanPasses "$($state.CleanPasses)/$($config.CleanPassesRequired)" `
                        -RunRoot $paths.RunRoot `
                        -LedgerPath $paths.LedgerPath `
                        -TranscriptPath $terminalPath
                    return [pscustomobject]@{
                        Status = $state.Status
                        ExitCode = 0
                        Reason = ""
                        NextSteps = @()
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
            Invoke-ReviewLoopOpenClusters `
                -Config $config -State $state -StatePath $statePath `
                -Ledger $ledger -LedgerPath $paths.LedgerPath `
                -RepoPath $repo -Speed $Speed -RunRoot $paths.RunRoot -CodexPath $CodexPath
        }
        Stop-ReviewLoopBlocked -Message "Maximum review cycle count $($config.MaxReviewCycles) reached."
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
    $lock = $null
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
        if ($null -ne $lock) {
            $lock.Dispose()
        }
    }
}
