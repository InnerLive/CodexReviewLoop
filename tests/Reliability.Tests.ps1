$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
$modulePath = Join-Path $root "CodexReviewLoop.psd1"
$fakeCodex = Join-Path $here "FakeCodex.ps1"

Import-Module $modulePath -Force
. (Join-Path $here 'ArchitectureFixtures.ps1')

function New-ReliabilityRepo {
    param([Parameter(Mandatory = $true)][string]$Path)

    $template = Join-Path $TestDrive "repo-template-reliability"
    if (-not (Test-Path -LiteralPath (Join-Path $template ".git") -PathType Container)) {
        New-Item -ItemType Directory -Path $template -Force | Out-Null
        & git -C $template init -q
        & git -C $template config user.email "review-loop-tests@example.invalid"
        & git -C $template config user.name "Review Loop Tests"
        & git -C $template config core.autocrlf false
        Set-Content -LiteralPath (Join-Path $template "README.txt") -Value "initial"
        Set-Content -LiteralPath (Join-Path $template "review-loop-test.proj") -Value @"
<Project>
  <Target Name="VSTest">
    <Message Text="targeted test passed" Importance="High" />
  </Target>
</Project>
"@
        & git -C $template add README.txt review-loop-test.proj
        & git -C $template commit -q -m "initial"
    }
    & git clone -q --no-hardlinks `
        -c user.email=review-loop-tests@example.invalid `
        -c user.name="Review Loop Tests" `
        -c core.autocrlf=false `
        -- $template $Path
    if ($LASTEXITCODE -ne 0) {
        throw "Reliability repository clone failed: '$Path'."
    }
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
    TargetedTestRepositoryChanges = @{
        Mode = 'Fail'
    }
    AutoCommit = `$true
    CommitMessagePrefix = 'Reliability'
    HostGates = @()
    Roles = @{
        Reviewer = @{ Model = 'fake'; Thinking = 'high' }
        Architect = @{ Model = 'fake'; Thinking = 'high' }
        Fixer = @{ Model = 'fake'; Thinking = 'high' }
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

function Test-ReliabilityThrows {
    param([Parameter(Mandatory = $true)][scriptblock]$Script)

    try {
        & $Script | Out-Null
        return $false
    }
    catch {
        return $true
    }
}

function New-ReliabilityTestCase {
    & (Get-Module CodexReviewLoop) {
        $script:ReviewLoopRetryDelayOverride = { param([int]$seconds) }
    }
    $caseRoot = Join-Path $TestDrive ([Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $caseRoot | Out-Null
    $caseRoot = (Get-Item -LiteralPath $caseRoot).FullName
    $repo = New-ReliabilityRepo -Path (Join-Path $caseRoot "repo")
    $logRoot = New-TestLogRoot -ToolRoot $root
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

    return [pscustomobject]@{
        Root = $caseRoot
        Repo = $repo
        LogRoot = $logRoot
        ConfigPath = $configPath
    }
}

function Clear-ReliabilityTestCase {
    Clear-TestLogRoots -ToolRoot $root
    & (Get-Module CodexReviewLoop) { $script:ReviewLoopRetryDelayOverride = $null }
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

function Add-CriticTestReviews {
    param($State, [int]$From = 1, [int]$To = 10)
    & (Get-Module CodexReviewLoop) {
        param($s, $first, $last)
        foreach ($cycle in $first..$last) {
            Add-ReviewLoopRoleCall -State $s -Call ([pscustomobject]@{
                CallId = ('review-{0:d2}' -f $cycle); Role = 'Reviewer'
                Model = 'fake'; Thinking = 'high'; Speed = 'standard'
                Success = $true; ExitCode = 0; FailureKind = 'none'; ThreadId = ''
                Usage = @{ InputTokens = 0; OutputTokens = 0 }
                JsonlPath = ''; ResultPath = ''; FinalMessage = 'No findings.'
                RepositoryHead = $s.CurrentHead
            }) | Out-Null
        }
        $s.ReviewCycle = $last
    } $State $From $To
}

function Invoke-CriticTestGate {
    param($Config, $State, $StatePath, $Repo, $RunRoot, $Fake)
    & (Get-Module CodexReviewLoop) {
        param($c, $s, $path, $r, $logs, $cli)
        Invoke-ReviewLoopCriticGate -Config $c -State $s -StatePath $path `
            -Ledger (New-ReviewLoopLedger -RepoPath $r) -RepoPath $r `
            -Speed standard -RunRoot $logs -CodexPath $cli
    } $Config $State $StatePath $Repo $RunRoot $Fake
}

function New-CriticTestPendingCall {
    param($State, $Repo, [string]$Role, [string]$CallId, [string]$ThreadId = 'interrupted-thread')
    & (Get-Module CodexReviewLoop) {
        param($s, $r, $roleName, $id, $thread)
        $snap = Get-ReviewLoopRepositorySnapshot -RepoPath $r
        [pscustomobject]@{
            CallId = $id; Role = $roleName; ThreadId = $thread
            ExecutionFingerprint = ''; CheckpointStage = $s.Stage
            RepositoryHead = $snap.Head; WorktreeFingerprint = $snap.Fingerprint
            RepositoryBranch = $snap.Branch; RepositoryHeadRef = $snap.HeadRef
            RefsFingerprint = $snap.RefsFingerprint; IndexFingerprint = $snap.IndexFingerprint
            CoveredReviewCount = Get-ReviewLoopCompletedReviewCount -State $s
        }
    } $State $Repo $Role $CallId $ThreadId
}

function Assert-CriticTestFeedbackDelivery {
    param($Call, [int]$ReviewCount, [string]$Feedback)

    $instructions = [string]$Call.prompt
    $expected = (Get-Content -Raw (Join-Path $root 'prompts/critic-feedback.md')).
        Replace('{{CRITIC_ID}}', ('critic-{0:D4}' -f $ReviewCount)).
        Replace('{{COVERED_REVIEWS}}', [string]$ReviewCount).
        Replace('{{FEEDBACK}}', $Feedback)
    $instructions.Contains($expected) | Should Be $true
}

Describe "Periodic Critic process and resume" -Tags @("Process") {
    BeforeEach {
        $case = New-ReliabilityTestCase
        $repo = $case.Repo
        $configPath = $case.ConfigPath
        $config = & (Get-Module CodexReviewLoop) {
            param($path, $r)
            Import-ReviewLoopConfig -ConfigPath $path -RepoPath $r
        } $configPath $repo
        $paths = & (Get-Module CodexReviewLoop) {
            param($c, $r)
            $p = New-ReviewLoopRunPaths -Config $c -RepoPath $r `
                -ReviewBaseCommit (Get-ReviewLoopGitValue -RepoPath $r -Arguments @('rev-parse', 'HEAD'))
            Initialize-ReviewLoopRunPaths -Paths $p | Out-Null
            $p
        } $config $repo
        $runRoot = $paths.RunRoot
        $statePath = $paths.StatePath
        $state = New-ReviewLoopState -RepoPath $repo -ReviewBase HEAD -Speed standard `
            -ReviewBaseCommit (& git -C $repo rev-parse HEAD) -RunRoot $runRoot
        Add-CriticTestReviews -State $state
        Write-ReviewLoopState -Path $statePath -State $state | Out-Null
    }
    AfterEach {
        & (Get-Module CodexReviewLoop) {
            Initialize-ReviewLoopConsole -TranscriptPath "" -HostOutputEnabled $false
        }
        Clear-ReliabilityTestCase
    }

    It "defaults old profiles and critiques 41 reviews before the next native review" {
        $config.CriticStartAfterReviews | Should Be 5
        Add-CriticTestReviews -State $state -From 11 -To 41
        $state.PSObject.Properties.Remove('ActiveCriticCall')
        Write-ReviewLoopState -Path $statePath -State $state | Out-Null
        $result = Invoke-CodexReviewLoop -RepoPath $repo -ConfigPath $configPath -CodexPath $fakeCodex -Json
        $result.Status | Should Be 'completed'
        # Inspect the ordinary role sequence; task clarification and overall judgment are covered separately.
        $calls = @(Get-Content $env:CODEX_REVIEW_LOOP_FAKE_LOG | ForEach-Object { $_ | ConvertFrom-Json } |
            Where-Object { $_.schemaPath -notmatch 'architecture-orientation' -and $_.phase -ne 'completion' })
        [IO.Path]::GetFileName($calls[0].schemaPath) | Should Be 'critic-v2.schema.json'
        @($calls | Where-Object schemaPath -match 'critic-v2').Count | Should Be 2
        $saved = Read-ReviewLoopState $statePath
        $critics = @($saved.RoleCalls | Where-Object Role -eq 'Critic')
        $critics.Count | Should Be 2
        $critics[0].CoveredReviewCount | Should Be 41
        $critics[1].CoveredReviewCount | Should Be 42
        $critics[0].Model | Should Be 'gpt-5.6-sol'
        $critics[0].Thinking | Should Be 'high'
        $saved.ReviewCycle | Should Be 43
        $saved.ActiveCriticCall | Should BeNullOrEmpty
        ($calls[1].arguments -join ' ') | Should Not Match 'Reviewer: examine'
        ($calls[1].arguments -join ' ') | Should Not Match 'Architect: make'
    }

    It "counts unique successful reviews and starts fresh critiques only when due" {
        $state.RoleCalls = @()
        Add-CriticTestReviews -State $state -From 1 -To 4
        Add-CriticTestReviews -State $state -From 1 -To 1
        Invoke-CriticTestGate $config $state $statePath $repo $runRoot $fakeCodex
        Test-Path $env:CODEX_REVIEW_LOOP_FAKE_LOG | Should Be $false
        Add-CriticTestReviews -State $state -From 5 -To 6
        $state.RoleCalls[-1].Success = $false
        Invoke-CriticTestGate $config $state $statePath $repo $runRoot $fakeCodex
        Invoke-CriticTestGate $config $state $statePath $repo $runRoot $fakeCodex
        Add-CriticTestReviews -State $state -From 6 -To 6
        Invoke-CriticTestGate $config $state $statePath $repo $runRoot $fakeCodex
        Add-CriticTestReviews -State $state -From 7 -To 7
        Invoke-CriticTestGate $config $state $statePath $repo $runRoot $fakeCodex
        # Inspect the ordinary role sequence; task clarification and overall judgment are covered separately.
        $calls = @(Get-Content $env:CODEX_REVIEW_LOOP_FAKE_LOG | ForEach-Object { $_ | ConvertFrom-Json } |
            Where-Object { $_.schemaPath -notmatch 'architecture-orientation' -and $_.phase -ne 'completion' })
        $calls.Count | Should Be 3
        @($calls | Where-Object callKind -eq 'exec').Count | Should Be 3
        $calls[1].prompt | Should Match 'Reviewer: examine'
        $calls[1].prompt | Should Match 'Architect: make'
        $calls[1].prompt | Should Match 'Fixer: implement'
        @($state.RoleCalls | Where-Object Role -eq 'Critic' | Select-Object -ExpandProperty CoveredReviewCount) |
            Should Be @(5, 6, 7)
    }

    It "defers newly due criticism at the invocation limit and runs it first on resume" {
        Set-Content $configPath ((Get-Content -Raw $configPath).Replace('MaxReviewCycles = 6', 'MaxReviewCycles = 1'))
        $state.RoleCalls = @()
        Add-CriticTestReviews -State $state -From 1 -To 4
        Write-ReviewLoopState $statePath $state | Out-Null
        $first = Invoke-CodexReviewLoop -RepoPath $repo -ConfigPath $configPath -CodexPath $fakeCodex -Json
        $first.Status | Should Be 'limit_reached'
        # Inspect the ordinary role sequence; task clarification and overall judgment are covered separately.
        $calls = @(Get-Content $env:CODEX_REVIEW_LOOP_FAKE_LOG | ForEach-Object { $_ | ConvertFrom-Json } |
            Where-Object { $_.schemaPath -notmatch 'architecture-orientation' -and $_.phase -ne 'completion' })
        $calls.Count | Should Be 1
        $calls[0].callKind | Should Be 'review'
        $second = Invoke-CodexReviewLoop -RepoPath $repo -ConfigPath $configPath -CodexPath $fakeCodex -Json
        $second.Status | Should Be 'completed'
        # Inspect the ordinary role sequence; task clarification and overall judgment are covered separately.
        $calls = @(Get-Content $env:CODEX_REVIEW_LOOP_FAKE_LOG | ForEach-Object { $_ | ConvertFrom-Json } |
            Where-Object { $_.schemaPath -notmatch 'architecture-orientation' -and $_.phase -ne 'completion' })
        [IO.Path]::GetFileName($calls[1].schemaPath) | Should Be 'critic-v2.schema.json'
        $calls[2].callKind | Should Be 'review'
        (Read-ReviewLoopState $statePath).CleanPasses | Should Be 2
    }

    It "honors disabled and changed thresholds without invalidating clean evidence" {
        $state.CleanPasses = 1
        $state.CleanHead = $state.CurrentHead
        $config.CriticStartAfterReviews = 0
        Invoke-CriticTestGate $config $state $statePath $repo $runRoot $fakeCodex
        Test-Path $env:CODEX_REVIEW_LOOP_FAKE_LOG | Should Be $false
        $config.CriticStartAfterReviews = 11
        Invoke-CriticTestGate $config $state $statePath $repo $runRoot $fakeCodex
        Test-Path $env:CODEX_REVIEW_LOOP_FAKE_LOG | Should Be $false
        $config.CriticStartAfterReviews = 10
        Invoke-CriticTestGate $config $state $statePath $repo $runRoot $fakeCodex
        $state.CleanPasses | Should Be 1
        $state.CleanHead | Should Be $state.CurrentHead
        $state.ReviewCyclesThisInvocation | Should Be 0
        $state.ExecutionFingerprint | Should Be ''
    }

    It "gives successful completion precedence over overdue criticism" {
        $state.CleanPasses = 2
        $state.CleanHead = $state.CurrentHead
        Invoke-CriticTestGate $config $state $statePath $repo $runRoot $fakeCodex
        Test-Path $env:CODEX_REVIEW_LOOP_FAKE_LOG | Should Be $false
    }

    It "routes feedback separately and requalifies cached Architect advice and assessment" {
        $module = Get-Module CodexReviewLoop
        $invoke = {
            param($c, $s, $path, $r, $logs, $cli, $role, $id, $schema)
            Invoke-ConfiguredCodexRole -Config $c -Role $role -RepoPath $r `
                -Speed standard -Prompt 'Current work' -LogRoot $logs -SchemaName $schema `
                -CallId $id -State $s -StatePath $path -CodexPath $cli
        }
        & $module $invoke $config $state $statePath $repo $runRoot $fakeCodex Architect advice 'architecture-advice-v3.schema.json' | Out-Null
        Invoke-CriticTestGate $config $state $statePath $repo $runRoot $fakeCodex
        & $module $invoke $config $state $statePath $repo $runRoot $fakeCodex Architect advice 'architecture-advice-v3.schema.json' | Out-Null
        & $module $invoke $config $state $statePath $repo $runRoot $fakeCodex Architect advice 'architecture-advice-v3.schema.json' | Out-Null
        & $module $invoke $config $state $statePath $repo $runRoot $fakeCodex Architect assessment 'architecture-assessment-v2.schema.json' | Out-Null
        $config.ReviewerInstructions = 'Keep my original review context.'
        & $module {
            param($c, $s, $path, $r, $logs, $cli)
            Invoke-ConfiguredCodexRole -Config $c -Role Reviewer -RepoPath $r -Speed standard `
                -Prompt '' -LogRoot $logs -Mode Review -ReviewBase HEAD -CallId review-11 `
                -State $s -StatePath $path -CodexPath $cli
        } $config $state $statePath $repo $runRoot $fakeCodex | Out-Null
        # Inspect the ordinary role sequence; task clarification and overall judgment are covered separately.
        $calls = @(Get-Content $env:CODEX_REVIEW_LOOP_FAKE_LOG | ForEach-Object { $_ | ConvertFrom-Json } |
            Where-Object { $_.schemaPath -notmatch 'architecture-orientation' -and $_.phase -ne 'completion' })
        $calls.Count | Should Be 5
        $calls[1].prompt | Should Match 'feedback, which remains in context until replaced'
        $calls[1].prompt | Should Match '"CriticStartAfterReviews":5'
        foreach ($index in @(2, 3)) {
            Assert-CriticTestFeedbackDelivery $calls[$index] 10 'Architect: make coherent decisions.'
            ($calls[$index].arguments -join ' ') | Should Not Match 'Reviewer: examine'
        }
        ($calls[4].arguments -join ' ') | Should Match 'Keep my original review context'
        ($calls[4].arguments -join ' ') | Should Not Match 'Reviewer: examine the current work independently'
        ($calls[4].arguments -join ' ') | Should Not Match 'Architect: make'
        $state.RoleCalls[-1].CriticId | Should Be 'critic-0010'
        $saved = Read-ReviewLoopState $statePath
        $savedCritique = @($saved.RoleCalls | Where-Object Role -eq Critic)[0]
        $savedCritique.StructuredResult.reviewerFeedback | Should Be 'Reviewer: examine the current work independently.'
        $savedCritique.StructuredResult.architectFeedback | Should Be 'Architect: make coherent decisions.'
    }

    It "delivers only Fixer feedback on resumed calls and requalifies cached Fixer results" {
        $invokeFixer = {
            param($c, $s, $p, $r, $logs, $cli)
            Invoke-ConfiguredCodexRole -Config $c -Role Fixer -RepoPath $r -Speed standard `
                -Prompt 'Current fix' -LogRoot $logs -SchemaName fixer-result-v3.schema.json `
                -CallId fix -State $s -StatePath $p -CodexPath $cli
        }
        Invoke-CriticTestGate $config $state $statePath $repo $runRoot $fakeCodex
        $state.ActiveRoleCall = New-CriticTestPendingCall $state $repo Fixer fix fixer-thread
        & (Get-Module CodexReviewLoop) $invokeFixer $config $state $statePath $repo $runRoot $fakeCodex | Out-Null
        $state.RoleCalls[-1].CriticId | Should Be 'critic-0010'
        & (Get-Module CodexReviewLoop) $invokeFixer $config $state $statePath $repo $runRoot $fakeCodex | Out-Null
        Add-CriticTestReviews -State $state -From 11 -To 11
        Invoke-CriticTestGate $config $state $statePath $repo $runRoot $fakeCodex
        & (Get-Module CodexReviewLoop) $invokeFixer $config $state $statePath $repo $runRoot $fakeCodex | Out-Null
        # Inspect the ordinary role sequence; task clarification and overall judgment are covered separately.
        $calls = @(Get-Content $env:CODEX_REVIEW_LOOP_FAKE_LOG | ForEach-Object { $_ | ConvertFrom-Json } |
            Where-Object { $_.schemaPath -notmatch 'architecture-orientation' -and $_.phase -ne 'completion' })
        $calls.Count | Should Be 4
        $calls[1].callKind | Should Be 'resume'
        $calls[1].resumeThreadId | Should Be 'fixer-thread'
        Assert-CriticTestFeedbackDelivery $calls[1] 10 'Fixer: implement the agreed solution coherently.'
        Assert-CriticTestFeedbackDelivery $calls[3] 11 'Fixer: implement the agreed solution coherently.'
        foreach ($i in @(1, 3)) {
            ($calls[$i].arguments -join ' ') | Should Not Match 'Reviewer: examine|Architect: make'
        }
        $calls[2].prompt | Should Match 'Fixer: implement'
        $calls[2].prompt | Should Match 'Reviewer: examine'
        $calls[2].prompt | Should Match 'Architect: make'
        @($state.RoleCalls | Where-Object Role -eq Fixer | Select-Object -ExpandProperty CriticId) |
            Should Be @('critic-0010', 'critic-0011')
    }

    It "retains old two-recipient criticism without inventing Fixer feedback" {
        Invoke-CriticTestGate $config $state $statePath $repo $runRoot $fakeCodex
        $legacy = $state.RoleCalls[-1]
        $legacy.StructuredResult.PSObject.Properties.Remove('fixerFeedback')
        $legacy.StructuredResult.schemaVersion = '1.0'
        $before = $legacy.StructuredResult | ConvertTo-Json -Compress
        Write-ReviewLoopState $statePath $state | Out-Null
        $state = Read-ReviewLoopState $statePath
        & (Get-Module CodexReviewLoop) {
            param($c, $s, $p, $r, $logs, $cli)
            Invoke-ConfiguredCodexRole -Config $c -Role Fixer -RepoPath $r -Speed standard `
                -Prompt 'Fix' -LogRoot $logs -SchemaName fixer-result-v3.schema.json `
                -CallId legacy-fix -State $s -StatePath $p -CodexPath $cli | Out-Null
            Invoke-ConfiguredCodexRole -Config $c -Role Architect -RepoPath $r -Speed standard `
                -Prompt 'Advice' -LogRoot $logs -SchemaName architecture-advice-v3.schema.json `
                -CallId legacy-advice -State $s -StatePath $p -CodexPath $cli | Out-Null
        } $config $state $statePath $repo $runRoot $fakeCodex
        # Inspect the ordinary role sequence; task clarification and overall judgment are covered separately.
        $calls = @(Get-Content $env:CODEX_REVIEW_LOOP_FAKE_LOG | ForEach-Object { $_ | ConvertFrom-Json } |
            Where-Object { $_.schemaPath -notmatch 'architecture-orientation' -and $_.phase -ne 'completion' })
        ($calls[1].arguments -join ' ') | Should Not Match 'Latest Critic feedback|Reviewer: examine|Architect: make'
        $calls[2].prompt | Should Match 'Architect: make'
        @($state.RoleCalls | Where-Object Role -eq Fixer)[0].CriticId | Should Be ''
        @($state.RoleCalls | Where-Object Role -eq Critic)[0].StructuredResult |
            ConvertTo-Json -Compress | Should Be $before
    }

    It "waits through unfinished phases and repeated assessments until the cycle boundary" {
        foreach ($stage in @('reviewing', 'reviewed', 'cluster_selected', 'strategy_ready', 'fixing',
            'fix_attempted', 'testing', 'tested', 'test_failed', 'verified', 'gate_failed',
            'commit_preparing', 'commit_pending', 'lessons_learned_analyzing')) {
            $state.Stage = $stage
            Invoke-CriticTestGate $config $state $statePath $repo $runRoot $fakeCodex
            Invoke-CriticTestGate $config $state $statePath $repo $runRoot $fakeCodex
        }
        Test-Path $env:CODEX_REVIEW_LOOP_FAKE_LOG | Should Be $false
        $state.Stage = 'fix_committed'
        Invoke-CriticTestGate $config $state $statePath $repo $runRoot $fakeCodex
        Invoke-CriticTestGate $config $state $statePath $repo $runRoot $fakeCodex
        @(Get-Content $env:CODEX_REVIEW_LOOP_FAKE_LOG).Count | Should Be 1
    }

    It "preserves and resumes an interrupted Architect with its new feedback" {
        Invoke-CriticTestGate $config $state $statePath $repo $runRoot $fakeCodex
        $state.ActiveRoleCall = New-CriticTestPendingCall $state $repo Architect advice
        $before = $state.ActiveRoleCall | ConvertTo-Json -Compress
        Invoke-CriticTestGate $config $state $statePath $repo $runRoot $fakeCodex
        ($state.ActiveRoleCall | ConvertTo-Json -Compress) | Should Be $before
        & (Get-Module CodexReviewLoop) {
            param($c, $s, $path, $r, $logs, $cli)
            Invoke-ConfiguredCodexRole -Config $c -Role Architect -RepoPath $r -Speed standard `
                -Prompt 'Advice' -LogRoot $logs -SchemaName architecture-advice-v3.schema.json `
                -CallId advice -State $s -StatePath $path -CodexPath $cli
        } $config $state $statePath $repo $runRoot $fakeCodex | Out-Null
        $last = Get-Content $env:CODEX_REVIEW_LOOP_FAKE_LOG | Select-Object -Last 1 | ConvertFrom-Json
        $last.callKind | Should Be 'resume'
        $last.resumeThreadId | Should Be 'interrupted-thread'
        Assert-CriticTestFeedbackDelivery $last 10 'Architect: make coherent decisions.'
        ($last.arguments -join ' ') | Should Not Match 'Reviewer: examine'
    }

    It "preserves dirty Fixer work and its checkpoint through a failed and resumed critique" {
        $state.ActiveFindingIds = @('owned-finding')
        $state.Stage = 'fixing'
        $state.ActiveRoleCall = New-CriticTestPendingCall $state $repo Fixer fix
        Set-Content (Join-Path $repo 'README.txt') 'unfinished fixer patch'
        $state.ActiveCriticCall = New-CriticTestPendingCall $state $repo Critic critic-0010
        $before = $state.ActiveRoleCall | ConvertTo-Json -Compress
        $env:CODEX_REVIEW_LOOP_FAKE_EXIT_CODE = '1'
        $env:CODEX_REVIEW_LOOP_FAKE_STDERR = 'technical failure'
        (Test-ReliabilityThrows { Invoke-CriticTestGate $config $state $statePath $repo $runRoot $fakeCodex }) | Should Be $true
        ($state.ActiveRoleCall | ConvertTo-Json -Compress) | Should Be $before
        $state.Stage | Should Be 'fixing'
        $state.RoleCalls[-1].Success | Should Be $false
        $criticThread = $state.ActiveCriticCall.ThreadId
        $criticThread | Should Not BeNullOrEmpty
        $env:CODEX_REVIEW_LOOP_FAKE_EXIT_CODE = ''
        $env:CODEX_REVIEW_LOOP_FAKE_STDERR = ''
        Invoke-CriticTestGate $config $state $statePath $repo $runRoot $fakeCodex
        ($state.ActiveRoleCall | ConvertTo-Json -Compress) | Should Be $before
        (Get-Content (Join-Path $repo 'README.txt')) | Should Be 'unfinished fixer patch'
        $state.RoleCalls[-1].CoveredReviewCount | Should Be 10
        $last = Get-Content $env:CODEX_REVIEW_LOOP_FAKE_LOG | Select-Object -Last 1 | ConvertFrom-Json
        $last.callKind | Should Be 'resume'
        $last.resumeThreadId | Should Be $criticThread
        $saved = Read-ReviewLoopState $statePath
        $saved.ActiveCriticCall | Should BeNullOrEmpty
        $saved.RoleCalls[-1].StructuredResult.reviewerFeedback | Should Not BeNullOrEmpty
        $saved.RoleCalls[-1].StructuredResult.architectFeedback | Should Not BeNullOrEmpty
        $saved.RoleCalls[-1].StructuredResult.fixerFeedback | Should Not BeNullOrEmpty
    }

    It "recovers an interrupted critique independently and does not repeat a saved success" {
        $state.ActiveRoleCall = New-CriticTestPendingCall $state $repo Architect advice
        $state.ActiveCriticCall = New-CriticTestPendingCall $state $repo Critic critic-0010 critic-thread
        $before = $state.ActiveRoleCall | ConvertTo-Json -Compress
        Write-ReviewLoopState $statePath $state | Out-Null
        $state = Read-ReviewLoopState $statePath
        Invoke-CriticTestGate $config $state $statePath $repo $runRoot $fakeCodex
        $state = Read-ReviewLoopState $statePath
        Invoke-CriticTestGate $config $state $statePath $repo $runRoot $fakeCodex
        # Inspect the ordinary role sequence; task clarification and overall judgment are covered separately.
        $calls = @(Get-Content $env:CODEX_REVIEW_LOOP_FAKE_LOG | ForEach-Object { $_ | ConvertFrom-Json } |
            Where-Object { $_.schemaPath -notmatch 'architecture-orientation' -and $_.phase -ne 'completion' })
        $calls.Count | Should Be 1
        $calls[0].callKind | Should Be 'resume'
        $calls[0].resumeThreadId | Should Be 'critic-thread'
        ($state.ActiveRoleCall | ConvertTo-Json -Compress) | Should Be $before
        $state.ActiveCriticCall | Should BeNullOrEmpty
    }

    It "rejects unrelated dirty work before starting the Critic" {
        Set-Content (Join-Path $repo 'unrelated.txt') 'user work'
        (Test-ReliabilityThrows { Invoke-CriticTestGate $config $state $statePath $repo $runRoot $fakeCodex }) | Should Be $true
        Test-Path $env:CODEX_REVIEW_LOOP_FAKE_LOG | Should Be $false
        (Get-Content (Join-Path $repo 'unrelated.txt')) | Should Be 'user work'
    }

    It "discards a Critic mutation and accepts its feedback exactly once" {
        $env:CODEX_REVIEW_LOOP_FAKE_MUTATE_ON_SCHEMA = 'critic-v2.schema.json'
        Invoke-CriticTestGate $config $state $statePath $repo $runRoot $fakeCodex
        Invoke-CriticTestGate $config $state $statePath $repo $runRoot $fakeCodex
        @($state.RoleCalls | Where-Object Role -eq 'Critic').Count | Should Be 1
        $state.RoleCalls[-1].StructuredResult.fixerFeedback | Should Not BeNullOrEmpty
        Test-Path (Join-Path $repo 'fake-review-loop-change.test.txt') | Should Be $false
        $state.ActiveCriticCall | Should BeNullOrEmpty
        (& git -C $repo status --porcelain | Out-String).Trim() | Should Be ''
    }

    It "restores overwritten deleted and binary Fixer files after a failed Critic" {
        $state.Stage = 'fixing'
        $state.ActiveFindingIds = @('owned-finding')
        $state.ActiveRoleCall = New-CriticTestPendingCall $state $repo Fixer fix
        Set-Content (Join-Path $repo 'README.txt') 'unfinished fixer patch'
        Remove-Item -LiteralPath (Join-Path $repo 'review-loop-test.proj')
        $binaryPath = Join-Path $repo 'unfinished.bin'
        [System.IO.File]::WriteAllBytes($binaryPath, [byte[]](0, 255, 128, 13, 10))
        $state.ActiveCriticCall = New-CriticTestPendingCall $state $repo Critic critic-0010
        $before = $state.ActiveRoleCall | ConvertTo-Json -Compress
        $planPath = Join-Path $case.Root 'critic-mutations.json'
        Write-ReliabilityJsonArray -Path $planPath -Values @([pscustomobject]@{
            exitCode = 1
            mutations = @(
                @{ path = 'README.txt'; content = 'critic overwrite' },
                @{ path = 'review-loop-test.proj'; content = 'critic recreation' },
                @{ path = 'unfinished.bin'; delete = $true },
                @{ path = 'critic-only.txt'; content = 'disposable' })
        })
        $env:CODEX_REVIEW_LOOP_FAKE_INVOCATION_SEQUENCE = $planPath
        $env:CODEX_REVIEW_LOOP_FAKE_EXIT_CODE = '1'
        (Test-ReliabilityThrows { Invoke-CriticTestGate $config $state $statePath $repo $runRoot $fakeCodex }) | Should Be $true
        ($state.ActiveRoleCall | ConvertTo-Json -Compress) | Should Be $before
        (Get-Content (Join-Path $repo 'README.txt')) | Should Be 'unfinished fixer patch'
        Test-Path (Join-Path $repo 'review-loop-test.proj') | Should Be $false
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($binaryPath)) | Should Be 'AP+ADQo='
        Test-Path (Join-Path $repo 'critic-only.txt') | Should Be $false
        $state.ActiveCriticCall.RepositoryBackup | Should Not BeNullOrEmpty
        $thread = $state.ActiveCriticCall.ThreadId
        $env:CODEX_REVIEW_LOOP_FAKE_EXIT_CODE = ''
        $state = Read-ReviewLoopState $statePath
        Invoke-CriticTestGate $config $state $statePath $repo $runRoot $fakeCodex
        $last = Get-Content $env:CODEX_REVIEW_LOOP_FAKE_LOG | Select-Object -Last 1 | ConvertFrom-Json
        $last.resumeThreadId | Should Be $thread
        $state.RoleCalls[-1].Success | Should Be $true
        ($state.ActiveRoleCall | ConvertTo-Json -Compress) | Should Be $before
    }

    It "recovers a backed-up interrupted Critic branch commit refs and index before public resume" {
        $branch = & git -C $repo branch --show-current
        & git -C $repo symbolic-ref refs/remotes/origin/HEAD "refs/heads/$branch"
        $state.ActiveCriticCall = New-CriticTestPendingCall $state $repo Critic critic-0010 preserved-critic-thread
        $state.ActiveCriticCall.ExecutionFingerprint = 'old-tool'
        & (Get-Module CodexReviewLoop) {
            param($r, $s, $p, $logs)
            $s.ActiveCriticCall | Add-Member -NotePropertyName RepositoryBackup -NotePropertyValue (
                New-ReviewLoopRepositoryBackup -RepoPath $r -LogRoot $logs)
            Write-ReviewLoopState -Path $p -State $s | Out-Null
            Set-ReviewLoopReviewerRecoveryLocator -RepoPath $r -StatePath $p
        } $repo $state $statePath $runRoot
        Set-Content (Join-Path $repo 'README.txt') 'critic commit'
        & git -C $repo add README.txt
        & git -C $repo commit -q -m 'disposable critic commit'
        & git -C $repo switch -q -c critic-other
        & git -C $repo tag critic-tag
        & git -C $repo symbolic-ref refs/remotes/origin/HEAD refs/heads/critic-other
        & git -C $repo update-index --assume-unchanged README.txt
        $result = Invoke-CodexReviewLoop -RepoPath $repo -ConfigPath $configPath -CodexPath $fakeCodex -Json
        $result.Status | Should Be 'completed'
        $result.StatePath | Should Be $statePath
        (& git -C $repo branch --show-current) | Should Be $branch
        (& git -C $repo rev-parse HEAD) | Should Be $state.CurrentHead
        (& git -C $repo for-each-ref --format='%(refname)' | Out-String) | Should Not Match 'critic-other|critic-tag'
        (& git -C $repo ls-files -v README.txt) | Should Be 'H README.txt'
        (& git -C $repo symbolic-ref refs/remotes/origin/HEAD) | Should Be "refs/heads/$branch"
        # Inspect the ordinary role sequence; task clarification and overall judgment are covered separately.
        $calls = @(Get-Content $env:CODEX_REVIEW_LOOP_FAKE_LOG | ForEach-Object { $_ | ConvertFrom-Json } |
            Where-Object { $_.schemaPath -notmatch 'architecture-orientation' -and $_.phase -ne 'completion' })
        $calls[0].callKind | Should Be 'resume'
        $calls[0].resumeThreadId | Should Be 'preserved-critic-thread'
        $saved = Read-ReviewLoopState $statePath
        @($saved.RoleCalls | Where-Object { $_.Role -eq 'Critic' -and $_.CallId -eq 'critic-0010' }).Count | Should Be 1
        $saved.ActiveCriticCall | Should BeNullOrEmpty
    }

    It "rejects incomplete structured feedback as a technical failure" {
        $env:CODEX_REVIEW_LOOP_FAKE_MUTATE_ON_SCHEMA = 'critic-v2.schema.json'
        $env:CODEX_REVIEW_LOOP_FAKE_RESULT = '{"schemaVersion":"2.0","reviewerFeedback":"Review.","architectFeedback":"Advice."}'
        (Test-ReliabilityThrows { Invoke-CriticTestGate $config $state $statePath $repo $runRoot $fakeCodex }) | Should Be $true
        @($state.RoleCalls | Where-Object { $_.Role -eq 'Critic' -and $_.Success }).Count | Should Be 0
        $state.ReviewCycle | Should Be 10
        Test-Path (Join-Path $repo 'fake-review-loop-change.test.txt') | Should Be $false
    }

    It "restores a legacy clean Critic index mutation before public resume" {
        $state.ActiveCriticCall = New-CriticTestPendingCall $state $repo Critic critic-0010 critic-thread
        Write-ReviewLoopState $statePath $state | Out-Null
        & git -C $repo update-index --assume-unchanged README.txt
        $result = Invoke-CodexReviewLoop -RepoPath $repo -ConfigPath $configPath -CodexPath $fakeCodex -Json
        $result.Status | Should Be 'completed'
        $result.StatePath | Should Be $statePath
        (& git -C $repo ls-files -v README.txt) | Should Be 'H README.txt'
        $saved = Read-ReviewLoopState $statePath
        @($saved.RoleCalls | Where-Object { $_.Role -eq 'Critic' -and $_.CallId -eq 'critic-0010' }).Count | Should Be 1
        $saved.ActiveCriticCall | Should BeNullOrEmpty
    }

    It "requalifies the newest completed run instead of an older Critic with or without a locator" {
        Set-Content $configPath ((Get-Content -Raw $configPath).Replace(
            'CleanPassesRequired = 2', "CriticStartAfterReviews = 0`n    CleanPassesRequired = 2"))
        $state.Status = 'failed'
        $state.CreatedAt = '2026-01-01T00:00:00+00:00'
        $state.ActiveCriticCall = New-CriticTestPendingCall $state $repo Critic critic-0010 old-critic-thread
        Write-ReviewLoopState $statePath $state | Out-Null
        $oldBytes = Get-Content -Raw $statePath
        Set-Content (Join-Path $repo 'README.txt') 'accepted newer work'
        & git -C $repo add README.txt
        & git -C $repo commit -q -m 'accepted newer work'
        $newHead = & git -C $repo rev-parse HEAD
        $newRoot = Join-Path $paths.ProfileRoot 'new-completed-generation'
        New-Item -ItemType Directory -Path $newRoot | Out-Null
        $newPath = Join-Path $newRoot 'run-v1.json'
        $new = New-ReviewLoopState -RepoPath $repo -ReviewBase HEAD -Speed standard `
            -RunRoot $newRoot -ReviewBaseCommit $state.ReviewBaseCommit -ExecutionFingerprint old-guidance
        $new.CreatedAt = '2026-01-02T00:00:00+00:00'
        $new.Status = 'completed'
        $new.Stage = 'completed'
        $new.CleanPasses = 2
        $new.CleanHead = $newHead
        Add-CriticTestReviews -State $new -From 1 -To 2
        Write-ReviewLoopState $newPath $new | Out-Null
        foreach ($useLocator in @($false, $true)) {
            if ($useLocator) {
                & (Get-Module CodexReviewLoop) {
                    param($r, $p)
                    Set-ReviewLoopReviewerRecoveryLocator -RepoPath $r -StatePath $p
                } $repo $statePath
            }
            $result = Invoke-CodexReviewLoop -RepoPath $repo -ConfigPath $configPath `
                -ReviewerInstructions "Updated review guidance $useLocator" -CodexPath $fakeCodex -Json
            $result.Status | Should Be 'completed'
            $result.StatePath | Should Be $newPath
            $result.CleanPasses | Should Be 2
            (& git -C $repo rev-parse HEAD) | Should Be $newHead
            (Get-Content (Join-Path $repo 'README.txt')) | Should Be 'accepted newer work'
            (Get-Content -Raw $statePath) | Should Be $oldBytes
        }
        # Inspect the ordinary role sequence; task clarification and overall judgment are covered separately.
        $calls = @(Get-Content $env:CODEX_REVIEW_LOOP_FAKE_LOG | ForEach-Object { $_ | ConvertFrom-Json } |
            Where-Object { $_.schemaPath -notmatch 'architecture-orientation' -and $_.phase -ne 'completion' })
        $calls.Count | Should Be 4
        @($calls | Where-Object callKind -eq 'review').Count | Should Be 4
        (Read-ReviewLoopState $newPath).ReviewCycle | Should Be 6
    }

    It "does not mutate Git or files when a legacy Critic identity cannot be recovered" {
        $pending = New-CriticTestPendingCall $state $repo Critic critic-0010
        Set-Content (Join-Path $repo 'README.txt') 'newer committed work'
        & git -C $repo add README.txt
        & git -C $repo commit -q -m 'newer work'
        & git -C $repo tag user-tag
        Set-Content (Join-Path $repo 'README.txt') 'uncommitted user work'
        & git -C $repo add README.txt
        Set-Content (Join-Path $repo 'user.txt') 'untracked user bytes'
        & (Get-Module CodexReviewLoop) {
            param($r, $p)
            $before = ConvertTo-ReviewLoopJsonCompact (Get-ReviewLoopRepositorySnapshot -RepoPath $r)
            $index = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $r '.git/index')))
            $failure = ''
            try { Invoke-ReviewLoopCriticRepositoryRecovery -RepoPath $r -Recovery $p }
            catch { $failure = $_.Exception.Message }
            $failure | Should Match 'original files were not backed up'
            (ConvertTo-ReviewLoopJsonCompact (Get-ReviewLoopRepositorySnapshot -RepoPath $r)) | Should Be $before
            [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $r '.git/index'))) | Should Be $index
        } $repo $pending
        (Get-Content (Join-Path $repo 'README.txt')) | Should Be 'uncommitted user work'
        (Get-Content (Join-Path $repo 'user.txt')) | Should Be 'untracked user bytes'
    }

    It "retains unknown legacy user and technical refs without cleaning files" {
        $pending = New-CriticTestPendingCall $state $repo Critic critic-0010
        foreach ($ref in @('refs/heads/user-branch', 'refs/tags/user-tag', 'refs/codex/turn-diffs/captures/test/base')) {
            & git -C $repo update-ref $ref $state.CurrentHead
            Set-Content (Join-Path $repo 'README.txt') 'preserved concurrent bytes'
            & (Get-Module CodexReviewLoop) {
                param($r, $p)
                $before = ConvertTo-ReviewLoopJsonCompact (Get-ReviewLoopRepositorySnapshot -RepoPath $r)
                $failure = ''
                try { Invoke-ReviewLoopCriticRepositoryRecovery -RepoPath $r -Recovery $p }
                catch { $failure = $_.Exception.Message }
                $failure | Should Match 'original files were not backed up'
                (ConvertTo-ReviewLoopJsonCompact (Get-ReviewLoopRepositorySnapshot -RepoPath $r)) | Should Be $before
            } $repo $pending
            (& git -C $repo show-ref --verify --hash $ref) | Should Be $state.CurrentHead
            (Get-Content (Join-Path $repo 'README.txt')) | Should Be 'preserved concurrent bytes'
            & git -C $repo update-ref -d $ref $state.CurrentHead
        }
    }

    It "checks legacy index reconstruction before modifying the actual index or files" {
        & git -C $repo update-index --assume-unchanged README.txt
        $pending = New-CriticTestPendingCall $state $repo Critic critic-0010
        & git -C $repo update-index --no-assume-unchanged README.txt
        Set-Content (Join-Path $repo 'README.txt') 'preserved file change'
        & (Get-Module CodexReviewLoop) {
            param($r, $p)
            $before = ConvertTo-ReviewLoopJsonCompact (Get-ReviewLoopRepositorySnapshot -RepoPath $r)
            $index = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $r '.git/index')))
            $failure = ''
            try { Invoke-ReviewLoopCriticRepositoryRecovery -RepoPath $r -Recovery $p }
            catch { $failure = $_.Exception.Message }
            $failure | Should Match 'original Critic index cannot be reconstructed'
            (ConvertTo-ReviewLoopJsonCompact (Get-ReviewLoopRepositorySnapshot -RepoPath $r)) | Should Be $before
            [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $r '.git/index'))) | Should Be $index
        } $repo $pending
        (Get-Content (Join-Path $repo 'README.txt')) | Should Be 'preserved file change'
    }

    It "retains an interrupted Critic when its required backup is corrupted" {
        $env:CODEX_REVIEW_LOOP_FAKE_EXIT_CODE = '1'
        (Test-ReliabilityThrows { Invoke-CriticTestGate $config $state $statePath $repo $runRoot $fakeCodex }) | Should Be $true
        $pending = $state.ActiveCriticCall | ConvertTo-Json -Depth 20 -Compress
        Set-Content (Join-Path $repo 'README.txt') 'critic leftovers'
        Set-Content (Join-Path $state.ActiveCriticCall.RepositoryBackup.Root 'index') 'corrupt'
        $env:CODEX_REVIEW_LOOP_FAKE_EXIT_CODE = ''
        $failure = ''
        try { Invoke-CriticTestGate $config $state $statePath $repo $runRoot $fakeCodex }
        catch { $failure = $_.Exception.Message }
        $failure | Should Match 'Critic recovery index failed its integrity check'
        (Get-Content (Join-Path $repo 'README.txt')) | Should Be 'critic leftovers'
        ($state.ActiveCriticCall | ConvertTo-Json -Depth 20 -Compress) | Should Be $pending
        @($state.RoleCalls | Where-Object { $_.Role -eq 'Critic' -and $_.Success }).Count | Should Be 0
    }

    It "preserves the staged and unstaged split and index flags of backed-up Fixer work" {
        Set-Content (Join-Path $repo 'README.txt') 'staged fixer version'
        & git -C $repo add README.txt
        Set-Content (Join-Path $repo 'README.txt') 'unstaged fixer version'
        & git -C $repo update-index --assume-unchanged review-loop-test.proj
        $pending = New-CriticTestPendingCall $state $repo Critic critic-0010
        & (Get-Module CodexReviewLoop) {
            param($r, $p, $logs)
            $p | Add-Member -NotePropertyName RepositoryBackup -NotePropertyValue (
                New-ReviewLoopRepositoryBackup -RepoPath $r -LogRoot $logs)
        } $repo $pending $runRoot
        Set-Content (Join-Path $repo 'README.txt') 'critic staged overwrite'
        & git -C $repo add README.txt
        Set-Content (Join-Path $repo 'staged-new.txt') 'critic staged addition'
        & git -C $repo add staged-new.txt
        & git -C $repo update-index --no-assume-unchanged review-loop-test.proj
        & (Get-Module CodexReviewLoop) {
            param($r, $p)
            Invoke-ReviewLoopCriticRepositoryRecovery -RepoPath $r -Recovery $p
            Invoke-ReviewLoopCriticRepositoryRecovery -RepoPath $r -Recovery $p
        } $repo $pending
        (Get-Content (Join-Path $repo 'README.txt')) | Should Be 'unstaged fixer version'
        (& git -C $repo show :README.txt) | Should Be 'staged fixer version'
        (& git -C $repo ls-files -v review-loop-test.proj) | Should Be 'h review-loop-test.proj'
        Test-Path (Join-Path $repo 'staged-new.txt') | Should Be $false
    }

    It "stops a resumed run on Critic timeout without resetting the interrupted Fixer" {
        $state.Stage = 'fixing'
        $state.ActiveFindingIds = @('owned-finding')
        $state.ActiveRoleCall = New-CriticTestPendingCall $state $repo Fixer fix
        Set-Content (Join-Path $repo 'README.txt') 'unfinished patch'
        $state.ActiveCriticCall = New-CriticTestPendingCall $state $repo Critic critic-0010
        $state.ActiveCriticCall | Add-Member -NotePropertyName SchemaName -NotePropertyValue critic-v1.schema.json
        Write-ReviewLoopState $statePath $state | Out-Null
        $env:CODEX_REVIEW_LOOP_FAKE_EXIT_CODE = '124'
        $result = Invoke-CodexReviewLoop -RepoPath $repo -ConfigPath $configPath -CodexPath $fakeCodex -Json
        $result.Status | Should Be 'failed'
        $result.Reason | Should Match 'Critic.*timeout'
        $saved = Read-ReviewLoopState $statePath
        $saved.Stage | Should Be 'fixing'
        $saved.ActiveRoleCall.Role | Should Be 'Fixer'
        $saved.ActiveCriticCall.SchemaName | Should Be 'critic-v2.schema.json'
        $saved.BlockedCleanup | Should BeNullOrEmpty
        @($saved.RoleCalls | Where-Object Role -eq 'Critic').Count | Should Be 1
        $saved.RoleCalls[-1].Attempts.Count | Should Be 3
        $saved.ReviewCycle | Should Be 10
        (Get-Content (Join-Path $repo 'README.txt')) | Should Be 'unfinished patch'
    }

    It "discards a legacy interrupted Critic index change while preserving Fixer file contents" {
        $state.ActiveFindingIds = @('owned-finding')
        $state.ActiveRoleCall = New-CriticTestPendingCall $state $repo Fixer fix
        Set-Content (Join-Path $repo 'README.txt') 'unfinished patch'
        $state.ActiveCriticCall = New-CriticTestPendingCall $state $repo Critic critic-0010
        & git -C $repo add README.txt
        Invoke-CriticTestGate $config $state $statePath $repo $runRoot $fakeCodex
        (& git -C $repo diff --cached --name-only | Out-String).Trim() | Should Be ''
        (Get-Content (Join-Path $repo 'README.txt')) | Should Be 'unfinished patch'
        $state.RoleCalls[-1].Success | Should Be $true
        $state.ActiveRoleCall.Role | Should Be 'Fixer'
    }

    It "finishes an interrupted native review after a tool update before new criticism" {
        $state.Stage = 'reviewing'
        $state.ReviewCycle = 11
        $state.ExecutionFingerprint = 'old-tool'
        Write-ReviewLoopState $statePath $state | Out-Null
        $result = Invoke-CodexReviewLoop -RepoPath $repo -ConfigPath $configPath -CodexPath $fakeCodex -Json
        $result.Status | Should Be 'completed'
        # Inspect the ordinary role sequence; task clarification and overall judgment are covered separately.
        $calls = @(Get-Content $env:CODEX_REVIEW_LOOP_FAKE_LOG | ForEach-Object { $_ | ConvertFrom-Json } |
            Where-Object { $_.schemaPath -notmatch 'architecture-orientation' -and $_.phase -ne 'completion' })
        $calls.Count | Should Be 3
        $calls[0].callKind | Should Be 'review'
        [IO.Path]::GetFileName($calls[1].schemaPath) | Should Be 'critic-v2.schema.json'
        $calls[2].callKind | Should Be 'review'
        $saved = Read-ReviewLoopState $statePath
        @($saved.RoleCalls | Where-Object Role -eq Critic)[0].CoveredReviewCount | Should Be 11
        $saved.ReviewCycle | Should Be 12
    }

    It "finishes a dirty interrupted Fixer and repeated assessment after a tool update before new criticism" {
        $ledger = New-ReviewLoopLedger -RepoPath $repo
        Merge-ReviewLoopFindings -Ledger $ledger -Findings @((New-ReliabilityFinding)) `
            -ReviewId review-10 -Head $state.CurrentHead | Out-Null
        $finding = $ledger.Findings[0]
        $finding.Status = 'fixing'
        $finding.FixAttempts = 1
        $finding.FixerThreadId = 'preserved-fixer-thread'
        Write-ReviewLoopLedger -Path $paths.LedgerPath -Ledger $ledger | Out-Null
        $state.Stage = 'fixing'
        $state.ExecutionFingerprint = 'old-tool'
        $state.ActiveClusterId = $finding.ClusterId
        $state.ActiveFindingIds = @($finding.Id)
        $state.ActiveReviewText = 'Fix the reliability defect.'
        $state.ActiveRoleCall = New-CriticTestPendingCall $state $repo Fixer fix preserved-fixer-thread
        $state.ActiveRoleCall.ExecutionFingerprint = 'old-tool'
        Set-Content (Join-Path $repo 'README.txt') 'preserved unfinished work'
        Write-ReviewLoopState $statePath $state | Out-Null
        $sequencePath = Join-Path $case.Root 'updated-fixer-results.json'
        Write-ReliabilityJsonArray -Path $sequencePath -Values @(
            '{"schemaVersion":"3.0","summary":"Finished preserved work.","targetedTest":{"available":true,"executable":"pwsh","arguments":["-NoProfile","-Command","exit 0"]}}',
            '{"schemaVersion":"1.0","accept":false,"summary":"One correction remains.","feedback":["Complete the agreed solution."],"commitMessage":{"subject":"Finish preserved work","rationale":"Correction needed.","changes":["Finish the interrupted fix."]}}',
            '{"schemaVersion":"3.0","summary":"Corrected preserved work.","targetedTest":{"available":true,"executable":"pwsh","arguments":["-NoProfile","-Command","exit 0"]}}',
            '{"schemaVersion":"1.0","accept":true,"summary":"Accepted preserved work.","feedback":[],"commitMessage":{"subject":"Finish preserved work","rationale":"Current checks passed.","changes":["Finish the interrupted fix."]}}',
            '{"schemaVersion":"2.0","reviewerFeedback":"Reviewer: examine the work.","architectFeedback":"Architect: make coherent decisions.","fixerFeedback":"Fixer: keep focused."}',
            'No actionable findings.',
            '{"schemaVersion":"2.0","reviewerFeedback":"Reviewer: examine the work.","architectFeedback":"Architect: make coherent decisions.","fixerFeedback":"Fixer: keep focused."}',
            'No actionable findings.'
        )
        $env:CODEX_REVIEW_LOOP_FAKE_RESULT_SEQUENCE = $sequencePath

        $result = Invoke-CodexReviewLoop -RepoPath $repo -ConfigPath $configPath -CodexPath $fakeCodex -Json

        $result.Status | Should Be 'completed'
        # Inspect the ordinary role sequence; task clarification and overall judgment are covered separately.
        $calls = @(Get-Content $env:CODEX_REVIEW_LOOP_FAKE_LOG | ForEach-Object { $_ | ConvertFrom-Json } |
            Where-Object { $_.schemaPath -notmatch 'architecture-orientation' -and $_.phase -ne 'completion' })
        [IO.Path]::GetFileName($calls[0].schemaPath) | Should Be 'fixer-result-v3.schema.json'
        $calls[0].callKind | Should Be 'resume'
        $calls[0].resumeThreadId | Should Be 'preserved-fixer-thread'
        [IO.Path]::GetFileName($calls[1].schemaPath) | Should Be 'architecture-assessment-v2.schema.json'
        [IO.Path]::GetFileName($calls[2].schemaPath) | Should Be 'fixer-result-v3.schema.json'
        [IO.Path]::GetFileName($calls[3].schemaPath) | Should Be 'architecture-assessment-v2.schema.json'
        [IO.Path]::GetFileName($calls[4].schemaPath) | Should Be 'critic-v2.schema.json'
        ($calls[1].arguments -join ' ') | Should Not Match 'Architect: make'
        (Get-Content (Join-Path $repo 'README.txt')) | Should Be 'preserved unfinished work'
        (& git -C $repo status --porcelain) | Should BeNullOrEmpty
        (Read-ReviewLoopLedger -Path $paths.LedgerPath).Findings[0].Status | Should Be 'resolved'
    }
}

Describe "Unattended process reliability boundaries" -Tags @("Process") {
    BeforeEach {
        $case = New-ReliabilityTestCase
        $caseRoot = $case.Root
        $repo = $case.Repo
        $logRoot = $case.LogRoot
        $configPath = $case.ConfigPath
        & (Get-Module CodexReviewLoop) { Initialize-ReviewLoopConsole -TranscriptPath "" -HostOutputEnabled $false }
    }

    AfterEach {
        Clear-ReliabilityTestCase
    }

    It "ignores personal config for exec and resume" {
        $calls = @(
            ,@(Get-CodexRoleArguments -RepoPath $repo -Model m -Thinking low)
            ,@(Get-CodexRoleArguments -RepoPath $repo -Model m -Thinking low -Mode Resume -ThreadId t)
        )
        foreach ($arguments in $calls) {
            @($arguments | Where-Object { $_ -eq "--ignore-user-config" }).Count | Should Be 1
            @($arguments | Where-Object { $_ -eq "--ignore-rules" }).Count | Should Be 1
            @($arguments | Where-Object { $_ -eq "--yolo" }).Count | Should Be 1
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
        (@($records[0].arguments) -contains "--yolo") | Should Be $true
        (@($records[1].arguments) -contains "--yolo") | Should Be $true
        @($records | Where-Object { @($_.arguments) -contains "--sandbox" }).Count | Should Be 0
    }

    It "rejects worktree changes made by an analysis role with full command access" {
        $config = Import-PowerShellDataFile -LiteralPath $configPath
        $env:CODEX_REVIEW_LOOP_FAKE_MUTATE_ON_SCHEMA = "architecture-advice-v3.schema.json"
        $message = ""
        try {
            & (Get-Module CodexReviewLoop) {
                param($profile, $repository, $logs, $fake)
                Invoke-ConfiguredCodexRole -Config $profile -Role Architect -RepoPath $repository `
                    -Speed standard -Prompt review -LogRoot $logs -CodexPath $fake `
                    -SchemaName "architecture-advice-v3.schema.json"
            } $config $repo $logRoot $fakeCodex | Out-Null
        }
        catch {
            $message = $_.Exception.Message
        }

        $message | Should Match "changed repository state"
        (& git -C $repo status --porcelain=v1) | Should Not BeNullOrEmpty
    }

    It "rejects worktree changes made by the Architect assessment" {
        $config = Import-PowerShellDataFile -LiteralPath $configPath
        $env:CODEX_REVIEW_LOOP_FAKE_MUTATE_ON_SCHEMA = "architecture-assessment-v2.schema.json"
        $message = ""
        try {
            & (Get-Module CodexReviewLoop) {
                param($profile, $repository, $logs, $fake)
                Invoke-ConfiguredCodexRole -Config $profile -Role Architect -RepoPath $repository `
                    -Speed standard -Prompt assess -LogRoot $logs -CodexPath $fake `
                    -SchemaName "architecture-assessment-v2.schema.json"
            } $config $repo $logRoot $fakeCodex | Out-Null
        }
        catch {
            $message = $_.Exception.Message
        }

        $message | Should Match "changed repository state"
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
            -SchemaPath (Join-Path $root "schemas\architecture-advice-v3.schema.json")

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
            -SchemaPath (Join-Path $root "schemas\architecture-advice-v3.schema.json")
        $call.Success | Should Be $true
        $call.StructuredResult.summary | Should Be "advice"
        $records = @(Get-Content -LiteralPath $env:CODEX_REVIEW_LOOP_FAKE_LOG |
            ForEach-Object { $_ | ConvertFrom-Json })
        $records[1].callKind | Should Be "resume"
    }

    It "corrects incomplete acceptance before success and before completed-cache reuse" {
        $module = Get-Module CodexReviewLoop
        $config = Import-PowerShellDataFile -LiteralPath $configPath
        $statePath = Join-Path $caseRoot 'state.json'
        $state = New-ReviewLoopState -RepoPath $repo -ReviewBase HEAD -Speed standard `
            -ReviewBaseCommit (& git -C $repo rev-parse HEAD) -RunRoot $logRoot
        & $module {
            param($s)
            Merge-ReviewLoopWorkOrders -State $s -Orders @([pscustomobject]@{
                id='QUALIFICATION'; objective='Verify the candidate'; rationale='Acceptance evidence';
                doneWhen='Candidate tests and source bindings agree'; evidence=@('README.md')
            })
            $s.ActiveWorkIds = @('QUALIFICATION')
        } $state
        $workBefore = $state.ArchitectWork | ConvertTo-Json -Depth 30 -Compress
        $invalid = [ordered]@{
            schemaVersion='2.0'; accept=$true; summary='Candidate assessed'; feedback=@();
            commitMessage=@{subject='Verify candidate'; rationale='Evidence'; changes=@('Verified')};
            newOrders=@(); workOutcomes=@(); goalComplete=$false
        }
        $invalidText = $invalid | ConvertTo-Json -Depth 15 -Compress
        $invalid.workOutcomes = @(@{id='QUALIFICATION'; status='accepted'; evidence='Tests and source bindings agree'})
        $validText = $invalid | ConvertTo-Json -Depth 15 -Compress
        $sequence = Join-Path $caseRoot 'assessment-results.json'
        Write-ReliabilityJsonArray -Path $sequence -Values @($invalidText, $validText, $validText)
        $env:CODEX_REVIEW_LOOP_FAKE_RESULT_SEQUENCE = $sequence
        $invoke = {
            param($c,$s,$p,$r,$logs,$fake)
            Invoke-ConfiguredCodexRole -Config $c -Role Architect -RepoPath $r -Speed standard `
                -Prompt 'Assess selected work' -LogRoot $logs -CodexPath $fake `
                -SchemaName 'architecture-assessment-v2.schema.json' -CallId assessment `
                -State $s -StatePath $p
        }
        $first = & $module $invoke $config $state $statePath $repo $logRoot $fakeCodex
        $first.Success | Should Be $true
        $first.Attempts.Count | Should Be 2
        $first.Attempts[0].ExitCode | Should Be 4
        $first.Attempts[0].FailureKind | Should Be 'invalid_structured_output'
        ($state.ArchitectWork | ConvertTo-Json -Depth 30 -Compress) | Should Be $workBefore
        $record = $state.RoleCalls[-1]
        $record.StructuredResult = $invalidText | ConvertFrom-Json
        $cachedBefore = $record | ConvertTo-Json -Depth 30 -Compress
        $originalHash = (Get-FileHash $record.ResultPath).Hash
        $second = & $module $invoke $config $state $statePath $repo $logRoot $fakeCodex
        $second.Success | Should Be $true
        $second.ResultPath | Should Not Be $record.ResultPath
        ($record | ConvertTo-Json -Depth 30 -Compress) | Should Be $cachedBefore
        (Get-FileHash $record.ResultPath).Hash | Should Be $originalHash
        ($state.ArchitectWork | ConvertTo-Json -Depth 30 -Compress) | Should Be $workBefore
        $third = & $module $invoke $config $state $statePath $repo $logRoot $fakeCodex
        $third.ResultPath | Should Be $second.ResultPath
        $records = @(Get-Content $env:CODEX_REVIEW_LOOP_FAKE_LOG | ForEach-Object { $_ | ConvertFrom-Json })
        $records.Count | Should Be 3
        $records[1].callKind | Should Be 'resume'
        $records[2].callKind | Should Be 'resume'
        $records[2].prompt | Should Match 'explicitly assess every selected'
        $records[2].prompt | Should Match "final run exit remain the orchestrator's obligations"
        @($state.ArchitectWork.Orders | Where-Object status -ne 'open').Count | Should Be 0
    }

    It "corrects orientation plan and completion semantics before success and cache reuse" {
        $module=Get-Module CodexReviewLoop
        $config=Import-PowerShellDataFile -LiteralPath $configPath
        foreach($kind in @('orientation','plan','goal')){
            $state=New-ReviewLoopState -RepoPath $repo -ReviewBase HEAD -Speed standard `
                -ReviewBaseCommit (& git -C $repo rev-parse HEAD) -RunRoot $logRoot
            & $module {
                param($s)
                Merge-ReviewLoopWorkOrders -State $s -Orders @([pscustomobject]@{
                    id='CLOSED';objective='Original work';rationale='Evidence';doneWhen='Verified';evidence=@('README.md')
                })
                $s.ArchitectWork.Orders[0].status='accepted'
            } $state
            $statePath=Join-Path $caseRoot "$kind-state.json"
            $order=@{id='CLOSED';objective='New work';rationale='New evidence';doneWhen='Verified';evidence=@('README.md')}
            $newOrder=$order.Clone();$newOrder.id='NEW'
            switch($kind){
                orientation {
                    $schema='architecture-orientation-v1.schema.json'
                    $invalid=@{schemaVersion='1.0';goal=@{statement='Clarified goal';sources=@('README.md');uncertainties=@()};orders=@($order)}
                    $valid=$invalid.Clone();$valid.orders=@($newOrder)
                }
                plan {
                    $schema='architecture-advice-v3.schema.json'
                    $invalid=@{schemaVersion='3.0';summary='Plan';approach='Address new work';steps=@();considerations=@();orders=@($order);selectedWorkIds=@('CLOSED')}
                    $valid=$invalid.Clone();$valid.orders=@($newOrder);$valid.selectedWorkIds=@('NEW')
                }
                goal {
                    $schema='architecture-assessment-v2.schema.json'
                    $invalid=@{schemaVersion='2.0';accept=$false;summary='Remaining work';feedback=@();commitMessage=@{subject='';rationale='';changes=@()};newOrders=@();workOutcomes=@();goalComplete=$false}
                    $valid=$invalid.Clone();$valid.newOrders=@($newOrder)
                }
            }
            $invalidText=$invalid|ConvertTo-Json -Depth 20 -Compress
            $validText=$valid|ConvertTo-Json -Depth 20 -Compress
            $sequence=Join-Path $caseRoot "$kind-results.json"
            $phase=if($kind -eq 'orientation'){'orientation'}else{''}
            Write-ReliabilityJsonArray -Path $sequence -Values @(
                @{phase=$phase;result=$invalidText}, @{phase=$phase;result=$validText},
                @{phase=$phase;result=$validText})
            $env:CODEX_REVIEW_LOOP_FAKE_INVOCATION_SEQUENCE=$sequence
            $invoke={
                param($c,$s,$p,$r,$logs,$fake,$schema,$kind)
                Invoke-ConfiguredCodexRole -Config $c -Role Architect -RepoPath $r -Speed standard `
                    -Prompt 'Assess current task' -LogRoot $logs -CodexPath $fake -SchemaName $schema `
                    -CallId "boundary-$kind" -State $s -StatePath $p `
                    -RequireWorkSelection:($kind -eq 'plan') -RequireGoalDecision:($kind -eq 'goal')
            }
            $workBefore=$state.ArchitectWork|ConvertTo-Json -Depth 30 -Compress
            $first=& $module $invoke $config $state $statePath $repo $logRoot $fakeCodex $schema $kind
            $first.Success|Should Be $true
            if ($first.Attempts.Count -ne 2) {
                throw "$kind expected semantic correction; attempts=$($first.Attempts.Count); result=$($first.FinalMessage); work=$workBefore"
            }
            $first.Attempts.Count|Should Be 2
            $first.Attempts[0].ExitCode|Should Be 4
            $first.Attempts[0].FailureKind|Should Be 'invalid_structured_output'
            ($state.ArchitectWork|ConvertTo-Json -Depth 30 -Compress)|Should Be $workBefore
            $state.ActiveWorkIds.Count|Should Be 0
            $record=$state.RoleCalls[-1]
            # Simulate a schema-valid legacy checkpoint before semantic validation existed.
            $record.StructuredResult=$invalidText|ConvertFrom-Json
            $record.FinalMessage=$invalidText
            [IO.File]::WriteAllText($record.ResultPath,$invalidText,[Text.UTF8Encoding]::new($false))
            $recordBefore=$record|ConvertTo-Json -Depth 30 -Compress
            $oldHash=(Get-FileHash $record.ResultPath).Hash
            $second=& $module $invoke $config $state $statePath $repo $logRoot $fakeCodex $schema $kind
            $second.Success|Should Be $true
            $second.ResultPath|Should Not Be $record.ResultPath
            ($record|ConvertTo-Json -Depth 30 -Compress)|Should Be $recordBefore
            (Get-FileHash $record.ResultPath).Hash|Should Be $oldHash
            ($state.ArchitectWork|ConvertTo-Json -Depth 30 -Compress)|Should Be $workBefore
            $third=& $module $invoke $config $state $statePath $repo $logRoot $fakeCodex $schema $kind
            $third.ResultPath|Should Be $second.ResultPath
            & $module {
                param($s,$r,$kind)
                switch($kind){
                    orientation {Register-ReviewLoopOrientation -State $s -Result $r}
                    plan {Register-ReviewLoopWorkPlan -State $s -Result $r -RequireSelection}
                    goal {Register-ReviewLoopWorkAssessment -State $s -Result $r -RequireGoalDecision}
                }
            } $state $second.StructuredResult $kind
            $state.ArchitectWork.Orders[0].status|Should Be 'accepted'
            @($state.ArchitectWork.Orders|Where-Object id -eq NEW).Count|Should Be 1
            if($kind -eq 'plan'){$state.ActiveWorkIds|Should Be @('NEW')}
        }
        $records=@(Get-Content $env:CODEX_REVIEW_LOOP_FAKE_LOG|ForEach-Object{$_|ConvertFrom-Json})
        $records.Count|Should Be 9
        @($records|Where-Object callKind -eq resume).Count|Should Be 6
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

}

Describe "Fixer ref identity evidence and resume" -Tags @("GitSafety", "GitSafetyA") {
    BeforeEach {
        $case = New-ReliabilityTestCase
        $repo = $case.Repo
        $logRoot = $case.LogRoot
        New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
        $statePath = Join-Path $logRoot 'run-v1.json'
        $state = New-ReviewLoopState -RepoPath $repo -ReviewBase HEAD -Speed standard -RunRoot $logRoot
        & (Get-Module CodexReviewLoop) { Initialize-ReviewLoopConsole -TranscriptPath "" -HostOutputEnabled $false }
    }
    AfterEach { Clear-ReliabilityTestCase }

    It "captures exact complete rows with the unchanged legacy fingerprint" {
        $branch = (& git -C $repo symbolic-ref HEAD | Out-String).Trim()
        & git -C $repo symbolic-ref refs/remotes/origin/HEAD $branch
        & (Get-Module CodexReviewLoop) {
            param($r, $logs)
            $snapshot = Get-ReviewLoopRepositorySnapshot $r
            $native = @(& git -C $r for-each-ref '--format=%(refname) %(objectname) %(symref)')
            ($snapshot.Refs -join "`n") | Should Be ($native -join "`n")
            $legacy = @(& git -C $r for-each-ref '--format=%(refname) %(objectname)')
            $snapshot.RefsFingerprint | Should Be (Get-ReviewLoopSha256 (@($legacy | Sort-Object) -join "`n"))
            Assert-ReviewLoopFixerRepositoryIdentity -Before $snapshot -After (Get-ReviewLoopRepositorySnapshot $r) -LogRoot $logs -CallId unchanged
            Test-Path (Join-Path $logs 'unchanged-repository-identity-failure.json') | Should Be $false
        } $repo $logRoot
    }

    It "rejects HEAD, symbolic HEAD, user branch, tag and technical ref changes with exact public deltas" {
        Set-Content (Join-Path $repo 'README.txt') 'preserved fixer candidate'
        foreach ($ref in @('refs/heads/user-branch', 'refs/tags/user-tag', 'refs/codex/turn-diffs/captures/test/base')) {
            $before = & (Get-Module CodexReviewLoop) { param($r) Get-ReviewLoopRepositorySnapshot $r } $repo
            & git -C $repo update-ref $ref $before.Head
            $after = & (Get-Module CodexReviewLoop) { param($r) Get-ReviewLoopRepositorySnapshot $r } $repo
            & (Get-Module CodexReviewLoop) {
                param($a, $b, $logs)
                $failure = ''
                try { Assert-ReviewLoopFixerRepositoryIdentity -Before $a -After $b -LogRoot $logs -CallId mutation }
                catch { $failure = $_.Exception.Message }
                $failure | Should Match 'Fixer changed HEAD or Git refs'
            } $before $after $logRoot
            $proof = Get-Content -Raw (Join-Path $logRoot 'mutation-repository-identity-failure.json') | ConvertFrom-Json
            ($proof.ChangedFields -join ',') | Should Be 'RefsFingerprint,Refs'
            ($proof.Before.Refs -join "`n") | Should Be ($before.Refs -join "`n")
            ($proof.After.Refs -join "`n") | Should Be ($after.Refs -join "`n")
            $proof.RefDelta.Count | Should Be 1
            $proof.RefDelta[0].Change | Should Be 'Added'
            $proof.RefDelta[0].Row | Should Be (@($after.Refs | Where-Object { $_ -clike "$ref *" })[0])
            (Get-Content (Join-Path $repo 'README.txt')) | Should Be 'preserved fixer candidate'
        }
        $before = & (Get-Module CodexReviewLoop) { param($r) Get-ReviewLoopRepositorySnapshot $r } $repo
        & git -C $repo symbolic-ref HEAD refs/heads/user-branch
        & (Get-Module CodexReviewLoop) {
            param($r, $a, $logs)
            $failure = ''
            try { Assert-ReviewLoopFixerRepositoryIdentity -Before $a -After (Get-ReviewLoopRepositorySnapshot $r) -LogRoot $logs -CallId symbolic }
            catch { $failure = $_.Exception.Message }
            $failure | Should Match 'Changed fields: HeadRef'
        } $repo $before $logRoot
        $proof = Get-Content -Raw (Join-Path $logRoot 'symbolic-repository-identity-failure.json') | ConvertFrom-Json
        ($proof.ChangedFields -join ',') | Should Be 'HeadRef'
        $before = & (Get-Module CodexReviewLoop) { param($r) Get-ReviewLoopRepositorySnapshot $r } $repo
        & git -C $repo add README.txt
        & git -C $repo commit -q -m 'actual head movement'
        & (Get-Module CodexReviewLoop) {
            param($r, $a, $logs)
            $failure = ''
            try { Assert-ReviewLoopFixerRepositoryIdentity -Before $a -After (Get-ReviewLoopRepositorySnapshot $r) -LogRoot $logs -CallId head }
            catch { $failure = $_.Exception.Message }
            $failure | Should Match 'Changed fields: Head'
        } $repo $before $logRoot
        $proof = Get-Content -Raw (Join-Path $logRoot 'head-repository-identity-failure.json') | ConvertFrom-Json
        ($proof.ChangedFields -contains 'Head') | Should Be $true
        (Get-Content (Join-Path $repo 'README.txt')) | Should Be 'preserved fixer candidate'
    }

    It "refuses and persists a pending ref violation before starting a resumed Fixer after tool change" {
        $state.Stage = 'fixing'
        $state.ActiveRoleCall = New-CriticTestPendingCall $state $repo Fixer fixer-identity
        $state.ActiveRoleCall.ExecutionFingerprint = 'old-tool'
        $start = & (Get-Module CodexReviewLoop) { param($r) Get-ReviewLoopRepositorySnapshot $r } $repo
        $state.ActiveRoleCall | Add-Member RepositoryRefs $start.Refs
        Set-Content (Join-Path $repo 'README.txt') 'preserved dirty candidate'
        Set-Content (Join-Path $repo 'new-candidate.txt') 'preserved new candidate'
        & git -C $repo tag unexpected-tag
        Write-ReviewLoopState $statePath $state | Out-Null
        $config = Import-PowerShellDataFile $case.ConfigPath
        $config['__ExecutionFingerprint'] = 'updated-tool'
        & (Get-Module CodexReviewLoop) {
            param($c, $s, $r, $logs, $path, $fake)
            $failure = ''
            try { Invoke-ConfiguredCodexRole -Config $c -Role Fixer -RepoPath $r -Speed standard -Prompt 'Continue' -LogRoot $logs -SchemaName fixer-result-v3.schema.json -CallId fixer-identity -State $s -StatePath $path -CodexPath $fake }
            catch { $failure = $_.Exception.Message }
            $failure | Should Match 'Fixer changed HEAD or Git refs'
        } $config $state $repo $logRoot $statePath $fakeCodex
        $saved = Read-ReviewLoopState $statePath
        $failure = $saved.ActiveRoleCall.RepositoryIdentityFailure
        $failure.Sha256 | Should Be (Get-FileHash $failure.Path -Algorithm SHA256).Hash
        $proof = Get-Content -Raw $failure.Path | ConvertFrom-Json
        $proof.BeforeInventoryAvailable | Should Be $true
        $proof.RefDelta.Count | Should Be 1
        Test-Path $env:CODEX_REVIEW_LOOP_FAKE_LOG | Should Be $false
        # Even restoring the tag externally must not erase the persisted violation.
        & git -C $repo tag -d unexpected-tag | Out-Null
        & (Get-Module CodexReviewLoop) {
            param($c, $s, $r, $logs, $path, $fake)
            $failure = ''
            try { Invoke-ConfiguredCodexRole -Config $c -Role Fixer -RepoPath $r -Speed standard -Prompt 'Continue' -LogRoot $logs -SchemaName fixer-result-v3.schema.json -CallId fixer-identity -State $s -StatePath $path -CodexPath $fake }
            catch { $failure = $_.Exception.Message }
            $failure | Should Match 'Unresolved Fixer repository identity violation'
        } $config $saved $repo $logRoot $statePath $fakeCodex
        (Get-Content (Join-Path $repo 'README.txt')) | Should Be 'preserved dirty candidate'
        (Get-Content (Join-Path $repo 'new-candidate.txt')) | Should Be 'preserved new candidate'
        (Get-FileHash $failure.Path -Algorithm SHA256).Hash | Should Be $failure.Sha256
        Test-Path $env:CODEX_REVIEW_LOOP_FAKE_LOG | Should Be $false
    }

    It "does not invent missing legacy ref inventory rows" {
        $before = & (Get-Module CodexReviewLoop) {
            param($r) Get-ReviewLoopRepositorySnapshot $r | Select-Object Head, HeadRef, RefsFingerprint
        } $repo
        & git -C $repo tag legacy-unknown
        & (Get-Module CodexReviewLoop) {
            param($r, $a, $logs)
            $failure = ''
            try { Assert-ReviewLoopFixerRepositoryIdentity -Before $a -After (Get-ReviewLoopRepositorySnapshot $r) -LogRoot $logs -CallId legacy }
            catch { $failure = $_.Exception.Message }
            $failure | Should Match 'Fixer changed HEAD or Git refs'
        } $repo $before $logRoot
        $proof = Get-Content -Raw (Join-Path $logRoot 'legacy-repository-identity-failure.json') | ConvertFrom-Json
        $proof.BeforeInventoryAvailable | Should Be $false
        $proof.Before.Refs | Should BeNullOrEmpty
        $proof.RefDelta | Should BeNullOrEmpty
        $proof.AfterInventoryAvailable | Should Be $true
        (& git -C $repo show-ref --verify --hash refs/tags/legacy-unknown) | Should Be $before.Head
    }

    It "detects a symbolic technical ref retarget even with identical object IDs and fingerprint" {
        $head = $state.CurrentHead
        & git -C $repo update-ref refs/heads/target-a $head
        & git -C $repo update-ref refs/heads/target-b $head
        & git -C $repo symbolic-ref refs/codex/symbolic refs/heads/target-a
        $before = & (Get-Module CodexReviewLoop) { param($r) Get-ReviewLoopRepositorySnapshot $r } $repo
        & git -C $repo symbolic-ref refs/codex/symbolic refs/heads/target-b
        $after = & (Get-Module CodexReviewLoop) { param($r) Get-ReviewLoopRepositorySnapshot $r } $repo
        $after.RefsFingerprint | Should Be $before.RefsFingerprint
        $failure = ''
        try { & (Get-Module CodexReviewLoop) { param($a,$b,$logs) Assert-ReviewLoopFixerRepositoryIdentity -Before $a -After $b -LogRoot $logs -CallId symbolic-same-object } $before $after $logRoot }
        catch { $failure = $_.Exception.Message }
        $failure | Should Match 'Changed fields: Refs'
        $proof = Get-Content -Raw (Join-Path $logRoot 'symbolic-same-object-repository-identity-failure.json') | ConvertFrom-Json -DateKind String
        ($proof.ChangedFields -join ',') | Should Be 'Refs'
        $proof.RefDelta.Count | Should Be 2
        $proof.RefDelta[0].Row | Should Be "refs/codex/symbolic $head refs/heads/target-a"
        $proof.RefDelta[1].Row | Should Be "refs/codex/symbolic $head refs/heads/target-b"
    }
}

