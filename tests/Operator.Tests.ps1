$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
$fakeCodex = Join-Path $here 'FakeCodex.ps1'
Import-Module (Join-Path $root 'CodexReviewLoop.psd1') -Force
. (Join-Path $here 'ArchitectureFixtures.ps1')

function New-OperatorCase {
    $caseRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    $repo = Join-Path $caseRoot 'repo'
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
    & git -C $repo init -q
    & git -C $repo config user.email 'operator@example.invalid'
    & git -C $repo config user.name 'Operator Tests'
    Set-Content (Join-Path $repo 'README.txt') 'initial'
    & git -C $repo add README.txt
    & git -C $repo commit -q -m initial
    if ($LASTEXITCODE -ne 0) { throw 'Cannot create operator Git fixture.' }
    $logs = New-TestLogRoot $root
    $profile = Join-Path $caseRoot 'profile.psd1'
    @"
@{
 Name='Operator'; RepositoryPath='$($repo.Replace("'","''"))'; ReviewBase='HEAD'
 LogRoot='$($logs.Replace("'","''"))'; CleanPassesRequired=1; MaxReviewCycles=4
 MaxFixAttempts=2; CriticStartAfterReviews=0; LessonsLearnedCommitThreshold=0
 AutoCommit=`$true; HostGates=@(); Roles=@{
 Reviewer=@{Model='fake';Thinking='high'}; Architect=@{Model='fake';Thinking='high'}
 Fixer=@{Model='fake';Thinking='high'} }
}
"@ | Set-Content $profile
    $paths = & (Get-Module CodexReviewLoop) {
        param($repo,$profile)
        $config = Import-ReviewLoopConfig -ConfigPath $profile -RepoPath $repo
        $paths = New-ReviewLoopRunPaths -Config $config -RepoPath $repo
        Initialize-ReviewLoopRunPaths $paths | Out-Null
        $state = New-ReviewLoopState -RepoPath $repo -ReviewBase HEAD -Speed standard `
            -RunRoot $paths.RunRoot -ReviewBaseCommit (Get-ReviewLoopGitValue $repo @('rev-parse','HEAD')) `
            -ExecutionFingerprint (Get-ReviewLoopExecutionFingerprint -ConfigPath $profile)
        Write-ReviewLoopState $paths.StatePath $state | Out-Null
        $paths
    } $repo $profile
    $env:CODEX_REVIEW_LOOP_FAKE_LOG = Join-Path $caseRoot 'calls.jsonl'
    $script:operatorCase = [pscustomobject]@{ Repo=$repo; Root=$caseRoot; Paths=$paths; Profile=$profile; Logs=$logs }
    return $script:operatorCase
}

function Invoke-OperatorRole {
    param($Case, [string]$Role='Architect', [string]$CallId='operator-call')
    & (Get-Module CodexReviewLoop) {
        param($case,$role,$id,$fake)
        $state = Read-ReviewLoopState $case.Paths.StatePath
        $config = Import-ReviewLoopConfig -ConfigPath $case.Profile -RepoPath $case.Repo
        $schema = switch ($role) { Architect {'architecture-orientation-v1.schema.json'}; Fixer {'fixer-result-v3.schema.json'}; default {''} }
        $mode = if ($role -eq 'Reviewer') { 'Review' } else { 'Exec' }
        $prompt = if ($role -eq 'Reviewer') { '' } else { 'Inspect the current evidence.' }
        Invoke-ConfiguredCodexRole -Config $config -Role $role -RepoPath $case.Repo -Speed standard `
            -Prompt $prompt -Mode $mode -ReviewBase HEAD -SchemaName $schema -CallId $id `
            -State $state -StatePath $case.Paths.StatePath -LogRoot $case.Paths.RunRoot -CodexPath $fake
    } $Case $Role $CallId $fakeCodex
}

function Get-OperatorCalls {
    @(Get-Content $env:CODEX_REVIEW_LOOP_FAKE_LOG | ForEach-Object { $_ | ConvertFrom-Json })
}

function Set-OperatorPlans {
    param($Case, [object[]]$Plans)
    $env:CODEX_REVIEW_LOOP_FAKE_INVOCATION_SEQUENCE=Join-Path $Case.Root 'plans.json'
    ConvertTo-Json -InputObject @($Plans) -Depth 20 | Set-Content $env:CODEX_REVIEW_LOOP_FAKE_INVOCATION_SEQUENCE
}

function Get-OperatorAcceptResult {
    '{"schemaVersion":"2.0","accept":true,"summary":"Accepted.","feedback":[],"commitMessage":{"subject":"Handle operator evidence","rationale":"The evidence is addressed.","changes":["Update the owned candidate."]},"newOrders":[],"workOutcomes":[],"goalComplete":true}'
}

function Invoke-OperatorLoop {
    param($Case)
    Invoke-CodexReviewLoop -RepoPath $Case.Repo -ConfigPath $Case.Profile -CodexPath $fakeCodex -HeartbeatSeconds 0 -Json
}

function New-OperatorPausePlan {
    param($Case, [string]$At)
    @{ runRoot = $Case.Paths.RunRoot; pauseAt = $At; message = 'Investigate the evidence.' }
}

function Clear-OperatorCase {
        & (Get-Module CodexReviewLoop) { Initialize-ReviewLoopConsole -TranscriptPath '' -HostOutputEnabled $false }
        if ($null -ne $script:operatorCase) {
            $state=Read-ReviewLoopState $script:operatorCase.Paths.StatePath
            $mailbox=& (Get-Module CodexReviewLoop) { param($s) Get-ReviewLoopOperatorMailbox $s } $state
            $expected=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CodexReviewLoop\operator'
            if ([IO.Path]::GetDirectoryName($mailbox) -ine $expected) { throw 'Unsafe operator test cleanup.' }
            if (Test-Path $mailbox) { Remove-Item -LiteralPath $mailbox -Recurse -Force }
        }
        Clear-TestLogRoots $root
        Get-ChildItem Env:CODEX_REVIEW_LOOP_FAKE_* | Remove-Item
        $script:operatorCase=$null
}

function Invoke-OperatorCritic {
    param($Case)
    & (Get-Module CodexReviewLoop) {
        param($c,$fake)
        $s = Read-ReviewLoopState $c.Paths.StatePath
        $config = Import-ReviewLoopConfig -ConfigPath $c.Profile -RepoPath $c.Repo
        Invoke-ReviewLoopCriticGate -Config $config -State $s -StatePath $c.Paths.StatePath `
            -Ledger (New-ReviewLoopLedger $c.Repo) -RepoPath $c.Repo -Speed standard `
            -RunRoot $c.Paths.RunRoot -CodexPath $fake
    } $Case $fakeCodex
}

Describe 'One-time Operator Critic requests' {
    AfterEach {
        & (Get-Module CodexReviewLoop) { $script:ReviewLoopRetryDelayOverride = $null }
        Clear-OperatorCase
    }

    It 'publishes immutable isolated requests with the existing identity and message limits' {
        $c = New-OperatorCase
        $id = [guid]::NewGuid().ToString('D')
        Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -RequestCritic -Message 'CAUSE evidence.log' -Id $id | Should Be $id
        (& (Join-Path $root 'operator-message.ps1') $c.Paths.RunRoot -RequestCritic -Message 'CAUSE evidence.log' -Id $id) | Should Match "$id requested Critic"
        { Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -RequestCritic -Message 'different' -Id $id } | Should Throw 'different content'
        foreach ($extra in @(@{To='Architect'}, @{RequireDelivery=$true}, @{PauseAt='AfterRole'}, @{ReassessArchitect=$true})) {
            $caught = $false
            try { Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -RequestCritic -Message mixed @extra -ErrorAction Stop }
            catch { $caught = $true }
            $caught | Should Be $true
        }
        { Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -RequestCritic -Message ('x' * 4001) } | Should Throw '4000'
        { Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -RequestCritic -Message ' ' } | Should Throw '4000'
        @((Read-ReviewLoopState $c.Paths.StatePath).Operator.Requests).Count | Should Be 0
        Invoke-OperatorCritic $c
        $s = Read-ReviewLoopState $c.Paths.StatePath
        $s.Operator.Version | Should Be 4
        $s.Operator.Requests[0].Status | Should Be handled
        $s.Operator.Requests[0].RequireDelivery | Should Be $false
        @($s.Operator.Requests[0].Deliveries).Count | Should Be 0
        $s.Operator.Revisions.Architect | Should Be 0
        @(& git -C $c.Repo status --porcelain).Count | Should Be 0
    }

    It 'runs explicitly with disabled or not-yet-due automation and coalesces a due automatic critique' {
        foreach ($threshold in @(0,5,1)) {
            $c = New-OperatorCase
            (Get-Content -Raw $c.Profile).Replace('CriticStartAfterReviews=0',"CriticStartAfterReviews=$threshold") | Set-Content $c.Profile
            & (Get-Module CodexReviewLoop) {
                param($c)
                $s = Read-ReviewLoopState $c.Paths.StatePath
                $s.RoleCalls = @([pscustomobject]@{ Role='Reviewer'; Success=$true; CallId='review-01' })
                $s.ReviewCycle = 1; $s.Stage = 'clean_review'
                Write-ReviewLoopState $c.Paths.StatePath $s | Out-Null
            } $c
            $profileHash = (Get-FileHash $c.Profile).Hash
            $id = Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -RequestCritic -Message 'ROOT_CAUSE evidence.log'
            Invoke-OperatorCritic $c
            Invoke-OperatorCritic $c
            $calls = @(Get-OperatorCalls)
            $calls.Count | Should Be 1
            $calls[0].prompt | Should Match ROOT_CAUSE
            $calls[0].prompt | Should Match $id
            $calls[0].prompt | Should Match 'Run retrospective:|Previous critiques:'
            (Get-FileHash $c.Profile).Hash | Should Be $profileHash
            $s = Read-ReviewLoopState $c.Paths.StatePath
            @($s.RoleCalls | Where-Object Role -eq Critic).Count | Should Be 1
            $s.RoleCalls[-1].CoveredReviewCount | Should Be 1
            $s.ReviewCyclesThisInvocation | Should Be 0
            $s.CleanPasses | Should Be 0
            Clear-OperatorCase
        }
    }

    It 'batches pending requests once and uses distinct calls for new requests at the same review count' {
        $c = New-OperatorCase
        $first = Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -RequestCritic -Message FIRST
        Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -RequestCritic -Message FIRST -Id $first | Should Be $first
        $second = Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -RequestCritic -Message SECOND
        Invoke-OperatorCritic $c
        $third = Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -RequestCritic -Message THIRD
        Invoke-OperatorCritic $c
        Invoke-OperatorCritic $c
        $calls = Get-OperatorCalls
        $calls.Count | Should Be 2
        $calls[0].prompt | Should Match FIRST
        $calls[0].prompt | Should Match SECOND
        $calls[1].prompt | Should Match THIRD
        $s = Read-ReviewLoopState $c.Paths.StatePath
        @($s.Operator.Requests | Where-Object Status -eq handled).Count | Should Be 3
        @($s.RoleCalls[0].OperatorMessageIds | Sort-Object) | Should Be @(@($first,$second) | Sort-Object)
        $s.RoleCalls[1].OperatorMessageIds | Should Be @($third)
        $s.RoleCalls[0].CallId | Should Not Be $s.RoleCalls[1].CallId
    }

    It 'keeps arrivals during a running critique pending and routes feedback separately' {
        $c = New-OperatorCase
        $first = Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -RequestCritic -Message FIRST
        Set-OperatorPlans $c @(@{operatorMessages=@(@{runRoot=$c.Paths.RunRoot;requestCritic=$true;message='LATE_EVIDENCE'})})
        Invoke-OperatorCritic $c
        $s = Read-ReviewLoopState $c.Paths.StatePath
        ($s.Operator.Requests | Where-Object Id -eq $first).Status | Should Be handled
        ($s.Operator.Requests | Where-Object Message -eq LATE_EVIDENCE).Status | Should Be pending
        @($s.RoleCalls[-1].OperatorMessageIds) | Should Be @($first)
        (Get-OperatorCalls)[0].prompt | Should Not Match LATE_EVIDENCE
        Remove-Item Env:CODEX_REVIEW_LOOP_FAKE_INVOCATION_SEQUENCE
        (Invoke-OperatorRole $c -Role Architect).Success | Should Be $true
        (Invoke-OperatorRole $c -Role Fixer).Success | Should Be $true
        (Invoke-OperatorRole $c -Role Reviewer).Success | Should Be $true
        $calls = Get-OperatorCalls
        $calls[1].prompt | Should Match 'Architect: make coherent decisions'
        $calls[1].prompt | Should Not Match 'Reviewer: examine|Fixer: implement'
        $calls[2].prompt | Should Match 'Fixer: implement'
        $calls[2].prompt | Should Not Match 'Reviewer: examine|Architect: make'
        # Preserve the native Reviewer's existing guidance surface and recorded Critic binding.
        ($calls[3].arguments -join ' ') | Should Match 'review --base HEAD'
        ($calls[3].arguments -join ' ') | Should Not Match 'Architect: make|Fixer: implement'
        (Read-ReviewLoopState $c.Paths.StatePath).RoleCalls[-1].CriticId | Should Be $s.RoleCalls[-1].CallId
    }

    It 'defers requests throughout work and sealed commit transactions' {
        $c = New-OperatorCase
        $id = Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -RequestCritic -Message DEFER
        foreach ($stage in @('fixing','verifying','verified','commit_preparing','commit_pending','reviewed')) {
            $s = Read-ReviewLoopState $c.Paths.StatePath
            $s.Stage = $stage
            Write-ReviewLoopState $c.Paths.StatePath $s | Out-Null
            Invoke-OperatorCritic $c
            (Read-ReviewLoopState $c.Paths.StatePath).Operator.Requests[0].Status | Should Be pending
        }
        & (Get-Module CodexReviewLoop) {
            param($c)
            $s = Read-ReviewLoopState $c.Paths.StatePath
            $s.Stage = 'fix_committed'; $s.PendingCommit = [pscustomobject]@{marker='owned'}
            Close-ReviewLoopOperatorBoundary $s $c.Paths.StatePath commit | Out-Null
        } $c
        Invoke-OperatorCritic $c
        Test-Path $env:CODEX_REVIEW_LOOP_FAKE_LOG | Should Be $false
        $s = Read-ReviewLoopState $c.Paths.StatePath
        $s.PendingCommit.marker | Should Be owned
        $s.Operator.Boundary.Kind | Should Be commit
        $s.PendingCommit = $null
        Write-ReviewLoopState $c.Paths.StatePath $s | Out-Null
        Invoke-OperatorCritic $c
        (Read-ReviewLoopState $c.Paths.StatePath).Operator.Requests[0].Status | Should Be handled
    }

    It 'finishes fixing testing assessment and commit gates before one requested critique' {
        $c = New-OperatorCase
        $before = (& git -C $c.Repo rev-parse HEAD).Trim()
        $test = Join-Path $c.Root 'targeted.ps1'
        $gate = Join-Path $c.Root 'gate.ps1'
        $marker = Join-Path $c.Root 'gate-ran.txt'
        @"
& '$root\operator-message.ps1' '$($c.Paths.RunRoot)' -RequestCritic -Message 'TARGETED_EVIDENCE' | Out-Null
"@ | Set-Content $test
        @"
if (-not (Test-Path -LiteralPath '$marker')) {
    & '$root\operator-message.ps1' '$($c.Paths.RunRoot)' -RequestCritic -Message 'GATE_EVIDENCE' | Out-Null
    Set-Content -LiteralPath '$marker' executed
}
"@ | Set-Content $gate
        (Get-Content -Raw $c.Profile).Replace('HostGates=@()', "HostGates=@(@{Name='request gate';FilePath='pwsh';Arguments=@('-NoProfile','-File','$gate')})") | Set-Content $c.Profile
        $fixer = @{schemaVersion='3.0';summary='Fixed';targetedTest=@{available=$true;executable='pwsh';arguments=@('-NoProfile','-File',$test)}} | ConvertTo-Json -Depth 6 -Compress
        Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -To Fixer -Message fix -RequireDelivery | Out-Null
        Set-OperatorPlans $c @(
            @{result=$fixer;mutations=@(@{path='README.txt';content='fixed'});operatorMessages=@(@{runRoot=$c.Paths.RunRoot;requestCritic=$true;message='FIXER_EVIDENCE'})},
            @{result=(Get-OperatorAcceptResult);operatorMessages=@(@{runRoot=$c.Paths.RunRoot;requestCritic=$true;message='ASSESSMENT_EVIDENCE'})},
            @{}, @{result='No findings.'})
        $result = Invoke-OperatorLoop $c
        if ($result.Status -ne 'completed') { throw $result.Reason }
        (& git -C $c.Repo rev-list --count "$before..HEAD") | Should Be 1
        $s = Read-ReviewLoopState $c.Paths.StatePath
        $requests = @($s.Operator.Requests | Where-Object Kind -eq critic_request)
        $requests.Count | Should Be 4
        @($requests | Where-Object Status -ne handled).Count | Should Be 0
        @($requests.CallId | Select-Object -Unique).Count | Should Be 1
        $calls = @(Get-OperatorCalls | Where-Object { $_.phase -notin @('orientation','completion') })
        [IO.Path]::GetFileName($calls[0].schemaPath) | Should Be fixer-result-v3.schema.json
        [IO.Path]::GetFileName($calls[1].schemaPath) | Should Be architecture-assessment-v2.schema.json
        [IO.Path]::GetFileName($calls[2].schemaPath) | Should Be critic-v2.schema.json
        $calls[2].prompt | Should Match FIXER_EVIDENCE
        $calls[2].prompt | Should Match TARGETED_EVIDENCE
        $calls[2].prompt | Should Match ASSESSMENT_EVIDENCE
        $calls[2].prompt | Should Match GATE_EVIDENCE
        $critic = $s.RoleCalls | Where-Object Role -eq Critic
        $critic.RepositoryHead | Should Be $s.CurrentHead
        @($s.RoleCalls | Where-Object Role -eq Fixer).Count | Should Be 1
        $s.ActiveHostGateRecovery | Should BeNullOrEmpty
        $s.PendingCommit | Should BeNullOrEmpty
    }

    It 'recovers a prepared commit before handling a later Critic request' {
        $c = New-OperatorCase
        $before = (& git -C $c.Repo rev-parse HEAD).Trim()
        Set-Content (Join-Path $c.Repo 'README.txt') candidate
        & (Get-Module CodexReviewLoop) {
            param($c)
            $s = Read-ReviewLoopState $c.Paths.StatePath
            $s.ActiveFindingSource = 'operator'; $s.ActiveClusterId = 'pending-critic'
            $s.Stage = 'commit_preparing'
            Write-ReviewLoopLedger $c.Paths.LedgerPath (New-ReviewLoopLedger $c.Repo) | Out-Null
            Close-ReviewLoopOperatorBoundary $s $c.Paths.StatePath commit | Out-Null
            $s.PendingCommit = [pscustomobject]@{
                PreHead=$s.CurrentHead; PatchFingerprint=Get-ReviewLoopWorktreeFingerprint $c.Repo
                ExpectedTree='';ExpectedCommit='';Message='Test: prepared candidate';NeedsCurrentGates=$false
                OperatorBoundaryId=$s.Operator.Boundary.Id
                Verification=[pscustomobject]@{WorkRevision=0;workOutcomes=@();goalComplete=$false}
            }
            Write-ReviewLoopState $c.Paths.StatePath $s | Out-Null
        } $c
        $id = Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -RequestCritic -Message AFTER_PREPARATION
        (Invoke-OperatorLoop $c).Status | Should Be completed
        (& git -C $c.Repo rev-list --count "$before..HEAD") | Should Be 1
        $s = Read-ReviewLoopState $c.Paths.StatePath
        ($s.Operator.Requests | Where-Object Id -eq $id).Status | Should Be handled
        ($s.RoleCalls | Where-Object Role -eq Critic).RepositoryHead | Should Be $s.CurrentHead
        @((Get-OperatorCalls) | Where-Object schemaPath -match 'critic-v2').Count | Should Be 1
        $s.PendingCommit | Should BeNullOrEmpty
    }

    It 'preserves a request across a pause before start and never repeats the handled call on resume' {
        $c = New-OperatorCase
        $id = Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -RequestCritic -Message RESUME
        Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -PauseAt AfterRole -Message 'before start' | Out-Null
        (Invoke-OperatorLoop $c).Status | Should Be paused
        ($s = Read-ReviewLoopState $c.Paths.StatePath).Operator.Requests | Out-Null
        ($s.Operator.Requests | Where-Object Id -eq $id).Status | Should Be pending
        Set-OperatorPlans $c @(@{operatorMessages=@((New-OperatorPausePlan $c AfterRole))})
        (Invoke-OperatorLoop $c).Status | Should Be paused
        ($s = Read-ReviewLoopState $c.Paths.StatePath).Operator.Requests | Out-Null
        ($s.Operator.Requests | Where-Object Id -eq $id).Status | Should Be handled
        Remove-Item Env:CODEX_REVIEW_LOOP_FAKE_INVOCATION_SEQUENCE
        (Invoke-OperatorLoop $c).Status | Should Be completed
        @((Get-OperatorCalls) | Where-Object schemaPath -match 'critic-v2').Count | Should Be 1
    }

    It 'leaves requests pending at an exhausted review budget and handles them after explicit resume' {
        $c = New-OperatorCase
        (Get-Content -Raw $c.Profile).Replace('MaxReviewCycles=4','MaxReviewCycles=1').Replace('CleanPassesRequired=1','CleanPassesRequired=2') | Set-Content $c.Profile
        Set-OperatorPlans $c @(@{result='No findings.';operatorMessages=@(@{runRoot=$c.Paths.RunRoot;requestCritic=$true;message='NEXT_INVOCATION'})})
        (Invoke-OperatorLoop $c).Status | Should Be limit_reached
        $s = Read-ReviewLoopState $c.Paths.StatePath
        ($s.Operator.Requests | Where-Object Kind -eq critic_request).Status | Should Be pending
        @((Get-OperatorCalls) | Where-Object schemaPath -match 'critic-v2').Count | Should Be 0
        Remove-Item Env:CODEX_REVIEW_LOOP_FAKE_INVOCATION_SEQUENCE
        (Invoke-OperatorLoop $c).Status | Should Be completed
        @((Get-OperatorCalls) | Where-Object schemaPath -match 'critic-v2').Count | Should Be 1
        (Read-ReviewLoopState $c.Paths.StatePath).ReviewCycle | Should Be 2
    }

    It 'retains failed request bindings with or without a thread and restores Critic mutations on resume' {
        foreach ($emitThread in @($true,$false)) {
            $c = New-OperatorCase
            & (Get-Module CodexReviewLoop) { $script:ReviewLoopRetryDelayOverride = {param($seconds)} }
            $id = Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -RequestCritic -Message ORIGINAL
            $env:CODEX_REVIEW_LOOP_FAKE_EXIT_CODE = '1'
            Set-OperatorPlans $c @(@{exitCode=1;emitThread=$emitThread;mutations=@(@{path='README.txt';content='critic mutation'})},
                @{exitCode=1;emitThread=$emitThread}, @{exitCode=1;emitThread=$emitThread})
            $caught = $false
            try { Invoke-OperatorCritic $c } catch { $caught = $true }
            $caught | Should Be $true
            $s = Read-ReviewLoopState $c.Paths.StatePath
            $s.ActiveCriticCall.CriticRequests[0].Id | Should Be $id
            $s.Operator.Requests[0].Status | Should Be pending
            (Get-Content (Join-Path $c.Repo 'README.txt')) | Should Be initial
            $callId = $s.ActiveCriticCall.CallId
            $thread = $s.ActiveCriticCall.ThreadId
            $late = Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -RequestCritic -Message LATE
            Remove-Item Env:CODEX_REVIEW_LOOP_FAKE_EXIT_CODE,Env:CODEX_REVIEW_LOOP_FAKE_INVOCATION_SEQUENCE
            Invoke-OperatorCritic $c
            $s = Read-ReviewLoopState $c.Paths.StatePath
            $s.RoleCalls[-1].CallId | Should Be $callId
            @($s.RoleCalls[-1].OperatorMessageIds) | Should Be @($id)
            ($s.Operator.Requests | Where-Object Id -eq $late).Status | Should Be pending
            if ($emitThread) { (Get-OperatorCalls)[-1].resumeThreadId | Should Be $thread }
            else { (Get-OperatorCalls)[-1].prompt | Should Match ORIGINAL }
            Invoke-OperatorCritic $c
            (Read-ReviewLoopState $c.Paths.StatePath).RoleCalls[-1].CallId | Should Not Be $callId
            Clear-OperatorCase
        }
    }

    It 'keeps an invalid Critic result pending until a valid structured result is recovered' {
        $c = New-OperatorCase
        & (Get-Module CodexReviewLoop) { $script:ReviewLoopRetryDelayOverride = {param($seconds)} }
        Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -RequestCritic -Message INVALID | Out-Null
        $env:CODEX_REVIEW_LOOP_FAKE_RESULT = '{"schemaVersion":"invalid"}'
        $caught = $false
        try { Invoke-OperatorCritic $c } catch { $caught = $true }
        $caught | Should Be $true
        $s = Read-ReviewLoopState $c.Paths.StatePath
        $s.Operator.Requests[0].Status | Should Be pending
        $s.ActiveCriticCall | Should Not BeNullOrEmpty
        Remove-Item Env:CODEX_REVIEW_LOOP_FAKE_RESULT
        Invoke-OperatorCritic $c
        (Read-ReviewLoopState $c.Paths.StatePath).Operator.Requests[0].Status | Should Be handled
    }

    It 'lets completion supersede a request published during final assessment and rejects new requests afterwards' {
        $c = New-OperatorCase
        Set-OperatorPlans $c @(@{result='No findings.'}, @{phase='completion';result=(Get-OperatorAcceptResult);operatorMessages=@(@{runRoot=$c.Paths.RunRoot;requestCritic=$true;message='FINAL_PHASE'})})
        $result = Invoke-OperatorLoop $c
        if ($result.Status -ne 'completed') { throw $result.Reason }
        $s = Read-ReviewLoopState $c.Paths.StatePath
        $request = $s.Operator.Requests | Where-Object Kind -eq critic_request
        $request.Status | Should Be superseded
        @((Get-OperatorCalls) | Where-Object schemaPath -match 'critic-v2').Count | Should Be 0
        { Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -RequestCritic -Message NEW } | Should Throw 'completion is sealed'
        Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -RequestCritic -Message FINAL_PHASE -Id $request.Id | Should Be $request.Id
    }

    It 'supersedes an already pending request when clean completion takes precedence' {
        $c = New-OperatorCase
        Set-OperatorPlans $c @(@{result='No findings.';operatorMessages=@(@{runRoot=$c.Paths.RunRoot;requestCritic=$true;message='CLEAN_GATE'})})
        (Invoke-OperatorLoop $c).Status | Should Be completed
        (Read-ReviewLoopState $c.Paths.StatePath).Operator.Requests[0].Status | Should Be superseded
        @((Get-OperatorCalls) | Where-Object schemaPath -match 'critic-v2').Count | Should Be 0
    }

    It 'rejects wrong-run and malformed Critic requests without changing role revisions' {
        $c = New-OperatorCase
        $wrong = Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -RequestCritic -Message WRONG
        $bad = Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -RequestCritic -Message BAD
        & (Get-Module CodexReviewLoop) {
            param($c,$wrong,$bad)
            $s = Read-ReviewLoopState $c.Paths.StatePath
            $mailbox = Get-ReviewLoopOperatorMailbox $s
            $r = Read-ReviewLoopJson (Join-Path $mailbox "$wrong.json")
            $r.Run.RunId = 'other-run'
            Write-ReviewLoopUtf8File (Join-Path $mailbox "$wrong.json") ($r | ConvertTo-Json -Depth 10)
            $r = Read-ReviewLoopJson (Join-Path $mailbox "$bad.json")
            $r | Add-Member RequireDelivery $true
            Write-ReviewLoopUtf8File (Join-Path $mailbox "$bad.json") ($r | ConvertTo-Json -Depth 10)
        } $c $wrong $bad
        Invoke-OperatorCritic $c
        $s = Read-ReviewLoopState $c.Paths.StatePath
        ($s.Operator.Requests | Where-Object Id -eq $wrong).Rejection | Should Be 'run identity mismatch'
        ($s.Operator.Requests | Where-Object Id -eq $bad).Rejection | Should Be 'invalid request'
        $s.Operator.Revisions.Architect | Should Be 0
        Test-Path $env:CODEX_REVIEW_LOOP_FAKE_LOG | Should Be $false
    }
}

Describe 'Durable operator messages' {
    AfterEach { Clear-OperatorCase }

    It 'publishes immutable messages outside the worktree and retries identical IDs' {
        $c=New-OperatorCase
        $id=[guid]::NewGuid().ToString('D')
        Send-ReviewLoopOperatorMessage $c.Paths.RunRoot @('Fixer','Architect') 'evidence' $id | Should Be $id
        Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -To Architect,Fixer -Message 'evidence' -Id $id | Should Be $id
        & (Join-Path $root 'operator-message.ps1') $c.Paths.RunRoot @('Architect','Fixer') 'evidence' $id | Should Be $id
        { Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -To Fixer -Message 'different' -Id $id } | Should Throw 'different content'
        $s=Read-ReviewLoopState $c.Paths.StatePath
        @($s.Operator.Requests).Count | Should Be 0
        $mailbox=& (Get-Module CodexReviewLoop) {param($s) Get-ReviewLoopOperatorMailbox $s} $s
        @(Get-ChildItem $mailbox -Filter '*.json').Count | Should Be 1
        @(& git -C $c.Repo status --porcelain).Count | Should Be 0
    }

    It 'delivers each recipient once and does not replay messages on later calls' {
        $c=New-OperatorCase
        $id=Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -To Architect,Fixer -Message 'ONE_TIME_EVIDENCE'
        (Invoke-OperatorRole $c).Success | Should Be $true
        (Invoke-OperatorRole $c -CallId next).Success | Should Be $true
        (Invoke-OperatorRole $c -Role Fixer).Success | Should Be $true
        $calls=Get-OperatorCalls
        $calls[0].prompt | Should Match 'ONE_TIME_EVIDENCE'
        $calls[1].prompt | Should Not Match 'ONE_TIME_EVIDENCE'
        $calls[1].callKind | Should Be resume
        $calls[2].prompt | Should Match 'ONE_TIME_EVIDENCE'
        $s=Read-ReviewLoopState $c.Paths.StatePath
        @($s.Operator.Requests[0].Deliveries | Where-Object Status -NE delivered).Count | Should Be 0
        @($s.RoleCalls[0].OperatorMessageIds) | Should Be @($id)
    }

    It 'invalidates a completed same-ID decision only when new addressed evidence exists' {
        $c=New-OperatorCase
        (Invoke-OperatorRole $c).Success | Should Be $true
        (Invoke-OperatorRole $c).Success | Should Be $true
        @(Get-OperatorCalls).Count | Should Be 1
        Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -To Architect -Message 'NEW_EVIDENCE' | Out-Null
        (Invoke-OperatorRole $c).Success | Should Be $true
        (Invoke-OperatorRole $c).Success | Should Be $true
        @(Get-OperatorCalls).Count | Should Be 2
        (Get-OperatorCalls)[1].prompt | Should Match NEW_EVIDENCE
    }

    It 'preserves the native Reviewer contract and delivers short developer guidance' {
        $c=New-OperatorCase
        Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -To Reviewer -Message 'REVIEW_EVIDENCE' | Out-Null
        (Invoke-OperatorRole $c -Role Reviewer).Success | Should Be $true
        $call=(Get-OperatorCalls)[0]
        $call.prompt | Should Be ''
        ($call.arguments -join ' ') | Should Match 'review --base HEAD'
        ($call.arguments -join ' ') | Should Match REVIEW_EVIDENCE
        ($call.arguments -join ' ') | Should Not Match 'output-schema|--json| -o '
    }

    It 'rejects wrong-run and malformed requests durably and ignores unpublished files' {
        $c=New-OperatorCase
        $id=Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -To Architect -Message 'wrong'
        $s=Read-ReviewLoopState $c.Paths.StatePath
        $mailbox=& (Get-Module CodexReviewLoop) {param($s) Get-ReviewLoopOperatorMailbox $s} $s
        $path=Join-Path $mailbox "$id.json"
        $request=Get-Content $path -Raw | ConvertFrom-Json
        $request.Run.RunId='another-run'
        $request | ConvertTo-Json -Depth 10 | Set-Content $path
        $bad=[guid]::NewGuid().ToString('D')
        Set-Content (Join-Path $mailbox "$bad.json") '{'
        Set-Content (Join-Path $mailbox '.unpublished.tmp') '{'
        (Invoke-OperatorRole $c).Success | Should Be $true
        $s=Read-ReviewLoopState $c.Paths.StatePath
        @($s.Operator.Requests).Count | Should Be 2
        ($s.Operator.Requests | Where-Object Id -EQ $id).Rejection | Should Match 'run identity mismatch'
        (Get-OperatorCalls)[0].prompt | Should Not Match 'wrong'
    }

    It 'keeps imported requests after a crash and resumes a bound role with new evidence' {
        $c=New-OperatorCase
        Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -To Architect -Message 'RECOVERED_EVIDENCE' | Out-Null
        & (Get-Module CodexReviewLoop) {
            param($c)
            $s=Read-ReviewLoopState $c.Paths.StatePath
            Sync-ReviewLoopOperatorMessages $s $c.Paths.StatePath
        } $c
        # Crash after the thread checkpoint but before a successful role result.
        $env:CODEX_REVIEW_LOOP_FAKE_TAIL_DELAY_MS='400'
        $c2=$c
        $s=Read-ReviewLoopState $c.Paths.StatePath
        & (Get-Module CodexReviewLoop) {
            param($s,$c)
            $snapshot=Get-ReviewLoopRepositorySnapshot $c.Repo
            $s.ActiveRoleCall=[pscustomobject]@{
                CallId='operator-call';Role='Architect';ThreadId='interrupted-operator-thread'
                RepositoryHead=$snapshot.Head;WorktreeFingerprint=$snapshot.Fingerprint;ExecutionFingerprint=''
                RepositoryBranch=$snapshot.Branch;RepositoryHeadRef=$snapshot.HeadRef
                RefsFingerprint=$snapshot.RefsFingerprint;CheckpointStage='initialized'
            }
            Write-ReviewLoopState $c.Paths.StatePath $s | Out-Null
        } $s $c
        (Invoke-OperatorRole $c2).Success | Should Be $true
        $call=(Get-OperatorCalls)[0]
        $call.callKind | Should Be resume
        $call.prompt | Should Match RECOVERED_EVIDENCE
        (Invoke-OperatorRole $c2).Success | Should Be $true
        @(Get-OperatorCalls).Count | Should Be 1
    }

    It 'seals commit requests and carries later required messages into the next phase' {
        $c=New-OperatorCase
        & (Get-Module CodexReviewLoop) {
            param($c)
            $s=Read-ReviewLoopState $c.Paths.StatePath
            @(Close-ReviewLoopOperatorBoundary $s $c.Paths.StatePath commit).Count | Should Be 0
        } $c
        Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -To Architect -Message 'NEXT_PHASE' -RequireDelivery | Out-Null
        $s=Read-ReviewLoopState $c.Paths.StatePath
        & (Get-Module CodexReviewLoop) {
            param($s,$c)
            Sync-ReviewLoopOperatorMessages $s $c.Paths.StatePath
            @($s.Operator.Requests).Count | Should Be 0
            Open-ReviewLoopOperatorBoundary $s
            Write-ReviewLoopState $c.Paths.StatePath $s | Out-Null
            @(Close-ReviewLoopOperatorBoundary $s $c.Paths.StatePath commit) | Should Be @('Architect')
            $s.Operator.Boundary | Should BeNullOrEmpty
        } $s $c
        (Invoke-OperatorRole $c).Success | Should Be $true
    }

    It 'rejects new messages after completion is sealed but permits idempotent retries' {
        $c=New-OperatorCase
        $id=Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -To Fixer -Message 'ordinary'
        & (Get-Module CodexReviewLoop) {
            param($c)
            $s=Read-ReviewLoopState $c.Paths.StatePath
            @(Close-ReviewLoopOperatorBoundary $s $c.Paths.StatePath completion).Count | Should Be 0
        } $c
        {Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -To Architect -Message 'late'} | Should Throw 'completion is sealed'
        Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -To Fixer -Message 'ordinary' -Id $id | Should Be $id
    }

    It 'forces all three recipients through existing roles before clean completion' {
        $c=New-OperatorCase
        Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -To Reviewer,Architect,Fixer -Message 'REQUIRED_ALL' -RequireDelivery | Out-Null
        $env:CODEX_REVIEW_LOOP_FAKE_INVOCATION_SEQUENCE=Join-Path $c.Root 'plans.json'
        @(
            @{result='No findings.'},
            @{result='{"schemaVersion":"3.0","summary":"No change.","targetedTest":{"available":false,"executable":"","arguments":[]}}'},
            @{result='{"schemaVersion":"2.0","accept":true,"summary":"Accepted.","feedback":[],"commitMessage":{"subject":"","rationale":"","changes":[]},"newOrders":[],"workOutcomes":[],"goalComplete":true}'},
            @{result='No findings.'}
        ) | ConvertTo-Json -Depth 10 | Set-Content $env:CODEX_REVIEW_LOOP_FAKE_INVOCATION_SEQUENCE
        $result=Invoke-CodexReviewLoop -RepoPath $c.Repo -ConfigPath $c.Profile -CodexPath $fakeCodex -HeartbeatSeconds 0 -Json
        if ($result.Status -ne 'completed') { throw $result.Reason }
        $result.Status | Should Be completed
        $s=Read-ReviewLoopState $c.Paths.StatePath
        @($s.Operator.Requests[0].Deliveries | Where-Object Status -NE delivered).Count | Should Be 0
        @($s.RoleCalls | Where-Object Role -EQ Fixer).Count | Should Be 1
        @(& git -C $c.Repo status --porcelain).Count | Should Be 0
    }

    It 'rejects an undelivered ordinary Fixer message at final completion' {
        $c=New-OperatorCase
        Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -To Fixer -Message 'WAIT_FOR_NORMAL_FIX' | Out-Null
        $result=Invoke-CodexReviewLoop -RepoPath $c.Repo -ConfigPath $c.Profile -CodexPath $fakeCodex -HeartbeatSeconds 0 -Json
        if ($result.Status -ne 'completed') { throw $result.Reason }
        $result.Status | Should Be completed
        $s=Read-ReviewLoopState $c.Paths.StatePath
        $s.Operator.Requests[0].Deliveries[0].Status | Should Be rejected
        @($s.RoleCalls | Where-Object Role -EQ Fixer).Count | Should Be 0
    }

    It 'publishes the same public command concurrently without overwriting or duplicating it' {
        $c=New-OperatorCase
        $id=[guid]::NewGuid().ToString('D')
        $processes=@()
        try {
            1..2 | ForEach-Object {
                $info=[Diagnostics.ProcessStartInfo]::new()
                $info.FileName=Join-Path $PSHOME 'pwsh.exe'
                $info.UseShellExecute=$false
                $info.CreateNoWindow=$true
                $info.RedirectStandardOutput=$true
                $info.RedirectStandardError=$true
                @('-NoProfile','-File',(Join-Path $root 'operator-message.ps1'),$c.Paths.RunRoot,
                    '-To','Reviewer,Architect','-Message','parallel evidence','-Id',$id) | ForEach-Object { [void]$info.ArgumentList.Add($_) }
                $processes += [Diagnostics.Process]::Start($info)
            }
            foreach($process in $processes) {
                if (-not $process.WaitForExit(30000)) { throw 'Operator publisher did not finish.' }
                $process.StandardOutput.ReadToEnd().Trim() | Should Be $id
                $process.StandardError.ReadToEnd() | Should Be ''
                $process.ExitCode | Should Be 0
            }
            (Invoke-OperatorRole $c).Success | Should Be $true
            @((Read-ReviewLoopState $c.Paths.StatePath).Operator.Requests).Count | Should Be 1
        }
        finally {
            foreach($process in $processes) {
                if (-not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
                $process.Dispose()
            }
        }
    }

    It 'rejects unknown request and durable state versions explicitly' {
        $c=New-OperatorCase
        $id=Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -To Architect -Message 'versioned'
        $s=Read-ReviewLoopState $c.Paths.StatePath
        $mailbox=& (Get-Module CodexReviewLoop) {param($s) Get-ReviewLoopOperatorMailbox $s} $s
        $path=Join-Path $mailbox "$id.json"
        $request=Get-Content $path -Raw | ConvertFrom-Json
        $request.Version=5
        $request | ConvertTo-Json -Depth 10 | Set-Content $path
        (Invoke-OperatorRole $c).Success | Should Be $true
        $s=Read-ReviewLoopState $c.Paths.StatePath
        $s.Operator.Requests[0].Rejection | Should Be 'unknown request version'
        $s.Operator.Version=5
        $s | ConvertTo-Json -Depth 50 | Set-Content $c.Paths.StatePath
        {Read-ReviewLoopState $c.Paths.StatePath} | Should Throw 'Unknown operator state version'
        $s.Operator.Version=1
        $s | ConvertTo-Json -Depth 50 | Set-Content $c.Paths.StatePath
        $upgraded=Read-ReviewLoopState $c.Paths.StatePath
        $upgraded.Operator.Version | Should Be 4
        $upgraded.Operator.Requests[0].Rejection | Should Be 'unknown request version'
        $upgraded.Operator.Version=3
        $upgraded | ConvertTo-Json -Depth 50 | Set-Content $c.Paths.StatePath
        $upgraded=Read-ReviewLoopState $c.Paths.StatePath
        $upgraded.Operator.Version | Should Be 4
        $upgraded.Operator.Requests[0].Rejection | Should Be 'unknown request version'
        $upgraded.Operator.Version=2
        $upgraded | ConvertTo-Json -Depth 50 | Set-Content $c.Paths.StatePath
        $upgraded=Read-ReviewLoopState $c.Paths.StatePath
        $upgraded.Operator.Version | Should Be 4
        $upgraded.Operator.Requests[0].Rejection | Should Be 'unknown request version'
    }

    It 'reruns Architect assessment for evidence arriving during a completed assessment' {
        $c=New-OperatorCase
        Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -To Fixer -Message 'start' -RequireDelivery | Out-Null
        Set-OperatorPlans $c @(
            @{},
            @{result=(Get-OperatorAcceptResult);operatorMessages=@(@{runRoot=$c.Paths.RunRoot;to=@('Architect');message='LATE_ARCHITECT';requireDelivery=$true})},
            @{result=(Get-OperatorAcceptResult)},
            @{result='No findings.'}
        )
        $result=Invoke-CodexReviewLoop -RepoPath $c.Repo -ConfigPath $c.Profile -CodexPath $fakeCodex -HeartbeatSeconds 0 -Json
        if ($result.Status -ne 'completed') { throw $result.Reason }
        $calls=Get-OperatorCalls
        @($calls | Where-Object { $_.schemaPath -match 'fixer-result' }).Count | Should Be 1
        $assessments=@($calls | Where-Object { $_.schemaPath -match 'architecture-assessment' })
        @($assessments | Where-Object { $_.prompt -match 'LATE_ARCHITECT' }).Count | Should Be 1
        @((Read-ReviewLoopState $c.Paths.StatePath).Operator.Requests | Where-Object Message -EQ LATE_ARCHITECT).Count | Should Be 1
    }

    It 'returns to the Fixer when required evidence arrives during assessment' {
        $c=New-OperatorCase
        Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -To Fixer -Message 'start' -RequireDelivery | Out-Null
        Set-OperatorPlans $c @(
            @{},
            @{result=(Get-OperatorAcceptResult);operatorMessages=@(@{runRoot=$c.Paths.RunRoot;to=@('Fixer');message='LATE_FIXER';requireDelivery=$true})},
            @{}, @{result=(Get-OperatorAcceptResult)}, @{result='No findings.'}
        )
        $result=Invoke-CodexReviewLoop -RepoPath $c.Repo -ConfigPath $c.Profile -CodexPath $fakeCodex -HeartbeatSeconds 0 -Json
        if ($result.Status -ne 'completed') { throw $result.Reason }
        $fixers=@(Get-OperatorCalls | Where-Object { $_.schemaPath -match 'fixer-result' })
        $fixers.Count | Should Be 2
        $fixers[1].prompt | Should Match LATE_FIXER
    }

    It 'preserves a dirty candidate for required native review before committing it' {
        $c=New-OperatorCase
        $before=& git -C $c.Repo rev-parse HEAD
        Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -To Fixer -Message 'start' -RequireDelivery | Out-Null
        Set-OperatorPlans $c @(
            @{mutations=@(@{path='README.txt';content='owned change'})},
            @{result=(Get-OperatorAcceptResult);operatorMessages=@(@{runRoot=$c.Paths.RunRoot;to=@('Reviewer');message='REVIEW_CANDIDATE';requireDelivery=$true})},
            @{result='No findings.'}, @{result=(Get-OperatorAcceptResult)}, @{result='No findings.'}
        )
        $result=Invoke-CodexReviewLoop -RepoPath $c.Repo -ConfigPath $c.Profile -CodexPath $fakeCodex -HeartbeatSeconds 0 -Json
        if ($result.Status -ne 'completed') { throw $result.Reason }
        $reviews=@(Get-OperatorCalls | Where-Object callKind -EQ review)
        ($reviews[0].arguments -join ' ') | Should Match REVIEW_CANDIDATE
        & git -C $c.Repo rev-list --count "$before..HEAD" | Should Be 1
        Get-Content (Join-Path $c.Repo 'README.txt') -Raw | Should Be 'owned change'
    }

    It 'keeps required delivery pending when the native review budget is exhausted and resumes it' {
        $c=New-OperatorCase
        (Get-Content $c.Profile -Raw).Replace('MaxReviewCycles=4','MaxReviewCycles=1') | Set-Content $c.Profile
        Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -To Fixer -Message 'start' -RequireDelivery | Out-Null
        Set-OperatorPlans $c @(
            @{}, @{result=(Get-OperatorAcceptResult)},
            @{result='No findings.';operatorMessages=@(@{runRoot=$c.Paths.RunRoot;to=@('Reviewer');message='NEXT_REVIEW';requireDelivery=$true})}
        )
        $result=Invoke-CodexReviewLoop -RepoPath $c.Repo -ConfigPath $c.Profile -CodexPath $fakeCodex -HeartbeatSeconds 0 -Json
        if ($result.Status -ne 'limit_reached') { throw $result.Reason }
        $s=Read-ReviewLoopState $c.Paths.StatePath
        ($s.Operator.Requests | Where-Object Message -EQ NEXT_REVIEW).Deliveries[0].Status | Should Be pending
        Set-OperatorPlans $c @(@{result='No findings.'})
        $result=Invoke-CodexReviewLoop -RepoPath $c.Repo -ConfigPath $c.Profile -CodexPath $fakeCodex -HeartbeatSeconds 0 -Json
        if ($result.Status -ne 'completed') { throw $result.Reason }
        $s=Read-ReviewLoopState $c.Paths.StatePath
        ($s.Operator.Requests | Where-Object Message -EQ NEXT_REVIEW).Deliveries[0].Status | Should Be delivered
    }

    It 'binds overall acceptance to the operator context revision' {
        $c=New-OperatorCase
        & (Get-Module CodexReviewLoop) {
            param($c)
            $s=Read-ReviewLoopState $c.Paths.StatePath
            $s.ArchitectWork.OrientationRequired=$false
            $s.ArchitectWork.Goal=[pscustomobject]@{statement='complete';sources=@();uncertainties=@()}
            Complete-ReviewLoopArchitectureWork -State $s -RepoPath $c.Repo -Result ([pscustomobject]@{
                WorkRevision=0;workOutcomes=@();goalComplete=$true;summary='old';OperatorRevision=0
            })
            (Test-ReviewLoopGoalAccepted $s) | Should Be $true
            Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -To Architect -Message 'NEW_ACCEPTANCE_EVIDENCE' | Out-Null
            Sync-ReviewLoopOperatorMessages $s $c.Paths.StatePath
            (Test-ReviewLoopGoalAccepted $s) | Should Be $false
            # A different Architect phase consuming the message cannot revive the old judgment.
            $s.Operator.Requests[0].Deliveries[0].Status='delivered'
            (Test-ReviewLoopGoalAccepted $s) | Should Be $false
        } $c
    }

    It 'does not reuse a stored successful Fixer result after new addressed evidence on resume' {
        $c=New-OperatorCase
        $call=Invoke-OperatorRole $c -Role Fixer
        $call.Success | Should Be $true
        & (Get-Module CodexReviewLoop) {
            param($c,$call)
            $s=Read-ReviewLoopState $c.Paths.StatePath
            $s.ActiveFindingSource='operator'
            $s.ActiveClusterId='operator-stored'
            $s.ActiveFixAttempt=1
            $s.Stage='fix_attempted'
            $s.LastFixerResult=[pscustomobject]@{
                CallId=$call.CallId;Attempt=1;Success=$true;FailureKind='none';Correction=0
                StructuredResult=$call.StructuredResult;ThreadId=$call.ThreadId
                RepositorySnapshot=(Get-ReviewLoopRepositorySnapshot $c.Repo)
                WorktreeHead=$s.CurrentHead;WorktreeFingerprint=(Get-ReviewLoopWorktreeFingerprint $c.Repo)
            }
            Write-ReviewLoopState $c.Paths.StatePath $s | Out-Null
        } $c $call
        Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -To Fixer -Message 'STORED_FIXER_IS_OLD' | Out-Null
        Set-OperatorPlans $c @(@{},@{result=(Get-OperatorAcceptResult)},@{result='No findings.'})
        $result=Invoke-CodexReviewLoop -RepoPath $c.Repo -ConfigPath $c.Profile -CodexPath $fakeCodex -HeartbeatSeconds 0 -Json
        if ($result.Status -ne 'completed') { throw $result.Reason }
        $fixers=@(Get-OperatorCalls | Where-Object { $_.schemaPath -match 'fixer-result' })
        $fixers.Count | Should Be 2
        $fixers[1].prompt | Should Match STORED_FIXER_IS_OLD
    }

    It 'does not bypass new ordinary Fixer evidence with a retained candidate result' {
        $c=New-OperatorCase
        Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -To Fixer -Message 'start' -RequireDelivery | Out-Null
        Set-OperatorPlans $c @(
            @{mutations=@(@{path='README.txt';content='retained change'})},
            @{result=(Get-OperatorAcceptResult);operatorMessages=@(@{runRoot=$c.Paths.RunRoot;to=@('Reviewer');message='review';requireDelivery=$true})},
            @{result='No findings.';operatorMessages=@(@{runRoot=$c.Paths.RunRoot;to=@('Fixer');message='RETAINED_NEW_FIXER';requireDelivery=$false})},
            @{}, @{result=(Get-OperatorAcceptResult)}, @{result='No findings.'}
        )
        $result=Invoke-CodexReviewLoop -RepoPath $c.Repo -ConfigPath $c.Profile -CodexPath $fakeCodex -HeartbeatSeconds 0 -Json
        if ($result.Status -ne 'completed') { throw $result.Reason }
        $fixers=@(Get-OperatorCalls | Where-Object { $_.schemaPath -match 'fixer-result' })
        $fixers.Count | Should Be 2
        $fixers[1].prompt | Should Match RETAINED_NEW_FIXER
    }

    It 'recovers a sealed pending commit without retroactively accepting later required evidence' {
        $c=New-OperatorCase
        $before=& git -C $c.Repo rev-parse HEAD
        Set-Content (Join-Path $c.Repo 'README.txt') 'sealed candidate'
        & (Get-Module CodexReviewLoop) {
            param($c)
            $s=Read-ReviewLoopState $c.Paths.StatePath
            $s.ActiveFindingSource='operator'
            $s.ActiveClusterId='operator-pending'
            $s.Stage='commit_preparing'
            $s.Status='failed'
            $ledger=New-ReviewLoopLedger $c.Repo
            Write-ReviewLoopLedger $c.Paths.LedgerPath $ledger | Out-Null
            @(Close-ReviewLoopOperatorBoundary $s $c.Paths.StatePath commit).Count | Should Be 0
            $s.PendingCommit=[pscustomobject]@{
                PreHead=$s.CurrentHead;PatchFingerprint=(Get-ReviewLoopWorktreeFingerprint $c.Repo)
                ExpectedTree='';ExpectedCommit='';Message='Test: sealed candidate';NeedsCurrentGates=$false
                OperatorBoundaryId=$s.Operator.Boundary.Id
                Verification=[pscustomobject]@{WorkRevision=0;workOutcomes=@();goalComplete=$false}
            }
            Write-ReviewLoopState $c.Paths.StatePath $s | Out-Null
        } $c
        Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -To Fixer -Message 'AFTER_COMMIT_CUTOFF' -RequireDelivery | Out-Null
        & (Get-Module CodexReviewLoop) {
            param($c)
            $s=Read-ReviewLoopState $c.Paths.StatePath
            $config=Import-ReviewLoopConfig -ConfigPath $c.Profile -RepoPath $c.Repo
            $ledger=Read-ReviewLoopLedger $c.Paths.LedgerPath
            Complete-ReviewLoopPendingCommit -Config $config -State $s -StatePath $c.Paths.StatePath `
                -Ledger $ledger -LedgerPath $c.Paths.LedgerPath -RepoPath $c.Repo -RunRoot $c.Paths.RunRoot | Out-Null
            $s=Read-ReviewLoopState $c.Paths.StatePath
            @($s.Operator.Requests).Count | Should Be 0
            $s.PendingCommit | Should BeNullOrEmpty
            $s.Operator.Boundary | Should BeNullOrEmpty
            Sync-ReviewLoopOperatorMessages $s $c.Paths.StatePath
            $s.Operator.Requests[0].Deliveries[0].Status | Should Be pending
            Complete-ReviewLoopPendingCommit -Config $config -State $s -StatePath $c.Paths.StatePath `
                -Ledger $ledger -LedgerPath $c.Paths.LedgerPath -RepoPath $c.Repo -RunRoot $c.Paths.RunRoot | Should Be $false
        } $c
        & git -C $c.Repo rev-list --count "$before..HEAD" | Should Be 1
    }

    It 'refuses a mailbox located within the reviewed worktree' {
        $c=New-OperatorCase
        $s=Read-ReviewLoopState $c.Paths.StatePath
        $s.RepoPath=[Environment]::GetFolderPath('LocalApplicationData')
        { & (Get-Module CodexReviewLoop) {param($s) Get-ReviewLoopOperatorMailbox $s} $s } |
            Should Throw 'outside the reviewed worktree'
    }

    It 'preserves the pre-gate commit cutoff across resume before PendingCommit exists' {
        $c=New-OperatorCase
        $env:CODEX_REVIEW_LOOP_FAKE_MUTATE_ON_SCHEMA='fixer-result-v3.schema.json'
        $call=Invoke-OperatorRole $c -Role Fixer
        Remove-Item Env:CODEX_REVIEW_LOOP_FAKE_MUTATE_ON_SCHEMA
        $call.Success | Should Be $true
        & (Get-Module CodexReviewLoop) {
            param($c,$call)
            $s=Read-ReviewLoopState $c.Paths.StatePath
            $s.ActiveFindingSource='operator'
            $s.ActiveClusterId='operator-cutoff'
            $s.ActiveFixAttempt=1
            $s.Stage='verified'
            $s.Status='failed'
            $s.LastFixerResult=[pscustomobject]@{
                CallId=$call.CallId;Attempt=1;Success=$true;FailureKind='none';Correction=0
                StructuredResult=$call.StructuredResult;ThreadId=$call.ThreadId
                RepositorySnapshot=(Get-ReviewLoopRepositorySnapshot $c.Repo)
                WorktreeHead=$s.CurrentHead;WorktreeFingerprint=(Get-ReviewLoopWorktreeFingerprint $c.Repo)
            }
            Write-ReviewLoopState $c.Paths.StatePath $s | Out-Null
            @(Close-ReviewLoopOperatorBoundary $s $c.Paths.StatePath commit).Count | Should Be 0
        } $c $call
        Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -To Fixer -Message 'AFTER_PRE_GATE_CUTOFF' -RequireDelivery | Out-Null
        Set-OperatorPlans $c @(
            @{result=(Get-OperatorAcceptResult)}, @{},
            @{result=(Get-OperatorAcceptResult)}, @{result='No findings.'}
        )
        $result=Invoke-CodexReviewLoop -RepoPath $c.Repo -ConfigPath $c.Profile -CodexPath $fakeCodex -HeartbeatSeconds 0 -Json
        if ($result.Status -ne 'completed') { throw $result.Reason }
        $workCalls=@(Get-OperatorCalls | Where-Object { $_.schemaPath -notmatch 'orientation' -and $_.callKind -ne 'review' })
        $workCalls[1].schemaPath | Should Match 'architecture-assessment'
        $workCalls[1].prompt | Should Not Match AFTER_PRE_GATE_CUTOFF
        $workCalls[2].schemaPath | Should Match 'fixer-result'
        $workCalls[2].prompt | Should Match AFTER_PRE_GATE_CUTOFF
        @((Read-ReviewLoopState $c.Paths.StatePath).LoopCommits).Count | Should Be 1
    }
}

Describe 'Targeted Architect reassessment' {
    AfterEach { Clear-OperatorCase }

    It 'publishes an immutable typed request and does not consume it in orientation' {
        $c=New-OperatorCase
        $id=Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -ReassessArchitect -Message 'Reason: assumption X failed. Evidence: check.log.'
        & (Join-Path $root 'operator-message.ps1') $c.Paths.RunRoot -ReassessArchitect -Message 'Reason: assumption X failed. Evidence: check.log.' -Id $id | Should Be $id
        {Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -ReassessArchitect -Message 'different' -Id $id} | Should Throw 'different content'
        foreach($incompatible in @(@('-To','Fixer'),@('-RequireDelivery'),@('-PauseAt','AfterRole'))) {
            & pwsh -NoProfile -File (Join-Path $root 'operator-message.ps1') $c.Paths.RunRoot -ReassessArchitect -Message invalid @incompatible 2>$null
            $LASTEXITCODE | Should Not Be 0
        }
        (Invoke-OperatorRole $c).Success | Should Be $true
        $s=Read-ReviewLoopState $c.Paths.StatePath
        $s.Operator.Version | Should Be 4
        $s.Operator.Requests[0].Deliveries[0].Status | Should Be pending
        (Get-OperatorCalls)[0].prompt | Should Not Match 'assumption X failed'
        & (Get-Module CodexReviewLoop) {
            param($c,$fake)
            $s=Read-ReviewLoopState $c.Paths.StatePath
            $config=Import-ReviewLoopConfig $c.Profile $c.Repo
            Invoke-ReviewLoopArchitect -Config $config -State $s -StatePath $c.Paths.StatePath -RepoPath $c.Repo `
                -Speed standard -RunRoot $c.Paths.RunRoot -Findings @() -CodexPath $fake -Reassessment | Out-Null
        } $c $fakeCodex
        $s=Read-ReviewLoopState $c.Paths.StatePath
        $s.Operator.Requests[0].Deliveries[0].Status | Should Be delivered
        $s.Operator.Requests[0].Deliveries[0].CallId | Should Match 'reassess'
        $s.TaskContext | Should Be ''
        $calls=Get-OperatorCalls
        $calls[-1].resumeThreadId | Should Be $s.RoleCalls[0].ThreadId
    }

    It 'coalesces pending evidence and reassesses again for evidence arriving during advice before one Fixer call' {
        $c=New-OperatorCase
        Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -To Fixer -Message 'start' -RequireDelivery | Out-Null
        Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -ReassessArchitect -Message 'FIRST_COUNTERCHECK' | Out-Null
        Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -ReassessArchitect -Message 'SECOND_COUNTERCHECK' | Out-Null
        Set-OperatorPlans $c @(
            @{operatorMessages=@(@{runRoot=$c.Paths.RunRoot;reassessArchitect=$true;message='LATER_COUNTERCHECK'})},
            @{}, @{}, @{result=(Get-OperatorAcceptResult)}, @{result='No findings.'})
        $r=Invoke-OperatorLoop $c
        if($r.Status -ne 'completed'){throw $r.Reason}
        $calls=Get-OperatorCalls
        $advice=@($calls | Where-Object schemaPath -match 'architecture-advice')
        $advice.Count | Should Be 2
        $advice[0].prompt | Should Match FIRST_COUNTERCHECK
        $advice[0].prompt | Should Match SECOND_COUNTERCHECK
        $advice[0].prompt | Should Not Match LATER_COUNTERCHECK
        $advice[1].prompt | Should Match LATER_COUNTERCHECK
        @($calls | Where-Object schemaPath -match 'fixer-result').Count | Should Be 1
        $calls[3].schemaPath | Should Match 'fixer-result'
        @((Read-ReviewLoopState $c.Paths.StatePath).Operator.Requests | Where-Object {$_.Kind -eq 'architect_reassessment' -and $_.Deliveries[0].Status -eq 'delivered'}).Count | Should Be 3
    }

    It 'reassesses an existing candidate after acceptance without repeating its Fixer or matching targeted test' {
        $c=New-OperatorCase
        $counter=Join-Path $c.Root 'tests.txt'
        $test=Join-Path $c.Root 'targeted.ps1'
        "Add-Content -LiteralPath '$counter' executed" | Set-Content $test
        $fixer=@{schemaVersion='3.0';summary='Fix';targetedTest=@{available=$true;executable='pwsh';arguments=@('-NoProfile','-File',$test)}} | ConvertTo-Json -Depth 6 -Compress
        Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -To Fixer -Message 'start' -RequireDelivery | Out-Null
        Set-OperatorPlans $c @(
            @{result=$fixer;mutations=@(@{path='README.txt';content='candidate'})},
            @{result=(Get-OperatorAcceptResult);operatorMessages=@(@{runRoot=$c.Paths.RunRoot;reassessArchitect=$true;message='AFTER_ACCEPTANCE'})},
            @{result=(Get-OperatorAcceptResult)}, @{result='No findings.'})
        $r=Invoke-OperatorLoop $c
        if($r.Status -ne 'completed'){throw $r.Reason}
        @(Get-Content $counter).Count | Should Be 1
        @((Get-OperatorCalls) | Where-Object schemaPath -match 'fixer-result').Count | Should Be 1
        @((Get-OperatorCalls) | Where-Object {$_.schemaPath -match 'assessment' -and $_.phase -ne 'completion'}).Count | Should Be 2
        @((Get-OperatorCalls) | Where-Object prompt -match AFTER_ACCEPTANCE).Count | Should Be 1
    }

    It 'blocks a pending commit at every recoverable preparation phase and preserves the candidate' {
        foreach($phase in @('prepared','staged','object')) {
            $c=New-OperatorCase
            [IO.File]::WriteAllText((Join-Path $c.Repo 'README.txt'),'candidate')
            & (Get-Module CodexReviewLoop) {
                param($c,$phase)
                $s=Read-ReviewLoopState $c.Paths.StatePath
                $s.ActiveFindingSource='operator';$s.ActiveClusterId='reassessment-pending';$s.Stage='commit_preparing'
                $ledger=New-ReviewLoopLedger $c.Repo
                Write-ReviewLoopLedger $c.Paths.LedgerPath $ledger | Out-Null
                Close-ReviewLoopOperatorBoundary $s $c.Paths.StatePath commit | Out-Null
                $s.PendingCommit=[pscustomobject]@{
                    PreHead=$s.CurrentHead;PatchFingerprint=Get-ReviewLoopWorktreeFingerprint $c.Repo
                    ExpectedTree='';ExpectedCommit='';Message='Test: reassessment';NeedsCurrentGates=$false
                    OperatorBoundaryId=$s.Operator.Boundary.Id
                    Verification=[pscustomobject]@{WorkRevision=0;workOutcomes=@();goalComplete=$false}
                }
                if($phase -ne 'prepared') {
                    & git -C $c.Repo add -A
                    $s.PendingCommit.ExpectedTree=Get-ReviewLoopGitValue $c.Repo @('write-tree')
                }
                if($phase -eq 'object') {
                    $s.PendingCommit.ExpectedCommit=(& git -C $c.Repo commit-tree $s.PendingCommit.ExpectedTree -p $s.CurrentHead -m $s.PendingCommit.Message).Trim()
                }
                Write-ReviewLoopState $c.Paths.StatePath $s | Out-Null
            } $c $phase
            $before=(& git -C $c.Repo rev-parse HEAD).Trim()
            Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -ReassessArchitect -Message 'PRE_HEAD_COUNTERCHECK' | Out-Null
            & (Get-Module CodexReviewLoop) {
                param($c)
                $s=Read-ReviewLoopState $c.Paths.StatePath
                $config=Import-ReviewLoopConfig $c.Profile $c.Repo
                $ledger=Read-ReviewLoopLedger $c.Paths.LedgerPath
                Complete-ReviewLoopPendingCommit -Config $config -State $s -StatePath $c.Paths.StatePath `
                    -Ledger $ledger -LedgerPath $c.Paths.LedgerPath -RepoPath $c.Repo -RunRoot $c.Paths.RunRoot | Should Be $false
                $s.PendingCommit | Should BeNullOrEmpty
                $s.Stage | Should Be fix_attempted
                Test-Path $s.Operator.Requests[0].SupersededCommitPath | Should Be $true
            } $c
            (& git -C $c.Repo rev-parse HEAD).Trim() | Should Be $before
            Get-Content (Join-Path $c.Repo 'README.txt') | Should Be candidate
            @(& git -C $c.Repo diff --cached --name-only).Count | Should Be 0
            Clear-OperatorCase
        }
    }

    It 'reassesses evidence published inside commit gates and reruns gates before committing' {
        $c=New-OperatorCase
        $gate=Join-Path $c.Root 'gate.ps1'
        $counter=Join-Path $c.Root 'gates.txt'
        @"
if (-not (Test-Path '$counter')) {
    & '$root\operator-message.ps1' '$($c.Paths.RunRoot)' -ReassessArchitect -Message 'IN_COMMIT_GATE' | Out-Null
}
Add-Content '$counter' executed
"@ | Set-Content $gate
        (Get-Content -Raw $c.Profile).Replace('HostGates=@()',"HostGates=@(@{Name='evidence';FilePath='pwsh';Arguments=@('-NoProfile','-File','$gate')})") | Set-Content $c.Profile
        Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -To Fixer -Message 'start' -RequireDelivery | Out-Null
        Set-OperatorPlans $c @(@{mutations=@(@{path='README.txt';content='candidate'})},
            @{result=(Get-OperatorAcceptResult)}, @{result=(Get-OperatorAcceptResult)}, @{result='No findings.'})
        $r=Invoke-OperatorLoop $c
        if($r.Status -ne 'completed'){throw $r.Reason}
        @(Get-Content $counter).Count | Should Be 2
        @((Get-OperatorCalls) | Where-Object schemaPath -match 'fixer-result').Count | Should Be 1
        @((Get-OperatorCalls) | Where-Object prompt -match IN_COMMIT_GATE).Count | Should Be 1
        (Read-ReviewLoopState $c.Paths.StatePath).Operator.Requests[-1].SupersededCommitPath | Should Not BeNullOrEmpty
    }

    It 'accepts requests during sealed completion and evaluates them without another native review' {
        $c=New-OperatorCase
        Set-OperatorPlans $c @(@{result='No findings.'},
            @{phase='completion';result=(Get-OperatorAcceptResult);operatorMessages=@(@{runRoot=$c.Paths.RunRoot;reassessArchitect=$true;message='DURING_COMPLETION'})})
        $r=Invoke-OperatorLoop $c
        if($r.Status -ne 'completed'){throw $r.Reason}
        $calls=Get-OperatorCalls
        @($calls | Where-Object callKind -eq review).Count | Should Be 1
        @($calls | Where-Object phase -eq completion).Count | Should Be 2
        @($calls | Where-Object prompt -match DURING_COMPLETION).Count | Should Be 1
        {Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -ReassessArchitect -Message 'too late'} | Should Throw 'completion is sealed'
    }

    It 'serializes late evidence before HEAD advancement and preserves requests arriving just after it' {
        foreach($injection in @(2,3,4,5)) {
            $c=New-OperatorCase
            $before=(& git -C $c.Repo rev-parse HEAD).Trim()
            Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -To Fixer -Message 'start' -RequireDelivery | Out-Null
            $plans=@(@{mutations=@(@{path='README.txt';content='candidate'})},@{result=(Get-OperatorAcceptResult)})
            if($injection -lt 5){$plans+=@{result=(Get-OperatorAcceptResult)}}
            $plans+=@{result='No findings.'}
            Set-OperatorPlans $c $plans
            & (Get-Module CodexReviewLoop) {
                param($c,$at,$fake)
                $script:reassessmentPauseOriginal=${function:Invoke-ReviewLoopPauseBoundary}
                $script:reassessmentInjection=[pscustomobject]@{Case=$c;At=$at;Count=0;HeadBefore='';HeadAfter=''}
                function script:Invoke-ReviewLoopPauseBoundary {
                    param($State,$StatePath,$At='Step',[switch]$Locked)
                    if($At -eq 'CommitRecovery' -and -not $Locked) {
                        $script:reassessmentInjection.Count++
                        if($script:reassessmentInjection.Count -eq $script:reassessmentInjection.At) {
                            $case=$script:reassessmentInjection.Case
                            $script:reassessmentInjection.HeadBefore=Get-ReviewLoopGitValue $case.Repo @('rev-parse','HEAD')
                            Send-ReviewLoopOperatorMessage $case.Paths.RunRoot -ReassessArchitect -Message 'AT_PUBLICATION_BOUNDARY' | Out-Null
                        }
                    }
                    & $script:reassessmentPauseOriginal @PSBoundParameters
                }
                try {
                    $r=Invoke-CodexReviewLoop -RepoPath $c.Repo -ConfigPath $c.Profile -CodexPath $fake -HeartbeatSeconds 0 -Json
                    if($r.Status -ne 'completed'){throw $r.Reason}
                    $script:reassessmentInjection.HeadBefore
                }
                finally {
                    Set-Item Function:script:Invoke-ReviewLoopPauseBoundary $script:reassessmentPauseOriginal
                    Remove-Variable reassessmentPauseOriginal,reassessmentInjection -Scope Script
                }
            } $c $injection $fakeCodex | ForEach-Object {
                if($injection -lt 5){$_ | Should Be $before}else{$_ | Should Not Be $before}
            }
            (& git -C $c.Repo rev-list --count "$before..HEAD") | Should Be 1
            $calls=Get-OperatorCalls
            @($calls | Where-Object schemaPath -match 'fixer-result').Count | Should Be 1
            @($calls | Where-Object prompt -match AT_PUBLICATION_BOUNDARY).Count | Should Be 1
            $s=Read-ReviewLoopState $c.Paths.StatePath
            $s.Operator.Requests[-1].Deliveries[0].Status | Should Be delivered
            if($injection -lt 5){Test-Path $s.Operator.Requests[-1].SupersededCommitPath | Should Be $true}
            Clear-OperatorCase
        }
    }

    It 'reassesses before retrying a Fixer after a failed targeted test and keeps the new advice' {
        $c=New-OperatorCase
        $test=Join-Path $c.Root 'failing.ps1'
        "& '$root\operator-message.ps1' '$($c.Paths.RunRoot)' -ReassessArchitect -Message 'FAILED_TEST_COUNTERCHECK' | Out-Null; exit 1" | Set-Content $test
        $fixer=@{schemaVersion='3.0';summary='First candidate';targetedTest=@{available=$true;executable='pwsh';arguments=@('-NoProfile','-File',$test)}} | ConvertTo-Json -Depth 6 -Compress
        $advice='{"schemaVersion":"3.0","summary":"Revised plan","approach":"REVISED_APPROACH","steps":[],"considerations":[],"orders":[],"selectedWorkIds":[]}'
        Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -To Fixer -Message 'start' -RequireDelivery | Out-Null
        Set-OperatorPlans $c @(@{result=$fixer},@{result=$advice},@{},@{result=(Get-OperatorAcceptResult)},@{result='No findings.'})
        $r=Invoke-OperatorLoop $c
        if($r.Status -ne 'completed'){throw $r.Reason}
        $calls=Get-OperatorCalls
        $calls[2].schemaPath | Should Match 'architecture-advice'
        $calls[2].prompt | Should Match FAILED_TEST_COUNTERCHECK
        $calls[3].schemaPath | Should Match 'fixer-result'
        $calls[3].prompt | Should Match REVISED_APPROACH
        @($calls | Where-Object schemaPath -match 'fixer-result').Count | Should Be 2
    }

    It 'keeps evidence pending across a failed Architect and resumes its existing session before fixing' {
        $c=New-OperatorCase
        Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -To Fixer -Message 'start' -RequireDelivery | Out-Null
        Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -ReassessArchitect -Message 'RESUMABLE_COUNTERCHECK' | Out-Null
        Set-OperatorPlans $c @(@{exitCode=7},@{exitCode=7},@{exitCode=7})
        $first=Invoke-OperatorLoop $c
        $first.Status | Should Not Be completed
        $s=Read-ReviewLoopState $c.Paths.StatePath
        @($s.Operator.Requests | Where-Object Kind -eq architect_reassessment)[0].Deliveries[0].Status | Should Be pending
        @((Get-OperatorCalls) | Where-Object schemaPath -match 'fixer-result').Count | Should Be 0
        Set-OperatorPlans $c @(@{},@{},@{result=(Get-OperatorAcceptResult)},@{result='No findings.'})
        $second=Invoke-OperatorLoop $c
        if($second.Status -ne 'completed'){throw $second.Reason}
        @((Read-ReviewLoopState $c.Paths.StatePath).Operator.Requests | Where-Object Kind -eq architect_reassessment)[0].Deliveries[0].Status | Should Be delivered
    }

    It 'uses normal assessment for a retained candidate with fresh evidence from native review' {
        $c=New-OperatorCase
        Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -To Fixer -Message 'start' -RequireDelivery | Out-Null
        Set-OperatorPlans $c @(
            @{mutations=@(@{path='README.txt';content='retained'})},
            @{result=(Get-OperatorAcceptResult);operatorMessages=@(@{runRoot=$c.Paths.RunRoot;to=@('Reviewer');message='review candidate';requireDelivery=$true})},
            @{result='No findings.';operatorMessages=@(@{runRoot=$c.Paths.RunRoot;reassessArchitect=$true;message='RETAINED_COUNTERCHECK'})},
            @{result=(Get-OperatorAcceptResult)},@{result='No findings.'})
        $r=Invoke-OperatorLoop $c
        if($r.Status -ne 'completed'){throw $r.Reason}
        $calls=Get-OperatorCalls
        @($calls | Where-Object schemaPath -match 'fixer-result').Count | Should Be 1
        @($calls | Where-Object schemaPath -match 'architecture-advice').Count | Should Be 0
        @($calls | Where-Object prompt -match RETAINED_COUNTERCHECK).Count | Should Be 1
        (Read-ReviewLoopState $c.Paths.StatePath).RetainedCandidate | Should BeNullOrEmpty
    }

    It 'prevents no-op resolution and final completion from using an old acceptance' {
        foreach($mode in @('noop','completion')) {
            $c=New-OperatorCase
            $gate=Join-Path $c.Root 'gate.ps1'
            $counter=Join-Path $c.Root 'count.txt'
            @"
if (-not (Test-Path '$counter')) {
    & '$root\operator-message.ps1' '$($c.Paths.RunRoot)' -ReassessArchitect -Message 'LATE_GATE_COUNTERCHECK' | Out-Null
}
Add-Content '$counter' executed
"@ | Set-Content $gate
            (Get-Content -Raw $c.Profile).Replace('HostGates=@()',"HostGates=@(@{Name='evidence';FilePath='pwsh';Arguments=@('-NoProfile','-File','$gate')})") | Set-Content $c.Profile
            if($mode -eq 'noop') {
                Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -To Fixer -Message 'start' -RequireDelivery | Out-Null
                Set-OperatorPlans $c @(@{},@{result=(Get-OperatorAcceptResult)},@{result=(Get-OperatorAcceptResult)},@{result='No findings.'})
            }
            else {Set-OperatorPlans $c @(@{result='No findings.'})}
            $head=(& git -C $c.Repo rev-parse HEAD).Trim()
            $r=Invoke-OperatorLoop $c
            if($r.Status -ne 'completed'){throw $r.Reason}
            (& git -C $c.Repo rev-parse HEAD).Trim() | Should Be $head
            @(Get-Content $counter).Count | Should Be 2
            @((Get-OperatorCalls) | Where-Object prompt -match LATE_GATE_COUNTERCHECK).Count | Should Be 1
            @((Get-OperatorCalls) | Where-Object callKind -eq review).Count | Should Be 1
            Clear-OperatorCase
        }
    }

    It 'returns from the final completion write to assessment for a just-published request' {
        $c=New-OperatorCase
        Set-OperatorPlans $c @(@{result='No findings.'})
        & (Get-Module CodexReviewLoop) {
            param($c,$fake)
            $script:reassessmentCompletionOriginal=${function:Complete-ReviewLoopRun}
            $script:reassessmentCompletionInjected=$false
            function script:Complete-ReviewLoopRun {
                param($State,$StatePath,$RunRoot,$LedgerPath,$TranscriptPath,$CleanPassesRequired,$CompletionEvidence='')
                if(-not $script:reassessmentCompletionInjected) {
                    Send-ReviewLoopOperatorMessage $RunRoot -ReassessArchitect -Message 'AT_FINAL_WRITE' | Out-Null
                    $script:reassessmentCompletionInjected=$true
                }
                & $script:reassessmentCompletionOriginal @PSBoundParameters
            }
            try {
                $r=Invoke-CodexReviewLoop -RepoPath $c.Repo -ConfigPath $c.Profile -CodexPath $fake -HeartbeatSeconds 0 -Json
                if($r.Status -ne 'completed'){throw $r.Reason}
            }
            finally {
                Set-Item Function:script:Complete-ReviewLoopRun $script:reassessmentCompletionOriginal
                Remove-Variable reassessmentCompletionOriginal,reassessmentCompletionInjected -Scope Script
            }
        } $c $fakeCodex
        $calls=Get-OperatorCalls
        @($calls | Where-Object callKind -eq review).Count | Should Be 1
        @($calls | Where-Object phase -eq completion).Count | Should Be 2
        @($calls | Where-Object prompt -match AT_FINAL_WRITE).Count | Should Be 1
    }
}

Describe 'Architect reassessment recovery boundaries' {
    AfterEach { Clear-OperatorCase }

    It 'keeps a pause pending while a dirty interrupted Fixer is suspended for reassessment' {
        $c=New-OperatorCase
        [IO.File]::WriteAllText((Join-Path $c.Repo 'README.txt'),'interrupted candidate')
        & (Get-Module CodexReviewLoop) {
            param($c)
            $s=Read-ReviewLoopState $c.Paths.StatePath
            $s.Stage='fixing'
            $s.Operator.InterruptedFixerCall=[pscustomobject]@{
                CallId='suspended-fixer';ReassessmentSnapshot=Get-ReviewLoopRepositorySnapshot $c.Repo
            }
            Write-ReviewLoopState $c.Paths.StatePath $s | Out-Null
        } $c
        Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -PauseAt AfterRole -Message 'inspect after recovery' | Out-Null
        & (Get-Module CodexReviewLoop) {
            param($c)
            $s=Read-ReviewLoopState $c.Paths.StatePath
            Invoke-ReviewLoopPauseBoundary $s $c.Paths.StatePath Step
            $s.Operator.Requests[0].Status | Should Be pending
            $s.Status | Should Not Be paused
            Get-Content (Join-Path $c.Repo 'README.txt') | Should Be 'interrupted candidate'
        } $c
    }

    It 'rejects malformed reassessment envelopes without advancing Architect context' {
        $c=New-OperatorCase
        foreach($variant in @('recipient','required','kind','empty','run')) {
            $id=Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -ReassessArchitect -Message 'counter-check'
            & (Get-Module CodexReviewLoop) {
                param($c,$id,$variant)
                $s=Read-ReviewLoopState $c.Paths.StatePath
                $mailbox=Get-ReviewLoopOperatorMailbox $s
                $path=Join-Path $mailbox "$id.json"
                $request=Read-ReviewLoopJson $path
                switch($variant) {
                    recipient {$request.To=@('Fixer')}
                    required {$request.RequireDelivery=$false}
                    kind {$request.Kind='message'}
                    empty {$request.Message=' '}
                    run {$request.Run.RunId='another-run'}
                }
                Write-ReviewLoopAtomicJson $path $request
                Sync-ReviewLoopOperatorMessages $s $c.Paths.StatePath
                $s.Operator.Requests[-1].Rejection | Should Not BeNullOrEmpty
                @($s.Operator.Requests[-1].Deliveries).Count | Should Be 0
                $s.Operator.Revisions.Architect | Should Be 0
            } $c $id $variant
        }
    }

    It 'preserves an interrupted dirty Fixer while reassessment fails and resumes that Fixer only after the decision' {
        $c=New-OperatorCase
        & (Get-Module CodexReviewLoop) {
            param($c,$fake)
            $s=Read-ReviewLoopState $c.Paths.StatePath
            $config=Import-ReviewLoopConfig $c.Profile $c.Repo
            Invoke-ReviewLoopOrientation -Config $config -State $s -StatePath $c.Paths.StatePath `
                -RepoPath $c.Repo -Speed standard -RunRoot $c.Paths.RunRoot -CodexPath $fake
            $snapshot=Get-ReviewLoopRepositorySnapshot $c.Repo
            $s.ActiveClusterId='interrupted-fixer';$s.ActiveFindingSource='operator';$s.ActiveFixAttempt=1;$s.Stage='fixing'
            $s.ActiveRoleCall=[pscustomobject]@{
                CallId='interrupted-fixer-c0-fix-a1-c0';Role='Fixer';ThreadId='original-fixer-thread'
                Model='fake';Thinking='high';Speed='standard';Mode='Exec';SchemaName='fixer-result-v3.schema.json'
                ExecutionFingerprint=$s.ExecutionFingerprint;CriticId='';WorkRevision=$s.ArchitectWork.Revision
                RepositoryHead=$snapshot.Head;RepositoryHeadRef=$snapshot.HeadRef;RepositoryBranch=$snapshot.Branch
                RefsFingerprint=$snapshot.RefsFingerprint;RepositoryRefs=$snapshot.Refs
                WorktreeFingerprint=$snapshot.Fingerprint;IndexFingerprint=$snapshot.IndexFingerprint
                OperatorRevision=0;OperatorMessageIds=@();CheckpointStage='fixing';StartedAt=[DateTimeOffset]::UtcNow.ToString('O')
            }
            Write-ReviewLoopState $c.Paths.StatePath $s | Out-Null
        } $c $fakeCodex
        [IO.File]::WriteAllText((Join-Path $c.Repo 'README.txt'),'interrupted candidate')
        Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -ReassessArchitect -Message 'INTERRUPTED_FIXER_COUNTERCHECK' | Out-Null
        Set-OperatorPlans $c @(@{exitCode=7},@{exitCode=7},@{exitCode=7})
        (Invoke-OperatorLoop $c).Status | Should Not Be completed
        $saved=Read-ReviewLoopState $c.Paths.StatePath
        $saved.Operator.InterruptedFixerCall.ThreadId | Should Be original-fixer-thread
        $saved.Operator.Requests[0].Deliveries[0].Status | Should Be pending
        Get-Content (Join-Path $c.Repo 'README.txt') | Should Be 'interrupted candidate'
        @((Get-OperatorCalls) | Where-Object schemaPath -match 'fixer-result').Count | Should Be 0
        Set-OperatorPlans $c @(@{},@{},@{result=(Get-OperatorAcceptResult)},@{result='No findings.'})
        $external=Join-Path $c.Repo 'external.txt'
        Set-Content -LiteralPath $external 'unrelated external work'
        $changed=Invoke-OperatorLoop $c
        $changed.Status | Should Not Be completed
        $changed.Reason | Should Match 'Suspended Fixer reassessment'
        @((Get-OperatorCalls) | Where-Object schemaPath -match 'fixer-result').Count | Should Be 0
        [IO.File]::Delete($external)
        $resumed=Invoke-OperatorLoop $c
        if($resumed.Status -ne 'completed'){throw $resumed.Reason}
        $fixers=@((Get-OperatorCalls) | Where-Object schemaPath -match 'fixer-result')
        $fixers.Count | Should Be 1
        $fixers[0].resumeThreadId | Should Be original-fixer-thread
        $saved=Read-ReviewLoopState $c.Paths.StatePath
        $saved.Operator.InterruptedFixerCall | Should BeNullOrEmpty
        $saved.Operator.Requests[0].Deliveries[0].Status | Should Be delivered
    }

    It 'recovers a saved role result before or after registration without repeating the Architect call' {
        foreach($crash in @('before','after')) {
            $c=New-OperatorCase
            Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -ReassessArchitect -Message 'REGISTER_COUNTERCHECK' | Out-Null
            & (Get-Module CodexReviewLoop) {
                param($c,$fake,$crash)
                $script:reassessmentRegisterOriginal=${function:Register-ReviewLoopWorkPlan}
                $script:reassessmentRegisterCrash=$crash
                function script:Register-ReviewLoopWorkPlan {
                    param($State,$Result,[switch]$RequireSelection)
                    $authoritative=$State.PSObject.Properties.Name -contains 'Operator'
                    if($authoritative -and $script:reassessmentRegisterCrash -eq 'before'){throw 'simulated registration crash'}
                    & $script:reassessmentRegisterOriginal @PSBoundParameters
                    if($authoritative){throw 'simulated registration crash'}
                }
                try {
                    $s=Read-ReviewLoopState $c.Paths.StatePath
                    $config=Import-ReviewLoopConfig $c.Profile $c.Repo
                    {Invoke-ReviewLoopArchitect -Config $config -State $s -StatePath $c.Paths.StatePath -RepoPath $c.Repo `
                        -Speed standard -RunRoot $c.Paths.RunRoot -Findings @() -CodexPath $fake -Reassessment} | Should Throw 'registration crash'
                }
                finally {
                    Set-Item Function:script:Register-ReviewLoopWorkPlan $script:reassessmentRegisterOriginal
                    Remove-Variable reassessmentRegisterOriginal,reassessmentRegisterCrash -Scope Script
                }
                $s=Read-ReviewLoopState $c.Paths.StatePath
                $s.Operator.Requests[0].Deliveries[0].Status | Should Be pending
                Invoke-ReviewLoopArchitect -Config $config -State $s -StatePath $c.Paths.StatePath -RepoPath $c.Repo `
                    -Speed standard -RunRoot $c.Paths.RunRoot -Findings @() -CodexPath $fake -Reassessment | Out-Null
                $s.Operator.Requests[0].Deliveries[0].Status | Should Be delivered
            } $c $fakeCodex $crash
            @(Get-OperatorCalls).Count | Should Be 1
            Clear-OperatorCase
        }
    }

    It 'retains the pending-commit invalidation intent across an interrupted index cleanup' {
        $c=New-OperatorCase
        [IO.File]::WriteAllText((Join-Path $c.Repo 'README.txt'),'candidate')
        & (Get-Module CodexReviewLoop) {
            param($c)
            $s=Read-ReviewLoopState $c.Paths.StatePath
            $s.ActiveFindingSource='operator';$s.ActiveClusterId='interrupted-cleanup';$s.Stage='commit_pending'
            $ledger=New-ReviewLoopLedger $c.Repo
            Write-ReviewLoopLedger $c.Paths.LedgerPath $ledger | Out-Null
            Close-ReviewLoopOperatorBoundary $s $c.Paths.StatePath commit | Out-Null
            & git -C $c.Repo add -A
            $s.PendingCommit=[pscustomobject]@{
                PreHead=$s.CurrentHead;PatchFingerprint=Get-ReviewLoopWorktreeFingerprint $c.Repo
                ExpectedTree=Get-ReviewLoopGitValue $c.Repo @('write-tree');ExpectedCommit='';Message='Test: cleanup recovery';NeedsCurrentGates=$false
                OperatorBoundaryId=$s.Operator.Boundary.Id
                Verification=[pscustomobject]@{WorkRevision=0;workOutcomes=@();goalComplete=$false}
            }
            Write-ReviewLoopState $c.Paths.StatePath $s | Out-Null
        } $c
        Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -ReassessArchitect -Message 'CLEANUP_COUNTERCHECK' | Out-Null
        & (Get-Module CodexReviewLoop) {
            param($c)
            $script:reassessmentRestoreOriginal=${function:Restore-ReviewLoopVerifiedPatchToCleanIndex}
            function script:Restore-ReviewLoopVerifiedPatchToCleanIndex {throw 'simulated cleanup crash'}
            try {
                $s=Read-ReviewLoopState $c.Paths.StatePath
                $config=Import-ReviewLoopConfig $c.Profile $c.Repo
                $ledger=Read-ReviewLoopLedger $c.Paths.LedgerPath
                {Complete-ReviewLoopPendingCommit -Config $config -State $s -StatePath $c.Paths.StatePath `
                    -Ledger $ledger -LedgerPath $c.Paths.LedgerPath -RepoPath $c.Repo -RunRoot $c.Paths.RunRoot} | Should Throw 'cleanup crash'
            }
            finally {
                Set-Item Function:script:Restore-ReviewLoopVerifiedPatchToCleanIndex $script:reassessmentRestoreOriginal
                Remove-Variable reassessmentRestoreOriginal -Scope Script
            }
            $s=Read-ReviewLoopState $c.Paths.StatePath
            $s.PendingCommit.ReassessmentRequired | Should Be $true
            Complete-ReviewLoopPendingCommit -Config $config -State $s -StatePath $c.Paths.StatePath `
                -Ledger $ledger -LedgerPath $c.Paths.LedgerPath -RepoPath $c.Repo -RunRoot $c.Paths.RunRoot | Should Be $false
            $s.PendingCommit | Should BeNullOrEmpty
            $s.Operator.Requests[0].Deliveries[0].Status | Should Be pending
            @(& git -C $c.Repo diff --cached --name-only).Count | Should Be 0
            Get-Content (Join-Path $c.Repo 'README.txt') | Should Be candidate
        } $c
    }
}

Describe 'Operator assessment dependency binding' {
    AfterEach { Clear-OperatorCase }

    It 'reassesses a same-ID same-tree Fixer result when its operator context changes' {
        $c=New-OperatorCase
        $env:CODEX_REVIEW_LOOP_FAKE_RESULT=Get-OperatorAcceptResult
        & (Get-Module CodexReviewLoop) {
            param($c,$fake)
            $state=Read-ReviewLoopState $c.Paths.StatePath
            $config=Import-ReviewLoopConfig -ConfigPath $c.Profile -RepoPath $c.Repo
            $state.ActiveClusterId='same-fixer-context'
            $fixer=[pscustomobject]@{
                CallId='same-fixer-call';OperatorRevision=0
                StructuredResult=[pscustomobject]@{summary='No change.';targetedTest=[pscustomobject]@{available=$false;executable='';arguments=@()}}
            }
            $arguments=@{Config=$config;State=$state;StatePath=$c.Paths.StatePath;RepoPath=$c.Repo
                Speed='standard';RunRoot=$c.Paths.RunRoot;Findings=@();FixerCall=$fixer;Attempt=1;CodexPath=$fake}
            (Invoke-ReviewLoopArchitectAssessment @arguments).Accepted | Should Be $true
            $fixer.OperatorRevision=1
            (Invoke-ReviewLoopArchitectAssessment @arguments).Accepted | Should Be $true
            (Invoke-ReviewLoopArchitectAssessment @arguments).Accepted | Should Be $true
        } $c $fakeCodex
        @(Get-OperatorCalls).Count | Should Be 2
    }
}

Describe 'Controlled operator pauses' {
    AfterEach { Clear-OperatorCase }

    It 'publishes an immutable pause, coalesces due requests, and consumes them across resume' {
        $c = New-OperatorCase
        $id = Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -PauseAt afterrole -Message 'inspect'
        Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -PauseAt AfterRole -Message 'inspect' -Id $id | Should Be $id
        { Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -PauseAt BeforeCommit -Message 'inspect' -Id $id } | Should Throw 'different content'
        Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -PauseAt AfterRound -Message 'also inspect' | Out-Null
        $r = Invoke-OperatorLoop $c
        $r.Status | Should Be paused
        $r.ExitCode | Should Be 5
        $r.Requests.Count | Should Be 2
        @((Read-ReviewLoopState $c.Paths.StatePath).RoleCalls).Count | Should Be 0
        Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -PauseAt AfterRole -Message 'inspect' -Id $id | Should Be $id
        (Invoke-OperatorLoop $c).Status | Should Be completed
        (Read-ReviewLoopState $c.Paths.StatePath).Operator.Requests[0].Status | Should Be reached
    }

    It 'stops after native Reviewer before classifier and reuses the completed native result' {
        $c = New-OperatorCase
        Set-OperatorPlans $c @(@{ result = 'The result requires interpretation.'; operatorMessages = @((New-OperatorPausePlan $c AfterRole)) })
        $r = Invoke-OperatorLoop $c
        if ($r.Status -ne 'paused') { throw "Expected pause, got $($r.Status): $($r.Reason)" }
        @((Get-OperatorCalls) | Where-Object callKind -eq review).Count | Should Be 1
        @((Get-OperatorCalls) | Where-Object schemaPath -match 'classification').Count | Should Be 0
        Set-OperatorPlans $c @(@{}, @{ result = (Get-OperatorAcceptResult) })
        (Invoke-OperatorLoop $c).Status | Should Be completed
        @((Get-OperatorCalls) | Where-Object callKind -eq review).Count | Should Be 1
        @((Get-OperatorCalls) | Where-Object schemaPath -match 'classification').Count | Should Be 1
    }

    It 'stops after classifier before another role and does not repeat either completed review call' {
        $c = New-OperatorCase
        Set-OperatorPlans $c @(@{ result = 'The result requires interpretation.' },
            @{ result = '{"schemaVersion":"1.0","hasFindings":false}'; operatorMessages = @((New-OperatorPausePlan $c AfterRole)) })
        (Invoke-OperatorLoop $c).Status | Should Be paused
        Set-OperatorPlans $c @(@{ result = (Get-OperatorAcceptResult) })
        (Invoke-OperatorLoop $c).Status | Should Be completed
        @((Get-OperatorCalls) | Where-Object callKind -eq review).Count | Should Be 1
        @((Get-OperatorCalls) | Where-Object schemaPath -match 'classification').Count | Should Be 1
    }

    It 'preserves all dirty Fixer files and resumes at the targeted test without another Fixer call' {
        $c = New-OperatorCase
        # Commit only fixture baseline files, never the tool checkout.
        Set-Content (Join-Path $c.Repo 'delete.txt') 'delete me'
        [IO.File]::WriteAllBytes((Join-Path $c.Repo 'binary.dat'), [byte[]]@(0,1,2,255))
        & git -C $c.Repo add .
        & git -C $c.Repo commit -q -m 'fixture files'
        & (Get-Module CodexReviewLoop) {
            param($c)
            $s = Read-ReviewLoopState $c.Paths.StatePath
            $s.StartHead = $s.CurrentHead = Get-ReviewLoopGitValue $c.Repo @('rev-parse','HEAD')
            Write-ReviewLoopState $c.Paths.StatePath $s | Out-Null
        } $c
        Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -To Fixer -Message 'fix' -RequireDelivery | Out-Null
        Set-OperatorPlans $c @(@{ mutations = @(
            @{ path = 'README.txt'; content = 'fixed' }, @{ path = 'delete.txt'; delete = $true },
            @{ path = 'binary.dat'; content = "`0new`0" }, @{ path = 'new.txt'; content = 'untracked' }
        ); operatorMessages = @((New-OperatorPausePlan $c AfterRole)) })
        $r = Invoke-OperatorLoop $c
        if ($r.Status -ne 'paused') { throw $r.Reason }
        $s = Read-ReviewLoopState $c.Paths.StatePath
        $s.Stage | Should Be fix_attempted
        $s.Operator.Pause.Backup.Entries.Count | Should Be 4
        Test-Path $s.Operator.Pause.Backup.ManifestPath | Should Be $true
        $s.RetainedCandidate | Should BeNullOrEmpty
        Set-OperatorPlans $c @(@{ result = (Get-OperatorAcceptResult) }, @{ result = 'No findings.' })
        (Invoke-OperatorLoop $c).Status | Should Be completed
        @((Get-OperatorCalls) | Where-Object schemaPath -match 'fixer-result').Count | Should Be 1
        Test-Path (Join-Path $c.Repo 'delete.txt') | Should Be $false
        Get-Content (Join-Path $c.Repo 'new.txt') | Should Be untracked
    }

    It 'stops before commit gates and does not repeat a completed test or Architect assessment' {
        $c = New-OperatorCase
        $counter = Join-Path $c.Root 'test-count.txt'
        $test = Join-Path $c.Root 'targeted.ps1'
        "Add-Content -LiteralPath '$($counter.Replace("'","''"))' -Value executed" | Set-Content $test
        $fixer = @{ schemaVersion = '3.0'; summary = 'Fix'; targetedTest = @{ available = $true; executable = 'pwsh'; arguments = @('-NoProfile','-File',$test) } } | ConvertTo-Json -Depth 5 -Compress
        Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -To Fixer -Message 'fix' -RequireDelivery | Out-Null
        Set-OperatorPlans $c @(@{ result = $fixer; mutations = @(@{ path = 'README.txt'; content = 'fixed' }); operatorMessages = @((New-OperatorPausePlan $c BeforeCommit)) },
            @{ result = (Get-OperatorAcceptResult) })
        $r = Invoke-OperatorLoop $c
        if ($r.Status -ne 'paused') { throw $r.Reason }
        $s = Read-ReviewLoopState $c.Paths.StatePath
        $s.Stage | Should Be verified
        $s.PendingCommit | Should BeNullOrEmpty
        $s.Operator.Boundary | Should BeNullOrEmpty
        Set-OperatorPlans $c @(@{ result = 'No findings.' })
        (Invoke-OperatorLoop $c).Status | Should Be completed
        @(Get-Content $counter).Count | Should Be 1
        @((Get-OperatorCalls) | Where-Object schemaPath -match 'assessment').Count | Should Be 1
    }

    It 'stops after a targeted test and preserves its outcome for resume' {
        $c = New-OperatorCase
        (Get-Content -Raw $c.Profile).Replace('AutoCommit=', "TargetedTestRepositoryChanges=@{Mode='RestoreAll'}; AutoCommit=") | Set-Content $c.Profile
        $test = Join-Path $c.Root 'targeted.ps1'
        $counter = Join-Path $c.Root 'count.txt'
        @"
& '$root\operator-message.ps1' '$($c.Paths.RunRoot)' -PauseAt AfterRole -Message 'test complete' | Out-Null
Set-Content '$($c.Repo)\README.txt' 'temporary test side effect'
Add-Content '$counter' executed
"@ | Set-Content $test
        $fixer = @{ schemaVersion = '3.0'; summary = 'Fix'; targetedTest = @{ available = $true; executable = 'pwsh'; arguments = @('-NoProfile','-File',$test) } } | ConvertTo-Json -Depth 5 -Compress
        Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -To Fixer -Message 'fix' -RequireDelivery | Out-Null
        Set-OperatorPlans $c @(@{ result = $fixer })
        (Invoke-OperatorLoop $c).Status | Should Be paused
        (Read-ReviewLoopState $c.Paths.StatePath).Stage | Should Be tested
        @(& git -C $c.Repo status --porcelain).Count | Should Be 0
        Set-OperatorPlans $c @(@{ result = (Get-OperatorAcceptResult) }, @{ result = 'No findings.' })
        (Invoke-OperatorLoop $c).Status | Should Be completed
        @(Get-Content $counter).Count | Should Be 1
    }

    It 'finishes an accepted dirty round before stopping and retains later halt requests' {
        $c = New-OperatorCase
        Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -To Fixer -Message 'fix' -RequireDelivery | Out-Null
        Set-OperatorPlans $c @(@{ mutations = @(@{ path = 'README.txt'; content = 'fixed' }); operatorMessages = @(
            (New-OperatorPausePlan $c AfterRound), (New-OperatorPausePlan $c BeforeCompletion)) }, @{ result = (Get-OperatorAcceptResult) })
        $r = Invoke-OperatorLoop $c
        if ($r.Status -ne 'paused') { throw $r.Reason }
        (Read-ReviewLoopState $c.Paths.StatePath).Stage | Should Be fix_committed
        $r.PendingPauseIds.Count | Should Be 1
        @(& git -C $c.Repo status --porcelain).Count | Should Be 0
        Set-OperatorPlans $c @(@{ result = 'No findings.' })
        (Invoke-OperatorLoop $c).Status | Should Be paused
        (Invoke-OperatorLoop $c).Status | Should Be completed
    }

    It 'stops at an exhausted dirty round with intact RetainedCandidate provenance' {
        $c = New-OperatorCase
        Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -To Fixer -Message 'fix' -RequireDelivery | Out-Null
        Set-OperatorPlans $c @(@{ mutations = @(@{ path = 'README.txt'; content = 'retained' }); operatorMessages = @((New-OperatorPausePlan $c AfterRound)) }, @{},
            @{ mutations = @(@{path='README.txt';content='retained second attempt'}) }, @{})
        $r = Invoke-OperatorLoop $c
        if ($r.Status -ne 'paused') { throw $r.Reason }
        $s = Read-ReviewLoopState $c.Paths.StatePath
        $s.Stage | Should Be review_round_requested
        $s.RetainedCandidate.Artifact.ManifestPath | Should Not BeNullOrEmpty
        $s.RetainedCandidate.Attempt | Should Be 2
        $s.RetainedCandidate.Snapshot.Fingerprint | Should Be $s.Operator.Pause.Snapshot.Fingerprint
        Set-OperatorPlans $c @(@{ result = 'No findings.' }, @{ result = (Get-OperatorAcceptResult) }, @{ result = 'No findings.' })
        (Invoke-OperatorLoop $c).Status | Should Be completed
        @((Get-OperatorCalls) | Where-Object schemaPath -match 'fixer-result').Count | Should Be 2
    }

    It 'accepts a completion pause while messages are sealed and resumes without another goal call' {
        $c = New-OperatorCase
        Set-OperatorPlans $c @(@{ result = 'No findings.' }, @{ phase = 'completion'; result = (Get-OperatorAcceptResult); operatorMessages = @((New-OperatorPausePlan $c BeforeCompletion)) })
        $r = Invoke-OperatorLoop $c
        if ($r.Status -ne 'paused') { throw $r.Reason }
        $r.Requests[0].Reached | Should Be BeforeCompletion
        (Read-ReviewLoopState $c.Paths.StatePath).Operator.Boundary.Kind | Should Be completion
        $before = @(Get-OperatorCalls).Count
        (Invoke-OperatorLoop $c).Status | Should Be completed
        @(Get-OperatorCalls).Count | Should Be $before
        { Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -PauseAt AfterRole -Message 'late' } | Should Throw 'completion is sealed'
    }

    It 'does not turn a role technical failure into a successful pause' {
        $c = New-OperatorCase
        Set-OperatorPlans $c @(@{ exitCode = 7; operatorMessages = @((New-OperatorPausePlan $c AfterRole)) })
        $r = Invoke-OperatorLoop $c
        $r.Status | Should Be failed
        $r.ExitCode | Should Be 2
    }

    It 'preserves a published request through an import crash and marks it reached atomically' {
        $c = New-OperatorCase
        $id = Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -PauseAt AfterRole -Message 'inspect'
        & (Get-Module CodexReviewLoop) {
            param($c)
            $s = Read-ReviewLoopState $c.Paths.StatePath
            Import-ReviewLoopOperatorMessages $s (Get-ReviewLoopOperatorMailbox $s)
            # Simulate loss before the in-memory import was checkpointed.
            $s = Read-ReviewLoopState $c.Paths.StatePath
            @($s.Operator.Requests).Count | Should Be 0
        } $c
        (Invoke-OperatorLoop $c).Status | Should Be paused
        $s = Read-ReviewLoopState $c.Paths.StatePath
        $s.Status | Should Be paused
        $s.Operator.Requests[0].Status | Should Be reached
        Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -PauseAt AfterRole -Message 'inspect' -Id $id | Should Be $id
        (Invoke-OperatorLoop $c).Status | Should Be completed
    }

    It 'refuses changed paused candidates and damaged backups before resuming model work' {
        $c = New-OperatorCase
        Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -To Fixer -Message 'fix' -RequireDelivery | Out-Null
        Set-OperatorPlans $c @(@{ mutations = @(@{ path = 'README.txt'; content = 'fixed' }); operatorMessages = @((New-OperatorPausePlan $c AfterRole)) })
        (Invoke-OperatorLoop $c).Status | Should Be paused
        $before = @(Get-OperatorCalls).Count
        Set-Content (Join-Path $c.Repo 'README.txt') 'outside'
        (Invoke-OperatorLoop $c).Status | Should Be failed
        @(Get-OperatorCalls).Count | Should Be $before
        [IO.File]::WriteAllText((Join-Path $c.Repo 'README.txt'), 'fixed')
        $s = Read-ReviewLoopState $c.Paths.StatePath
        Set-Content (Join-Path $s.Operator.Pause.Backup.Root 'files\README.txt') 'damaged'
        (Invoke-OperatorLoop $c).Status | Should Be failed
        @(Get-OperatorCalls).Count | Should Be $before
    }

    It 'keeps PendingCommit resumable before staging, after staging, after commit-object creation and after HEAD advancement' {
        foreach ($phase in @('prepared','staged','object','advanced')) {
            $c = New-OperatorCase
            $before = & git -C $c.Repo rev-parse HEAD
            [IO.File]::WriteAllText((Join-Path $c.Repo 'README.txt'), 'candidate')
            & (Get-Module CodexReviewLoop) {
                param($c,$phase)
                $s = Read-ReviewLoopState $c.Paths.StatePath
                $s.ActiveFindingSource = 'operator'; $s.ActiveClusterId = 'pending-pause'
                $s.Stage = 'commit_preparing'
                $ledger = New-ReviewLoopLedger $c.Repo
                Write-ReviewLoopLedger $c.Paths.LedgerPath $ledger | Out-Null
                Close-ReviewLoopOperatorBoundary $s $c.Paths.StatePath commit | Out-Null
                $s.PendingCommit = [pscustomobject]@{
                    PreHead = $s.CurrentHead; PatchFingerprint = Get-ReviewLoopWorktreeFingerprint $c.Repo
                    ExpectedTree = ''; ExpectedCommit = ''; Message = 'Test: pending pause'; NeedsCurrentGates = $false
                    OperatorBoundaryId = $s.Operator.Boundary.Id
                    Verification = [pscustomobject]@{ WorkRevision=0; workOutcomes=@(); goalComplete=$false }
                }
                if ($phase -ne 'prepared') {
                    & git -C $c.Repo add -A
                    $s.PendingCommit.ExpectedTree = Get-ReviewLoopGitValue $c.Repo @('write-tree')
                    $s.Stage = 'commit_pending'
                }
                if ($phase -in @('object','advanced')) {
                    $s.PendingCommit.ExpectedCommit = (& git -C $c.Repo commit-tree $s.PendingCommit.ExpectedTree -p $s.CurrentHead -m $s.PendingCommit.Message).Trim()
                }
                if ($phase -eq 'advanced') {
                    & git -C $c.Repo update-ref HEAD $s.PendingCommit.ExpectedCommit $s.CurrentHead
                }
                Write-ReviewLoopState $c.Paths.StatePath $s | Out-Null
            } $c $phase
            Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -PauseAt BeforeCommit -Message 'late commit check' | Out-Null
            $r = Invoke-OperatorLoop $c
            if ($r.Status -ne 'paused') { throw "$phase : $($r.Reason)" }
            $r.Requests[0].Missed | Should Be $true
            $r.Requests[0].Reached | Should Be CommitRecovery
            (Read-ReviewLoopState $c.Paths.StatePath).PendingCommit | Should Not BeNullOrEmpty
            (Invoke-OperatorLoop $c).Status | Should Be completed
            (& git -C $c.Repo rev-list --count "$before..HEAD") | Should Be 1
            @(& git -C $c.Repo status --porcelain).Count | Should Be 0
            Clear-OperatorCase
        }
    }

    It 'finishes a running host gate and pauses at a recoverable commit instead of starting another transaction' {
        $c = New-OperatorCase
        $gate = Join-Path $c.Root 'gate.ps1'
        $counter = Join-Path $c.Root 'gate-count.txt'
        @"
& '$root\operator-message.ps1' '$($c.Paths.RunRoot)' -PauseAt BeforeCommit -Message 'gate check' | Out-Null
Add-Content '$counter' executed
"@ | Set-Content $gate
        (Get-Content -Raw $c.Profile).Replace('HostGates=@()', "HostGates=@(@{Name='pause gate';FilePath='pwsh';Arguments=@('-NoProfile','-File','$gate')})") | Set-Content $c.Profile
        Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -To Fixer -Message 'fix' -RequireDelivery | Out-Null
        Set-OperatorPlans $c @(@{ mutations = @(@{path='README.txt';content='fixed'}) }, @{ result=(Get-OperatorAcceptResult) })
        $r = Invoke-OperatorLoop $c
        if ($r.Status -ne 'paused') { throw $r.Reason }
        $r.Requests[0].Missed | Should Be $true
        $r.Requests[0].Reached | Should Be CommitRecovery
        $s = Read-ReviewLoopState $c.Paths.StatePath
        $s.ActiveHostGateRecovery | Should BeNullOrEmpty
        $s.PendingCommit | Should Not BeNullOrEmpty
        @(Get-Content $counter).Count | Should Be 1
        # Remove only the test gate after its recorded transaction. This forces
        # the ordinary execution requalification path on explicit resume.
        (Get-Content -Raw $c.Profile).Replace("HostGates=@(@{Name='pause gate';FilePath='pwsh';Arguments=@('-NoProfile','-File','$gate')})",'HostGates=@()') | Set-Content $c.Profile
        Set-OperatorPlans $c @(@{result=(Get-OperatorAcceptResult)}, @{result='No findings.'})
        (Invoke-OperatorLoop $c).Status | Should Be completed
    }

    It 'stops after a Critic and does not repeat its completed call on resume' {
        $c = New-OperatorCase
        (Get-Content -Raw $c.Profile).Replace('CriticStartAfterReviews=0','CriticStartAfterReviews=1').Replace('CleanPassesRequired=1','CleanPassesRequired=2') | Set-Content $c.Profile
        $env:CODEX_REVIEW_LOOP_FAKE_PID_FILE = Join-Path $c.Root 'role.pid'
        Set-OperatorPlans $c @(@{result='No findings.'}, @{operatorMessages=@((New-OperatorPausePlan $c AfterRole))})
        $r = Invoke-OperatorLoop $c
        $r.Status | Should Be paused
        @((Get-OperatorCalls) | Where-Object schemaPath -match 'critic-v2').Count | Should Be 1
        $rolePid = [int](Get-Content $env:CODEX_REVIEW_LOOP_FAKE_PID_FILE)
        Get-Process -Id $rolePid -ErrorAction SilentlyContinue | Should BeNullOrEmpty
        (Invoke-OperatorLoop $c).Status | Should Be completed
        @((Get-OperatorCalls) | Where-Object schemaPath -match 'critic-v2').Count | Should Be 1
    }

    It 'publishes identical pause IDs concurrently through the public command' {
        $c=New-OperatorCase
        $id=[guid]::NewGuid().ToString('D')
        $processes=@()
        try {
            foreach ($i in 1..2) {
                $info=[Diagnostics.ProcessStartInfo]::new()
                $info.FileName=(Get-Command pwsh).Source; $info.UseShellExecute=$false; $info.CreateNoWindow=$true
                $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
                @('-NoProfile','-File',(Join-Path $root 'operator-message.ps1'),$c.Paths.RunRoot,
                    '-PauseAt','AfterRole','-Message','parallel halt','-Id',$id) | ForEach-Object {[void]$info.ArgumentList.Add($_)}
                $processes += [Diagnostics.Process]::Start($info)
            }
            foreach ($process in $processes) {
                if (-not $process.WaitForExit(30000)) { throw 'Pause publisher did not finish.' }
                $process.StandardOutput.ReadToEnd() | Should Match "$id requested AfterRole"
                $process.StandardError.ReadToEnd() | Should Be ''
                $process.ExitCode | Should Be 0
            }
            $r=Invoke-OperatorLoop $c
            $r.Status | Should Be paused
            $r.Requests.Count | Should Be 1
        }
        finally {
            foreach ($process in $processes) {
                if (-not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
                $process.Dispose()
            }
        }
    }

    It 'returns public CLI exit 5 with JSON and releases the repository lease' {
        $c=New-OperatorCase
        Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -PauseAt AfterRole -Message 'CLI halt' | Out-Null
        $info=[Diagnostics.ProcessStartInfo]::new()
        $info.FileName=(Get-Command pwsh).Source; $info.UseShellExecute=$false; $info.CreateNoWindow=$true
        $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
        @('-NoProfile','-File',(Join-Path $root 'codex-review-loop.ps1'),'-RepoPath',$c.Repo,
            '-ConfigPath',$c.Profile,'-CodexPath',$fakeCodex,'-Json','-HeartbeatSeconds','0') | ForEach-Object {[void]$info.ArgumentList.Add($_)}
        $process=[Diagnostics.Process]::Start($info)
        try {
            if (-not $process.WaitForExit(30000)) { throw 'Paused CLI did not exit.' }
            $process.ExitCode | Should Be 5
            ($process.StandardOutput.ReadToEnd() | ConvertFrom-Json).Status | Should Be paused
            $process.StandardError.ReadToEnd() | Should Be ''
            $lease=[IO.FileStream]::new((Join-Path $c.Repo '.git\codex-review-loop.lock'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
            $lease.Dispose()
        }
        finally {
            if (-not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
            $process.Dispose()
        }
    }

}

Describe 'Operator pause persistence boundaries' {
    AfterEach { Clear-OperatorCase }

    It 'recovers actual process death after saving a Fixer result and after saving the reached pause' {
        foreach ($crashAt in @('fixer-result','paused')) {
            $c=New-OperatorCase
            $marker=Join-Path $c.Root 'checkpoint-saved.txt'
            $scriptPath=Join-Path $c.Root 'crash-window.ps1'
            @'
param($modulePath,$repo,$profilePath,$fake,$marker,$crashAt)
Import-Module $modulePath -Force
& (Get-Module CodexReviewLoop) {
    param($marker,$crashAt)
    $script:crashMarker=$marker
    $script:crashAt=$crashAt
    $script:crashWrite=${function:Write-ReviewLoopState}
    function script:Write-ReviewLoopState {
        param($Path,$State)
        & $script:crashWrite -Path $Path -State $State
        $last=$State.RoleCalls | Select-Object -Last 1
        $ready=($script:crashAt -eq 'paused' -and $State.Status -eq 'paused') -or
            ($script:crashAt -eq 'fixer-result' -and $State.Stage -eq 'fixing' -and
             $null -eq $State.ActiveRoleCall -and $null -ne $last -and $last.Role -eq 'Fixer' -and $last.Success)
        if ($ready) {
            [IO.File]::WriteAllText($script:crashMarker,'saved')
            Start-Sleep -Seconds 60
        }
    }
} $marker $crashAt
Invoke-CodexReviewLoop -RepoPath $repo -ConfigPath $profilePath -CodexPath $fake -HeartbeatSeconds 0 -Json
'@ | Set-Content $scriptPath
            if ($crashAt -eq 'fixer-result') {
                Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -To Fixer -Message 'fix' -RequireDelivery | Out-Null
                Set-OperatorPlans $c @(@{mutations=@(@{path='README.txt';content='saved candidate'});operatorMessages=@((New-OperatorPausePlan $c AfterRole))})
            }
            else { Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -PauseAt AfterRole -Message 'crash after halt' | Out-Null }
            $info=[Diagnostics.ProcessStartInfo]::new()
            $info.FileName=(Get-Command pwsh).Source; $info.UseShellExecute=$false; $info.CreateNoWindow=$true
            $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
            @('-NoProfile','-File',$scriptPath,(Join-Path $root 'CodexReviewLoop.psd1'),$c.Repo,$c.Profile,$fakeCodex,$marker,$crashAt) |
                ForEach-Object {[void]$info.ArgumentList.Add($_)}
            $process=[Diagnostics.Process]::Start($info)
            try {
                $deadline=[DateTimeOffset]::UtcNow.AddSeconds(30)
                while (-not (Test-Path $marker) -and -not $process.HasExited -and [DateTimeOffset]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
                if (-not (Test-Path $marker)) { throw "Crash checkpoint was not reached ($crashAt)." }
                $process.Kill($true)
                $process.WaitForExit()
            }
            finally {
                if (-not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
                $process.Dispose()
            }
            if ($crashAt -eq 'fixer-result') {
                (Invoke-OperatorLoop $c).Status | Should Be paused
                Set-OperatorPlans $c @(@{result=(Get-OperatorAcceptResult)}, @{result='No findings.'})
            }
            (Invoke-OperatorLoop $c).Status | Should Be completed
            if ($crashAt -eq 'fixer-result') {
                @((Get-OperatorCalls) | Where-Object schemaPath -match 'fixer-result').Count | Should Be 1
                Get-Content (Join-Path $c.Repo 'README.txt') | Should Be 'saved candidate'
            }
            Clear-OperatorCase
        }
    }

    It 'stops after Architect assessment before gates and reuses the applied decision on resume' {
        $c=New-OperatorCase
        Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -To Fixer -Message 'fix' -RequireDelivery | Out-Null
        Set-OperatorPlans $c @(@{mutations=@(@{path='README.txt';content='fixed'})},
            @{result=(Get-OperatorAcceptResult);operatorMessages=@((New-OperatorPausePlan $c AfterRole))})
        $r=Invoke-OperatorLoop $c
        $r.Status | Should Be paused
        (Read-ReviewLoopState $c.Paths.StatePath).Stage | Should Be verified
        Set-OperatorPlans $c @(@{result='No findings.'})
        (Invoke-OperatorLoop $c).Status | Should Be completed
        @((Get-OperatorCalls) | Where-Object schemaPath -match 'assessment').Count | Should Be 1
    }

    It 'keeps a mutating gate failure technical while its pause remains pending' {
        $c=New-OperatorCase
        $gate=Join-Path $c.Root 'mutating-gate.ps1'
        @"
& '$root\operator-message.ps1' '$($c.Paths.RunRoot)' -PauseAt AfterRole -Message 'gate failed' | Out-Null
Set-Content '$($c.Repo)\README.txt' 'gate side effect'
"@ | Set-Content $gate
        (Get-Content -Raw $c.Profile).Replace('HostGates=@()',"HostGates=@(@{Name='mutation';FilePath='pwsh';Arguments=@('-NoProfile','-File','$gate')})") | Set-Content $c.Profile
        Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -To Fixer -Message 'fix' -RequireDelivery | Out-Null
        Set-OperatorPlans $c @(@{mutations=@(@{path='README.txt';content='fixed'})},@{result=(Get-OperatorAcceptResult)})
        $r=Invoke-OperatorLoop $c
        $r.Status | Should Be failed
        $r.ExitCode | Should Be 2
        (Read-ReviewLoopState $c.Paths.StatePath).ActiveHostGateRecovery | Should Not BeNullOrEmpty
    }

    It 'rejects malformed or stale pause envelopes without delivering them as role evidence' {
        $c=New-OperatorCase
        $mixedRejected=$false
        try { Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -PauseAt AfterRole -To Fixer -Message 'mixed' -ErrorAction Stop }
        catch [System.Management.Automation.ParameterBindingException] { $mixedRejected=$true }
        $mixedRejected | Should Be $true
        $bad=Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -PauseAt AfterRole -Message 'bad target'
        $stale=Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -PauseAt AfterRole -Message 'wrong run'
        & (Get-Module CodexReviewLoop) {
            param($c,$bad,$stale)
            $s=Read-ReviewLoopState $c.Paths.StatePath
            $mailbox=Get-ReviewLoopOperatorMailbox $s
            $p=Join-Path $mailbox "$bad.json"
            $request=Read-ReviewLoopJson $p
            $request.Target.Cycle='invalid'
            Write-ReviewLoopAtomicJson $p $request
            $p=Join-Path $mailbox "$stale.json"
            $request=Read-ReviewLoopJson $p
            $request.Run.RunId='wrong-run'
            Write-ReviewLoopAtomicJson $p $request
        } $c $bad $stale
        (Invoke-OperatorRole $c).Success | Should Be $true
        $s=Read-ReviewLoopState $c.Paths.StatePath
        ($s.Operator.Requests | Where-Object Id -eq $bad).Rejection | Should Be 'invalid request'
        ($s.Operator.Requests | Where-Object Id -eq $stale).Rejection | Should Be 'run identity mismatch'
        $s.Operator.Revisions.Architect | Should Be 0
    }
}

Describe 'Operator pause completion-round boundaries' {
    AfterEach { Clear-OperatorCase }

    It 'stops after LessonsLearned or its outside-round result before new repair work' {
        foreach ($variant in @(@{At='AfterRole';Changes=$false}, @{At='AfterRound';Changes=$false}, @{At='AfterRound';Changes=$true})) {
            $c=New-OperatorCase
            Set-Content (Join-Path $c.Repo 'AGENTS.md') 'Use the repository contract.'
            & git -C $c.Repo add AGENTS.md
            & git -C $c.Repo commit -q -m 'fixture guidance'
            & (Get-Module CodexReviewLoop) {
                param($c)
                $s=Read-ReviewLoopState $c.Paths.StatePath
                $s.StartHead=$s.CurrentHead=Get-ReviewLoopGitValue $c.Repo @('rev-parse','HEAD')
                Write-ReviewLoopState $c.Paths.StatePath $s | Out-Null
            } $c
            (Get-Content -Raw $c.Profile).Replace('LessonsLearnedCommitThreshold=0','LessonsLearnedCommitThreshold=1') | Set-Content $c.Profile
            Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -To Fixer -Message 'fix' -RequireDelivery | Out-Null
            $lesson=@{operatorMessages=@((New-OperatorPausePlan $c $variant.At))}
            if ($variant.Changes) {
                $lesson.result=@{
                    schemaVersion='2.0';summary='Record a durable invariant.'
                    diagnosis=@{summary='The guidance needs clarification.';causes=@();guidanceAssessment=@()}
                    changes=@(@{title='Record the invariant';action='update';surface='agents_md';targets=@('AGENTS.md')
                        outcome='Clarify the invariant.';rationale='The run evidenced a gap.';futureUse='Future changes.';evidence=@('The accepted fix.')})
                } | ConvertTo-Json -Depth 10 -Compress
            }
            $plans=@(@{mutations=@(@{path='README.txt';content='fixed'})}, @{result=(Get-OperatorAcceptResult)}, @{result='No findings.'}, $lesson)
            if ($variant.Changes) { $plans+=@(@{exitCode=13},@{exitCode=13},@{exitCode=13}) }
            Set-OperatorPlans $c $plans
            $r=Invoke-OperatorLoop $c
            if ($r.Status -ne 'paused') { throw "Expected $($variant.At) pause, got $($r.Status): $($r.Reason)" }
            $s=Read-ReviewLoopState $c.Paths.StatePath
            $s.Stage | Should Be $(if($variant.Changes){'reviewed'}else{'lessons_learned_completed'})
            @((Get-OperatorCalls) | Where-Object schemaPath -match 'fixer-result').Count | Should Be 1
            if ($variant.Changes) {
                Set-OperatorPlans $c @(@{}, @{mutations=@(@{path='AGENTS.md';content='Updated lesson guidance.'})}, @{result=(Get-OperatorAcceptResult)})
            }
            (Invoke-OperatorLoop $c).Status | Should Be completed
            @((Get-OperatorCalls) | Where-Object schemaPath -match 'lessons-learned').Count | Should Be 1
            if ($variant.Changes) { @((Get-OperatorCalls) | Where-Object schemaPath -match 'fixer-result').Count | Should Be 2 }
            Clear-OperatorCase
        }
    }
}
