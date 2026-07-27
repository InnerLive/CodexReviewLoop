$script:FindingStatuses = @(
    "pending",
    "open",
    "fixing",
    "resolved",
    "superseded",
    "duplicate",
    "blocked"
)

function Get-ReviewLoopFindingId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Component,
        [Parameter(Mandatory = $true)][string]$RootCause,
        [Parameter(Mandatory = $true)][string]$Invariant
    )

    $canonical = @(
        (ConvertTo-ReviewLoopCanonicalText $Path),
        (ConvertTo-ReviewLoopCanonicalText $Component),
        (ConvertTo-ReviewLoopCanonicalText $RootCause),
        (ConvertTo-ReviewLoopCanonicalText $Invariant)
    ) -join "`n"
    return "F-" + (Get-ReviewLoopSha256 $canonical).Substring(0, 20)
}

function Get-ReviewLoopClusterId {
    param(
        [Parameter(Mandatory = $true)][string]$Component,
        [Parameter(Mandatory = $true)][string]$RootCause,
        [Parameter(Mandatory = $true)][string]$Invariant
    )

    $canonical = @(
        (ConvertTo-ReviewLoopCanonicalText $Component),
        (ConvertTo-ReviewLoopCanonicalText $RootCause),
        (ConvertTo-ReviewLoopCanonicalText $Invariant)
    ) -join "`n"
    return "C-" + (Get-ReviewLoopSha256 $canonical).Substring(0, 16)
}

function New-ReviewLoopLedger {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$RepoPath)

    return [pscustomobject][ordered]@{
        SchemaVersion = "1.0"
        RepoPath = Resolve-ReviewLoopPath -Path $RepoPath -MustExist
        Revision = 0
        Findings = @()
        CreatedAt = [DateTimeOffset]::UtcNow.ToString("O")
        UpdatedAt = [DateTimeOffset]::UtcNow.ToString("O")
    }
}

function Test-ReviewLoopLedger {
    param([Parameter(Mandatory = $true)][object]$Ledger)

    if ([string]$Ledger.SchemaVersion -ne "1.0") {
        throw "Unbekannte Ledger-Version: $($Ledger.SchemaVersion)"
    }
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($finding in @($Ledger.Findings)) {
        if ([string]::IsNullOrWhiteSpace([string]$finding.Id)) {
            throw "Ledger-Finding ohne ID."
        }
        if (-not $seen.Add([string]$finding.Id)) {
            throw "Doppelte Finding-ID im Ledger: $($finding.Id)"
        }
        if ([string]$finding.Status -notin $script:FindingStatuses) {
            throw "Ungültiger Finding-Status '$($finding.Status)' für $($finding.Id)."
        }
        if ([string]$finding.Status -eq "resolved" -and $null -eq $finding.Verification) {
            throw "Finding $($finding.Id) ist resolved, besitzt aber keinen Verifikationsnachweis."
        }
    }
    return $true
}

function Read-ReviewLoopLedger {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$RepoPath = ""
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        if ([string]::IsNullOrWhiteSpace($RepoPath)) {
            throw "Ledger fehlt und RepoPath wurde nicht angegeben: $Path"
        }
        return New-ReviewLoopLedger -RepoPath $RepoPath
    }
    $ledger = Read-ReviewLoopJson -Path $Path
    Test-ReviewLoopLedger -Ledger $ledger | Out-Null
    return $ledger
}

function Write-ReviewLoopLedger {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Ledger
    )

    Test-ReviewLoopLedger -Ledger $Ledger | Out-Null
    $Ledger.Revision = [int]$Ledger.Revision + 1
    $Ledger.UpdatedAt = [DateTimeOffset]::UtcNow.ToString("O")
    Write-ReviewLoopAtomicJson -Path $Path -Value $Ledger
    return $Ledger
}

