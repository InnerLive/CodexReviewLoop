function Initialize-ReviewLoopOperator {
    param([object]$State)
    if ($null -eq $State) { return }
    if ($State.PSObject.Properties.Name -notcontains 'Operator') {
        $State | Add-Member -NotePropertyName Operator -NotePropertyValue ([pscustomobject]@{
            Version = 1
            Revisions = [pscustomobject]@{ Reviewer = 0; Architect = 0; Fixer = 0 }
            Requests = @()
            Boundary = $null
        })
    }
    if ($State.Operator.Version -ne 1) { throw 'Unknown operator state version.' }
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
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][string[]]$To,
        [Parameter(Mandatory)][string]$Message,
        [string]$Id = ([guid]::NewGuid().ToString('D')),
        [switch]$RequireDelivery
    )
    $guid = [guid]::Empty
    if (-not [guid]::TryParse($Id, [ref]$guid)) { throw 'Message ID must be a GUID.' }
    $Id = $guid.ToString('D')
    # pwsh -File passes a comma-separated native argument as one string.
    $recipients = @($To | ForEach-Object { $_ -split ',' } | ForEach-Object {
        switch ($_.Trim().ToLowerInvariant()) {
            reviewer { 'Reviewer' }; architect { 'Architect' }; fixer { 'Fixer' }
            default { throw 'Recipients must be Reviewer, Architect or Fixer.' }
        }
    } | Sort-Object -Unique)
    if ($recipients.Count -eq 0) { throw 'Select at least one recipient.' }
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
    Invoke-ReviewLoopOperatorLock $state {
        param($mailbox)
        $current = Read-ReviewLoopState $statePath
        if ((ConvertTo-ReviewLoopJsonCompact (Get-ReviewLoopOperatorIdentity $current)) -cne
            (ConvertTo-ReviewLoopJsonCompact $identity)) { throw 'Run identity mismatch.' }
        $path = Join-Path $mailbox "$Id.json"
        if (Test-Path -LiteralPath $path) {
            if ((ConvertTo-ReviewLoopJsonCompact (Read-ReviewLoopJson $path)) -cne
                (ConvertTo-ReviewLoopJsonCompact $request)) { throw 'Message ID already has different content.' }
            return
        }
        if ($current.Status -eq 'completed' -or
            ($null -ne $current.Operator.Boundary -and $current.Operator.Boundary.Kind -eq 'completion')) {
            throw 'Run completion is sealed.'
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
    param([object]$State, [string]$Mailbox)
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
            if ($request.Version -ne 1) { throw 'unknown request version' }
            if ((ConvertTo-ReviewLoopJsonCompact $request.Run) -cne $identity) { throw 'run identity mismatch' }
            if ($request.RequireDelivery -isnot [bool] -or $request.Message -isnot [string] -or
                [string]::IsNullOrWhiteSpace($request.Message) -or $request.Message.Length -gt 4000 -or
                @($request.To).Count -eq 0 -or @($request.To | Where-Object { $_ -cnotin @('Reviewer','Architect','Fixer') }).Count -gt 0 -or
                @($request.To | Select-Object -Unique).Count -ne @($request.To).Count) { throw 'invalid message' }
        }
        catch {
            $reason = if ($_.Exception.Message -cin @('invalid message ID','unknown request version','run identity mismatch','invalid message')) {
                $_.Exception.Message
            } else { 'invalid request' }
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
            RequireDelivery = -not $reason -and $request.RequireDelivery
            Deliveries = $deliveries; Rejection = $reason
        }
        if ($reason) { Write-ReviewLoopStatus -Message "$id rejected: $reason" -Kind Warning }
    }
}

function Sync-ReviewLoopOperatorMessages {
    param([object]$State, [string]$StatePath)
    Initialize-ReviewLoopOperator $State
    # A sealed transaction owns its exact request set through recovery.
    if ($null -ne $State.Operator.Boundary) { return }
    Invoke-ReviewLoopOperatorLock $State {
        param($mailbox)
        Import-ReviewLoopOperatorMessages -State $State -Mailbox $mailbox
        Write-ReviewLoopState -Path $StatePath -State $State | Out-Null
    }
}

function Get-ReviewLoopPendingOperatorMessages {
    param([object]$State, [string]$Role = '', [switch]$Required)
    Initialize-ReviewLoopOperator $State
    return @($State.Operator.Requests | Where-Object {
        (-not $Required -or $_.RequireDelivery) -and
        @($_.Deliveries | Where-Object { $_.Status -eq 'pending' -and (-not $Role -or $_.Role -eq $Role) }).Count -gt 0
    })
}

function Close-ReviewLoopOperatorBoundary {
    param([object]$State, [string]$StatePath,
        [ValidateSet('commit','completion')][string]$Kind,
        [string[]]$AllowRoles = @())
    Initialize-ReviewLoopOperator $State
    if ($null -ne $State.Operator.Boundary) {
        if ($State.Operator.Boundary.Kind -ne $Kind) { throw 'Operator transaction boundary mismatch.' }
        return @()
    }
    return @(Invoke-ReviewLoopOperatorLock $State {
        param($mailbox)
        Import-ReviewLoopOperatorMessages -State $State -Mailbox $mailbox
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
