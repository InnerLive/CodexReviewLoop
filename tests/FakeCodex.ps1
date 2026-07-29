$ErrorActionPreference = "Stop"

function Test-FakeBoolean {
    param([AllowNull()][object]$Value)

    if ($Value -is [bool]) {
        return [bool]$Value
    }
    return [string]$Value -match "^(?i:1|true|yes|on)$"
}

function Get-FakePlanValue {
    param(
        [AllowNull()][object]$Plan,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][object]$Default = $null
    )

    if ($null -ne $Plan -and $Plan.PSObject.Properties.Name -contains $Name) {
        return $Plan.$Name
    }
    return $Default
}

function Read-FakeInvocationPlan {
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $sequence = @(Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json)
    if ($sequence.Count -eq 0) {
        throw "Fake Codex invocation sequence is empty."
    }

    $plan = $sequence[0]
    $remaining = if ($sequence.Count -gt 1) {
        @($sequence[1..($sequence.Count - 1)])
    }
    else {
        @()
    }
    [System.IO.File]::WriteAllText(
        $Path,
        (ConvertTo-Json -InputObject $remaining -Depth 20),
        [System.Text.UTF8Encoding]::new($false))
    return $plan
}

$arguments = @($args)
$prompt = [Console]::In.ReadToEnd()
$logPath = [Environment]::GetEnvironmentVariable("CODEX_REVIEW_LOOP_FAKE_LOG")
$resultOverride = [Environment]::GetEnvironmentVariable("CODEX_REVIEW_LOOP_FAKE_RESULT")
$resultSequencePath = [Environment]::GetEnvironmentVariable("CODEX_REVIEW_LOOP_FAKE_RESULT_SEQUENCE")
$invocationSequencePath = [Environment]::GetEnvironmentVariable("CODEX_REVIEW_LOOP_FAKE_INVOCATION_SEQUENCE")
$exitText = [Environment]::GetEnvironmentVariable("CODEX_REVIEW_LOOP_FAKE_EXIT_CODE")
$stderrText = [Environment]::GetEnvironmentVariable("CODEX_REVIEW_LOOP_FAKE_STDERR")
$eventDelayText = [Environment]::GetEnvironmentVariable("CODEX_REVIEW_LOOP_FAKE_EVENT_DELAY_MS")
$stderrDelayText = [Environment]::GetEnvironmentVariable("CODEX_REVIEW_LOOP_FAKE_STDERR_DELAY_MS")
$commandExitText = [Environment]::GetEnvironmentVariable("CODEX_REVIEW_LOOP_FAKE_COMMAND_EXIT_CODE")
$commandOutputText = [Environment]::GetEnvironmentVariable("CODEX_REVIEW_LOOP_FAKE_COMMAND_OUTPUT")
$nullUsageText = [Environment]::GetEnvironmentVariable("CODEX_REVIEW_LOOP_FAKE_NULL_USAGE")
$hangText = [Environment]::GetEnvironmentVariable("CODEX_REVIEW_LOOP_FAKE_HANG_MS")
$tailDelayText = [Environment]::GetEnvironmentVariable("CODEX_REVIEW_LOOP_FAKE_TAIL_DELAY_MS")
$pidFile = [Environment]::GetEnvironmentVariable("CODEX_REVIEW_LOOP_FAKE_PID_FILE")
$threadId = [Environment]::GetEnvironmentVariable("CODEX_REVIEW_LOOP_FAKE_THREAD")
$mutateSchema = [Environment]::GetEnvironmentVariable("CODEX_REVIEW_LOOP_FAKE_MUTATE_ON_SCHEMA")
$invocationPlan = Read-FakeInvocationPlan -Path $invocationSequencePath

$exitText = [string](Get-FakePlanValue -Plan $invocationPlan -Name "exitCode" -Default $exitText)
$stderrText = [string](Get-FakePlanValue -Plan $invocationPlan -Name "stderr" -Default $stderrText)
$eventDelayText = [string](Get-FakePlanValue -Plan $invocationPlan -Name "eventDelayMs" -Default $eventDelayText)
$stderrDelayText = [string](Get-FakePlanValue -Plan $invocationPlan -Name "stderrDelayMs" -Default $stderrDelayText)
$nullUsageText = Get-FakePlanValue -Plan $invocationPlan -Name "nullUsage" -Default $nullUsageText
$hangText = [string](Get-FakePlanValue -Plan $invocationPlan -Name "hangMs" -Default $hangText)
$tailDelayText = [string](Get-FakePlanValue -Plan $invocationPlan -Name "tailDelayMs" -Default $tailDelayText)
$threadId = [string](Get-FakePlanValue -Plan $invocationPlan -Name "threadId" -Default $threadId)
$emitThread = Get-FakePlanValue -Plan $invocationPlan -Name "emitThread" -Default $true
$plannedResult = Get-FakePlanValue -Plan $invocationPlan -Name "result"
$plannedMutations = @(Get-FakePlanValue -Plan $invocationPlan -Name "mutations" -Default @())
$profileMutation = Get-FakePlanValue -Plan $invocationPlan -Name "profileMutation"
$childPidPath = [string](Get-FakePlanValue -Plan $invocationPlan -Name "childPidPath" -Default "")
$childSleepSeconds = [int](Get-FakePlanValue -Plan $invocationPlan -Name "childSleepSeconds" -Default 60)

