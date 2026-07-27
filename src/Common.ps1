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

    $repo = Resolve-ReviewLoopPath -Path $RepoPath -MustExist
    $absolute = Resolve-ReviewLoopPath -Path $Path
    $name = Split-Path -Leaf $repo
    $reviewBase = Get-ReviewLoopDefaultReviewBase -RepoPath $repo
    $logRoot = Join-Path $script:ModuleRoot "runs"
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

    # Git-Revision, gegen die Codex den Branch prüft, z. B. origin/main, origin/master oder main.
    ReviewBase = $(ConvertTo-ReviewLoopPowerShellLiteral $reviewBase)

    # Verzeichnis für Ledger, Checkpoints, JSONL- und Ergebnislogs.
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

    $repo = Resolve-ReviewLoopPath -Path $RepoPath -MustExist
    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
        $explicit = Resolve-ReviewLoopPath -Path $ConfigPath
        if (Test-Path -LiteralPath $explicit -PathType Leaf) {
            return $explicit
        }
        return New-ReviewLoopProfile -RepoPath $repo -Path $explicit
    }

    foreach ($candidate in @(
        (Join-Path $repo ".codex-review-loop.psd1"),
        (Join-Path $repo ".codex\review-loop.psd1")
    )) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-ReviewLoopPath -Path $candidate)
        }
    }

    $profileDirectory = if ([string]::IsNullOrWhiteSpace($ProfilesRoot)) {
        Join-Path $script:ModuleRoot "profiles"
    }
    else {
        Resolve-ReviewLoopPath -Path $ProfilesRoot
    }
    $profilePath = Join-Path $profileDirectory ("{0}.psd1" -f (Split-Path -Leaf $repo))
    if (Test-Path -LiteralPath $profilePath -PathType Leaf) {
        return (Resolve-ReviewLoopPath -Path $profilePath)
    }
    return New-ReviewLoopProfile -RepoPath $repo -Path $profilePath
}

function Import-ReviewLoopConfig {
    param([Parameter(Mandatory = $true)][string]$ConfigPath)

    $absolute = Resolve-ReviewLoopPath -Path $ConfigPath -MustExist
    $config = Import-PowerShellDataFile -LiteralPath $absolute
    $required = @("Name", "ReviewBase", "LogRoot", "Roles", "HostGates")
    foreach ($name in $required) {
        if (-not $config.ContainsKey($name)) {
            throw "Konfiguration enthält '$name' nicht: $absolute"
        }
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
