Set-StrictMode -Version Latest

function New-ReviewLoopFailureException {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [AllowEmptyCollection()][string[]]$NextSteps = @(),
        [ValidateRange(0, 100)][int]$RecommendedStepCount = 1,
        [ValidateSet("failed", "blocked")][string]$Status = "failed"
    )

    $exception = [System.InvalidOperationException]::new($Message)
    $exception.Data["ReviewLoopStatus"] = $Status
    if ($NextSteps.Count -gt 0) {
        $exception.Data["ReviewLoopNextSteps"] = @($NextSteps)
        $exception.Data["ReviewLoopRecommendedStepCount"] = [Math]::Min(
            $NextSteps.Count,
            $RecommendedStepCount)
    }
    return $exception
}

function Get-ReviewLoopFailureNextSteps {
    param(
        [Parameter(Mandatory = $true)][System.Exception]$Exception,
        [ValidateSet("startup", "failed", "blocked")][string]$Context = "failed"
    )

    if ($Exception.Data.Contains("ReviewLoopNextSteps")) {
        return @(
            $Exception.Data["ReviewLoopNextSteps"] |
                ForEach-Object { [string]$_ } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
    }

    return @(switch ($Context) {
        "startup" {
            "Correct the reported startup problem, then run the same command again."
            "Use -Help to review parameters and examples if the selected repository, profile, or option is unclear."
            "If the problem concerns an old checkpoint and the current repository state is intentional, make the worktree clean and use -NewRun."
        }
        "blocked" {
            "Inspect the transcript, ledger, and current Git diff before deciding which work to preserve."
            "Make the worktree clean without blindly discarding changes."
            "Start with -NewRun to requalify the current HEAD and give blocked findings a fresh bounded attempt budget."
        }
        default {
            "Correct the reported problem, then run the same command again to resume from the last safe checkpoint."
            "If the repository was changed intentionally, first make the worktree clean and use -NewRun instead."
            "If the same failure repeats without any state change, preserve the transcript and ledger and report the defect instead of editing checkpoint files."
        }
    })
}

function Get-ReviewLoopRecommendedStepCount {
    param(
        [Parameter(Mandatory = $true)][System.Exception]$Exception,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Steps
    )

    if ($Steps.Count -eq 0) {
        return 0
    }
    if ($Exception.Data.Contains("ReviewLoopRecommendedStepCount")) {
        return [Math]::Min(
            $Steps.Count,
            [Math]::Max(0, [int]$Exception.Data["ReviewLoopRecommendedStepCount"]))
    }
    return 1
}

function Stop-ReviewLoopBlocked {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [AllowEmptyCollection()][string[]]$NextSteps = @(),
        [ValidateRange(0, 100)][int]$RecommendedStepCount = 1
    )

    throw (New-ReviewLoopFailureException `
        -Message $Message `
        -NextSteps $NextSteps `
        -RecommendedStepCount $RecommendedStepCount)
}

function Resolve-ReviewLoopPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [switch]$MustExist
    )

    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    $absolute = [System.IO.Path]::GetFullPath($expanded)
    if ($MustExist -and -not (Test-Path -LiteralPath $absolute)) {
        throw (New-ReviewLoopFailureException `
            -Message "The requested path does not exist: $absolute" `
            -NextSteps @(
                "Check the path for typing errors and confirm that the drive or network location is available."
                "Run the same command again with an existing path."
            ))
    }
    return $absolute
}

function Test-ReviewLoopRepositoryRelativePath {
    param([AllowNull()][string]$Path)

    $value = ([string]$Path).Trim()
    return -not [string]::IsNullOrWhiteSpace($value) -and
        -not [System.IO.Path]::IsPathRooted($value) -and
        $value -notmatch '(^|[\\/])\.\.([\\/]|$)' -and
        $value -notmatch '^~([\\/]|$)' -and
        $value -notmatch '^[a-z][a-z0-9_.-]*:{1,2}'
}

function ConvertTo-ReviewLoopCanonicalText {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return ""
    }

    return ([string]$Value).Trim().Replace("\", "/").ToLowerInvariant()
}

function Get-ReviewLoopSha256 {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $hash = [System.Security.Cryptography.SHA256]::HashData($bytes)
    return [Convert]::ToHexString($hash).ToLowerInvariant()
}

function ConvertTo-ReviewLoopRedactedText {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) {
        return ""
    }

    $redacted = $Text
    $redacted = [regex]::Replace($redacted, "(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{12,}", "Bearer [redacted]")
    $redacted = [regex]::Replace($redacted, "\bsk-[A-Za-z0-9_-]{12,}", "[redacted-secret]")
    $redacted = [regex]::Replace(
        $redacted,
        '(?i)("(?:access[_-]?token|refresh[_-]?token|id[_-]?token|authorization|api[_-]?key|client[_-]?secret|secret|password)"\s*:\s*")((?:\\.|[^"\\])*)(")',
        '$1[redacted]$3'
    )
    $redacted = [regex]::Replace(
        $redacted,
        "(?i)\b(access[_-]?token|refresh[_-]?token|id[_-]?token|authorization|api[_-]?key|client[_-]?secret|secret|password)(\s*[:=]\s*)[^\s,;""'{}\[\]]+",
        '$1$2[redacted]'
    )
    return $redacted
}

function Write-ReviewLoopUtf8File {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowNull()][string]$Content
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, ($Content ?? ""), [System.Text.UTF8Encoding]::new($false))
}

function Write-ReviewLoopAtomicJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )

    $absolute = Resolve-ReviewLoopPath -Path $Path
    $parent = Split-Path -Parent $absolute
    [System.IO.Directory]::CreateDirectory($parent) | Out-Null

    $temporary = Join-Path $parent (".{0}.{1}.tmp" -f ([System.IO.Path]::GetFileName($absolute)), [Guid]::NewGuid().ToString("N"))
    try {
        $json = $Value | ConvertTo-Json -Depth 50
        Write-ReviewLoopUtf8File -Path $temporary -Content $json
        [System.IO.File]::Move($temporary, $absolute, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporary) {
            [System.IO.File]::Delete($temporary)
        }
    }
}

function Read-ReviewLoopJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$Optional
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        if ($Optional) {
            return $null
        }
        throw "JSON file is missing: $Path"
    }

    return Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
}

function ConvertTo-ReviewLoopPowerShellLiteral {
    param([AllowNull()][string]$Value)
    return "'$(([string]$Value).Replace("'", "''"))'"
}

function Get-ReviewLoopComparablePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    $absolute = [System.IO.Path]::GetFullPath($expanded)
    return [System.IO.Path]::TrimEndingDirectorySeparator($absolute)
}

function Get-ReviewLoopRepositoryRoot {
    param([Parameter(Mandatory = $true)][string]$RepoPath)

    $candidate = Resolve-ReviewLoopPath -Path $RepoPath -MustExist
    $root = (& git -C $candidate rev-parse --show-toplevel 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($root)) {
        throw (New-ReviewLoopFailureException `
            -Message "The selected RepoPath is not inside a Git worktree: $candidate" `
            -NextSteps @(
                "Pass the repository folder as the first argument or with -RepoPath."
                "Run git status in that folder to confirm it is a usable Git worktree, then try again."
            ))
    }
    return Get-ReviewLoopComparablePath -Path $root
}

function Test-ReviewLoopSamePath {
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )

    $leftPath = Get-ReviewLoopComparablePath -Path $Left
    $rightPath = Get-ReviewLoopComparablePath -Path $Right
    if ((Test-Path -LiteralPath $leftPath -PathType Container) -and
        (Test-Path -LiteralPath $rightPath -PathType Container)) {
        $leftRoot = (& git -C $leftPath rev-parse --show-toplevel 2>$null | Out-String).Trim()
        $leftExit = $LASTEXITCODE
        $rightRoot = (& git -C $rightPath rev-parse --show-toplevel 2>$null | Out-String).Trim()
        if ($leftExit -eq 0 -and $LASTEXITCODE -eq 0) {
            $leftPath = Get-ReviewLoopComparablePath -Path $leftRoot
            $rightPath = Get-ReviewLoopComparablePath -Path $rightRoot
        }
    }
    $comparison = if ($IsWindows) {
        [System.StringComparison]::OrdinalIgnoreCase
    }
    else {
        [System.StringComparison]::Ordinal
    }
    return [string]::Equals(
        $leftPath,
        $rightPath,
        $comparison)
}

function Assert-ReviewLoopConfigRepository {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][string]$RepoPath
    )

    $config = Import-PowerShellDataFile -LiteralPath $ConfigPath
    if (-not $config.ContainsKey("RepositoryPath") -or
        [string]::IsNullOrWhiteSpace([string]$config.RepositoryPath)) {
        return
    }
    $configured = [string]$config.RepositoryPath
    if (-not [System.IO.Path]::IsPathRooted(
        [Environment]::ExpandEnvironmentVariables($configured))) {
        throw (New-ReviewLoopFailureException `
            -Message "Profile '$ConfigPath' contains a relative RepositoryPath. RepositoryPath must be absolute." `
            -NextSteps @(
                "Set RepositoryPath in that profile to the full Git repository path."
                "Run the same command again, or select a different profile with -ConfigPath."
            ))
    }
    if (-not (Test-ReviewLoopSamePath -Left $configured -Right $RepoPath)) {
        throw (New-ReviewLoopFailureException `
            -Message "Profile '$ConfigPath' belongs to repository '$configured', not '$RepoPath'." `
            -NextSteps @(
                "Use this profile with '$configured', or select the correct profile for '$RepoPath' with -ConfigPath."
                "If the profile binding is wrong, correct RepositoryPath in the profile and run the command again."
            ))
    }
}

function Find-ReviewLoopProfileByRepository {
    param(
        [Parameter(Mandatory = $true)][string]$ProfilesRoot,
        [Parameter(Mandatory = $true)][string]$RepoPath
    )

    if (-not (Test-Path -LiteralPath $ProfilesRoot -PathType Container)) {
        return ""
    }
    $matches = [System.Collections.Generic.List[string]]::new()
    foreach ($profile in @(Get-ChildItem -LiteralPath $ProfilesRoot -Filter "*.psd1" -File)) {
        try {
            $config = Import-PowerShellDataFile -LiteralPath $profile.FullName
        }
        catch {
            Write-ReviewLoopStatus `
                -Message "Skipping invalid profile while matching the repository: $($profile.FullName)" `
                -Kind Warning
            continue
        }
        if (-not $config.ContainsKey("RepositoryPath")) {
            continue
        }
        $configured = [string]$config.RepositoryPath
        if ([string]::IsNullOrWhiteSpace($configured) -or
            -not [System.IO.Path]::IsPathRooted(
                [Environment]::ExpandEnvironmentVariables($configured))) {
            continue
        }
        if (Test-ReviewLoopSamePath -Left $configured -Right $RepoPath) {
            [void]$matches.Add($profile.FullName)
        }
    }
    if ($matches.Count -gt 1) {
        throw (New-ReviewLoopFailureException `
            -Message "Multiple tool-local profiles belong to '$RepoPath': $($matches -join ', ')" `
            -NextSteps @(
                "Choose one explicitly with -ConfigPath."
                "To restore automatic discovery, change or remove the duplicate profiles so exactly one remains bound to this repository."
            ))
    }
    if ($matches.Count -eq 1) {
        return Get-ReviewLoopComparablePath -Path $matches[0]
    }
    return ""
}

function Get-ReviewLoopNextProfilePath {
    param(
        [Parameter(Mandatory = $true)][string]$ProfilesRoot,
        [Parameter(Mandatory = $true)][string]$RepositoryName
    )

    [System.IO.Directory]::CreateDirectory($ProfilesRoot) | Out-Null
    $safeName = [regex]::Replace($RepositoryName, "[^A-Za-z0-9._-]+", "-").Trim("-", ".", "_")
    if ([string]::IsNullOrWhiteSpace($safeName)) {
        $safeName = "repository"
    }
    $namePattern = "^{0}-(\d+)$" -f [regex]::Escape($safeName)
    $numbers = @(Get-ChildItem -LiteralPath $ProfilesRoot -Filter "*.psd1" -File |
        Where-Object { $_.BaseName -match $namePattern } |
        ForEach-Object {
            if ($_.BaseName -match $namePattern) {
                [int64]$Matches[1]
            }
        })
    $next = if ($numbers.Count -eq 0) {
        1L
    }
    else {
        [int64](($numbers | Measure-Object -Maximum).Maximum) + 1L
    }
    do {
        $path = Join-Path $ProfilesRoot ("{0}-{1:D3}.psd1" -f $safeName, $next)
        $next++
    } while (Test-Path -LiteralPath $path)
    return $path
}

function Get-ReviewLoopDefaultReviewBase {
    param([Parameter(Mandatory = $true)][string]$RepoPath)

    $originHead = (& git -C $RepoPath symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($originHead)) {
        return $originHead
    }

    foreach ($candidate in @("origin/main", "origin/master", "main", "master", "HEAD^", "HEAD")) {
        & git -C $RepoPath rev-parse --verify "$candidate^{commit}" *> $null
        if ($LASTEXITCODE -eq 0) {
            return $candidate
        }
    }

    return "HEAD"
}

function New-ReviewLoopProfile {
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $repo = Get-ReviewLoopRepositoryRoot -RepoPath $RepoPath
    $absolute = Resolve-ReviewLoopPath -Path $Path
    $name = Split-Path -Leaf $repo
    $reviewBase = Get-ReviewLoopDefaultReviewBase -RepoPath $repo
    $logRoot = ".\runs"
    $solution = @(Get-ChildItem -LiteralPath $repo -File | Where-Object {
        $_.Extension -in @(".sln", ".slnx")
    })

    $hostGates = [System.Collections.Generic.List[string]]::new()
    if ($solution.Count -eq 1) {
        $solutionArgument = ".\$($solution[0].Name)"
        [void]$hostGates.Add(@"
        @{
            Name = 'Solution tests'
            FilePath = 'dotnet'
            Arguments = @('test', $(ConvertTo-ReviewLoopPowerShellLiteral $solutionArgument))
        }
"@)
    }
    [void]$hostGates.Add(@"
        @{
            Name = 'Git diff check'
            FilePath = 'git'
            Arguments = @('diff', '--check')
        }
"@)

    $content = @"
@{
    # Profile display name. It is also used as the subdirectory for the ledger and runs.
    Name = $(ConvertTo-ReviewLoopPowerShellLiteral $name)

    # Canonical Git root bound to this profile. It prevents collisions between equally named repositories.
    RepositoryPath = $(ConvertTo-ReviewLoopPowerShellLiteral $repo)

    # Git revision against which Codex reviews the branch, for example origin/main, origin/master, or main.
    ReviewBase = $(ConvertTo-ReviewLoopPowerShellLiteral $reviewBase)

    # Optional supplemental developer instructions for the native Reviewer.
    # -ReviewerInstructions wins when explicitly passed, including an empty value.
    # The effective value is fixed for the complete script invocation.
    ReviewerInstructions = ''

    # Directory for the ledger, checkpoints, JSONL logs, and result logs.
    # Relative paths are resolved against the review loop script directory.
    LogRoot = $(ConvertTo-ReviewLoopPowerShellLiteral $logRoot)

    # Recommended: 2-3 clean passes on an unchanged HEAD.
    CleanPassesRequired = 2

    # Recommended: 6-30 native review cycles per script invocation. Reaching
    # the limit pauses without blocking findings. Every new script invocation
    # resumes the checkpoint with a fresh cycle counter.
    MaxReviewCycles = 12

    # Run one repository lessons-learned analysis before completion after this
    # many verified loop commits. Zero disables the additional analysis.
    # This value is reloaded when the clean-pass gate is reached.
    LessonsLearnedCommitThreshold = 6

    # By default, an accepted lessons-learned solution is the final cycle.
    # Set this to true to require the normal clean native reviews again after
    # a real lessons-learned commit. The value is captured when analysis starts.
    ReviewAfterLessonsLearnedCommit = `$false

    # Recommended: 2-5 fixer calls before discarding the rejected round and
    # starting a new native Codex review. This value is reloaded at safe
    # boundaries while a run is active.
    MaxFixAttempts = 2

    # Recommended: 15-120 minutes without real child-process output. Zero or a
    # negative value disables inactivity termination. Changes apply to the next
    # role, targeted test, or host gate that starts.
    InactivityTimeoutMinutes = 30

    # Model-selected targeted tests must not change the verified fixer worktree.
    # Use Mode = 'RestoreAll' only when every regular file side effect from the
    # targeted-test window is disposable and the repository is used exclusively.
    TargetedTestRepositoryChanges = @{
        Mode = 'Fail'
    }

    # When false, verified changes are staged and the loop waits for a manual
    # commit or for AutoCommit to be enabled before continuing.
    AutoCommit = `$true

    # Reloaded for future commits while a run is active.
    CommitMessagePrefix = 'Review-Loop'

    # Host gates run after successful finding verification and before the commit.
    # A gate consists of Name, FilePath, and an Arguments list. Add project-specific
    # tests as additional hashtables. RepositoryChanges is optional. Its Mode is
    # Fail (default), RestoreMatching with a PathRegex list, or RestoreAll.
    # RestoreAll assumes exclusive repository use while the gate runs and is
    # substantially broader than an exact RestoreMatching allowlist.
    HostGates = @(
$($hostGates -join "`n")
    )

    # Role settings:
    # - Model: a model ID supported by the installed Codex CLI.
    # - Thinking: low, medium, high, xhigh, or max.
    # ReviewClassifier is a mechanical helper used only when the native review
    # text is ambiguous. Existing profiles without it use gpt-5.6-luna/low.
    # Existing profiles without LessonsLearned use gpt-5.6-sol/high.
    # Settings are reloaded at safe role boundaries while a run is active.
    Roles = @{
        Reviewer = @{ Model = 'gpt-5.6-sol'; Thinking = 'high' }
        ReviewClassifier = @{ Model = 'gpt-5.6-luna'; Thinking = 'low' }
        LessonsLearned = @{ Model = 'gpt-5.6-sol'; Thinking = 'high' }
        Architect = @{ Model = 'gpt-5.6-sol'; Thinking = 'high' }
        Fixer = @{ Model = 'gpt-5.6-sol'; Thinking = 'high' }
        Verifier = @{ Model = 'gpt-5.6-sol'; Thinking = 'low' }
    }
}
"@

    Write-ReviewLoopUtf8File -Path $absolute -Content $content
    Write-ReviewLoopStatus -Message "Profile created: $absolute" -Kind Success
    return $absolute
}

