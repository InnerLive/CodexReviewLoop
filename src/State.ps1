$script:FindingStatuses = @(
    "pending",
    "open",
    "fixing",
    "resolved",
    "superseded",
    "duplicate",
    "blocked"
)

function Get-ReviewLoopSessionRoleNames {
    return @(
        "ReviewClassifier",
        "LessonsLearned",
        "Architect",
        "Fixer"
    )
}

function Get-ReviewLoopCompletedReviewCount {
    param([Parameter(Mandatory = $true)][object]$State)

    return @($State.RoleCalls | Where-Object {
        $_.Role -eq "Reviewer" -and $_.Success -and $_.CallId -match '^review-[0-9]+$'
    } | Select-Object -ExpandProperty CallId -Unique).Count
}

function Test-ReviewLoopCycleBoundary {
    param([Parameter(Mandatory = $true)][object]$State)

    return $null -eq $State.ActiveRoleCall -and [string]$State.Stage -in @(
        "initialized", "clean_review", "fix_committed", "review_round_requested", "limit_reached"
    )
}

function Get-ReviewLoopLatestCritique {
    param([AllowNull()][object]$State)

    if ($null -eq $State) { return $null }
    return $State.RoleCalls | Where-Object {
        $_.Role -eq "Critic" -and $_.Success
    } | Select-Object -Last 1
}

function New-ReviewLoopRoleSessions {
    $sessions = [ordered]@{}
    foreach ($role in @(Get-ReviewLoopSessionRoleNames)) {
        $sessions[$role] = ""
    }
    return [pscustomobject]$sessions
}

function Initialize-ReviewLoopRoleSessions {
    param([Parameter(Mandatory = $true)][object]$State)

    if ($State.PSObject.Properties.Name -notcontains "RoleSessions") {
        $State | Add-Member -NotePropertyName RoleSessions `
            -NotePropertyValue (New-ReviewLoopRoleSessions)
    }
    foreach ($role in @(Get-ReviewLoopSessionRoleNames)) {
        if ($State.RoleSessions.PSObject.Properties.Name -notcontains $role) {
            $State.RoleSessions | Add-Member -NotePropertyName $role -NotePropertyValue ""
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$State.RoleSessions.$role)) {
            continue
        }
        $latest = @((Get-ReviewLoopObjectProperty -Object $State -Name "RoleCalls" -Default @()) |
            Where-Object {
                [bool](Get-ReviewLoopObjectProperty -Object $_ -Name "Success" -Default $false) -and
                [string](Get-ReviewLoopObjectProperty -Object $_ -Name "Role" -Default "") -eq $role -and
                -not [string]::IsNullOrWhiteSpace([string](Get-ReviewLoopObjectProperty `
                    -Object $_ -Name "ThreadId" -Default ""))
            } |
            Select-Object -Last 1)
        if ($latest.Count -gt 0) {
            $State.RoleSessions.$role = [string]$latest[0].ThreadId
        }
    }
}

function Get-ReviewLoopRoleSessionThreadId {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$Role
    )

    if ($Role -notin @(Get-ReviewLoopSessionRoleNames)) {
        return ""
    }
    Initialize-ReviewLoopRoleSessions -State $State
    return [string]$State.RoleSessions.$Role
}

function Set-ReviewLoopRoleSessionThreadId {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$Role,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ThreadId
    )

    if ($Role -notin @(Get-ReviewLoopSessionRoleNames) -or
        [string]::IsNullOrWhiteSpace($ThreadId)) {
        return
    }
    Initialize-ReviewLoopRoleSessions -State $State
    $State.RoleSessions.$Role = $ThreadId
}

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
        [string]$ReviewBaseSetting = "",
        [string]$ReviewBaseCommit = "",
        [string]$ExecutionFingerprint = ""
    )

    $repo = Resolve-ReviewLoopPath -Path $RepoPath -MustExist
    if ([string]::IsNullOrWhiteSpace($ReviewBaseSetting)) {
        $ReviewBaseSetting = $ReviewBase
    }
    return [pscustomobject][ordered]@{
        SchemaVersion = "2.0"
        RunId = Split-Path -Leaf $RunRoot
        RunRoot = Resolve-ReviewLoopPath -Path $RunRoot
        RepoPath = $repo
        Branch = Get-ReviewLoopGitValue -RepoPath $repo -Arguments @("branch", "--show-current")
        ReviewBaseSetting = $ReviewBaseSetting
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
        LoopCommits = @()
        LoopCommitsInitialized = $true
        CleanPasses = 0
        CleanHead = ""
        ActiveClusterId = ""
        ActiveFindingIds = @()
        ActiveFindingSource = ""
        ActiveReviewText = ""
        LessonsLearned = [pscustomobject][ordered]@{
            Status = "pending"
            Attempt = 0
            TriggerHead = ""
            TriggerCommitCount = 0
            CompletedHead = ""
            ReviewAfterCommit = $false
        }
        RoleSessions = New-ReviewLoopRoleSessions
        ActiveRoleCall = $null
        ActiveCriticCall = $null
        ActiveStrategy = $null
        TaskContext = ""
        CompletionRequalificationRequired = $false
        ArchitectWork = New-ReviewLoopArchitectWork
        ActiveWorkIds = @()
        ActiveFixAttempt = 0
        RetainedCandidate = $null
        LastReview = $null
        LastFixerResult = $null
        PartialFixRecovery = $null
        PendingCommit = $null
        ActiveHostGateRecovery = $null
        BlockedCleanup = $null
        BlockedReason = ""
        RoleCalls = @()
        CreatedAt = [DateTimeOffset]::UtcNow.ToString("O")
        UpdatedAt = [DateTimeOffset]::UtcNow.ToString("O")
    }
}