function ConvertTo-ReviewLoopFindingRecord {
    param(
        [Parameter(Mandatory = $true)][object]$Finding,
        [Parameter(Mandatory = $true)][string]$ReviewId,
        [Parameter(Mandatory = $true)][string]$Head
    )

    $id = Get-ReviewLoopFindingId `
        -Path ([string]$Finding.path) `
        -Component ([string]$Finding.component) `
        -RootCause ([string]$Finding.rootCause) `
        -Invariant ([string]$Finding.invariant)
    $clusterId = Get-ReviewLoopClusterId `
        -Component ([string]$Finding.component) `
        -RootCause ([string]$Finding.rootCause) `
        -Invariant ([string]$Finding.invariant)

    $fixPaths = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace([string]$Finding.path)) {
        [void]$fixPaths.Add(([string]$Finding.path).Replace("\", "/"))
    }
    if ($Finding.PSObject.Properties.Name -contains "fixPaths") {
        foreach ($path in @($Finding.fixPaths)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$path) -and -not $fixPaths.Contains(([string]$path).Replace("\", "/"))) {
                [void]$fixPaths.Add(([string]$path).Replace("\", "/"))
            }
        }
    }

    return [pscustomobject][ordered]@{
        Id = $id
        ClusterId = $clusterId
        Status = "open"
        Priority = [string]$Finding.priority
        Title = [string]$Finding.title
        Path = ([string]$Finding.path).Replace("\", "/")
        Line = [int]$Finding.line
        Component = [string]$Finding.component
        RootCause = [string]$Finding.rootCause
        Invariant = [string]$Finding.invariant
        Evidence = [string]$Finding.evidence
        Reproduction = [string]$Finding.reproduction
        SuggestedFix = [string]$Finding.suggestedFix
        SuggestedTest = [string]$Finding.suggestedTest
        FixPaths = $fixPaths.ToArray()
        FirstSeenReview = $ReviewId
        LastSeenReview = $ReviewId
        FirstSeenHead = $Head
        LastSeenHead = $Head
        RecurrenceCount = 0
        FixAttempts = 0
        FixerThreadId = ""
        Verification = $null
        ResolutionCommit = ""
        BlockedReason = ""
        CreatedAt = [DateTimeOffset]::UtcNow.ToString("O")
        UpdatedAt = [DateTimeOffset]::UtcNow.ToString("O")
    }
}

function Merge-ReviewLoopFindings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Ledger,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Findings,
        [Parameter(Mandatory = $true)][string]$ReviewId,
        [Parameter(Mandatory = $true)][string]$Head
    )

    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($existing in @($Ledger.Findings)) {
        [void]$records.Add($existing)
    }

    foreach ($finding in $Findings) {
        $incoming = ConvertTo-ReviewLoopFindingRecord -Finding $finding -ReviewId $ReviewId -Head $Head
        $existing = $records | Where-Object { [string]$_.Id -eq [string]$incoming.Id } | Select-Object -First 1
        if ($null -eq $existing) {
            [void]$records.Add($incoming)
            continue
        }

        if ([string]$existing.Status -eq "resolved") {
            $existing.Status = "open"
            $existing.RecurrenceCount = [int]$existing.RecurrenceCount + 1
            $existing.Verification = $null
            $existing.ResolutionCommit = ""
        }
        elseif ([string]$existing.Status -in @("superseded", "duplicate")) {
            continue
        }
        $existing.LastSeenReview = $ReviewId
        $existing.LastSeenHead = $Head
        $existing.Priority = $incoming.Priority
        $existing.Title = $incoming.Title
        $existing.Line = $incoming.Line
        $existing.Evidence = $incoming.Evidence
        $existing.Reproduction = $incoming.Reproduction
        $existing.SuggestedFix = $incoming.SuggestedFix
        $existing.SuggestedTest = $incoming.SuggestedTest
        $existing.FixPaths = $incoming.FixPaths
        $existing.UpdatedAt = [DateTimeOffset]::UtcNow.ToString("O")
    }

    $Ledger.Findings = @($records | Sort-Object Id)
    return $Ledger
}

function Get-ReviewLoopTriggerCandidates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Finding,
        [Parameter(Mandatory = $true)][object]$Ledger
    )

    $component = ConvertTo-ReviewLoopCanonicalText $Finding.Component
    $cause = ConvertTo-ReviewLoopCanonicalText $Finding.RootCause
    $invariant = ConvertTo-ReviewLoopCanonicalText $Finding.Invariant
    $paths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($path in @($Finding.FixPaths)) {
        $paths.Add((ConvertTo-ReviewLoopCanonicalText $path)) | Out-Null
    }

    $candidates = foreach ($candidate in @($Ledger.Findings)) {
        if ([string]$candidate.Id -eq [string]$Finding.Id -or [string]$candidate.Status -in @("duplicate", "superseded")) {
            continue
        }

        $sameComponent = -not [string]::IsNullOrWhiteSpace($component) -and $component -eq (ConvertTo-ReviewLoopCanonicalText $candidate.Component)
        $sameCause = -not [string]::IsNullOrWhiteSpace($cause) -and $cause -eq (ConvertTo-ReviewLoopCanonicalText $candidate.RootCause)
        $sameInvariant = -not [string]::IsNullOrWhiteSpace($invariant) -and $invariant -eq (ConvertTo-ReviewLoopCanonicalText $candidate.Invariant)
        $sameCluster = [string]$Finding.ClusterId -eq [string]$candidate.ClusterId
        $overlap = @($candidate.FixPaths | Where-Object { $paths.Contains((ConvertTo-ReviewLoopCanonicalText $_)) }).Count -gt 0

        # Pfadüberlappung ist nur Evidenz. Mindestens ein semantisches Merkmal muss passen.
        if ($sameComponent -or $sameCause -or $sameInvariant -or $sameCluster) {
            [pscustomobject]@{
                Finding = $candidate
                SameComponent = $sameComponent
                SameRootCause = $sameCause
                SameInvariant = $sameInvariant
                SameCluster = $sameCluster
                OverlappingFixPaths = $overlap
            }
        }
    }

    return @($candidates | Sort-Object { $_.Finding.Id })
}

function New-ReviewLoopState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$ReviewBase,
        [Parameter(Mandatory = $true)][string]$Speed,
        [Parameter(Mandatory = $true)][string]$RunRoot
    )

    $repo = Resolve-ReviewLoopPath -Path $RepoPath -MustExist
    return [pscustomobject][ordered]@{
        SchemaVersion = "1.0"
        RunId = Split-Path -Leaf $RunRoot
        RunRoot = Resolve-ReviewLoopPath -Path $RunRoot
        RepoPath = $repo
        Branch = Get-ReviewLoopGitValue -RepoPath $repo -Arguments @("branch", "--show-current")
        ReviewBase = $ReviewBase
        Speed = $Speed
        StartHead = Get-ReviewLoopGitValue -RepoPath $repo -Arguments @("rev-parse", "HEAD")
        CurrentHead = Get-ReviewLoopGitValue -RepoPath $repo -Arguments @("rev-parse", "HEAD")
        Stage = "initialized"
        Status = "running"
        ExitCode = 0
        ReviewCycle = 0
        CleanPasses = 0
        CleanHead = ""
        ActiveClusterId = ""
        ActiveFindingIds = @()
        ArchitectureRevision = 0
        ActiveStrategy = $null
        LastFixerResult = $null
        BlockedReason = ""
        RoleCalls = @()
        CreatedAt = [DateTimeOffset]::UtcNow.ToString("O")
        UpdatedAt = [DateTimeOffset]::UtcNow.ToString("O")
    }
}

function Test-ReviewLoopState {
    param([Parameter(Mandatory = $true)][object]$State)

    if ([string]$State.SchemaVersion -ne "1.0") {
        throw "Unbekannte State-Version: $($State.SchemaVersion)"
    }
    if ([string]$State.Status -notin @("running", "completed", "blocked", "failed")) {
        throw "Ungültiger Run-Status: $($State.Status)"
    }
    return $true
}

function Read-ReviewLoopState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $state = Read-ReviewLoopJson -Path $Path
    Test-ReviewLoopState -State $state | Out-Null
    return $state
}

function Write-ReviewLoopState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$State
    )

    Test-ReviewLoopState -State $State | Out-Null
    $State.UpdatedAt = [DateTimeOffset]::UtcNow.ToString("O")
    Write-ReviewLoopAtomicJson -Path $Path -Value $State
    return $State
}

function Add-ReviewLoopRoleCall {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][object]$Call
    )

    $record = [pscustomobject][ordered]@{
        Role = $Call.Role
        Model = $Call.Model
        Thinking = $Call.Thinking
        Speed = $Call.Speed
        Success = $Call.Success
        ExitCode = $Call.ExitCode
        FailureKind = $Call.FailureKind
        ThreadId = $Call.ThreadId
        Usage = $Call.Usage
        JsonlPath = $Call.JsonlPath
        ResultPath = $Call.ResultPath
        RecordedAt = [DateTimeOffset]::UtcNow.ToString("O")
    }
    $State.RoleCalls = @($State.RoleCalls) + @($record)
    return $State
}

function Set-ReviewLoopCheckpoint {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][string]$Stage,
        [string]$Status = ""
    )

    $State.Stage = $Stage
    if (-not [string]::IsNullOrWhiteSpace($Status)) {
        $State.Status = $Status
    }
    Write-ReviewLoopState -Path $StatePath -State $State | Out-Null
}
