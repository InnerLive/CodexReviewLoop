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
    LogRoot = '$literalLog'
    CleanPassesRequired = 2
    MaxReviewCycles = 6
    MaxFixAttempts = 2
    MaxArchitectureRevisions = 1
    AutoCommit = `$true
    CommitMessagePrefix = 'Reliability'
    HostGates = @()
    Roles = @{
        Reviewer = @{ Model = 'fake'; Thinking = 'high' }
        TriggerJudge = @{ Model = 'fake'; Thinking = 'low' }
        TriggerConfirm = @{ Model = 'fake'; Thinking = 'low' }
        TriggerTieBreak = @{ Model = 'fake'; Thinking = 'medium' }
        Architect = @{ Model = 'fake'; Thinking = 'max' }
        ArchitectureCritic = @{ Model = 'fake'; Thinking = 'medium' }
        ArchitectureVeto = @{ Model = 'fake'; Thinking = 'medium' }
        ArchitectureTieBreak = @{ Model = 'fake'; Thinking = 'high' }
        PointFixer = @{ Model = 'fake'; Thinking = 'high' }
        ArchitectureFixer = @{ Model = 'fake'; Thinking = 'max' }
        FindingVerifier = @{ Model = 'fake'; Thinking = 'low' }
        VerifierConfirm = @{ Model = 'fake'; Thinking = 'low' }
        VerifierTieBreak = @{ Model = 'fake'; Thinking = 'medium' }
    }
}
"@
    Set-Content -LiteralPath $Path -Value $content -Encoding UTF8
    return $Path
}

function New-ReliabilityFinding {
    return [pscustomobject]@{
        priority = "P1"
        title = "reliability defect"
        path = "src/A.cs"
        line = 10
        component = "cache"
        rootCause = "missing dependency"
        invariant = "cache invalidates"
        evidence = "evidence"
        reproduction = "reproduction"
        suggestedFix = "fix"
        suggestedTest = "test"
        fixPaths = @("src/A.cs")
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

    It "ignores personal config for exec review and resume" {
        $calls = @(
            ,@(Get-CodexRoleArguments -RepoPath $repo -Model m -Thinking low)
            ,@(Get-CodexRoleArguments -RepoPath $repo -Model m -Thinking low -Mode Review -ReviewBase HEAD)
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
        $config.Roles.PointFixer.Sandbox = "workspace-write"
        $module = Get-Module CodexReviewLoop
        & $module {
            param($profile, $repository, $logs, $fake)
            Invoke-ConfiguredCodexRole -Config $profile -Role PointFixer -RepoPath $repository `
                -Speed standard -Prompt fix -LogRoot $logs -CodexPath $fake | Out-Null
            Invoke-ConfiguredCodexRole -Config $profile -Role Reviewer -RepoPath $repository `
                -Speed standard -Prompt review -LogRoot $logs -CodexPath $fake | Out-Null
        } $config $repo $logRoot $fakeCodex

        $records = @(Get-Content -LiteralPath $env:CODEX_REVIEW_LOOP_FAKE_LOG |
            ForEach-Object { $_ | ConvertFrom-Json })
        (@($records[0].arguments) -contains "--dangerously-bypass-approvals-and-sandbox") | Should Be $true
        (@($records[1].arguments) -contains "--dangerously-bypass-approvals-and-sandbox") | Should Be $true
        @($records | Where-Object { @($_.arguments) -contains "--sandbox" }).Count | Should Be 0
    }

    It "rejects worktree changes made by an analysis role with full command access" {
        $config = Import-PowerShellDataFile -LiteralPath $configPath
        $env:CODEX_REVIEW_LOOP_FAKE_MUTATE_ON_SCHEMA = "review-result-v1.schema.json"
        $message = ""
        try {
            & (Get-Module CodexReviewLoop) {
                param($profile, $repository, $logs, $fake)
                Invoke-ConfiguredCodexRole -Config $profile -Role Reviewer -RepoPath $repository `
                    -Speed standard -Prompt review -LogRoot $logs -CodexPath $fake `
                    -SchemaName "review-result-v1.schema.json"
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
        $finding = New-ReliabilityFinding
        $finding.evidence = "authorization=$secret"
        $env:CODEX_REVIEW_LOOP_FAKE_RESULT = ConvertTo-Json -Compress -Depth 20 ([pscustomobject]@{
            schemaVersion = "1.0"
            classification = "findings"
            summary = "finding"
            findings = @($finding)
        })

        $call = Invoke-CodexCliRole -Role Test -RepoPath $repo -Model model -Thinking low `
            -Prompt p -LogRoot $logRoot -CodexPath $fakeCodex -MaxAttempts 1 `
            -SchemaPath (Join-Path $root "schemas\review-result-v1.schema.json")

        $call.Success | Should Be $true
        (Get-Content -Raw -LiteralPath $call.ResultPath) | Should Not Match $secret
        [string]$call.StructuredResult.findings[0].evidence | Should Not Match $secret
    }

    It "deletes stale structured output and resumes after invalid JSON" {
        $resultPath = Join-Path $caseRoot "results.json"
        Write-ReliabilityJsonArray -Path $resultPath -Values @(
            "not json",
            '{"schemaVersion":"1.0","classification":"clean","summary":"clean","findings":[]}'
        )
        $env:CODEX_REVIEW_LOOP_FAKE_RESULT_SEQUENCE = $resultPath

        $call = Invoke-CodexCliRole -Role Test -RepoPath $repo -Model model -Thinking low `
            -Prompt p -LogRoot $logRoot -CodexPath $fakeCodex -MaxAttempts 2 `
            -SchemaPath (Join-Path $root "schemas\review-result-v1.schema.json")
        $call.Success | Should Be $true
        $call.StructuredResult.classification | Should Be "clean"
        $records = @(Get-Content -LiteralPath $env:CODEX_REVIEW_LOOP_FAKE_LOG |
            ForEach-Object { $_ | ConvertFrom-Json })
        $records[1].callKind | Should Be "resume"
    }

    It "terminates a timed-out role" {
        $planPath = Join-Path $caseRoot "invocations.json"
        $childPidPath = Join-Path $caseRoot "child.pid"
        Write-ReliabilityJsonArray -Path $planPath -Values @(
            [pscustomobject]@{
                hangMs = 5000
                commands = @()
                childPidPath = $childPidPath
                childSleepSeconds = 60
            }
        )
        $env:CODEX_REVIEW_LOOP_FAKE_INVOCATION_SEQUENCE = $planPath

        $call = Invoke-CodexCliRole -Role Test -RepoPath $repo -Model model -Thinking low `
            -Prompt p -LogRoot $logRoot -CodexPath $fakeCodex -MaxAttempts 1 -TimeoutSeconds 1
        $call.Success | Should Be $false
        $call.FailureKind | Should Be "timeout"
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

    It "does not retry a dirty fixer without a resumable thread" {
        $planPath = Join-Path $caseRoot "invocations.json"
        Write-ReliabilityJsonArray -Path $planPath -Values @(
            [pscustomobject]@{ emitThread = $false; commands = @() }
        )
        $env:CODEX_REVIEW_LOOP_FAKE_INVOCATION_SEQUENCE = $planPath
        $env:CODEX_REVIEW_LOOP_FAKE_RESULT = "not json"
        $env:CODEX_REVIEW_LOOP_FAKE_MUTATE_ON_SCHEMA = "review-result-v1.schema.json"

        $call = Invoke-CodexCliRole -Role PointFixer -RepoPath $repo -Model model -Thinking high `
            -Prompt p -LogRoot $logRoot -CodexPath $fakeCodex `
            -MaxAttempts 2 -SchemaPath (Join-Path $root "schemas\review-result-v1.schema.json")

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
                filePath = $pwsh
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

    It "keeps raw paraphrases provisional until semantic adjudication" {
        $head = & git -C $repo rev-parse HEAD
        $ledger = New-ReviewLoopLedger -RepoPath $repo
        $first = New-ReliabilityFinding
        $first.title = "Cache invalidation is lost after failed regeneration"
        $first.rootCause = "requested representation invalidation is cleared before regeneration succeeds"
        $first.invariant = "requested representation remains invalid until successful regeneration"
        Merge-ReviewLoopFindings -Ledger $ledger -Findings @($first) `
            -ReviewId r1 -Head $head | Out-Null
        $originalId = [string]$ledger.Findings[0].Id

        $paraphrase = New-ReliabilityFinding
        $paraphrase.title = "Failed regeneration loses the requested representation invalidation"
        $paraphrase.rootCause = "representation invalidation is cleared before requested regeneration succeeds"
        $paraphrase.invariant = "the requested representation remains invalid through successful regeneration"
        Merge-ReviewLoopFindings -Ledger $ledger -Findings @($paraphrase) `
            -ReviewId r2 -Head $head | Out-Null

        @($ledger.Findings).Count | Should Be 2
        @($ledger.Findings | Where-Object { [string]$_.Id -eq $originalId }).Count | Should Be 1
        @($ledger.Findings | Where-Object { [string]$_.LastSeenReview -eq "r2" }).Count | Should Be 1
    }

    It "does not require reviewer-predicted fix paths" {
        (Get-Content -Raw -LiteralPath (Join-Path $root "src\Loop.ps1")) |
            Should Not Match "Assert-ReviewLoopFixScope|outside the active finding paths"
    }

    It "requires a complete high-confidence architecture approval" {
        $valid = [pscustomobject]@{
            decision = "approve"
            confidence = "high"
            coherentRootCause = $true
            allFindingsCovered = $true
            allRequiredPathsCovered = $true
            minimalEnough = $true
            missingPaths = @()
            requiredChanges = @()
        }
        $medium = [pscustomobject]@{
            decision = "approve"
            confidence = "medium"
            coherentRootCause = $true
            allFindingsCovered = $true
            allRequiredPathsCovered = $true
            minimalEnough = $true
            missingPaths = @()
            requiredChanges = @()
        }
        $incomplete = [pscustomobject]@{
            decision = "approve"
            confidence = "high"
            coherentRootCause = $true
            allFindingsCovered = $false
            allRequiredPathsCovered = $true
            minimalEnough = $true
            missingPaths = @()
            requiredChanges = @()
        }
        $changesRequired = $valid.PSObject.Copy()
        $changesRequired.requiredChanges = @("add a regression test")
        $module = Get-Module CodexReviewLoop
        (& $module { param($value) Test-ReviewLoopArchitectureApproval $value } $valid) |
            Should Be $true
        (& $module { param($value) Test-ReviewLoopArchitectureApproval $value } $medium) |
            Should Be $false
        (& $module { param($value) Test-ReviewLoopArchitectureApproval $value } $incomplete) |
            Should Be $false
        (& $module { param($value) Test-ReviewLoopArchitectureApproval $value } $changesRequired) |
            Should Be $false
    }

    It "uses Terra when trigger confirmation is not high confidence" {
        $config = Import-PowerShellDataFile -LiteralPath $configPath
        $runRoot = Join-Path $caseRoot "trigger-run"
        New-Item -ItemType Directory -Path $runRoot | Out-Null
        $state = New-ReviewLoopState -RepoPath $repo -ReviewBase HEAD -Speed standard -RunRoot $runRoot
        $statePath = Join-Path $runRoot "run-v1.json"
        Write-ReviewLoopState -Path $statePath -State $state | Out-Null
        $ledger = New-ReviewLoopLedger -RepoPath $repo
        $first = New-ReliabilityFinding
        $second = New-ReliabilityFinding
        $second.path = "src/B.cs"
        $second.title = "second edge"
        $second.rootCause = "different edge"
        Merge-ReviewLoopFindings -Ledger $ledger -Findings @($first, $second) `
            -ReviewId r1 -Head (& git -C $repo rev-parse HEAD) | Out-Null
        $finding = $ledger.Findings[0]
        $candidates = @(Get-ReviewLoopTriggerCandidates -Finding $finding -Ledger $ledger)
        $candidateId = [string]$candidates[0].Finding.Id
        $primary = '{"schemaVersion":"1.0","decisions":[{"candidateFindingId":"' + $candidateId + '","relation":"same_contract_different_edge","architectureRecommended":true,"confidence":"high","rationale":"shared","evidence":[{"path":"README.txt","line":1,"claim":"shared contract"}]}]}'
        $medium = '{"schemaVersion":"1.0","decisions":[{"candidateFindingId":"' + $candidateId + '","relation":"same_contract_different_edge","architectureRecommended":true,"confidence":"medium","rationale":"uncertain","evidence":[{"path":"README.txt","line":1,"claim":"shared contract"}]}]}'
        $tie = '{"schemaVersion":"1.0","decisions":[{"candidateFindingId":"' + $candidateId + '","relation":"same_contract_different_edge","architectureRecommended":true,"confidence":"high","rationale":"confirmed","evidence":[{"path":"README.txt","line":1,"claim":"shared contract"}]}]}'
        $sequence = Join-Path $caseRoot "trigger-results.json"
        Write-ReliabilityJsonArray -Path $sequence -Values @($primary, $medium, $tie)
        $env:CODEX_REVIEW_LOOP_FAKE_RESULT_SEQUENCE = $sequence

        $decision = & (Get-Module CodexReviewLoop) {
            param($profile, $loopState, $loopStatePath, $repository, $logs, $current, $prior, $fake)
            Invoke-ReviewLoopTriggerJudge -Config $profile -State $loopState -StatePath $loopStatePath `
                -RepoPath $repository -Speed standard -RunRoot $logs -Finding $current `
                -Candidates $prior -CodexPath $fake
        } $config $state $statePath $repo $runRoot $finding $candidates $fakeCodex

        $decision.ArchitectureRecommended | Should Be $true
        @($decision.Calls).Count | Should Be 3
    }

    It "reuses a stable finding identity after paraphrased reviewer output" {
        $config = Import-PowerShellDataFile -LiteralPath $configPath
        $ledger = New-ReviewLoopLedger -RepoPath $repo
        Merge-ReviewLoopFindings -Ledger $ledger -Findings @((New-ReliabilityFinding)) `
            -ReviewId r1 -Head (& git -C $repo rev-parse HEAD) | Out-Null
        $existingId = [string]$ledger.Findings[0].Id
        $incoming = New-ReliabilityFinding
        $incoming.rootCause = "dependency changes are not observed"
        $incoming.invariant = "cached values must be invalidated when dependencies change"
        $decision = '{"schemaVersion":"1.0","decisions":[{"candidateFindingId":"' +
            $existingId +
            '","relation":"same_root_cause","architectureRecommended":false,"confidence":"high","rationale":"same defect expressed differently","evidence":[{"path":"README.txt","line":1,"claim":"same behavior"}]}]}'
        $sequence = Join-Path $caseRoot "identity-results.json"
        Write-ReliabilityJsonArray -Path $sequence -Values @($decision, $decision)
        $env:CODEX_REVIEW_LOOP_FAKE_RESULT_SEQUENCE = $sequence
        $runRoot = Join-Path $caseRoot "identity-run"
        New-Item -ItemType Directory -Path $runRoot | Out-Null
        $state = New-ReviewLoopState -RepoPath $repo -ReviewBase HEAD -Speed standard -RunRoot $runRoot
        $statePath = Join-Path $runRoot "run-v1.json"
        Write-ReviewLoopState -Path $statePath -State $state | Out-Null

        $resolved = & (Get-Module CodexReviewLoop) {
            param($profile, $loopState, $loopStatePath, $loopLedger, $finding, $repository, $logs, $fake)
            @(Resolve-ReviewLoopFindingRelations `
                -Config $profile -State $loopState -StatePath $loopStatePath -Ledger $loopLedger `
                -Findings @($finding) -RepoPath $repository -Speed standard `
                -RunRoot $logs -CodexPath $fake)
        } $config $state $statePath $ledger $incoming $repo $runRoot $fakeCodex
        Merge-ReviewLoopFindings -Ledger $ledger -Findings $resolved `
            -ReviewId r2 -Head $state.CurrentHead | Out-Null

        @($ledger.Findings).Count | Should Be 1
        $ledger.Findings[0].Id | Should Be $existingId
        @($ledger.Findings[0].IdentityHistory).Count | Should Be 2
    }

    It "keeps independent findings in the same file separate after adjudication" {
        $config = Import-PowerShellDataFile -LiteralPath $configPath
        $ledger = New-ReviewLoopLedger -RepoPath $repo
        Merge-ReviewLoopFindings -Ledger $ledger -Findings @((New-ReliabilityFinding)) `
            -ReviewId r1 -Head (& git -C $repo rev-parse HEAD) | Out-Null
        $existingId = [string]$ledger.Findings[0].Id
        $incoming = New-ReliabilityFinding
        $incoming.rootCause = "unrelated parser validation"
        $incoming.invariant = "invalid syntax must be rejected"
        $decision = '{"schemaVersion":"1.0","decisions":[{"candidateFindingId":"' +
            $existingId +
            '","relation":"independent_same_file","architectureRecommended":false,"confidence":"high","rationale":"different contract","evidence":[{"path":"README.txt","line":1,"claim":"independent behavior"}]}]}'
        $sequence = Join-Path $caseRoot "independent-results.json"
        Write-ReliabilityJsonArray -Path $sequence -Values @($decision, $decision)
        $env:CODEX_REVIEW_LOOP_FAKE_RESULT_SEQUENCE = $sequence
        $runRoot = Join-Path $caseRoot "independent-run"
        New-Item -ItemType Directory -Path $runRoot | Out-Null
        $state = New-ReviewLoopState -RepoPath $repo -ReviewBase HEAD -Speed standard -RunRoot $runRoot
        $statePath = Join-Path $runRoot "run-v1.json"
        Write-ReviewLoopState -Path $statePath -State $state | Out-Null

        $resolved = & (Get-Module CodexReviewLoop) {
            param($profile, $loopState, $loopStatePath, $loopLedger, $finding, $repository, $logs, $fake)
            @(Resolve-ReviewLoopFindingRelations `
                -Config $profile -State $loopState -StatePath $loopStatePath -Ledger $loopLedger `
                -Findings @($finding) -RepoPath $repository -Speed standard `
                -RunRoot $logs -CodexPath $fake)
        } $config $state $statePath $ledger $incoming $repo $runRoot $fakeCodex
        Merge-ReviewLoopFindings -Ledger $ledger -Findings $resolved `
            -ReviewId r2 -Head $state.CurrentHead | Out-Null

        @($ledger.Findings).Count | Should Be 2
    }

    It "returns inconclusive resolved adjudication without orchestrator test evidence" {
        $config = Import-PowerShellDataFile -LiteralPath $configPath
        $runRoot = Join-Path $caseRoot "verifier-run"
        New-Item -ItemType Directory -Path $runRoot | Out-Null
        $state = New-ReviewLoopState -RepoPath $repo -ReviewBase HEAD -Speed standard -RunRoot $runRoot
        $state.ActiveClusterId = "verifier-evidence"
        $statePath = Join-Path $runRoot "run-v1.json"
        Write-ReviewLoopState -Path $statePath -State $state | Out-Null
        $fixerCall = [pscustomobject]@{
            StructuredResult = [pscustomobject]@{
                testExecution = [pscustomobject]@{ Passed = $false }
            }
        }
        $primary = '{"schemaVersion":"1.0","verdict":"resolved","confidence":"medium","rationale":"maybe","evidence":[{"path":"README.txt","line":1,"claim":"maybe fixed"}]}'
        $wrong = '{"schemaVersion":"1.0","verdict":"resolved","confidence":"high","rationale":"claimed","evidence":[{"path":"README.txt","line":1,"claim":"claimed fixed"}]}'
        $sequence = Join-Path $caseRoot "verifier-results.json"
        Write-ReliabilityJsonArray -Path $sequence -Values @($primary, $wrong, $wrong)
        $env:CODEX_REVIEW_LOOP_FAKE_RESULT_SEQUENCE = $sequence

        $verification = & (Get-Module CodexReviewLoop) {
            param($profile, $loopState, $loopStatePath, $repository, $logs, $finding, $fixer, $fake)
            Invoke-ReviewLoopVerifier -Config $profile -State $loopState -StatePath $loopStatePath `
                -RepoPath $repository -Speed standard -RunRoot $logs -Findings @($finding) `
                -FixerCall $fixer -Attempt 1 -CodexPath $fake
        } $config $state $statePath $repo $runRoot (New-ReliabilityFinding) $fixerCall $fakeCodex
        $verification.Accepted | Should Be $false
        $verification.Basis | Should Match "lacked orchestrator-owned test evidence"
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
        $failure.Exception.Data["ReviewLoopStatus"] | Should Be "blocked"
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
        $statePath = Join-Path $runRoot "run-v1.json"
        Write-ReviewLoopState -Path $statePath -State $state | Out-Null
        $fixerCall = [pscustomobject]@{
            StructuredResult = [pscustomobject]@{
                testExecution = [pscustomobject]@{ Passed = $true }
            }
        }
        $result = '{"schemaVersion":"1.0","verdict":"reproduced","confidence":"high","rationale":"still present","evidence":[{"path":"README.txt","line":1,"claim":"current path remains"}]}'
        $sequence = Join-Path $caseRoot "large-verifier-results.json"
        Write-ReliabilityJsonArray -Path $sequence -Values @($result)
        $env:CODEX_REVIEW_LOOP_FAKE_RESULT_SEQUENCE = $sequence
        $verification = & (Get-Module CodexReviewLoop) {
            param($profile, $loopState, $loopStatePath, $repository, $logs, $finding, $fixer, $fake)
            Invoke-ReviewLoopVerifier -Config $profile -State $loopState -StatePath $loopStatePath `
                -RepoPath $repository -Speed standard -RunRoot $logs -Findings @($finding) `
                -FixerCall $fixer -Attempt 1 -CodexPath $fake
        } $config $state $statePath $repo $runRoot (New-ReliabilityFinding) $fixerCall $fakeCodex
        $verification.Result.verdict | Should Be "reproduced"
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
        $failure.Exception.Data["ReviewLoopStatus"] | Should Be "blocked"
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
        (& git -C $repo rev-parse HEAD) | Should Be $externalHead
        (& git -C $repo show -s --format=%s HEAD) | Should Be "external commit"
    }

    It "blocks a failed targeted test that mutates repository state" {
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
                    filePath = "dotnet"
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
        $failure.Exception.Data["ReviewLoopStatus"] | Should Be "blocked"
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

    It "invalidates a clean pass recorded by an older tool fingerprint" {
        $config = Import-PowerShellDataFile -LiteralPath $configPath
        $paths = & (Get-Module CodexReviewLoop) {
            param($profile, $repository)
            New-ReviewLoopRunPaths -Config $profile -RepoPath $repository
        } $config $repo
        $paths.RunRoot = Join-Path $paths.ProfileRoot "99999999-stale-clean-pass"
        New-Item -ItemType Directory -Path $paths.RunRoot -Force | Out-Null
        $statePath = Join-Path $paths.RunRoot "run-v1.json"
        $head = & git -C $repo rev-parse HEAD
        $state = New-ReviewLoopState -RepoPath $repo -ReviewBase HEAD -Speed standard `
            -RunRoot $paths.RunRoot -ReviewBaseCommit $head -ExecutionFingerprint "old"
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
            Where-Object {
                [System.IO.Path]::GetFileName([string]$_.schemaPath) -eq "review-result-v1.schema.json"
            })
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

    It "uses the final fixer attempt after a crash before that call" {
        $config = Import-PowerShellDataFile -LiteralPath $configPath
        $paths = & (Get-Module CodexReviewLoop) {
            param($profile, $repository)
            New-ReviewLoopRunPaths -Config $profile -RepoPath $repository
        } $config $repo
        $paths.RunRoot = Join-Path $paths.ProfileRoot "99999999-fixer-pending"
        New-Item -ItemType Directory -Path $paths.RunRoot -Force | Out-Null
        $statePath = Join-Path $paths.RunRoot "run-v1.json"
        $ledger = New-ReviewLoopLedger -RepoPath $repo
        Merge-ReviewLoopFindings -Ledger $ledger -Findings @((New-ReliabilityFinding)) `
            -ReviewId r1 -Head (& git -C $repo rev-parse HEAD) | Out-Null
        $finding = $ledger.Findings[0]
        $finding.Status = "fixing"
        $finding.FixAttempts = 2
        $finding.FixerThreadId = ""
        $finding.FixPaths = @($finding.FixPaths) + "interrupted.txt"
        Write-ReviewLoopLedger -Path $paths.LedgerPath -Ledger $ledger | Out-Null
        $currentHead = & git -C $repo rev-parse HEAD
        $executionFingerprint = & (Get-Module CodexReviewLoop) {
            param($path)
            Get-ReviewLoopExecutionFingerprint -ConfigPath $path
        } $configPath
        $state = New-ReviewLoopState -RepoPath $repo -ReviewBase HEAD -Speed standard `
            -RunRoot $paths.RunRoot -ReviewBaseCommit $currentHead `
            -ExecutionFingerprint $executionFingerprint
        $state.Status = "failed"
        $state.Stage = "fixing"
        $state.ActiveClusterId = $finding.ClusterId
        $state.ActiveFindingIds = @($finding.Id)
        $state.LastFixerResult = [pscustomobject]@{
            Success = $true
            FailureKind = "none"
            Attempt = 1
            ThreadId = ""
            StructuredResult = [pscustomobject]@{
                schemaVersion = "1.0"
                outcome = "changed"
                summary = "old attempt"
                changedPaths = @("interrupted.txt")
                targetedTest = [pscustomobject]@{
                    filePath = "dotnet"
                    arguments = @("test", ".\review-loop-test.proj", "--no-restore", "--nologo")
                    rationale = "targeted regression"
                }
                remainingRisk = ""
            }
        }
        Write-ReviewLoopState -Path $statePath -State $state | Out-Null
        Set-Content -LiteralPath (
            Join-Path $paths.RunRoot "$($finding.ClusterId)-fix-2-pointfixer.jsonl"
        ) -Value '{"type":"thread.started","thread_id":"reliability-thread"}' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $repo "interrupted.txt") -Value "partial"
        $env:CODEX_REVIEW_LOOP_FAKE_MUTATE_ON_SCHEMA = "fixer-result-v1.schema.json"
        $fix = '{"schemaVersion":"1.0","outcome":"changed","summary":"fixed","changedPaths":[],"targetedTest":{"filePath":"dotnet","arguments":["test",".\\review-loop-test.proj","--no-restore","--nologo"],"rationale":"targeted regression"},"remainingRisk":""}'
        $resolved = '{"schemaVersion":"1.0","verdict":"resolved","confidence":"high","rationale":"fixed","evidence":[{"path":"README.txt","line":1,"claim":"the defect is fixed"}]}'
        $resultSequence = Join-Path $caseRoot "results.json"
        Write-ReliabilityJsonArray -Path $resultSequence -Values @(
            $fix,
            $resolved,
            '{"schemaVersion":"1.0","classification":"clean","summary":"clean","findings":[]}',
            '{"schemaVersion":"1.0","classification":"clean","summary":"clean","findings":[]}'
        )
        $env:CODEX_REVIEW_LOOP_FAKE_RESULT_SEQUENCE = $resultSequence

        $result = Invoke-CodexReviewLoop -RepoPath $repo -ConfigPath $configPath `
            -CodexPath $fakeCodex -HeartbeatSeconds 0 -ColorMode Never
        $result.Status | Should Be "completed"
        $records = @(Get-Content -LiteralPath $env:CODEX_REVIEW_LOOP_FAKE_LOG |
            ForEach-Object { $_ | ConvertFrom-Json })
        @($records | Where-Object {
            [System.IO.Path]::GetFileName([string]$_.schemaPath) -eq "fixer-result-v1.schema.json"
        }).Count | Should Be 1
        $fixerRecord = @($records | Where-Object {
            [System.IO.Path]::GetFileName([string]$_.schemaPath) -eq "fixer-result-v1.schema.json"
        })[0]
        $fixerRecord.callKind | Should Be "resume"
        $fixerRecord.resumeThreadId | Should Be "reliability-thread"
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
            $threw = $false
            try {
                Invoke-CodexReviewLoop -RepoPath $repo -ConfigPath $configPath `
                    -CodexPath $fakeCodex -NewRun | Out-Null
            }
            catch {
                $threw = $true
            }
            $threw | Should Be $true
        }
        finally {
            $lock.Dispose()
        }
    }
}