if ([string]::IsNullOrWhiteSpace($threadId)) {
    $threadId = "fake-thread-001"
}
if (-not [string]::IsNullOrWhiteSpace($pidFile)) {
    [System.IO.File]::WriteAllText($pidFile, [string]$PID, [System.Text.UTF8Encoding]::new($false))
}
if (-not [string]::IsNullOrWhiteSpace($childPidPath)) {
    $childStartInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $childStartInfo.FileName = Join-Path $PSHOME "pwsh.exe"
    $childStartInfo.UseShellExecute = $false
    $childStartInfo.CreateNoWindow = $true
    [void]$childStartInfo.ArgumentList.Add("-NoProfile")
    [void]$childStartInfo.ArgumentList.Add("-NonInteractive")
    [void]$childStartInfo.ArgumentList.Add("-Command")
    [void]$childStartInfo.ArgumentList.Add("Start-Sleep -Seconds $childSleepSeconds")
    $childProcess = [System.Diagnostics.Process]::Start($childStartInfo)
    [System.IO.File]::WriteAllText(
        $childPidPath,
        [string]$childProcess.Id,
        [System.Text.UTF8Encoding]::new($false))
}

$resultPath = ""
$schemaPath = ""
$repoPath = ""
$callKind = "exec"
$resumeThreadId = ""
for ($index = 0; $index -lt $arguments.Count; $index++) {
    if ($arguments[$index] -eq "-o" -and $index + 1 -lt $arguments.Count) {
        $resultPath = $arguments[$index + 1]
    }
    if ($arguments[$index] -eq "--output-schema" -and $index + 1 -lt $arguments.Count) {
        $schemaPath = $arguments[$index + 1]
    }
    if ($arguments[$index] -ceq "-C" -and $index + 1 -lt $arguments.Count) {
        $repoPath = $arguments[$index + 1]
    }
    if ($arguments[$index] -eq "resume") {
        $callKind = "resume"
        if ($index + 1 -lt $arguments.Count) {
            $resumeThreadId = [string]$arguments[$index + 1]
        }
    }
}

if (-not [string]::IsNullOrWhiteSpace($logPath)) {
    $record = [pscustomobject]@{
        invocationId = [Guid]::NewGuid().ToString("N")
        callKind = $callKind
        resumeThreadId = $resumeThreadId
        arguments = $arguments
        prompt = $prompt
        resultPath = $resultPath
        schemaPath = $schemaPath
    }
    [System.IO.File]::AppendAllText(
        $logPath,
        (($record | ConvertTo-Json -Depth 10 -Compress) + [Environment]::NewLine),
        [System.Text.UTF8Encoding]::new($false))
}

if (-not [string]::IsNullOrWhiteSpace($stderrText) -and [string]::IsNullOrWhiteSpace($stderrDelayText)) {
    [Console]::Error.WriteLine($stderrText)
    [Console]::Error.Flush()
}

$exitCode = 0
if (-not [string]::IsNullOrWhiteSpace($exitText)) {
    $exitCode = [int]$exitText
}