function Test-ReviewLoopState {
    param([Parameter(Mandatory = $true)][object]$State)

    if ([string]$State.SchemaVersion -notin @("1.0", "2.0")) {
        throw "Unknown state version: $($State.SchemaVersion)"
    }
    if ([string]$State.SchemaVersion -eq "2.0") {
        foreach ($name in @("TaskContext", "ArchitectWork", "ActiveWorkIds", "ActiveFixAttempt",
            "RetainedCandidate", "LastReview", "CompletionRequalificationRequired")) {
            if ($State.PSObject.Properties.Name -notcontains $name) { throw "State 2.0 is missing '$name'." }
        }
        $work = $State.ArchitectWork
        foreach ($name in @("Revision", "OrientationRequired", "Goal", "Orders", "OverallAssessment")) {
            if ($null -eq $work -or $work.PSObject.Properties.Name -notcontains $name) {
                throw "State 2.0 architecture work is missing '$name'."
            }
        }
        if ([int]$work.Revision -lt 0 -or (-not $work.OrientationRequired -and
            ($null -eq $work.Goal -or [string]::IsNullOrWhiteSpace([string]$work.Goal.statement)))) {
            throw "State 2.0 has an invalid goal revision or missing clarified goal."
        }
        $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($order in @($work.Orders)) {
            if ([string]::IsNullOrWhiteSpace([string]$order.id) -or -not $ids.Add([string]$order.id) -or
                $order.status -notin @("open", "accepted", "withdrawn")) {
                throw "State 2.0 has invalid architecture work."
            }
        }
    }
    if ([string]$State.Status -notin @(
        "running",
        "paused",
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
    Initialize-ReviewLoopOperator $state
    foreach ($name in @("ActiveRoleCall", "ActiveCriticCall", "PartialFixRecovery", "ActiveHostGateRecovery")) {
        if ($state.PSObject.Properties.Name -notcontains $name) {
            $state | Add-Member -NotePropertyName $name -NotePropertyValue $null
        }
    }
    if ($state.PSObject.Properties.Name -notcontains "ReviewCyclesThisInvocation") {
        $state | Add-Member -NotePropertyName ReviewCyclesThisInvocation `
            -NotePropertyValue ([int]$state.ReviewCycle)
    }
    if ($state.PSObject.Properties.Name -notcontains "ReviewBaseSetting") {
        $state | Add-Member -NotePropertyName ReviewBaseSetting `
            -NotePropertyValue ([string]$state.ReviewBase)
    }
    if ($state.PSObject.Properties.Name -notcontains "LoopCommits") {
        $state | Add-Member -NotePropertyName LoopCommits -NotePropertyValue @()
    }
    if ($state.PSObject.Properties.Name -notcontains "LoopCommitsInitialized") {
        $state | Add-Member -NotePropertyName LoopCommitsInitialized `
            -NotePropertyValue $false
    }
    if ($state.PSObject.Properties.Name -notcontains "ActiveFindingSource") {
        $state | Add-Member -NotePropertyName ActiveFindingSource -NotePropertyValue ""
    }
    if ($state.PSObject.Properties.Name -notcontains "LessonsLearned") {
        $state | Add-Member -NotePropertyName LessonsLearned -NotePropertyValue (
            [pscustomobject][ordered]@{
                Status = "pending"
                Attempt = 0
                TriggerHead = ""
                TriggerCommitCount = 0
                CompletedHead = ""
                ReviewAfterCommit = $false
            })
    }
    else {
        foreach ($entry in @(
            @{ Name = "Status"; Value = "pending" },
            @{ Name = "Attempt"; Value = 0 },
            @{ Name = "TriggerHead"; Value = "" },
            @{ Name = "TriggerCommitCount"; Value = 0 },
            @{ Name = "CompletedHead"; Value = "" },
            @{ Name = "ReviewAfterCommit"; Value = $false }
        )) {
            if ($state.LessonsLearned.PSObject.Properties.Name -notcontains $entry.Name) {
                $state.LessonsLearned | Add-Member `
                    -NotePropertyName $entry.Name -NotePropertyValue $entry.Value
            }
        }
    }
    Initialize-ReviewLoopRoleSessions -State $state
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
        CriticId = [string](Get-ReviewLoopObjectProperty -Object $Call -Name "CriticId" -Default "")
        WorkRevision = [int](Get-ReviewLoopObjectProperty -Object $Call -Name "WorkRevision" -Default -1)
        OperatorRevision = [int](Get-ReviewLoopObjectProperty -Object $Call -Name 'OperatorRevision' -Default 0)
        OperatorMessageIds = @((Get-ReviewLoopObjectProperty -Object $Call -Name 'OperatorMessageIds' -Default @()))
        RepositorySnapshot = Get-ReviewLoopObjectProperty -Object $Call -Name RepositorySnapshot
        CoveredReviewCount = [int](Get-ReviewLoopObjectProperty -Object $Call -Name "CoveredReviewCount" -Default 0)
        RepositoryHead = [string](Get-ReviewLoopObjectProperty `
            -Object $Call -Name "RepositoryHead" -Default "")
        WorktreeFingerprint = [string](Get-ReviewLoopObjectProperty `
            -Object $Call -Name "WorktreeFingerprint" -Default "")
        RecordedAt = [DateTimeOffset]::UtcNow.ToString("O")
    }
    $State.RoleCalls = @($State.RoleCalls) + @($record)
    return $State
}