function Resolve-ReviewLoopConfigPath {
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [string]$ConfigPath = "",
        [string]$ProfilesRoot = ""
    )

    $repo = Get-ReviewLoopRepositoryRoot -RepoPath $RepoPath
    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
        $explicit = Resolve-ReviewLoopPath -Path $ConfigPath
        if (Test-Path -LiteralPath $explicit -PathType Leaf) {
            Assert-ReviewLoopConfigRepository -ConfigPath $explicit -RepoPath $repo
            return $explicit
        }
        return New-ReviewLoopProfile -RepoPath $repo -Path $explicit
    }

    foreach ($candidate in @(
        (Join-Path $repo ".codex-review-loop.psd1"),
        (Join-Path $repo ".codex\review-loop.psd1")
    )) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $local = Resolve-ReviewLoopPath -Path $candidate
            Assert-ReviewLoopConfigRepository -ConfigPath $local -RepoPath $repo
            return $local
        }
    }

    $profileDirectory = if ([string]::IsNullOrWhiteSpace($ProfilesRoot)) {
        Join-Path $script:ModuleRoot "profiles"
    }
    else {
        Resolve-ReviewLoopPath -Path $ProfilesRoot
    }
    $matched = Find-ReviewLoopProfileByRepository `
        -ProfilesRoot $profileDirectory `
        -RepoPath $repo
    if (-not [string]::IsNullOrWhiteSpace($matched)) {
        return $matched
    }
    $profilePath = Get-ReviewLoopNextProfilePath `
        -ProfilesRoot $profileDirectory `
        -RepositoryName (Split-Path -Leaf $repo)
    return New-ReviewLoopProfile -RepoPath $repo -Path $profilePath
}