if ($exitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($resultPath)) {
    if ($null -ne $plannedResult) {
        $result = [string]$plannedResult
    }
    elseif (-not [string]::IsNullOrWhiteSpace($resultSequencePath) -and (Test-Path -LiteralPath $resultSequencePath)) {
        $sequence = @(Get-Content -Raw -LiteralPath $resultSequencePath | ConvertFrom-Json)
        if ($sequence.Count -eq 0) {
            throw "Fake Codex result sequence is empty."
        }
        $result = [string]$sequence[0]
        $remaining = if ($sequence.Count -gt 1) { @($sequence[1..($sequence.Count - 1)]) } else { @() }
        [System.IO.File]::WriteAllText(
            $resultSequencePath,
            ($remaining | ConvertTo-Json -Depth 10),
            [System.Text.UTF8Encoding]::new($false))
    }
    elseif (-not [string]::IsNullOrWhiteSpace($resultOverride)) {
        $result = $resultOverride
    }
    elseif ([string]::IsNullOrWhiteSpace($schemaPath)) {
        $result = "No actionable findings."
    }
    else {
        $schemaName = [System.IO.Path]::GetFileName($schemaPath)
        $result = switch ($schemaName) {
            "review-result-v1.schema.json" {
                '{"schemaVersion":"1.0","classification":"clean","summary":"clean","findings":[]}'
            }
            "trigger-decision-v2.schema.json" {
                '{"schemaVersion":"2.0","decisions":[]}'
            }
            "architecture-proposal-v1.schema.json" {
                '{"schemaVersion":"1.0","recommendation":"point_fix","summary":"point","sharedRootCause":"","minimalAlternative":"point","findings":[],"steps":[],"risks":[],"breaksPublicContract":false}'
            }
            "architecture-critique-v1.schema.json" {
                '{"schemaVersion":"1.0","decision":"reject_to_point_fix","confidence":"high","rationale":"bounded","coherentRootCause":false,"allFindingsCovered":true,"allRequiredPathsCovered":true,"minimalEnough":false,"missingPaths":[],"requiredChanges":[]}'
            }
            "fixer-result-v1.schema.json" {
                '{"schemaVersion":"1.0","outcome":"no_change","summary":"none","changedPaths":[],"targetedTest":{"filePath":"dotnet","arguments":["test"],"rationale":"targeted regression"},"remainingRisk":""}'
            }
            "verifier-result-v2.schema.json" {
                '{"schemaVersion":"2.0","verdict":"reproduced","patchSafety":"safe","confidence":"high","rationale":"still present","regressions":[],"evidence":[]}'
            }
            default {
                '{}'
            }
        }
    }
    $parent = Split-Path -Parent $resultPath
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    }
    [System.IO.File]::WriteAllText($resultPath, $result, [System.Text.UTF8Encoding]::new($false))
    if (-not [string]::IsNullOrWhiteSpace($mutateSchema) -and
        [System.IO.Path]::GetFileName($schemaPath) -eq $mutateSchema -and
        -not [string]::IsNullOrWhiteSpace($repoPath)) {
        [System.IO.File]::AppendAllText(
            (Join-Path $repoPath "fake-review-loop-change.test.txt"),
            ([Guid]::NewGuid().ToString("N") + [Environment]::NewLine),
            [System.Text.UTF8Encoding]::new($false))
    }
}

if ($plannedMutations.Count -gt 0) {
    if ([string]::IsNullOrWhiteSpace($repoPath)) {
        throw "Fake Codex cannot apply a planned mutation without a repository path."
    }
    $repoRoot = [System.IO.Path]::GetFullPath($repoPath)
    $repoPrefix = [System.IO.Path]::TrimEndingDirectorySeparator($repoRoot) +
        [System.IO.Path]::DirectorySeparatorChar
    foreach ($mutation in $plannedMutations) {
        $relative = [string](Get-FakePlanValue -Plan $mutation -Name "path" -Default "")
        if ([string]::IsNullOrWhiteSpace($relative) -or [System.IO.Path]::IsPathRooted($relative) -or
            $relative -match '(^|[\\/])\.\.([\\/]|$)') {
            throw "Fake Codex mutation path is invalid: '$relative'."
        }
        $absolute = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $relative))
        if (-not $absolute.StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Fake Codex mutation path escapes the repository: '$relative'."
        }
        $parent = Split-Path -Parent $absolute
        if (-not [string]::IsNullOrWhiteSpace($parent)) {
            [System.IO.Directory]::CreateDirectory($parent) | Out-Null
        }
        $content = [string](Get-FakePlanValue -Plan $mutation -Name "content" -Default "")
        $append = Test-FakeBoolean (Get-FakePlanValue -Plan $mutation -Name "append" -Default $false)
        if ($append) {
            [System.IO.File]::AppendAllText(
                $absolute,
                $content,
                [System.Text.UTF8Encoding]::new($false))
        }
        else {
            [System.IO.File]::WriteAllText(
                $absolute,
                $content,
                [System.Text.UTF8Encoding]::new($false))
        }
    }
}

if ($null -ne $profileMutation) {
    $profileMutationPath = [string](Get-FakePlanValue `
        -Plan $profileMutation -Name "path" -Default "")
    if ([string]::IsNullOrWhiteSpace($profileMutationPath) -or
        [System.IO.Path]::GetExtension($profileMutationPath) -ne ".psd1" -or
        -not (Test-Path -LiteralPath $profileMutationPath -PathType Leaf)) {
        throw "Fake Codex profile mutation path is invalid: '$profileMutationPath'."
    }
    $profileText = [System.IO.File]::ReadAllText($profileMutationPath)
    foreach ($replacement in @(Get-FakePlanValue `
        -Plan $profileMutation -Name "replacements" -Default @())) {
        $old = [string](Get-FakePlanValue -Plan $replacement -Name "old" -Default "")
        $new = [string](Get-FakePlanValue -Plan $replacement -Name "new" -Default "")
        if ([string]::IsNullOrEmpty($old) -or -not $profileText.Contains($old)) {
            throw "Fake Codex profile mutation did not find the requested text."
        }
        $profileText = $profileText.Replace($old, $new)
    }
    [System.IO.File]::WriteAllText(
        $profileMutationPath,
        $profileText,
        [System.Text.UTF8Encoding]::new($false))
}

