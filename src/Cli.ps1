function Resolve-CodexCliExecutable {
    param([string]$CodexPath = "")

    if (-not [string]::IsNullOrWhiteSpace($CodexPath)) {
        return Resolve-ReviewLoopPath -Path $CodexPath -MustExist
    }

    # The Windows Store may expose a codex.exe alias that cannot be started
    # directly. The npm PowerShell launcher is the reliable Windows-native
    # process boundary and runs in its own pwsh process.
    $command = Get-Command "codex.ps1" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) {
        $command = Get-Command "codex.cmd" -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if ($null -eq $command) {
        $command = Get-Command "codex.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if ($null -eq $command) {
        throw "Codex CLI was not found. Install or authenticate Codex before starting the loop."
    }
    return $command.Source
}

function Get-CodexRoleArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$Model,
        [Parameter(Mandatory = $true)][string]$Thinking,
        [ValidateSet("standard", "fast")][string]$Speed = "standard",
        [ValidateSet("read-only", "workspace-write", "danger-full-access")][string]$Sandbox = "read-only",
        [ValidateSet("Exec", "Review", "Resume")][string]$Mode = "Exec",
        [string]$ReviewBase = "",
        [string]$ThreadId = "",
        [string]$DeveloperInstructions = "",
        [string]$SchemaPath = "",
        [string]$ResultPath = ""
    )

    $arguments = [System.Collections.Generic.List[string]]::new()
    [void]$arguments.Add("exec")
    [void]$arguments.Add("--json")
    [void]$arguments.Add("-C")
    [void]$arguments.Add((Resolve-ReviewLoopPath -Path $RepoPath -MustExist))
    [void]$arguments.Add("-m")
    [void]$arguments.Add($Model)
    [void]$arguments.Add("-c")
    [void]$arguments.Add("model_reasoning_effort=`"$($Thinking.ToLowerInvariant())`"")
    [void]$arguments.Add("-c")
    $tier = if ($Speed -eq "fast") { "fast" } else { "default" }
    [void]$arguments.Add("service_tier=`"$tier`"")
    if ($Speed -eq "fast") {
        [void]$arguments.Add("--enable")
        [void]$arguments.Add("fast_mode")
    }

    if ($Sandbox -eq "danger-full-access") {
        [void]$arguments.Add("--dangerously-bypass-approvals-and-sandbox")
    }
    else {
        [void]$arguments.Add("--sandbox")
        [void]$arguments.Add($Sandbox)
    }

    if (-not [string]::IsNullOrWhiteSpace($SchemaPath)) {
        [void]$arguments.Add("--output-schema")
        [void]$arguments.Add((Resolve-ReviewLoopPath -Path $SchemaPath -MustExist))
    }
    if (-not [string]::IsNullOrWhiteSpace($ResultPath)) {
        [void]$arguments.Add("-o")
        [void]$arguments.Add((Resolve-ReviewLoopPath -Path $ResultPath))
    }

    switch ($Mode) {
        "Review" {
            if ([string]::IsNullOrWhiteSpace($ReviewBase)) {
                throw "ReviewBase is required for a review call."
            }
            if (-not [string]::IsNullOrWhiteSpace($DeveloperInstructions)) {
                # JSON string literals are valid TOML basic strings as well.
                # Review --base must not receive a positional prompt.
                $tomlString = ConvertTo-Json -InputObject $DeveloperInstructions -Compress
                [void]$arguments.Add("-c")
                [void]$arguments.Add("developer_instructions=$tomlString")
            }
            [void]$arguments.Add("review")
            [void]$arguments.Add("--base")
            [void]$arguments.Add($ReviewBase)
        }
        "Resume" {
            if ([string]::IsNullOrWhiteSpace($ThreadId)) {
                throw "ThreadId is required for a resume call."
            }
            [void]$arguments.Add("resume")
            [void]$arguments.Add($ThreadId)
            [void]$arguments.Add("-")
        }
        default {
            [void]$arguments.Add("-")
        }
    }

    return $arguments.ToArray()
}