function Import-ReviewLoopConfig {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [string]$RepoPath = ""
    )

    $absolute = Resolve-ReviewLoopPath -Path $ConfigPath -MustExist
    if (-not [string]::IsNullOrWhiteSpace($RepoPath)) {
        Assert-ReviewLoopConfigRepository `
            -ConfigPath $absolute `
            -RepoPath (Get-ReviewLoopRepositoryRoot -RepoPath $RepoPath)
    }
    $config = Import-PowerShellDataFile -LiteralPath $absolute
    $required = @("Name", "ReviewBase", "LogRoot", "Roles", "HostGates")
    foreach ($name in $required) {
        if (-not $config.ContainsKey($name)) {
            throw "Configuration does not contain '$name': $absolute"
        }
    }
    if ([string]::IsNullOrWhiteSpace([string]$config.LogRoot)) {
        throw "Configuration does not contain a valid LogRoot: $absolute"
    }

    $defaults = @{
        CleanPassesRequired = 2
        MaxReviewCycles = 12
        LessonsLearnedCommitThreshold = 6
        ReviewAfterLessonsLearnedCommit = $false
        MaxFixAttempts = 2
        InactivityTimeoutMinutes = 30
        TargetedTestRepositoryChanges = @{ Mode = "Fail" }
        AutoCommit = $true
        CommitMessagePrefix = "Review-Loop"
        ReviewerInstructions = ""
    }
    foreach ($entry in $defaults.GetEnumerator()) {
        if (-not $config.ContainsKey($entry.Key)) {
            $config[$entry.Key] = $entry.Value
        }
    }
    $configuredLogRoot = [Environment]::ExpandEnvironmentVariables([string]$config.LogRoot)
    $config.LogRoot = if ([System.IO.Path]::IsPathRooted($configuredLogRoot)) {
        [System.IO.Path]::GetFullPath($configuredLogRoot)
    }
    else {
        [System.IO.Path]::GetFullPath((Join-Path $script:ModuleRoot $configuredLogRoot))
    }

    return $config
}