Describe "Explicit external ref requalification" -Tags @("GitSafety", "GitSafetyA") {
    $global:RefRecoveryOriginalWrite = & (Get-Module CodexReviewLoop) { ${function:Write-ReviewLoopState} }
    BeforeEach {
        $case = New-ReliabilityTestCase
        $repo = $case.Repo
        $runRoot = & (Get-Module CodexReviewLoop) {
            param($configPath,$r)
            $config = Import-ReviewLoopConfig -ConfigPath $configPath -RepoPath $r
            $config.ReviewBase = Get-ReviewLoopGitValue $r @('rev-parse', 'HEAD')
            $paths = New-ReviewLoopRunPaths -Config $config -RepoPath $r
            Initialize-ReviewLoopRunPaths -Paths $paths | Out-Null
            $paths.RunRoot
        } $case.ConfigPath $repo
        New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
        $statePath = Join-Path $runRoot 'run-v1.json'
        $packagePath = Join-Path $case.Root 'approval.json'
        & (Get-Module CodexReviewLoop) {
            param($r, $logs, $path, $approval)
            Initialize-ReviewLoopConsole -TranscriptPath '' -HostOutputEnabled $false
            $base = Get-ReviewLoopGitValue $r @('rev-parse', 'HEAD')
            & git -C $r update-ref refs/codex/capture/old $base
            & git -C $r update-ref refs/codex/checkpoint/old $base
            $s = New-ReviewLoopState -RepoPath $r -ReviewBase $base -ReviewBaseCommit $base -Speed standard -RunRoot $logs
            $start = Get-ReviewLoopRepositorySnapshot $r
            $s.Stage = 'fixing'; $s.ActiveClusterId = 'cluster'; $s.ActiveFindingIds = @('F1'); $s.ActiveWorkIds = @('W1')
            Merge-ReviewLoopWorkOrders -State $s -Orders @([pscustomobject]@{
                id='W1'; objective='Preserve the candidate'; rationale='The public contract remains mandatory'
                doneWhen='Current review and gates accept the exact candidate'; evidence=@('README.txt')
            })
            $s.ArchitectWork.OrientationRequired = $false
            $s.ArchitectWork.Goal = [pscustomobject]@{statement='Preserve the candidate';sources=@('README.txt');uncertainties=@()}
            $s.ActiveRoleCall = [pscustomobject]@{
                Role = 'Fixer'; CallId = 'failed-fixer'; RepositoryHead = $start.Head
                RepositoryHeadRef = $start.HeadRef; RefsFingerprint = $start.RefsFingerprint; RepositoryRefs = $start.Refs
            }
            Set-Content (Join-Path $r 'README.txt') 'preserved edited bytes'
            & git -C $r add README.txt
            Set-Content (Join-Path $r 'new.txt') 'preserved untracked bytes'
            & git -C $r update-ref -d refs/codex/capture/old
            & git -C $r update-ref -d refs/codex/checkpoint/old
            & git -C $r update-ref refs/codex/capture/new $base
            & git -C $r update-ref refs/codex/checkpoint/new $base
            try { Assert-ReviewLoopFixerRepositoryIdentity -Before $start -After (Get-ReviewLoopRepositorySnapshot $r) -LogRoot $logs -CallId failed-fixer -State $s -StatePath $path }
            catch { if ($_.Exception.Message -notmatch 'Fixer changed HEAD') { throw } }
            $s.Status = 'failed'; $s.Stage = 'stopped'; $s.ExitCode = 2
            Write-ReviewLoopState $path $s | Out-Null
            $ledger = Join-Path (Split-Path -Parent $logs) 'ledger-v2.json'
            $findingLedger = New-ReviewLoopLedger -RepoPath $r
            $finding = ConvertTo-ReviewLoopFindingRecord -Finding ([pscustomobject]@{
                title='[P1] candidate defect';description='Preserve the public contract';locations=@([pscustomobject]@{path='README.txt';line=1})
            }) -ReviewId old-review -Head $base
            $finding.Id = 'F1'
            $findingLedger.Findings = @($finding)
            Write-ReviewLoopLedger -Path $ledger -Ledger $findingLedger | Out-Null
            $lease = Get-ReviewLoopGitValue $r @('rev-parse', '--git-path', 'codex-review-loop.lock')
            if (-not [IO.Path]::IsPathRooted($lease)) { $lease = Join-Path $r $lease }
            [IO.File]::WriteAllBytes($lease, [byte[]]@())
            $actor = Join-Path $logs 'independent-actor.json'
            Write-ReviewLoopAtomicJson $actor ([pscustomobject]@{ ClosedTurnId = 'actual-external-turn'; ObservedAt = '2026-10-12T04:50:35Z' })
            $role = Join-Path $logs 'failed-fixer.jsonl'
            Set-Content $role '{"type":"turn.completed"}'
            $proof = Get-Content -Raw $s.ActiveRoleCall.RepositoryIdentityFailure.Path | ConvertFrom-Json -DateKind String
            $package = [pscustomobject]@{
                SchemaVersion = '1.0'; OperatorApproved = $true; RepoPath = $r; RunId = $s.RunId
                CallId = 'failed-fixer'; ReviewBaseCommit = $base
                StateSha256 = (Get-FileHash $path -Algorithm SHA256).Hash
                Failure = $s.ActiveRoleCall.RepositoryIdentityFailure; ApprovedRefDelta = $proof.RefDelta
                Candidate = Get-ReviewLoopRepositorySnapshot $r
                ExternalActorEvidence = @([pscustomobject]@{ Path = $actor; Sha256 = (Get-FileHash $actor -Algorithm SHA256).Hash })
                RoleEvidence = @([pscustomobject]@{ Path = $role; Sha256 = (Get-FileHash $role -Algorithm SHA256).Hash })
                Ledger = [pscustomobject]@{ Path = $ledger; Sha256 = (Get-FileHash $ledger -Algorithm SHA256).Hash }
            }
            Write-ReviewLoopAtomicJson $approval $package
        } $repo $runRoot $statePath $packagePath
        $state = Read-ReviewLoopState $statePath
        $package = Get-Content -Raw $packagePath | ConvertFrom-Json -DateKind String
        $stateHash = (Get-FileHash $statePath -Algorithm SHA256).Hash
        $failureHash = $package.Failure.Sha256
    }
    AfterEach {
        & (Get-Module CodexReviewLoop) { Set-Item Function:script:Write-ReviewLoopState -Value $global:RefRecoveryOriginalWrite }
        Clear-ReliabilityTestCase
    }

    It "dry-runs without checkpoint writes or model calls and returns exact candidate pins" {
        $package.Candidate = $null; $package.StateSha256 = ''
        $package | ConvertTo-Json -Depth 100 | Set-Content $packagePath
        $result = Invoke-CodexReviewLoop -RepoPath $repo -ConfigPath $case.ConfigPath -RequalifyExternalRefChange $packagePath -RequalificationDryRun -Json
        $result.ExitCode | Should Be 0
        $result.Status | Should Be 'requalification_ready'
        $result.CandidateApproved | Should Be $false
        $result.StateSha256 | Should Be $stateHash
        $current = & (Get-Module CodexReviewLoop) { param($r) Get-ReviewLoopRepositorySnapshot $r } $repo
        ($result.Candidate.Refs -join "`n") | Should Be ($current.Refs -join "`n")
        (Get-FileHash $statePath -Algorithm SHA256).Hash | Should Be $stateHash
        Test-Path $env:CODEX_REVIEW_LOOP_FAKE_LOG | Should Be $false
        Test-Path (Join-Path $runRoot 'repository-backups') | Should Be $false
    }

    It "atomically preserves candidate, ledger, work orders and original failure for fresh review" {
        $result = & (Get-Module CodexReviewLoop) { param($s,$p,$r,$e) Invoke-ReviewLoopExternalRefRequalification $s $p $r $e } $state $statePath $repo $packagePath
        $result.Status | Should Be 'requalified'
        $saved = Read-ReviewLoopState $statePath
        $saved.Stage | Should Be 'review_round_requested'
        $saved.ActiveRoleCall | Should BeNullOrEmpty
        $saved.CompletionRequalificationRequired | Should Be $true
        $saved.RetainedCandidate.FixerResult.Success | Should Be $false
        $saved.RetainedCandidate.FixerResult.StructuredResult | Should BeNullOrEmpty
        $saved.RetainedCandidate.FindingIds[0] | Should Be 'F1'
        $saved.RetainedCandidate.WorkIds[0] | Should Be 'W1'
        $saved.ArchitectWork.Orders[0].id | Should Be 'W1'
        (Get-FileHash $package.Ledger.Path -Algorithm SHA256).Hash | Should Be $package.Ledger.Sha256
        (Get-FileHash $package.Failure.Path -Algorithm SHA256).Hash | Should Be $failureHash
        (Get-Content (Join-Path $repo 'README.txt')) | Should Be 'preserved edited bytes'
        (Get-Content (Join-Path $repo 'new.txt')) | Should Be 'preserved untracked bytes'
        & (Get-Module CodexReviewLoop) { param($r,$c) Assert-ReviewLoopRepositoryUnchanged $r $c 'preserved candidate' } $repo $package.Candidate
        Test-Path $env:CODEX_REVIEW_LOOP_FAKE_LOG | Should Be $false
    }

    It "is idempotent after acknowledgement without another state transition" {
        & (Get-Module CodexReviewLoop) { param($s,$p,$r,$e) Invoke-ReviewLoopExternalRefRequalification $s $p $r $e } $state $statePath $repo $packagePath | Out-Null
        $saved = Read-ReviewLoopState $statePath
        $afterHash = (Get-FileHash $statePath -Algorithm SHA256).Hash
        $result = & (Get-Module CodexReviewLoop) { param($s,$p,$r,$e) Invoke-ReviewLoopExternalRefRequalification $s $p $r $e } $saved $statePath $repo $packagePath
        $result.Status | Should Be 'already_requalified'
        (Get-FileHash $statePath -Algorithm SHA256).Hash | Should Be $afterHash
        @((Read-ReviewLoopState $statePath).ExternalRefRequalifications).Count | Should Be 1
    }

    It "refuses extra branch, tag, technical ref and HEAD changes before state writes" {
        foreach ($ref in @('refs/heads/unapproved','refs/tags/unapproved','refs/codex/unapproved')) {
            & git -C $repo update-ref $ref $state.CurrentHead
            $failure = ''
            try { & (Get-Module CodexReviewLoop) { param($s,$p,$r,$e) Invoke-ReviewLoopExternalRefRequalification $s $p $r $e } $state $statePath $repo $packagePath }
            catch { $failure = $_.Exception.Message }
            $failure | Should Match 'Current full repository identity differs'
            (Get-FileHash $statePath -Algorithm SHA256).Hash | Should Be $stateHash
            & git -C $repo update-ref -d $ref
        }
        & git -C $repo commit -q -m 'unapproved head'
        $failure = ''
        try { & (Get-Module CodexReviewLoop) { param($s,$p,$r,$e) Invoke-ReviewLoopExternalRefRequalification $s $p $r $e } $state $statePath $repo $packagePath }
        catch { $failure = $_.Exception.Message }
        $failure | Should Match 'Current full repository identity differs'
        (Get-FileHash $statePath -Algorithm SHA256).Hash | Should Be $stateHash
    }

    It "refuses candidate file and index changes and absent approval without writes" {
        foreach ($kind in @('file','index','approval')) {
            if ($kind -eq 'file') { Set-Content (Join-Path $repo 'new.txt') 'unapproved content' }
            if ($kind -eq 'index') { & git -C $repo add new.txt }
            if ($kind -eq 'approval') { $package.OperatorApproved = $false; $package | ConvertTo-Json -Depth 100 | Set-Content $packagePath }
            $failure = ''
            try { & (Get-Module CodexReviewLoop) { param($s,$p,$r,$e) Invoke-ReviewLoopExternalRefRequalification $s $p $r $e } $state $statePath $repo $packagePath }
            catch { $failure = $_.Exception.Message }
            $failure | Should Not BeNullOrEmpty
            (Get-FileHash $statePath -Algorithm SHA256).Hash | Should Be $stateHash
            if ($kind -eq 'file') { Set-Content (Join-Path $repo 'new.txt') 'preserved untracked bytes' }
            if ($kind -eq 'index') { & git -C $repo reset -q HEAD -- new.txt }
        }
    }

    It "refuses forged delta and missing actor, role or legacy inventory proofs" {
        foreach ($kind in @('delta','actor','role','legacy')) {
            $attempt = Get-Content -Raw $packagePath | ConvertFrom-Json -DateKind String
            if ($kind -eq 'delta') { $attempt.ApprovedRefDelta[0].Row += 'forged' }
            if ($kind -eq 'actor') { $attempt.ExternalActorEvidence[0].Sha256 = '0' * 64 }
            if ($kind -eq 'role') { $attempt.RoleEvidence = @() }
            if ($kind -eq 'legacy') { $state.ActiveRoleCall.RepositoryRefs = $null }
            $attemptPath = Join-Path $case.Root "approval-$kind.json"
            $attempt | ConvertTo-Json -Depth 100 | Set-Content $attemptPath
            $failure = ''
            try { & (Get-Module CodexReviewLoop) { param($s,$p,$r,$e) Invoke-ReviewLoopExternalRefRequalification $s $p $r $e } $state $statePath $repo $attemptPath }
            catch { $failure = $_.Exception.Message }
            $failure | Should Not BeNullOrEmpty
            (Get-FileHash $statePath -Algorithm SHA256).Hash | Should Be $stateHash
            Test-Path (Join-Path $runRoot 'repository-backups') | Should Be $false
        }
    }

    It "ordinary resume refuses the persisted failure before initialization or models" {
        $result = Invoke-CodexReviewLoop -RepoPath $repo -ConfigPath $case.ConfigPath -CodexPath $fakeCodex -Json
        $result.ExitCode | Should Be 2
        $result.Reason | Should Match 'Unresolved Fixer repository identity violation'
        (Get-FileHash $statePath -Algorithm SHA256).Hash | Should Be $stateHash
        Test-Path $env:CODEX_REVIEW_LOOP_FAKE_LOG | Should Be $false
    }

    It "requires separately bound approval of an exact intervening delta and rejects any further ref" {
        & git -C $repo update-ref -d refs/codex/checkpoint/new
        & git -C $repo update-ref refs/codex/checkpoint/later $state.CurrentHead
        $current = & (Get-Module CodexReviewLoop) { param($r) Get-ReviewLoopRepositorySnapshot $r } $repo
        $failure = Get-Content -Raw $package.Failure.Path | ConvertFrom-Json -DateKind String
        $laterDelta = & (Get-Module CodexReviewLoop) { param($a,$b) @(Get-ReviewLoopRefDelta $a $b) } $failure.After.Refs $current.Refs
        $package | Add-Member ApprovedInterveningRefDelta @($laterDelta)
        $package.Candidate = $current
        $package | ConvertTo-Json -Depth 100 | Set-Content $packagePath
        $unbound = Invoke-CodexReviewLoop -RepoPath $repo -ConfigPath $case.ConfigPath -RequalifyExternalRefChange $packagePath -Json
        $unbound.Reason | Should Match 'Independent intervening-actor evidence'
        (Get-FileHash $statePath -Algorithm SHA256).Hash | Should Be $stateHash
        $actorPath = Join-Path $case.Root 'independent-later-actor.json'
        Set-Content $actorPath '{"closedOwnerTurn":"independently-observed-later-turn"}'
        $package | Add-Member InterveningActorEvidence @([pscustomobject]@{Path=$actorPath;Sha256=(Get-FileHash $actorPath -Algorithm SHA256).Hash})
        $package | ConvertTo-Json -Depth 100 | Set-Content $packagePath
        & git -C $repo update-ref refs/tags/still-unapproved $state.CurrentHead
        $extra = Invoke-CodexReviewLoop -RepoPath $repo -ConfigPath $case.ConfigPath -RequalifyExternalRefChange $packagePath -Json
        $extra.Reason | Should Match 'differs from the exact approved intervening delta'
        (Get-FileHash $statePath -Algorithm SHA256).Hash | Should Be $stateHash
        & git -C $repo update-ref -d refs/tags/still-unapproved
        $approved = Invoke-CodexReviewLoop -RepoPath $repo -ConfigPath $case.ConfigPath -RequalifyExternalRefChange $packagePath -Json
        $approved.Status | Should Be 'requalified'
        @($approved.ApprovedInterveningRefDelta).Count | Should Be 2
        (Get-FileHash $package.Failure.Path -Algorithm SHA256).Hash | Should Be $failureHash
    }

    It "does not create a missing lease in a public dry run" {
        $lease = Join-Path $repo '.git/codex-review-loop.lock'
        Remove-Item -LiteralPath $lease
        $result = Invoke-CodexReviewLoop -RepoPath $repo -ConfigPath $case.ConfigPath -RequalifyExternalRefChange $packagePath -RequalificationDryRun -Json
        $result.ExitCode | Should Be 2
        Test-Path $lease | Should Be $false
        (Get-FileHash $statePath -Algorithm SHA256).Hash | Should Be $stateHash
        Test-Path $env:CODEX_REVIEW_LOOP_FAKE_LOG | Should Be $false
    }

    It "rejects missing or empty mandatory snapshot bindings at the shared boundary" {
        foreach ($snapshot in @([pscustomobject]@{}, [pscustomobject]@{Head=$state.CurrentHead}, [pscustomobject]@{Head='';Fingerprint=''})) {
            $failure = ''
            try { & (Get-Module CodexReviewLoop) { param($r,$s) Assert-ReviewLoopRepositoryUnchanged $r $s 'mandatory snapshot' } $repo $snapshot }
            catch { $failure = $_.Exception.Message }
            $failure | Should Match 'complete mandatory repository snapshot'
        }
    }

    It "recovers interruption before the atomic checkpoint write without losing the candidate" {
        $global:RefRecoveryInterrupt = $true
        & (Get-Module CodexReviewLoop) {
            Set-Item Function:script:Write-ReviewLoopState -Value {
                param($Path,$State)
                if ($global:RefRecoveryInterrupt) { throw 'simulated before atomic write' }
                & $global:RefRecoveryOriginalWrite -Path $Path -State $State
            }
        }
        $first = Invoke-CodexReviewLoop -RepoPath $repo -ConfigPath $case.ConfigPath -RequalifyExternalRefChange $packagePath -Json
        $first.ExitCode | Should Be 2
        $first.Reason | Should Match 'simulated before atomic write'
        (Get-FileHash $statePath -Algorithm SHA256).Hash | Should Be $stateHash
        @((Read-ReviewLoopState $statePath).ActiveFindingIds)[0] | Should Be 'F1'
        $global:RefRecoveryInterrupt = $false
        $second = Invoke-CodexReviewLoop -RepoPath $repo -ConfigPath $case.ConfigPath -RequalifyExternalRefChange $packagePath -Json
        $second.Status | Should Be 'requalified'
        (Get-FileHash $package.Failure.Path -Algorithm SHA256).Hash | Should Be $failureHash
        (Get-Content (Join-Path $repo 'new.txt')) | Should Be 'preserved untracked bytes'
    }

    It "recognizes interruption after the atomic write as acknowledged without repeating it" {
        $global:RefRecoveryWrites = 0
        & (Get-Module CodexReviewLoop) {
            Set-Item Function:script:Write-ReviewLoopState -Value {
                param($Path,$State)
                $global:RefRecoveryWrites++
                & $global:RefRecoveryOriginalWrite -Path $Path -State $State
                throw 'simulated after atomic write'
            }
        }
        $first = Invoke-CodexReviewLoop -RepoPath $repo -ConfigPath $case.ConfigPath -RequalifyExternalRefChange $packagePath -Json
        $first.ExitCode | Should Be 2
        $first.Reason | Should Match 'simulated after atomic write'
        $afterHash = (Get-FileHash $statePath -Algorithm SHA256).Hash
        $second = Invoke-CodexReviewLoop -RepoPath $repo -ConfigPath $case.ConfigPath -RequalifyExternalRefChange $packagePath -Json
        $second.Status | Should Be 'already_requalified'
        $global:RefRecoveryWrites | Should Be 1
        (Get-FileHash $statePath -Algorithm SHA256).Hash | Should Be $afterHash
        (Read-ReviewLoopState $statePath).RetainedCandidate.FixerResult.Success | Should Be $false
    }

    It "publicly requalifies then resumes through fresh native review, Architect, gates and clean passes" {
        # Host gates require a clean index. Pin this successful workflow fixture
        # after unstaging; the separate preservation case covers staged bytes.
        & git -C $repo reset -q HEAD -- README.txt
        $package.Candidate = & (Get-Module CodexReviewLoop) { param($r) Get-ReviewLoopRepositorySnapshot $r } $repo
        $package | ConvertTo-Json -Depth 100 | Set-Content $packagePath
        $gateMarker = Join-Path $case.Root 'host-gate.txt'
        $gate = "HostGates = @(@{ Name = 'recovery-gate'; FilePath = 'pwsh'; Arguments = @('-NoProfile', '-Command', 'Set-Content -LiteralPath ''$gateMarker'' -Value checked; exit 0') })"
        (Get-Content -Raw $case.ConfigPath).Replace('HostGates = @()', $gate).Replace('LessonsLearnedCommitThreshold = 6','LessonsLearnedCommitThreshold = 0') | Set-Content $case.ConfigPath
        $result = Invoke-CodexReviewLoop -RepoPath $repo -ConfigPath $case.ConfigPath -RequalifyExternalRefChange $packagePath -Json
        $result.Status | Should Be 'requalified'
        Test-Path $env:CODEX_REVIEW_LOOP_FAKE_LOG | Should Be $false
        Test-Path $gateMarker | Should Be $false
        $env:CODEX_REVIEW_LOOP_FAKE_INVOCATION_SEQUENCE = Join-Path $case.Root 'plans.json'
        $plans = @(
            @{result='No findings.'},
            @{result='{"schemaVersion":"3.0","summary":"Freshly assess preserved progress","approach":"Check the public contract","steps":[],"considerations":[],"orders":[],"selectedWorkIds":["W1"]}'},
            @{result='{"schemaVersion":"3.0","summary":"Preserved contract","targetedTest":{"available":false,"executable":"","arguments":[]}}'},
            @{result='{"schemaVersion":"2.0","accept":true,"summary":"Fresh candidate accepted","feedback":[],"commitMessage":{"subject":"Preserve contract","rationale":"Fresh review and gates","changes":["Preserve candidate"]},"newOrders":[],"workOutcomes":[{"id":"W1","status":"accepted","evidence":"Current contract checked"}],"goalComplete":true}'},
            @{result='No findings.'}, @{result='No findings.'}
        )
        Write-ReliabilityJsonArray -Path $env:CODEX_REVIEW_LOOP_FAKE_INVOCATION_SEQUENCE -Values $plans
        $resumed = Invoke-CodexReviewLoop -RepoPath $repo -ConfigPath $case.ConfigPath -ReviewerInstructions 'Prüfe A29 gemäß Paketkarte.' -CodexPath $fakeCodex -Json
        if ($resumed.Status -ne 'completed') {
            Write-Host ($resumed | ConvertTo-Json -Depth 20)
            $failedState = Read-ReviewLoopState $statePath
            Write-Host ($failedState | Select-Object Stage, Status, ExitCode, ActiveRoleCall, RoleCalls | ConvertTo-Json -Depth 30)
        }
        $resumed.Reason | Should Be ''
        $resumed.Status | Should Be 'completed'
        $resumed.CleanPasses | Should Be 2
        $saved = Read-ReviewLoopState $statePath
        $saved.RunId | Should Be $state.RunId
        $saved.ArchitectWork.Orders[0].id | Should Be 'W1'
        $saved.ArchitectWork.Orders[0].status | Should Be 'accepted'
        $saved.RetainedCandidate | Should BeNullOrEmpty
        $saved.CurrentHead | Should Not Be $state.CurrentHead
        Test-Path $gateMarker | Should Be $true
        $calls = @(Get-Content $env:CODEX_REVIEW_LOOP_FAKE_LOG | ForEach-Object { $_ | ConvertFrom-Json -DateKind String })
        $calls[0].callKind | Should Be 'review'
        @($calls | Where-Object callKind -eq review).Count | Should Be 3
        @($calls | Where-Object schemaPath -match 'assessment-v2').Count | Should Be 1
        $saved.ExternalRefRequalifications[0].FailedCall.CallId | Should Be 'failed-fixer'
        (Get-FileHash $package.Failure.Path -Algorithm SHA256).Hash | Should Be $failureHash
        @((Read-ReviewLoopLedger -Path $package.Ledger.Path -RepoPath $repo).Findings | Where-Object Id -eq F1).Count | Should Be 1
    }
}