if (Test-FakeBoolean $emitThread) {
    [Console]::Out.WriteLine('{"type":"thread.started","thread_id":"' + $threadId + '"}')
    [Console]::Out.Flush()
}

$rawEvents = @(Get-FakePlanValue -Plan $invocationPlan -Name "rawEvents" -Default @())
foreach ($rawEvent in $rawEvents) {
    [Console]::Out.WriteLine([string]$rawEvent)
    [Console]::Out.Flush()
}

$commandPlans = [System.Collections.Generic.List[object]]::new()
$hasPlanCommands = $null -ne $invocationPlan -and
    $invocationPlan.PSObject.Properties.Name -contains "commands"
if ($hasPlanCommands) {
    foreach ($commandPlan in @(Get-FakePlanValue -Plan $invocationPlan -Name "commands" -Default @())) {
        [void]$commandPlans.Add($commandPlan)
    }
}
elseif (-not [string]::IsNullOrWhiteSpace($commandExitText)) {
    $legacyOutput = if ($null -eq $commandOutputText) { "fake command output" } else { $commandOutputText }
    [void]$commandPlans.Add([pscustomobject]@{
        command = '"C:\Program Files\PowerShell\7\pwsh.exe" -Command ''Get-Location'''
        exitCode = [int]$commandExitText
        output = $legacyOutput
    })
}

$commandIndex = 0
foreach ($commandPlan in $commandPlans) {
    $commandIndex++
    $commandName = [string](Get-FakePlanValue `
        -Plan $commandPlan `
        -Name "command" `
        -Default '"C:\Program Files\PowerShell\7\pwsh.exe" -Command ''Get-Location''')
    $commandExit = [int](Get-FakePlanValue -Plan $commandPlan -Name "exitCode" -Default 0)
    $commandOutput = [string](Get-FakePlanValue -Plan $commandPlan -Name "output" -Default "")
    $commandStatus = [string](Get-FakePlanValue -Plan $commandPlan -Name "status" -Default "completed")
    $commandDelayText = [string](Get-FakePlanValue `
        -Plan $commandPlan `
        -Name "delayMs" `
        -Default $eventDelayText)

    $startedEvent = [ordered]@{
        type = "item.started"
        item = [ordered]@{
            id = "fake-command-$commandIndex"
            type = "command_execution"
            command = $commandName
        }
    }
    [Console]::Out.WriteLine(($startedEvent | ConvertTo-Json -Depth 6 -Compress))
    [Console]::Out.Flush()
    if (-not [string]::IsNullOrWhiteSpace($commandDelayText)) {
        Start-Sleep -Milliseconds ([int]$commandDelayText)
    }

    $completedEvent = [ordered]@{
        type = "item.completed"
        item = [ordered]@{
            id = "fake-command-$commandIndex"
            type = "command_execution"
            command = $commandName
            exit_code = $commandExit
            aggregated_output = $commandOutput
            status = $commandStatus
        }
    }
    [Console]::Out.WriteLine(($completedEvent | ConvertTo-Json -Depth 6 -Compress))
    [Console]::Out.Flush()
}
if ($commandPlans.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($eventDelayText)) {
    Start-Sleep -Milliseconds ([int]$eventDelayText)
}

if (-not [string]::IsNullOrWhiteSpace($stderrText) -and -not [string]::IsNullOrWhiteSpace($stderrDelayText)) {
    Start-Sleep -Milliseconds ([int]$stderrDelayText)
    [Console]::Error.WriteLine($stderrText)
    [Console]::Error.Flush()
}

if (-not [string]::IsNullOrWhiteSpace($hangText)) {
    if ($hangText -eq "infinite") {
        while ($true) {
            Start-Sleep -Seconds 60
        }
    }
    Start-Sleep -Milliseconds ([int]$hangText)
}

if (Test-FakeBoolean $nullUsageText) {
    [Console]::Out.WriteLine('{"type":"turn.completed","usage":null}')
}
else {
    [Console]::Out.WriteLine('{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":80,"output_tokens":20,"reasoning_output_tokens":5}}')
}
[Console]::Out.Flush()
if (-not [string]::IsNullOrWhiteSpace($tailDelayText)) {
    Start-Sleep -Milliseconds ([int]$tailDelayText)
}
exit $exitCode
