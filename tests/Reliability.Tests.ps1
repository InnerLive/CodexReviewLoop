$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
$modulePath = Join-Path $root "CodexReviewLoop.psd1"
$fakeCodex = Join-Path $here "FakeCodex.ps1"

Import-Module $modulePath -Force

function New-ReliabilityRepo {
    param([Parameter(Mandatory = $true)][string]$Path)

    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    & git -C $Path init -q
    & git -C $Path config user.email "review-loop-tests@example.invalid"
    & git -C $Path config user.name "Review Loop Tests"
    & git -C $Path config core.excludesFile (Join-Path $Path ".git\info\exclude")
    & git -C $Path config core.autocrlf false
    Set-Content -LiteralPath (Join-Path $Path "README.txt") -Value "initial"
    Set-Content -LiteralPath (Join-Path $Path "review-loop-test.proj") -Value @"
<Project>
  <Target Name="VSTest">
    <Message Text="targeted test passed" Importance="High" />
  </Target>
</Project>
"@
    & git -C $Path add README.txt review-loop-test.proj
    & git -C $Path commit -q -m "initial"
    return $Path
}

function New-ReliabilityConfig {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$LogRoot,
        [string]$Name = "Reliability"
    )

    $literalRepo = $RepoPath.Replace("'", "''")
    $literalLog = $LogRoot.Replace("'", "''")
    $content = @"
@{
    Name = '$Name'
    RepositoryPath = '$literalRepo'
    ReviewBase = 'HEAD'
    ReviewerInstructions = ''
    LogRoot = '$literalLog'
    CleanPassesRequired = 2
    MaxReviewCycles = 6
    LessonsLearnedCommitThreshold = 6
    ReviewAfterLessonsLearnedCommit = `$false
    MaxFixAttempts = 2
    InactivityTimeoutMinutes = 30
    AutoCommit = `$true
    CommitMessagePrefix = 'Reliability'
    HostGates = @()
    Roles = @{
        Reviewer = @{ Model = 'fake'; Thinking = 'high' }
        Architect = @{ Model = 'fake'; Thinking = 'high' }
        Fixer = @{ Model = 'fake'; Thinking = 'high' }
        Verifier = @{ Model = 'fake'; Thinking = 'low' }
    }
}
"@
    Set-Content -LiteralPath $Path -Value $content -Encoding UTF8
    return $Path
}

function New-ReliabilityFinding {
    return [pscustomobject]@{
        title = "reliability defect"
        description = "The cache misses a dependency."
        locations = @([pscustomobject]@{ path = "src/A.cs"; line = 10 })
    }
}

function Write-ReliabilityJsonArray {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Values
    )
    Set-Content -LiteralPath $Path -Value (ConvertTo-Json -InputObject @($Values) -Depth 30) -Encoding UTF8
}