function Assert-ReviewLoopConfigValues {
    param([Parameter(Mandatory = $true)][hashtable]$Config)

    foreach ($name in @("Name", "ReviewBase", "CommitMessagePrefix")) {
        $value = [string]$Config[$name]
        if ([string]::IsNullOrWhiteSpace($value) -or $value -match "[`r`n]") {
            throw "Configuration value '$name' must be one non-empty line."
        }
    }
    if ([string]$Config.Name -in @(".", "..") -or
        ([string]$Config.Name).IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) {
        throw "Configuration value 'Name' must be a safe directory name."
    }
    if ($Config.Roles -isnot [System.Collections.IDictionary]) {
        throw "Configuration value 'Roles' must be a hashtable."
    }
    if ($Config.ReviewerInstructions -isnot [string]) {
        throw "Configuration value 'ReviewerInstructions' must be a string."
    }
    if ($Config.ReviewAfterLessonsLearnedCommit -isnot [bool]) {
        throw "Configuration value 'ReviewAfterLessonsLearnedCommit' must be a boolean."
    }
    $targetedChanges = $Config.TargetedTestRepositoryChanges
    if ($targetedChanges -isnot [System.Collections.IDictionary]) {
        throw "Configuration value 'TargetedTestRepositoryChanges' must be a hashtable."
    }
    foreach ($key in @($targetedChanges.Keys)) {
        if ([string]$key -ne "Mode") {
            throw "TargetedTestRepositoryChanges contains unsupported key '$key'."
        }
    }
    if (-not $targetedChanges.Contains("Mode") -or
        [string]$targetedChanges.Mode -notin @("Fail", "RestoreAll")) {
        throw "TargetedTestRepositoryChanges Mode must be 'Fail' or 'RestoreAll'."
    }

    foreach ($name in @(
        "CleanPassesRequired",
        "MaxReviewCycles",
        "LessonsLearnedCommitThreshold",
        "MaxFixAttempts",
        "InactivityTimeoutMinutes"
    )) {
        try {
            $value = [int]$Config[$name]
        }
        catch {
            throw "Configuration value '$name' must be an integer."
        }
        $Config[$name] = $value
    }
    $roles = @(
        "Reviewer", "ReviewClassifier", "LessonsLearned",
        "Architect", "Fixer", "Verifier"
    )
    foreach ($role in $roles) {
        $roleConfig = Get-ReviewLoopRoleConfig -Config $Config -Role $role
        if ([string]$roleConfig.Thinking -notin @("low", "medium", "high", "xhigh", "max")) {
            throw "Role '$role' contains unsupported Thinking '$($roleConfig.Thinking)'."
        }
    }

    foreach ($gate in @($Config.HostGates)) {
        if ($gate -isnot [System.Collections.IDictionary]) {
            throw "Every HostGates entry must be a hashtable."
        }
        foreach ($name in @("Name", "FilePath", "Arguments")) {
            if (-not $gate.Contains($name)) {
                throw "Host gate is missing '$name'."
            }
        }
        if ([string]::IsNullOrWhiteSpace([string]$gate.Name) -or
            [string]::IsNullOrWhiteSpace([string]$gate.FilePath)) {
            throw "Host gate Name and FilePath must be non-empty."
        }
        if ($gate.Arguments -is [string] -or $null -eq $gate.Arguments) {
            throw "Host gate '$($gate.Name)' Arguments must be a list."
        }
        if (-not $gate.Contains("RepositoryChanges")) {
            continue
        }
        $changes = $gate.RepositoryChanges
        if ($changes -isnot [System.Collections.IDictionary]) {
            throw "Host gate '$($gate.Name)' RepositoryChanges must be a hashtable."
        }
        foreach ($key in @($changes.Keys)) {
            if ([string]$key -notin @("Mode", "PathRegex")) {
                throw "Host gate '$($gate.Name)' RepositoryChanges contains unsupported key '$key'."
            }
        }
        if (-not $changes.Contains("Mode")) {
            throw "Host gate '$($gate.Name)' RepositoryChanges is missing 'Mode'."
        }
        $mode = [string]$changes.Mode
        if ($mode -notin @("Fail", "RestoreMatching", "RestoreAll")) {
            throw "Host gate '$($gate.Name)' RepositoryChanges Mode '$mode' is unsupported."
        }
        $hasPathRegex = $changes.Contains("PathRegex")
        if ($mode -ne "RestoreMatching" -and $hasPathRegex) {
            throw "Host gate '$($gate.Name)' RepositoryChanges PathRegex is only valid with Mode 'RestoreMatching'."
        }
        if ($mode -ne "RestoreMatching") {
            continue
        }
        if (-not $hasPathRegex -or $null -eq $changes.PathRegex -or
            $changes.PathRegex -is [string]) {
            throw "Host gate '$($gate.Name)' RestoreMatching requires PathRegex to be a non-empty list."
        }
        $patterns = @($changes.PathRegex)
        if ($patterns.Count -eq 0) {
            throw "Host gate '$($gate.Name)' RestoreMatching requires at least one PathRegex entry."
        }
        foreach ($patternValue in $patterns) {
            if ($patternValue -isnot [string] -or
                [string]::IsNullOrWhiteSpace([string]$patternValue)) {
                throw "Host gate '$($gate.Name)' RepositoryChanges PathRegex entries must be non-empty strings."
            }
            try {
                [void][regex]::new(
                    [string]$patternValue,
                    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
                        [System.Text.RegularExpressions.RegexOptions]::CultureInvariant,
                    [TimeSpan]::FromSeconds(1))
            }
            catch {
                throw "Host gate '$($gate.Name)' contains invalid RepositoryChanges PathRegex '$patternValue': $($_.Exception.Message)"
            }
        }
    }
}

