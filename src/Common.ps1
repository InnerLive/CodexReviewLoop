Set-StrictMode -Version Latest

function Write-ReviewLoopStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet("Info", "Success", "Warning", "Error")]
        [string]$Kind = "Info"
    )

    $prefix = switch ($Kind) {
        "Success" { "[ok]" }
        "Warning" { "[warn]" }
        "Error" { "[error]" }
        default { "[info]" }
    }
    Write-Host "$prefix $Message"
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
        throw "Pfad existiert nicht: $absolute"
    }
    return $absolute
}

function ConvertTo-ReviewLoopCanonicalText {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return ""
    }

    return ([string]$Value).Trim().Replace("\", "/").ToLowerInvariant()
}

function Get-ReviewLoopSha256 {
    param([Parameter(Mandatory = $true)][string]$Text)

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
    $redacted = [regex]::Replace($redacted, "(?i)(access[_-]?token|authorization|secret)\s*[:=]\s*[^\s,;]+", '$1=[redacted]')
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
        throw "JSON-Datei fehlt: $Path"
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
    $root = (& git -C $candidate rev-parse --show-toplevel 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($root)) {
        throw "RepoPath ist kein Git-Repository: $candidate"
    }
    return Get-ReviewLoopComparablePath -Path $root
}

function Test-ReviewLoopSamePath {
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )

    $comparison = if ($IsWindows) {
        [System.StringComparison]::OrdinalIgnoreCase
    }
    else {
        [System.StringComparison]::Ordinal
    }
    return [string]::Equals(
        (Get-ReviewLoopComparablePath -Path $Left),
        (Get-ReviewLoopComparablePath -Path $Right),
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
        throw "RepositoryPath muss absolut sein: $ConfigPath"
    }
    if (-not (Test-ReviewLoopSamePath -Left $configured -Right $RepoPath)) {
        throw "Profil '$ConfigPath' gehört zu '$configured', nicht zu '$RepoPath'."
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
                -Message "Ungültiges Profil wird bei der Repository-Suche übersprungen: $($profile.FullName)" `
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
        throw "Mehrere Profile gehören zu '$RepoPath': $($matches -join ', ')"
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
    # Anzeigename des Profils. Er bildet zugleich den Unterordner für Ledger und Runs.
    Name = $(ConvertTo-ReviewLoopPowerShellLiteral $name)

    # Kanonischer Git-Root dieses Profils. Er verhindert Kollisionen zwischen gleichnamigen Repositories.
    RepositoryPath = $(ConvertTo-ReviewLoopPowerShellLiteral $repo)

    # Git-Revision, gegen die Codex den Branch prüft, z. B. origin/main, origin/master oder main.
    ReviewBase = $(ConvertTo-ReviewLoopPowerShellLiteral $reviewBase)

    # Verzeichnis für Ledger, Checkpoints, JSONL- und Ergebnislogs.
    # Relative Pfade werden gegen das Verzeichnis des Review-Loop-Skripts aufgelöst.
    LogRoot = $(ConvertTo-ReviewLoopPowerShellLiteral $logRoot)

    # Zwei Clean-Passes auf unverändertem HEAD sind der empfohlene Abschluss.
    CleanPassesRequired = 2

    # Harte Grenzen gegen endlose Review-, Fix- und Architektur-Schleifen.
    MaxReviewCycles = 12
    MaxFixAttempts = 2
    MaxArchitectureRevisions = 1
    MaxArchitecturePaths = 15
    MaxProductionPaths = 8

    # `$true erstellt nach erfolgreicher Verifikation und allen Host-Gates einen Commit.
    AutoCommit = `$true
    CommitMessagePrefix = 'Review-Loop'

    # Host-Gates laufen nach erfolgreicher Finding-Verifikation und vor dem Commit.
    # Ein Gate besteht aus Name, FilePath und einer Arguments-Liste. Weitere projektspezifische
    # Tests können als zusätzliche Hashtables ergänzt werden.
    HostGates = @(
$($hostGates -join "`n")
    )

    # Rollenwerte:
    # - Model: eine von der installierten Codex-CLI unterstützte Modell-ID.
    # - Thinking: low, medium, high, xhigh oder max.
    # - Sandbox: read-only, workspace-write oder danger-full-access.
    # Fixer benötigen Schreibzugriff; alle beurteilenden Rollen bleiben read-only.
    Roles = @{
        Reviewer = @{ Model = 'gpt-5.6-sol'; Thinking = 'high'; Sandbox = 'read-only' }
        Normalizer = @{ Model = 'gpt-5.6-luna'; Thinking = 'low'; Sandbox = 'read-only' }
        TriggerJudge = @{ Model = 'gpt-5.6-luna'; Thinking = 'low'; Sandbox = 'read-only' }
        TriggerConfirm = @{ Model = 'gpt-5.6-sol'; Thinking = 'low'; Sandbox = 'read-only' }
        TriggerTieBreak = @{ Model = 'gpt-5.6-terra'; Thinking = 'medium'; Sandbox = 'read-only' }
        Architect = @{ Model = 'gpt-5.6-sol'; Thinking = 'max'; Sandbox = 'read-only' }
        ArchitectureCritic = @{ Model = 'gpt-5.6-terra'; Thinking = 'medium'; Sandbox = 'read-only' }
        ArchitectureVeto = @{ Model = 'gpt-5.6-sol'; Thinking = 'medium'; Sandbox = 'read-only' }
        ArchitectureTieBreak = @{ Model = 'gpt-5.6-terra'; Thinking = 'high'; Sandbox = 'read-only' }
        PointFixer = @{ Model = 'gpt-5.6-sol'; Thinking = 'high'; Sandbox = 'danger-full-access' }
        ArchitectureFixer = @{ Model = 'gpt-5.6-sol'; Thinking = 'max'; Sandbox = 'danger-full-access' }
        FindingVerifier = @{ Model = 'gpt-5.6-luna'; Thinking = 'low'; Sandbox = 'read-only' }
        VerifierConfirm = @{ Model = 'gpt-5.6-sol'; Thinking = 'low'; Sandbox = 'read-only' }
        VerifierTieBreak = @{ Model = 'gpt-5.6-terra'; Thinking = 'medium'; Sandbox = 'read-only' }
    }
}
"@

    Write-ReviewLoopUtf8File -Path $absolute -Content $content
    Write-ReviewLoopStatus -Message "Profil wurde angelegt: $absolute" -Kind Success
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
            throw "Konfiguration enthält '$name' nicht: $absolute"
        }
    }
    if ([string]::IsNullOrWhiteSpace([string]$config.LogRoot)) {
        throw "Konfiguration enthält keinen gültigen LogRoot: $absolute"
    }

    $defaults = @{
        CleanPassesRequired = 2
        MaxReviewCycles = 12
        MaxFixAttempts = 2
        MaxArchitectureRevisions = 1
        MaxArchitecturePaths = 15
        MaxProductionPaths = 8
        AutoCommit = $true
        CommitMessagePrefix = "Review-Loop"
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

function Get-ReviewLoopRoleConfig {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][string]$Role
    )

    if (-not $Config.Roles.ContainsKey($Role)) {
        throw "Rolle '$Role' fehlt in der Konfiguration."
    }

    $roleConfig = $Config.Roles[$Role]
    foreach ($key in @("Model", "Thinking", "Sandbox")) {
        if (-not $roleConfig.ContainsKey($key) -or [string]::IsNullOrWhiteSpace([string]$roleConfig[$key])) {
            throw "Rolle '$Role' enthält '$key' nicht."
        }
    }
    return $roleConfig
}

function Get-ReviewLoopGitValue {
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $value = & git -C $RepoPath @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') fehlgeschlagen: $($value -join [Environment]::NewLine)"
    }
    return (($value | Out-String).Trim())
}

function Test-ReviewLoopGitClean {
    param([Parameter(Mandatory = $true)][string]$RepoPath)

    return [string]::IsNullOrWhiteSpace((Get-ReviewLoopGitValue -RepoPath $RepoPath -Arguments @("status", "--porcelain")))
}

function ConvertTo-ReviewLoopJsonCompact {
    param([Parameter(Mandatory = $true)][object]$Value)
    return ($Value | ConvertTo-Json -Depth 30 -Compress)
}