Describe "Unattended reliability boundaries" {
    BeforeEach {
        $caseRoot = Join-Path $TestDrive ([Guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $caseRoot | Out-Null
        $repo = New-ReliabilityRepo -Path (Join-Path $caseRoot "repo")
        $logRoot = Join-Path $caseRoot "logs"
        $configPath = New-ReliabilityConfig -Path (Join-Path $caseRoot "profile.psd1") `
            -RepoPath $repo -LogRoot $logRoot
        $env:CODEX_REVIEW_LOOP_FAKE_LOG = Join-Path $caseRoot "calls.jsonl"
        $env:CODEX_REVIEW_LOOP_FAKE_RESULT = ""
        $env:CODEX_REVIEW_LOOP_FAKE_RESULT_SEQUENCE = ""
        $env:CODEX_REVIEW_LOOP_FAKE_INVOCATION_SEQUENCE = ""
        $env:CODEX_REVIEW_LOOP_FAKE_EXIT_CODE = ""
        $env:CODEX_REVIEW_LOOP_FAKE_STDERR = ""
        $env:CODEX_REVIEW_LOOP_FAKE_THREAD = "reliability-thread"
        $env:CODEX_REVIEW_LOOP_FAKE_COMMAND_EXIT_CODE = ""
        $env:CODEX_REVIEW_LOOP_FAKE_COMMAND_OUTPUT = ""
        $env:CODEX_REVIEW_LOOP_FAKE_NULL_USAGE = ""
        $env:CODEX_REVIEW_LOOP_FAKE_HANG_MS = ""
        $env:CODEX_REVIEW_LOOP_FAKE_MUTATE_ON_SCHEMA = ""
    }

    AfterEach {
        @(
            "CODEX_REVIEW_LOOP_FAKE_LOG",
            "CODEX_REVIEW_LOOP_FAKE_RESULT",
            "CODEX_REVIEW_LOOP_FAKE_RESULT_SEQUENCE",
            "CODEX_REVIEW_LOOP_FAKE_INVOCATION_SEQUENCE",
            "CODEX_REVIEW_LOOP_FAKE_EXIT_CODE",
            "CODEX_REVIEW_LOOP_FAKE_STDERR",
            "CODEX_REVIEW_LOOP_FAKE_THREAD",
            "CODEX_REVIEW_LOOP_FAKE_COMMAND_EXIT_CODE",
            "CODEX_REVIEW_LOOP_FAKE_COMMAND_OUTPUT",
            "CODEX_REVIEW_LOOP_FAKE_NULL_USAGE",
            "CODEX_REVIEW_LOOP_FAKE_HANG_MS",
            "CODEX_REVIEW_LOOP_FAKE_MUTATE_ON_SCHEMA"
        ) | ForEach-Object { Remove-Item "Env:\$_" -ErrorAction SilentlyContinue }
    }

    It "ignores personal config for exec and resume" {
        $calls = @(
            ,@(Get-CodexRoleArguments -RepoPath $repo -Model m -Thinking low)
            ,@(Get-CodexRoleArguments -RepoPath $repo -Model m -Thinking low -Mode Resume -ThreadId t)
        )
        foreach ($arguments in $calls) {
            @($arguments | Where-Object { $_ -eq "--ignore-user-config" }).Count | Should Be 1
            @($arguments | Where-Object { $_ -eq "--ignore-rules" }).Count | Should Be 1
            @($arguments | Where-Object { $_ -eq "--dangerously-bypass-approvals-and-sandbox" }).Count | Should Be 1
            @($arguments | Where-Object { $_ -eq "--sandbox" }).Count | Should Be 0
        }
    }

    It "ignores legacy per-role sandbox keys and keeps every role unattended" {
        $config = Import-PowerShellDataFile -LiteralPath $configPath
        $config.Roles.Reviewer.Sandbox = "read-only"
        $config.Roles.Fixer.Sandbox = "workspace-write"
        $module = Get-Module CodexReviewLoop
        & $module {
            param($profile, $repository, $logs, $fake)
            Invoke-ConfiguredCodexRole -Config $profile -Role Fixer -RepoPath $repository `
                -Speed standard -Prompt fix -LogRoot $logs -CodexPath $fake | Out-Null
            Invoke-ConfiguredCodexRole -Config $profile -Role Reviewer -RepoPath $repository `
                -Speed standard -Prompt "" -LogRoot $logs -CodexPath $fake `
                -Mode Review -ReviewBase HEAD | Out-Null
        } $config $repo $logRoot $fakeCodex

        $records = @(Get-Content -LiteralPath $env:CODEX_REVIEW_LOOP_FAKE_LOG |
            ForEach-Object { $_ | ConvertFrom-Json })
        (@($records[0].arguments) -contains "--dangerously-bypass-approvals-and-sandbox") | Should Be $true
        (@($records[1].arguments) -contains "--dangerously-bypass-approvals-and-sandbox") | Should Be $true
        @($records | Where-Object { @($_.arguments) -contains "--sandbox" }).Count | Should Be 0
    }

    It "rejects worktree changes made by an analysis role with full command access" {
        $config = Import-PowerShellDataFile -LiteralPath $configPath
        $env:CODEX_REVIEW_LOOP_FAKE_MUTATE_ON_SCHEMA = "architecture-advice-v2.schema.json"
        $message = ""
        try {
            & (Get-Module CodexReviewLoop) {
                param($profile, $repository, $logs, $fake)
                Invoke-ConfiguredCodexRole -Config $profile -Role Architect -RepoPath $repository `
                    -Speed standard -Prompt review -LogRoot $logs -CodexPath $fake `
                    -SchemaName "architecture-advice-v2.schema.json"
            } $config $repo $logRoot $fakeCodex | Out-Null
        }
        catch {
            $message = $_.Exception.Message
        }

        $message | Should Match "changed the repository worktree"
        (& git -C $repo status --porcelain=v1) | Should Not BeNullOrEmpty
    }

    It "contains no model command allowlist" {
        (Get-Content -Raw -LiteralPath (Join-Path $root "src\Cli.ps1")) |
            Should Not Match "Test-ReviewLoopModelOwnedTestCommand|command-policy violation"
    }

    It "removes inherited helper-program configuration from model processes" {
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.Environment["RIPGREP_CONFIG_PATH"] = "unsafe"
        $startInfo.Environment["GIT_EXTERNAL_DIFF"] = "unsafe"
        & (Get-Module CodexReviewLoop) {
            param($info)
            Clear-ReviewLoopModelHelperEnvironment -StartInfo $info
        } $startInfo

        $startInfo.Environment.ContainsKey("RIPGREP_CONFIG_PATH") | Should Be $false
        $startInfo.Environment.ContainsKey("GIT_EXTERNAL_DIFF") | Should Be $false
    }

    It "keeps a failed analysis command inside the successful Codex turn and out of compact output" {
        $planPath = Join-Path $caseRoot "invocations.json"
        Write-ReliabilityJsonArray -Path $planPath -Values @(
            [pscustomobject]@{
                threadId = "same-thread"
                commands = @([pscustomobject]@{
                    command = '"C:\Program Files\PowerShell\7\pwsh.exe" -Command "rg -n -F -e RequiredWatch tests\missing.cs"'
                    exitCode = 1
                    output = "rg: tests\missing.cs: file not found"
                })
            }
        )
        $env:CODEX_REVIEW_LOOP_FAKE_INVOCATION_SEQUENCE = $planPath
        $transcript = Join-Path $logRoot "terminal.log"
        & (Get-Module CodexReviewLoop) {
            param($path)
            Initialize-ReviewLoopConsole `
                -OutputMode compact -HeartbeatSeconds 0 -ColorMode Never -TranscriptPath $path
        } $transcript

        $call = Invoke-CodexCliRole -Role Test -RepoPath $repo -Model model -Thinking low `
            -Prompt p -LogRoot $logRoot -CodexPath $fakeCodex -MaxAttempts 2

        $call.Success | Should Be $true
        @($call.Attempts).Count | Should Be 1
        $records = @(Get-Content -LiteralPath $env:CODEX_REVIEW_LOOP_FAKE_LOG |
            ForEach-Object { $_ | ConvertFrom-Json })
        $records[0].callKind | Should Be "exec"
        $transcriptText = Get-Content -Raw -LiteralPath $transcript
        $transcriptText | Should Not Match "Agent command failed"
        $transcriptText | Should Not Match "tests\\missing.cs"
        (Get-Content -Raw -LiteralPath $call.JsonlPath) | Should Match "tests\\\\missing.cs"
        $allJsonLinesValid = $true
        foreach ($line in @(Get-Content -LiteralPath $call.JsonlPath | Where-Object { $_ })) {
            try {
                $line | ConvertFrom-Json | Out-Null
            }
            catch {
                $allJsonLinesValid = $false
            }
        }
        $allJsonLinesValid | Should Be $true
    }

    It "keeps a Codex policy decline out of compact output" {
        $planPath = Join-Path $caseRoot "invocations.json"
        Write-ReliabilityJsonArray -Path $planPath -Values @(
            [pscustomobject]@{
                threadId = "same-thread"
                commands = @([pscustomobject]@{
                    command = '"C:\Program Files\PowerShell\7\pwsh.exe" -Command "git blame -L 1,2 README.txt"'
                    exitCode = -1
                    status = "declined"
                    output = "rejected: blocked by policy"
                })
            }
        )
        $env:CODEX_REVIEW_LOOP_FAKE_INVOCATION_SEQUENCE = $planPath
        $transcript = Join-Path $logRoot "terminal.log"
        & (Get-Module CodexReviewLoop) {
            param($path)
            Initialize-ReviewLoopConsole `
                -OutputMode compact -HeartbeatSeconds 0 -ColorMode Never -TranscriptPath $path
        } $transcript

        $call = Invoke-CodexCliRole -Role Test -RepoPath $repo -Model model -Thinking low `
            -Prompt p -LogRoot $logRoot -CodexPath $fakeCodex -MaxAttempts 1

        $call.Success | Should Be $true
        $text = Get-Content -Raw -LiteralPath $transcript
        $text | Should Not Match "declined by Codex policy"
        (Get-Content -Raw -LiteralPath $call.JsonlPath) | Should Match '"status":"declined"'
    }

    It "allows model-owned tests to finish in the same turn" {
        $planPath = Join-Path $caseRoot "invocations.json"
        Write-ReliabilityJsonArray -Path $planPath -Values @(
            [pscustomobject]@{
                threadId = "policy-thread"
                commands = @([pscustomobject]@{
                    command = "dotnet test .\review-loop-test.proj"
                    exitCode = 0
                    output = "completed"
                })
            }
        )
        $env:CODEX_REVIEW_LOOP_FAKE_INVOCATION_SEQUENCE = $planPath

        $call = Invoke-CodexCliRole -Role Test -RepoPath $repo -Model model -Thinking low `
            -Prompt p -LogRoot $logRoot -CodexPath $fakeCodex -MaxAttempts 2

        $call.Success | Should Be $true
        @($call.Attempts).Count | Should Be 1
        $records = @(Get-Content -LiteralPath $env:CODEX_REVIEW_LOOP_FAKE_LOG |
            ForEach-Object { $_ | ConvertFrom-Json })
        $records[0].callKind | Should Be "exec"
        (Get-Content -Raw -LiteralPath $call.JsonlPath) |
            Should Match '"type":"item.completed".*"command":"dotnet test'
    }

    It "accepts rg no-match without retrying" {
        $planPath = Join-Path $caseRoot "invocations.json"
        Write-ReliabilityJsonArray -Path $planPath -Values @(
            [pscustomobject]@{
                commands = @([pscustomobject]@{ command = "rg -F missing ."; exitCode = 1; output = "" })
            }
        )
        $env:CODEX_REVIEW_LOOP_FAKE_INVOCATION_SEQUENCE = $planPath

        $call = Invoke-CodexCliRole -Role Test -RepoPath $repo -Model model -Thinking low `
            -Prompt p -LogRoot $logRoot -CodexPath $fakeCodex -MaxAttempts 1
        $call.Success | Should Be $true
        @($call.Attempts).Count | Should Be 1
    }

    It "counts redacted JSON error events without corrupting JSONL" {
        $planPath = Join-Path $caseRoot "invocations.json"
        Write-ReliabilityJsonArray -Path $planPath -Values @(
            [pscustomobject]@{
                rawEvents = @(
                    '{"type":"error","message":"authorization:plain-secret-value-123456","authorization":"json-secret-value-123456","nested":{"access_token":"nested-secret-value-123456"}}'
                )
                commands = @()
            }
        )
        $env:CODEX_REVIEW_LOOP_FAKE_INVOCATION_SEQUENCE = $planPath

        $call = Invoke-CodexCliRole -Role Test -RepoPath $repo -Model model -Thinking low `
            -Prompt p -LogRoot $logRoot -CodexPath $fakeCodex -MaxAttempts 1

        $call.Success | Should Be $true
        $call.FailureKind | Should Be "none"
        $jsonl = Get-Content -Raw -LiteralPath $call.JsonlPath
        $jsonl | Should Not Match "plain-secret-value-123456"
        $jsonl | Should Not Match "json-secret-value-123456"
        $jsonl | Should Not Match "nested-secret-value-123456"
        $jsonl | Should Match "authorization:\[redacted\]"
        $jsonl | Should Match '"authorization":"\[redacted\]"'
        $jsonl | Should Match '"access_token":"\[redacted\]"'
        $validJsonLines = $true
        foreach ($line in @($jsonl -split "\r?\n" | Where-Object { $_ })) {
            try {
                $line | ConvertFrom-Json | Out-Null
            }
            catch {
                $validJsonLines = $false
            }
        }
        $validJsonLines | Should Be $true
    }

    It "accepts malformed auxiliary events when the final result is valid" {
        $planPath = Join-Path $caseRoot "malformed-events.json"
        Write-ReliabilityJsonArray -Path $planPath -Values @(
            [pscustomobject]@{ rawEvents = @("not-json"); commands = @() }
        )
        $env:CODEX_REVIEW_LOOP_FAKE_INVOCATION_SEQUENCE = $planPath

        $call = Invoke-CodexCliRole -Role Test -RepoPath $repo -Model model -Thinking low `
            -Prompt p -LogRoot $logRoot -CodexPath $fakeCodex -MaxAttempts 1

        $call.Success | Should Be $true
        $call.FailureKind | Should Be "none"
    }

    It "rejects an explicit turn failure even when the process exits zero" {
        $planPath = Join-Path $caseRoot "turn-failed-events.json"
        Write-ReliabilityJsonArray -Path $planPath -Values @(
            [pscustomobject]@{
                rawEvents = @('{"type":"turn.failed","message":"turn failed"}')
                commands = @()
            }
        )
        $env:CODEX_REVIEW_LOOP_FAKE_INVOCATION_SEQUENCE = $planPath

        $call = Invoke-CodexCliRole -Role Test -RepoPath $repo -Model model -Thinking low `
            -Prompt p -LogRoot $logRoot -CodexPath $fakeCodex -MaxAttempts 1

        $call.Success | Should Be $false
        $call.FailureKind | Should Be "turn_failed"
    }

    It "redacts structured result files before returning or checkpointing them" {
        $secret = "result-secret-value-123456"
        $env:CODEX_REVIEW_LOOP_FAKE_RESULT = ConvertTo-Json -Compress -Depth 20 ([pscustomobject]@{
            schemaVersion = "2.0"
            summary = "advice"
            approach = "Inspect the result."
            steps = @("Apply the selected change.")
            considerations = @("authorization=$secret")
        })

        $call = Invoke-CodexCliRole -Role Test -RepoPath $repo -Model model -Thinking low `
            -Prompt p -LogRoot $logRoot -CodexPath $fakeCodex -MaxAttempts 1 `
            -SchemaPath (Join-Path $root "schemas\architecture-advice-v2.schema.json")

        $call.Success | Should Be $true
        (Get-Content -Raw -LiteralPath $call.ResultPath) | Should Not Match $secret
        [string]$call.StructuredResult.considerations[0] | Should Not Match $secret
    }

    It "deletes stale structured output and resumes after invalid JSON" {
        $resultPath = Join-Path $caseRoot "results.json"
        Write-ReliabilityJsonArray -Path $resultPath -Values @(
            "not json",
            '{"schemaVersion":"2.0","summary":"advice","approach":"Continue.","steps":[],"considerations":[]}'
        )
        $env:CODEX_REVIEW_LOOP_FAKE_RESULT_SEQUENCE = $resultPath

        $call = Invoke-CodexCliRole -Role Test -RepoPath $repo -Model model -Thinking low `
            -Prompt p -LogRoot $logRoot -CodexPath $fakeCodex -MaxAttempts 2 `
            -SchemaPath (Join-Path $root "schemas\architecture-advice-v2.schema.json")
        $call.Success | Should Be $true
        $call.StructuredResult.summary | Should Be "advice"
        $records = @(Get-Content -LiteralPath $env:CODEX_REVIEW_LOOP_FAKE_LOG |
            ForEach-Object { $_ | ConvertFrom-Json })
        $records[1].callKind | Should Be "resume"
    }

    It "terminates a timed-out role" {
        $planPath = Join-Path $caseRoot "invocations.json"
        $childPidPath = Join-Path $caseRoot "child.pid"
        Write-ReliabilityJsonArray -Path $planPath -Values @(
            [pscustomobject]@{
                hangMs = 10000
                commands = @()
                childPidPath = $childPidPath
                childSleepSeconds = 60
            }
        )
        $env:CODEX_REVIEW_LOOP_FAKE_INVOCATION_SEQUENCE = $planPath

        $call = Invoke-CodexCliRole -Role Test -RepoPath $repo -Model model -Thinking low `
            -Prompt p -LogRoot $logRoot -CodexPath $fakeCodex -MaxAttempts 1 -TimeoutSeconds 3
        $call.Success | Should Be $false
        $call.FailureKind | Should Be "timeout"
        $call.FailureReason | Should Match "inactive for 3s"
        $call.FailureReason | Should Match "after \d+s total"
        $call.FailureReason | Should Match "Logs:"
        Test-Path -LiteralPath $childPidPath | Should Be $true
        $childPid = [int](Get-Content -Raw -LiteralPath $childPidPath)
        Start-Sleep -Milliseconds 200
        $remainingChild = Get-Process -Id $childPid -ErrorAction SilentlyContinue
        try {
            $remainingChild | Should BeNullOrEmpty
        }
        finally {
            if ($null -ne $remainingChild) {
                Stop-Process -Id $childPid -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "allows a role to outlive the inactivity limit while output remains active" {
        $planPath = Join-Path $caseRoot "active-invocations.json"
        Write-ReliabilityJsonArray -Path $planPath -Values @(
            [pscustomobject]@{
                commands = @(
                    [pscustomobject]@{ delayMs = 1200; output = "first" }
                    [pscustomobject]@{ delayMs = 1200; output = "second" }
                )
            }
        )
        $env:CODEX_REVIEW_LOOP_FAKE_INVOCATION_SEQUENCE = $planPath

        $call = Invoke-CodexCliRole -Role Test -RepoPath $repo -Model model -Thinking low `
            -Prompt p -LogRoot $logRoot -CodexPath $fakeCodex -MaxAttempts 1 `
            -TimeoutSeconds 2

        $call.Success | Should Be $true
        ([DateTimeOffset]::Parse($call.FinishedAt) -
            [DateTimeOffset]::Parse($call.StartedAt)).TotalSeconds | Should BeGreaterThan 2
    }

    It "disables inactivity termination when the configured duration is zero" {
        $planPath = Join-Path $caseRoot "unbounded-invocations.json"
        Write-ReliabilityJsonArray -Path $planPath -Values @(
            [pscustomobject]@{ hangMs = 1500; commands = @() }
        )
        $env:CODEX_REVIEW_LOOP_FAKE_INVOCATION_SEQUENCE = $planPath

        $call = Invoke-CodexCliRole -Role Test -RepoPath $repo -Model model -Thinking low `
            -Prompt p -LogRoot $logRoot -CodexPath $fakeCodex -MaxAttempts 1 `
            -TimeoutSeconds 0

        $call.Success | Should Be $true
    }

    It "uses the process-scoped Windows system-awake flags without display or restart policy flags" {
        [CodexReviewLoopAwakeGuard]::RequiredFlags |
            Should Be ([CodexReviewLoopAwakeGuard]::EsContinuous -bor
                [CodexReviewLoopAwakeGuard]::EsSystemRequired)
        ([CodexReviewLoopAwakeGuard]::RequiredFlags -band 0x00000002) | Should Be 0

        $active = & (Get-Module CodexReviewLoop) { Start-ReviewLoopAwakeGuard }
        try {
            $active | Should Be $true
        }
        finally {
            & (Get-Module CodexReviewLoop) {
                param($wasActive)
                Stop-ReviewLoopAwakeGuard -WasActive $wasActive
            } $active
        }
    }

    It "does not retry a dirty fixer without a resumable thread" {
        $planPath = Join-Path $caseRoot "invocations.json"
        Write-ReliabilityJsonArray -Path $planPath -Values @(
            [pscustomobject]@{ emitThread = $false; commands = @() }
        )
        $env:CODEX_REVIEW_LOOP_FAKE_INVOCATION_SEQUENCE = $planPath
        $env:CODEX_REVIEW_LOOP_FAKE_RESULT = "not json"
        $env:CODEX_REVIEW_LOOP_FAKE_MUTATE_ON_SCHEMA = "fixer-result-v3.schema.json"

        $call = Invoke-CodexCliRole -Role Fixer -RepoPath $repo -Model model -Thinking high `
            -Prompt p -LogRoot $logRoot -CodexPath $fakeCodex `
            -MaxAttempts 2 -SchemaPath (Join-Path $root "schemas\fixer-result-v3.schema.json")

        $call.Success | Should Be $false
        $call.FailureKind | Should Be "unsafe_partial_mutation"
        @($call.Attempts).Count | Should Be 1
        (& git -C $repo status --porcelain=v1) | Should Not BeNullOrEmpty
    }

    It "reports unavailable usage without inventing token counts" {
        $transcript = Join-Path $caseRoot "terminal.log"
        $env:CODEX_REVIEW_LOOP_FAKE_NULL_USAGE = "true"
        $module = Get-Module CodexReviewLoop
        & $module {
            param($path)
            Initialize-ReviewLoopConsole -OutputMode compact -HeartbeatSeconds 0 -ColorMode Never -TranscriptPath $path
        } $transcript
        $call = Invoke-CodexCliRole -Role Test -RepoPath $repo -Model model -Thinking low `
            -Prompt p -LogRoot $logRoot -CodexPath $fakeCodex -MaxAttempts 1
        $call.Usage.InputTokens | Should Be 0
        (Get-Content -Raw -LiteralPath $transcript) | Should Match "usage not reported by CLI"
    }

    It "streams full logs while retaining only a bounded diagnostic tail" {
        $stdoutPath = Join-Path $caseRoot "large-output.txt"
        $stderrPath = Join-Path $caseRoot "large-output.stderr.txt"
        $command = '1..5000 | ForEach-Object { Write-Output ((''x'' * 200) + $_) }'
        $observed = & (Get-Module CodexReviewLoop) {
            param($output, $errors, $script)
            $pwsh = (Get-Command pwsh.exe -ErrorAction Stop | Select-Object -First 1).Source
            $startInfo = New-CodexProcessStartInfo -CodexExecutable $pwsh `
                -Arguments @("-NoLogo", "-NoProfile", "-NonInteractive", "-Command", $script)
            Invoke-ReviewLoopObservedProcess -StartInfo $startInfo -DisplayName "large output" `
                -StdoutPath $output -StderrPath $errors -EventKind HostGate -TimeoutSeconds 30
        } $stdoutPath $stderrPath $command

        $observed.ExitCode | Should Be 0
        $observed.Stdout.Length | Should BeLessThan 65537
        (Get-Item -LiteralPath $stdoutPath).Length | Should BeGreaterThan 500000
    }

    It "executes an arbitrary structured targeted test" {
        $pwsh = (Get-Command pwsh.exe -ErrorAction Stop | Select-Object -First 1).Source
        $fixer = [pscustomobject]@{
            targetedTest = [pscustomobject]@{
                executable = $pwsh
                arguments = @("-NoProfile", "-Command", "exit 0")
                rationale = "repository-specific regression wrapper"
            }
        }
        $module = Get-Module CodexReviewLoop
        $result = & $module {
            param($value, $repository, $logs)
            Invoke-ReviewLoopTargetedTests -FixerResult $value -RepoPath $repository `
                -RunRoot $logs -ClusterId custom -Attempt 1
        } $fixer $repo $logRoot
        $result.Success | Should Be $true
        $fixer.testExecution.Passed | Should Be $true
    }

    It "includes staged and untracked files in verifier evidence" {
        Set-Content -LiteralPath (Join-Path $repo "README.txt") -Value "tracked change"
        Set-Content -LiteralPath (Join-Path $repo "new.txt") -Value "untracked change"
        & git -C $repo add README.txt
        $patch = & (Get-Module CodexReviewLoop) {
            param($repository)
            Get-ReviewLoopWorktreePatch -RepoPath $repository
        } $repo
        $patch | Should Match "tracked change"
        $patch | Should Match "new.txt"
        $patch | Should Match "untracked change"
    }

    It "does not require reviewer-predicted fix paths" {
        (Get-Content -Raw -LiteralPath (Join-Path $root "src\Loop.ps1")) |
            Should Not Match "Assert-ReviewLoopFixScope|outside the active finding paths"
    }

    It "uses native Codex review without a prompt or schema and reuses its text checkpoint" {
        $config = Import-PowerShellDataFile -LiteralPath $configPath
        $runRoot = Join-Path $caseRoot "reviewer-run"
        New-Item -ItemType Directory -Path $runRoot | Out-Null
        $head = & git -C $repo rev-parse HEAD
        $state = New-ReviewLoopState -RepoPath $repo -ReviewBase HEAD -Speed standard `
            -RunRoot $runRoot -ReviewBaseCommit $head
        $state.ReviewCycle = 1
        $statePath = Join-Path $runRoot "run-v1.json"
        Write-ReviewLoopState -Path $statePath -State $state | Out-Null
        $ledger = New-ReviewLoopLedger -RepoPath $repo

        $review = & (Get-Module CodexReviewLoop) {
            param($profile, $loopState, $loopStatePath, $loopLedger, $repository, $logs, $fake)
            Invoke-ReviewLoopReview -Config $profile -State $loopState -StatePath $loopStatePath `
                -Ledger $loopLedger -RepoPath $repository -Speed standard -RunRoot $logs -CodexPath $fake
        } $config $state $statePath $ledger $repo $runRoot $fakeCodex

        $records = @(Get-Content -LiteralPath $env:CODEX_REVIEW_LOOP_FAKE_LOG |
            ForEach-Object { $_ | ConvertFrom-Json })
        $review.Result.clean | Should Be $true
        $review.Result.text | Should Be "No actionable findings."
        $records.Count | Should Be 1
        $records[0].callKind | Should Be "review"
        [string]$records[0].prompt | Should Be ""
        [string]$records[0].schemaPath | Should Be ""
        ($records[0].arguments -join " ") | Should Match "review --base HEAD"
        ($records[0].arguments -join " ") | Should Not Match "developer_instructions="

        $replayed = & (Get-Module CodexReviewLoop) {
            param($profile, $loopState, $loopStatePath, $loopLedger, $repository, $logs, $fake)
            Invoke-ReviewLoopReview -Config $profile -State $loopState -StatePath $loopStatePath `
                -Ledger $loopLedger -RepoPath $repository -Speed standard -RunRoot $logs -CodexPath $fake
        } $config $state $statePath $ledger $repo $runRoot $fakeCodex
        $replayed.Result.text | Should Be $review.Result.text
        @((Get-Content -LiteralPath $env:CODEX_REVIEW_LOOP_FAKE_LOG)).Count | Should Be 1
        @((Read-ReviewLoopState -Path $statePath).RoleCalls).Count | Should Be 1
    }

    It "uses ReviewerInstructions from the profile for native review" {
        $content = (Get-Content -Raw -LiteralPath $configPath).
            Replace("CleanPassesRequired = 2", "CleanPassesRequired = 1").
            Replace(
                "ReviewerInstructions = ''",
                "ReviewerInstructions = 'Profile review guidance'")
        Set-Content -LiteralPath $configPath -Value $content -Encoding UTF8

        $result = Invoke-CodexReviewLoop -RepoPath $repo -ConfigPath $configPath `
            -CodexPath $fakeCodex -HeartbeatSeconds 0 -ColorMode Never

        $result.Status | Should Be "completed"
        $reviewCall = @(Get-Content -LiteralPath $env:CODEX_REVIEW_LOOP_FAKE_LOG |
            ForEach-Object { $_ | ConvertFrom-Json } |
            Where-Object { $_.callKind -eq "review" })[0]
        @($reviewCall.arguments | Where-Object { $_ -like "developer_instructions=*" }) |
            Should Be @('developer_instructions="Profile review guidance"')
        [string]$reviewCall.prompt | Should Be ""
        [string]$reviewCall.schemaPath | Should Be ""
    }

    It "lets a CLI ReviewerInstructions value override the profile without checkpointing it" {
        $content = (Get-Content -Raw -LiteralPath $configPath).
            Replace("CleanPassesRequired = 2", "CleanPassesRequired = 1").
            Replace(
                "ReviewerInstructions = ''",
                "ReviewerInstructions = 'Profile review guidance'")
        Set-Content -LiteralPath $configPath -Value $content -Encoding UTF8
        $override = "CLI `"priority`"`nPrüfe Unicode 你好"
        $expected = "developer_instructions=$(ConvertTo-Json -InputObject $override -Compress)"

        $result = Invoke-CodexReviewLoop -RepoPath $repo -ConfigPath $configPath `
            -ReviewerInstructions $override -CodexPath $fakeCodex `
            -HeartbeatSeconds 0 -ColorMode Never

        $result.Status | Should Be "completed"
        $reviewCall = @(Get-Content -LiteralPath $env:CODEX_REVIEW_LOOP_FAKE_LOG |
            ForEach-Object { $_ | ConvertFrom-Json } |
            Where-Object { $_.callKind -eq "review" })[0]
        @($reviewCall.arguments | Where-Object { $_ -like "developer_instructions=*" }) |
            Should Be @($expected)
        (Get-Content -Raw -LiteralPath $result.StatePath) |
            Should Not Match "Prüfe Unicode"
        (Get-Content -Raw -LiteralPath (Join-Path $result.RunRoot "terminal.log")) |
            Should Not Match "Prüfe Unicode"
    }

    It "lets an explicitly empty CLI ReviewerInstructions value disable the profile" {
        $content = (Get-Content -Raw -LiteralPath $configPath).
            Replace("CleanPassesRequired = 2", "CleanPassesRequired = 1").
            Replace(
                "ReviewerInstructions = ''",
                "ReviewerInstructions = 'Profile review guidance'")
        Set-Content -LiteralPath $configPath -Value $content -Encoding UTF8

        $result = Invoke-CodexReviewLoop -RepoPath $repo -ConfigPath $configPath `
            -ReviewerInstructions "" -CodexPath $fakeCodex `
            -HeartbeatSeconds 0 -ColorMode Never

        $result.Status | Should Be "completed"
        $reviewCall = @(Get-Content -LiteralPath $env:CODEX_REVIEW_LOOP_FAKE_LOG |
            ForEach-Object { $_ | ConvertFrom-Json } |
            Where-Object { $_.callKind -eq "review" })[0]
        @($reviewCall.arguments | Where-Object { $_ -like "developer_instructions=*" }).Count |
            Should Be 0
    }

    It "restarts an interrupted native review without a custom prompt or schema" {
        $config = Import-PowerShellDataFile -LiteralPath $configPath
        $runRoot = Join-Path $caseRoot "role-resume-run"
        New-Item -ItemType Directory -Path $runRoot | Out-Null
        $head = & git -C $repo rev-parse HEAD
        $state = New-ReviewLoopState -RepoPath $repo -ReviewBase HEAD -Speed standard `
            -RunRoot $runRoot -ReviewBaseCommit $head
        $state.Stage = "reviewing"
        $snapshot = & (Get-Module CodexReviewLoop) {
            param($repository)
            Get-ReviewLoopRepositorySnapshot -RepoPath $repository
        } $repo
        $state.ActiveRoleCall = [pscustomobject]@{
            CallId = "review-01"
            Role = "Reviewer"
            ThreadId = "checkpointed-reviewer"
            ExecutionFingerprint = ""
            CheckpointStage = "reviewing"
            RepositoryHead = $snapshot.Head
            WorktreeFingerprint = $snapshot.Fingerprint
        }
        $statePath = Join-Path $runRoot "run-v1.json"
        Write-ReviewLoopState -Path $statePath -State $state | Out-Null

        $call = & (Get-Module CodexReviewLoop) {
            param($profile, $loopState, $loopStatePath, $repository, $logs, $fake)
            Invoke-ConfiguredCodexRole -Config $profile -Role Reviewer -RepoPath $repository `
                -Speed standard -Prompt "" -LogRoot $logs -Mode Review -ReviewBase HEAD `
                -CallId "review-01" `
                -State $loopState -StatePath $loopStatePath -CodexPath $fake
        } $config $state $statePath $repo $runRoot $fakeCodex

        $call.Success | Should Be $true
        $record = Get-Content -LiteralPath $env:CODEX_REVIEW_LOOP_FAKE_LOG | ConvertFrom-Json
        $record.callKind | Should Be "review"
        [string]$record.prompt | Should Be ""
        [string]$record.schemaPath | Should Be ""
        ($record.arguments -join " ") | Should Not Match "developer_instructions="
        (Read-ReviewLoopState -Path $statePath).ActiveRoleCall | Should BeNullOrEmpty
    }

    It "does not replay a completed fixer when the same attempt needs a technical correction" {
        $config = Import-PowerShellDataFile -LiteralPath $configPath
        $runRoot = Join-Path $caseRoot "fixer-correction-run"
        New-Item -ItemType Directory -Path $runRoot | Out-Null
        $state = New-ReviewLoopState -RepoPath $repo -ReviewBase HEAD -Speed standard `
            -RunRoot $runRoot
        $state.ActiveClusterId = "C-fixer-correction"
        $state.Stage = "fixing"
        $statePath = Join-Path $runRoot "run-v1.json"
        Write-ReviewLoopState -Path $statePath -State $state | Out-Null
        $fix = '{"schemaVersion":"3.0","summary":"corrected","targetedTest":{"available":false,"executable":"","arguments":[]}}'
        $env:CODEX_REVIEW_LOOP_FAKE_RESULT = $fix
        $finding = New-ReviewLoopLedger -RepoPath $repo
        Merge-ReviewLoopFindings -Ledger $finding -Findings @((New-ReliabilityFinding)) `
            -ReviewId r1 -Head (& git -C $repo rev-parse HEAD) | Out-Null

        $calls = & (Get-Module CodexReviewLoop) {
            param($profile, $loopState, $loopStatePath, $repository, $logs, $item, $fake)
            $first = Invoke-ReviewLoopFixer `
                -Config $profile -State $loopState -StatePath $loopStatePath `
                -RepoPath $repository -Speed standard -RunRoot $logs `
                -Findings @($item) -Strategy $null -Attempt 1 -CodexPath $fake
            $second = Invoke-ReviewLoopFixer `
                -Config $profile -State $loopState -StatePath $loopStatePath `
                -RepoPath $repository -Speed standard -RunRoot $logs `
                -Findings @($item) -Strategy $null -Attempt 1 -Correction 1 `
                -ThreadId $first.ThreadId -CodexPath $fake -Feedback "Correct the targeted test."
            return @($first, $second)
        } $config $state $statePath $repo $runRoot $finding.Findings[0] $fakeCodex

        @($calls).Count | Should Be 2
        $records = @((Read-ReviewLoopState -Path $statePath).RoleCalls)
        @($records).Count | Should Be 2
        $records[0].CallId | Should Be "C-fixer-correction-c0-fix-a1-c0"
        $records[1].CallId | Should Be "C-fixer-correction-c0-fix-a1-c1"
        @((Get-Content -LiteralPath $env:CODEX_REVIEW_LOOP_FAKE_LOG)).Count | Should Be 2
    }

    It "treats a targeted test that cannot start as a correction of the same attempt" {
        $runRoot = Join-Path $caseRoot "targeted-start-failure"
        New-Item -ItemType Directory -Path $runRoot | Out-Null
        $fixerResult = [pscustomobject]@{
            targetedTest = [pscustomobject]@{
                executable = ".\README.txt"
                arguments = @("ignored")
            }
        }

        $result = & (Get-Module CodexReviewLoop) {
            param($fix, $repository, $logs)
            Invoke-ReviewLoopTargetedTests `
                -FixerResult $fix -RepoPath $repository -RunRoot $logs `
                -ClusterId "C-start-failure" -Attempt 1
        } $fixerResult $repo $runRoot

        $result.Success | Should Be $false
        $result.Correctable | Should Be $true
        $result.Feedback | Should Match "Exit code -1"
    }

    It "keeps the worktree fingerprint stable when verified files are staged" {
        Set-Content -LiteralPath (Join-Path $repo "README.txt") -Value "tracked change"
        Set-Content -LiteralPath (Join-Path $repo "new.txt") -Value "untracked change"
        $module = Get-Module CodexReviewLoop
        $before = & $module {
            param($repository)
            Get-ReviewLoopWorktreeFingerprint -RepoPath $repository
        } $repo
        & git -C $repo add -A
        $after = & $module {
            param($repository)
            Get-ReviewLoopWorktreeFingerprint -RepoPath $repository
        } $repo
        $after | Should Be $before
    }

    It "builds a redacted structured commit message from accepted evidence" {
        $findings = @(
            [pscustomobject]@{
                Title = "first defect"
                Description = "The first path is inconsistent."
            },
            [pscustomobject]@{
                Title = "second defect"
                Description = "The second path is inconsistent."
            }
        )
        $verification = [pscustomobject]@{
            commitMessage = [pscustomobject]@{
                subject = "  Preserve`r`nconsistent behavior  "
                rationale = "Remove password=super-secret-value from the explanation."
                changes = @(
                    "Update the first path.",
                    "Update the first path.",
                    "Update`n the second path."
                )
            }
        }
        $fixer = [pscustomobject]@{
            summary = "Updated the affected behavior."
            testExecution = [pscustomobject]@{
                FilePath = "dotnet"
                Passed = $true
            }
        }
        $gates = @(
            [pscustomobject]@{ Name = "Solution tests"; Success = $true },
            [pscustomobject]@{ Name = "Solution tests"; Success = $true },
            [pscustomobject]@{ Name = "Skipped gate"; Success = $false }
        )

        $message = & (Get-Module CodexReviewLoop) {
            param($items, $fix, $decision, $checks)
            New-ReviewLoopCommitMessage `
                -Prefix "Reliability" -Findings $items -FixerResult $fix `
                -VerificationResult $decision -GateResults $checks
        } $findings $fixer $verification $gates

        $message | Should Match "^Reliability: Preserve consistent behavior"
        $message | Should Match "password=\[redacted\]"
        @($message -split "`n" | Where-Object {
            $_ -eq "- Update the first path."
        }).Count | Should Be 1
        $message | Should Match "Findings addressed:`n- first defect`n- second defect"
        $message | Should Match "Verified:`n- Targeted regression test`n- Solution tests"
        $message | Should Not Match "Skipped gate|super-secret-value|dotnet"
    }

    It "bounds commit-message content and falls back to fixer and finding text" {
        $longText = "x" * 5000
        $findings = @([pscustomobject]@{
            Title = "fallback finding"
            Description = ""
        })
        $fixer = [pscustomobject]@{
            summary = "Fallback fixer summary"
        }
        $verification = [pscustomobject]@{
            commitMessage = [pscustomobject]@{
                subject = ""
                rationale = $longText
                changes = @($longText)
            }
        }

        $message = & (Get-Module CodexReviewLoop) {
            param($items, $fix, $decision)
            New-ReviewLoopCommitMessage `
                -Prefix ("p" * 180) -Findings $items -FixerResult $fix `
                -VerificationResult $decision
        } $findings $fixer $verification

        ($message -split "`n")[0].Length | Should Be 200
        ($message -split "`n")[0] | Should Match "Fallback fixer"
        $message.Length | Should BeLessThan 4001
        $message | Should Match "Changes:"
        $message | Should Not Match "Verified:"
    }

    It "uses a sealed commit identity instead of re-decoding its message" {
        $preHead = & git -C $repo rev-parse HEAD
        Set-Content -LiteralPath (Join-Path $repo "README.txt") -Value "verified change"
        & git -C $repo add -A
        $tree = & git -C $repo write-tree
        & git -C $repo commit -q -m "Reliability: actual commit message"
        $commit = & git -C $repo rev-parse HEAD
        $pending = [pscustomobject]@{
            PreHead = $preHead
            ExpectedTree = $tree
            ExpectedCommit = $commit
            Message = "Reliability: text decoding must not decide this check"
        }

        $check = & (Get-Module CodexReviewLoop) {
            param($repository, $sealed)
            Get-ReviewLoopPendingCommitCheck -RepoPath $repository -Pending $sealed
        } $repo $pending

        $check.Matches | Should Be $true
        $check.CommitMatches | Should Be $true
        $check.MessageMatches | Should Be $false
        $check.MessageMatchRequired | Should Be $false
    }

    It "commits the structured message with authoritative gate evidence" {
        $config = Import-PowerShellDataFile -LiteralPath $configPath
        $config.HostGates = @(@{
            Name = "Solution tests"
            FilePath = "pwsh"
            Arguments = @("-NoProfile", "-Command", "exit 0")
        })
        $runRoot = Join-Path $caseRoot "structured-message-run"
        New-Item -ItemType Directory -Path $runRoot | Out-Null
        $statePath = Join-Path $runRoot "run-v1.json"
        $ledgerPath = Join-Path $caseRoot "structured-message-ledger.json"
        $head = & git -C $repo rev-parse HEAD
        Set-Content -LiteralPath (Join-Path $repo "README.txt") -Value "verified fix"

        $ledger = New-ReviewLoopLedger -RepoPath $repo
        Merge-ReviewLoopFindings -Ledger $ledger -Findings @((New-ReliabilityFinding)) `
            -ReviewId r1 -Head $head | Out-Null
        $finding = $ledger.Findings[0]
        $finding.Status = "fixing"
        Write-ReviewLoopLedger -Path $ledgerPath -Ledger $ledger | Out-Null
        $state = New-ReviewLoopState `
            -RepoPath $repo -ReviewBase HEAD -Speed standard -RunRoot $runRoot
        $state.CurrentHead = $head
        $state.ActiveClusterId = $finding.ClusterId
        $state.ActiveFindingIds = @($finding.Id)
        Write-ReviewLoopState -Path $statePath -State $state | Out-Null
        $snapshot = & (Get-Module CodexReviewLoop) {
            param($repository)
            Get-ReviewLoopRepositorySnapshot -RepoPath $repository
        } $repo
        $verification = [pscustomobject]@{
            Result = [pscustomobject]@{
                schemaVersion = "4.0"
                accept = $true
                summary = "Accepted."
                feedback = @()
                commitMessage = [pscustomobject]@{
                    subject = "Fix dependency-aware cache invalidation"
                    rationale = "Keep cached values aligned with their dependencies."
                    changes = @(
                        "Track the missing dependency.",
                        "Invalidate affected cache entries."
                    )
                }
            }
        }
        $fixer = [pscustomobject]@{
            summary = "Updated cache invalidation."
            testExecution = [pscustomobject]@{
                FilePath = "dotnet"
                Passed = $true
            }
        }

        $result = & (Get-Module CodexReviewLoop) {
            param($profile, $loopState, $loopStatePath, $loopLedger,
                $loopLedgerPath, $loopFinding, $decision, $fix,
                $repository, $logs, $expected)
            Complete-ReviewLoopFix `
                -Config $profile -State $loopState -StatePath $loopStatePath `
                -Ledger $loopLedger -LedgerPath $loopLedgerPath `
                -Findings @($loopFinding) -Verification $decision `
                -FixerResult $fix -RepoPath $repository -RunRoot $logs `
                -ExpectedSnapshot $expected
        } $config $state $statePath $ledger $ledgerPath $finding `
            $verification $fixer $repo $runRoot $snapshot

        $result.Success | Should Be $true
        $subject = & git -C $repo show -s --format=%s HEAD
        $message = (& git -C $repo show -s --format=%B HEAD | Out-String).Trim()
        $subject | Should Be "Reliability: Fix dependency-aware cache invalidation"
        $message | Should Match "Changes:`r?`n- Track the missing dependency\."
        $message | Should Match "Verified:`r?`n- Targeted regression test`r?`n- Solution tests"
        $message | Should Not Match "dotnet|-Command"
        (Read-ReviewLoopState -Path $statePath).PendingCommit |
            Should BeNullOrEmpty
        @((Read-ReviewLoopState -Path $statePath).LoopCommits) |
            Should Be @(& git -C $repo rev-parse HEAD)
    }

    It "stages verified work when AutoCommit is disabled and resumes after it is enabled" {
        $config = Import-PowerShellDataFile -LiteralPath $configPath
        $config.AutoCommit = $false
        $runRoot = Join-Path $caseRoot "manual-commit-run"
        New-Item -ItemType Directory -Path $runRoot | Out-Null
        $statePath = Join-Path $runRoot "run-v1.json"
        $ledgerPath = Join-Path $caseRoot "manual-commit-ledger.json"
        $preHead = & git -C $repo rev-parse HEAD
        Set-Content -LiteralPath (Join-Path $repo "README.txt") -Value "verified manual commit"
        $fingerprint = & (Get-Module CodexReviewLoop) {
            param($repository)
            Get-ReviewLoopWorktreeFingerprint -RepoPath $repository
        } $repo

        $ledger = New-ReviewLoopLedger -RepoPath $repo
        Merge-ReviewLoopFindings -Ledger $ledger -Findings @((New-ReliabilityFinding)) `
            -ReviewId r1 -Head $preHead | Out-Null
        $finding = $ledger.Findings[0]
        $finding.Status = "fixing"
        $finding.Verification = [pscustomobject]@{
            verdict = "resolved"
            patchSafety = "safe"
            confidence = "high"
        }
        Write-ReviewLoopLedger -Path $ledgerPath -Ledger $ledger | Out-Null

        $state = New-ReviewLoopState `
            -RepoPath $repo -ReviewBase HEAD -Speed standard -RunRoot $runRoot
        $state.CurrentHead = $preHead
        $state.ActiveClusterId = $finding.ClusterId
        $state.ActiveFindingIds = @($finding.Id)
        $state.PendingCommit = [pscustomobject]@{
            PreHead = $preHead
            PatchFingerprint = $fingerprint
            ExpectedTree = ""
            Message = "Reliability: verified manual commit`n`nKeep the staged tree intact.`n`nChanges:`n- update README"
            NeedsCurrentGates = $false
        }
        Write-ReviewLoopState -Path $statePath -State $state | Out-Null

        $failure = $null
        try {
            & (Get-Module CodexReviewLoop) {
                param($profile, $loopState, $loopStatePath, $loopLedger, $loopLedgerPath, $repository, $logs)
                Complete-ReviewLoopPendingCommit `
                    -Config $profile -State $loopState -StatePath $loopStatePath `
                    -Ledger $loopLedger -LedgerPath $loopLedgerPath `
                    -RepoPath $repository -RunRoot $logs
            } $config $state $statePath $ledger $ledgerPath $repo $runRoot | Out-Null
        }
        catch {
            $failure = $_
        }

        $failure | Should Not BeNullOrEmpty
        $failure.Exception.Data["ReviewLoopStatus"] | Should Be "failed"
        $failure.Exception.Message | Should Match "AutoCommit is disabled"
        @($failure.Exception.Data["ReviewLoopNextSteps"])[0] |
            Should Match ([regex]::Escape($statePath))
        (& git -C $repo rev-parse HEAD) | Should Be $preHead
        @(& git -C $repo diff --cached --name-only) | Should Be @("README.txt")
        (Read-ReviewLoopState -Path $statePath).Stage | Should Be "commit_pending"

        $config.AutoCommit = $true
        $config.CommitMessagePrefix = "Changed after preparation"
        $completed = & (Get-Module CodexReviewLoop) {
            param($profile, $loopState, $loopStatePath, $loopLedger, $loopLedgerPath, $repository, $logs)
            Complete-ReviewLoopPendingCommit `
                -Config $profile -State $loopState -StatePath $loopStatePath `
                -Ledger $loopLedger -LedgerPath $loopLedgerPath `
                -RepoPath $repository -RunRoot $logs
        } $config $state $statePath $ledger $ledgerPath $repo $runRoot

        $completed | Should Be $true
        (& git -C $repo rev-parse HEAD) | Should Not Be $preHead
        (& git -C $repo show -s --format=%s HEAD) |
            Should Be "Reliability: verified manual commit"
        ((& git -C $repo show -s --format=%B HEAD | Out-String).Trim()) |
            Should Match "Keep the staged tree intact"
        (& git -C $repo status --porcelain) | Should BeNullOrEmpty
        (Read-ReviewLoopLedger -Path $ledgerPath).Findings[0].Status | Should Be "resolved"
        @((Read-ReviewLoopState -Path $statePath).LoopCommits).Count | Should Be 1
    }

    It "recovers an already-created multiline commit from its sealed checkpoint" {
        $runRoot = Join-Path $caseRoot "multiline-crash-run"
        New-Item -ItemType Directory -Path $runRoot | Out-Null
        $statePath = Join-Path $runRoot "run-v1.json"
        $ledgerPath = Join-Path $caseRoot "multiline-crash-ledger.json"
        $preHead = & git -C $repo rev-parse HEAD
        Set-Content -LiteralPath (Join-Path $repo "README.txt") -Value "committed before crash"
        $fingerprint = & (Get-Module CodexReviewLoop) {
            param($repository)
            Get-ReviewLoopWorktreeFingerprint -RepoPath $repository
        } $repo
        & git -C $repo add -A
        $tree = & git -C $repo write-tree
        $message = @"
Reliability: recover a multiline commit

Preserve the exact accepted message across restart.

Changes:
- update README
"@.Trim()
        & git -C $repo -c commit.gpgsign=false commit -q -m $message
        $committedHead = & git -C $repo rev-parse HEAD

        $ledger = New-ReviewLoopLedger -RepoPath $repo
        Merge-ReviewLoopFindings -Ledger $ledger -Findings @((New-ReliabilityFinding)) `
            -ReviewId r1 -Head $preHead | Out-Null
        $finding = $ledger.Findings[0]
        $finding.Status = "fixing"
        $finding.Verification = [pscustomobject]@{
            schemaVersion = "4.0"
            accept = $true
            summary = "Accepted."
        }
        Write-ReviewLoopLedger -Path $ledgerPath -Ledger $ledger | Out-Null

        $state = New-ReviewLoopState `
            -RepoPath $repo -ReviewBase HEAD -Speed standard -RunRoot $runRoot
        $state.CurrentHead = $preHead
        $state.ActiveClusterId = $finding.ClusterId
        $state.ActiveFindingIds = @($finding.Id)
        $state.PendingCommit = [pscustomobject]@{
            PreHead = $preHead
            PatchFingerprint = $fingerprint
            ExpectedTree = $tree
            Message = $message
            NeedsCurrentGates = $false
        }
        Write-ReviewLoopState -Path $statePath -State $state | Out-Null

        $completed = & (Get-Module CodexReviewLoop) {
            param($loopState, $loopStatePath, $loopLedger, $loopLedgerPath,
                $repository, $logs)
            Complete-ReviewLoopPendingCommit `
                -Config @{ AutoCommit = $true; HostGates = @() } `
                -State $loopState -StatePath $loopStatePath `
                -Ledger $loopLedger -LedgerPath $loopLedgerPath `
                -RepoPath $repository -RunRoot $logs
        } $state $statePath $ledger $ledgerPath $repo $runRoot

        $completed | Should Be $true
        (& git -C $repo rev-parse HEAD) | Should Be $committedHead
        ((& git -C $repo show -s --format=%B HEAD | Out-String).Trim()).
            Replace("`r`n", "`n") |
            Should Be $message.Replace("`r`n", "`n")
        (Read-ReviewLoopLedger -Path $ledgerPath).Findings[0].Status |
            Should Be "resolved"
        @((Read-ReviewLoopState -Path $statePath).LoopCommits) |
            Should Be @($committedHead)
    }

    It "refuses a verified change that remains unstaged before advancing HEAD" {
        $preHead = & git -C $repo rev-parse HEAD
        Set-Content -LiteralPath (Join-Path $repo "README.txt") -Value "verified"
        $module = Get-Module CodexReviewLoop
        $fingerprint = & $module {
            param($repository)
            Get-ReviewLoopWorktreeFingerprint -RepoPath $repository
        } $repo
        & git -C $repo add -A
        $tree = & git -C $repo write-tree
        Set-Content -LiteralPath (Join-Path $repo "README.txt") -Value "changed after verification"

        $failure = $null
        try {
            & $module {
                param($repository, $head, $patch, $staged)
                Assert-ReviewLoopVerifiedWorktreeIsFullyStaged `
                    -RepoPath $repository -PreHead $head `
                    -PatchFingerprint $patch -StagedTree $staged
            } $repo $preHead $fingerprint $tree
        }
        catch {
            $failure = $_
        }

        $failure | Should Not BeNullOrEmpty
        $failure.Exception.Data["ReviewLoopStatus"] | Should Be "failed"
        $failure.Exception.Message | Should Match "cannot stage completely"
        (& git -C $repo rev-parse HEAD) | Should Be $preHead
        $tree | Should Not Be (& git -C $repo rev-parse "HEAD^{tree}")
    }

    It "verifies large patches from the worktree without an inline size limit" {
        $config = Import-PowerShellDataFile -LiteralPath $configPath
        Set-Content -LiteralPath (Join-Path $repo "oversized.txt") `
            -Value ([string]::new("x", 121000)) -NoNewline
        $runRoot = Join-Path $caseRoot "run"
        New-Item -ItemType Directory -Path $runRoot | Out-Null
        $state = New-ReviewLoopState -RepoPath $repo -ReviewBase HEAD -Speed standard -RunRoot $runRoot
        $state.ActiveClusterId = "oversized"
        $state.ActiveReviewText = "- large patch finding"
        $state.ActiveStrategy = [pscustomobject]@{
            schemaVersion = "2.0"
            summary = "Inspect it."
            approach = "Review the current worktree."
            steps = @()
            considerations = @()
        }
        $statePath = Join-Path $runRoot "run-v1.json"
        Write-ReviewLoopState -Path $statePath -State $state | Out-Null
        $fixerCall = [pscustomobject]@{
            CallId = "oversized-fixer"
            StructuredResult = [pscustomobject]@{
                schemaVersion = "2.0"
                summary = "Changed the implementation."
                targetedTest = [pscustomobject]@{
                    available = $false
                    executable = ""
                    arguments = @()
                }
            }
        }
        $result = '{"schemaVersion":"4.0","accept":false,"summary":"Still present.","feedback":["Inspect the current path."],"commitMessage":{"subject":"","rationale":"","changes":[]}}'
        $sequence = Join-Path $caseRoot "large-verifier-results.json"
        Write-ReliabilityJsonArray -Path $sequence -Values @($result)
        $env:CODEX_REVIEW_LOOP_FAKE_RESULT_SEQUENCE = $sequence
        $verification = & (Get-Module CodexReviewLoop) {
            param($profile, $loopState, $loopStatePath, $repository, $logs, $finding, $fixer, $fake)
            Invoke-ReviewLoopVerifier -Config $profile -State $loopState -StatePath $loopStatePath `
                -RepoPath $repository -Speed standard -RunRoot $logs -Findings @($finding) `
                -FixerCall $fixer -Attempt 1 -CodexPath $fake
        } $config $state $statePath $repo $runRoot (New-ReliabilityFinding) $fixerCall $fakeCodex
        $verification.Accepted | Should Be $false
        $verification.Result.summary | Should Be "Still present."
    }

    It "resolves an already-fixed finding without an empty commit" {
        $runRoot = Join-Path $caseRoot "run"
        New-Item -ItemType Directory -Path $runRoot | Out-Null
        $statePath = Join-Path $runRoot "run-v1.json"
        $ledgerPath = Join-Path $caseRoot "ledger-v1.json"
        $ledger = New-ReviewLoopLedger -RepoPath $repo
        Merge-ReviewLoopFindings -Ledger $ledger -Findings @((New-ReliabilityFinding)) `
            -ReviewId r1 -Head (& git -C $repo rev-parse HEAD) | Out-Null
        $finding = $ledger.Findings[0]
        $finding.Status = "fixing"
        Write-ReviewLoopLedger -Path $ledgerPath -Ledger $ledger | Out-Null
        $state = New-ReviewLoopState -RepoPath $repo -ReviewBase HEAD -Speed standard -RunRoot $runRoot
        $state.ActiveClusterId = $finding.ClusterId
        $state.ActiveFindingIds = @($finding.Id)
        Write-ReviewLoopState -Path $statePath -State $state | Out-Null
        $before = & git -C $repo rev-parse HEAD

        $result = & (Get-Module CodexReviewLoop) {
            param($loopState, $loopStatePath, $loopLedger, $loopLedgerPath, $loopFinding, $repository, $logs)
            Complete-ReviewLoopFix -Config @{ HostGates = @(); CommitMessagePrefix = "Reliability" } `
                -State $loopState -StatePath $loopStatePath -Ledger $loopLedger -LedgerPath $loopLedgerPath `
                -Findings @($loopFinding) -Verification ([pscustomobject]@{
                    Result = [pscustomobject]@{ verdict = "resolved"; confidence = "high" }
                }) -RepoPath $repository -RunRoot $logs `
                -ExpectedSnapshot (Get-ReviewLoopRepositorySnapshot -RepoPath $repository)
        } $state $statePath $ledger $ledgerPath $finding $repo $runRoot

        $result.Success | Should Be $true
        (& git -C $repo rev-parse HEAD) | Should Be $before
        (Read-ReviewLoopLedger -Path $ledgerPath).Findings[0].Status | Should Be "resolved"
    }

    It "completes a no-op lessons-learned resolution without counting a commit" {
        $runRoot = Join-Path $caseRoot "lessons-no-op-run"
        New-Item -ItemType Directory -Path $runRoot | Out-Null
        $statePath = Join-Path $runRoot "run-v1.json"
        $ledgerPath = Join-Path $caseRoot "lessons-no-op-ledger.json"
        $ledger = New-ReviewLoopLedger -RepoPath $repo
        Merge-ReviewLoopFindings -Ledger $ledger -Findings @((New-ReliabilityFinding)) `
            -ReviewId lessons-learned-01 -Head (& git -C $repo rev-parse HEAD) | Out-Null
        $finding = $ledger.Findings[0]
        $finding.Status = "fixing"
        Write-ReviewLoopLedger -Path $ledgerPath -Ledger $ledger | Out-Null
        $state = New-ReviewLoopState `
            -RepoPath $repo -ReviewBase HEAD -Speed standard -RunRoot $runRoot
        $state.ActiveFindingSource = "lessons_learned"
        $state.ActiveFindingIds = @($finding.Id)
        $state.LessonsLearned.Status = "implementing"
        $state.LessonsLearned.TriggerHead = [string]$state.CurrentHead
        $state.LessonsLearned.ReviewAfterCommit = $true
        Write-ReviewLoopState -Path $statePath -State $state | Out-Null
        $head = & git -C $repo rev-parse HEAD

        & (Get-Module CodexReviewLoop) {
            param($loopState, $loopStatePath, $loopLedger, $loopLedgerPath, $loopFinding, $commit)
            Complete-ReviewLoopResolution `
                -State $loopState -StatePath $loopStatePath `
                -Ledger $loopLedger -LedgerPath $loopLedgerPath `
                -Findings @($loopFinding) `
                -VerificationResult ([pscustomobject]@{ accept = $true }) `
                -Commit $commit
        } $state $statePath $ledger $ledgerPath $finding $head

        $reloaded = Read-ReviewLoopState -Path $statePath
        $reloaded.LessonsLearned.Status | Should Be "completed"
        $reloaded.LessonsLearned.CompletedHead | Should Be $head
        @($reloaded.LoopCommits).Count | Should Be 0
        $reloaded.ActiveFindingSource | Should Be ""
        $completion = & (Get-Module CodexReviewLoop) {
            param($loopState)
            Get-ReviewLoopLessonsLearnedFinalCompletion -State $loopState
        } $reloaded
        $completion.CompletionAllowed | Should Be $true
        $completion.Evidence | Should Match "without a commit"
    }

    It "resumes directly after a final lessons-learned commit by default" {
        $runRoot = Join-Path $caseRoot "lessons-final-resume-run"
        New-Item -ItemType Directory -Path $runRoot | Out-Null
        $statePath = Join-Path $runRoot "run-v1.json"
        $state = New-ReviewLoopState `
            -RepoPath $repo -ReviewBase HEAD -Speed standard -RunRoot $runRoot
        $triggerHead = [string]$state.CurrentHead
        Set-Content -LiteralPath (Join-Path $repo "AGENTS.md") `
            -Value "# Final guidance"
        & git -C $repo add AGENTS.md
        & git -C $repo commit -q -m "final lessons learned"
        $completedHead = & git -C $repo rev-parse HEAD
        $state.CurrentHead = $completedHead
        $state.Stage = "fix_committed"
        $state.LessonsLearned.Status = "completed"
        $state.LessonsLearned.TriggerHead = $triggerHead
        $state.LessonsLearned.CompletedHead = $completedHead
        $state.LessonsLearned.ReviewAfterCommit = $false
        Write-ReviewLoopState -Path $statePath -State $state | Out-Null

        $reloaded = Read-ReviewLoopState -Path $statePath
        $completion = & (Get-Module CodexReviewLoop) {
            param($loopState)
            Get-ReviewLoopLessonsLearnedFinalCompletion -State $loopState
        } $reloaded

        $completion.CompletionAllowed | Should Be $true
        $completion.Evidence | Should Match "final lessons-learned change verified"

        $reloaded.LessonsLearned.ReviewAfterCommit = $true
        $postReviewCompletion = & (Get-Module CodexReviewLoop) {
            param($loopState)
            Get-ReviewLoopLessonsLearnedFinalCompletion -State $loopState
        } $reloaded
        $postReviewCompletion.CompletionAllowed | Should Be $false
    }

    It "leaves lessons learned open when the fixer round returns to native review" {
        $runRoot = Join-Path $caseRoot "lessons-restart-run"
        New-Item -ItemType Directory -Path $runRoot | Out-Null
        $statePath = Join-Path $runRoot "run-v1.json"
        $ledgerPath = Join-Path $caseRoot "lessons-restart-ledger.json"
        $ledger = New-ReviewLoopLedger -RepoPath $repo
        Merge-ReviewLoopFindings -Ledger $ledger -Findings @((New-ReliabilityFinding)) `
            -ReviewId lessons-learned-01 -Head (& git -C $repo rev-parse HEAD) | Out-Null
        $finding = $ledger.Findings[0]
        $finding.Status = "fixing"
        $finding.FixAttempts = 1
        Write-ReviewLoopLedger -Path $ledgerPath -Ledger $ledger | Out-Null
        $state = New-ReviewLoopState `
            -RepoPath $repo -ReviewBase HEAD -Speed standard -RunRoot $runRoot
        $state.ActiveClusterId = $finding.ClusterId
        $state.ActiveFindingIds = @($finding.Id)
        $state.ActiveFindingSource = "lessons_learned"
        $state.LessonsLearned.Status = "implementing"
        Write-ReviewLoopState -Path $statePath -State $state | Out-Null

        & (Get-Module CodexReviewLoop) {
            param($loopState, $loopStatePath, $loopLedger, $loopLedgerPath, $loopFinding, $repository, $logs)
            Restart-ReviewLoopReviewRound `
                -State $loopState -StatePath $loopStatePath `
                -Ledger $loopLedger -LedgerPath $loopLedgerPath `
                -Findings @($loopFinding) -RepoPath $repository `
                -RunRoot $logs -Attempt 1 | Out-Null
        } $state $statePath $ledger $ledgerPath $finding $repo $runRoot

        $reloaded = Read-ReviewLoopState -Path $statePath
        $reloaded.LessonsLearned.Status | Should Be "pending"
        $reloaded.Stage | Should Be "review_round_requested"
        $reloaded.ActiveFindingSource | Should Be ""
        (Read-ReviewLoopLedger -Path $ledgerPath).Findings[0].Status | Should Be "open"
    }

    It "refuses changes created by a host gate" {
        Set-Content -LiteralPath (Join-Path $repo "README.txt") -Value "verified fix"
        $runRoot = Join-Path $caseRoot "run"
        New-Item -ItemType Directory -Path $runRoot | Out-Null
        $statePath = Join-Path $runRoot "run-v1.json"
        $ledgerPath = Join-Path $caseRoot "ledger-v1.json"
        $ledger = New-ReviewLoopLedger -RepoPath $repo
        Merge-ReviewLoopFindings -Ledger $ledger -Findings @((New-ReliabilityFinding)) `
            -ReviewId r1 -Head (& git -C $repo rev-parse HEAD) | Out-Null
        $finding = $ledger.Findings[0]
        $finding.Status = "fixing"
        Write-ReviewLoopLedger -Path $ledgerPath -Ledger $ledger | Out-Null
        $state = New-ReviewLoopState -RepoPath $repo -ReviewBase HEAD -Speed standard -RunRoot $runRoot
        $state.ActiveClusterId = $finding.ClusterId
        $state.ActiveFindingIds = @($finding.Id)
        Write-ReviewLoopState -Path $statePath -State $state | Out-Null
        $snapshot = & (Get-Module CodexReviewLoop) {
            param($repository)
            Get-ReviewLoopRepositorySnapshot -RepoPath $repository
        } $repo

        $failure = $null
        try {
            & (Get-Module CodexReviewLoop) {
            param($loopState, $loopStatePath, $loopLedger, $loopLedgerPath, $loopFinding, $repository, $logs, $expected)
            Complete-ReviewLoopFix -Config @{
                CommitMessagePrefix = "Reliability"
                HostGates = @(@{
                    Name = "mutating gate"
                    FilePath = "pwsh"
                    Arguments = @(
                        "-NoProfile",
                        "-Command",
                        "Set-Content -LiteralPath generated.txt -Value generated; exit 1"
                    )
                })
            } -State $loopState -StatePath $loopStatePath -Ledger $loopLedger -LedgerPath $loopLedgerPath `
                -Findings @($loopFinding) -Verification ([pscustomobject]@{
                    Result = [pscustomobject]@{ verdict = "resolved"; confidence = "high" }
                }) -RepoPath $repository -RunRoot $logs -ExpectedSnapshot $expected
            } $state $statePath $ledger $ledgerPath $finding $repo $runRoot $snapshot | Out-Null
        }
        catch {
            $failure = $_
        }

        $failure | Should Not BeNullOrEmpty
        $failure.Exception.Data["ReviewLoopStatus"] | Should Be "failed"
        $failure.Exception.Message | Should Match "host gate.*changed repository state"
        (& git -C $repo rev-list --count HEAD) | Should Be 1
    }

    It "does not treat an unrelated concurrent commit as the pending verified commit" {
        $runRoot = Join-Path $caseRoot "concurrent-commit-run"
        New-Item -ItemType Directory -Path $runRoot | Out-Null
        $statePath = Join-Path $runRoot "run-v1.json"
        $ledgerPath = Join-Path $caseRoot "concurrent-ledger-v1.json"
        $preHead = & git -C $repo rev-parse HEAD
        Set-Content -LiteralPath (Join-Path $repo "README.txt") -Value "verified change"
        $module = Get-Module CodexReviewLoop
        $verifiedFingerprint = & $module {
            param($repository)
            Get-ReviewLoopWorktreeFingerprint -RepoPath $repository
        } $repo
        & git -C $repo add -A
        $verifiedTree = & git -C $repo write-tree
        & git -C $repo reset --hard -q $preHead
        Set-Content -LiteralPath (Join-Path $repo "README.txt") -Value "external change"
        & git -C $repo add -A
        & git -C $repo commit -q -m "external commit"
        $externalHead = & git -C $repo rev-parse HEAD

        $ledger = New-ReviewLoopLedger -RepoPath $repo
        Merge-ReviewLoopFindings -Ledger $ledger -Findings @((New-ReliabilityFinding)) `
            -ReviewId r1 -Head $preHead | Out-Null
        $finding = $ledger.Findings[0]
        $finding.Status = "fixing"
        Write-ReviewLoopLedger -Path $ledgerPath -Ledger $ledger | Out-Null
        $state = New-ReviewLoopState -RepoPath $repo -ReviewBase HEAD -Speed standard -RunRoot $runRoot
        $state.CurrentHead = $preHead
        $state.ActiveClusterId = $finding.ClusterId
        $state.ActiveFindingIds = @($finding.Id)
        $state.PendingCommit = [pscustomobject]@{
            PreHead = $preHead
            PatchFingerprint = $verifiedFingerprint
            ExpectedTree = $verifiedTree
            Message = "Reliability: verified change"
            NeedsCurrentGates = $false
        }
        Write-ReviewLoopState -Path $statePath -State $state | Out-Null

        $failure = $null
        try {
            & $module {
                param($profile, $loopState, $loopStatePath, $loopLedger, $loopLedgerPath, $repository, $logs)
                Complete-ReviewLoopPendingCommit -Config $profile -State $loopState `
                    -StatePath $loopStatePath -Ledger $loopLedger -LedgerPath $loopLedgerPath `
                    -RepoPath $repository -RunRoot $logs
            } (Import-PowerShellDataFile -LiteralPath $configPath) $state $statePath `
                $ledger $ledgerPath $repo $runRoot | Out-Null
        }
        catch {
            $failure = $_
        }

        $failure | Should Not BeNullOrEmpty
        $failure.Exception.Message | Should Match "does not match the verified pending commit"
        $failure.Exception.Message | Should Match "tree expected .* but found"
        $failure.Exception.Message | Should Match "commit message differs from the sealed message"
        $failure.Exception.Message | Should Match "expected sha256 [0-9a-f]{64} length"
        (& git -C $repo rev-parse HEAD) | Should Be $externalHead
        (& git -C $repo show -s --format=%s HEAD) | Should Be "external commit"
    }

    It "reports the dirty paths when an otherwise valid pending commit is not clean" {
        $runRoot = Join-Path $caseRoot "dirty-pending-commit-run"
        New-Item -ItemType Directory -Path $runRoot | Out-Null
        $statePath = Join-Path $runRoot "run-v1.json"
        $ledgerPath = Join-Path $caseRoot "dirty-pending-commit-ledger.json"
        $preHead = & git -C $repo rev-parse HEAD
        Set-Content -LiteralPath (Join-Path $repo "README.txt") -Value "verified change"
        $module = Get-Module CodexReviewLoop
        $verifiedFingerprint = & $module {
            param($repository)
            Get-ReviewLoopWorktreeFingerprint -RepoPath $repository
        } $repo
        & git -C $repo add -A
        $verifiedTree = & git -C $repo write-tree
        $message = "Reliability: verified change"
        & git -C $repo commit -q -m $message
        $committedHead = & git -C $repo rev-parse HEAD
        Set-Content -LiteralPath (Join-Path $repo "unexpected.txt") -Value "late mutation"

        $ledger = New-ReviewLoopLedger -RepoPath $repo
        Merge-ReviewLoopFindings -Ledger $ledger -Findings @((New-ReliabilityFinding)) `
            -ReviewId r1 -Head $preHead | Out-Null
        $finding = $ledger.Findings[0]
        $finding.Status = "fixing"
        Write-ReviewLoopLedger -Path $ledgerPath -Ledger $ledger | Out-Null
        $state = New-ReviewLoopState -RepoPath $repo -ReviewBase HEAD -Speed standard -RunRoot $runRoot
        $state.CurrentHead = $preHead
        $state.ActiveClusterId = $finding.ClusterId
        $state.ActiveFindingIds = @($finding.Id)
        $state.PendingCommit = [pscustomobject]@{
            PreHead = $preHead
            PatchFingerprint = $verifiedFingerprint
            ExpectedTree = $verifiedTree
            Message = $message
            NeedsCurrentGates = $false
        }
        Write-ReviewLoopState -Path $statePath -State $state | Out-Null

        $failure = $null
        try {
            & $module {
                param($profile, $loopState, $loopStatePath, $loopLedger,
                    $loopLedgerPath, $repository, $logs)
                Complete-ReviewLoopPendingCommit `
                    -Config $profile -State $loopState -StatePath $loopStatePath `
                    -Ledger $loopLedger -LedgerPath $loopLedgerPath `
                    -RepoPath $repository -RunRoot $logs
            } (Import-PowerShellDataFile -LiteralPath $configPath) $state $statePath `
                $ledger $ledgerPath $repo $runRoot | Out-Null
        }
        catch {
            $failure = $_
        }

        $failure | Should Not BeNullOrEmpty
        $failure.Exception.Message |
            Should Match "worktree or index is not clean: \?\? unexpected\.txt"
        (& git -C $repo rev-parse HEAD) | Should Be $committedHead
    }

    It "fails technically when a targeted test mutates repository state" {
        $config = Import-PowerShellDataFile -LiteralPath $configPath
        Set-Content -LiteralPath (Join-Path $repo "README.txt") -Value "verified fix"
        Set-Content -LiteralPath (Join-Path $repo "review-loop-test.proj") -Value @'
<Project>
  <Target Name="VSTest">
    <WriteLinesToFile File="$(MSBuildProjectDirectory)\target-test-mutated.txt"
                      Lines="unexpected mutation"
                      Overwrite="true" />
    <Error Text="intentional targeted-test failure" />
  </Target>
</Project>
'@
        $runRoot = Join-Path $caseRoot "run"
        New-Item -ItemType Directory -Path $runRoot | Out-Null
        $statePath = Join-Path $runRoot "run-v1.json"
        $ledgerPath = Join-Path $caseRoot "ledger-v1.json"
        $ledger = New-ReviewLoopLedger -RepoPath $repo
        Merge-ReviewLoopFindings -Ledger $ledger -Findings @((New-ReliabilityFinding)) `
            -ReviewId r1 -Head (& git -C $repo rev-parse HEAD) | Out-Null
        $finding = $ledger.Findings[0]
        $finding.Status = "fixing"
        $finding.FixPaths = @($finding.FixPaths) + "README.txt"
        Write-ReviewLoopLedger -Path $ledgerPath -Ledger $ledger | Out-Null
        $state = New-ReviewLoopState -RepoPath $repo -ReviewBase HEAD -Speed standard -RunRoot $runRoot
        $state.ActiveClusterId = $finding.ClusterId
        $state.ActiveFindingIds = @($finding.Id)
        Write-ReviewLoopState -Path $statePath -State $state | Out-Null
        $fixerCall = [pscustomobject]@{
            Success = $true
            ThreadId = "fixer-thread"
            StructuredResult = [pscustomobject]@{
                schemaVersion = "1.0"
                outcome = "changed"
                summary = "candidate fix"
                changedPaths = @()
                targetedTest = [pscustomobject]@{
                    executable = "dotnet"
                    arguments = @("test", ".\review-loop-test.proj", "--no-restore", "--nologo")
                    rationale = "targeted regression"
                }
                remainingRisk = ""
            }
        }

        $failure = $null
        try {
            & (Get-Module CodexReviewLoop) {
                param(
                    $profile, $loopState, $loopStatePath, $loopLedger, $loopLedgerPath,
                    $loopFinding, $fixer, $repository, $logs
                )
                Invoke-ReviewLoopAttemptAssessment -Config $profile `
                    -State $loopState -StatePath $loopStatePath `
                    -Ledger $loopLedger -LedgerPath $loopLedgerPath `
                    -Findings @($loopFinding) -FixerCall $fixer -Attempt 1 `
                    -RepoPath $repository -Speed standard -RunRoot $logs
            } $config `
                $state $statePath $ledger $ledgerPath $finding $fixerCall $repo $runRoot | Out-Null
        }
        catch {
            $failure = $_
        }

        $failure | Should Not BeNullOrEmpty
        $failure.Exception.Data["ReviewLoopStatus"] | Should Be "failed"
        $failure.Exception.Message | Should Match "targeted test.*changed repository state"
        Test-Path -LiteralPath (Join-Path $repo "target-test-mutated.txt") | Should Be $true
        (& git -C $repo rev-list --count HEAD) | Should Be 1
    }

    It "recovers a commit made immediately before a crash" {
        $baseHead = & git -C $repo rev-parse HEAD
        $profileText = (Get-Content -LiteralPath $configPath -Raw).Replace(
            "ReviewBase = 'HEAD'",
            "ReviewBase = '$baseHead'")
        Set-Content -LiteralPath $configPath -Value $profileText -Encoding UTF8
        $config = Import-PowerShellDataFile -LiteralPath $configPath
        $paths = & (Get-Module CodexReviewLoop) {
            param($profile, $repository)
            New-ReviewLoopRunPaths -Config $profile -RepoPath $repository
        } $config $repo
        $paths.RunRoot = Join-Path $paths.ProfileRoot "99999999-commit-pending"
        New-Item -ItemType Directory -Path $paths.RunRoot -Force | Out-Null
        $statePath = Join-Path $paths.RunRoot "run-v1.json"
        $ledger = New-ReviewLoopLedger -RepoPath $repo
        Merge-ReviewLoopFindings -Ledger $ledger -Findings @((New-ReliabilityFinding)) `
            -ReviewId r1 -Head $baseHead | Out-Null
        $finding = $ledger.Findings[0]
        $finding.Status = "fixing"
        $verification = [pscustomobject]@{ verdict = "resolved"; confidence = "high" }
        $finding.Verification = $verification
        Write-ReviewLoopLedger -Path $paths.LedgerPath -Ledger $ledger | Out-Null
        $executionFingerprint = & (Get-Module CodexReviewLoop) {
            param($path)
            Get-ReviewLoopExecutionFingerprint -ConfigPath $path
        } $configPath
        $state = New-ReviewLoopState -RepoPath $repo -ReviewBase $baseHead -Speed standard `
            -RunRoot $paths.RunRoot -ReviewBaseCommit $baseHead `
            -ExecutionFingerprint $executionFingerprint
        $state.Status = "failed"
        $state.Stage = "commit_pending"
        $state.ActiveClusterId = $finding.ClusterId
        $state.ActiveFindingIds = @($finding.Id)

        Set-Content -LiteralPath (Join-Path $repo "fixed.txt") -Value "fixed"
        $fingerprint = & (Get-Module CodexReviewLoop) {
            param($repository)
            Get-ReviewLoopWorktreeFingerprint -RepoPath $repository
        } $repo
        & git -C $repo add -A
        $tree = & git -C $repo write-tree
        $message = "Reliability: reliability defect"
        & git -C $repo -c commit.gpgsign=false commit -q -m $message
        $committedHead = & git -C $repo rev-parse HEAD
        $state.PendingCommit = [pscustomobject]@{
            PreHead = $baseHead
            PatchFingerprint = $fingerprint
            ExpectedTree = $tree
            Message = $message
        }
        Write-ReviewLoopState -Path $statePath -State $state | Out-Null
        $resultSequence = Join-Path $caseRoot "results.json"
        Write-ReliabilityJsonArray -Path $resultSequence -Values @(
            '{"schemaVersion":"1.0","classification":"clean","summary":"clean","findings":[]}',
            '{"schemaVersion":"1.0","classification":"clean","summary":"clean","findings":[]}'
        )
        $env:CODEX_REVIEW_LOOP_FAKE_RESULT_SEQUENCE = $resultSequence

        $result = Invoke-CodexReviewLoop -RepoPath $repo -ConfigPath $configPath `
            -CodexPath $fakeCodex -HeartbeatSeconds 0 -ColorMode Never
        $result.Status | Should Be "completed"
        (& git -C $repo rev-parse HEAD) | Should Be $committedHead
        (& git -C $repo rev-list --count HEAD) | Should Be 2
        (Read-ReviewLoopLedger -Path $paths.LedgerPath).Findings[0].Status | Should Be "resolved"
    }

    It "invalidates a clean pass when a CLI ReviewerInstructions override is omitted" {
        $config = Import-PowerShellDataFile -LiteralPath $configPath
        $paths = & (Get-Module CodexReviewLoop) {
            param($profile, $repository)
            New-ReviewLoopRunPaths -Config $profile -RepoPath $repository
        } $config $repo
        $paths.RunRoot = Join-Path $paths.ProfileRoot "99999999-stale-clean-pass"
        New-Item -ItemType Directory -Path $paths.RunRoot -Force | Out-Null
        $statePath = Join-Path $paths.RunRoot "run-v1.json"
        $head = & git -C $repo rev-parse HEAD
        $previousFingerprint = & (Get-Module CodexReviewLoop) {
            param($path)
            Get-ReviewLoopExecutionFingerprint `
                -ConfigPath $path -ReviewerInstructions "previous CLI guidance"
        } $configPath
        $state = New-ReviewLoopState -RepoPath $repo -ReviewBase HEAD -Speed standard `
            -RunRoot $paths.RunRoot -ReviewBaseCommit $head `
            -ExecutionFingerprint $previousFingerprint
        $state.Stage = "clean_review"
        $state.ReviewCycle = 1
        $state.CleanPasses = 1
        $state.CleanHead = $head
        Write-ReviewLoopState -Path $statePath -State $state | Out-Null
        Write-ReviewLoopLedger -Path $paths.LedgerPath `
            -Ledger (New-ReviewLoopLedger -RepoPath $repo) | Out-Null
        $sequence = Join-Path $caseRoot "clean-results.json"
        Write-ReliabilityJsonArray -Path $sequence -Values @(
            '{"schemaVersion":"1.0","classification":"clean","summary":"clean","findings":[]}',
            '{"schemaVersion":"1.0","classification":"clean","summary":"clean","findings":[]}'
        )
        $env:CODEX_REVIEW_LOOP_FAKE_RESULT_SEQUENCE = $sequence

        $result = Invoke-CodexReviewLoop -RepoPath $repo -ConfigPath $configPath `
            -CodexPath $fakeCodex -HeartbeatSeconds 0 -ColorMode Never

        $result.Status | Should Be "completed"
        $result.CleanPasses | Should Be 2
        $result.ReviewCycles | Should Be 3
        $reviewCalls = @(Get-Content -LiteralPath $env:CODEX_REVIEW_LOOP_FAKE_LOG |
            ForEach-Object { $_ | ConvertFrom-Json } |
            Where-Object { $_.callKind -eq "review" })
        $reviewCalls.Count | Should Be 2
    }

    It "never resurrects an older failed run after a newer run completed" {
        $profileRoot = Join-Path $caseRoot "run-generations"
        $oldRoot = Join-Path $profileRoot "old"
        $newRoot = Join-Path $profileRoot "new"
        New-Item -ItemType Directory -Path $oldRoot, $newRoot -Force | Out-Null
        $old = New-ReviewLoopState -RepoPath $repo -ReviewBase HEAD -Speed standard `
            -RunRoot $oldRoot
        $old.Status = "failed"
        $old.Stage = "reviewing"
        $old.CreatedAt = "2026-01-01T00:00:00.0000000+00:00"
        Write-ReviewLoopState -Path (Join-Path $oldRoot "run-v1.json") -State $old | Out-Null
        $new = New-ReviewLoopState -RepoPath $repo -ReviewBase HEAD -Speed standard `
            -RunRoot $newRoot
        $new.Status = "completed"
        $new.Stage = "completed"
        $new.CreatedAt = "2026-01-02T00:00:00.0000000+00:00"
        Write-ReviewLoopState -Path (Join-Path $newRoot "run-v1.json") -State $new | Out-Null

        $selected = & (Get-Module CodexReviewLoop) {
            param($root)
            Get-ReviewLoopLatestActiveStatePath -ProfileRoot $root
        } $profileRoot

        $selected | Should BeNullOrEmpty
    }

    It "isolates ledgers by branch while keeping a moving review base stable" {
        $config = Import-PowerShellDataFile -LiteralPath $configPath
        $config.ReviewBase = "main"
        $module = Get-Module CodexReviewLoop
        $mainRoot = & $module {
            param($profile, $repository)
            (New-ReviewLoopRunPaths -Config $profile -RepoPath $repository `
                -ReviewBaseCommit ("a" * 40)).ProfileRoot
        } $config $repo
        $advancedBaseRoot = & $module {
            param($profile, $repository)
            (New-ReviewLoopRunPaths -Config $profile -RepoPath $repository `
                -ReviewBaseCommit ("b" * 40)).ProfileRoot
        } $config $repo
        $initialBranch = & git -C $repo branch --show-current
        & git -C $repo switch -q -c reliability-other
        try {
            $otherRoot = & $module {
                param($profile, $repository)
                (New-ReviewLoopRunPaths -Config $profile -RepoPath $repository `
                    -ReviewBaseCommit ("b" * 40)).ProfileRoot
            } $config $repo
        }
        finally {
            & git -C $repo switch -q $initialBranch
        }

        $advancedBaseRoot | Should Be $mainRoot
        $otherRoot | Should Not Be $mainRoot
    }

    It "does not resume an active checkpoint from a legacy run location" {
        $config = Import-PowerShellDataFile -LiteralPath $configPath
        $paths = & (Get-Module CodexReviewLoop) {
            param($profile, $repository)
            New-ReviewLoopRunPaths -Config $profile -RepoPath $repository
        } $config $repo
        $stableName = Split-Path -Leaf $paths.StableProfileRoot
        $legacyName = $stableName.Substring(0, $stableName.Length - 8) + "deadbeef"
        $legacyRoot = Join-Path (Split-Path -Parent $paths.StableProfileRoot) $legacyName
        $legacyRun = Join-Path $legacyRoot "99999999-legacy-active"
        New-Item -ItemType Directory -Path $legacyRun -Force | Out-Null
        $head = & git -C $repo rev-parse HEAD
        $legacyState = New-ReviewLoopState -RepoPath $repo -ReviewBase HEAD -Speed standard `
            -RunRoot $legacyRun -ReviewBaseCommit $head
        $legacyState.Status = "running"
        $legacyState.Stage = "reviewing"
        Write-ReviewLoopState -Path (Join-Path $legacyRun "run-v1.json") -State $legacyState | Out-Null
        $sequence = Join-Path $caseRoot "legacy-results.json"
        Write-ReliabilityJsonArray -Path $sequence -Values @(
            '{"schemaVersion":"1.0","classification":"clean","summary":"clean","findings":[]}',
            '{"schemaVersion":"1.0","classification":"clean","summary":"clean","findings":[]}'
        )
        $env:CODEX_REVIEW_LOOP_FAKE_RESULT_SEQUENCE = $sequence

        $result = Invoke-CodexReviewLoop -RepoPath $repo -ConfigPath $configPath `
            -CodexPath $fakeCodex -HeartbeatSeconds 0 -ColorMode Never

        $result.Status | Should Be "completed"
        $result.RunRoot | Should Not Be $legacyRun
        (Split-Path -Parent $result.RunRoot) | Should Be $paths.StableProfileRoot
        (Read-ReviewLoopState -Path (Join-Path $legacyRun "run-v1.json")).Status | Should Be "running"
    }

    It "imports legacy findings but clears interrupted execution state" {
        $config = Import-PowerShellDataFile -LiteralPath $configPath
        $initialPaths = & (Get-Module CodexReviewLoop) {
            param($profile, $repository)
            New-ReviewLoopRunPaths -Config $profile -RepoPath $repository
        } $config $repo
        $stableName = Split-Path -Leaf $initialPaths.StableProfileRoot
        $legacyName = $stableName.Substring(0, $stableName.Length - 8) + "cafebabe"
        $legacyRoot = Join-Path (Split-Path -Parent $initialPaths.StableProfileRoot) $legacyName
        $legacyRun = Join-Path $legacyRoot "99999999-legacy-fixing"
        New-Item -ItemType Directory -Path $legacyRun -Force | Out-Null
        $head = & git -C $repo rev-parse HEAD
        $legacyState = New-ReviewLoopState -RepoPath $repo -ReviewBase HEAD -Speed standard `
            -RunRoot $legacyRun -ReviewBaseCommit $head
        Write-ReviewLoopState -Path (Join-Path $legacyRun "run-v1.json") -State $legacyState | Out-Null
        $legacyLedger = New-ReviewLoopLedger -RepoPath $repo
        Merge-ReviewLoopFindings -Ledger $legacyLedger -Findings @((New-ReliabilityFinding)) `
            -ReviewId legacy -Head $head | Out-Null
        $legacyFinding = $legacyLedger.Findings[0]
        $legacyFinding.Status = "fixing"
        $legacyFinding.FixAttempts = 2
        $legacyFinding.FixerThreadId = "stale-thread"
        $legacyFinding.BlockedReason = "interrupted"
        Write-ReviewLoopLedger -Path (Join-Path $legacyRoot "ledger-v1.json") `
            -Ledger $legacyLedger | Out-Null
        $paths = & (Get-Module CodexReviewLoop) {
            param($profile, $repository)
            New-ReviewLoopRunPaths -Config $profile -RepoPath $repository
        } $config $repo

        & (Get-Module CodexReviewLoop) {
            param($candidatePaths, $repository, $branch)
            Import-ReviewLoopLegacyLedgers -Paths $candidatePaths -RepoPath $repository `
                -Branch $branch -ReviewBase HEAD
        } $paths $repo (& git -C $repo branch --show-current)
        $imported = Read-ReviewLoopLedger -Path $paths.LedgerPath -RepoPath $repo

        @($imported.Findings).Count | Should Be 1
        $imported.Findings[0].Status | Should Be "open"
        $imported.Findings[0].FixAttempts | Should Be 0
        $imported.Findings[0].FixerThreadId | Should BeNullOrEmpty
        $imported.Findings[0].BlockedReason | Should BeNullOrEmpty
    }

    It "preserves and restores tracked binary staged deleted and untracked fixer changes" {
        Set-Content -LiteralPath (Join-Path $repo "delete.txt") -Value "delete me"
        [System.IO.File]::WriteAllBytes(
            (Join-Path $repo "binary.bin"),
            [byte[]](0, 1, 2, 3, 255))
        & git -C $repo add delete.txt binary.bin
        & git -C $repo commit -q -m "add artifact fixtures"
        $head = & git -C $repo rev-parse HEAD

        Set-Content -LiteralPath (Join-Path $repo "README.txt") -Value "unstaged change"
        Set-Content -LiteralPath (Join-Path $repo "review-loop-test.proj") -Value "staged change"
        & git -C $repo add review-loop-test.proj
        Remove-Item -LiteralPath (Join-Path $repo "delete.txt")
        & git -C $repo add -u -- delete.txt
        [System.IO.File]::WriteAllBytes(
            (Join-Path $repo "binary.bin"),
            [byte[]](255, 3, 2, 1, 0, 42))
        $untrackedPath = Join-Path $repo "new\untracked.bin"
        New-Item -ItemType Directory -Path (Split-Path -Parent $untrackedPath) | Out-Null
        [System.IO.File]::WriteAllBytes($untrackedPath, [byte[]](9, 8, 7, 6))

        $runRoot = Join-Path $caseRoot "artifact-run"
        New-Item -ItemType Directory -Path $runRoot | Out-Null
        $state = New-ReviewLoopState `
            -RepoPath $repo -ReviewBase HEAD -Speed standard -RunRoot $runRoot
        $state.CurrentHead = $head
        $snapshot = & (Get-Module CodexReviewLoop) {
            param($repository)
            Get-ReviewLoopRepositorySnapshot -RepoPath $repository
        } $repo
        $state.LastFixerResult = [pscustomobject]@{
            WorktreeFingerprint = [string]$snapshot.Fingerprint
        }
        $artifact = & (Get-Module CodexReviewLoop) {
            param($runState, $repository, $rootPath)
            Get-ReviewLoopBlockedArtifact `
                -State $runState -RepoPath $repository -RunRoot $rootPath `
                -ClusterId "C-artifact" -Attempt 2
        } $state $repo $runRoot
        $manifest = Get-Content -Raw -LiteralPath $artifact.ManifestPath | ConvertFrom-Json

        & (Get-Module CodexReviewLoop) {
            param($repository, $cleanup)
            Restore-ReviewLoopBlockedWorktree -RepoPath $repository -Cleanup $cleanup
        } $repo $artifact

        (& git -C $repo status --porcelain | Out-String).Trim() | Should Be ""
        Test-Path -LiteralPath (Join-Path $artifact.ArtifactRoot "tracked.patch") | Should Be $true
        Test-Path -LiteralPath (
            Join-Path $artifact.ArtifactRoot "untracked\new\untracked.bin"
        ) | Should Be $true
        @($manifest.Tracked).Count | Should Be 4
        @($manifest.Untracked).Count | Should Be 1
        $trackedTypes = @($manifest.Tracked | ForEach-Object { [string]$_.FileType })
        ($trackedTypes -contains "tracked_deletion") | Should Be $true
        $manifest.Untracked[0].FileType | Should Be "untracked_file"

        & git -C $repo apply (Join-Path $artifact.ArtifactRoot "tracked.patch")
        New-Item -ItemType Directory -Path (Split-Path -Parent $untrackedPath) -Force | Out-Null
        [System.IO.File]::Copy(
            (Join-Path $artifact.ArtifactRoot "untracked\new\untracked.bin"),
            $untrackedPath,
            $true)
        $reconstructed = & (Get-Module CodexReviewLoop) {
            param($repository)
            Get-ReviewLoopWorktreeFingerprint -RepoPath $repository
        } $repo
        $reconstructed | Should Be ([string]$manifest.WorktreeFingerprint)
    }

    It "resumes an interrupted partial blocked-patch cleanup idempotently" {
        Set-Content -LiteralPath (Join-Path $repo "README.txt") -Value "first change"
        Set-Content -LiteralPath (Join-Path $repo "review-loop-test.proj") -Value "second change"
        Set-Content -LiteralPath (Join-Path $repo "untracked.txt") -Value "third change"
        $runRoot = Join-Path $caseRoot "partial-cleanup"
        New-Item -ItemType Directory -Path $runRoot | Out-Null
        $statePath = Join-Path $runRoot "run-v1.json"
        $ledgerPath = Join-Path $runRoot "ledger-v2.json"
        $ledger = New-ReviewLoopLedger -RepoPath $repo
        Merge-ReviewLoopFindings `
            -Ledger $ledger -Findings @((New-ReliabilityFinding)) `
            -ReviewId r1 -Head (& git -C $repo rev-parse HEAD) | Out-Null
        $finding = $ledger.Findings[0]
        $finding.Status = "fixing"
        Write-ReviewLoopLedger -Path $ledgerPath -Ledger $ledger | Out-Null
        $state = New-ReviewLoopState `
            -RepoPath $repo -ReviewBase HEAD -Speed standard -RunRoot $runRoot
        $state.ActiveClusterId = $finding.ClusterId
        $state.ActiveFindingIds = @($finding.Id)
        $snapshot = & (Get-Module CodexReviewLoop) {
            param($repository)
            Get-ReviewLoopRepositorySnapshot -RepoPath $repository
        } $repo
        $state.LastFixerResult = [pscustomobject]@{
            WorktreeFingerprint = [string]$snapshot.Fingerprint
        }
        $artifact = & (Get-Module CodexReviewLoop) {
            param($runState, $repository, $rootPath)
            Get-ReviewLoopBlockedArtifact `
                -State $runState -RepoPath $repository -RunRoot $rootPath `
                -ClusterId ([string]$runState.ActiveClusterId) -Attempt 2
        } $state $repo $runRoot
        $artifact | Add-Member -Force -NotePropertyName Reason `
            -NotePropertyValue "Finding cluster remained open after 2 fix attempts."
        $artifact | Add-Member -Force -NotePropertyName FindingIds `
            -NotePropertyValue @($finding.Id)
        $state.BlockedCleanup = $artifact
        $state.Stage = "blocked_patch_captured"
        Write-ReviewLoopState -Path $statePath -State $state | Out-Null

        & git -C $repo restore --source=HEAD --staged --worktree -- README.txt
        & (Get-Module CodexReviewLoop) {
            param($runState, $checkpoint, $currentLedger, $ledgerFile, $repository, $rootPath)
            Resume-ReviewLoopBlockedCleanup `
                -State $runState -StatePath $checkpoint `
                -Ledger $currentLedger -LedgerPath $ledgerFile `
                -RepoPath $repository -RunRoot $rootPath
        } $state $statePath $ledger $ledgerPath $repo $runRoot | Should Be $true

        (& git -C $repo status --porcelain | Out-String).Trim() | Should Be ""
        $state.Stage | Should Be "cluster_blocked"
        $state.ActiveFindingIds.Count | Should Be 0
        $updated = Read-ReviewLoopLedger -Path $ledgerPath
        $updated.Findings[0].Status | Should Be "blocked"
        Test-Path -LiteralPath $updated.Findings[0].BlockedArtifactRoot | Should Be $true
    }

    It "leaves every file untouched when an unexpected path appears before cleanup" {
        Set-Content -LiteralPath (Join-Path $repo "README.txt") -Value "fixer change"
        $runRoot = Join-Path $caseRoot "unsafe-cleanup"
        New-Item -ItemType Directory -Path $runRoot | Out-Null
        $state = New-ReviewLoopState `
            -RepoPath $repo -ReviewBase HEAD -Speed standard -RunRoot $runRoot
        $snapshot = & (Get-Module CodexReviewLoop) {
            param($repository)
            Get-ReviewLoopRepositorySnapshot -RepoPath $repository
        } $repo
        $state.LastFixerResult = [pscustomobject]@{
            WorktreeFingerprint = [string]$snapshot.Fingerprint
        }
        $artifact = & (Get-Module CodexReviewLoop) {
            param($runState, $repository, $rootPath)
            Get-ReviewLoopBlockedArtifact `
                -State $runState -RepoPath $repository -RunRoot $rootPath `
                -ClusterId "C-unsafe" -Attempt 2
        } $state $repo $runRoot
        Set-Content -LiteralPath (Join-Path $repo "unexpected.txt") -Value "concurrent"

        $failure = $null
        try {
            & (Get-Module CodexReviewLoop) {
                param($repository, $cleanup)
                Restore-ReviewLoopBlockedWorktree -RepoPath $repository -Cleanup $cleanup
            } $repo $artifact
        }
        catch {
            $failure = $_
        }

        $failure | Should Not BeNullOrEmpty
        $failure.Exception.Message | Should Match "Unexpected path"
        (Get-Content -Raw -LiteralPath (Join-Path $repo "README.txt")) |
            Should Match "fixer change"
        Test-Path -LiteralPath (Join-Path $repo "unexpected.txt") | Should Be $true
    }

    It "does not clean the worktree when a blocked artifact fails integrity checks" {
        Set-Content -LiteralPath (Join-Path $repo "README.txt") -Value "fixer change"
        $runRoot = Join-Path $caseRoot "damaged-artifact"
        New-Item -ItemType Directory -Path $runRoot | Out-Null
        $state = New-ReviewLoopState `
            -RepoPath $repo -ReviewBase HEAD -Speed standard -RunRoot $runRoot
        $snapshot = & (Get-Module CodexReviewLoop) {
            param($repository)
            Get-ReviewLoopRepositorySnapshot -RepoPath $repository
        } $repo
        $state.LastFixerResult = [pscustomobject]@{
            WorktreeFingerprint = [string]$snapshot.Fingerprint
        }
        $artifact = & (Get-Module CodexReviewLoop) {
            param($runState, $repository, $rootPath)
            Get-ReviewLoopBlockedArtifact `
                -State $runState -RepoPath $repository -RunRoot $rootPath `
                -ClusterId "C-damaged" -Attempt 2
        } $state $repo $runRoot
        Set-Content -LiteralPath (
            Join-Path $artifact.ArtifactRoot "tracked.patch"
        ) -Value "damaged"

        $failure = $null
        try {
            & (Get-Module CodexReviewLoop) {
                param($repository, $cleanup)
                Restore-ReviewLoopBlockedWorktree -RepoPath $repository -Cleanup $cleanup
            } $repo $artifact
        }
        catch {
            $failure = $_
        }

        $failure | Should Not BeNullOrEmpty
        $failure.Exception.Message | Should Match "integrity check"
        (Get-Content -Raw -LiteralPath (Join-Path $repo "README.txt")) |
            Should Match "fixer change"
    }

    It "rejects submodule entries without changing the index" {
        $head = (& git -C $repo rev-parse HEAD | Out-String).Trim()
        & git -C $repo update-index --add --cacheinfo 160000 $head dependency
        $LASTEXITCODE | Should Be 0
        (& git -C $repo diff --cached --name-only | Out-String) | Should Match "dependency"
        $runRoot = Join-Path $caseRoot "submodule-artifact"
        New-Item -ItemType Directory -Path $runRoot | Out-Null
        $state = New-ReviewLoopState `
            -RepoPath $repo -ReviewBase HEAD -Speed standard -RunRoot $runRoot
        $snapshot = & (Get-Module CodexReviewLoop) {
            param($repository)
            Get-ReviewLoopRepositorySnapshot -RepoPath $repository
        } $repo
        $state.LastFixerResult = [pscustomobject]@{
            WorktreeFingerprint = [string]$snapshot.Fingerprint
        }

        $failure = $null
        try {
            & (Get-Module CodexReviewLoop) {
                param($runState, $repository, $rootPath)
                Get-ReviewLoopBlockedArtifact `
                    -State $runState -RepoPath $repository -RunRoot $rootPath `
                    -ClusterId "C-submodule" -Attempt 2
            } $state $repo $runRoot | Out-Null
        }
        catch {
            $failure = $_
        }

        $failure | Should Not BeNullOrEmpty
        $failure.Exception.Message | Should Match "submodule"
        (& git -C $repo diff --cached --name-only | Out-String) | Should Match "dependency"
    }

    It "rejects a reparse point in an untracked file path" {
        $target = Join-Path $caseRoot "junction-target"
        New-Item -ItemType Directory -Path $target | Out-Null
        Set-Content -LiteralPath (Join-Path $target "fix.txt") -Value "external"
        New-Item -ItemType Junction -Path (Join-Path $repo "linked") -Target $target | Out-Null

        $failure = $null
        try {
            & (Get-Module CodexReviewLoop) {
                param($repository)
                Assert-ReviewLoopPathWithoutReparsePoints `
                    -RootPath $repository `
                    -RelativePath "linked/fix.txt" `
                    -Description "Automatic blocked-patch cleanup"
            } $repo | Out-Null
        }
        catch {
            $failure = $_
        }

        $failure | Should Not BeNullOrEmpty
        $failure.Exception.Message | Should Match "reparse point"
        (Get-Content -Raw -LiteralPath (Join-Path $target "fix.txt")) |
            Should Match "external"
        Remove-Item -LiteralPath (Join-Path $repo "linked") -Force
    }

    It "uses an exclusive repository lock" {
        $lockPath = & (Get-Module CodexReviewLoop) {
            param($repository)
            $path = Get-ReviewLoopGitValue -RepoPath $repository -Arguments @(
                "rev-parse", "--git-path", "codex-review-loop.lock"
            )
            if ([System.IO.Path]::IsPathRooted($path)) { return $path }
            return Join-Path $repository $path
        } $repo
        $lock = [System.IO.FileStream]::new(
            $lockPath,
            [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None)
        try {
            $result = Invoke-CodexReviewLoop -RepoPath $repo -ConfigPath $configPath `
                -CodexPath $fakeCodex -NewRun -ColorMode Never
            $result.Status | Should Be "failed"
            $result.Reason | Should Match "already running"
            ($result.NextSteps -join "`n") | Should Match "Let the existing loop finish"
            ($result.NextSteps -join "`n") | Should Match "Do not delete the lock"
        }
        finally {
            $lock.Dispose()
        }
    }

}