function New-ReviewLoopArchitectWork {
    return [pscustomobject][ordered]@{
        Revision = 0
        OrientationRequired = $true
        Goal = $null
        Orders = @()
        OverallAssessment = $null
    }
}

function Get-ReviewLoopOpenWork {
    param([Parameter(Mandatory = $true)][object]$State)
    return @($State.ArchitectWork.Orders | Where-Object { $_.status -eq "open" })
}

function Merge-ReviewLoopWorkOrders {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Orders
    )
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $changed = $false
    foreach ($order in $Orders) {
        if (-not $seen.Add([string]$order.id)) { throw "Duplicate architecture work ID '$($order.id)'." }
        $existing = @($State.ArchitectWork.Orders | Where-Object { $_.id -ceq $order.id })
        if ($existing.Count -gt 0 -and $existing[0].status -ne "open") {
            throw "Architecture work '$($order.id)' is already closed; use a new ID for new work."
        }
        $value = [pscustomobject][ordered]@{
            id = [string]$order.id
            objective = [string]$order.objective
            rationale = [string]$order.rationale
            doneWhen = [string]$order.doneWhen
            evidence = @($order.evidence)
            status = "open"
            outcomeEvidence = ""
        }
        if ($existing.Count -eq 0) {
            $State.ArchitectWork.Orders = @($State.ArchitectWork.Orders) + @($value)
            $changed = $true
        }
        elseif ((ConvertTo-ReviewLoopJsonCompact $existing[0]) -ne
                (ConvertTo-ReviewLoopJsonCompact $value)) {
            $State.ArchitectWork.Orders = @($State.ArchitectWork.Orders | ForEach-Object {
                if ($_.id -ceq $order.id) { $value } else { $_ }
            })
            $changed = $true
        }
    }
    if ($changed) {
        $State.ArchitectWork.Revision++
        $State.ArchitectWork.OverallAssessment = $null
    }
}

function Set-ReviewLoopWorkSelection {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Ids
    )
    $open = @(Get-ReviewLoopOpenWork -State $State | ForEach-Object { [string]$_.id })
    if (@($Ids | Select-Object -Unique).Count -ne $Ids.Count -or
        @($Ids | Where-Object { $_ -cnotin $open }).Count -gt 0) {
        throw "Architect selected duplicate or unknown open work IDs."
    }
    $State.ActiveWorkIds = @($Ids)
}

