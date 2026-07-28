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
        SchemaVersion = "2.0"
        RepoPath = Resolve-ReviewLoopPath -Path $RepoPath -MustExist
        Revision = 0
        Findings = @()
        CreatedAt = [DateTimeOffset]::UtcNow.ToString("O")
        UpdatedAt = [DateTimeOffset]::UtcNow.ToString("O")
    }
}

function Test-ReviewLoopLedger {
    param([Parameter(Mandatory = $true)][object]$Ledger)

    if ([string]$Ledger.SchemaVersion -ne "2.0") {
        throw "Unknown ledger version: $($Ledger.SchemaVersion)"
    }
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($finding in @($Ledger.Findings)) {
        if ([string]::IsNullOrWhiteSpace([string]$finding.Id)) {
            throw "Ledger finding has no ID."
        }
        if (-not $seen.Add([string]$finding.Id)) {
            throw "Duplicate finding ID in ledger: $($finding.Id)"
        }
        if ([string]$finding.Status -notin $script:FindingStatuses) {
            throw "Invalid finding status '$($finding.Status)' for $($finding.Id)."
        }
        if ([string]$finding.Status -eq "resolved" -and $null -eq $finding.Verification) {
            throw "Finding $($finding.Id) is resolved but has no verification evidence."
        }
    }
    return $true
}

function ConvertTo-ReviewLoopLedgerV2 {
    param([Parameter(Mandatory = $true)][object]$Ledger)

    if ([string]$Ledger.SchemaVersion -eq "2.0") {
        return $Ledger
    }
    if ([string]$Ledger.SchemaVersion -ne "1.0") {
        throw "Unknown ledger version: $($Ledger.SchemaVersion)"
    }
    foreach ($finding in @($Ledger.Findings)) {
        if ($finding.PSObject.Properties.Name -notcontains "Relations") {
            $finding | Add-Member -NotePropertyName Relations -NotePropertyValue @()
        }
        if ($finding.PSObject.Properties.Name -notcontains "IdentityHistory") {
            $finding | Add-Member -NotePropertyName IdentityHistory -NotePropertyValue @(
                [pscustomobject]@{
                    Path = [string]$finding.Path
                    Component = [string]$finding.Component
                    RootCause = [string]$finding.RootCause
                    Invariant = [string]$finding.Invariant
                    SeenAt = [string]$finding.UpdatedAt
                }
            )
        }
        if ($finding.PSObject.Properties.Name -notcontains "LastBlockedHead") {
            $finding | Add-Member -NotePropertyName LastBlockedHead -NotePropertyValue ""
        }
    }
    $Ledger.SchemaVersion = "2.0"
    return $Ledger
}