Describe "Unattended Git and recovery reliability boundaries" `
    -Tags @("GitSafety", "GitSafetyA") {
    BeforeEach {
        $case = New-ReliabilityTestCase
        $caseRoot = $case.Root
        $repo = $case.Repo
        $logRoot = $case.LogRoot
        $configPath = $case.ConfigPath
        & (Get-Module CodexReviewLoop) { Initialize-ReviewLoopConsole -TranscriptPath "" -HostOutputEnabled $false }
    }

    AfterEach {
        Clear-ReliabilityTestCase
    }

    It "continues when an idempotent Git value command fails transiently" {
        $alias = @'
!f() { if test -f .git/review-loop-flaky; then echo recovered; exit 0; fi; echo first >.git/review-loop-flaky; echo first-failure >&2; exit 17; }; f
'@
        & git -C $repo config alias.review-loop-flaky $alias.Trim()

        $value = & (Get-Module CodexReviewLoop) {
            param($repository)
            Get-ReviewLoopGitValue `
                -RepoPath $repository -Arguments @("review-loop-flaky")
        } $repo

        $value | Should Be "recovered"
        Test-Path -LiteralPath (Join-Path $repo ".git/review-loop-flaky") |
            Should Be $true
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
        $runRoot = Join-Path $caseRoot "targeted-success"
        New-Item -ItemType Directory -Path $runRoot | Out-Null
        $statePath = Join-Path $runRoot "run-v1.json"
        $state = New-ReviewLoopState -RepoPath $repo -ReviewBase HEAD -Speed standard -RunRoot $runRoot
        Write-ReviewLoopState -Path $statePath -State $state | Out-Null
        $config = Import-PowerShellDataFile -LiteralPath $configPath
        $module = Get-Module CodexReviewLoop
        $result = & $module {
            param($profile, $loopState, $loopStatePath, $value, $repository, $logs)
            Invoke-ReviewLoopTargetedTests `
                -Config $profile -State $loopState -StatePath $loopStatePath `
                -FixerResult $value -RepoPath $repository `
                -RunRoot $logs -ClusterId custom -Attempt 1
        } $config $state $statePath $fixer $repo $runRoot
        $result.Success | Should Be $true
        $fixer.testExecution.Passed | Should Be $true
    }

    It "includes staged and untracked files in assessment evidence" {
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
        ($records[0].arguments -join " ") | Should Not Match "Current shared task"

        $replayed = & (Get-Module CodexReviewLoop) {
            param($profile, $loopState, $loopStatePath, $loopLedger, $repository, $logs, $fake)
            Invoke-ReviewLoopReview -Config $profile -State $loopState -StatePath $loopStatePath `
                -Ledger $loopLedger -RepoPath $repository -Speed standard -RunRoot $logs -CodexPath $fake
        } $config $state $statePath $ledger $repo $runRoot $fakeCodex
        $replayed.Result.text | Should Be $review.Result.text
        @((Get-Content -LiteralPath $env:CODEX_REVIEW_LOOP_FAKE_LOG)).Count | Should Be 1
        @((Read-ReviewLoopState -Path $statePath).RoleCalls).Count | Should Be 1
    }

    It "silently removes an untracked file left by the native Reviewer" {
        $planPath = Join-Path $caseRoot "reviewer-mutation.json"
        Write-ReliabilityJsonArray -Path $planPath -Values @(
            [pscustomobject]@{
                result = "No actionable findings."
                mutations = @([pscustomobject]@{
                    path = "tmp-reviewer-output.txt"
                    content = "temporary review output"
                })
            },
            [pscustomobject]@{ result = "No actionable findings." }
        )
        $env:CODEX_REVIEW_LOOP_FAKE_INVOCATION_SEQUENCE = $planPath

        $result = Invoke-CodexReviewLoop -RepoPath $repo -ConfigPath $configPath `
            -CodexPath $fakeCodex -HeartbeatSeconds 0 -ColorMode Never

        $result.Status | Should Be "completed"
        Test-Path -LiteralPath (Join-Path $repo "tmp-reviewer-output.txt") |
            Should Be $false
        (& git -C $repo status --porcelain=v1 | Out-String).Trim() | Should Be ""
        (Get-Content -Raw -LiteralPath (Join-Path $result.RunRoot "terminal.log")) |
            Should Not Match "Reviewer cleanup|tmp-reviewer-output"
    }

    It "restores tracked staged deleted and untracked Reviewer changes" {
        $snapshot = & (Get-Module CodexReviewLoop) {
            param($repository)
            Get-ReviewLoopRepositorySnapshot -RepoPath $repository
        } $repo
        Set-Content -LiteralPath (Join-Path $repo "README.txt") -Value "reviewer edit"
        [System.IO.File]::Delete((Join-Path $repo "review-loop-test.proj"))
        Set-Content -LiteralPath (Join-Path $repo "staged.txt") -Value "staged"
        Set-Content -LiteralPath (Join-Path $repo "untracked.txt") -Value "untracked"
        & git -C $repo add README.txt review-loop-test.proj staged.txt

        & (Get-Module CodexReviewLoop) {
            param($repository, $baseline)
            Restore-ReviewLoopReviewerRepository -RepoPath $repository -Recovery ([pscustomobject]@{
                RepositoryHead = [string]$baseline.Head
                WorktreeFingerprint = [string]$baseline.Fingerprint
                RepositoryBranch = [string]$baseline.Branch
                RepositoryHeadRef = [string]$baseline.HeadRef
            })
        } $repo $snapshot

        (Get-Content -Raw -LiteralPath (Join-Path $repo "README.txt")).Trim() |
            Should Be "initial"
        Test-Path -LiteralPath (Join-Path $repo "review-loop-test.proj") |
            Should Be $true
        Test-Path -LiteralPath (Join-Path $repo "staged.txt") | Should Be $false
        Test-Path -LiteralPath (Join-Path $repo "untracked.txt") | Should Be $false
        (& git -C $repo status --porcelain=v1 | Out-String).Trim() | Should Be ""
    }

    It "restores the original branch and commit after Reviewer ref changes" {
        $snapshot = & (Get-Module CodexReviewLoop) {
            param($repository)
            Get-ReviewLoopRepositorySnapshot -RepoPath $repository
        } $repo
        Set-Content -LiteralPath (Join-Path $repo "README.txt") -Value "reviewer commit"
        & git -C $repo add README.txt
        & git -C $repo commit -q -m "reviewer commit"
        & git -C $repo switch -q -c reviewer-other

        & (Get-Module CodexReviewLoop) {
            param($repository, $baseline)
            Restore-ReviewLoopReviewerRepository -RepoPath $repository -Recovery ([pscustomobject]@{
                RepositoryHead = [string]$baseline.Head
                WorktreeFingerprint = [string]$baseline.Fingerprint
                RepositoryBranch = [string]$baseline.Branch
                RepositoryHeadRef = [string]$baseline.HeadRef
            })
        } $repo $snapshot

        (& git -C $repo branch --show-current) | Should Be $snapshot.Branch
        (& git -C $repo rev-parse HEAD) | Should Be $snapshot.Head
        (Get-Content -Raw -LiteralPath (Join-Path $repo "README.txt")).Trim() |
            Should Be "initial"
        (& git -C $repo show-ref --verify --hash refs/heads/reviewer-other) |
            Should Not Be $snapshot.Head
        (& git -C $repo status --porcelain=v1 | Out-String).Trim() | Should Be ""
    }

    It "restores a detached Reviewer HEAD" {
        & git -C $repo checkout -q --detach HEAD
        $snapshot = & (Get-Module CodexReviewLoop) {
            param($repository)
            Get-ReviewLoopRepositorySnapshot -RepoPath $repository
        } $repo
        Set-Content -LiteralPath (Join-Path $repo "README.txt") -Value "detached commit"
        & git -C $repo add README.txt
        & git -C $repo commit -q -m "detached reviewer commit"

        & (Get-Module CodexReviewLoop) {
            param($repository, $baseline)
            Restore-ReviewLoopReviewerRepository -RepoPath $repository -Recovery ([pscustomobject]@{
                RepositoryHead = [string]$baseline.Head
                WorktreeFingerprint = [string]$baseline.Fingerprint
                RepositoryBranch = [string]$baseline.Branch
                RepositoryHeadRef = [string]$baseline.HeadRef
            })
        } $repo $snapshot

        (& git -C $repo branch --show-current | Out-String).Trim() | Should Be ""
        (& git -C $repo rev-parse HEAD) | Should Be $snapshot.Head
        (Get-Content -Raw -LiteralPath (Join-Path $repo "README.txt")).Trim() |
            Should Be "initial"
        (& git -C $repo status --porcelain=v1 | Out-String).Trim() | Should Be ""
    }

    It "finds and recovers an interrupted Reviewer after it switches branches" {
        $checkpoint = & (Get-Module CodexReviewLoop) {
            param($profilePath, $repository)
            $profile = Import-PowerShellDataFile -LiteralPath $profilePath
            $paths = New-ReviewLoopRunPaths -Config $profile -RepoPath $repository
            Initialize-ReviewLoopRunPaths -Paths $paths | Out-Null
            $head = Get-ReviewLoopGitValue -RepoPath $repository -Arguments @(
                "rev-parse", "HEAD"
            )
            $state = New-ReviewLoopState -RepoPath $repository -ReviewBase HEAD `
                -Speed standard -RunRoot $paths.RunRoot -ReviewBaseCommit $head
            $state.Stage = "reviewing"
            $state.ReviewCycle = 1
            $snapshot = Get-ReviewLoopRepositorySnapshot -RepoPath $repository
            $state.ActiveRoleCall = [pscustomobject]@{
                CallId = "review-01"
                Role = "Reviewer"
                ExecutionFingerprint = ""
                CheckpointStage = "reviewing"
                RepositoryHead = [string]$snapshot.Head
                WorktreeFingerprint = [string]$snapshot.Fingerprint
                RepositoryBranch = [string]$snapshot.Branch
                RepositoryHeadRef = [string]$snapshot.HeadRef
            }
            Write-ReviewLoopState -Path $paths.StatePath -State $state | Out-Null
            Set-ReviewLoopReviewerRecoveryLocator `
                -RepoPath $repository -StatePath $paths.StatePath
            [pscustomobject]@{
                StatePath = $paths.StatePath
                Branch = [string]$snapshot.Branch
                Head = [string]$snapshot.Head
            }
        } $configPath $repo
        & git -C $repo switch -q -c reviewer-interrupted
        Set-Content -LiteralPath (Join-Path $repo "reviewer-left.txt") -Value "left"
        $planPath = Join-Path $caseRoot "reviewer-resume.json"
        Write-ReliabilityJsonArray -Path $planPath -Values @(
            [pscustomobject]@{ result = "No actionable findings." },
            [pscustomobject]@{ result = "No actionable findings." }
        )
        $env:CODEX_REVIEW_LOOP_FAKE_INVOCATION_SEQUENCE = $planPath

        $result = Invoke-CodexReviewLoop -RepoPath $repo -ConfigPath $configPath `
            -CodexPath $fakeCodex -HeartbeatSeconds 0 -ColorMode Never

        $result.Status | Should Be "completed"
        $result.StatePath | Should Be $checkpoint.StatePath
        (& git -C $repo branch --show-current) | Should Be $checkpoint.Branch
        (& git -C $repo rev-parse HEAD) | Should Be $checkpoint.Head
        Test-Path -LiteralPath (Join-Path $repo "reviewer-left.txt") | Should Be $false
        (& git -C $repo status --porcelain=v1 | Out-String).Trim() | Should Be ""
    }

    It "recovers a legacy interrupted Reviewer checkpoint without new metadata" {
        $checkpoint = & (Get-Module CodexReviewLoop) {
            param($profilePath, $repository)
            $profile = Import-PowerShellDataFile -LiteralPath $profilePath
            $paths = New-ReviewLoopRunPaths -Config $profile -RepoPath $repository
            Initialize-ReviewLoopRunPaths -Paths $paths | Out-Null
            $head = Get-ReviewLoopGitValue -RepoPath $repository -Arguments @(
                "rev-parse", "HEAD"
            )
            $state = New-ReviewLoopState -RepoPath $repository -ReviewBase HEAD `
                -Speed standard -RunRoot $paths.RunRoot -ReviewBaseCommit $head
            $state.Stage = "stopped"
            $state.Status = "failed"
            $state.ReviewCycle = 1
            $snapshot = Get-ReviewLoopRepositorySnapshot -RepoPath $repository
            $state.ActiveRoleCall = [pscustomobject]@{
                CallId = "review-01"
                Role = "Reviewer"
                ExecutionFingerprint = ""
                CheckpointStage = "reviewing"
                RepositoryHead = [string]$snapshot.Head
                WorktreeFingerprint = [string]$snapshot.Fingerprint
            }
            Write-ReviewLoopState -Path $paths.StatePath -State $state | Out-Null
            [pscustomobject]@{ StatePath = $paths.StatePath }
        } $configPath $repo
        Set-Content -LiteralPath (Join-Path $repo "tmp_review_diff.txt") -Value "left"
        $planPath = Join-Path $caseRoot "legacy-reviewer-resume.json"
        Write-ReliabilityJsonArray -Path $planPath -Values @(
            [pscustomobject]@{ result = "No actionable findings." },
            [pscustomobject]@{ result = "No actionable findings." }
        )
        $env:CODEX_REVIEW_LOOP_FAKE_INVOCATION_SEQUENCE = $planPath

        $result = Invoke-CodexReviewLoop -RepoPath $repo -ConfigPath $configPath `
            -CodexPath $fakeCodex -HeartbeatSeconds 0 -ColorMode Never

        $result.Status | Should Be "completed"
        $result.StatePath | Should Be $checkpoint.StatePath
        Test-Path -LiteralPath (Join-Path $repo "tmp_review_diff.txt") | Should Be $false
    }

    It "keeps an interrupted Reviewer checkpoint when cleanup is not provably safe" {
        $runRoot = Join-Path $caseRoot "unsafe-reviewer"
        New-Item -ItemType Directory -Path $runRoot | Out-Null
        $head = & git -C $repo rev-parse HEAD
        $state = New-ReviewLoopState -RepoPath $repo -ReviewBase HEAD -Speed standard `
            -RunRoot $runRoot -ReviewBaseCommit $head
        $state.Stage = "reviewing"
        $state.ActiveRoleCall = [pscustomobject]@{
            Role = "Reviewer"
            CheckpointStage = "reviewing"
            RepositoryHead = $head
            WorktreeFingerprint = "not-a-clean-fingerprint"
        }
        $statePath = Join-Path $runRoot "run-v1.json"
        Write-ReviewLoopState -Path $statePath -State $state | Out-Null
        $message = ""
        try {
            & (Get-Module CodexReviewLoop) {
                param($loopState, $checkpoint, $repository)
                Complete-ReviewLoopInterruptedReviewerRecovery `
                    -State $loopState -StatePath $checkpoint -RepoPath $repository
            } $state $statePath $repo | Out-Null
        }
        catch {
            $message = $_.Exception.Message
        }

        $message | Should Match "requires a checkpoint captured from a clean worktree"
        (Read-ReviewLoopState -Path $statePath).ActiveRoleCall | Should Not BeNullOrEmpty
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
        $instructions = [string]@($reviewCall.arguments | Where-Object { $_ -like "developer_instructions=*" })[0]
        ($instructions.Substring("developer_instructions=".Length) | ConvertFrom-Json).StartsWith("Profile review guidance") | Should Be $true
        $instructions | Should Not Match "Current shared task"
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
        $instructions = [string]@($reviewCall.arguments | Where-Object { $_ -like "developer_instructions=*" })[0]
        ($instructions.Substring("developer_instructions=".Length) | ConvertFrom-Json).StartsWith($override) | Should Be $true
        $instructions | Should Not Match "Profile review guidance"
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
        ($reviewCall.arguments -join " ") | Should Not Match "Current shared task"
        ($reviewCall.arguments -join " ") | Should Not Match "Profile review guidance"
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
        ($record.arguments -join " ") | Should Not Match "Current shared task"
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
        $statePath = Join-Path $runRoot "run-v1.json"
        $state = New-ReviewLoopState -RepoPath $repo -ReviewBase HEAD -Speed standard -RunRoot $runRoot
        Write-ReviewLoopState -Path $statePath -State $state | Out-Null
        $config = Import-PowerShellDataFile -LiteralPath $configPath

        $result = & (Get-Module CodexReviewLoop) {
            param($profile, $loopState, $loopStatePath, $fix, $repository, $logs)
            Invoke-ReviewLoopTargetedTests `
                -Config $profile -State $loopState -StatePath $loopStatePath `
                -FixerResult $fix -RepoPath $repository -RunRoot $logs `
                -ClusterId "C-start-failure" -Attempt 1
        } $config $state $statePath $fixerResult $repo $runRoot

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

    It "does not alter a partially staged fixer patch during requalification" {
        Set-Content -LiteralPath (Join-Path $repo "README.txt") -Value "staged version"
        & git -C $repo add README.txt
        Set-Content -LiteralPath (Join-Path $repo "README.txt") -Value "newer unstaged version"
        $module = Get-Module CodexReviewLoop
        $head = & git -C $repo rev-parse HEAD
        $fingerprint = & $module {
            param($repository)
            Get-ReviewLoopWorktreeFingerprint -RepoPath $repository
        } $repo
        $runRoot = Join-Path $caseRoot "partial-staged-requalification"
        New-Item -ItemType Directory -Path $runRoot | Out-Null

        $message = ""
        try {
            & $module {
                param($repository, $expectedHead, $expectedFingerprint, $logs)
                Restore-ReviewLoopVerifiedPatchToCleanIndex `
                    -RepoPath $repository -ExpectedHead $expectedHead `
                    -ExpectedFingerprint $expectedFingerprint `
                    -RunRoot $logs -ClusterId "C-partial-requalification"
            } $repo $head $fingerprint $runRoot | Out-Null
        }
        catch {
            $message = $_.Exception.Message
        }

        $message | Should Match "cannot stage completely|fully staged"
        (& git -C $repo diff --cached --name-only) | Should Be "README.txt"
        (& git -C $repo diff --name-only) | Should Be "README.txt"
        (Get-Content -Raw -LiteralPath (Join-Path $repo "README.txt")) |
            Should Match "newer unstaged version"
    }

    It "resumes interrupted assessment with the original cached Fixer call identity" {
        $plans=Join-Path $caseRoot 'assessment-interruption.json'
        Write-ReliabilityJsonArray -Path $plans -Values @(
            @{result='- [P1] preserve dependency (README.txt:1): current defect'},
            @{},
            @{mutations=@(@{path='README.txt';content='verified fix'})})
        $env:CODEX_REVIEW_LOOP_FAKE_INVOCATION_SEQUENCE=$plans
        $env:CODEX_REVIEW_LOOP_FAKE_INTERRUPT_ASSESSMENT='1'
        Mock Invoke-CodexCliRole -ModuleName CodexReviewLoop -ParameterFilter {
            $SchemaPath -match 'architecture-assessment' -and
                $env:CODEX_REVIEW_LOOP_FAKE_INTERRUPT_ASSESSMENT -eq '1'
        } -MockWith {
            & $OnThreadStarted $env:CODEX_REVIEW_LOOP_FAKE_THREAD
            throw 'Simulated interruption after the assessment thread checkpoint.'
        }
        $first=Invoke-CodexReviewLoop -RepoPath $repo -ConfigPath $configPath `
            -CodexPath $fakeCodex -HeartbeatSeconds 0 -ColorMode Never
        $first.Status|Should Be 'failed'
        $first.Reason|Should Match 'Simulated interruption'
        $saved=Read-ReviewLoopState $first.StatePath
        $pendingId=$saved.ActiveRoleCall.CallId
        $pendingThread=$saved.ActiveRoleCall.ThreadId
        $fixerId=$saved.LastFixerResult.CallId
        $pendingId|Should Match 'architect-assess-'
        $fixerId|Should Not BeNullOrEmpty
        $expectedKey=& (Get-Module CodexReviewLoop) {param($id)(Get-ReviewLoopSha256 $id).Substring(0,12)} $fixerId
        $pendingId|Should Match $expectedKey
        $pendingThread|Should Not BeNullOrEmpty
        (Get-Content (Join-Path $repo 'README.txt'))|Should Be 'verified fix'
        $accepted='{"schemaVersion":"2.0","accept":true,"summary":"Preserved fix assessed","feedback":[],"commitMessage":{"subject":"Preserve dependency","rationale":"Verified fix","changes":["Fix dependency"]},"newOrders":[],"workOutcomes":[],"goalComplete":false}'
        Write-ReliabilityJsonArray -Path $plans -Values @(
            @{result=$accepted}, @{result='No findings.'}, @{result='No findings.'})
        $env:CODEX_REVIEW_LOOP_FAKE_INTERRUPT_ASSESSMENT=''
        $resumed=Invoke-CodexReviewLoop -RepoPath $repo -ConfigPath $configPath `
            -CodexPath $fakeCodex -HeartbeatSeconds 0 -ColorMode Never
        $resumed.Status|Should Be 'completed'
        $resumed.RunRoot|Should Be $first.RunRoot
        $state=Read-ReviewLoopState $resumed.StatePath
        $state.RunId|Should Be $saved.RunId
        $assessment=@($state.RoleCalls|Where-Object {$_.CallId -eq $pendingId -and $_.Success})
        $assessment.Count|Should Be 1
        $assessment[0].ThreadId|Should Be $pendingThread
        @($state.RoleCalls|Where-Object {$_.Role -eq 'Fixer' -and $_.Success}).Count|Should Be 1
        $state.ActiveRoleCall|Should BeNullOrEmpty
        $state.CleanPasses|Should Be 2
        (& git -C $repo status --porcelain)|Should BeNullOrEmpty
        (Get-Content (Join-Path $repo 'README.txt'))|Should Be 'verified fix'
        $calls=@(Get-Content $env:CODEX_REVIEW_LOOP_FAKE_LOG|ForEach-Object{$_|ConvertFrom-Json})
        $assessmentCalls=@($calls|Where-Object schemaPath -match 'architecture-assessment')
        $assessmentCalls[-1].callKind|Should Be 'resume'
        $assessmentCalls[-1].resumeThreadId|Should Be $pendingThread
    }

    It "requalifies a staged commit checkpoint through completion" {
        $config = Import-PowerShellDataFile -LiteralPath $configPath
        $paths = & (Get-Module CodexReviewLoop) {
            param($profile, $repository)
            New-ReviewLoopRunPaths -Config $profile -RepoPath $repository
        } $config $repo
        $paths.RunRoot = Join-Path $paths.ProfileRoot "99999999-staged-requalification"
        New-Item -ItemType Directory -Path $paths.RunRoot -Force | Out-Null
        $statePath = Join-Path $paths.RunRoot "run-v1.json"
        $head = & git -C $repo rev-parse HEAD

        $ledger = New-ReviewLoopLedger -RepoPath $repo
        Merge-ReviewLoopFindings -Ledger $ledger -Findings @((New-ReliabilityFinding)) `
            -ReviewId r1 -Head $head | Out-Null
        $finding = $ledger.Findings[0]
        $finding.Status = "fixing"
        $finding.FixAttempts = 1
        $finding.FixerThreadId = "fixer-thread"
        Write-ReviewLoopLedger -Path $paths.LedgerPath -Ledger $ledger | Out-Null

        Set-Content -LiteralPath (Join-Path $repo "README.txt") -Value "verified fix"
        Set-Content -LiteralPath (Join-Path $repo "new.txt") -Value "verified new file"
        $module = Get-Module CodexReviewLoop
        $snapshot = & $module {
            param($repository)
            Get-ReviewLoopRepositorySnapshot -RepoPath $repository
        } $repo
        $pwsh = (Get-Command pwsh.exe -ErrorAction Stop | Select-Object -First 1).Source
        $state = New-ReviewLoopState `
            -RepoPath $repo -ReviewBase HEAD -Speed standard -RunRoot $paths.RunRoot `
            -ReviewBaseCommit $head -ExecutionFingerprint "stale-execution-fingerprint"
        $state.Status = "failed"
        $state.Stage = "commit_preparing"
        $state.CurrentHead = $head
        $state.ActiveClusterId = $finding.ClusterId
        $state.ActiveFindingIds = @($finding.Id)
        $state.LastFixerResult = [pscustomobject]@{
            Success = $true
            FailureKind = ""
            ThreadId = "fixer-thread"
            Attempt = 1
            Correction = 0
            WorktreeHead = $head
            WorktreeFingerprint = [string]$snapshot.Fingerprint
            StructuredResult = [pscustomobject]@{
                schemaVersion = "1.0"
                outcome = "changed"
                summary = "Applied the verified fix."
                changedPaths = @("README.txt", "new.txt")
                targetedTest = [pscustomobject]@{
                    available = $true
                    executable = $pwsh
                    arguments = @("-NoProfile", "-Command", "exit 0")
                    rationale = "focused regression"
                }
                remainingRisk = ""
            }
        }
        $state.PendingCommit = [pscustomobject]@{
            Verification = $finding.Verification
            PreHead = $head
            PatchFingerprint = [string]$snapshot.Fingerprint
            ExpectedTree = ""
            ExpectedCommit = ""
            Message = "Reliability: interrupted commit preparation"
            NeedsCurrentGates = $false
        }
        & git -C $repo add -A
        Write-ReviewLoopState -Path $statePath -State $state | Out-Null
        $sequence = Join-Path $caseRoot "staged-requalification-results.json"
        Write-ReliabilityJsonArray -Path $sequence -Values @(
            '{"schemaVersion":"1.0","accept":true,"summary":"Accepted.","feedback":[],"commitMessage":{"subject":"Resume the verified staged fix","rationale":"The complete patch was requalified.","changes":["Preserve the verified change."]}}',
            "No actionable findings.",
            "No actionable findings."
        )
        $env:CODEX_REVIEW_LOOP_FAKE_RESULT_SEQUENCE = $sequence

        $resumed = Invoke-CodexReviewLoop -RepoPath $repo -ConfigPath $configPath `
            -CodexPath $fakeCodex -HeartbeatSeconds 0 -ColorMode Never

        $resumed.Status | Should Be "completed"
        (& git -C $repo rev-parse HEAD) | Should Not Be $head
        (@(& git -C $repo show --format= --name-only HEAD) -contains "new.txt") |
            Should Be $true
        (& git -C $repo status --porcelain) | Should BeNullOrEmpty
        (Read-ReviewLoopState -Path $statePath).PendingCommit | Should BeNullOrEmpty
        (Read-ReviewLoopLedger -Path $paths.LedgerPath).Findings[0].Status |
            Should Be "resolved"
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
            Arguments = @(
                "-NoProfile",
                "-Command",
                "Set-Content -LiteralPath gate-output.tmp -Value generated; exit 0"
            )
            RepositoryChanges = @{
                Mode = "RestoreMatching"
                PathRegex = @("^gate-output[.]tmp$")
            }
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
        (Test-Path -LiteralPath (Join-Path $repo "gate-output.tmp")) | Should Be $false
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
            Verification = $finding.Verification
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
            Verification = $finding.Verification
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
        $result = '{"schemaVersion":"1.0","accept":false,"summary":"Still present.","feedback":["Inspect the current path."],"commitMessage":{"subject":"","rationale":"","changes":[]}}'
        $sequence = Join-Path $caseRoot "large-assessment-results.json"
        Write-ReliabilityJsonArray -Path $sequence -Values @($result)
        $env:CODEX_REVIEW_LOOP_FAKE_RESULT_SEQUENCE = $sequence
        $verification = & (Get-Module CodexReviewLoop) {
            param($profile, $loopState, $loopStatePath, $repository, $logs, $finding, $fixer, $fake)
            Invoke-ReviewLoopArchitectAssessment -Config $profile -State $loopState -StatePath $loopStatePath `
                -RepoPath $repository -Speed standard -RunRoot $logs -Findings @($finding) `
                -FixerCall $fixer -Attempt 1 -CodexPath $fake
        } $config $state $statePath $repo $runRoot (New-ReliabilityFinding) $fixerCall $fakeCodex
        $verification.Accepted | Should Be $false
        $verification.Result.summary | Should Be "Still present."
        $record = Get-Content -LiteralPath $env:CODEX_REVIEW_LOOP_FAKE_LOG |
            Select-Object -Last 1 | ConvertFrom-Json
        $record.prompt | Should Match "large patch finding"
        $record.prompt | Should Match "Review the current worktree"
        $record.prompt | Should Match "Changed the implementation"
        $record.prompt | Should Match '"repositoryContext"'
        $record.prompt | Should Match '"reviewBase"'
        $record.prompt | Should Match '"changedPaths"'
    }

    It "reassesses a matching interrupted legacy Verifier checkpoint with the Architect thread" {
        $config = Import-PowerShellDataFile -LiteralPath $configPath
        $config["__ExecutionFingerprint"] = "new-execution"
        Set-Content -LiteralPath (Join-Path $repo "legacy-fix.txt") -Value "preserved fix"
        $runRoot = Join-Path $caseRoot "legacy-verifier-transition"
        New-Item -ItemType Directory -Path $runRoot | Out-Null
        $state = New-ReviewLoopState -RepoPath $repo -ReviewBase HEAD -Speed standard `
            -RunRoot $runRoot -ExecutionFingerprint "old-execution"
        $state.ReviewCycle = 1
        $state.ActiveClusterId = "C-legacy"
        $state.ActiveReviewText = "- legacy finding"
        $state.ActiveStrategy = [pscustomobject]@{
            schemaVersion = "2.0"; summary = "Fix it."; approach = "Use judgment."
            steps = @(); considerations = @()
        }
        $state.RoleSessions.Architect = "architect-thread"
        $snapshot = & (Get-Module CodexReviewLoop) {
            param($repository)
            Get-ReviewLoopRepositorySnapshot -RepoPath $repository
        } $repo
        $state.ActiveRoleCall = [pscustomobject]@{
            CallId = "C-legacy-c1-verify-old"
            Role = "Verifier"
            ExecutionFingerprint = "old-execution"
            RepositoryHead = $snapshot.Head
            WorktreeFingerprint = $snapshot.Fingerprint
        }
        $statePath = Join-Path $runRoot "run-v1.json"
        Write-ReviewLoopState -Path $statePath -State $state | Out-Null
        $fixerCall = [pscustomobject]@{
            CallId = "C-legacy-c1-fix-a1-c0"
            StructuredResult = [pscustomobject]@{
                schemaVersion = "3.0"
                summary = "Applied a better solution."
                targetedTest = [pscustomobject]@{ available = $false; executable = ""; arguments = @() }
            }
        }
        $sequence = Join-Path $caseRoot "legacy-verifier-transition-results.json"
        Write-ReliabilityJsonArray -Path $sequence -Values @(
            '{"schemaVersion":"1.0","accept":true,"summary":"Accepted deviation.","feedback":[],"commitMessage":{"subject":"Accept the better fix","rationale":"It resolves the finding.","changes":["Use the improved implementation."]}}'
        )
        $env:CODEX_REVIEW_LOOP_FAKE_RESULT_SEQUENCE = $sequence

        $assessment = & (Get-Module CodexReviewLoop) {
            param($profile, $loopState, $loopStatePath, $repository, $logs, $finding, $fixer, $fake)
            Invoke-ReviewLoopArchitectAssessment -Config $profile -State $loopState `
                -StatePath $loopStatePath -RepoPath $repository -Speed standard `
                -RunRoot $logs -Findings @($finding) `
                -FixerCall $fixer -Attempt 1 -CodexPath $fake
        } $config $state $statePath $repo $runRoot (New-ReliabilityFinding) $fixerCall $fakeCodex

        $assessment.Accepted | Should Be $true
        (Get-Content -Raw -LiteralPath (Join-Path $repo "legacy-fix.txt")) | Should Match "preserved fix"
        $reloaded = Read-ReviewLoopState -Path $statePath
        $reloaded.ActiveRoleCall | Should BeNullOrEmpty
        $reloaded.RoleCalls[-1].Role | Should Be "Architect"
        $record = Get-Content -LiteralPath $env:CODEX_REVIEW_LOOP_FAKE_LOG |
            Select-Object -Last 1 | ConvertFrom-Json
        $record.callKind | Should Be "resume"
        $record.resumeThreadId | Should Be "architect-thread"
        $record.prompt | Should Match 'Recovery context.+\{\}'
        $record.prompt | Should Match "Applied a better solution"
        $record.prompt | Should Not Match "legacy finding"
        $record.prompt | Should Not Match "Use judgment"
    }

    It "keeps a mismatched interrupted legacy Verifier checkpoint blocked" {
        $config = Import-PowerShellDataFile -LiteralPath $configPath
        $config["__ExecutionFingerprint"] = "new-execution"
        Set-Content -LiteralPath (Join-Path $repo "legacy-fix.txt") -Value "original fix"
        $runRoot = Join-Path $caseRoot "legacy-verifier-mismatch"
        New-Item -ItemType Directory -Path $runRoot | Out-Null
        $state = New-ReviewLoopState -RepoPath $repo -ReviewBase HEAD -Speed standard `
            -RunRoot $runRoot -ExecutionFingerprint "old-execution"
        $state.ReviewCycle = 1
        $state.ActiveClusterId = "C-legacy"
        $state.ActiveReviewText = "- legacy finding"
        $state.ActiveStrategy = [pscustomobject]@{
            schemaVersion = "2.0"; summary = "Fix it."; approach = "Use judgment."
            steps = @(); considerations = @()
        }
        $state.RoleSessions.Architect = "architect-thread"
        $snapshot = & (Get-Module CodexReviewLoop) {
            param($repository)
            Get-ReviewLoopRepositorySnapshot -RepoPath $repository
        } $repo
        $state.ActiveRoleCall = [pscustomobject]@{
            CallId = "C-legacy-c1-verify-old"
            Role = "Verifier"
            ExecutionFingerprint = "old-execution"
            RepositoryHead = $snapshot.Head
            WorktreeFingerprint = $snapshot.Fingerprint
        }
        Set-Content -LiteralPath (Join-Path $repo "legacy-fix.txt") -Value "concurrent change"
        $statePath = Join-Path $runRoot "run-v1.json"
        Write-ReviewLoopState -Path $statePath -State $state | Out-Null
        $fixerCall = [pscustomobject]@{
            CallId = "C-legacy-c1-fix-a1-c0"
            StructuredResult = [pscustomobject]@{
                schemaVersion = "3.0"; summary = "Changed."
                targetedTest = [pscustomobject]@{ available = $false; executable = ""; arguments = @() }
            }
        }
        $message = ""
        try {
            & (Get-Module CodexReviewLoop) {
                param($profile, $loopState, $loopStatePath, $repository, $logs, $finding, $fixer, $fake)
                Invoke-ReviewLoopArchitectAssessment -Config $profile -State $loopState `
                    -StatePath $loopStatePath -RepoPath $repository -Speed standard `
                    -RunRoot $logs -Findings @($finding) `
                    -FixerCall $fixer -Attempt 1 -CodexPath $fake
            } $config $state $statePath $repo $runRoot (New-ReliabilityFinding) $fixerCall $fakeCodex | Out-Null
        }
        catch {
            $message = $_.Exception.Message
        }

        $message | Should Match "legacy Verifier checkpoint no longer matches"
        (Read-ReviewLoopState -Path $statePath).ActiveRoleCall.Role | Should Be "Verifier"
        (Get-Content -Raw -LiteralPath (Join-Path $repo "legacy-fix.txt")) | Should Match "concurrent change"
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

}

