function Get-ReviewLoopTerminalAnchor {
    param([IO.Stream]$Stream, [long]$Offset)
    $bytes = [byte[]]::new([int][Math]::Min(128, $Offset))
    if ($bytes.Length) {
        $Stream.Position = $Offset - $bytes.Length
        $read = $Stream.Read($bytes, 0, $bytes.Length)
        if ($read -ne $bytes.Length) { throw 'Terminal log changed; request a fresh status.' }
    }
    return Get-ReviewLoopSha256 ([Convert]::ToBase64String($bytes))
}

function Read-ReviewLoopTerminalChanges {
    param([string]$RunRoot, [string]$RunKey, [string]$Since)
    $previous = $null
    if ($Since) {
        try {
            $previous = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Since)) | ConvertFrom-Json
            if ($previous.Version -ne 1 -or $previous.Run -cne $RunKey -or
                $previous.Offset -isnot [long] -and $previous.Offset -isnot [int] -or
                $previous.Offset -lt 0 -or $previous.Anchor -isnot [string]) { throw 'invalid' }
        }
        catch { throw 'Invalid status cursor or different run.' }
    }
    $path = Join-Path $RunRoot 'terminal.log'
    $stream = $null
    try {
        try {
            $stream = [IO.FileStream]::new($path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
                [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        }
        catch [IO.FileNotFoundException] { }
        catch [IO.DirectoryNotFoundException] { }
        $end = 0L
        if ($null -ne $stream) {
            # Capture a finite prefix and leave an incomplete last record for the next query.
            $position = $stream.Length
            $buffer = [byte[]]::new(4096)
            while ($position -gt 0 -and $end -eq 0) {
                $count = [int][Math]::Min($buffer.Length, $position)
                $position -= $count
                $stream.Position = $position
                if ($stream.Read($buffer, 0, $count) -ne $count) { throw 'Terminal log changed; request a fresh status.' }
                for ($i = $count - 1; $i -ge 0; $i--) {
                    if ($buffer[$i] -eq 10) { $end = $position + $i + 1; break }
                }
            }
        }
        $offset = if ($null -ne $previous) { [long]$previous.Offset } else { $end }
        if ($offset -gt $end -or ($null -ne $previous -and
            (Get-ReviewLoopTerminalAnchor $stream $offset) -cne $previous.Anchor)) {
            throw 'Terminal log reset or replaced; request a fresh status.'
        }
        $lines = [Collections.Generic.List[string]]::new()
        if ($null -ne $stream -and $offset -lt $end) {
            $stream.Position = $offset
            $line = [IO.MemoryStream]::new()
            try {
                $utf8 = [Text.UTF8Encoding]::new($false, $true)
                while ($stream.Position -lt $end -and $lines.Count -lt 50) {
                    $value = $stream.ReadByte()
                    if ($value -lt 0) { throw 'Terminal log changed; request a fresh status.' }
                    if ($value -eq 10) {
                        $text = $utf8.GetString($line.ToArray()).TrimEnd("`r").TrimStart([char]0xfeff)
                        $lines.Add((ConvertTo-ReviewLoopRedactedText (Remove-ReviewLoopAnsi $text)))
                        $line.SetLength(0)
                        $line.Position = 0
                        $offset = $stream.Position
                    }
                    else { $line.WriteByte([byte]$value) }
                }
            }
            finally { $line.Dispose() }
        }
        $cursor = [ordered]@{ Version = 1; Run = $RunKey; Offset = $offset
            Anchor = Get-ReviewLoopTerminalAnchor $stream $offset }
        $result = [ordered]@{
            Cursor = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((ConvertTo-ReviewLoopJsonCompact $cursor)))
            HasMore = $offset -lt $end
        }
        if ($Since) { $result.Lines = $lines.ToArray() }
        if ($null -ne $stream) { $result.LastWriteTime = [IO.File]::GetLastWriteTimeUtc($path).ToString('O') }
        return [pscustomobject]$result
    }
    finally { if ($null -ne $stream) { $stream.Dispose() } }
}

