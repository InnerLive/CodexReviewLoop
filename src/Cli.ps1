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

function Assert-CodexOutputSchemaSupported {
    param([Parameter(Mandatory = $true)][string]$SchemaPath)

    $path = Resolve-ReviewLoopPath -Path $SchemaPath -MustExist
    $schemaText = Get-Content -Raw -LiteralPath $path
    $unsupported = @(
        "uniqueItems"
    )
    $found = @($unsupported | Where-Object {
        $schemaText -match ('"{0}"\s*:' -f [regex]::Escape($_))
    })
    if ($found.Count -gt 0) {
        throw "Codex Structured Output schema '$path' uses unsupported JSON Schema keyword(s): $($found -join ', ')."
    }
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
    [void]$arguments.Add("--ignore-user-config")
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
        Assert-CodexOutputSchemaSupported -SchemaPath $SchemaPath
        [void]$arguments.Add("--output-schema")
        [void]$arguments.Add((Resolve-ReviewLoopPath -Path $SchemaPath -MustExist))
    }
    if (-not [string]::IsNullOrWhiteSpace($ResultPath)) {
        [void]$arguments.Add("-o")
        [void]$arguments.Add((Resolve-ReviewLoopPath -Path $ResultPath))
    }
    if (-not [string]::IsNullOrWhiteSpace($DeveloperInstructions)) {
        # JSON string literals are valid TOML basic strings as well.
        $tomlString = ConvertTo-Json -InputObject $DeveloperInstructions -Compress
        [void]$arguments.Add("-c")
        [void]$arguments.Add("developer_instructions=$tomlString")
    }

    switch ($Mode) {
        "Review" {
            if ([string]::IsNullOrWhiteSpace($ReviewBase)) {
                throw "ReviewBase is required for a review call."
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

function Read-ReviewLoopSanitizedResult {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [ValidateRange(1024, 104857600)][int]$MaxBytes = 10485760
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ Text = ""; TooLarge = $false }
    }
    $length = (Get-Item -LiteralPath $Path).Length
    if ($length -gt $MaxBytes) {
        $message = "[redacted oversized result: $length bytes exceeds the $MaxBytes-byte limit]"
        Write-ReviewLoopUtf8File -Path $Path -Content $message
        return [pscustomobject]@{ Text = $message; TooLarge = $true }
    }
    $safe = ConvertTo-ReviewLoopRedactedText (Get-Content -Raw -LiteralPath $Path)
    Write-ReviewLoopUtf8File -Path $Path -Content $safe
    return [pscustomobject]@{ Text = $safe; TooLarge = $false }
}

function Get-CodexFailureKind {
    param(
        [int]$ExitCode,
        [AllowNull()][string]$Output
    )

    if ($ExitCode -eq 0) {
        return "none"
    }
    if ($ExitCode -eq 124) {
        return "timeout"
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
        $Message -match "(?i)^(Skill descriptions were shortened to fit\b|in-process app-server event stream lagged; dropped \d+ events\b)"
}

function Test-ReviewLoopCommandReturnedNoResult {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [int]$ExitCode,
        [AllowNull()][string]$Output
    )

    if ($ExitCode -ne 1 -or -not [string]::IsNullOrWhiteSpace($Output)) {
        return $false
    }
    $payload = Get-ReviewLoopCommandPayload -Command $Command
    return $payload -match '(?i)^\s*(?:&\s*)?(?:"[^"]*[\\/])?rg(?:\.exe)?"?\s'
}

function Get-ReviewLoopCommandPayload {
    param([Parameter(Mandatory = $true)][string]$Command)

    $payload = $Command.Trim()
    if ($payload -match '(?is)^\s*(?:"[^"]*(?:pwsh|powershell)(?:\.exe)?"|[^\s]*(?:pwsh|powershell)(?:\.exe)?)\s+.*?-(?:Command|c)\s+(?<payload>.+)$') {
        $payload = $Matches.payload.Trim()
    }
    elseif ($payload -match '(?is)^\s*(?:"[^"]*cmd(?:\.exe)?"|[^\s]*cmd(?:\.exe)?)\s+.*?/c\s+(?<payload>.+)$') {
        $payload = $Matches.payload.Trim()
    }
    if ($payload.Length -ge 2 -and
        (($payload[0] -eq "'" -and $payload[$payload.Length - 1] -eq "'") -or
         ($payload[0] -eq '"' -and $payload[$payload.Length - 1] -eq '"'))) {
        $payload = $payload.Substring(1, $payload.Length - 2).Trim()
    }
    return $payload
}

function Clear-ReviewLoopModelHelperEnvironment {
    param([Parameter(Mandatory = $true)][System.Diagnostics.ProcessStartInfo]$StartInfo)

    foreach ($name in @(
        "RIPGREP_CONFIG_PATH", "GIT_EXTERNAL_DIFF", "GIT_PAGER", "PAGER",
        "GIT_EDITOR", "GIT_SEQUENCE_EDITOR", "GIT_ASKPASS", "SSH_ASKPASS"
    )) {
        [void]$StartInfo.Environment.Remove($name)
    }
}

function Test-ReviewLoopForbiddenRoleCommand {
    param([Parameter(Mandatory = $true)][string]$Command)

    $payload = Get-ReviewLoopCommandPayload -Command $Command
    if ($null -ne (ConvertFrom-ReviewLoopTargetedCommand -Command $payload)) {
        return $true
    }
    $parsed = ConvertFrom-ReviewLoopDirectCommand -Command $payload
    if ($null -eq $parsed) {
        return $true
    }
    $runner = [System.IO.Path]::GetFileNameWithoutExtension([string]$parsed.FilePath).ToLowerInvariant()
    $arguments = @($parsed.Arguments | ForEach-Object { [string]$_ })

    if ($runner -eq "git") {
        $gitArguments = @($arguments | ForEach-Object { $_.ToLowerInvariant() })
        $forbiddenGitOptions = @(
            "-C", "-c", "--config-env", "--exec-path", "--git-dir", "--work-tree",
            "-o", "--ext-diff", "--textconv", "--filters", "--open-files-in-pager"
        )
        if (@($gitArguments | Where-Object {
            $_ -in $forbiddenGitOptions -or
            $_ -match '^(?:-[cC].+|-[oO].+)$' -or
            $_ -match '^--(?:config-env|exec-path|git-dir|work-tree|ext-diff|textconv|filters|open-files-in-pager)='
        }).Count -gt 0) {
            return $true
        }
        $allowedGlobalOptions = @(
            "--no-pager", "--no-optional-locks", "--literal-pathspecs",
            "--glob-pathspecs", "--noglob-pathspecs", "--icase-pathspecs"
        )
        $subcommandIndex = 0
        while ($subcommandIndex -lt $gitArguments.Count -and
            $gitArguments[$subcommandIndex] -in $allowedGlobalOptions) {
            $subcommandIndex++
        }
        if ($subcommandIndex -ge $gitArguments.Count) {
            return $true
        }
        $readOnlyVerbs = @(
            "blame", "cat-file", "describe", "diff", "for-each-ref", "grep",
            "log", "ls-files", "ls-tree", "merge-base", "name-rev", "rev-parse",
            "show", "status"
        )
        return $gitArguments[$subcommandIndex] -notin $readOnlyVerbs
    }

    if ($runner -in @("rg", "ripgrep") -and @($arguments | Where-Object {
        $_ -in @("--pre", "--hostname-bin", "--search-zip", "-z") -or
        $_ -match '^--(?:pre|hostname-bin)=' -or
        $_ -match '^-[a-z]*z[a-z]*$'
    }).Count -gt 0) {
        return $true
    }
    if ($runner -in @("rg", "ripgrep")) {
        return $false
    }

    $allowedRunners = @(
        "apply_patch", "apply-patch",
        "rg", "ripgrep", "tree", "where",
        "get-childitem", "get-content", "get-filehash", "get-item",
        "get-location", "get-command", "resolve-path",
        "test-path", "compare-object", "measure-object", "select-object",
        "format-list", "format-table", "out-string", "write-output",
        "dir", "ls", "type", "pwd", "echo"
    )
    if ($runner -notin $allowedRunners) {
        return $true
    }
    return $false
}

function Update-ReviewLoopCodexActivity {
    param(
        [Parameter(Mandatory = $true)][string]$Line,
        [Parameter(Mandatory = $true)][object]$Activity
    )

    foreach ($property in @(
        "CommandFailureCount", "EventErrorCount", "EventStreamLossCount",
        "PolicyViolationCount", "MalformedEventCount"
    )) {
        if ($Activity.PSObject.Properties.Name -notcontains $property) {
            $Activity | Add-Member -NotePropertyName $property -NotePropertyValue 0
        }
    }
    if ($Activity.PSObject.Properties.Name -notcontains "PolicyViolationReason") {
        $Activity | Add-Member -NotePropertyName PolicyViolationReason -NotePropertyValue ""
    }
    if ($Activity.PSObject.Properties.Name -notcontains "Usage") {
        $Activity | Add-Member -NotePropertyName Usage -NotePropertyValue ([pscustomobject]@{
            InputTokens = 0L; CachedInputTokens = 0L; OutputTokens = 0L; ReasoningOutputTokens = 0L
        })
    }

    try {
        $event = $Line | ConvertFrom-Json
    }
    catch {
        $Activity.MalformedEventCount = [int]$Activity.MalformedEventCount + 1
        Write-ReviewLoopStatus -Message "Codex emitted malformed JSONL; the role trace will be rejected." -Kind Warning -Indent 1
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
    if ($type -eq "turn.completed") {
        $eventUsage = Get-ReviewLoopObjectProperty -Object $event -Name "usage"
        $map = @{
            InputTokens = "input_tokens"
            CachedInputTokens = "cached_input_tokens"
            OutputTokens = "output_tokens"
            ReasoningOutputTokens = "reasoning_output_tokens"
        }
        foreach ($entry in $map.GetEnumerator()) {
            $value = Get-ReviewLoopObjectProperty -Object $eventUsage -Name $entry.Value -Default 0
            $Activity.Usage.($entry.Key) = [long]$Activity.Usage.($entry.Key) + [long]$value
        }
    }

    $item = Get-ReviewLoopObjectProperty -Object $event -Name "item"
    $itemType = [string](Get-ReviewLoopObjectProperty -Object $item -Name "type" -Default "")
    if ($type -eq "item.started") {
        $Activity.ActionCount = [int]$Activity.ActionCount + 1
        if ($itemType -eq "command_execution") {
            $command = [string](Get-ReviewLoopObjectProperty -Object $item -Name "command" -Default "command")
            if (Test-ReviewLoopForbiddenRoleCommand -Command $command) {
                $Activity.PolicyViolationCount = [int]$Activity.PolicyViolationCount + 1
                $Activity.PolicyViolationReason = ConvertTo-ReviewLoopRedactedText (
                    "Model role attempted a command outside the unattended allowlist: $command"
                )
                Write-ReviewLoopStatus -Message $Activity.PolicyViolationReason -Kind Error -Indent 1
            }
            elseif (Test-ReviewLoopOutputLevel -Minimum balanced) {
                Write-ReviewLoopStatus -Message "CLI: $command" -Kind Muted -Indent 1
            }
        }
    }
    elseif ($type -eq "item.completed" -and $itemType -eq "command_execution") {
        $exitCode = [int](Get-ReviewLoopObjectProperty -Object $item -Name "exit_code" -Default 0)
        if ($exitCode -ne 0) {
            $command = [string](Get-ReviewLoopObjectProperty -Object $item -Name "command" -Default "internal command")
            $output = [string](Get-ReviewLoopObjectProperty -Object $item -Name "aggregated_output" -Default "")
            if (Test-ReviewLoopCommandReturnedNoResult -Command $command -ExitCode $exitCode -Output $output) {
                if (Test-ReviewLoopOutputLevel -Minimum detailed) {
                    Write-ReviewLoopStatus -Message "CLI returned no results: $command" -Kind Muted -Indent 1
                }
            }
            else {
                $Activity.CommandFailureCount = [int]$Activity.CommandFailureCount + 1
                Write-ReviewLoopStatus -Message "CLI command failed (exit code $exitCode): $command" -Kind Warning -Indent 1
                foreach ($excerpt in @(Get-ReviewLoopTextExcerpt -Text $output -MaxLines 4)) {
                    Write-ReviewLoopStatus -Message $excerpt -Kind Muted -Indent 2
                }
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
        if ($message -match "(?i)^in-process app-server event stream lagged; dropped \d+ events\b") {
            $Activity.EventStreamLossCount = [int]$Activity.EventStreamLossCount + 1
            Write-ReviewLoopStatus -Message $message -Kind Warning -Indent 1
        }
        elseif (Test-ReviewLoopCodexAdvisoryMessage -Message $message) {
            if (Test-ReviewLoopOutputLevel -Minimum detailed) {
                Write-ReviewLoopStatus -Message $message -Kind Muted -Indent 1
            }
        }
        else {
            $Activity.EventErrorCount = [int]$Activity.EventErrorCount + 1
            Write-ReviewLoopStatus -Message $message -Kind Error -Indent 1
        }
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

function New-ReviewLoopTextTail {
    return [pscustomobject]@{
        Lines = [System.Collections.Generic.Queue[string]]::new()
        Characters = 0
    }
}

function Add-ReviewLoopTextTailLine {
    param(
        [Parameter(Mandatory = $true)][object]$Tail,
        [AllowNull()][string]$Line,
        [ValidateRange(1024, 1048576)][int]$MaxCharacters = 65536,
        [ValidateRange(10, 10000)][int]$MaxLines = 256
    )

    $bounded = [string]$Line
    $lineBudget = $MaxCharacters - 1
    if ($bounded.Length -gt $lineBudget) {
        $bounded = $bounded.Substring($bounded.Length - $lineBudget)
    }
    $Tail.Lines.Enqueue($bounded)
    $Tail.Characters = [int]$Tail.Characters + $bounded.Length + 1
    while ($Tail.Lines.Count -gt $MaxLines -or [int]$Tail.Characters -gt $MaxCharacters) {
        $removed = $Tail.Lines.Dequeue()
        $Tail.Characters = [Math]::Max(0, [int]$Tail.Characters - $removed.Length - 1)
    }
}

function Get-ReviewLoopTextTail {
    param([Parameter(Mandatory = $true)][object]$Tail)
    return (@($Tail.Lines.ToArray()) -join [Environment]::NewLine)
}

function Stop-ReviewLoopProcessTree {
    param([AllowNull()][System.Diagnostics.Process]$Process)

    if ($null -eq $Process) {
        return $true
    }
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            if ($Process.HasExited) {
                return $true
            }
            $Process.Kill($true)
            if ($Process.WaitForExit(2000)) {
                return $true
            }
        }
        catch {
            try {
                if ($Process.HasExited) {
                    return $true
                }
            }
            catch {
                # Retry while the process handle remains usable.
            }
        }
        Start-Sleep -Milliseconds 50
    }
    try {
        return [bool]$Process.HasExited
    }
    catch {
        return $false
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
        [switch]$AppendLogs,
        [ValidateRange(0, 86400)][int]$TimeoutSeconds = 0
    )

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $StartInfo
    $stdoutWriter = $null
    $stderrWriter = $null
    $stdoutTail = New-ReviewLoopTextTail
    $stderrTail = New-ReviewLoopTextTail
    $activity = [pscustomobject]@{
        ActionCount = 0
        ThreadId = ""
        LastActivity = [DateTimeOffset]::UtcNow
        CommandFailureCount = 0
        EventErrorCount = 0
        EventStreamLossCount = 0
        PolicyViolationCount = 0
        PolicyViolationReason = ""
        MalformedEventCount = 0
        Usage = [pscustomobject]@{
            InputTokens = 0L
            CachedInputTokens = 0L
            OutputTokens = 0L
            ReasoningOutputTokens = 0L
        }
    }
    $startedAt = [DateTimeOffset]::UtcNow
    $exitCode = -1
    $wasStarted = $false
    $timedOut = $false
    $policyStopped = $false
    $stdinClosed = $false
    $inputWriteFailed = $false
    $inputWriteFailureReason = ""
    try {
        $stdoutWriter = New-ReviewLoopStreamWriter -Path $StdoutPath -Append:$AppendLogs
        $stderrWriter = New-ReviewLoopStreamWriter -Path $StderrPath -Append:$AppendLogs
        if ($AppendLogs) {
            $marker = "--- new attempt $(Get-Date -Format o) ---"
            $stderrWriter.WriteLine($marker)
        }
        if (-not $process.Start()) {
            throw "$DisplayName could not be started."
        }
        $wasStarted = $true
        $stdoutDone = $false
        $stderrDone = $false
        $stdoutTask = $process.StandardOutput.ReadLineAsync()
        $stderrTask = $process.StandardError.ReadLineAsync()
        $stdinTask = if ($null -ne $InputText) {
            $process.StandardInput.WriteAsync($InputText)
        }
        else {
            [System.Threading.Tasks.Task]::CompletedTask
        }
        $heartbeatSeconds = [int](Get-ReviewLoopConsoleOption -Name HeartbeatSeconds)
        $nextHeartbeat = if ($heartbeatSeconds -gt 0) {
            [DateTimeOffset]::UtcNow.AddSeconds($heartbeatSeconds)
        }
        else {
            [DateTimeOffset]::MaxValue
        }

        while (-not ($stdoutDone -and $stderrDone -and $process.HasExited)) {
            $readAny = $false
            if (-not $stdinClosed -and $stdinTask.IsCompleted) {
                try {
                    [void]$stdinTask.GetAwaiter().GetResult()
                }
                catch {
                    if (-not $timedOut -and -not $policyStopped) {
                        $inputWriteFailed = $true
                        $inputWriteFailureReason = ConvertTo-ReviewLoopRedactedText $_.Exception.Message
                        $stderrWriter.WriteLine($inputWriteFailureReason)
                        Add-ReviewLoopTextTailLine -Tail $stderrTail -Line $inputWriteFailureReason
                    }
                }
                $process.StandardInput.Close()
                $stdinClosed = $true
                $readAny = $true
            }
            while (-not $stdoutDone -and $stdoutTask.IsCompleted) {
                $line = $stdoutTask.GetAwaiter().GetResult()
                if ($null -eq $line) {
                    $stdoutDone = $true
                }
                else {
                    if ($EventKind -eq "Codex") {
                        Update-ReviewLoopCodexActivity -Line $line -Activity $activity
                    }
                    $safeLine = ConvertTo-ReviewLoopRedactedText $line
                    $stdoutWriter.WriteLine($safeLine)
                    Add-ReviewLoopTextTailLine -Tail $stdoutTail -Line $safeLine
                    $activity.LastActivity = [DateTimeOffset]::UtcNow
                    $stdoutTask = $process.StandardOutput.ReadLineAsync()
                }
                $readAny = $true
            }
            while (-not $stderrDone -and $stderrTask.IsCompleted) {
                $line = $stderrTask.GetAwaiter().GetResult()
                if ($null -eq $line) {
                    $stderrDone = $true
                }
                else {
                    $safeLine = ConvertTo-ReviewLoopRedactedText $line
                    $stderrWriter.WriteLine($safeLine)
                    Add-ReviewLoopTextTailLine -Tail $stderrTail -Line $safeLine
                    $activity.LastActivity = [DateTimeOffset]::UtcNow
                    if (Test-ReviewLoopOutputLevel -Minimum detailed) {
                        Write-ReviewLoopStatus -Message $safeLine -Kind Muted -Indent 1
                    }
                    $stderrTask = $process.StandardError.ReadLineAsync()
                }
                $readAny = $true
            }

            $now = [DateTimeOffset]::UtcNow
            if (-not $policyStopped -and [int]$activity.PolicyViolationCount -gt 0) {
                if (-not (Stop-ReviewLoopProcessTree -Process $process)) {
                    throw "$DisplayName process tree could not be stopped after a command-policy violation."
                }
                $policyStopped = $true
            }
            if (-not $timedOut -and $TimeoutSeconds -gt 0 -and
                ($now - $startedAt).TotalSeconds -ge $TimeoutSeconds) {
                $timedOut = $true
                Write-ReviewLoopStatus -Message "$DisplayName exceeded its ${TimeoutSeconds}s time limit; stopping its process tree." -Kind Warning
                if (-not (Stop-ReviewLoopProcessTree -Process $process)) {
                    throw "$DisplayName did not stop after its time limit."
                }
            }
            if ($now -ge $nextHeartbeat) {
                $elapsed = Format-ReviewLoopDuration -Duration ($now - $startedAt)
                $idleSeconds = [Math]::Max(0, [int]($now - $activity.LastActivity).TotalSeconds)
                $activityText = if ($EventKind -eq "Codex") {
                    "$($activity.ActionCount) CLI actions"
                }
                else {
                    "process active"
                }
                Write-ReviewLoopStatus -Message "$DisplayName running for $elapsed · $activityText · last activity ${idleSeconds}s ago" -Kind Progress -Inline
                $nextHeartbeat = $now.AddSeconds($heartbeatSeconds)
            }
            if (-not $readAny -and -not ($stdoutDone -and $stderrDone -and $process.HasExited)) {
                Start-Sleep -Milliseconds 20
            }
        }
        $process.WaitForExit()
        $exitCode = if ($timedOut) { 124 } else { $process.ExitCode }
    }
    catch {
        Add-ReviewLoopTextTailLine -Tail $stderrTail `
            -Line (ConvertTo-ReviewLoopRedactedText $_.Exception.Message)
        if ($null -ne $stderrWriter) {
            $stderrWriter.WriteLine((ConvertTo-ReviewLoopRedactedText $_.Exception.Message))
        }
        throw
    }
    finally {
        $terminationFailed = $false
        Complete-ReviewLoopInlineStatus
        if ($wasStarted -and -not $stdinClosed) {
            try {
                $process.StandardInput.Close()
            }
            catch {
                # A terminated child may already have closed its input pipe.
            }
        }
        if ($wasStarted -and -not $process.HasExited) {
            $terminationFailed = -not (Stop-ReviewLoopProcessTree -Process $process)
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
        if ($terminationFailed) {
            throw "$DisplayName process tree could not be stopped during cleanup."
        }
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Stdout = Get-ReviewLoopTextTail -Tail $stdoutTail
        Stderr = Get-ReviewLoopTextTail -Tail $stderrTail
        StartedAt = $startedAt
        FinishedAt = [DateTimeOffset]::UtcNow
        Duration = [DateTimeOffset]::UtcNow - $startedAt
        ActionCount = [int]$activity.ActionCount
        ThreadId = [string]$activity.ThreadId
        TimedOut = $timedOut
        CommandFailureCount = [int]$activity.CommandFailureCount
        EventErrorCount = [int]$activity.EventErrorCount
        EventStreamLossCount = [int]$activity.EventStreamLossCount
        PolicyViolationCount = [int]$activity.PolicyViolationCount
        PolicyViolationReason = [string]$activity.PolicyViolationReason
        MalformedEventCount = [int]$activity.MalformedEventCount
        InputWriteFailed = $inputWriteFailed
        InputWriteFailureReason = $inputWriteFailureReason
        Usage = $activity.Usage
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
        [string]$CallId = "",
        [string]$DeveloperInstructions = "",
        [ValidateRange(1, 86400)][int]$TimeoutSeconds = 2700
    )

    $repo = Resolve-ReviewLoopPath -Path $RepoPath -MustExist
    $logDirectory = Resolve-ReviewLoopPath -Path $LogRoot
    [System.IO.Directory]::CreateDirectory($logDirectory) | Out-Null
    $executable = Resolve-CodexCliExecutable -CodexPath $CodexPath
    $safeRole = [regex]::Replace($Role.ToLowerInvariant(), "[^a-z0-9-]+", "-").Trim("-")
    if ([string]::IsNullOrWhiteSpace($CallId)) {
        $CallId = "{0}-{1}" -f (Get-Date -Format "yyyyMMdd-HHmmss-fff"), ([Guid]::NewGuid().ToString("N").Substring(0, 8))
    }
    $stemBase = Join-Path $logDirectory "$CallId-$safeRole"
    $stem = $stemBase
    $invocation = 2
    while (
        (Test-Path -LiteralPath "$stem.jsonl") -or
        (Test-Path -LiteralPath "$stem.stderr.txt") -or
        (Test-Path -LiteralPath "$stem.result.json")
    ) {
        $stem = "$stemBase-run$invocation"
        $invocation++
    }
    $jsonlPath = "$stem.jsonl"
    $stderrPath = "$stem.stderr.txt"
    $resultPath = "$stem.result.json"

    $attemptRecords = [System.Collections.Generic.List[object]]::new()
    $totalUsage = [ordered]@{
        InputTokens = 0L
        CachedInputTokens = 0L
        OutputTokens = 0L
        ReasoningOutputTokens = 0L
    }
    $currentMode = $Mode
    $currentThreadId = $ThreadId
    $currentPrompt = $Prompt
    $effectiveDeveloperInstructions = if ($Mode -eq "Review" -and
        [string]::IsNullOrWhiteSpace($DeveloperInstructions)) {
        $Prompt
    }
    else {
        $DeveloperInstructions
    }
    $lastThreadId = $ThreadId
    $arguments = @()

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        if (Test-Path -LiteralPath $resultPath) {
            Remove-Item -LiteralPath $resultPath -Force
        }
        $arguments = Get-CodexRoleArguments `
            -RepoPath $repo `
            -Model $Model `
            -Thinking $Thinking `
            -Speed $Speed `
            -Sandbox $Sandbox `
            -Mode $currentMode `
            -ReviewBase $ReviewBase `
            -ThreadId $currentThreadId `
            -DeveloperInstructions $effectiveDeveloperInstructions `
            -SchemaPath $SchemaPath `
            -ResultPath $resultPath

        Write-ReviewLoopStatus -Message "$Role · $Model/$Thinking · $Speed · attempt $attempt/$MaxAttempts" -Kind Progress
        $startInfo = New-CodexProcessStartInfo -CodexExecutable $executable -Arguments $arguments
        Clear-ReviewLoopModelHelperEnvironment -StartInfo $startInfo
        $observed = $null
        try {
            $observed = Invoke-ReviewLoopObservedProcess `
                -StartInfo $startInfo `
                -DisplayName $Role `
                -StdoutPath $jsonlPath `
                -StderrPath $stderrPath `
                -InputText $(if ($currentMode -eq "Review") { $null } else { $currentPrompt }) `
                -EventKind Codex `
                -AppendLogs:($attempt -gt 1) `
                -TimeoutSeconds $TimeoutSeconds
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
        $sanitizedResult = Read-ReviewLoopSanitizedResult -Path $resultPath
        $usage = if ($null -ne $observed) {
            $observed.Usage
        }
        else {
            [pscustomobject]@{
                InputTokens = 0L
                CachedInputTokens = 0L
                OutputTokens = 0L
                ReasoningOutputTokens = 0L
            }
        }
        foreach ($name in @("InputTokens", "CachedInputTokens", "OutputTokens", "ReasoningOutputTokens")) {
            $totalUsage[$name] = [long]$totalUsage[$name] + [long]$usage.$name
        }
        if ($null -ne $observed -and -not [string]::IsNullOrWhiteSpace([string]$observed.ThreadId)) {
            $lastThreadId = [string]$observed.ThreadId
        }
        elseif (-not [string]::IsNullOrWhiteSpace($currentThreadId)) {
            $lastThreadId = $currentThreadId
        }

        $diagnosticOutput = (($stderr, $stdout | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        }) -join [Environment]::NewLine).Trim()
        $failureKind = Get-CodexFailureKind -ExitCode $exitCode -Output $diagnosticOutput
        $failureReason = if ($exitCode -eq 0) { "" } else { (($stderr, $stdout | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        }) -join [Environment]::NewLine).Trim() }
        $finalText = ""
        $structured = $null
        if ($null -ne $observed -and [int]$observed.PolicyViolationCount -gt 0) {
            $exitCode = 5
            $failureKind = "forbidden_role_command"
            $failureReason = [string]$observed.PolicyViolationReason
        }
        elseif ($null -ne $observed -and [bool]$observed.InputWriteFailed) {
            $exitCode = 5
            $failureKind = "input_write_error"
            $failureReason = "Codex closed its input pipe before the role prompt was fully delivered: $($observed.InputWriteFailureReason)"
        }
        elseif ($exitCode -eq 0 -and $null -ne $observed -and [int]$observed.MalformedEventCount -gt 0) {
            $exitCode = 5
            $failureKind = "malformed_event_stream"
            $failureReason = "$($observed.MalformedEventCount) malformed Codex JSONL event(s) occurred; the role trace was rejected."
        }
        elseif ($exitCode -eq 0 -and $null -ne $observed -and [int]$observed.CommandFailureCount -gt 0) {
            $exitCode = 5
            $failureKind = "role_command_error"
            $failureReason = "$($observed.CommandFailureCount) internal command(s) failed; the role result was rejected."
        }
        elseif ($exitCode -eq 0 -and $null -ne $observed -and [int]$observed.EventErrorCount -gt 0) {
            $exitCode = 5
            $failureKind = "role_event_error"
            $failureReason = "$($observed.EventErrorCount) Codex error event(s) occurred; the role result was rejected."
        }
        elseif ($exitCode -eq 0 -and $null -ne $observed -and [int]$observed.EventStreamLossCount -gt 0) {
            $exitCode = 5
            $failureKind = "event_stream_loss"
            $failureReason = "Codex dropped app-server events; the incomplete role trace was rejected."
        }
        elseif ($exitCode -eq 0) {
            $finalText = [string]$sanitizedResult.Text
            if ([bool]$sanitizedResult.TooLarge) {
                $exitCode = 4
                $failureKind = "invalid_output"
                $failureReason = "Final result exceeded the 10485760-byte safety limit."
            }
            elseif ([string]::IsNullOrWhiteSpace($finalText)) {
                $exitCode = 4
                $failureKind = "invalid_output"
                $failureReason = "Final result is missing or empty."
            }
            elseif (-not [string]::IsNullOrWhiteSpace($SchemaPath)) {
                $validation = Test-CodexStructuredResult -ResultPath $resultPath -SchemaPath $SchemaPath
                if (-not $validation.Valid) {
                    $exitCode = 4
                    $failureKind = "invalid_structured_output"
                    $failureReason = $validation.Reason
                    $structured = $validation.Value
                }
                else {
                    $structured = $validation.Value
                }
            }
        }

        [void]$attemptRecords.Add([pscustomobject]@{
            Attempt = $attempt
            ExitCode = $exitCode
            FailureKind = $failureKind
            ThreadId = $lastThreadId
            StartedAt = $startedAt
            FinishedAt = $finishedAt
        })

        if ($exitCode -eq 0) {
            Write-ReviewLoopUtf8File -Path $resultPath -Content $finalText

            $duration = Format-ReviewLoopDuration -Duration ($finishedAt - $startedAt)
            $inputTokens = [long]$totalUsage.InputTokens
            $cachedTokens = [long]$totalUsage.CachedInputTokens
            $newInputTokens = [Math]::Max(0L, $inputTokens - $cachedTokens)
            $outputTokens = [long]$totalUsage.OutputTokens
            $usageText = if ($inputTokens -eq 0 -and $cachedTokens -eq 0 -and $outputTokens -eq 0) {
                "usage not reported by CLI"
            }
            else {
                "$newInputTokens new input · $cachedTokens cached input · $outputTokens output tokens"
            }
            Write-ReviewLoopStatus -Message "$Role completed · $duration · $usageText" -Kind Success
            return [pscustomobject]@{
                Success = $true
                Role = $Role
                Model = $Model
                Thinking = $Thinking
                Speed = $Speed
                ExitCode = 0
                FailureKind = "none"
                FailureReason = ""
                ThreadId = $lastThreadId
                Usage = [pscustomobject]$totalUsage
                FinalMessage = $finalText
                StructuredResult = $structured
                Arguments = $arguments
                JsonlPath = $jsonlPath
                ResultPath = $resultPath
                Attempts = $attemptRecords.ToArray()
            }
        }

        $retryable = $failureKind -in @(
            "transient",
            "timeout",
            "invalid_output",
            "invalid_structured_output",
            "role_command_error",
            "role_event_error",
            "event_stream_loss",
            "forbidden_role_command",
            "input_write_error",
            "malformed_event_stream"
        )
        if ($retryable -and $Sandbox -ne "read-only" -and
            [string]::IsNullOrWhiteSpace($lastThreadId) -and
            -not (Test-ReviewLoopGitClean -RepoPath $repo)) {
            $retryable = $false
            $failureKind = "unsafe_partial_mutation"
            $failureReason = "The mutating role changed the worktree but returned no thread ID; a fresh automatic retry would be unsafe."
            $attemptRecords[$attemptRecords.Count - 1].FailureKind = $failureKind
        }
        if (-not $retryable -or $attempt -ge $MaxAttempts) {
            Write-ReviewLoopStatus -Message "$Role failed ($failureKind, exit code $exitCode)" -Kind Error
            foreach ($excerpt in @(Get-ReviewLoopTextExcerpt -Text $failureReason -MaxLines 8)) {
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
                FailureReason = $failureReason
                ThreadId = $lastThreadId
                Usage = [pscustomobject]$totalUsage
                FinalMessage = ""
                StructuredResult = $structured
                Arguments = $arguments
                JsonlPath = $jsonlPath
                ResultPath = $resultPath
                Attempts = $attemptRecords.ToArray()
            }
        }

        $delay = [int][Math]::Min(8, [Math]::Pow(2, $attempt))
        if (-not [string]::IsNullOrWhiteSpace($lastThreadId)) {
            $currentMode = "Resume"
            $currentThreadId = $lastThreadId
            $currentPrompt = @"
The previous $Role turn was rejected for a technical reason: $failureReason
Do not repeat completed investigation or edits. Correct the operational problem, inspect the current worktree, and return a valid final result for the original task.
"@
        }
        elseif ($Mode -ne "Review") {
            $currentMode = $Mode
            $currentPrompt = @"
The previous $Role process failed before a thread ID was available: $failureReason
Inspect the current worktree, preserve correct partial work, and complete the original task.

Original task:
$Prompt
"@
        }
        Write-ReviewLoopStatus -Message "${Role}: $failureKind; retrying in ${delay}s$(if (-not [string]::IsNullOrWhiteSpace($lastThreadId)) { ' on the same thread' } else { '' })." -Kind Warning
        Start-Sleep -Seconds $delay
    }
}