Describe "Unattended Git and recovery reliability boundaries 2" `
    -Tags @("GitSafety", "GitSafetyB") {
    BeforeEach {
        $case = New-ReliabilityTestCase
        $caseRoot = $case.Root
        $repo = $case.Repo
        $logRoot = $case.LogRoot
        $configPath = $case.ConfigPath
        & (Get-Module CodexReviewLoop) { Initialize-ReviewLoopConsole -TranscriptPath "" -HostOutputEnabled $false }
    }

    AfterEach {
        Clear-ReliabilityTestCase
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
        $completion.Evidence | Should Match "final retrospective guidance change verified"

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
        $failure.Exception.Message | Should Match "Host gate 'mutating gate'.*not authorized"
        $failure.Exception.Message | Should Match "generated[.]txt"
        (Read-ReviewLoopState -Path $statePath).ActiveHostGateRecovery.Phase |
            Should Be "observed"
        (Test-Path -LiteralPath (Join-Path $repo "generated.txt")) | Should Be $true
        (& git -C $repo rev-list --count HEAD) | Should Be 1
    }

    It "restores every allowed tracked and untracked gate side effect and supports policy update on resume" {
        Set-Content -LiteralPath (Join-Path $repo "tracked-delete.txt") -Value "tracked baseline"
        Set-Content -LiteralPath (Join-Path $repo "tracked-change.txt") -Value "tracked original"
        & git -C $repo add tracked-delete.txt tracked-change.txt
        & git -C $repo commit -q -m "recovery fixtures"
        Set-Content -LiteralPath (Join-Path $repo "README.txt") -Value "verified fixer change"
        Set-Content -LiteralPath (Join-Path $repo "untouched-fixer.txt") -Value "verified untouched fixer change"
        $untouchedTimestamp = [DateTime]::SpecifyKind(
            [DateTime]::Parse("2001-02-03T04:05:06"),
            [DateTimeKind]::Utc)
        [System.IO.File]::SetLastWriteTimeUtc(
            (Join-Path $repo "untouched-fixer.txt"),
            $untouchedTimestamp)
        New-Item -ItemType Directory -Path (Join-Path $repo "cache") | Out-Null
        Set-Content -LiteralPath (Join-Path $repo "cache/deleted.tmp") -Value "saved deleted untracked"
        Set-Content -LiteralPath (Join-Path $repo "cache/changed.tmp") -Value "saved changed untracked"

        $runRoot = Join-Path $caseRoot "host-gate-recovery-run"
        New-Item -ItemType Directory -Path $runRoot | Out-Null
        $statePath = Join-Path $runRoot "run-v1.json"
        $state = New-ReviewLoopState `
            -RepoPath $repo -ReviewBase HEAD -Speed standard -RunRoot $runRoot
        Write-ReviewLoopState -Path $statePath -State $state | Out-Null
        $gate = @{
            Name = "generator gate"
            FilePath = "pwsh"
            Arguments = @("-NoProfile", "-Command", "exit 0")
        }
        $profilePath = [System.IO.Path]::GetFullPath((Join-Path $caseRoot "active-profile.psd1"))
        $terminalPath = Join-Path $runRoot "terminal.log"
        $config = @{ HostGates = @($gate); __ConfigPath = $profilePath }
        $module = Get-Module CodexReviewLoop
        & $module {
            param($path)
            Initialize-ReviewLoopConsole `
                -OutputMode compact -HeartbeatSeconds 0 -ColorMode Never `
                -TranscriptPath $path
        } $terminalPath
        $baseline = & $module {
            param($loopState, $loopStatePath, $repository, $logs, $hostGate)
            $snapshot = Get-ReviewLoopRepositorySnapshot -RepoPath $repository
            New-ReviewLoopHostGateRecovery `
                -State $loopState -StatePath $loopStatePath -RepoPath $repository `
                -RunRoot $logs -Gate $hostGate | Out-Null
            return $snapshot
        } $state $statePath $repo $runRoot $gate

        Set-Content -LiteralPath (Join-Path $repo "README.txt") -Value "gate overwrote fixer change"
        Set-Content -LiteralPath (Join-Path $repo "tracked-change.txt") -Value "gate changed tracked"
        Remove-Item -LiteralPath (Join-Path $repo "tracked-delete.txt")
        Remove-Item -LiteralPath (Join-Path $repo "cache/deleted.tmp")
        Set-Content -LiteralPath (Join-Path $repo "cache/changed.tmp") -Value "gate changed untracked"
        Set-Content -LiteralPath (Join-Path $repo "cache/new.tmp") -Value "gate-created untracked"

        $failure = $null
        try {
            & $module {
                param($activeConfig, $loopState, $loopStatePath, $repository, $hostGate)
                Complete-ReviewLoopHostGateRecovery `
                    -Config $activeConfig -State $loopState -StatePath $loopStatePath `
                    -RepoPath $repository -Gate $hostGate | Out-Null
            } $config $state $statePath $repo $gate
        }
        catch {
            $failure = $_
        }

        & $module {
            param($errorRecord, $path)
            $steps = @(Get-ReviewLoopFailureNextSteps `
                -Exception $errorRecord.Exception -Context failed)
            Write-ReviewLoopFailureSummary `
                -Title "Review Loop stopped" `
                -Problem $errorRecord.Exception.Message -Status failed `
                -NextSteps $steps -RecommendedStepCount 2 `
                -TranscriptPath $path
        } $failure $terminalPath

        $failure | Should Not BeNullOrEmpty
        $failure.Exception.Message | Should Match "generator gate"
        $steps = @($failure.Exception.Data["ReviewLoopNextSteps"]) -join "`n"
        $steps | Should Match ([regex]::Escape($profilePath))
        $steps | Should Match "inside the HostGates entry named 'generator gate'"
        $steps | Should Match "Mode = 'RestoreMatching'"
        $steps | Should Match "Mode = 'RestoreAll'"
        $steps | Should Match ([regex]::Escape("'^README\.txt$'"))
        $steps | Should Match "Run the same review-loop command again"
        $terminalText = Get-Content -Raw -LiteralPath $terminalPath
        $terminalText | Should Match ([regex]::Escape((Split-Path -Leaf $profilePath)))
        $terminalText | Should Match "generator gate"
        $terminalText | Should Match "README[.]txt"
        $terminalText | Should Match "Mode = 'RestoreMatching'"
        $terminalText | Should Match "Run the same review-loop command again"
        (Get-Content -Raw -LiteralPath (Join-Path $repo "README.txt")) |
            Should Match "gate overwrote fixer change"
        (Test-Path -LiteralPath (Join-Path $repo "tracked-delete.txt")) | Should Be $false

        $gate.RepositoryChanges = @{
            Mode = "RestoreMatching"
            PathRegex = @(
                "^README[.]txt$",
                "^tracked-change[.]txt$",
                "^tracked-delete[.]txt$",
                "^cache/deleted[.]tmp$",
                "^cache/changed[.]tmp$",
                "^cache/new[.]tmp$"
            )
        }
        [void]$config.Remove("__ConfigPath")
        (& $module {
            param($activeConfig, $loopState, $loopStatePath, $repository)
            Resume-ReviewLoopHostGateRecovery `
                -Config $activeConfig -State $loopState -StatePath $loopStatePath `
                -RepoPath $repository
        } $config $state $statePath $repo) | Should Be $true

        (& $module {
            param($repository)
            (Get-ReviewLoopRepositorySnapshot -RepoPath $repository).Fingerprint
        } $repo) | Should Be $baseline.Fingerprint
        (Get-Content -Raw -LiteralPath (Join-Path $repo "README.txt")) |
            Should Match "verified fixer change"
        (Get-Content -Raw -LiteralPath (Join-Path $repo "tracked-change.txt")) |
            Should Match "tracked original"
        (Get-Content -Raw -LiteralPath (Join-Path $repo "untouched-fixer.txt")) |
            Should Match "verified untouched fixer change"
        (Get-Item -LiteralPath (Join-Path $repo "untouched-fixer.txt")).LastWriteTimeUtc |
            Should Be $untouchedTimestamp
        (Test-Path -LiteralPath (Join-Path $repo "tracked-delete.txt")) | Should Be $true
        (Get-Content -Raw -LiteralPath (Join-Path $repo "cache/deleted.tmp")) |
            Should Match "saved deleted untracked"
        (Get-Content -Raw -LiteralPath (Join-Path $repo "cache/changed.tmp")) |
            Should Match "saved changed untracked"
        (Test-Path -LiteralPath (Join-Path $repo "cache/new.tmp")) | Should Be $false
        (Read-ReviewLoopState -Path $statePath).ActiveHostGateRecovery |
            Should BeNullOrEmpty
        & $module {
            Initialize-ReviewLoopConsole `
                -OutputMode compact -HeartbeatSeconds 0 -ColorMode Never `
                -TranscriptPath ""
        }
    }

    It "does not partially restore a mixed mutation and RestoreAll can restore it explicitly" {
        $runRoot = Join-Path $caseRoot "host-gate-mixed-run"
        New-Item -ItemType Directory -Path $runRoot | Out-Null
        $statePath = Join-Path $runRoot "run-v1.json"
        $state = New-ReviewLoopState `
            -RepoPath $repo -ReviewBase HEAD -Speed standard -RunRoot $runRoot
        Write-ReviewLoopState -Path $statePath -State $state | Out-Null
        $gate = @{
            Name = "mixed gate"
            FilePath = "pwsh"
            Arguments = @("-NoProfile", "-Command", "exit 0")
            RepositoryChanges = @{
                Mode = "RestoreMatching"
                PathRegex = @("^allowed[.]txt$")
            }
        }
        $config = @{ HostGates = @($gate) }
        $module = Get-Module CodexReviewLoop
        & $module {
            param($loopState, $loopStatePath, $repository, $logs, $hostGate)
            New-ReviewLoopHostGateRecovery `
                -State $loopState -StatePath $loopStatePath -RepoPath $repository `
                -RunRoot $logs -Gate $hostGate | Out-Null
        } $state $statePath $repo $runRoot $gate
        Set-Content -LiteralPath (Join-Path $repo "allowed.txt") -Value "allowed"
        Set-Content -LiteralPath (Join-Path $repo "denied.txt") -Value "denied"

        (Test-ReliabilityThrows {
            & $module {
                param($activeConfig, $loopState, $loopStatePath, $repository, $hostGate)
                Complete-ReviewLoopHostGateRecovery `
                    -Config $activeConfig -State $loopState -StatePath $loopStatePath `
                    -RepoPath $repository -Gate $hostGate | Out-Null
            } $config $state $statePath $repo $gate
        }) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $repo "allowed.txt")) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $repo "denied.txt")) | Should Be $true

        $gate.RepositoryChanges = @{ Mode = "RestoreAll" }
        & $module {
            param($activeConfig, $loopState, $loopStatePath, $repository, $hostGate)
            Complete-ReviewLoopHostGateRecovery `
                -Config $activeConfig -State $loopState -StatePath $loopStatePath `
                -RepoPath $repository -Gate $hostGate | Out-Null
        } $config $state $statePath $repo $gate
        (Test-Path -LiteralPath (Join-Path $repo "allowed.txt")) | Should Be $false
        (Test-Path -LiteralPath (Join-Path $repo "denied.txt")) | Should Be $false
    }

    It "refuses concurrent worktree changes after gate mutations were recorded" {
        $runRoot = Join-Path $caseRoot "host-gate-concurrent-run"
        New-Item -ItemType Directory -Path $runRoot | Out-Null
        $statePath = Join-Path $runRoot "run-v1.json"
        $state = New-ReviewLoopState `
            -RepoPath $repo -ReviewBase HEAD -Speed standard -RunRoot $runRoot
        Write-ReviewLoopState -Path $statePath -State $state | Out-Null
        $gate = @{
            Name = "concurrent gate"
            FilePath = "pwsh"
            Arguments = @("-NoProfile", "-Command", "exit 0")
        }
        $config = @{ HostGates = @($gate) }
        $module = Get-Module CodexReviewLoop
        & $module {
            param($loopState, $loopStatePath, $repository, $logs, $hostGate)
            New-ReviewLoopHostGateRecovery `
                -State $loopState -StatePath $loopStatePath -RepoPath $repository `
                -RunRoot $logs -Gate $hostGate | Out-Null
        } $state $statePath $repo $runRoot $gate
        Set-Content -LiteralPath (Join-Path $repo "generated.txt") -Value "gate value"
        (Test-ReliabilityThrows {
            & $module {
                param($activeConfig, $loopState, $loopStatePath, $repository, $hostGate)
                Complete-ReviewLoopHostGateRecovery `
                    -Config $activeConfig -State $loopState -StatePath $loopStatePath `
                    -RepoPath $repository -Gate $hostGate | Out-Null
            } $config $state $statePath $repo $gate
        }) | Should Be $true

        Set-Content -LiteralPath (Join-Path $repo "generated.txt") -Value "concurrent value"
        $gate.RepositoryChanges = @{ Mode = "RestoreAll" }
        $failure = $null
        try {
            & $module {
                param($activeConfig, $loopState, $loopStatePath, $repository, $hostGate)
                Complete-ReviewLoopHostGateRecovery `
                    -Config $activeConfig -State $loopState -StatePath $loopStatePath `
                    -RepoPath $repository -Gate $hostGate | Out-Null
            } $config $state $statePath $repo $gate
        }
        catch {
            $failure = $_
        }
        $failure.Exception.Message | Should Match "changed after host-gate mutations were recorded"
        (Get-Content -Raw -LiteralPath (Join-Path $repo "generated.txt")) |
            Should Match "concurrent value"
    }

    It "finishes an interrupted host-gate restoration idempotently" {
        Set-Content -LiteralPath (Join-Path $repo "README.txt") -Value "verified baseline"
        Set-Content -LiteralPath (Join-Path $repo "saved.tmp") -Value "saved untracked"
        $runRoot = Join-Path $caseRoot "host-gate-interrupted-restore-run"
        New-Item -ItemType Directory -Path $runRoot | Out-Null
        $statePath = Join-Path $runRoot "run-v1.json"
        $state = New-ReviewLoopState `
            -RepoPath $repo -ReviewBase HEAD -Speed standard -RunRoot $runRoot
        Write-ReviewLoopState -Path $statePath -State $state | Out-Null
        $gate = @{
            Name = "interrupted restore gate"
            FilePath = "pwsh"
            Arguments = @("-NoProfile", "-Command", "exit 0")
            RepositoryChanges = @{ Mode = "RestoreAll" }
        }
        $config = @{ HostGates = @($gate) }
        $module = Get-Module CodexReviewLoop
        $baseline = & $module {
            param($loopState, $loopStatePath, $repository, $logs, $hostGate)
            $snapshot = Get-ReviewLoopRepositorySnapshot -RepoPath $repository
            New-ReviewLoopHostGateRecovery `
                -State $loopState -StatePath $loopStatePath -RepoPath $repository `
                -RunRoot $logs -Gate $hostGate | Out-Null
            return $snapshot
        } $state $statePath $repo $runRoot $gate
        Set-Content -LiteralPath (Join-Path $repo "README.txt") -Value "gate value"
        Remove-Item -LiteralPath (Join-Path $repo "saved.tmp")
        Set-Content -LiteralPath (Join-Path $repo "new.tmp") -Value "gate output"

        (& $module {
            param($activeConfig, $loopState, $loopStatePath, $repository)
            Resume-ReviewLoopHostGateRecovery `
                -Config $activeConfig -State $loopState -StatePath $loopStatePath `
                -RepoPath $repository
        } $config $state $statePath $repo) | Should Be $true
        & $module {
            param($loopState, $loopStatePath, $repository, $logs, $hostGate)
            New-ReviewLoopHostGateRecovery `
                -State $loopState -StatePath $loopStatePath -RepoPath $repository `
                -RunRoot $logs -Gate $hostGate | Out-Null
        } $state $statePath $repo $runRoot $gate
        Set-Content -LiteralPath (Join-Path $repo "README.txt") -Value "gate value"
        Remove-Item -LiteralPath (Join-Path $repo "saved.tmp")
        Set-Content -LiteralPath (Join-Path $repo "new.tmp") -Value "gate output"

        & $module {
            param($loopState, $loopStatePath, $repository)
            $manifest = Read-ReviewLoopJson `
                -Path ([string]$loopState.ActiveHostGateRecovery.ManifestPath)
            $mutation = Get-ReviewLoopHostGateMutation `
                -RepoPath $repository -Manifest $manifest
            $loopState.ActiveHostGateRecovery.Phase = "restoring"
            $loopState.ActiveHostGateRecovery.ObservedFingerprint = [string]$mutation.Fingerprint
            $loopState.ActiveHostGateRecovery.ObservedPaths = @($mutation.ObservedPaths)
            $loopState.ActiveHostGateRecovery.ObservedEntries = @($mutation.ObservedEntries)
            Write-ReviewLoopState -Path $loopStatePath -State $loopState | Out-Null
        } $state $statePath $repo
        & git -C $repo restore --source=HEAD --staged --worktree -- README.txt
        Remove-Item -LiteralPath (Join-Path $repo "new.tmp")

        (& $module {
            param($activeConfig, $loopState, $loopStatePath, $repository)
            Resume-ReviewLoopHostGateRecovery `
                -Config $activeConfig -State $loopState -StatePath $loopStatePath `
                -RepoPath $repository
        } $config $state $statePath $repo) | Should Be $true
        (& $module {
            param($repository)
            (Get-ReviewLoopRepositorySnapshot -RepoPath $repository).Fingerprint
        } $repo) | Should Be $baseline.Fingerprint
        (Get-Content -Raw -LiteralPath (Join-Path $repo "README.txt")) |
            Should Match "verified baseline"
        (Get-Content -Raw -LiteralPath (Join-Path $repo "saved.tmp")) |
            Should Match "saved untracked"
        (Read-ReviewLoopState -Path $statePath).ActiveHostGateRecovery |
            Should BeNullOrEmpty
    }

    It "checks host-gate artifacts before changing the worktree" {
        Set-Content -LiteralPath (Join-Path $repo "README.txt") -Value "verified baseline"
        $runRoot = Join-Path $caseRoot "host-gate-integrity-run"
        New-Item -ItemType Directory -Path $runRoot | Out-Null
        $statePath = Join-Path $runRoot "run-v1.json"
        $state = New-ReviewLoopState `
            -RepoPath $repo -ReviewBase HEAD -Speed standard -RunRoot $runRoot
        Write-ReviewLoopState -Path $statePath -State $state | Out-Null
        $gate = @{
            Name = "integrity gate"
            FilePath = "pwsh"
            Arguments = @("-NoProfile", "-Command", "exit 0")
        }
        $config = @{ HostGates = @($gate) }
        $module = Get-Module CodexReviewLoop
        & $module {
            param($loopState, $loopStatePath, $repository, $logs, $hostGate)
            New-ReviewLoopHostGateRecovery `
                -State $loopState -StatePath $loopStatePath -RepoPath $repository `
                -RunRoot $logs -Gate $hostGate | Out-Null
        } $state $statePath $repo $runRoot $gate
        Set-Content -LiteralPath (Join-Path $repo "README.txt") -Value "gate value"
        Set-Content -LiteralPath (Join-Path $repo "generated.txt") -Value "gate output"
        (Test-ReliabilityThrows {
            & $module {
                param($activeConfig, $loopState, $loopStatePath, $repository, $hostGate)
                Complete-ReviewLoopHostGateRecovery `
                    -Config $activeConfig -State $loopState -StatePath $loopStatePath `
                    -RepoPath $repository -Gate $hostGate | Out-Null
            } $config $state $statePath $repo $gate
        }) | Should Be $true
        $gate.RepositoryChanges = @{ Mode = "RestoreAll" }
        Set-Content -LiteralPath $state.ActiveHostGateRecovery.ManifestPath `
            -Value "damaged manifest"

        $failure = $null
        try {
            & $module {
                param($activeConfig, $loopState, $loopStatePath, $repository, $hostGate)
                Complete-ReviewLoopHostGateRecovery `
                    -Config $activeConfig -State $loopState -StatePath $loopStatePath `
                    -RepoPath $repository -Gate $hostGate | Out-Null
            } $config $state $statePath $repo $gate
        }
        catch {
            $failure = $_
        }
        $failure.Exception.Message | Should Match "manifest failed its integrity check"
        (Get-Content -Raw -LiteralPath (Join-Path $repo "README.txt")) |
            Should Match "gate value"
        (Test-Path -LiteralPath (Join-Path $repo "generated.txt")) | Should Be $true
    }

    It "refuses index and ref mutations without automatic restoration" {
        foreach ($kind in @("index", "ref")) {
            $scenarioRepo = New-ReliabilityRepo -Path (Join-Path $caseRoot "host-gate-$kind-repo")
            $runRoot = Join-Path $caseRoot "host-gate-$kind-run"
            New-Item -ItemType Directory -Path $runRoot | Out-Null
            $statePath = Join-Path $runRoot "run-v1.json"
            $state = New-ReviewLoopState `
                -RepoPath $scenarioRepo -ReviewBase HEAD -Speed standard -RunRoot $runRoot
            Write-ReviewLoopState -Path $statePath -State $state | Out-Null
            $gate = @{
                Name = "$kind gate"
                FilePath = "pwsh"
                Arguments = @("-NoProfile", "-Command", "exit 0")
                RepositoryChanges = @{ Mode = "RestoreAll" }
            }
            $config = @{ HostGates = @($gate) }
            $module = Get-Module CodexReviewLoop
            & $module {
                param($loopState, $loopStatePath, $repository, $logs, $hostGate)
                New-ReviewLoopHostGateRecovery `
                    -State $loopState -StatePath $loopStatePath -RepoPath $repository `
                    -RunRoot $logs -Gate $hostGate | Out-Null
            } $state $statePath $scenarioRepo $runRoot $gate
            Set-Content -LiteralPath (Join-Path $scenarioRepo "generated.txt") -Value "generated"
            if ($kind -eq "index") {
                & git -C $scenarioRepo add generated.txt
            }
            else {
                & git -C $scenarioRepo tag gate-mutated-ref
            }

            $failure = $null
            try {
                & $module {
                    param($activeConfig, $loopState, $loopStatePath, $repository, $hostGate)
                    Complete-ReviewLoopHostGateRecovery `
                        -Config $activeConfig -State $loopState -StatePath $loopStatePath `
                        -RepoPath $repository -Gate $hostGate | Out-Null
                } $config $state $statePath $scenarioRepo $gate
            }
            catch {
                $failure = $_
            }
            $failure | Should Not BeNullOrEmpty
            $failure.Exception.Message | Should Match $(if ($kind -eq "index") { "index changed" } else { "refs changed" })
            (Test-Path -LiteralPath (Join-Path $scenarioRepo "generated.txt")) |
                Should Be $true
        }
    }

    It "resumes the sealed pending commit with a long Unicode message on native stdin" {
        $runRoot = Join-Path $caseRoot 'stdin-commit-run'
        New-Item -ItemType Directory -Path $runRoot | Out-Null
        $statePath = Join-Path $runRoot 'run-v1.json'
        $ledgerPath = Join-Path $caseRoot 'stdin-ledger.json'
        $preHead = & git -C $repo rev-parse HEAD
        Set-Content (Join-Path $repo 'README.txt') 'verified Unicode change'
        $module = Get-Module CodexReviewLoop
        $fingerprint = & $module {param($r) Get-ReviewLoopWorktreeFingerprint -RepoPath $r} $repo
        & git -C $repo add -A
        $tree = & git -C $repo write-tree
        $message = ('Reliability: Grüße Ω "quoted subject"' + "`n`n" +
            (("Preserve 日本語, quotes `"exact`", and verified change.`n" * 40).TrimEnd()))
        $message.Length | Should BeGreaterThan 500
        $ledger = New-ReviewLoopLedger -RepoPath $repo
        Merge-ReviewLoopFindings -Ledger $ledger -Findings @((New-ReliabilityFinding)) `
            -ReviewId r1 -Head $preHead | Out-Null
        $finding = $ledger.Findings[0]
        $finding.Status = 'fixing'
        $finding.Verification = [pscustomobject]@{
            accept=$true; WorkRevision=0; workOutcomes=@(); goalComplete=$false;
            summary='Verified tree and native checks agree'
        }
        Write-ReviewLoopLedger -Path $ledgerPath -Ledger $ledger | Out-Null
        $state = New-ReviewLoopState -RepoPath $repo -ReviewBase HEAD -Speed standard -RunRoot $runRoot
        $state.CurrentHead = $preHead
        $state.ActiveClusterId = $finding.ClusterId
        $state.ActiveFindingIds = @($finding.Id)
        $state.PendingCommit = [pscustomobject]@{
            Verification = $finding.Verification; PreHead = $preHead; PatchFingerprint = $fingerprint;
            ExpectedTree = $tree; Message = $message; NeedsCurrentGates = $false
        }
        Write-ReviewLoopState -Path $statePath -State $state | Out-Null
        $profile = Import-PowerShellDataFile -LiteralPath $configPath
        $profile.AutoCommit = $false
        $complete = {
            param($c,$s,$sp,$l,$lp,$r,$logs)
            Complete-ReviewLoopPendingCommit -Config $c -State $s -StatePath $sp `
                -Ledger $l -LedgerPath $lp -RepoPath $r -RunRoot $logs
        }
        $blocked = $null
        try { & $module $complete $profile $state $statePath $ledger $ledgerPath $repo $runRoot }
        catch { $blocked = $_ }
        $blocked.Exception.Message | Should Match 'AutoCommit is disabled'
        (& git -C $repo rev-parse HEAD) | Should Be $preHead
        $saved = Read-ReviewLoopState $statePath
        $saved.PendingCommit.Message | Should Be $message
        $saved.PendingCommit.ExpectedTree | Should Be $tree
        $profile.AutoCommit = $true
        (& $module $complete $profile $saved $statePath $ledger $ledgerPath $repo $runRoot) | Should Be $true
        (& git -C $repo show -s --format=%T HEAD) | Should Be $tree
        (& git -C $repo show -s --format=%P HEAD) | Should Be $preHead
        $actual = & $module {param($r) Get-ReviewLoopGitValue -RepoPath $r -Arguments @('show','-s','--format=%B','HEAD')} $repo
        $actual | Should Be $message
        (Read-ReviewLoopState $statePath).PendingCommit | Should BeNullOrEmpty
        (& git -C $repo status --porcelain) | Should BeNullOrEmpty
        (& $module $complete $profile $saved $statePath $ledger $ledgerPath $repo $runRoot) | Should Be $false
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
            Verification = $finding.Verification
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
            Verification = $finding.Verification
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

    It "restores all regular targeted-test side effects when configured" {
        $config = Import-PowerShellDataFile -LiteralPath $configPath
        $config.TargetedTestRepositoryChanges = @{ Mode = "RestoreAll" }
        Set-Content -LiteralPath (Join-Path $repo "README.txt") -Value "verified fix"
        Set-Content -LiteralPath (Join-Path $repo "fixer-untracked.txt") -Value "preserved fixer file"
        $runRoot = Join-Path $caseRoot "targeted-restore-all"
        New-Item -ItemType Directory -Path $runRoot | Out-Null
        $statePath = Join-Path $runRoot "run-v1.json"
        $state = New-ReviewLoopState -RepoPath $repo -ReviewBase HEAD -Speed standard -RunRoot $runRoot
        Write-ReviewLoopState -Path $statePath -State $state | Out-Null
        $scriptPath = Join-Path $caseRoot "mutating-targeted-test.ps1"
        Set-Content -LiteralPath $scriptPath -Value @'
param([string]$Repository)
[System.IO.File]::WriteAllText((Join-Path $Repository "README.txt"), "targeted mutation")
[System.IO.File]::WriteAllText((Join-Path $Repository "fixer-untracked.txt"), "targeted mutation")
[System.IO.File]::WriteAllText((Join-Path $Repository "targeted-side-effect.txt"), "disposable")
exit 0
'@ -Encoding UTF8
        $fixer = [pscustomobject]@{
            targetedTest = [pscustomobject]@{
                executable = (Get-Command pwsh.exe -ErrorAction Stop | Select-Object -First 1).Source
                arguments = @("-NoProfile", "-File", $scriptPath, $repo)
                rationale = "exercise targeted-test cleanup"
            }
        }
        $module = Get-Module CodexReviewLoop
        $before = & $module {
            param($repository)
            Get-ReviewLoopRepositorySnapshot -RepoPath $repository
        } $repo

        $result = & $module {
            param($profile, $loopState, $loopStatePath, $fix, $repository, $logs)
            Invoke-ReviewLoopTargetedTests `
                -Config $profile -State $loopState -StatePath $loopStatePath `
                -FixerResult $fix -RepoPath $repository -RunRoot $logs `
                -ClusterId "C-targeted-restore" -Attempt 1
        } $config $state $statePath $fixer $repo $runRoot

        $after = & $module {
            param($repository)
            Get-ReviewLoopRepositorySnapshot -RepoPath $repository
        } $repo
        $result.Success | Should Be $true
        $after.Fingerprint | Should Be $before.Fingerprint
        $after.IndexFingerprint | Should Be $before.IndexFingerprint
        (Get-Content -Raw -LiteralPath (Join-Path $repo "README.txt")).Trim() |
            Should Be "verified fix"
        (Get-Content -Raw -LiteralPath (Join-Path $repo "fixer-untracked.txt")).Trim() |
            Should Be "preserved fixer file"
        Test-Path -LiteralPath (Join-Path $repo "targeted-side-effect.txt") | Should Be $false
        (Read-ReviewLoopState -Path $statePath).ActiveHostGateRecovery | Should BeNullOrEmpty

        $failingScript = (Get-Content -Raw -LiteralPath $scriptPath).Replace("exit 0", "exit 7")
        Set-Content -LiteralPath $scriptPath -Value $failingScript -Encoding UTF8
        $failedResult = & $module {
            param($profile, $loopState, $loopStatePath, $fix, $repository, $logs)
            Invoke-ReviewLoopTargetedTests `
                -Config $profile -State $loopState -StatePath $loopStatePath `
                -FixerResult $fix -RepoPath $repository -RunRoot $logs `
                -ClusterId "C-targeted-restore" -Attempt 2
        } $config $state $statePath $fixer $repo $runRoot
        $afterFailure = & $module {
            param($repository)
            Get-ReviewLoopRepositorySnapshot -RepoPath $repository
        } $repo
        $failedResult.Success | Should Be $false
        $failedResult.Results[0].ExitCode | Should Be 7
        $afterFailure.Fingerprint | Should Be $before.Fingerprint
        Test-Path -LiteralPath (Join-Path $repo "targeted-side-effect.txt") | Should Be $false
        (Read-ReviewLoopState -Path $statePath).ActiveHostGateRecovery | Should BeNullOrEmpty
    }

    It "explains and resumes a targeted-test mutation under the safe default" {
        $config = Import-PowerShellDataFile -LiteralPath $configPath
        $config["__ConfigPath"] = [System.IO.Path]::GetFullPath($configPath)
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
                    $loopFinding, $fixer, $repository, $logs, $cliPath
                )
                Invoke-ReviewLoopAttemptAssessment -Config $profile `
                    -State $loopState -StatePath $loopStatePath `
                    -Ledger $loopLedger -LedgerPath $loopLedgerPath `
                    -Findings @($loopFinding) -FixerCall $fixer -Attempt 1 `
                    -RepoPath $repository -Speed standard -RunRoot $logs -CodexPath $cliPath
            } $config `
                $state $statePath $ledger $ledgerPath $finding $fixerCall $repo $runRoot $fakeCodex | Out-Null
        }
        catch {
            $failure = $_
        }

        $failure | Should Not BeNullOrEmpty
        $failure.Exception.Data["ReviewLoopStatus"] | Should Be "failed"
        $failure.Exception.Message | Should Match "Targeted test 'Targeted regression test'"
        $failure.Exception.Message | Should Match "target-test-mutated\.txt"
        $nextSteps = @($failure.Exception.Data["ReviewLoopNextSteps"])
        ($nextSteps -join "`n") | Should Match ([regex]::Escape([System.IO.Path]::GetFullPath($configPath)))
        ($nextSteps -join "`n") | Should Match "TargetedTestRepositoryChanges = @\{"
        ($nextSteps -join "`n") | Should Match "Mode = 'RestoreAll'"
        ($nextSteps -join "`n") | Should Match "same review-loop command again"
        ($nextSteps -join "`n") | Should Not Match "RestoreMatching|PathRegex"
        Test-Path -LiteralPath (Join-Path $repo "target-test-mutated.txt") | Should Be $true
        (& git -C $repo rev-list --count HEAD) | Should Be 1
        $saved = Read-ReviewLoopState -Path $statePath
        $saved.ActiveHostGateRecovery.Kind | Should Be "TargetedTest"

        $profileText = (Get-Content -Raw -LiteralPath $configPath).Replace(
            "Mode = 'Fail'",
            "Mode = 'RestoreAll'")
        Set-Content -LiteralPath $configPath -Value $profileText -Encoding UTF8
        $resumed = & (Get-Module CodexReviewLoop) {
            param($profile, $loopState, $loopStatePath, $repository)
            Resume-ReviewLoopHostGateRecovery `
                -Config $profile -State $loopState -StatePath $loopStatePath `
                -RepoPath $repository
        } $config $state $statePath $repo

        $resumed | Should Be $true
        Test-Path -LiteralPath (Join-Path $repo "target-test-mutated.txt") | Should Be $false
        (Get-Content -Raw -LiteralPath (Join-Path $repo "README.txt")).Trim() |
            Should Be "verified fix"
        (Read-ReviewLoopState -Path $statePath).ActiveHostGateRecovery | Should BeNullOrEmpty
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
            Verification = $finding.Verification
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

    It "uses host-gate recovery when requalifying an already committed transaction" {
        $runRoot = Join-Path $caseRoot "requalification-gate-run"
        New-Item -ItemType Directory -Path $runRoot | Out-Null
        $statePath = Join-Path $runRoot "run-v1.json"
        $ledgerPath = Join-Path $runRoot "ledger-v2.json"
        $preHead = & git -C $repo rev-parse HEAD
        Set-Content -LiteralPath (Join-Path $repo "README.txt") -Value "verified committed change"
        $fingerprint = & (Get-Module CodexReviewLoop) {
            param($repository)
            Get-ReviewLoopWorktreeFingerprint -RepoPath $repository
        } $repo
        & git -C $repo add -A
        $tree = & git -C $repo write-tree
        & git -C $repo commit -q -m "Reliability: requalification gate"
        $commit = & git -C $repo rev-parse HEAD

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
            Verification = $finding.Verification
            PreHead = $preHead
            PatchFingerprint = $fingerprint
            ExpectedTree = $tree
            ExpectedCommit = $commit
            Message = "Reliability: requalification gate"
            NeedsCurrentGates = $true
        }
        Write-ReviewLoopState -Path $statePath -State $state | Out-Null
        $config = @{
            AutoCommit = $true
            HostGates = @(@{
                Name = "requalification gate"
                FilePath = "pwsh"
                Arguments = @(
                    "-NoProfile",
                    "-Command",
                    "Set-Content -LiteralPath requalification.tmp -Value generated; exit 0"
                )
                RepositoryChanges = @{
                    Mode = "RestoreMatching"
                    PathRegex = @("^requalification[.]tmp$")
                }
            })
        }

        $completed = & (Get-Module CodexReviewLoop) {
            param($profile, $loopState, $loopStatePath, $loopLedger,
                $loopLedgerPath, $repository, $logs)
            Complete-ReviewLoopPendingCommit `
                -Config $profile -State $loopState -StatePath $loopStatePath `
                -Ledger $loopLedger -LedgerPath $loopLedgerPath `
                -RepoPath $repository -RunRoot $logs
        } $config $state $statePath $ledger $ledgerPath $repo $runRoot

        $completed | Should Be $true
        (Test-Path -LiteralPath (Join-Path $repo "requalification.tmp")) |
            Should Be $false
        (Read-ReviewLoopState -Path $statePath).PendingCommit | Should BeNullOrEmpty
        (Read-ReviewLoopLedger -Path $ledgerPath).Findings[0].Status |
            Should Be "resolved"
    }

    It "requalifies failed reviewing with concise new ReviewerInstructions on normal resume" {
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
                -ConfigPath $path -ReviewerInstructions ('historical long guidance '*200)
        } $configPath
        $state = New-ReviewLoopState -RepoPath $repo -ReviewBase HEAD -Speed standard `
            -RunRoot $paths.RunRoot -ReviewBaseCommit $head `
            -ExecutionFingerprint $previousFingerprint
        $state.Status = "failed"
        $state.Stage = "reviewing"
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
            -ReviewerInstructions 'Prüfe A29 gemäß Paketkarte.' -CodexPath $fakeCodex -HeartbeatSeconds 0 -ColorMode Never

        $result.Status | Should Be "completed"
        $result.CleanPasses | Should Be 2
        # Resume finishes the already started cycle before advancing to the next.
        $result.ReviewCycles | Should Be 2
        $reviewCalls = @(Get-Content -LiteralPath $env:CODEX_REVIEW_LOOP_FAKE_LOG |
            ForEach-Object { $_ | ConvertFrom-Json } |
            Where-Object { $_.callKind -eq "review" })
        $reviewCalls.Count | Should Be 2
        (Read-ReviewLoopState $statePath).RunId | Should Be $state.RunId
        ($reviewCalls[0].arguments -join ' ') | Should Match 'Prüfe A29'
        ($reviewCalls[0].arguments -join ' ') | Should Not Match 'historical long guidance|Current shared task'
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

    It "orders ISO checkpoint timestamps independently of the process culture" {
        $profileRoot = Join-Path $caseRoot "iso-run-generations"
        $oldRoot = Join-Path $profileRoot "old"
        $newRoot = Join-Path $profileRoot "new"
        New-Item -ItemType Directory -Path $oldRoot, $newRoot -Force | Out-Null
        $old = New-ReviewLoopState -RepoPath $repo -ReviewBase HEAD -Speed standard `
            -RunRoot $oldRoot
        $old.Status = "completed"
        $old.Stage = "completed"
        $old.CreatedAt = "2026-08-09T10:19:09.0000000+02:00"
        Write-ReviewLoopState -Path (Join-Path $oldRoot "run-v1.json") -State $old | Out-Null
        $new = New-ReviewLoopState -RepoPath $repo -ReviewBase HEAD -Speed standard `
            -RunRoot $newRoot
        $new.CreatedAt = "2026-08-13T07:48:16.0000000+02:00"
        $newPath = Join-Path $newRoot "run-v1.json"
        Write-ReviewLoopState -Path $newPath -State $new | Out-Null
        $previousCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture

        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture =
                [System.Globalization.CultureInfo]::GetCultureInfo("de-DE")
            $selected = & (Get-Module CodexReviewLoop) {
                param($root)
                Get-ReviewLoopLatestActiveStatePath -ProfileRoot $root
            } $profileRoot
        }
        finally {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = $previousCulture
        }

        $selected | Should Be $newPath
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

Describe "Bounded native transport and concise role context" -Tags @("Process") {
    AfterEach { Clear-ReliabilityTestCase }

    It "matches actual Windows quoting including Unicode backslashes quotes and empty arguments" {
        $info=[Diagnostics.ProcessStartInfo]::new()
        $info.FileName=Join-Path $PSHOME 'pwsh.exe'
        @('', 'simple', 'a b', '你好😀', 'quoted"value', 'trail slash\', 'slash\\"quote') | ForEach-Object { [void]$info.ArgumentList.Add($_) }
        $native=[Diagnostics.ProcessStartInfo].GetMethod('BuildArguments',[Reflection.BindingFlags]'Instance,NonPublic').Invoke($info,@())
        $actual=& (Get-Module CodexReviewLoop) { param($i) Get-ReviewLoopProcessCommandLine $i } $info
        $actual | Should Be ('"'+$info.FileName+'" '+$native)
    }

    It "allows the Windows limit including final NUL and rejects 32768 before start" {
        $info=[Diagnostics.ProcessStartInfo]::new()
        $info.FileName=Join-Path $PSHOME 'pwsh.exe'
        $info.Arguments='x'*(506-$info.FileName.Length-4)
        & (Get-Module CodexReviewLoop) { param($i) Assert-ReviewLoopProcessCommandLine $i } $info
        $info.Arguments='x'*(32766-$info.FileName.Length-4)
        & (Get-Module CodexReviewLoop) { param($i) Assert-ReviewLoopProcessCommandLine $i } $info
        $info.Arguments+='x'
        & (Get-Module CodexReviewLoop) { param($i) Assert-ReviewLoopProcessCommandLine $i } $info
        $info.Arguments+='x'
        { & (Get-Module CodexReviewLoop) { param($i) Assert-ReviewLoopProcessCommandLine $i } $info } | Should Throw '32768 UTF-16'
    }

    It "starts a native Reviewer with valid guidance beyond the former 500-character cap" {
        $case=New-ReliabilityTestCase
        $guidance='x'*1200
        $call=Invoke-CodexCliRole -Role Reviewer -RepoPath $case.Repo -Model fake -Thinking high -Speed standard -Mode Review -ReviewBase HEAD -Prompt '' -DeveloperInstructions $guidance -LogRoot $case.LogRoot -MaxAttempts 1 -CodexPath $fakeCodex
        $call.Success | Should Be $true
        $record=Get-Content $env:CODEX_REVIEW_LOOP_FAKE_LOG | ConvertFrom-Json
        ($record.arguments -join ' ') | Should Match $guidance
    }

    It "rejects a Windows-overlong native Reviewer before any fake child starts" {
        $case=New-ReliabilityTestCase
        $call=Invoke-CodexCliRole -Role Reviewer -RepoPath $case.Repo -Model fake -Thinking high -Speed standard -Mode Review -ReviewBase HEAD -Prompt '' -DeveloperInstructions ('x'*40000) -LogRoot $case.LogRoot -MaxAttempts 1 -CodexPath $fakeCodex
        $call.Success | Should Be $false
        $call.FailureReason | Should Match 'maximum is 32767'
        Test-Path $env:CODEX_REVIEW_LOOP_FAKE_LOG | Should Be $false
    }

    It "keeps short native review guidance and base without state or Critic serialization" {
        $case=New-ReliabilityTestCase
        $config=Import-PowerShellDataFile $case.ConfigPath
        $config.ReviewerInstructions='Prüfe A29 gemäß Paketkarte.'
        $state=New-ReviewLoopState -RepoPath $case.Repo -ReviewBase HEAD -Speed standard -RunRoot $case.LogRoot -ReviewBaseCommit (& git -C $case.Repo rev-parse HEAD)
        $state.RetainedCandidate=[pscustomobject]@{Snapshot=[pscustomobject]@{Refs=@('DO_NOT_SERIALIZE'*5000)}}
        $state.TaskContext='DO_NOT_SERIALIZE'
        $call=& (Get-Module CodexReviewLoop) { param($c,$s,$r,$log,$fake) Invoke-ConfiguredCodexRole -Config $c -Role Reviewer -RepoPath $r -Speed standard -Mode Review -ReviewBase HEAD -Prompt '' -LogRoot $log -CallId review-short -State $s -StatePath (Join-Path $log 'run-v1.json') -CodexPath $fake } $config $state $case.Repo $case.LogRoot $fakeCodex
        $call.Success | Should Be $true
        $record=Get-Content $env:CODEX_REVIEW_LOOP_FAKE_LOG | ConvertFrom-Json
        ($record.arguments -join ' ') | Should Match 'review --base HEAD'
        ($record.arguments -join ' ') | Should Match 'Prüfe A29'
        ($record.arguments -join ' ') | Should Not Match 'DO_NOT_SERIALIZE'
        $record.prompt | Should Be ''
    }

    It "passes structured exec and resume result schema and repository through equivalent short paths" {
        $case=New-ReliabilityTestCase
        $schema=Join-Path $root 'schemas/architecture-advice-v3.schema.json'
        $env:CODEX_REVIEW_LOOP_FAKE_RESULT='{"schemaVersion":"3.0","summary":"ok","approach":"ok","steps":[],"considerations":[],"orders":[],"selectedWorkIds":[]}'
        $callId='C-fbd6b50629c73f09-c2-architect-assess-full-stable-call-identity'
        $stem=& (Get-Module CodexReviewLoop) {param($id) Get-ReviewLoopRoleArtifactStem -CallId $id -Role Architect} $callId
        foreach($mode in @('Exec','Resume')) {
            $call=Invoke-CodexCliRole -Role Architect -CallId $callId -RepoPath $case.Repo -Model fake -Thinking high -Speed standard -Mode $mode -ThreadId fake-thread -Prompt 'Current concise task' -SchemaPath $schema -LogRoot $case.LogRoot -CodexPath $fakeCodex
            $call.Success | Should Be $true
            $call.CallId | Should Be $callId
            $leaf=if($mode-eq'Exec'){"$stem.result.json"}else{"$stem-run2.result.json"}
            [IO.Path]::GetFileName($call.ResultPath) | Should Be $leaf
            (Get-Content $call.ResultPath -Raw|ConvertFrom-Json).summary | Should Be 'ok'
            if($mode-eq'Exec') {$firstPath=$call.ResultPath;$firstHash=(Get-FileHash $firstPath).Hash}
        }
        (Get-FileHash $firstPath).Hash | Should Be $firstHash
        $calls=@(Get-Content $env:CODEX_REVIEW_LOOP_FAKE_LOG|ForEach-Object{$_|ConvertFrom-Json})
        $calls[1].callKind | Should Be 'resume'
        foreach($record in $calls) {
            $record.prompt | Should Be 'Current concise task'
            $record.schemaPath | Should Not BeNullOrEmpty
            [IO.Path]::IsPathRooted($record.resultPath) | Should Be $false
        }
    }

    It "excludes snapshots history and outcome evidence and emits each active objective once" {
        $case=New-ReliabilityTestCase
        $s=New-ReviewLoopState -RepoPath $case.Repo -ReviewBase HEAD -Speed standard -RunRoot $case.LogRoot -ReviewBaseCommit (& git -C $case.Repo rev-parse HEAD)
        $s.ArchitectWork.Goal=[pscustomobject]@{statement='CURRENT_GOAL';sources=@('PRIVATE_TECHNICAL_EVIDENCE');uncertainties=@()}
        $s.ArchitectWork.OrientationRequired=$false
        & (Get-Module CodexReviewLoop) { param($state) Merge-ReviewLoopWorkOrders -State $state -Orders @([pscustomobject]@{id='W-1';objective='CURRENT_OBJECTIVE';rationale='PRIVATE_TECHNICAL_EVIDENCE';doneWhen='CURRENT_DONE';evidence=@('PRIVATE_TECHNICAL_EVIDENCE')}) } $s
        $s.ActiveWorkIds=@('W-1')
        foreach($role in @('Architect','Fixer')) {
            $text=& (Get-Module CodexReviewLoop) { param($state,$repo,$role) Get-ReviewLoopSharedContextInstructions -State $state -RepoPath $repo -Role $role } $s $case.Repo $role
            foreach($token in @('CURRENT_GOAL','CURRENT_OBJECTIVE','CURRENT_DONE')) { [regex]::Matches($text,$token).Count | Should Be 1 }
            $text | Should Not Match 'PRIVATE_TECHNICAL_EVIDENCE|RetainedCandidate|outcomeEvidence|Refs'
        }
        foreach($role in @('Reviewer','Critic','LessonsLearned')) {
            (& (Get-Module CodexReviewLoop) { param($state,$repo,$role) Get-ReviewLoopSharedContextInstructions -State $state -RepoPath $repo -Role $role } $s $case.Repo $role) | Should Be ''
        }
    }
}
