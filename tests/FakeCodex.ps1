$ErrorActionPreference = "Stop"

$arguments = @($args)
$prompt = [Console]::In.ReadToEnd()
$logPath = [Environment]::GetEnvironmentVariable("CODEX_REVIEW_LOOP_FAKE_LOG")
$resultOverride = [Environment]::GetEnvironmentVariable("CODEX_REVIEW_LOOP_FAKE_RESULT")
$resultSequencePath = [Environment]::GetEnvironmentVariable("CODEX_REVIEW_LOOP_FAKE_RESULT_SEQUENCE")
$exitText = [Environment]::GetEnvironmentVariable("CODEX_REVIEW_LOOP_FAKE_EXIT_CODE")
$stderrText = [Environment]::GetEnvironmentVariable("CODEX_REVIEW_LOOP_FAKE_STDERR")
$eventDelayText = [Environment]::GetEnvironmentVariable("CODEX_REVIEW_LOOP_FAKE_EVENT_DELAY_MS")
$stderrDelayText = [Environment]::GetEnvironmentVariable("CODEX_REVIEW_LOOP_FAKE_STDERR_DELAY_MS")
$commandExitText = [Environment]::GetEnvironmentVariable("CODEX_REVIEW_LOOP_FAKE_COMMAND_EXIT_CODE")
$tailDelayText = [Environment]::GetEnvironmentVariable("CODEX_REVIEW_LOOP_FAKE_TAIL_DELAY_MS")
$pidFile = [Environment]::GetEnvironmentVariable("CODEX_REVIEW_LOOP_FAKE_PID_FILE")
$threadId = [Environment]::GetEnvironmentVariable("CODEX_REVIEW_LOOP_FAKE_THREAD")
$mutateSchema = [Environment]::GetEnvironmentVariable("CODEX_REVIEW_LOOP_FAKE_MUTATE_ON_SCHEMA")
if ([string]::IsNullOrWhiteSpace($threadId)) {
    $threadId = "fake-thread-001"
}
if (-not [string]::IsNullOrWhiteSpace($pidFile)) {
    [System.IO.File]::WriteAllText($pidFile, [string]$PID, [System.Text.UTF8Encoding]::new($false))
}

$resultPath = ""
$schemaPath = ""
$repoPath = ""
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
}

$isBaseReview = ($arguments -contains "review") -and ($arguments -contains "--base")
if ($isBaseReview -and (($arguments -contains "-") -or -not [string]::IsNullOrEmpty($prompt))) {
    [Console]::Error.WriteLine("error: the argument '--base <BRANCH>' cannot be used with '[PROMPT]'")
    exit 2
}

if (-not [string]::IsNullOrWhiteSpace($logPath)) {
    $record = [pscustomobject]@{
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
    if (-not [string]::IsNullOrWhiteSpace($resultSequencePath) -and (Test-Path -LiteralPath $resultSequencePath)) {
        $sequence = @(Get-Content -Raw -LiteralPath $resultSequencePath | ConvertFrom-Json)
        if ($sequence.Count -eq 0) {
            throw "Fake-Codex-Ergebnissequenz ist leer."
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
            "trigger-decision-v1.schema.json" {
                '{"schemaVersion":"1.0","relation":"independent_same_file","architectureRecommended":false,"confidence":"high","rationale":"independent","evidence":[]}'
            }
            "architecture-proposal-v1.schema.json" {
                '{"schemaVersion":"1.0","recommendation":"point_fix","summary":"point","sharedRootCause":"","minimalAlternative":"point","findings":[],"steps":[],"risks":[],"breaksPublicContract":false}'
            }
            "architecture-critique-v1.schema.json" {
                '{"schemaVersion":"1.0","decision":"reject_to_point_fix","confidence":"high","rationale":"bounded","coherentRootCause":false,"allFindingsCovered":true,"allRequiredPathsCovered":true,"minimalEnough":false,"missingPaths":[],"requiredChanges":[]}'
            }
            "fixer-result-v1.schema.json" {
                '{"schemaVersion":"1.0","outcome":"no_change","summary":"none","changedPaths":[],"targetedTests":[],"remainingRisk":""}'
            }
            "verifier-result-v1.schema.json" {
                '{"schemaVersion":"1.0","verdict":"reproduced","confidence":"high","rationale":"still present","evidence":[],"targetedTest":{"command":"","passed":false,"evidence":""}}'
            }
            "prompt-eval-suite-v1.schema.json" {
                '{"schemaVersion":"1.0","suite":"fake","cases":[]}'
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
            (Join-Path $repoPath "fake-review-loop-change.txt"),
            ([Guid]::NewGuid().ToString("N") + [Environment]::NewLine),
            [System.Text.UTF8Encoding]::new($false))
    }
}

[Console]::Out.WriteLine('{"type":"thread.started","thread_id":"' + $threadId + '"}')
[Console]::Out.Flush()
if (-not [string]::IsNullOrWhiteSpace($commandExitText)) {
    [Console]::Out.WriteLine('{"type":"item.started","item":{"type":"command_execution","command":"fake internal command"}}')
    [Console]::Out.Flush()
}
if (-not [string]::IsNullOrWhiteSpace($eventDelayText)) {
    Start-Sleep -Milliseconds ([int]$eventDelayText)
}
if (-not [string]::IsNullOrWhiteSpace($commandExitText)) {
    $commandExit = [int]$commandExitText
    [Console]::Out.WriteLine(
        '{"type":"item.completed","item":{"type":"command_execution","command":"fake internal command","exit_code":' +
        $commandExit +
        ',"aggregated_output":"fake command output"}}')
    [Console]::Out.Flush()
}
if (-not [string]::IsNullOrWhiteSpace($stderrText) -and -not [string]::IsNullOrWhiteSpace($stderrDelayText)) {
    Start-Sleep -Milliseconds ([int]$stderrDelayText)
    [Console]::Error.WriteLine($stderrText)
    [Console]::Error.Flush()
}
[Console]::Out.WriteLine('{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":80,"output_tokens":20,"reasoning_output_tokens":5}}')
[Console]::Out.Flush()
if (-not [string]::IsNullOrWhiteSpace($tailDelayText)) {
    Start-Sleep -Milliseconds ([int]$tailDelayText)
}
exit $exitCode