function Register-ReviewLoopOrientation {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][object]$Result
    )
    $preview = [pscustomobject]@{ ArchitectWork = $State.ArchitectWork.PSObject.Copy() }
    $preview.ArchitectWork.Goal = $Result.goal
    $preview.ArchitectWork.Revision++
    $preview.ArchitectWork.OverallAssessment = $null
    Merge-ReviewLoopWorkOrders -State $preview -Orders @($Result.orders)
    $preview.ArchitectWork.OrientationRequired = $false
    $State.ArchitectWork = $preview.ArchitectWork
}

function Register-ReviewLoopWorkPlan {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][object]$Result,
        [switch]$RequireSelection
    )
    $preview = [pscustomobject]@{
        ArchitectWork = $State.ArchitectWork.PSObject.Copy()
        ActiveWorkIds = @($State.ActiveWorkIds)
    }
    Merge-ReviewLoopWorkOrders -State $preview -Orders @($Result.orders)
    Set-ReviewLoopWorkSelection -State $preview -Ids @($Result.selectedWorkIds)
    if ($RequireSelection -and $preview.ActiveWorkIds.Count -eq 0) {
        throw "Architect must select necessary open work when no native findings require implementation."
    }
    $State.ArchitectWork = $preview.ArchitectWork
    $State.ActiveWorkIds = @($preview.ActiveWorkIds)
}

function Register-ReviewLoopWorkAssessment {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][object]$Result,
        [switch]$RequireGoalDecision
    )
    # Validate the complete assessment without changing authoritative work.
    $preview = [pscustomobject]@{ ArchitectWork = $State.ArchitectWork.PSObject.Copy() }
    Merge-ReviewLoopWorkOrders -State $preview -Orders @($Result.newOrders)
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $openIds = @(Get-ReviewLoopOpenWork -State $preview | ForEach-Object { [string]$_.id })
    foreach ($outcome in @($Result.workOutcomes)) {
        if (-not $seen.Add([string]$outcome.id) -or $outcome.id -cnotin $openIds) {
            throw "Architect assessed duplicate or unknown open work '$($outcome.id)'."
        }
        if ([string]::IsNullOrWhiteSpace([string]$outcome.evidence)) {
            throw "Architecture work outcomes require evidence."
        }
    }
    if ($Result.accept -and
        @($State.ActiveWorkIds | Where-Object { -not $seen.Contains([string]$_) }).Count -gt 0) {
        throw "Acceptance must explicitly assess every selected architecture work item."
    }
    if ($Result.goalComplete -and (-not $Result.accept -or
        @($openIds | Where-Object { -not $seen.Contains($_) }).Count -gt 0)) {
        throw "Overall completion cannot leave architecture work open or reject the current tree."
    }
    if ($RequireGoalDecision -and (-not $Result.accept -or -not $Result.goalComplete) -and
        @(Get-ReviewLoopOpenWork -State $preview).Count -eq 0) {
        throw "Architect withheld overall completion without identifying necessary work."
    }
    $State.ArchitectWork = $preview.ArchitectWork
    $Result | Add-Member -Force -NotePropertyName WorkRevision -NotePropertyValue ([int]$State.ArchitectWork.Revision)
}

function Complete-ReviewLoopArchitectureWork {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][object]$Result,
        [Parameter(Mandatory = $true)][string]$RepoPath
    )
    if ([int](Get-ReviewLoopObjectProperty -Object $Result -Name WorkRevision -Default -1) -ne
        [int]$State.ArchitectWork.Revision) {
        $State.ArchitectWork.OverallAssessment = $null
        return
    }
    foreach ($outcome in @($Result.workOutcomes)) {
        $order = @($State.ArchitectWork.Orders | Where-Object { $_.id -ceq $outcome.id })[0]
        $order.status = [string]$outcome.status
        $order.outcomeEvidence = [string]$outcome.evidence
    }
    if (@($Result.workOutcomes).Count -gt 0) { $State.ArchitectWork.Revision++ }
    $State.ArchitectWork.OverallAssessment = $null
    if ($Result.goalComplete -and @(Get-ReviewLoopOpenWork -State $State).Count -eq 0) {
        $snapshot = Get-ReviewLoopRepositorySnapshot -RepoPath $RepoPath
        $State.ArchitectWork.OverallAssessment = [pscustomobject]@{
            Revision = [int]$State.ArchitectWork.Revision
            Head = [string]$snapshot.Head
            Fingerprint = [string]$snapshot.Fingerprint
            IndexFingerprint = [string]$snapshot.IndexFingerprint
            RefsFingerprint = [string]$snapshot.RefsFingerprint
            Summary = [string]$Result.summary
            OperatorRevision = [int](Get-ReviewLoopObjectProperty $Result -Name OperatorRevision -Default 0)
        }
    }
}