function New-CodexProcessStartInfo {
    param(
        [Parameter(Mandatory = $true)][string]$CodexExecutable,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $extension = [System.IO.Path]::GetExtension($CodexExecutable)
    if ($extension -ieq ".ps1") {
        $pwsh = (Get-Command "pwsh.exe" -ErrorAction Stop | Select-Object -First 1).Source
        $info = [System.Diagnostics.ProcessStartInfo]::new()
        $info.FileName = $pwsh
        foreach ($prefix in @("-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", $CodexExecutable)) {
            [void]$info.ArgumentList.Add($prefix)
        }
    }
    elseif ($extension -ieq ".cmd" -or $extension -ieq ".bat") {
        $info = [System.Diagnostics.ProcessStartInfo]::new()
        $info.FileName = $env:ComSpec
        foreach ($prefix in @("/d", "/s", "/c", $CodexExecutable)) {
            [void]$info.ArgumentList.Add($prefix)
        }
    }
    else {
        $info = [System.Diagnostics.ProcessStartInfo]::new()
        $info.FileName = $CodexExecutable
    }

    foreach ($argument in $Arguments) {
        [void]$info.ArgumentList.Add($argument)
    }
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $info.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
    return $info
}

function ConvertFrom-CodexJsonLines {
    param([AllowNull()][string]$JsonLines)

    $threadId = ""
    $usage = [ordered]@{
        InputTokens = 0L
        CachedInputTokens = 0L
        OutputTokens = 0L
        ReasoningOutputTokens = 0L
    }
    $events = [System.Collections.Generic.List[object]]::new()

    foreach ($line in @($JsonLines -split "\r?\n")) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        try {
            $event = $line | ConvertFrom-Json
            [void]$events.Add($event)
            if ($event.type -eq "thread.started") {
                $candidate = if ($event.PSObject.Properties.Name -contains "thread_id") {
                    [string]$event.thread_id
                }
                elseif ($event.PSObject.Properties.Name -contains "threadId") {
                    [string]$event.threadId
                }
                else { "" }
                if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                    $threadId = $candidate
                }
            }
            if ($event.type -eq "turn.completed" -and $null -ne $event.usage) {
                $map = @{
                    InputTokens = "input_tokens"
                    CachedInputTokens = "cached_input_tokens"
                    OutputTokens = "output_tokens"
                    ReasoningOutputTokens = "reasoning_output_tokens"
                }
                foreach ($entry in $map.GetEnumerator()) {
                    if ($event.usage.PSObject.Properties.Name -contains $entry.Value) {
                        $usage[$entry.Key] += [long]$event.usage.($entry.Value)
                    }
                }
            }
        }
        catch {
            # Non-JSON lines remain in the raw log and are ignored by structured parsing.
        }
    }

    return [pscustomobject]@{
        ThreadId = $threadId
        Usage = [pscustomobject]$usage
        Events = $events.ToArray()
    }
}

function Test-CodexStructuredResult {
    param(
        [Parameter(Mandatory = $true)][string]$ResultPath,
        [Parameter(Mandatory = $true)][string]$SchemaPath
    )

    if (-not (Test-Path -LiteralPath $ResultPath)) {
        return [pscustomobject]@{ Valid = $false; Value = $null; Reason = "Final result file is missing." }
    }

    $text = Get-Content -Raw -LiteralPath $ResultPath
    try {
        $value = $text | ConvertFrom-Json
    }
    catch {
        return [pscustomobject]@{ Valid = $false; Value = $null; Reason = "Final response is not valid JSON: $($_.Exception.Message)" }
    }

    $testJson = Get-Command Test-Json -ErrorAction SilentlyContinue
    if ($null -ne $testJson) {
        try {
            if (-not ($text | Test-Json -SchemaFile $SchemaPath -ErrorAction Stop)) {
                return [pscustomobject]@{ Valid = $false; Value = $value; Reason = "Final response violates the JSON schema." }
            }
        }
        catch {
            return [pscustomobject]@{ Valid = $false; Value = $value; Reason = "Schema validation failed: $($_.Exception.Message)" }
        }
    }

    return [pscustomobject]@{ Valid = $true; Value = $value; Reason = "" }
}

