function Initialize-ReviewLoopOperator {
    param([object]$State)
    if ($null -eq $State) { return }
    if ($State.PSObject.Properties.Name -notcontains 'Operator') {
        $State | Add-Member -NotePropertyName Operator -NotePropertyValue ([pscustomobject]@{
            Version = 4
            Revisions = [pscustomobject]@{ Reviewer = 0; Architect = 0; Fixer = 0 }
            Requests = @()
            Boundary = $null
        })
    }
    if ($State.Operator.Version -notin @(1,2,3,4)) { throw 'Unknown operator state version.' }
    # Explicit additive upgrade; older tools must not ignore new request semantics.
    $State.Operator.Version = 4
    foreach ($name in @('Pause', 'TargetedTest', 'Assessment', 'FixerInput', 'InterruptedFixerCall')) {
        if ($State.Operator.PSObject.Properties.Name -notcontains $name) {
            $State.Operator | Add-Member -NotePropertyName $name -NotePropertyValue $null
        }
    }
}

function Get-ReviewLoopOperatorCanonicalPath {
    param([string]$Path)
    $absolute = [IO.Path]::GetFullPath($Path)
    $ancestor = [IO.DirectoryInfo]::new($absolute)
    while ($null -ne $ancestor) {
        if ($ancestor.Exists -and ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            $target = $ancestor.ResolveLinkTarget($true)
            return Get-ReviewLoopOperatorCanonicalPath (Join-Path $target.FullName ([IO.Path]::GetRelativePath($ancestor.FullName, $absolute)))
        }
        $ancestor = $ancestor.Parent
    }
    return $absolute.TrimEnd('\', '/').ToLowerInvariant()
}

function Get-ReviewLoopOperatorIdentity {
    param([object]$State)
    return [ordered]@{
        StatePath = Get-ReviewLoopOperatorCanonicalPath (Join-Path $State.RunRoot 'run-v1.json')
        RunId = [string]$State.RunId
        RepoPath = Get-ReviewLoopOperatorCanonicalPath $State.RepoPath
        Branch = [string]$State.Branch
        ReviewBaseCommit = [string]$State.ReviewBaseCommit
        CreatedAtTicks = ([DateTimeOffset]$State.CreatedAt).UtcTicks.ToString([Globalization.CultureInfo]::InvariantCulture)
    }
}

function Get-ReviewLoopOperatorMailbox {
    param([object]$State)
    $identity = Get-ReviewLoopOperatorIdentity $State
    $key = Get-ReviewLoopSha256 (ConvertTo-ReviewLoopJsonCompact $identity)
    $root = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    $path = Get-ReviewLoopOperatorCanonicalPath (Join-Path $root "CodexReviewLoop\operator\$key")
    $repo = [string]$identity.RepoPath
    if ((Test-ReviewLoopSamePath -Left $path -Right $repo) -or
        $path.StartsWith($repo.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The operator mailbox must be outside the reviewed worktree.'
    }
    return $path
}

function Invoke-ReviewLoopOperatorLock {
    param([object]$State, [scriptblock]$Action)
    $mailbox = Get-ReviewLoopOperatorMailbox $State
    [IO.Directory]::CreateDirectory($mailbox) | Out-Null
    $lease = $null
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(10)
    while ($null -eq $lease) {
        try {
            $lease = [IO.FileStream]::new((Join-Path $mailbox 'mailbox.lock'),
                [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        }
        catch [IO.IOException] {
            if ([DateTimeOffset]::UtcNow -ge $deadline) { throw 'Operator mailbox is busy; retry the same message ID.' }
            Start-Sleep -Milliseconds 25
        }
    }
    try { & $Action $mailbox } finally { $lease.Dispose() }
}

function Send-ReviewLoopOperatorMessage {
    [CmdletBinding(DefaultParameterSetName = 'Message')]
    param(
        [Parameter(Mandatory, Position = 0)][string]$RunRoot,
        [Parameter(Mandatory, Position = 1, ParameterSetName = 'Message')][string[]]$To,
        [Parameter(Mandatory, ParameterSetName = 'Pause')]
        [ValidateSet('AfterRole','AfterRound','BeforeCommit','BeforeCompletion')][string]$PauseAt,
        [Parameter(Mandatory, ParameterSetName = 'Reassessment')][switch]$ReassessArchitect,
        [Parameter(Mandatory, ParameterSetName = 'Critic')][switch]$RequestCritic,
        [Parameter(Mandatory, Position = 2)][string]$Message,
        [Parameter(Position = 3)][string]$Id = ([guid]::NewGuid().ToString('D')),
        [Parameter(ParameterSetName = 'Message')][switch]$RequireDelivery
    )
    $guid = [guid]::Empty
    if (-not [guid]::TryParse($Id, [ref]$guid)) { throw 'Message ID must be a GUID.' }
    $Id = $guid.ToString('D')
    if ($PauseAt) {
        $PauseAt = switch ($PauseAt) {
            AfterRole { 'AfterRole' }; AfterRound { 'AfterRound' }
            BeforeCommit { 'BeforeCommit' }; BeforeCompletion { 'BeforeCompletion' }
            default { throw 'Unknown pause boundary.' }
        }
    }
    # pwsh -File passes a comma-separated native argument as one string.
    $recipients = @($To | Where-Object { $null -ne $_ } | ForEach-Object { $_ -split ',' } | ForEach-Object {
        switch ($_.Trim().ToLowerInvariant()) {
            reviewer { 'Reviewer' }; architect { 'Architect' }; fixer { 'Fixer' }
            default { throw 'Recipients must be Reviewer, Architect or Fixer.' }
        }
    } | Sort-Object -Unique)
    if ($ReassessArchitect) { $recipients = @('Architect') }
    if (-not $PauseAt -and -not $RequestCritic -and $recipients.Count -eq 0) { throw 'Select at least one recipient.' }
    if ([string]::IsNullOrWhiteSpace($Message) -or $Message.Length -gt 4000) {
        throw 'Message must contain 1 to 4000 characters.'
    }
    $statePath = Join-Path (Resolve-ReviewLoopPath $RunRoot -MustExist) 'run-v1.json'
    $state = Read-ReviewLoopState $statePath
    $identity = Get-ReviewLoopOperatorIdentity $state
    if ((Get-ReviewLoopOperatorCanonicalPath $statePath) -cne $identity.StatePath) {
        throw 'Run identity mismatch.'
    }
    $request = [pscustomobject][ordered]@{
        Version = 1; Id = $Id; Run = $identity; To = $recipients
        Message = $Message; RequireDelivery = [bool]$RequireDelivery
    }
    if ($PauseAt) {
        $request = [pscustomobject][ordered]@{
            Version = 2; Kind = 'pause'; Id = $Id; Run = $identity
            Message = $Message; PauseAt = $PauseAt
        }
    }
    elseif ($ReassessArchitect) {
        $request = [pscustomobject][ordered]@{
            Version = 3; Kind = 'architect_reassessment'; Id = $Id; Run = $identity
            To = @('Architect'); Message = $Message; RequireDelivery = $true
        }
    }
    elseif ($RequestCritic) {
        $request = [pscustomobject][ordered]@{
            Version = 4; Kind = 'critic_request'; Id = $Id; Run = $identity
            Message = $Message
        }
    }
    Invoke-ReviewLoopOperatorLock $state {
        param($mailbox)
        $current = Read-ReviewLoopState $statePath
        if ((ConvertTo-ReviewLoopJsonCompact (Get-ReviewLoopOperatorIdentity $current)) -cne
            (ConvertTo-ReviewLoopJsonCompact $identity)) { throw 'Run identity mismatch.' }
        $path = Join-Path $mailbox "$Id.json"
        if (Test-Path -LiteralPath $path) {
            $existing = Read-ReviewLoopJson $path
            $existing.PSObject.Properties.Remove('Target')
            if ((ConvertTo-ReviewLoopJsonCompact $existing) -cne
                (ConvertTo-ReviewLoopJsonCompact $request)) { throw 'Message ID already has different content.' }
            return
        }
        if ($current.Status -eq 'completed' -or
            (-not $PauseAt -and -not $ReassessArchitect -and -not $RequestCritic -and $null -ne $current.Operator.Boundary -and $current.Operator.Boundary.Kind -eq 'completion')) {
            throw 'Run completion is sealed.'
        }
        if ($PauseAt) {
            $active = if ($null -ne $current.ActiveCriticCall) { $current.ActiveCriticCall } else { $current.ActiveRoleCall }
            $request | Add-Member -NotePropertyName Target -NotePropertyValue ([pscustomobject]@{
                CallId = [string](Get-ReviewLoopObjectProperty $active -Name CallId -Default '')
                Cycle = [int]$current.ReviewCycle
                Stage = [string]$current.Stage
                Boundary = [string](Get-ReviewLoopObjectProperty $current.Operator.Boundary -Name Kind -Default '')
            })
        }
        $temporary = Join-Path $mailbox ('.' + [guid]::NewGuid().ToString('N') + '.tmp')
        try {
            Write-ReviewLoopUtf8File -Path $temporary -Content ($request | ConvertTo-Json -Depth 20)
            [IO.File]::Move($temporary, $path, $false)
        }
        finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
    }
    # Publication is not a delivery receipt. The ID is sufficient to retry.
    return $Id
}

function Import-ReviewLoopOperatorMessages {
    param([object]$State, [string]$Mailbox, [switch]$PausesOnly)
    Initialize-ReviewLoopOperator $State
    $identity = ConvertTo-ReviewLoopJsonCompact (Get-ReviewLoopOperatorIdentity $State)
    foreach ($file in @(Get-ChildItem -LiteralPath $Mailbox -Filter '*.json' -File | Sort-Object Name)) {
        $id = $file.BaseName
        if (@($State.Operator.Requests | Where-Object Id -CEQ $id).Count -gt 0) { continue }
        $reason = ''
        $request = $null
        try {
            $request = Read-ReviewLoopJson $file.FullName
            $guid = [guid]::Empty
            if (-not [guid]::TryParseExact($id, 'D', [ref]$guid) -or $request.Id -cne $id) {
                throw 'invalid message ID'
            }
            if ($request.Version -notin @(1,2,3,4)) { throw 'unknown request version' }
            if ((ConvertTo-ReviewLoopJsonCompact $request.Run) -cne $identity) { throw 'run identity mismatch' }
            if ($request.Version -eq 2) {
                if ($request.Kind -cne 'pause' -or $request.PauseAt -cnotin @('AfterRole','AfterRound','BeforeCommit','BeforeCompletion') -or
                    $request.Message -isnot [string] -or [string]::IsNullOrWhiteSpace($request.Message) -or $request.Message.Length -gt 4000 -or
                    $null -eq $request.Target -or $request.Target.CallId -isnot [string] -or $request.Target.Cycle -isnot [long] -and $request.Target.Cycle -isnot [int] -or
                    [long]$request.Target.Cycle -lt 0 -or $request.Target.Stage -isnot [string] -or
                    $request.Target.Boundary -cnotin @('','commit','completion')) { throw 'invalid request' }
            }
            elseif ($request.Version -eq 4) {
                if ($request.Kind -cne 'critic_request' -or $request.Message -isnot [string] -or
                    [string]::IsNullOrWhiteSpace($request.Message) -or $request.Message.Length -gt 4000 -or
                    @($request.PSObject.Properties.Name | Where-Object { $_ -cnotin @('Version','Kind','Id','Run','Message') }).Count -gt 0) {
                    throw 'invalid request'
                }
            }
            elseif ($request.RequireDelivery -isnot [bool] -or $request.Message -isnot [string] -or
                [string]::IsNullOrWhiteSpace($request.Message) -or $request.Message.Length -gt 4000 -or
                @($request.To).Count -eq 0 -or @($request.To | Where-Object { $_ -cnotin @('Reviewer','Architect','Fixer') }).Count -gt 0 -or
                @($request.To | Select-Object -Unique).Count -ne @($request.To).Count) { throw 'invalid message' }
            if ($request.Version -eq 3 -and ($request.Kind -cne 'architect_reassessment' -or
                @($request.To).Count -ne 1 -or $request.To[0] -cne 'Architect' -or -not $request.RequireDelivery)) {
                throw 'invalid request'
            }
        }
        catch {
            $reason = if ($_.Exception.Message -cin @('invalid message ID','unknown request version','run identity mismatch','invalid message')) {
                $_.Exception.Message
            } else { 'invalid request' }
        }
        # Ordinary message sets stay sealed; control requests remain observable.
        if (-not $reason -and $request.Version -eq 1 -and ($PausesOnly -or $null -ne $State.Operator.Boundary)) { continue }
        if (-not $reason -and $request.Version -eq 2) {
            $State.Operator.Requests += [pscustomobject]@{
                Id = $id; Kind = 'pause'; Message = $request.Message; PauseAt = $request.PauseAt
                Target = $request.Target; Status = 'pending'; Missed = $false; Reached = ''; Stage = ''
                RequireDelivery = $false; Deliveries = @(); Rejection = ''
            }
            continue
        }
        if (-not $reason -and $request.Version -eq 4) {
            $State.Operator.Requests += [pscustomobject]@{
                Id = $id; Kind = 'critic_request'; Message = $request.Message
                Status = 'pending'; CallId = ''; RequireDelivery = $false
                Deliveries = @(); Rejection = ''
            }
            continue
        }
        $deliveries = @()
        if (-not $reason) {
            foreach ($role in $request.To) {
                $State.Operator.Revisions.$role++
                $deliveries += [pscustomobject]@{ Role = $role; Status = 'pending'; CallId = '' }
            }
        }
        $State.Operator.Requests += [pscustomobject]@{
            Id = $id; Message = if ($reason) { '' } else { $request.Message }
            Kind = if (-not $reason -and $request.Version -eq 3) { 'architect_reassessment' } else { 'message' }
            RequireDelivery = -not $reason -and $request.RequireDelivery
            Deliveries = $deliveries; Rejection = $reason
        }
        if ($reason) { Write-ReviewLoopStatus -Message "$id rejected: $reason" -Kind Warning }
    }
}

function Sync-ReviewLoopOperatorMessages {
    param([object]$State, [string]$StatePath)
    Initialize-ReviewLoopOperator $State
    # Ordinary messages retain their sealed set through recovery.
    Invoke-ReviewLoopOperatorLock $State {
        param($mailbox)
        Import-ReviewLoopOperatorMessages -State $State -Mailbox $mailbox
        Write-ReviewLoopState -Path $StatePath -State $State | Out-Null
    }
}

function Get-ReviewLoopPendingOperatorMessages {
    param([object]$State, [string]$Role = '', [switch]$Required, [switch]$Reassessment)
    Initialize-ReviewLoopOperator $State
    return @($State.Operator.Requests | Where-Object {
        (-not $Required -or $_.RequireDelivery) -and
        (-not $Reassessment -or (Get-ReviewLoopObjectProperty $_ -Name Kind -Default '') -eq 'architect_reassessment') -and
        @($_.Deliveries | Where-Object { $_.Status -eq 'pending' -and (-not $Role -or $_.Role -eq $Role) }).Count -gt 0
    })
}

function Get-ReviewLoopPendingCriticRequests {
    param([object]$State)
    return @($State.Operator.Requests | Where-Object {
        (Get-ReviewLoopObjectProperty $_ -Name Kind -Default '') -eq 'critic_request' -and $_.Status -eq 'pending'
    })
}

function Complete-ReviewLoopOperatorReassessment {
    param([object]$State, [object]$Call)
    # Called only after the normal Architect contract has been registered.
    foreach ($request in @(Get-ReviewLoopPendingOperatorMessages $State -Reassessment)) {
        if ($request.Id -cin @($Call.OperatorMessageIds)) {
            $request.Deliveries[0].Status = 'delivered'
            $request.Deliveries[0].CallId = [string]$Call.CallId
            Write-ReviewLoopStatus -Message "$($request.Id) evaluated by Architect" -Kind Info
        }
    }
}

function Close-ReviewLoopOperatorBoundary {
    param([object]$State, [string]$StatePath,
        [ValidateSet('commit','completion')][string]$Kind,
        [string[]]$AllowRoles = @())
    Initialize-ReviewLoopOperator $State
    if ($null -ne $State.Operator.Boundary) {
        if ($State.Operator.Boundary.Kind -ne $Kind) { throw 'Operator transaction boundary mismatch.' }
        Sync-ReviewLoopOperatorMessages $State $StatePath
        if ('Architect' -notin $AllowRoles -and @(Get-ReviewLoopPendingOperatorMessages $State -Reassessment).Count -gt 0) {
            return @('Architect')
        }
        return @()
    }
    return @(Invoke-ReviewLoopOperatorLock $State {
        param($mailbox)
        Import-ReviewLoopOperatorMessages -State $State -Mailbox $mailbox
        if ($Kind -eq 'commit') {
            Invoke-ReviewLoopPauseBoundary $State $StatePath BeforeCommit -Locked
        }
        $roles = @(Get-ReviewLoopPendingOperatorMessages $State -Required | ForEach-Object Deliveries |
            Where-Object { $_.Status -eq 'pending' -and $_.Role -notin $AllowRoles } |
            Select-Object -ExpandProperty Role -Unique)
        if ($roles.Count -eq 0) {
            $State.Operator.Boundary = [pscustomobject]@{
                Kind = $Kind; Id = [guid]::NewGuid().ToString('D')
                RequestIds = @($State.Operator.Requests | ForEach-Object Id)
            }
        }
        Write-ReviewLoopState -Path $StatePath -State $State | Out-Null
        $roles
    })
}

function Open-ReviewLoopOperatorBoundary {
    param([object]$State)
    Initialize-ReviewLoopOperator $State
    $State.Operator.Boundary = $null
}

function Invoke-ReviewLoopPauseBoundary {
    param([object]$State, [string]$StatePath,
        [ValidateSet('Step','AfterRole','AfterRound','BeforeCommit','BeforeCompletion','CommitRecovery')][string]$At = 'Step',
        [switch]$Locked)
    Initialize-ReviewLoopOperator $State
    if (-not $Locked) {
        Invoke-ReviewLoopOperatorLock $State {
            param($mailbox)
            Import-ReviewLoopOperatorMessages $State $mailbox
            Invoke-ReviewLoopPauseBoundary $State $StatePath $At -Locked
            Write-ReviewLoopState $StatePath $State | Out-Null
        }
        return
    }
    if ($null -ne $State.ActiveRoleCall -or $null -ne $State.ActiveCriticCall -or
        $null -ne $State.Operator.InterruptedFixerCall -or
        $null -ne $State.ActiveHostGateRecovery) { return }
    if ($null -ne $State.PendingCommit -and $At -ne 'CommitRecovery') { return }
    $postReviewStages = @('lessons_learned_analyzing', 'lessons_learned_completed')
    $roundBoundary = (Test-ReviewLoopCycleBoundary $State) -or $State.Stage -in $postReviewStages
    $due = @($State.Operator.Requests | Where-Object {
        if ((Get-ReviewLoopObjectProperty $_ -Name Kind -Default '') -ne 'pause' -or $_.Status -ne 'pending') { return $false }
        $missed = ($_.PauseAt -eq 'BeforeCommit' -and ($_.Target.Boundary -eq 'commit' -or
            $At -eq 'BeforeCompletion' -or $null -ne $State.PendingCommit)) -or
            ($_.PauseAt -eq 'AfterRound' -and [int]$State.ReviewCycle -gt [int]$_.Target.Cycle)
        $_.Missed = [bool]$missed
        return $missed -or $_.PauseAt -eq 'AfterRole' -or $_.PauseAt -eq $At -or
            ($_.PauseAt -eq 'AfterRound' -and ($roundBoundary -or $_.Target.Stage -in $postReviewStages -or $At -eq 'BeforeCompletion'))
    })
    if ($due.Count -eq 0) { return }
    $latest = $State.RoleCalls | Select-Object -Last 1
    $completedFixer = $State.Stage -eq 'fixing' -and $null -ne $latest -and $latest.Role -eq 'Fixer' -and $latest.Success
    if ($State.Stage -eq 'fixing' -and $null -ne $State.LastFixerResult -and
        -not $State.LastFixerResult.Success -and -not $completedFixer) { return }
    $snapshot = Get-ReviewLoopRepositorySnapshot $State.RepoPath
    if ($null -eq $State.PendingCommit) {
        if ($snapshot.Head -cne $State.CurrentHead) { throw 'HEAD changed before the requested pause.' }
        Assert-ReviewLoopRetainedCandidate $State
        if (-not (Test-ReviewLoopGitClean $State.RepoPath)) {
            $owned = if ($completedFixer) { $latest.RepositorySnapshot }
                elseif ($null -ne $State.RetainedCandidate) { $State.RetainedCandidate.Snapshot }
                else { Get-ReviewLoopObjectProperty $State.LastFixerResult -Name RepositorySnapshot }
            Assert-ReviewLoopRepositoryUnchanged -RepoPath $State.RepoPath -Snapshot $owned -Operation 'The candidate before pausing'
        }
    }
    $backup = if (-not (Test-ReviewLoopGitClean $State.RepoPath)) {
        New-ReviewLoopRepositoryBackup -RepoPath $State.RepoPath -LogRoot $State.RunRoot -Snapshot $snapshot
    } else { $null }
    $reached = if ($At -eq 'Step' -and $roundBoundary) { 'AfterRound' } else { $At }
    foreach ($request in $due) {
        $request.Status = 'reached'; $request.Reached = $reached; $request.Stage = [string]$State.Stage
    }
    $State.Operator.Pause = [pscustomobject]@{
        RequestIds = @($due | ForEach-Object Id); At = $reached; Stage = [string]$State.Stage
        Snapshot = $snapshot; Backup = $backup
    }
    $State.Status = 'paused'; $State.ExitCode = 5
    Write-ReviewLoopState $StatePath $State | Out-Null
    $exception = [InvalidOperationException]::new('Operator pause reached.')
    $exception.Data['ReviewLoopPaused'] = $true
    throw $exception
}

function Assert-ReviewLoopPausedRepository {
    param([object]$State)
    $pause = $State.Operator.Pause
    if ($null -eq $pause) { throw 'Paused run has no continuation checkpoint.' }
    Assert-ReviewLoopRepositoryUnchanged -RepoPath $State.RepoPath -Snapshot $pause.Snapshot -Operation 'The paused checkpoint'
    if ($null -ne $pause.Backup) {
        $backup = $pause.Backup
        if ((ConvertTo-ReviewLoopJsonCompact (Read-ReviewLoopJson $backup.ManifestPath)) -cne
            (ConvertTo-ReviewLoopJsonCompact $backup) -or
            (Get-FileHash -LiteralPath (Join-Path $backup.Root 'index') -Algorithm SHA256).Hash -ne $backup.IndexSha256) {
            throw 'The paused candidate backup is damaged.'
        }
        foreach ($entry in @($backup.Entries | Where-Object Exists)) {
            if ((Get-FileHash -LiteralPath (Join-Path (Join-Path $backup.Root 'files') $entry.Path) -Algorithm SHA256).Hash -ne $entry.Sha256) {
                throw 'The paused candidate backup is damaged.'
            }
        }
    }
}