function Get-ReviewLoopHostGateRepositoryChanges {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Gate)

    if (-not $Gate.Contains("RepositoryChanges")) {
        return [pscustomobject]@{ Mode = "Fail"; PathRegex = @() }
    }
    return [pscustomobject]@{
        Mode = [string]$Gate.RepositoryChanges.Mode
        PathRegex = if ($Gate.RepositoryChanges.Contains("PathRegex")) {
            @($Gate.RepositoryChanges.PathRegex | ForEach-Object { [string]$_ })
        }
        else {
            @()
        }
    }
}

$script:ReviewLoopLiveConfigKeys = @(
    "CleanPassesRequired",
    "MaxReviewCycles",
    "LessonsLearnedCommitThreshold",
    "ReviewAfterLessonsLearnedCommit",
    "MaxFixAttempts",
    "InactivityTimeoutMinutes",
    "TargetedTestRepositoryChanges",
    "AutoCommit",
    "CommitMessagePrefix",
    "HostGates",
    "Roles"
)

function Get-ReviewLoopInactivityTimeoutSeconds {
    param([Parameter(Mandatory = $true)][hashtable]$Config)

    $minutes = if ($Config.ContainsKey("InactivityTimeoutMinutes")) {
        [long]$Config.InactivityTimeoutMinutes
    }
    else {
        30L
    }
    if ($minutes -le 0) {
        return 0L
    }
    if ($minutes -gt [long]::MaxValue / 60L) {
        return [long]::MaxValue
    }
    return $minutes * 60L
}

