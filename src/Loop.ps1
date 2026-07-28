function Test-ReviewLoopStateCanResume {
    param([Parameter(Mandatory = $true)][object]$State)

    if ([string]$State.Status -eq "running") {
        return $true
    }
    return (
        [string]$State.Status -eq "failed" -and
        (
            [string]$State.Stage -ne "stopped" -or
            @($State.ActiveFindingIds).Count -gt 0
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
    $baseKey = (Get-ReviewLoopSha256 $ReviewBaseCommit).Substring(0, 8)
    $profileRoot = Join-Path $logRoot "$($Config.Name)-$repositoryKey-$safeBranch-$baseKey"
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
        throw "Checkpoint repository '$($State.RepoPath)' does not match '$RepoPath'."
    }
    $branch = Get-ReviewLoopGitValue -RepoPath $RepoPath -Arguments @("branch", "--show-current")
    if ([string]$State.Branch -ne $branch) {
        throw "Checkpoint branch '$($State.Branch)' does not match current branch '$branch'."
    }
    if ([string]$State.ReviewBase -ne $ReviewBase) {
        throw "Checkpoint review base '$($State.ReviewBase)' does not match '$ReviewBase'."
    }
    if (-not $SkipHead) {
        $head = Get-ReviewLoopGitValue -RepoPath $RepoPath -Arguments @("rev-parse", "HEAD")
        if ([string]$State.CurrentHead -ne $head) {
            throw "Checkpoint HEAD '$($State.CurrentHead)' does not match current HEAD '$head'."
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
            throw "Host gate '$($gate.Name)' executable '$($gate.FilePath)' could not be resolved: $($_.Exception.Message)"
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

function ConvertFrom-ReviewLoopTargetedCommand {
    param([Parameter(Mandatory = $true)][string]$Command)

    $parsed = ConvertFrom-ReviewLoopDirectCommand -Command $Command
    if ($null -eq $parsed -or @($parsed.Arguments | Where-Object {
        $_ -match "[`r`n]" -or $_ -in @("--help", "-h", "--version")
    }).Count -gt 0) {
        return $null
    }

    $runner = [System.IO.Path]::GetFileNameWithoutExtension([string]$parsed.FilePath).ToLowerInvariant()
    $arguments = @($parsed.Arguments)
    $isTest = switch ($runner) {
        "dotnet" { $arguments.Count -gt 0 -and $arguments[0] -in @("test", "vstest") }
        { $_ -in @("pytest", "ctest", "phpunit") } { $true }
        { $_ -in @("cargo", "go", "swift", "npm", "pnpm", "yarn", "bun") } {
            $arguments.Count -gt 0 -and $arguments[0] -eq "test"
        }
        { $_ -in @("mvn", "mvnw", "gradle", "gradlew") } {
            @($arguments | Where-Object { $_ -match "(?i)^test($|[^a-z])" }).Count -gt 0
        }
        { $_ -in @("python", "python3") } {
            $arguments.Count -gt 1 -and $arguments[0] -eq "-m" -and $arguments[1] -eq "pytest"
        }
        default { $false }
    }
    if (-not $isTest) {
        return $null
    }
    return $parsed
}

function Test-ReviewLoopTrustedTargetedExecutable {
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$FilePath
    )

    if (-not [System.IO.Path]::IsPathRooted($FilePath) -and
        -not $FilePath.Contains("\") -and -not $FilePath.Contains("/")) {
        return $true
    }
    try {
        $resolved = Resolve-ReviewLoopHostExecutable -RepoPath $RepoPath -FilePath $FilePath
        $relative = [System.IO.Path]::GetRelativePath($RepoPath, $resolved).Replace("\", "/")
        if ($relative -eq ".." -or $relative.StartsWith("../")) {
            return $false
        }
        & git -C $RepoPath cat-file -e "HEAD:$relative" 2>$null
        if ($LASTEXITCODE -ne 0) {
            return $false
        }
        & git -C $RepoPath diff --quiet HEAD -- $relative 2>$null
        return $LASTEXITCODE -eq 0
    }
    catch {
        return $false
    }
}

function Invoke-ReviewLoopTargetedTests {
    param(
        [Parameter(Mandatory = $true)][object]$FixerResult,
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$RunRoot,
        [Parameter(Mandatory = $true)][string]$ClusterId,
        [Parameter(Mandatory = $true)][int]$Attempt
    )

    $tests = @($FixerResult.targetedTests)
    if ($tests.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$tests[0].command)) {
        return [pscustomobject]@{
            Success = $false
            Feedback = "The fixer must return exactly one non-empty targeted test command."
            Results = @()
        }
    }

    $test = $tests[0]
    $command = [string]$test.command
    $parsedCommand = ConvertFrom-ReviewLoopTargetedCommand -Command $command
    if ($null -eq $parsedCommand -or
        -not (Test-ReviewLoopTrustedTargetedExecutable `
            -RepoPath $RepoPath -FilePath ([string]$parsedCommand.FilePath))) {
        $test.passed = $false
        $test.evidence = "Rejected by the orchestrator: use one direct recognized test runner; repository-local wrappers must be tracked and unchanged."
        return [pscustomobject]@{
            Success = $false
            Feedback = "$($test.evidence) Command: $command"
            Results = @()
        }
    }

    $gate = @{
        Name = "Targeted regression test"
        FilePath = [string]$parsedCommand.FilePath
        Arguments = @($parsedCommand.Arguments)
    }
    $result = Invoke-ReviewLoopHostGate `
        -RepoPath $RepoPath `
        -Gate $gate `
        -RunRoot $RunRoot `
        -ClusterId "$ClusterId-fix-$Attempt"
    $test.passed = [bool]$result.Success
    $test.evidence = if ($result.Success) {
        "Executed by the orchestrator; exit code 0. Log: $($result.LogPath)"
    }
    else {
        "Executed by the orchestrator; exit code $($result.ExitCode). Log: $($result.LogPath)"
    }
    return [pscustomobject]@{
        Success = [bool]$result.Success
        Feedback = if ($result.Success) { "" } else {
            $excerpt = @(Get-ReviewLoopTextExcerpt -Text $result.Output -MaxLines 6) -join " "
            "Targeted regression test failed. Command: $command. $($test.evidence) $excerpt"
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
    $untracked = @(& git -C $RepoPath ls-files --others --exclude-standard 2>$null)
    if ($LASTEXITCODE -ne 0) {
        throw "git ls-files --others failed."
    }
    return @(
        (@($tracked) + @($untracked)) |
            ForEach-Object { ([string]$_).Trim().Replace("\", "/") } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )
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

function Assert-ReviewLoopFixScope {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][object[]]$Findings,
        [Parameter(Mandatory = $true)][string[]]$ChangedPaths
    )

    $strategy = $State.ActiveStrategy
    $allowed = if ($null -ne $strategy -and [bool]$strategy.Approved) {
        @($strategy.Proposal.steps | ForEach-Object {
            ConvertTo-ReviewLoopCanonicalText ([string]$_.path)
        } | Sort-Object -Unique)
    }
    else {
        @($Findings | ForEach-Object {
            ConvertTo-ReviewLoopCanonicalText ([string]$_.Path)
            @($_.FixPaths) | ForEach-Object {
                ConvertTo-ReviewLoopCanonicalText ([string]$_)
            }
        } | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        } | Sort-Object -Unique)
    }
    $allowImplicitTestPaths = $null -eq $strategy -or -not [bool]$strategy.Approved
    $unexpected = @($ChangedPaths | Where-Object {
        $path = ConvertTo-ReviewLoopCanonicalText $_
        $isTestPath = $path -match '(^|/)(tests?|specs?|__tests__)(/|$)' -or
            (Split-Path -Leaf $path) -match '(?i)(^test[_-]|[_-]test\.|\.tests?\.|\.spec\.)'
        $path -notin $allowed -and -not ($allowImplicitTestPaths -and $isTestPath)
    })
    if ($unexpected.Count -gt 0) {
        $scopeName = if ($null -ne $strategy -and [bool]$strategy.Approved) {
            "approved architecture proposal"
        }
        else {
            "active finding paths"
        }
        Stop-ReviewLoopBlocked -Message "Fixer changed path(s) outside the ${scopeName}: $($unexpected -join ', ')."
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
    if ($changedPaths.Count -gt [int]$Config.MaxArchitecturePaths) {
        Stop-ReviewLoopBlocked -Message "Fixer changed $($changedPaths.Count) paths; the hard limit is $($Config.MaxArchitecturePaths)."
    }
    Assert-ReviewLoopFixScope -State $State -Findings $Findings -ChangedPaths $changedPaths
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
        return [pscustomobject]@{ Completed = $false; Feedback = $tests.Feedback }
    }
    Set-ReviewLoopCheckpoint -State $State -StatePath $StatePath -Stage "tested"

    $verification = Invoke-ReviewLoopVerifier `
        -Config $Config -State $State -StatePath $StatePath -RepoPath $RepoPath `
        -Speed $Speed -RunRoot $RunRoot -Findings $Findings -FixerCall $FixerCall `
        -Attempt $Attempt -CodexPath $CodexPath
    $targetedCommand = [string]$verification.Result.targetedTest.command
    $targetedState = if ([bool]$verification.Result.targetedTest.passed) { "passed" } else { "failed" }
    Write-ReviewLoopStatus `
        -Message "Verifier: $($verification.Result.verdict) · Confidence $($verification.Result.confidence) · $($verification.Basis) · Test $targetedState$(if (-not [string]::IsNullOrWhiteSpace($targetedCommand)) { ': ' + $targetedCommand } else { '' })" `
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
        return [pscustomobject]@{ Completed = $false; Feedback = $completion.Feedback }
    }

    if ([string]$verification.Result.verdict -eq "obsolete" -and (Test-ReviewLoopGitClean -RepoPath $RepoPath)) {
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
        Feedback = "Verifier returned $($verification.Result.verdict) with $($verification.Result.confidence) confidence: $($verification.Result.rationale)"
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
    if ($Recover -and [string]::IsNullOrWhiteSpace($threadId) -and $attempt -gt 0) {
        $threadId = Get-ReviewLoopFixerThreadIdFromLog `
            -RunRoot $RunRoot -ClusterId $State.ActiveClusterId -Attempt $attempt
    }
    if (-not [string]::IsNullOrWhiteSpace($threadId)) {
        foreach ($finding in $Findings) { $finding.FixerThreadId = $threadId }
        Write-ReviewLoopLedger -Path $LedgerPath -Ledger $Ledger | Out-Null
    }

    $feedback = "None."
    $retryCurrentAttempt = $Recover -and $attempt -gt 0
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
            $retryCurrentAttempt = $false
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
        $fixer = Invoke-ReviewLoopFixer `
            -Config $Config -State $State -StatePath $StatePath -RepoPath $RepoPath `
            -Speed $Speed -RunRoot $RunRoot -Findings $Findings -Strategy $State.ActiveStrategy `
            -Attempt $attempt -ThreadId $threadId -CodexPath $CodexPath -Feedback $feedback
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
    }

    $reason = "Finding cluster remained open after $attempt fix attempts."
    Set-ReviewLoopFindingsStatus -Findings $Findings -Status "blocked" -Reason $reason
    Write-ReviewLoopLedger -Path $LedgerPath -Ledger $Ledger | Out-Null
    Stop-ReviewLoopBlocked -Message $reason
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

    $groups = @(Get-ReviewLoopOpenFindings -Ledger $Ledger |
        Group-Object ClusterId | Sort-Object Name)
    foreach ($group in $groups) {
        $activeGroup = @($group.Group | Where-Object {
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

function Get-ReviewLoopFixerThreadIdFromLog {
    param(
        [Parameter(Mandatory = $true)][string]$RunRoot,
        [Parameter(Mandatory = $true)][string]$ClusterId,
        [Parameter(Mandatory = $true)][int]$Attempt
    )

    $pattern = "$ClusterId-fix-$Attempt-*.jsonl"
    foreach ($file in @(Get-ChildItem -LiteralPath $RunRoot -Filter $pattern -File |
        Sort-Object LastWriteTime -Descending)) {
        foreach ($line in @(Get-Content -LiteralPath $file.FullName -TotalCount 50)) {
            try {
                $event = $line | ConvertFrom-Json -ErrorAction Stop
                if ([string]$event.type -eq "thread.started" -and
                    -not [string]::IsNullOrWhiteSpace([string]$event.thread_id)) {
                    return [string]$event.thread_id
                }
            }
            catch {
                # Ignore malformed or partially flushed final lines.
            }
        }
    }
    return ""
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
    Assert-ReviewLoopConfigValues -Config $config
    Assert-ReviewLoopHostGatePreflight -Config $config -RepoPath $repo
    $resolvedReviewBase = Get-ReviewLoopGitValue `
        -RepoPath $repo -Arguments @("rev-parse", "--verify", "$($config.ReviewBase)^{commit}")
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
        throw "A resumed run keeps its global speed '$($state.Speed)'; requested speed was '$Speed'."
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
        if ([string]$state.Stage -eq "stopped" -and @($state.ActiveFindingIds).Count -gt 0) {
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
        -TranscriptPath $terminalPath

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
    Write-ReviewLoopRule -Title "Codex Review Loop" -Kind Progress
    Write-ReviewLoopKeyValue -Name "Repository" -Value $repo
    Write-ReviewLoopKeyValue -Name "Branch" -Value ([string]$state.Branch)
    Write-ReviewLoopKeyValue -Name "Review-Base" -Value ([string]$config.ReviewBase)
    $baseCommitText = [string]$state.ReviewBaseCommit
    $baseShort = if ($baseCommitText.Length -gt 10) {
        $baseCommitText.Substring(0, 10)
    }
    else {
        $baseCommitText
    }
    Write-ReviewLoopKeyValue -Name "Base commit" -Value $baseShort
    Write-ReviewLoopKeyValue -Name "HEAD" -Value $shortHead
    Write-ReviewLoopKeyValue -Name "Speed" -Value $Speed
    Write-ReviewLoopKeyValue -Name "Output" -Value "$OutputMode · heartbeat ${HeartbeatSeconds}s · $ColorMode"
    Write-ReviewLoopKeyValue -Name "Profile" -Value "$($config.Name) · $resolvedConfigPath"
    Write-ReviewLoopKeyValue -Name "Run" -Value "$($state.RunId) ($(if ($resumed) { 'resumed' } else { 'new' }))"
    Write-ReviewLoopKeyValue -Name "Checkpoint" -Value $statePath
    Write-ReviewLoopKeyValue -Name "Ledger" -Value $paths.LedgerPath
    Write-ReviewLoopKeyValue -Name "Terminal-Log" -Value $terminalPath
    if ($resumedFromFailure) {
        Write-ReviewLoopStatus -Message "Resuming the previous failed checkpoint at stage '$($state.Stage)'." -Kind Warning
    }
    if ($executionChanged) {
        Write-ReviewLoopStatus -Message "Tool or profile changed; completed model work will be requalified before any commit." -Kind Warning
    }

    try {
        if ($resumed) {
            Complete-ReviewLoopPendingCommit `
                -Config $config -State $state -StatePath $statePath -Ledger $ledger `
                -LedgerPath $paths.LedgerPath -RepoPath $repo -RunRoot $paths.RunRoot | Out-Null
            Assert-ReviewLoopResumeInvariant `
                -State $state -RepoPath $repo -ReviewBase ([string]$config.ReviewBase)
        }
        Get-ReviewLoopGitValue -RepoPath $repo -Arguments @(
            "rev-parse", "--verify", "$($state.ReviewBaseCommit)^{commit}"
        ) | Out-Null
        $blockedAtStart = @($ledger.Findings | Where-Object { [string]$_.Status -eq "blocked" })
        if ($blockedAtStart.Count -gt 0) {
            Stop-ReviewLoopBlocked -Message "Ledger contains $($blockedAtStart.Count) blocked findings."
        }
        $resumedCluster = Resume-ReviewLoopInterruptedFix `
            -Config $config -State $state -StatePath $statePath `
            -Ledger $ledger -LedgerPath $paths.LedgerPath `
            -RepoPath $repo -Speed $Speed -RunRoot $paths.RunRoot -CodexPath $CodexPath
        if (-not $resumedCluster -and $resumed -and
            [string]$state.Stage -eq "reviewed" -and
            @(Get-ReviewLoopOpenFindings -Ledger $ledger).Count -gt 0) {
            Write-ReviewLoopStatus -Message "Continuing the reviewed findings without spending another review call." -Kind Warning
            Invoke-ReviewLoopOpenClusters `
                -Config $config -State $state -StatePath $statePath `
                -Ledger $ledger -LedgerPath $paths.LedgerPath `
                -RepoPath $repo -Speed $Speed -RunRoot $paths.RunRoot -CodexPath $CodexPath
        }
        while (
            [int]$state.ReviewCycle -lt [int]$config.MaxReviewCycles -or
            [string]$state.Stage -eq "reviewing"
        ) {
            if (-not (Test-ReviewLoopGitClean -RepoPath $repo)) {
                throw "Worktree is not clean outside a resumable fix step."
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
            Merge-ReviewLoopFindings `
                -Ledger $ledger -Findings @($review.Result.findings) `
                -ReviewId $review.ReviewId -Head $review.Head | Out-Null
            Write-ReviewLoopLedger -Path $paths.LedgerPath -Ledger $ledger | Out-Null
            Set-ReviewLoopCheckpoint -State $state -StatePath $statePath -Stage "reviewed"
            if ((Get-ReviewLoopGitValue -RepoPath $repo -Arguments @("rev-parse", "HEAD")) -ne
                [string]$review.Head -or -not (Test-ReviewLoopGitClean -RepoPath $repo)) {
                Stop-ReviewLoopBlocked -Message "Repository state changed after review and before its result could be applied."
            }

            $blocked = @($ledger.Findings | Where-Object { [string]$_.Status -eq "blocked" })
            if ($blocked.Count -gt 0) {
                Stop-ReviewLoopBlocked -Message "Ledger contains $($blocked.Count) blocked findings."
            }
            $open = @(Get-ReviewLoopOpenFindings -Ledger $ledger)
            if ([string]$review.Result.classification -eq "findings" -and $open.Count -eq 0) {
                Stop-ReviewLoopBlocked -Message "Reviewer returned findings, but the ledger exposed none as open; refusing a zero-progress review loop."
            }
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
            Invoke-ReviewLoopOpenClusters `
                -Config $config -State $state -StatePath $statePath `
                -Ledger $ledger -LedgerPath $paths.LedgerPath `
                -RepoPath $repo -Speed $Speed -RunRoot $paths.RunRoot -CodexPath $CodexPath
        }
        Stop-ReviewLoopBlocked -Message "Maximum review cycle count $($config.MaxReviewCycles) reached."
    }
    catch {
        $message = $_.Exception.Message
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

    $repo = Get-ReviewLoopRepositoryRoot -RepoPath $RepoPath
    $lockPath = Get-ReviewLoopGitValue -RepoPath $repo -Arguments @(
        "rev-parse", "--git-path", "codex-review-loop.lock"
    )
    if (-not [System.IO.Path]::IsPathRooted($lockPath)) {
        $lockPath = Join-Path $repo $lockPath
    }
    $lock = $null
    try {
        try {
            $lock = [System.IO.FileStream]::new(
                $lockPath,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None)
        }
        catch {
            throw "A review loop is already running for '$repo'."
        }
        return Invoke-ReviewLoopCore @PSBoundParameters
    }
    finally {
        if ($null -ne $lock) {
            $lock.Dispose()
        }
    }
}
