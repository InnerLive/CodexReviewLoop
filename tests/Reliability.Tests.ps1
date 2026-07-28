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
    MaxArchitecturePaths = 15
    MaxProductionPaths = 8
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
        PointFixer = @{ Model = 'fake'; Thinking = 'high'; Sandbox = 'danger-full-access' }
        ArchitectureFixer = @{ Model = 'fake'; Thinking = 'max'; Sandbox = 'danger-full-access' }
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
        }
    }

    It "enforces loop-owned sandboxes despite profile values" {
        $config = Import-PowerShellDataFile -LiteralPath $configPath
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
        (@($records[0].arguments) -contains "workspace-write") | Should Be $true
        (@($records[0].arguments) -contains "--dangerously-bypass-approvals-and-sandbox") | Should Be $false
        (@($records[1].arguments) -contains "read-only") | Should Be $true
    }

    It "allows analysis commands and blocks orchestrator-owned tests" {
        $module = Get-Module CodexReviewLoop
        $allowed = @(
            "git diff --check",
            "git blame -L 850,1260 -- src/CoreRuntime/Representations/RepresentationCoordinator.cs",
            '"C:\Program Files\PowerShell\7\pwsh.exe" -Command ''git blame -L 850,1260 -- src/CoreRuntime/Representations/RepresentationCoordinator.cs''',
            "rg -F -e cache .",
            "Get-Content -LiteralPath .\README.txt -TotalCount 20"
        )
        foreach ($command in $allowed) {
            (& $module {
                param($value)
                Test-ReviewLoopModelOwnedTestCommand -Command $value
            } $command) | Should Be $false
        }

        $forbidden = @(
            "dotnet test .\review-loop-test.proj",
            "dotnet vstest .\tests.dll",
            "pytest -q",
            '"C:\Program Files\PowerShell\7\pwsh.exe" -Command ''dotnet test .\review-loop-test.proj'''
        )
        foreach ($command in $forbidden) {
            (& $module {
                param($value)
                Test-ReviewLoopModelOwnedTestCommand -Command $value
            } $command) | Should Be $true
        }
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

    It "keeps a failed analysis command inside the successful Codex turn" {
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
        $transcriptText | Should Match "CLI command failed"
        $transcriptText | Should Match "tests\\missing.cs"
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

    It "stops model-owned tests and retries on the same thread" {
        $planPath = Join-Path $caseRoot "invocations.json"
        Write-ReliabilityJsonArray -Path $planPath -Values @(
            [pscustomobject]@{
                threadId = "policy-thread"
                commands = @([pscustomobject]@{
                    command = "dotnet test .\review-loop-test.proj"
                    exitCode = 0
                    output = "must never complete"
                    delayMs = 5000
                })
            },
            [pscustomobject]@{ threadId = "policy-thread"; commands = @() }
        )
        $env:CODEX_REVIEW_LOOP_FAKE_INVOCATION_SEQUENCE = $planPath

        $call = Invoke-CodexCliRole -Role Test -RepoPath $repo -Model model -Thinking low `
            -Prompt p -LogRoot $logRoot -CodexPath $fakeCodex -MaxAttempts 2

        $call.Success | Should Be $true
        @($call.Attempts).Count | Should Be 2
        $call.Attempts[0].FailureKind | Should Be "model_owned_test"
        $records = @(Get-Content -LiteralPath $env:CODEX_REVIEW_LOOP_FAKE_LOG |
            ForEach-Object { $_ | ConvertFrom-Json })
        $records[1].callKind | Should Be "resume"
        $records[1].resumeThreadId | Should Be "policy-thread"
        (Get-Content -Raw -LiteralPath $call.JsonlPath) |
            Should Not Match '"type":"item.completed".*"command":"dotnet test'
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

        $call.Success | Should Be $false
        $call.FailureKind | Should Be "role_event_error"
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
            -Sandbox workspace-write -Prompt p -LogRoot $logRoot -CodexPath $fakeCodex `
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

    It "allows only direct recognized test-runner commands" {
        $module = Get-Module CodexReviewLoop
        $accepted = & $module {
            @(
                $null -ne (ConvertFrom-ReviewLoopTargetedCommand "dotnet test .\x.csproj --no-restore")
                $null -ne (ConvertFrom-ReviewLoopTargetedCommand "python -m pytest -k cache")
            )
        }
        @($accepted | Where-Object { $_ }).Count | Should Be 2

        $rejected = & $module {
            @(
                $null -ne (ConvertFrom-ReviewLoopTargetedCommand "Write-Output ok")
                $null -ne (ConvertFrom-ReviewLoopTargetedCommand "Invoke-Expression 'Remove-Item x'")
                $null -ne (ConvertFrom-ReviewLoopTargetedCommand "python -c 'print(1)'")
                $null -ne (ConvertFrom-ReviewLoopTargetedCommand "dotnet test x > result.txt")
                $null -ne (ConvertFrom-ReviewLoopTargetedCommand "dotnet --version")
            )
        }
        @($rejected | Where-Object { $_ }).Count | Should Be 0
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

    It "keeps paraphrased findings separate unless their stable identity matches" {
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

    It "keeps point-fix production changes inside the active finding scope" {
        $state = [pscustomobject]@{ ActiveStrategy = $null }
        $finding = New-ReliabilityFinding
        $module = Get-Module CodexReviewLoop

        { & $module {
            param($loopState, $activeFinding)
            Assert-ReviewLoopFixScope -State $loopState -Findings @($activeFinding) `
                -ChangedPaths @("tests/new-regression.test.cs")
        } $state $finding } | Should Not Throw

        $failure = $null
        try {
            & $module {
                param($loopState, $activeFinding)
                Assert-ReviewLoopFixScope -State $loopState -Findings @($activeFinding) `
                    -ChangedPaths @("src/Unrelated.cs")
            } $state $finding
        }
        catch {
            $failure = $_
        }
        $failure.Exception.Data["ReviewLoopStatus"] | Should Be "blocked"
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
        $primary = '{"schemaVersion":"1.0","relation":"same_contract_different_edge","architectureRecommended":true,"confidence":"high","rationale":"shared","evidence":["README.txt:1"]}'
        $medium = '{"schemaVersion":"1.0","relation":"same_contract_different_edge","architectureRecommended":true,"confidence":"medium","rationale":"uncertain","evidence":["README.txt:1"]}'
        $tie = '{"schemaVersion":"1.0","relation":"same_contract_different_edge","architectureRecommended":true,"confidence":"high","rationale":"confirmed","evidence":["README.txt:1"]}'
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

    It "rejects resolved adjudication without matching orchestrator test evidence" {
        $config = Import-PowerShellDataFile -LiteralPath $configPath
        $runRoot = Join-Path $caseRoot "verifier-run"
        New-Item -ItemType Directory -Path $runRoot | Out-Null
        $state = New-ReviewLoopState -RepoPath $repo -ReviewBase HEAD -Speed standard -RunRoot $runRoot
        $state.ActiveClusterId = "verifier-evidence"
        $statePath = Join-Path $runRoot "run-v1.json"
        Write-ReviewLoopState -Path $statePath -State $state | Out-Null
        $command = "dotnet test .\review-loop-test.proj --no-restore"
        $wrongCommand = "dotnet test .\different.proj --no-restore"
        $fixerCall = [pscustomobject]@{
            StructuredResult = [pscustomobject]@{
                targetedTests = @([pscustomobject]@{
                    command = $command
                    passed = $true
                    evidence = "orchestrator exit code 0"
                })
            }
        }
        $primary = '{"schemaVersion":"1.0","verdict":"resolved","confidence":"medium","rationale":"maybe","evidence":["README.txt:1"],"targetedTest":{"command":"dotnet test .\\review-loop-test.proj --no-restore","passed":true,"evidence":"passed"}}'
        $wrong = '{"schemaVersion":"1.0","verdict":"resolved","confidence":"high","rationale":"claimed","evidence":["README.txt:1"],"targetedTest":{"command":"dotnet test .\\different.proj --no-restore","passed":true,"evidence":"claimed"}}'
        $sequence = Join-Path $caseRoot "verifier-results.json"
        Write-ReliabilityJsonArray -Path $sequence -Values @($primary, $wrong, $wrong)
        $env:CODEX_REVIEW_LOOP_FAKE_RESULT_SEQUENCE = $sequence

        $failure = $null
        try {
            & (Get-Module CodexReviewLoop) {
                param($profile, $loopState, $loopStatePath, $repository, $logs, $finding, $fixer, $fake)
                Invoke-ReviewLoopVerifier -Config $profile -State $loopState -StatePath $loopStatePath `
                    -RepoPath $repository -Speed standard -RunRoot $logs -Findings @($finding) `
                    -FixerCall $fixer -Attempt 1 -CodexPath $fake
            } $config $state $statePath $repo $runRoot (New-ReliabilityFinding) $fixerCall $fakeCodex | Out-Null
        }
        catch {
            $failure = $_
        }

        $failure | Should Not BeNullOrEmpty
        $failure.Exception.Data["ReviewLoopStatus"] | Should Be "blocked"
        $failure.Exception.Message | Should Match "verifier_evidence_mismatch"
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

    It "blocks verification when the patch exceeds its evidence limit" {
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
                targetedTests = @([pscustomobject]@{
                    command = "dotnet test .\review-loop-test.proj --no-restore --nologo"
                    passed = $true
                    evidence = "passed"
                })
            }
        }

        $failure = $null
        try {
            & (Get-Module CodexReviewLoop) {
                param($profile, $loopState, $loopStatePath, $repository, $logs, $finding, $fixer)
                Invoke-ReviewLoopVerifier -Config $profile -State $loopState -StatePath $loopStatePath `
                    -RepoPath $repository -Speed standard -RunRoot $logs -Findings @($finding) `
                    -FixerCall $fixer -Attempt 1 -CodexPath ""
            } @{} $state $statePath $repo $runRoot (New-ReliabilityFinding) $fixerCall | Out-Null
        }
        catch {
            $failure = $_
        }

        $failure | Should Not BeNullOrEmpty
        $failure.Exception.Data["ReviewLoopStatus"] | Should Be "blocked"
        $failure.Exception.Message | Should Match "verifier limit is 120000"
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
                targetedTests = @([pscustomobject]@{
                    command = "dotnet test .\review-loop-test.proj --no-restore --nologo"
                    passed = $false
                    evidence = "not run; orchestrator-owned"
                })
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

    It "isolates ledgers and runs by branch and pinned review base" {
        $config = Import-PowerShellDataFile -LiteralPath $configPath
        $module = Get-Module CodexReviewLoop
        $mainRoot = & $module {
            param($profile, $repository)
            (New-ReviewLoopRunPaths -Config $profile -RepoPath $repository).ProfileRoot
        } $config $repo
        $initialBranch = & git -C $repo branch --show-current
        & git -C $repo switch -q -c reliability-other
        try {
            $otherRoot = & $module {
                param($profile, $repository)
                (New-ReviewLoopRunPaths -Config $profile -RepoPath $repository).ProfileRoot
            } $config $repo
        }
        finally {
            & git -C $repo switch -q $initialBranch
        }

        $otherRoot | Should Not Be $mainRoot
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
                targetedTests = @([pscustomobject]@{
                    command = "dotnet test .\review-loop-test.proj --no-restore --nologo"
                    passed = $true
                    evidence = "old"
                })
                remainingRisk = ""
            }
        }
        Write-ReviewLoopState -Path $statePath -State $state | Out-Null
        Set-Content -LiteralPath (
            Join-Path $paths.RunRoot "$($finding.ClusterId)-fix-2-pointfixer.jsonl"
        ) -Value '{"type":"thread.started","thread_id":"reliability-thread"}' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $repo "interrupted.txt") -Value "partial"
        $env:CODEX_REVIEW_LOOP_FAKE_MUTATE_ON_SCHEMA = "fixer-result-v1.schema.json"
        $fix = '{"schemaVersion":"1.0","outcome":"changed","summary":"fixed","changedPaths":[],"targetedTests":[{"command":"dotnet test .\\review-loop-test.proj --no-restore --nologo","passed":false,"evidence":"not run; orchestrator-owned"}],"remainingRisk":""}'
        $resolved = '{"schemaVersion":"1.0","verdict":"resolved","confidence":"high","rationale":"fixed","evidence":["README.txt:1"],"targetedTest":{"command":"dotnet test .\\review-loop-test.proj --no-restore --nologo","passed":true,"evidence":"passed"}}'
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
