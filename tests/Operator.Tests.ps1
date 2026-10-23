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

Describe 'Durable operator messages' {
    AfterEach { Clear-OperatorCase }

    It 'publishes immutable messages outside the worktree and retries identical IDs' {
        $c=New-OperatorCase
        $id=[guid]::NewGuid().ToString('D')
        Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -To Fixer,Architect -Message 'evidence' -Id $id | Should Be $id
        Send-ReviewLoopOperatorMessage $c.Paths.RunRoot -To Architect,Fixer -Message 'evidence' -Id $id | Should Be $id
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
        $request.Version=2
        $request | ConvertTo-Json -Depth 10 | Set-Content $path
        (Invoke-OperatorRole $c).Success | Should Be $true
        $s=Read-ReviewLoopState $c.Paths.StatePath
        $s.Operator.Requests[0].Rejection | Should Be 'unknown request version'
        $s.Operator.Version=2
        $s | ConvertTo-Json -Depth 50 | Set-Content $c.Paths.StatePath
        {Read-ReviewLoopState $c.Paths.StatePath} | Should Throw 'Unknown operator state version'
        $s.Operator.Version=1
        $s | ConvertTo-Json -Depth 50 | Set-Content $c.Paths.StatePath
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
