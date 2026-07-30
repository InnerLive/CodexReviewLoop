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

function Get-ReviewLoopSimpleFindingId {
    param([Parameter(Mandatory = $true)][object]$Finding)

    $locations = @((Get-ReviewLoopObjectProperty `
        -Object $Finding -Name "locations" -Default @()) | ForEach-Object {
        "$([string]$_.path):$([int]$_.line)"
    } | Sort-Object)
    $canonical = @(
        (ConvertTo-ReviewLoopCanonicalText ([string]$Finding.title)),
        (ConvertTo-ReviewLoopCanonicalText ([string](Get-ReviewLoopObjectProperty `
            -Object $Finding -Name "description" -Default ""))),
        ($locations -join "`n")
    ) -join "`n"
    return "F-" + (Get-ReviewLoopSha256 $canonical).Substring(0, 20)
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
    foreach ($finding in @($ledger.Findings)) {
        if ($finding.PSObject.Properties.Name -notcontains "VerifiedRecurrenceCount") {
            $finding | Add-Member -NotePropertyName VerifiedRecurrenceCount -NotePropertyValue 0
        }
    }
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

    $locations = @((Get-ReviewLoopObjectProperty `
        -Object $Finding -Name "locations" -Default @()) | ForEach-Object {
        [pscustomobject][ordered]@{
            path = ([string]$_.path).Replace("\", "/")
            line = [int]$_.line
        }
    })
    if ($locations.Count -eq 0 -and
        $Finding.PSObject.Properties.Name -contains "path") {
        $locations = @([pscustomobject][ordered]@{
            path = ([string]$Finding.path).Replace("\", "/")
            line = [int](Get-ReviewLoopObjectProperty -Object $Finding -Name "line" -Default 0)
        })
    }
    $primary = if ($locations.Count -gt 0) {
        $locations[0]
    }
    else {
        [pscustomobject]@{ path = ""; line = 0 }
    }
    $description = [string](Get-ReviewLoopObjectProperty `
        -Object $Finding -Name "description" -Default (
            Get-ReviewLoopObjectProperty -Object $Finding -Name "evidence" -Default ""))
    $id = Get-ReviewLoopSimpleFindingId -Finding ([pscustomobject]@{
        title = [string]$Finding.title
        description = $description
        locations = $locations
    })
    $clusterId = "C-" + (Get-ReviewLoopSha256 $id).Substring(0, 16)
    $fixPaths = @($locations | ForEach-Object {
        [string]$_.path
    } | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    } | Sort-Object -Unique)

    return [pscustomobject][ordered]@{
        Id = $id
        ClusterId = $clusterId
        Status = "open"
        Priority = ""
        Title = [string]$Finding.title
        Description = $description
        Locations = $locations
        Path = [string]$primary.path
        Line = [int]$primary.line
        Component = ""
        RootCause = ""
        Invariant = ""
        Evidence = $description
        Reproduction = ""
        SuggestedFix = ""
        SuggestedTest = ""
        FixPaths = $fixPaths
        Relations = @()
        IdentityHistory = @([pscustomobject]@{
            Path = [string]$primary.path
            Component = ""
            RootCause = ""
            Invariant = ""
            SeenAt = [DateTimeOffset]::UtcNow.ToString("O")
        })
        FirstSeenReview = $ReviewId
        LastSeenReview = $ReviewId
        FirstSeenHead = $Head
        LastSeenHead = $Head
        RecurrenceCount = 0
        VerifiedRecurrenceCount = 0
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
        if ([string]$existing.Status -in @("pending", "open", "fixing", "blocked")) {
            $existing.Status = "superseded"
            $existing.FixerThreadId = ""
            $existing.UpdatedAt = [DateTimeOffset]::UtcNow.ToString("O")
        }
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

        if ([string]$existing.Status -in @("resolved", "superseded", "duplicate", "blocked")) {
            if ([string]$existing.Status -eq "resolved") {
                $verifiedRecurrences = [int](Get-ReviewLoopObjectProperty `
                    -Object $existing -Name "VerifiedRecurrenceCount" -Default 0)
                $existing | Add-Member -Force -NotePropertyName VerifiedRecurrenceCount `
                    -NotePropertyValue ($verifiedRecurrences + 1)
            }
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
        $existing | Add-Member -Force -NotePropertyName Description `
            -NotePropertyValue $incoming.Description
        $existing | Add-Member -Force -NotePropertyName Locations `
            -NotePropertyValue @($incoming.Locations)
        $existing.Path = $incoming.Path
        $existing.Line = $incoming.Line
        $existing.Evidence = $incoming.Evidence
        $existing.Reproduction = $incoming.Reproduction
        $existing.SuggestedFix = $incoming.SuggestedFix
        $existing.SuggestedTest = $incoming.SuggestedTest
        $existing.FixPaths = $incoming.FixPaths
        $existing.Relations = @()
        $existing.IdentityHistory = @(
            @($existing.IdentityHistory) + @($incoming.IdentityHistory) |
                Sort-Object SeenAt
        )
        $existing.UpdatedAt = [DateTimeOffset]::UtcNow.ToString("O")
    }

    $Ledger.Findings = @($records | Sort-Object Id)
    return $Ledger
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
        ReviewCyclesThisInvocation = 0
        CleanPasses = 0
        CleanHead = ""
        ActiveClusterId = ""
        ActiveFindingIds = @()
        ActiveReviewText = ""
        ActiveRoleCall = $null
        ActiveStrategy = $null
        LastFixerResult = $null
        PendingCommit = $null
        BlockedCleanup = $null
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
    if ([string]$State.Status -notin @(
        "running",
        "completed",
        "limit_reached",
        "blocked",
        "failed"
    )) {
        throw "Invalid run status: $($State.Status)"
    }
    return $true
}

function Read-ReviewLoopState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $state = Read-ReviewLoopJson -Path $Path
    foreach ($name in @("ActiveRoleCall")) {
        if ($state.PSObject.Properties.Name -notcontains $name) {
            $state | Add-Member -NotePropertyName $name -NotePropertyValue $null
        }
    }
    if ($state.PSObject.Properties.Name -notcontains "ReviewCyclesThisInvocation") {
        $state | Add-Member -NotePropertyName ReviewCyclesThisInvocation `
            -NotePropertyValue ([int]$state.ReviewCycle)
    }
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
        CallId = [string](Get-ReviewLoopObjectProperty -Object $Call -Name "CallId" -Default "")
        Role = $Call.Role
        Model = $Call.Model
        Thinking = $Call.Thinking
        Speed = $Call.Speed
        Success = $Call.Success
        ExitCode = $Call.ExitCode
        FailureKind = $Call.FailureKind
        FailureReason = [string](Get-ReviewLoopObjectProperty -Object $Call -Name "FailureReason" -Default "")
        ThreadId = $Call.ThreadId
        Usage = $Call.Usage
        StructuredResult = Get-ReviewLoopObjectProperty -Object $Call -Name "StructuredResult"
        FinalMessage = [string](Get-ReviewLoopObjectProperty -Object $Call -Name "FinalMessage" -Default "")
        JsonlPath = $Call.JsonlPath
        ResultPath = $Call.ResultPath
        Attempts = @((Get-ReviewLoopObjectProperty -Object $Call -Name "Attempts" -Default @()))
        StartedAt = [string](Get-ReviewLoopObjectProperty -Object $Call -Name "StartedAt" -Default "")
        FinishedAt = [string](Get-ReviewLoopObjectProperty -Object $Call -Name "FinishedAt" -Default "")
        ExecutionFingerprint = [string](Get-ReviewLoopObjectProperty `
            -Object $Call -Name "ExecutionFingerprint" -Default "")
        RepositoryHead = [string](Get-ReviewLoopObjectProperty `
            -Object $Call -Name "RepositoryHead" -Default "")
        WorktreeFingerprint = [string](Get-ReviewLoopObjectProperty `
            -Object $Call -Name "WorktreeFingerprint" -Default "")
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