function ConvertTo-ReviewLoopFingerprintData {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return "null"
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $entries = foreach ($key in @($Value.Keys | ForEach-Object {
            [string]$_
        } | Sort-Object)) {
            $encodedKey = ConvertTo-Json -InputObject $key -Compress
            $encodedValue = ConvertTo-ReviewLoopFingerprintData -Value $Value[$key]
            "${encodedKey}:${encodedValue}"
        }
        return "{$($entries -join ',')}"
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $items = foreach ($item in $Value) {
            ConvertTo-ReviewLoopFingerprintData -Value $item
        }
        return "[$($items -join ',')]"
    }
    return ConvertTo-Json -InputObject $Value -Compress
}

function Get-ReviewLoopExecutionProfileText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [AllowEmptyString()][string]$ReviewerInstructions = ""
    )

    $profile = Import-PowerShellDataFile -LiteralPath (
        Resolve-ReviewLoopPath -Path $ConfigPath -MustExist)
    $effectiveReviewerInstructions = if ($PSBoundParameters.ContainsKey("ReviewerInstructions")) {
        $ReviewerInstructions
    }
    elseif ($profile.ContainsKey("ReviewerInstructions")) {
        [string]$profile.ReviewerInstructions
    }
    else {
        ""
    }
    $executionSettings = @{}
    foreach ($key in $profile.Keys) {
        if ([string]$key -notin $script:ReviewLoopLiveConfigKeys) {
            $executionSettings[$key] = $profile[$key]
        }
    }
    $executionSettings["ReviewerInstructions"] = $effectiveReviewerInstructions
    return ConvertTo-ReviewLoopFingerprintData -Value $executionSettings
}

function ConvertTo-ReviewLoopCommandDisplayToken {
    param([AllowEmptyString()][string]$Value)

    if ($Value.Length -eq 0) {
        return "''"
    }
    if ($Value -match '[\s''"]') {
        return "'{0}'" -f $Value.Replace("'", "''")
    }
    return $Value
}

function ConvertTo-ReviewLoopHostGateDisplayText {
    param([Parameter(Mandatory = $true)][object]$Gate)

    $name = [string]$Gate.Name
    $filePath = [string]$Gate.FilePath
    $arguments = @($Gate.Arguments)
    $tokens = @($filePath) + @($arguments | ForEach-Object { [string]$_ })
    $command = @($tokens | ForEach-Object {
        ConvertTo-ReviewLoopCommandDisplayToken -Value $_
    }) -join " "
    return "${name}: $command"
}

