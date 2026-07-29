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
        -RecommendedStepCount $RecommendedStepCount `
        -Status "blocked")
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
        Move-Item -LiteralPath $temporary -Destination $absolute -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force
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

    # Directory for the ledger, checkpoints, JSONL logs, and result logs.
    # Relative paths are resolved against the review loop script directory.
    LogRoot = $(ConvertTo-ReviewLoopPowerShellLiteral $logRoot)

    # Two clean passes on an unchanged HEAD are the required completion gate.
    CleanPassesRequired = 2

    # Hard limits prevent endless review, fix, and architecture loops.
    # MaxReviewCycles is reloaded at safe boundaries while a run is active.
    MaxReviewCycles = 12
    MaxFixAttempts = 2
    MaxArchitectureRevisions = 1
    # The unattended loop always commits after successful verification and all host gates.
    AutoCommit = `$true
    # CommitMessagePrefix is reloaded for future commits while a run is active.
    CommitMessagePrefix = 'Review-Loop'

    # Host gates run after successful finding verification and before the commit.
    # A gate consists of Name, FilePath, and an Arguments list. Add project-specific
    # tests as additional hashtables.
    HostGates = @(
$($hostGates -join "`n")
    )

    # Role settings:
    # - Model: a model ID supported by the installed Codex CLI.
    # - Thinking: low, medium, high, xhigh, or max.
    # Every role runs unattended with approvals, sandboxing, and Codex exec rules
    # bypassed. Repository invariants and verification are enforced by this tool.
    Roles = @{
        Reviewer = @{ Model = 'gpt-5.6-sol'; Thinking = 'high' }
        TriggerJudge = @{ Model = 'gpt-5.6-luna'; Thinking = 'low' }
        TriggerConfirm = @{ Model = 'gpt-5.6-sol'; Thinking = 'low' }
        TriggerTieBreak = @{ Model = 'gpt-5.6-terra'; Thinking = 'medium' }
        Architect = @{ Model = 'gpt-5.6-sol'; Thinking = 'high' }
        ArchitectureCritic = @{ Model = 'gpt-5.6-terra'; Thinking = 'medium' }
        ArchitectureVeto = @{ Model = 'gpt-5.6-sol'; Thinking = 'medium' }
        ArchitectureTieBreak = @{ Model = 'gpt-5.6-terra'; Thinking = 'high' }
        PointFixer = @{ Model = 'gpt-5.6-sol'; Thinking = 'high' }
        ArchitectureFixer = @{ Model = 'gpt-5.6-sol'; Thinking = 'high' }
        FindingVerifier = @{ Model = 'gpt-5.6-luna'; Thinking = 'low' }
        VerifierConfirm = @{ Model = 'gpt-5.6-sol'; Thinking = 'low' }
        VerifierTieBreak = @{ Model = 'gpt-5.6-terra'; Thinking = 'medium' }
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
        MaxFixAttempts = 2
        MaxArchitectureRevisions = 1
        AutoCommit = $true
        CommitMessagePrefix = "Review-Loop"
    }
    foreach ($entry in $defaults.GetEnumerator()) {
        if (-not $config.ContainsKey($entry.Key)) {
            $config[$entry.Key] = $entry.Value
        }
    }
    if (-not [bool]$config.AutoCommit) {
        throw "AutoCommit=false is incompatible with the unattended loop because it leaves a dirty worktree."
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

    $limits = @{
        CleanPassesRequired = @(2, 2)
        MaxReviewCycles = @(2, 100)
        MaxFixAttempts = @(2, 2)
        MaxArchitectureRevisions = @(1, 1)
    }
    foreach ($entry in $limits.GetEnumerator()) {
        try {
            $value = [int]$Config[$entry.Key]
        }
        catch {
            throw "Configuration value '$($entry.Key)' must be an integer."
        }
        if ($value -lt $entry.Value[0] -or $value -gt $entry.Value[1]) {
            $range = if ($entry.Value[0] -eq $entry.Value[1]) {
                [string]$entry.Value[0]
            }
            else {
                "$($entry.Value[0])..$($entry.Value[1])"
            }
            throw "Configuration value '$($entry.Key)' must be $range."
        }
        $Config[$entry.Key] = $value
    }
    if ([int]$Config.MaxReviewCycles -lt [int]$Config.CleanPassesRequired) {
        throw "MaxReviewCycles must be at least CleanPassesRequired."
    }
    $roles = @(
        "Reviewer",
        "TriggerJudge", "TriggerConfirm", "TriggerTieBreak",
        "Architect", "ArchitectureCritic", "ArchitectureVeto", "ArchitectureTieBreak",
        "PointFixer", "ArchitectureFixer",
        "FindingVerifier", "VerifierConfirm", "VerifierTieBreak"
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
    }
}

$script:ReviewLoopLiveConfigKeys = @(
    "MaxReviewCycles",
    "CommitMessagePrefix"
)

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
    param([Parameter(Mandatory = $true)][string]$ConfigPath)

    $profile = Import-PowerShellDataFile -LiteralPath (
        Resolve-ReviewLoopPath -Path $ConfigPath -MustExist)
    $executionSettings = @{}
    foreach ($key in $profile.Keys) {
        if ([string]$key -notin $script:ReviewLoopLiveConfigKeys) {
            $executionSettings[$key] = $profile[$key]
        }
    }
    return ConvertTo-ReviewLoopFingerprintData -Value $executionSettings
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

    $changes = [System.Collections.Generic.List[string]]::new()
    foreach ($key in $script:ReviewLoopLiveConfigKeys) {
        $before = ConvertTo-ReviewLoopFingerprintData -Value $Config[$key]
        $after = ConvertTo-ReviewLoopFingerprintData -Value $latest[$key]
        if ($before -eq $after) {
            continue
        }
        $Config[$key] = $latest[$key]
        if ($key -eq "MaxReviewCycles") {
            [void]$changes.Add("MaxReviewCycles $before -> $after")
        }
        else {
            [void]$changes.Add("$key updated")
        }
    }
    if ($changes.Count -gt 0) {
        Write-ReviewLoopStatus `
            -Message "Reloaded live profile settings · $($changes -join ' · ')" `
            -Kind Info
    }
}

function Get-ReviewLoopExecutionFingerprint {
    param([Parameter(Mandatory = $true)][string]$ConfigPath)

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
    $profileText = Get-ReviewLoopExecutionProfileText -ConfigPath $profilePath
    $records = @($records) + "$profileRelative`n$(Get-ReviewLoopSha256 $profileText)"
    return Get-ReviewLoopSha256 ($records -join "`n")
}

function Get-ReviewLoopRoleConfig {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][string]$Role
    )

    if (-not $Config.Roles.ContainsKey($Role)) {
        throw "Role '$Role' is missing from the configuration."
    }

    $roleConfig = $Config.Roles[$Role]
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

    $value = & git -C $RepoPath @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) {
        $failure = & git -C $RepoPath @Arguments 2>&1
        throw "git $($Arguments -join ' ') failed: $($failure -join [Environment]::NewLine)"
    }
    return (($value | Out-String).Trim())
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
    param([Parameter(Mandatory = $true)][object]$Value)
    return ($Value | ConvertTo-Json -Depth 30 -Compress)
}

function ConvertTo-ReviewLoopPowerShellLiteral {
    param([Parameter(Mandatory = $true)][string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}