function Get-CodexFailureKind {
    param(
        [int]$ExitCode,
        [AllowNull()][string]$Output
    )

    if ($ExitCode -eq 0) {
        return "none"
    }
    if ($Output -match "(?i)(fast mode|service tier).*(not available|unsupported|not supported|unavailable)") {
        return "fast_unavailable"
    }
    if ($Output -match "(?i)(authentication|unauthorized|not logged in|login required|credential)") {
        return "authentication"
    }
    if ($Output -match "(?i)(rate.?limit|temporar|timed? out|timeout|connection reset|connection refused|\b50[0234]\b)") {
        return "transient"
    }
    return "cli_error"
}

function Get-ReviewLoopObjectProperty {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][object]$Default = $null
    )

    if ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name) {
        return $Object.$Name
    }
    return $Default
}

function Get-ReviewLoopTextExcerpt {
    param(
        [AllowNull()][string]$Text,
        [ValidateRange(1, 50)][int]$MaxLines = 8,
        [ValidateRange(40, 1000)][int]$MaxLineLength = 220
    )

    $lines = @((ConvertTo-ReviewLoopRedactedText $Text) -split "\r?\n" |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $selected = if ($lines.Count -le $MaxLines) {
        @($lines)
    }
    else {
        $firstCount = [int][Math]::Ceiling($MaxLines / 2.0)
        $lastCount = $MaxLines - $firstCount
        @(
            $lines | Select-Object -First $firstCount
            "... $($lines.Count - $MaxLines) line(s) omitted ..."
            if ($lastCount -gt 0) {
                $lines | Select-Object -Last $lastCount
            }
        )
    }
    return @($selected | ForEach-Object {
        if ($_.Length -gt $MaxLineLength) { $_.Substring(0, $MaxLineLength) + "…" } else { $_ }
    })
}

function Test-ReviewLoopCodexAdvisoryMessage {
    param([AllowNull()][string]$Message)

    return -not [string]::IsNullOrWhiteSpace($Message) -and
        $Message -match "(?i)^Skill descriptions were shortened to fit\b"
}

function Update-ReviewLoopCodexActivity {
    param(
        [Parameter(Mandatory = $true)][string]$Line,
        [Parameter(Mandatory = $true)][object]$Activity
    )

    try {
        $event = $Line | ConvertFrom-Json
    }
    catch {
        if (Test-ReviewLoopOutputLevel -Minimum detailed) {
            Write-ReviewLoopStatus -Message $Line -Kind Muted -Indent 1
        }
        return
    }

    $type = [string](Get-ReviewLoopObjectProperty -Object $event -Name "type" -Default "")
    if ($type -eq "thread.started") {
        $candidate = Get-ReviewLoopObjectProperty -Object $event -Name "thread_id" -Default ""
        if ([string]::IsNullOrWhiteSpace([string]$candidate)) {
            $candidate = Get-ReviewLoopObjectProperty -Object $event -Name "threadId" -Default ""
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$candidate)) {
            $Activity.ThreadId = [string]$candidate
        }
    }

    $item = Get-ReviewLoopObjectProperty -Object $event -Name "item"
    $itemType = [string](Get-ReviewLoopObjectProperty -Object $item -Name "type" -Default "")
    if ($type -eq "item.started") {
        $Activity.ActionCount = [int]$Activity.ActionCount + 1
        if ($itemType -eq "command_execution" -and (Test-ReviewLoopOutputLevel -Minimum balanced)) {
            $command = [string](Get-ReviewLoopObjectProperty -Object $item -Name "command" -Default "command")
            Write-ReviewLoopStatus -Message "CLI: $command" -Kind Muted -Indent 1
        }
    }
    elseif ($type -eq "item.completed" -and $itemType -eq "command_execution") {
        $exitCode = [int](Get-ReviewLoopObjectProperty -Object $item -Name "exit_code" -Default 0)
        if ($exitCode -ne 0) {
            $command = [string](Get-ReviewLoopObjectProperty -Object $item -Name "command" -Default "internal command")
            Write-ReviewLoopStatus -Message "CLI command failed (exit code $exitCode): $command" -Kind Warning -Indent 1
            $output = [string](Get-ReviewLoopObjectProperty -Object $item -Name "aggregated_output" -Default "")
            foreach ($excerpt in @(Get-ReviewLoopTextExcerpt -Text $output -MaxLines 4)) {
                Write-ReviewLoopStatus -Message $excerpt -Kind Muted -Indent 2
            }
        }
        elseif (Test-ReviewLoopOutputLevel -Minimum detailed) {
            $command = [string](Get-ReviewLoopObjectProperty -Object $item -Name "command" -Default "command")
            Write-ReviewLoopStatus -Message "CLI completed: $command" -Kind Muted -Indent 1
        }
    }
    elseif ($itemType -eq "error" -or $type -in @("error", "turn.failed")) {
        $message = [string](Get-ReviewLoopObjectProperty -Object $item -Name "message" -Default "")
        if ([string]::IsNullOrWhiteSpace($message)) {
            $message = [string](Get-ReviewLoopObjectProperty -Object $event -Name "message" -Default "Codex reported an error.")
        }
        $kind = if (Test-ReviewLoopCodexAdvisoryMessage -Message $message) {
            "Warning"
        }
        else {
            "Error"
        }
        Write-ReviewLoopStatus -Message $message -Kind $kind -Indent 1
    }
}