function Write-ReviewLoopHostGateConfigChange {
    param(
        [AllowNull()][object]$Before,
        [AllowNull()][object]$After
    )

    Write-ReviewLoopStatus -Message "HostGates:" -Kind Muted -Indent 1
    foreach ($side in @(
        [pscustomobject]@{ Name = "Before"; Value = $Before },
        [pscustomobject]@{ Name = "After"; Value = $After }
    )) {
        Write-ReviewLoopStatus -Message "$($side.Name):" -Kind Muted -Indent 2
        $gates = @($side.Value)
        if ($gates.Count -eq 0) {
            Write-ReviewLoopStatus -Message "(none)" -Kind Muted -Indent 3
            continue
        }
        foreach ($gate in $gates) {
            Write-ReviewLoopStatus `
                -Message (ConvertTo-ReviewLoopHostGateDisplayText -Gate $gate) `
                -Kind Muted `
                -Indent 3
        }
    }
}

function Write-ReviewLoopRoleConfigChange {
    param(
        [AllowNull()][object]$Before,
        [AllowNull()][object]$After
    )

    $beforeRoles = if ($Before -is [System.Collections.IDictionary]) { $Before } else { @{} }
    $afterRoles = if ($After -is [System.Collections.IDictionary]) { $After } else { @{} }
    $roleNames = @(@($beforeRoles.Keys) + @($afterRoles.Keys) | ForEach-Object {
        [string]$_
    } | Sort-Object -Unique)
    $changedRoles = [System.Collections.Generic.List[string]]::new()
    foreach ($roleName in $roleNames) {
        $beforeRole = if ($beforeRoles.Contains($roleName)) { $beforeRoles[$roleName] } else { $null }
        $afterRole = if ($afterRoles.Contains($roleName)) { $afterRoles[$roleName] } else { $null }
        if ((ConvertTo-ReviewLoopFingerprintData -Value $beforeRole) -eq
            (ConvertTo-ReviewLoopFingerprintData -Value $afterRole)) {
            continue
        }
        $beforeText = if ($null -eq $beforeRole) {
            "not configured"
        }
        else {
            "$($beforeRole.Model)/$($beforeRole.Thinking)"
        }
        $afterText = if ($null -eq $afterRole) {
            "not configured"
        }
        else {
            "$($afterRole.Model)/$($afterRole.Thinking)"
        }
        [void]$changedRoles.Add("${roleName}: $beforeText -> $afterText")
    }

    Write-ReviewLoopStatus -Message "Roles:" -Kind Muted -Indent 1
    if ($changedRoles.Count -eq 0) {
        Write-ReviewLoopStatus -Message "updated" -Kind Muted -Indent 2
        return
    }
    foreach ($change in $changedRoles) {
        Write-ReviewLoopStatus -Message $change -Kind Muted -Indent 2
    }
}

function Write-ReviewLoopLiveConfigChanges {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Changes
    )

    if ($Changes.Count -eq 0) {
        return
    }
    Write-ReviewLoopStatus -Message "Reloaded live profile settings" -Kind Info
    foreach ($change in $Changes) {
        $name = [string]$change.Name
        switch ($name) {
            "CommitMessagePrefix" {
                Write-ReviewLoopStatus -Message "CommitMessagePrefix updated" -Kind Muted -Indent 1
            }
            "TargetedTestRepositoryChanges" {
                $beforeMode = if ($change.Before -is [System.Collections.IDictionary]) {
                    [string]$change.Before.Mode
                }
                else {
                    "not configured"
                }
                $afterMode = if ($change.After -is [System.Collections.IDictionary]) {
                    [string]$change.After.Mode
                }
                else {
                    "not configured"
                }
                Write-ReviewLoopStatus `
                    -Message "TargetedTestRepositoryChanges: $beforeMode -> $afterMode" `
                    -Kind Muted -Indent 1
            }
            "HostGates" {
                Write-ReviewLoopHostGateConfigChange -Before $change.Before -After $change.After
            }
            "Roles" {
                Write-ReviewLoopRoleConfigChange -Before $change.Before -After $change.After
            }
            default {
                $beforeText = if ($name -eq "AutoCommit") {
                    if ([bool]$change.Before) { "enabled" } else { "disabled" }
                }
                elseif ($null -eq $change.Before) { "not configured" }
                else { [string]$change.Before }
                $afterText = if ($name -eq "AutoCommit") {
                    if ([bool]$change.After) { "enabled" } else { "disabled" }
                }
                elseif ($null -eq $change.After) { "not configured" }
                else { [string]$change.After }
                Write-ReviewLoopStatus `
                    -Message "${name}: $beforeText -> $afterText" `
                    -Kind Muted `
                    -Indent 1
            }
        }
    }
}

function Update-ReviewLoopLiveConfig {
    param([Parameter(Mandatory = $true)][hashtable]$Config)

    if (-not $Config.ContainsKey("__ConfigPath")) {
        return
    }

    $latest = $null
    $lastError = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $latest = Import-ReviewLoopConfig -ConfigPath ([string]$Config.__ConfigPath)
            Assert-ReviewLoopConfigValues -Config $latest
            break
        }
        catch {
            $lastError = $_
            if ($attempt -lt 3) {
                Start-Sleep -Milliseconds 100
            }
        }
    }
    if ($null -eq $latest) {
        throw (New-ReviewLoopFailureException `
            -Message "The active profile could not be reloaded: $($lastError.Exception.Message)" `
            -NextSteps @(
                "Correct the active profile and keep it unchanged until it is a valid PowerShell data file."
                "Run the same command again to resume from the last safe checkpoint."
            ))
    }

    $changes = [System.Collections.Generic.List[object]]::new()
    foreach ($key in $script:ReviewLoopLiveConfigKeys) {
        $beforeValue = $Config[$key]
        $afterValue = $latest[$key]
        $beforeFingerprint = ConvertTo-ReviewLoopFingerprintData -Value $beforeValue
        $afterFingerprint = ConvertTo-ReviewLoopFingerprintData -Value $afterValue
        if ($beforeFingerprint -eq $afterFingerprint) {
            continue
        }
        $Config[$key] = $afterValue
        [void]$changes.Add([pscustomobject]@{
            Name = $key
            Before = $beforeValue
            After = $afterValue
        })
    }
    Write-ReviewLoopLiveConfigChanges -Changes $changes.ToArray()
}