function Get-ReviewLoopRepositoryLeaseStatus {
    param([string]$RepoPath)
    try {
        $path = Get-ReviewLoopGitValue $RepoPath @('rev-parse', '--git-path', 'codex-review-loop.lock')
        if (-not [IO.Path]::IsPathRooted($path)) { $path = Join-Path $RepoPath $path }
        if (-not [IO.File]::Exists($path)) { return }
        try {
            $stream = [IO.FileStream]::new($path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
                [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
            $stream.Dispose()
            return 'free'
        }
        catch [IO.IOException] {
            if (($_.Exception.HResult -band 0xffff) -in @(32,33)) { return 'held' }
        }
    }
    catch { } # An unavailable probe is not evidence of process activity or release.
}

function Get-ReviewLoopOperatorStatusReason {
    param([string]$Message)
    $text = (ConvertTo-ReviewLoopRedactedText $Message) -replace '\s+', ' '
    if ($text.Length -gt 240) { return $text.Substring(0, 237) + '...' }
    return $text
}

function Get-ReviewLoopOperatorStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$RunRoot, [string]$Since = '')
    $statePath = Join-Path (Resolve-ReviewLoopPath $RunRoot -MustExist) 'run-v1.json'
    # Read the actual fields, not the resume reader's additive compatibility defaults.
    $state = Read-ReviewLoopJson $statePath
    Test-ReviewLoopState $state | Out-Null
    Initialize-ReviewLoopOperator $state
    $identity = Get-ReviewLoopOperatorIdentity $state
    if ((Get-ReviewLoopOperatorCanonicalPath $statePath) -cne $identity.StatePath) { throw 'Run identity mismatch.' }
    $identityText = ConvertTo-ReviewLoopJsonCompact $identity
    $terminal = Read-ReviewLoopTerminalChanges -RunRoot $RunRoot -RunKey (Get-ReviewLoopSha256 $identityText) -Since $Since
    $saved = [ordered]@{ Run = $identity; Status = $state.Status; Phase = $state.Stage }
    foreach ($name in @('UpdatedAt','ReviewCycle','ReviewCyclesThisInvocation','CurrentHead')) {
        $value = Get-ReviewLoopObjectProperty $state -Name $name
        if ($null -ne $value) { $saved[$name] = $value }
    }
    $active = Get-ReviewLoopObjectProperty $state -Name ActiveCriticCall
    if ($null -eq $active) { $active = Get-ReviewLoopObjectProperty $state -Name ActiveRoleCall }
    if ($null -ne $active) {
        $role = [ordered]@{}
        foreach ($field in @('Role','CallId','StartedAt')) {
            $value = Get-ReviewLoopObjectProperty $active -Name $field
            if ($null -ne $value -and [string]$value -ne '') { $role[$field] = $value }
        }
        $saved.ActiveRole = [pscustomobject]$role
    }
    $work = [ordered]@{}
    foreach ($name in @('ActiveFindingIds','ActiveWorkIds','ActiveFixAttempt')) {
        $value = Get-ReviewLoopObjectProperty $state -Name $name
        if ($null -ne $value -and @($value).Count -gt 0) {
            if ($name -eq 'ActiveFixAttempt') { $work[$name] = $value }
            else { $work[$name] = @($value) }
        }
    }
    foreach ($name in @('RetainedCandidate','PendingCommit')) {
        $value = Get-ReviewLoopObjectProperty $state -Name $name
        if ($null -eq $value) { continue }
        $summary = [ordered]@{}
        foreach ($field in @('PreHead','ExpectedTree','ExpectedCommit','PatchFingerprint','NeedsCurrentGates','ClusterId','Attempt')) {
            $item = Get-ReviewLoopObjectProperty $value -Name $field
            if ($null -ne $item -and [string]$item -ne '') { $summary[$field] = $item }
        }
        $snapshot = Get-ReviewLoopObjectProperty $value -Name Snapshot
        if ($null -ne $snapshot) { $summary.Snapshot = $snapshot | Select-Object Head, Fingerprint }
        $work[$name] = [pscustomobject]$summary
    }
    $recovery = @(@('PartialFixRecovery','ActiveHostGateRecovery','BlockedCleanup') | Where-Object {
        $null -ne (Get-ReviewLoopObjectProperty $state -Name $_)
    })
    if ($null -ne $state.Operator.InterruptedFixerCall) { $recovery += 'InterruptedFixerCall' }
    if ($recovery.Count) { $work.Recovery = $recovery }
    if ($work.Count) { $saved.Work = [pscustomobject]$work }
    if ($state.Status -eq 'paused' -and $null -ne $state.Operator.Pause) {
        $pause = $state.Operator.Pause
        $saved.Pause = [pscustomobject]@{ At = $pause.At; Stage = $pause.Stage; Requests = @(
            $state.Operator.Requests | Where-Object Id -In $pause.RequestIds | Select-Object Id, PauseAt, Reached, Missed
        ) }
    }
    $requests = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($request in $state.Operator.Requests) {
        [void]$seen.Add([string]$request.Id)
        if (Get-ReviewLoopObjectProperty $request -Name Rejection -Default '') { continue }
        $kind = Get-ReviewLoopObjectProperty $request -Name Kind -Default 'message'
        $pending = @((Get-ReviewLoopObjectProperty $request -Name Deliveries -Default @()) | Where-Object Status -eq pending)
        if ($kind -in @('pause','critic_request')) {
            if ($request.Status -ne 'pending') { continue }
        }
        elseif (-not $pending.Count) { continue }
        $summary = [ordered]@{ Id = $request.Id; Kind = $kind; Source = 'checkpoint'; Status = 'pending'
            Message = Get-ReviewLoopOperatorStatusReason $request.Message }
        if ($kind -eq 'pause') { $summary.PauseAt = $request.PauseAt }
        if ($pending.Count) {
            $summary.To = @($request.Deliveries | ForEach-Object Role)
            $summary.PendingTo = @($pending | ForEach-Object Role)
            $summary.RequireDelivery = [bool]$request.RequireDelivery
        }
        $requests.Add([pscustomobject]$summary)
    }
    $mailbox = Get-ReviewLoopOperatorMailbox $state
    if (Test-Path -LiteralPath $mailbox -PathType Container) {
        foreach ($file in @(Get-ChildItem -LiteralPath $mailbox -Filter '*.json' -File | Sort-Object Name)) {
            if ($seen.Contains($file.BaseName)) { continue }
            $read = Read-ReviewLoopOperatorRequest -File $file -Identity $identityText
            $summary = [ordered]@{ Id = $file.BaseName; Source = 'mailbox'; Status = 'published' }
            if ($read.Rejection) {
                $summary.Status = 'invalid'; $summary.Reason = $read.Rejection
            }
            else {
                $request = $read.Request
                $summary.Kind = if ($request.Version -eq 1) { 'message' } else { $request.Kind }
                $summary.Message = Get-ReviewLoopOperatorStatusReason $request.Message
                foreach ($field in @('To','RequireDelivery','PauseAt')) {
                    $value = Get-ReviewLoopObjectProperty $request -Name $field
                    if ($null -ne $value) {
                        if ($field -eq 'To') { $summary[$field] = @($value) }
                        else { $summary[$field] = $value }
                    }
                }
            }
            $requests.Add([pscustomobject]$summary)
        }
    }
    $observed = [ordered]@{ At = [DateTimeOffset]::UtcNow.ToString('O') }
    $lease = Get-ReviewLoopRepositoryLeaseStatus $state.RepoPath
    if ($lease) { $observed.RepositoryLease = $lease }
    $activity = $null
    $activity = if ($terminal.PSObject.Properties.Name -contains 'LastWriteTime') {
        [ordered]@{ Source = 'terminal.log LastWriteTimeUtc'; At = $terminal.LastWriteTime }
    }
    elseif ($saved.Contains('UpdatedAt')) { [ordered]@{ Source = 'checkpoint UpdatedAt'; At = $saved.UpdatedAt } }
    if ($null -ne $activity) {
        $activity.AgeSeconds = [Math]::Max(0, [Math]::Round(([DateTimeOffset]::UtcNow - [DateTimeOffset]$activity.At).TotalSeconds, 1))
        $observed.LastActivity = [pscustomobject]$activity
    }
    $result = [ordered]@{ Saved = [pscustomobject]$saved; Observed = [pscustomobject]$observed
        Requests = $requests.ToArray(); Cursor = $terminal.Cursor }
    if ($Since) { $result.Changes = [pscustomobject]@{ Lines = @($terminal.Lines); HasMore = $terminal.HasMore } }
    return [pscustomobject]$result
}