function New-ReviewLoopStreamWriter {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$Append
    )

    $parent = Split-Path -Parent $Path
    [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    $mode = if ($Append) { [System.IO.FileMode]::Append } else { [System.IO.FileMode]::Create }
    $stream = [System.IO.FileStream]::new(
        $Path,
        $mode,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::ReadWrite
    )
    $writer = [System.IO.StreamWriter]::new($stream, [System.Text.UTF8Encoding]::new($false))
    $writer.AutoFlush = $true
    return $writer
}

function Stop-ReviewLoopProcessTree {
    param([AllowNull()][System.Diagnostics.Process]$Process)

    if ($null -eq $Process) {
        return
    }
    try {
        if (-not $Process.HasExited) {
            $Process.Kill($true)
            $Process.WaitForExit(5000) | Out-Null
        }
    }
    catch {
        # The process may terminate between HasExited and Kill.
    }
}

function Invoke-ReviewLoopObservedProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.Diagnostics.ProcessStartInfo]$StartInfo,
        [Parameter(Mandatory = $true)][string]$DisplayName,
        [Parameter(Mandatory = $true)][string]$StdoutPath,
        [Parameter(Mandatory = $true)][string]$StderrPath,
        [AllowNull()][string]$InputText = $null,
        [ValidateSet("Codex", "HostGate")][string]$EventKind = "Codex",
        [switch]$AppendLogs
    )

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $StartInfo
    $stdoutWriter = $null
    $stderrWriter = $null
    $stdoutBuilder = [System.Text.StringBuilder]::new()
    $stderrBuilder = [System.Text.StringBuilder]::new()
    $activity = [pscustomobject]@{
        ActionCount = 0
        ThreadId = ""
        LastActivity = [DateTimeOffset]::UtcNow
    }
    $startedAt = [DateTimeOffset]::UtcNow
    $exitCode = -1
    $wasStarted = $false
    try {
        $stdoutWriter = New-ReviewLoopStreamWriter -Path $StdoutPath -Append:$AppendLogs
        $stderrWriter = New-ReviewLoopStreamWriter -Path $StderrPath -Append:$AppendLogs
        if ($AppendLogs) {
            $marker = "--- new attempt $(Get-Date -Format o) ---"
            $stdoutWriter.WriteLine($marker)
            $stderrWriter.WriteLine($marker)
        }
        if (-not $process.Start()) {
            throw "$DisplayName could not be started."
        }
        $wasStarted = $true
        if ($null -ne $InputText) {
            $process.StandardInput.Write($InputText)
        }
        $process.StandardInput.Close()

        $stdoutDone = $false
        $stderrDone = $false
        $stdoutTask = $process.StandardOutput.ReadLineAsync()
        $stderrTask = $process.StandardError.ReadLineAsync()
        $heartbeatSeconds = [int](Get-ReviewLoopConsoleOption -Name HeartbeatSeconds)
        $nextHeartbeat = if ($heartbeatSeconds -gt 0) {
            [DateTimeOffset]::UtcNow.AddSeconds($heartbeatSeconds)
        }
        else {
            [DateTimeOffset]::MaxValue
        }

        while (-not ($stdoutDone -and $stderrDone -and $process.HasExited)) {
            if (-not $stdoutDone -and $stdoutTask.IsCompleted) {
                $line = $stdoutTask.GetAwaiter().GetResult()
                if ($null -eq $line) {
                    $stdoutDone = $true
                }
                else {
                    $safeLine = ConvertTo-ReviewLoopRedactedText $line
                    $stdoutWriter.WriteLine($safeLine)
                    [void]$stdoutBuilder.AppendLine($safeLine)
                    $activity.LastActivity = [DateTimeOffset]::UtcNow
                    if ($EventKind -eq "Codex") {
                        Update-ReviewLoopCodexActivity -Line $safeLine -Activity $activity
                    }
                    $stdoutTask = $process.StandardOutput.ReadLineAsync()
                }
            }
            if (-not $stderrDone -and $stderrTask.IsCompleted) {
                $line = $stderrTask.GetAwaiter().GetResult()
                if ($null -eq $line) {
                    $stderrDone = $true
                }
                else {
                    $safeLine = ConvertTo-ReviewLoopRedactedText $line
                    $stderrWriter.WriteLine($safeLine)
                    [void]$stderrBuilder.AppendLine($safeLine)
                    $activity.LastActivity = [DateTimeOffset]::UtcNow
                    if (Test-ReviewLoopOutputLevel -Minimum detailed) {
                        Write-ReviewLoopStatus -Message $safeLine -Kind Muted -Indent 1
                    }
                    $stderrTask = $process.StandardError.ReadLineAsync()
                }
            }

            $now = [DateTimeOffset]::UtcNow
            if ($now -ge $nextHeartbeat) {
                $elapsed = Format-ReviewLoopDuration -Duration ($now - $startedAt)
                $idleSeconds = [Math]::Max(0, [int]($now - $activity.LastActivity).TotalSeconds)
                $activityText = if ($EventKind -eq "Codex") {
                    "$($activity.ActionCount) CLI actions"
                }
                else {
                    "process active"
                }
                Write-ReviewLoopStatus -Message "$DisplayName running for $elapsed · $activityText · last activity ${idleSeconds}s ago" -Kind Progress
                $nextHeartbeat = $now.AddSeconds($heartbeatSeconds)
            }
            if (-not ($stdoutDone -and $stderrDone -and $process.HasExited)) {
                Start-Sleep -Milliseconds 75
            }
        }
        $process.WaitForExit()
        $exitCode = $process.ExitCode
    }
    catch {
        [void]$stderrBuilder.AppendLine((ConvertTo-ReviewLoopRedactedText $_.Exception.Message))
        if ($null -ne $stderrWriter) {
            $stderrWriter.WriteLine((ConvertTo-ReviewLoopRedactedText $_.Exception.Message))
        }
        throw
    }
    finally {
        if ($wasStarted -and -not $process.HasExited) {
            Stop-ReviewLoopProcessTree -Process $process
        }
        if ($null -ne $stdoutWriter) {
            $stdoutWriter.Flush()
            $stdoutWriter.Dispose()
        }
        if ($null -ne $stderrWriter) {
            $stderrWriter.Flush()
            $stderrWriter.Dispose()
        }
        $process.Dispose()
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Stdout = $stdoutBuilder.ToString()
        Stderr = $stderrBuilder.ToString()
        StartedAt = $startedAt
        FinishedAt = [DateTimeOffset]::UtcNow
        Duration = [DateTimeOffset]::UtcNow - $startedAt
        ActionCount = [int]$activity.ActionCount
        ThreadId = [string]$activity.ThreadId
    }
}