function Read-ReviewLoopLedger {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$RepoPath = ""
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        if ([string]::IsNullOrWhiteSpace($RepoPath)) {
            throw "Ledger is missing and RepoPath was not supplied: $Path"
        }
        return New-ReviewLoopLedger -RepoPath $RepoPath
    }
    $ledger = ConvertTo-ReviewLoopLedgerV2 (Read-ReviewLoopJson -Path $Path)
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

    $matchedId = [string](Get-ReviewLoopObjectProperty `
        -Object $Finding -Name "matchedFindingId" -Default "")
    $id = if ([string]::IsNullOrWhiteSpace($matchedId)) {
        Get-ReviewLoopFindingId `
            -Path ([string]$Finding.path) `
            -Component ([string]$Finding.component) `
            -RootCause ([string]$Finding.rootCause) `
            -Invariant ([string]$Finding.invariant)
    } else {
        $matchedId
    }
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
        Relations = @((Get-ReviewLoopObjectProperty `
            -Object $Finding -Name "relations" -Default @()))
        IdentityHistory = @([pscustomobject]@{
            Path = ([string]$Finding.path).Replace("\", "/")
            Component = [string]$Finding.component
            RootCause = [string]$Finding.rootCause
            Invariant = [string]$Finding.invariant
            SeenAt = [DateTimeOffset]::UtcNow.ToString("O")
        })
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
        LastBlockedHead = ""
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
        $existing = $records | Where-Object {
            [string]$_.Id -eq [string]$incoming.Id
        } | Select-Object -First 1
        if ($null -eq $existing) {
            [void]$records.Add($incoming)
            continue
        }

        if ([string]$existing.Status -in @("resolved", "superseded", "duplicate")) {
            $existing.Status = "open"
            $existing.RecurrenceCount = [int]$existing.RecurrenceCount + 1
            $existing.FixAttempts = 0
            $existing.FixerThreadId = ""
            $existing.Verification = $null
            $existing.ResolutionCommit = ""
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
        $existing.Relations = @(
            @($existing.Relations) + @($incoming.Relations) |
                Group-Object { "$($_.CandidateFindingId)|$($_.Relation)" } |
                ForEach-Object { $_.Group | Select-Object -Last 1 }
        )
        $existing.IdentityHistory = @(
            @($existing.IdentityHistory) + @($incoming.IdentityHistory) |
                Sort-Object SeenAt
        )
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
    $primaryPath = ConvertTo-ReviewLoopCanonicalText $Finding.Path
    $paths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($path in @($Finding.FixPaths)) {
        $canonicalPath = ConvertTo-ReviewLoopCanonicalText $path
        if (-not [string]::IsNullOrWhiteSpace($canonicalPath)) {
            $paths.Add($canonicalPath) | Out-Null
        }
    }

    $candidates = foreach ($candidate in @($Ledger.Findings)) {
        if ([string]$candidate.Id -eq [string]$Finding.Id -or [string]$candidate.Status -in @("duplicate", "superseded")) {
            continue
        }

        $sameComponent = -not [string]::IsNullOrWhiteSpace($component) -and $component -eq (ConvertTo-ReviewLoopCanonicalText $candidate.Component)
        $sameCause = -not [string]::IsNullOrWhiteSpace($cause) -and $cause -eq (ConvertTo-ReviewLoopCanonicalText $candidate.RootCause)
        $sameInvariant = -not [string]::IsNullOrWhiteSpace($invariant) -and $invariant -eq (ConvertTo-ReviewLoopCanonicalText $candidate.Invariant)
        $clusterId = [string]$Finding.ClusterId
        $sameCluster = -not [string]::IsNullOrWhiteSpace($clusterId) -and
            $clusterId -eq [string]$candidate.ClusterId
        $candidatePrimaryPath = ConvertTo-ReviewLoopCanonicalText $candidate.Path
        $overlap = @($candidate.FixPaths | Where-Object {
            $candidateFixPath = ConvertTo-ReviewLoopCanonicalText $_
            $paths.Contains($candidateFixPath) -and
                -not ($candidateFixPath -eq $primaryPath -and
                    $candidateFixPath -eq $candidatePrimaryPath)
        }).Count -gt 0

        # These are candidates only. No signal decides the relationship by itself.
        if ($sameComponent -or $sameCause -or $sameInvariant -or $sameCluster -or $overlap) {
            $score = @($sameCause, $sameInvariant, $sameCluster, $sameComponent, $overlap |
                Where-Object { $_ }).Count
            [pscustomobject]@{
                Finding = $candidate
                SameComponent = $sameComponent
                SameRootCause = $sameCause
                SameInvariant = $sameInvariant
                SameCluster = $sameCluster
                OverlappingFixPaths = $overlap
                Score = $score
            }
        }
    }

    return @($candidates | Sort-Object `
        @{ Expression = "Score"; Descending = $true },
        @{ Expression = { $_.Finding.UpdatedAt }; Descending = $true },
        @{ Expression = { $_.Finding.Id }; Descending = $false })
}

function New-ReviewLoopState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$ReviewBase,
        [Parameter(Mandatory = $true)][string]$Speed,
        [Parameter(Mandatory = $true)][string]$RunRoot,
        [string]$ReviewBaseCommit = "",
        [string]$ExecutionFingerprint = ""
    )

    $repo = Resolve-ReviewLoopPath -Path $RepoPath -MustExist
    return [pscustomobject][ordered]@{
        SchemaVersion = "1.0"
        RunId = Split-Path -Leaf $RunRoot
        RunRoot = Resolve-ReviewLoopPath -Path $RunRoot
        RepoPath = $repo
        Branch = Get-ReviewLoopGitValue -RepoPath $repo -Arguments @("branch", "--show-current")
        ReviewBase = $ReviewBase
        ReviewBaseCommit = $ReviewBaseCommit
        ExecutionFingerprint = $ExecutionFingerprint
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
        PendingCommit = $null
        BlockedReason = ""
        RoleCalls = @()
        CreatedAt = [DateTimeOffset]::UtcNow.ToString("O")
        UpdatedAt = [DateTimeOffset]::UtcNow.ToString("O")
    }
}

function Test-ReviewLoopState {
    param([Parameter(Mandatory = $true)][object]$State)

    if ([string]$State.SchemaVersion -ne "1.0") {
        throw "Unknown state version: $($State.SchemaVersion)"
    }
    if ([string]$State.Status -notin @("running", "completed", "blocked", "failed")) {
        throw "Invalid run status: $($State.Status)"
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