function Get-ReviewLoopExecutionFingerprint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [AllowEmptyString()][string]$ReviewerInstructions = ""
    )

    $files = [System.Collections.Generic.List[string]]::new()
    foreach ($name in @(
        "codex-review-loop.ps1",
        "CodexReviewLoop.psd1",
        "CodexReviewLoop.psm1"
    )) {
        [void]$files.Add((Join-Path $script:ModuleRoot $name))
    }
    foreach ($directory in @("src", "prompts", "schemas")) {
        foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $script:ModuleRoot $directory) -File |
            Sort-Object FullName)) {
            [void]$files.Add($file.FullName)
        }
    }

    $records = foreach ($file in $files) {
        $absolute = Resolve-ReviewLoopPath -Path $file -MustExist
        $relative = [System.IO.Path]::GetRelativePath($script:ModuleRoot, $absolute).Replace("\", "/")
        "$relative`n$(Get-ReviewLoopSha256 ([System.IO.File]::ReadAllText($absolute)))"
    }
    $profilePath = Resolve-ReviewLoopPath -Path $ConfigPath -MustExist
    $profileRelative = [System.IO.Path]::GetRelativePath(
        $script:ModuleRoot,
        $profilePath).Replace("\", "/")
    $profileTextArguments = @{ ConfigPath = $profilePath }
    if ($PSBoundParameters.ContainsKey("ReviewerInstructions")) {
        $profileTextArguments.ReviewerInstructions = $ReviewerInstructions
    }
    $profileText = Get-ReviewLoopExecutionProfileText @profileTextArguments
    $records = @($records) + "$profileRelative`n$(Get-ReviewLoopSha256 $profileText)"
    return Get-ReviewLoopSha256 ($records -join "`n")
}

function Get-ReviewLoopRoleConfig {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][string]$Role
    )

    $configuredRole = $Role
    if (-not $Config.Roles.ContainsKey($configuredRole)) {
        $defaultRole = switch ($Role) {
            "ReviewClassifier" {
                @{ Model = "gpt-5.6-luna"; Thinking = "low" }
            }
            "LessonsLearned" {
                @{ Model = "gpt-5.6-sol"; Thinking = "high" }
            }
            default { $null }
        }
        if ($null -ne $defaultRole) {
            return $defaultRole
        }
        $legacyRole = switch ($Role) {
            "Fixer" { "PointFixer" }
            "Verifier" { "FindingVerifier" }
            default { "" }
        }
        if (-not [string]::IsNullOrWhiteSpace($legacyRole) -and
            $Config.Roles.ContainsKey($legacyRole)) {
            $configuredRole = $legacyRole
        }
        else {
            throw "Role '$Role' is missing from the configuration."
        }
    }

    $roleConfig = $Config.Roles[$configuredRole]
    foreach ($key in @("Model", "Thinking")) {
        if (-not $roleConfig.ContainsKey($key) -or [string]::IsNullOrWhiteSpace([string]$roleConfig[$key])) {
            throw "Role '$Role' does not contain '$key'."
        }
    }
    return $roleConfig
}

function Get-ReviewLoopGitValue {
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $invoke = {
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = "git"
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        foreach ($argument in @("-C", $RepoPath) + $Arguments) {
            [void]$startInfo.ArgumentList.Add([string]$argument)
        }

        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        try {
            if (-not $process.Start()) {
                throw "Git could not start."
            }
            $stdoutTask = $process.StandardOutput.ReadToEndAsync()
            $stderrTask = $process.StandardError.ReadToEndAsync()
            $process.WaitForExit()
            return [pscustomobject]@{
                ExitCode = $process.ExitCode
                Stdout = $stdoutTask.GetAwaiter().GetResult()
                Stderr = $stderrTask.GetAwaiter().GetResult()
            }
        }
        finally {
            $process.Dispose()
        }
    }

    $last = $null
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $last = & $invoke
        if ([int]$last.ExitCode -eq 0) {
            return ([string]$last.Stdout).Trim()
        }
        if ($attempt -lt 2) {
            Start-Sleep -Milliseconds 100
        }
    }

    $detail = ([string]$last.Stderr).Trim()
    if ([string]::IsNullOrWhiteSpace($detail)) {
        $detail = ([string]$last.Stdout).Trim()
    }
    if ([string]::IsNullOrWhiteSpace($detail)) {
        $detail = "exit code $($last.ExitCode)"
    }
    throw "git $($Arguments -join ' ') failed after 2 attempts: $detail"
}

function Test-ReviewLoopGitClean {
    param([Parameter(Mandatory = $true)][string]$RepoPath)

    return [string]::IsNullOrWhiteSpace((Get-ReviewLoopGitValue -RepoPath $RepoPath -Arguments @("status", "--porcelain")))
}

function Get-ReviewLoopWorktreePatch {
    param([Parameter(Mandatory = $true)][string]$RepoPath)

    $changed = @(& git -C $RepoPath diff --name-only --no-renames HEAD -- 2>$null)
    if ($LASTEXITCODE -ne 0) {
        throw "git diff --name-only failed."
    }
    $untracked = @(& git -C $RepoPath ls-files --others --exclude-standard 2>$null)
    if ($LASTEXITCODE -ne 0) {
        throw "git ls-files --others failed."
    }
    $untrackedSet = [System.Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $untracked) {
        [void]$untrackedSet.Add([string]$path)
    }

    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($path in @($changed + $untracked | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_)
    } | Sort-Object -Unique)) {
        $patch = & git -C $RepoPath diff --binary --no-ext-diff --no-renames `
            --unified=80 HEAD -- ([string]$path) 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw "git diff failed for path '$path'."
        }
        $text = ($patch | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($text) -and $untrackedSet.Contains([string]$path)) {
            $patch = & git -C $RepoPath diff --binary --no-index --no-renames `
                --unified=80 -- /dev/null ([string]$path) 2>$null
            if ($LASTEXITCODE -notin @(0, 1)) {
                throw "git diff failed for untracked path '$path'."
            }
            $text = ($patch | Out-String).Trim()
        }
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            [void]$parts.Add($text)
        }
    }
    return ($parts -join [Environment]::NewLine)
}

function Get-ReviewLoopWorktreeFingerprint {
    param([Parameter(Mandatory = $true)][string]$RepoPath)
    return Get-ReviewLoopSha256 (Get-ReviewLoopWorktreePatch -RepoPath $RepoPath)
}

function ConvertTo-ReviewLoopJsonCompact {
    param([Parameter(Mandatory = $true)][AllowNull()][object]$Value)
    if ($null -eq $Value) {
        return "null"
    }
    return ($Value | ConvertTo-Json -Depth 30 -Compress)
}

function ConvertTo-ReviewLoopPowerShellLiteral {
    param([Parameter(Mandatory = $true)][string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}