function Invoke-CodexCliRole {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Role,
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$Model,
        [Parameter(Mandatory = $true)][string]$Thinking,
        [ValidateSet("standard", "fast")][string]$Speed = "standard",
        [ValidateSet("read-only", "workspace-write", "danger-full-access")][string]$Sandbox = "read-only",
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Prompt,
        [Parameter(Mandatory = $true)][string]$LogRoot,
        [string]$SchemaPath = "",
        [ValidateSet("Exec", "Review", "Resume")][string]$Mode = "Exec",
        [string]$ReviewBase = "",
        [string]$ThreadId = "",
        [string]$CodexPath = "",
        [ValidateRange(1, 5)][int]$MaxAttempts = 3,
        [string]$CallId = ""
    )

    $repo = Resolve-ReviewLoopPath -Path $RepoPath -MustExist
    $logDirectory = Resolve-ReviewLoopPath -Path $LogRoot
    [System.IO.Directory]::CreateDirectory($logDirectory) | Out-Null
    $executable = Resolve-CodexCliExecutable -CodexPath $CodexPath
    $safeRole = [regex]::Replace($Role.ToLowerInvariant(), "[^a-z0-9-]+", "-").Trim("-")
    if ([string]::IsNullOrWhiteSpace($CallId)) {
        $CallId = "{0}-{1}" -f (Get-Date -Format "yyyyMMdd-HHmmss-fff"), ([Guid]::NewGuid().ToString("N").Substring(0, 8))
    }
    $stem = Join-Path $logDirectory "$CallId-$safeRole"
    $jsonlPath = "$stem.jsonl"
    $stderrPath = "$stem.stderr.txt"
    $resultPath = "$stem.result.json"

    $arguments = Get-CodexRoleArguments `
        -RepoPath $repo `
        -Model $Model `
        -Thinking $Thinking `
        -Speed $Speed `
        -Sandbox $Sandbox `
        -Mode $Mode `
        -ReviewBase $ReviewBase `
        -ThreadId $ThreadId `
        -DeveloperInstructions $(if ($Mode -eq "Review") { $Prompt } else { "" }) `
        -SchemaPath $SchemaPath `
        -ResultPath $resultPath

    $attemptRecords = [System.Collections.Generic.List[object]]::new()
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        Write-ReviewLoopStatus -Message "$Role · $Model/$Thinking · $Speed · attempt $attempt/$MaxAttempts" -Kind Progress
        $startInfo = New-CodexProcessStartInfo -CodexExecutable $executable -Arguments $arguments
        $observed = $null
        try {
            $observed = Invoke-ReviewLoopObservedProcess `
                -StartInfo $startInfo `
                -DisplayName $Role `
                -StdoutPath $jsonlPath `
                -StderrPath $stderrPath `
                -InputText $(if ($Mode -eq "Review") { $null } else { $Prompt }) `
                -EventKind Codex `
                -AppendLogs:($attempt -gt 1)
            $stdout = $observed.Stdout
            $stderr = $observed.Stderr
            $exitCode = $observed.ExitCode
            $startedAt = $observed.StartedAt
            $finishedAt = $observed.FinishedAt
        }
        catch {
            $stdout = ""
            $stderr = $_.Exception.Message
            $exitCode = -1
            $startedAt = [DateTimeOffset]::UtcNow
            $finishedAt = [DateTimeOffset]::UtcNow
        }

        $stdout = ConvertTo-ReviewLoopRedactedText $stdout
        $stderr = ConvertTo-ReviewLoopRedactedText $stderr
        $parsed = ConvertFrom-CodexJsonLines -JsonLines $stdout
        if ([string]::IsNullOrWhiteSpace([string]$parsed.ThreadId) -and
            $null -ne $observed -and -not [string]::IsNullOrWhiteSpace([string]$observed.ThreadId)) {
            $parsed.ThreadId = [string]$observed.ThreadId
        }
        $failureKind = Get-CodexFailureKind -ExitCode $exitCode -Output "$stdout`n$stderr"
        [void]$attemptRecords.Add([pscustomobject]@{
            Attempt = $attempt
            ExitCode = $exitCode
            FailureKind = $failureKind
            StartedAt = $startedAt
            FinishedAt = $finishedAt
        })

        if ($exitCode -eq 0) {
            $finalText = if (Test-Path -LiteralPath $resultPath) {
                ConvertTo-ReviewLoopRedactedText (Get-Content -Raw -LiteralPath $resultPath)
            }
            else { "" }
            if (Test-Path -LiteralPath $resultPath) {
                Write-ReviewLoopUtf8File -Path $resultPath -Content $finalText
            }
            $structured = $null
            if (-not [string]::IsNullOrWhiteSpace($SchemaPath)) {
                $validation = Test-CodexStructuredResult -ResultPath $resultPath -SchemaPath $SchemaPath
                if (-not $validation.Valid) {
                    return [pscustomobject]@{
                        Success = $false
                        Role = $Role
                        Model = $Model
                        Thinking = $Thinking
                        Speed = $Speed
                        ExitCode = 4
                        FailureKind = "invalid_structured_output"
                        FailureReason = $validation.Reason
                        ThreadId = $parsed.ThreadId
                        Usage = $parsed.Usage
                        FinalMessage = $finalText
                        StructuredResult = $validation.Value
                        Arguments = $arguments
                        JsonlPath = $jsonlPath
                        ResultPath = $resultPath
                        Attempts = $attemptRecords.ToArray()
                    }
                }
                $structured = $validation.Value
            }

            $duration = Format-ReviewLoopDuration -Duration ($finishedAt - $startedAt)
            $tokens = [long]$parsed.Usage.InputTokens + [long]$parsed.Usage.OutputTokens
            Write-ReviewLoopStatus -Message "$Role completed · $duration · $tokens tokens" -Kind Success
            return [pscustomobject]@{
                Success = $true
                Role = $Role
                Model = $Model
                Thinking = $Thinking
                Speed = $Speed
                ExitCode = 0
                FailureKind = "none"
                FailureReason = ""
                ThreadId = $parsed.ThreadId
                Usage = $parsed.Usage
                FinalMessage = $finalText
                StructuredResult = $structured
                Arguments = $arguments
                JsonlPath = $jsonlPath
                ResultPath = $resultPath
                Attempts = $attemptRecords.ToArray()
            }
        }

        if ($failureKind -ne "transient" -or $attempt -ge $MaxAttempts) {
            Write-ReviewLoopStatus -Message "$Role failed ($failureKind, exit code $exitCode)" -Kind Error
            foreach ($excerpt in @(Get-ReviewLoopTextExcerpt -Text "$stderr`n$stdout" -MaxLines 8)) {
                Write-ReviewLoopStatus -Message $excerpt -Kind Muted -Indent 1
            }
            return [pscustomobject]@{
                Success = $false
                Role = $Role
                Model = $Model
                Thinking = $Thinking
                Speed = $Speed
                ExitCode = $exitCode
                FailureKind = $failureKind
                FailureReason = (($stderr, $stdout | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join [Environment]::NewLine).Trim()
                ThreadId = $parsed.ThreadId
                Usage = $parsed.Usage
                FinalMessage = ""
                StructuredResult = $null
                Arguments = $arguments
                JsonlPath = $jsonlPath
                ResultPath = $resultPath
                Attempts = $attemptRecords.ToArray()
            }
        }

        $delay = [int][Math]::Min(8, [Math]::Pow(2, $attempt))
        Write-ReviewLoopStatus -Message "${Role}: transient failure '$failureKind'; retrying in ${delay}s." -Kind Warning
        Start-Sleep -Seconds $delay
    }
}