function Test-ReviewLoopGoalAccepted {
    param([Parameter(Mandatory = $true)][object]$State)
    $assessment = $State.ArchitectWork.OverallAssessment
    if (@(Get-ReviewLoopPendingOperatorMessages $State -Role Architect).Count -gt 0) { return $false }
    if ($State.ArchitectWork.OrientationRequired -or $null -eq $assessment -or
        @(Get-ReviewLoopOpenWork -State $State).Count -gt 0 -or
        $null -ne $State.RetainedCandidate -or $null -ne $State.PendingCommit -or
        $null -ne $State.ActiveRoleCall -or $null -ne $State.ActiveCriticCall -or
        $null -ne $State.Operator.InterruptedFixerCall -or
        $null -ne $State.ActiveHostGateRecovery -or $null -ne $State.BlockedCleanup -or
        $null -ne $State.PartialFixRecovery) {
        return $false
    }
    $snapshot = Get-ReviewLoopRepositorySnapshot -RepoPath $State.RepoPath
    return [int]$assessment.Revision -eq [int]$State.ArchitectWork.Revision -and
        [int](Get-ReviewLoopObjectProperty $assessment -Name OperatorRevision -Default 0) -eq [int]$State.Operator.Revisions.Architect -and
        $assessment.Head -eq $snapshot.Head -and
        $assessment.Fingerprint -eq $snapshot.Fingerprint -and
        $assessment.IndexFingerprint -eq $snapshot.IndexFingerprint -and
        $assessment.RefsFingerprint -eq $snapshot.RefsFingerprint -and
        (Test-ReviewLoopGitClean -RepoPath $State.RepoPath)
}

function ConvertTo-ReviewLoopWorkState {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][string]$RepoPath
    )
    if ([string]$State.SchemaVersion -eq "2.0") { return }
    $inflight = @(@("ActiveRoleCall", "ActiveCriticCall", "PendingCommit",
        "ActiveHostGateRecovery", "BlockedCleanup", "PartialFixRecovery") | Where-Object {
        $null -ne (Get-ReviewLoopObjectProperty -Object $State -Name $_)
    })
    if ($inflight.Count -gt 0 -or -not [string]::IsNullOrWhiteSpace([string]$State.ActiveClusterId) -or
        @($State.ActiveFindingIds).Count -gt 0 -or $null -ne $State.LastFixerResult -or $null -ne $State.ActiveStrategy -or
        (-not (Test-ReviewLoopCycleBoundary -State $State) -and $State.Status -ne "completed") -or
        -not (Test-ReviewLoopGitClean -RepoPath $RepoPath)) {
        throw "State 1.0 requires a clean, inactive cycle boundary before upgrading. Finish the active round with the previous tool version, then resume with this version."
    }
    Assert-ReviewLoopResumeInvariant -State $State -RepoPath $RepoPath -ReviewBase $State.ReviewBase
    $backup = "$StatePath.before-work-state-2.0.json"
    if (-not (Test-Path -LiteralPath $backup)) {
        Copy-Item -LiteralPath $StatePath -Destination $backup -ErrorAction Stop
    }
    $State.SchemaVersion = "2.0"
    $State | Add-Member -NotePropertyName TaskContext -NotePropertyValue ""
    $State | Add-Member -NotePropertyName CompletionRequalificationRequired -NotePropertyValue $true
    $State | Add-Member -NotePropertyName ArchitectWork -NotePropertyValue (New-ReviewLoopArchitectWork)
    $State | Add-Member -NotePropertyName ActiveWorkIds -NotePropertyValue @()
    $State | Add-Member -NotePropertyName ActiveFixAttempt -NotePropertyValue 0
    $State | Add-Member -NotePropertyName RetainedCandidate -NotePropertyValue $null
    $State | Add-Member -NotePropertyName LastReview -NotePropertyValue $null
    $State.CleanPasses = 0
    $State.CleanHead = ""
    $State.Stage = "initialized"
    $State.Status = "running"
    $State.ExitCode = 0
    Write-ReviewLoopState -Path $StatePath -State $State | Out-Null
}

function Assert-ReviewLoopRetainedCandidate {
    param([Parameter(Mandatory = $true)][object]$State)
    $candidate = $State.RetainedCandidate
    if ($null -eq $candidate) { return }
    Assert-ReviewLoopRepositoryUnchanged -RepoPath $State.RepoPath -Snapshot $candidate.Snapshot -Operation "The retained Fixer candidate"
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
