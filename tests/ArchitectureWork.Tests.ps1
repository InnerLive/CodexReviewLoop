$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
Import-Module (Join-Path $root "CodexReviewLoop.psd1") -Force
. (Join-Path $here "InProcessCodex.ps1")

function New-WorkTestCase {
    $caseRoot = Join-Path $TestDrive ([Guid]::NewGuid().ToString("N"))
    $repo = Join-Path $caseRoot "repository"
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
    & git -C $repo init -q
    & git -C $repo config user.email "architecture-tests@example.invalid"
    & git -C $repo config user.name "Architecture Tests"
    & git -C $repo config core.autocrlf false
    Set-Content (Join-Path $repo "README.md") "Public discount accepts whole-number percentages."
    & git -C $repo add README.md
    & git -C $repo commit -qm "Preserve the public percentage contract"
    $profile = Join-Path $caseRoot "profile.psd1"
    @"
@{
 Name = 'ArchitectureTests'
 ReviewBase = 'HEAD'
 LogRoot = '$caseRoot/logs'
 CleanPassesRequired = 1
 MaxReviewCycles = 1
 MaxFixAttempts = 1
 CriticStartAfterReviews = 0
 LessonsLearnedCommitThreshold = 0
 HostGates = @()
 Roles = @{
  Reviewer = @{ Model = 'fake'; Thinking = 'high' }
  Architect = @{ Model = 'fake'; Thinking = 'high' }
  Fixer = @{ Model = 'fake'; Thinking = 'high' }
 }
}
"@ | Set-Content $profile
    $env:CODEX_REVIEW_LOOP_FAKE_LOG = Join-Path $caseRoot "calls.jsonl"
    $env:CODEX_REVIEW_LOOP_FAKE_INVOCATION_SEQUENCE = Join-Path $caseRoot "plans.json"
    $env:CODEX_REVIEW_LOOP_FAKE_THREAD = "work-thread"
    return @{ RepoPath=$repo; ConfigPath=$profile; CodexPath=(Join-Path $here "FakeCodex.ps1"); HeartbeatSeconds=0; ColorMode="Never" }
}
function Set-WorkTestPlans {
    param([object[]]$Plans)
    ConvertTo-Json -InputObject $Plans -Depth 30 | Set-Content $env:CODEX_REVIEW_LOOP_FAKE_INVOCATION_SEQUENCE
}
function Get-WorkTestCalls {
    @(Get-Content $env:CODEX_REVIEW_LOOP_FAKE_LOG | ForEach-Object { $_ | ConvertFrom-Json })
}
function New-WorkTestOrder {
    @{ id="W-1"; objective="Preserve the percentage contract"; rationale="Public exports share this contract";
       doneWhen="The exported calculation and documentation agree"; evidence=@("README.md") }
}
function New-WorkTestOrientation {
    param([object[]]$Orders=@())
    @{ phase="orientation"; result=(ConvertTo-Json -Compress -Depth 12 @{
        schemaVersion="1.0"; goal=@{statement="Preserve public percentage behavior";sources=@("README.md and commits");uncertainties=@()};orders=$Orders
    }) }
}
function New-WorkTestAdvice {
    @{ result=(ConvertTo-Json -Compress -Depth 12 @{
        schemaVersion="3.0";summary="Treat the shared cause";approach="Align the public contract";steps=@();considerations=@();
        orders=@();selectedWorkIds=@("W-1")
    }) }
}
function New-WorkTestAssessment {
    param([bool]$Accept=$true,[string]$Status="accepted")
    @{ result=(ConvertTo-Json -Compress -Depth 12 @{
        schemaVersion="2.0";accept=$Accept;summary="Current contract assessed";feedback=@();
        commitMessage=@{subject="Preserve the percentage contract";rationale="Resolve shared work";changes=@("Align public behavior")};
        newOrders=@();workOutcomes=@(if($Accept){@{id="W-1";status=$Status;evidence="Current code and documentation match"}});
        goalComplete=$Accept
    }) }
}
function New-WorkTestFix {
    param([bool]$Change=$false)
    $plan = @{result='{"schemaVersion":"3.0","summary":"Worked on the contract","targetedTest":{"available":false,"executable":"","arguments":[]}}'}
    if($Change){$plan.mutations=@(@{path="new-contract.txt";content="preserved progress"})}
    $plan
}

Describe "Shared architecture work" -Tags @("FullLocal") {
    BeforeEach {
        Enable-InProcessCodexRoleCalls -Module (Get-Module CodexReviewLoop) -HelperPath (Join-Path $here "InProcessCodex.ps1")
        $arguments = New-WorkTestCase
    }
    AfterEach {
        Disable-InProcessCodexRoleCalls -Module (Get-Module CodexReviewLoop)
        Get-ChildItem Env:CODEX_REVIEW_LOOP_FAKE_* | Remove-Item
    }

    It "clarifies an omitted task before review and finishes without invented work" {
        Set-WorkTestPlans @(@{result="No findings."})
        $result = Invoke-CodexReviewLoop @arguments
        $result.Status | Should Be "completed"
        $state = Read-ReviewLoopState $result.StatePath
        $state.SchemaVersion | Should Be "2.0"
        $state.TaskContext | Should Be ""
        $state.ArchitectWork.Goal.sources[0] | Should Match "README"
        @($state.ArchitectWork.Orders).Count | Should Be 0
        $calls = Get-WorkTestCalls
        $calls[0].schemaPath | Should Match "orientation-v1"
        $calls[1].callKind | Should Be "review"
        @($calls | Where-Object schemaPath -Match "fixer").Count | Should Be 0
        & (Get-Module CodexReviewLoop) { param($s) Test-ReviewLoopGoalAccepted $s } $state | Should Be $true
    }

    It "handles an open architecture order despite a clean native review and accepts a no-op" {
        Set-WorkTestPlans @(
            (New-WorkTestOrientation @((New-WorkTestOrder))),
            @{result="No findings."}, (New-WorkTestAdvice), (New-WorkTestFix), (New-WorkTestAssessment))
        $result = Invoke-CodexReviewLoop @arguments
        $result.Status | Should Be "limit_reached"
        $state = Read-ReviewLoopState $result.StatePath
        $state.CleanPasses | Should Be 0
        $state.ArchitectWork.Orders[0].status | Should Be "accepted"
        $state.ArchitectWork.Orders[0].outcomeEvidence | Should Not BeNullOrEmpty
        Set-WorkTestPlans @(@{result="No findings."})
        $resumed = Invoke-CodexReviewLoop @arguments
        $resumed.Status | Should Be "completed"
        $calls = Get-WorkTestCalls
        @($calls | Where-Object schemaPath -Match "fixer").Count | Should Be 1
        $fixCall = @($calls | Where-Object schemaPath -Match "fixer")[0]
        $fixCall.prompt | Should Match "Preserve public percentage behavior"
        $fixCall.prompt | Should Match "W-1"
        @(& git -C $arguments.RepoPath status --porcelain).Count | Should Be 0
    }

    It "preserves rejected progress across the review budget and re-assesses a clean dirty candidate" {
        $partial = New-WorkTestAssessment $false
        $assessment = $partial.result | ConvertFrom-Json
        $assessment.workOutcomes = @(@{id="W-1";status="accepted";evidence="The inspected partial contract is correct"})
        $assessment.feedback = @("The overall implementation still needs correction")
        $partial.result = ConvertTo-Json -Compress -Depth 12 $assessment
        Set-WorkTestPlans @(
            (New-WorkTestOrientation @((New-WorkTestOrder))),
            @{result="- [P1] public percentage defect at README.md:1"},
            (New-WorkTestAdvice), (New-WorkTestFix $true), $partial)
        $first = Invoke-CodexReviewLoop @arguments
        $first.Status | Should Be "limit_reached"
        $state = Read-ReviewLoopState $first.StatePath
        $state.ArchitectWork.Orders[0].status | Should Be "open"
        $state.RetainedCandidate | Should Not BeNullOrEmpty
        (Get-Content (Join-Path $arguments.RepoPath "new-contract.txt")) | Should Be "preserved progress"
        $state.CleanPasses | Should Be 0
        $state.ArchitectWork.OverallAssessment | Should BeNullOrEmpty
        $record = @($state.RoleCalls | Where-Object {
            $_.CallId -match '-architect-assess-'
        })[-1]
        $record.StructuredResult.accept | Should Be $false
        $record.StructuredResult.workOutcomes[0].status | Should Be 'accepted'
        $record.StructuredResult.feedback[0] | Should Be 'The overall implementation still needs correction'
        Set-WorkTestPlans @(@{result="No findings."},(New-WorkTestAssessment))
        $second = Invoke-CodexReviewLoop @arguments
        $second.Status | Should Be "limit_reached"
        $accepted = Read-ReviewLoopState $second.StatePath
        $accepted.RunId | Should Be $state.RunId
        $accepted.ReviewBaseCommit | Should Be $state.ReviewBaseCommit
        $accepted.RetainedCandidate | Should BeNullOrEmpty
        $accepted.CleanPasses | Should Be 0
        $accepted.ArchitectWork.Orders[0].status | Should Be "accepted"
        @(& git -C $arguments.RepoPath status --porcelain).Count | Should Be 0
        @((Get-WorkTestCalls) | Where-Object schemaPath -Match "fixer").Count | Should Be 1
        Set-WorkTestPlans @(@{result="No findings."})
        (Invoke-CodexReviewLoop @arguments).Status | Should Be "completed"
    }

    It "refuses concurrent changes to a retained candidate" {
        Set-WorkTestPlans @(
            (New-WorkTestOrientation @((New-WorkTestOrder))),
            @{result="No findings."}, (New-WorkTestAdvice), (New-WorkTestFix $true), (New-WorkTestAssessment $false))
        $first = Invoke-CodexReviewLoop @arguments
        Add-Content (Join-Path $arguments.RepoPath "new-contract.txt") "unrelated change"
        $second = Invoke-CodexReviewLoop @arguments
        $second.ExitCode | Should Be 2
        (Get-Content -Raw (Join-Path $arguments.RepoPath "new-contract.txt")) | Should Match "unrelated change"
        @((Get-WorkTestCalls) | Where-Object callKind -EQ "review").Count | Should Be 1
    }

    It "inherits TaskContext and reorients an explicit empty replacement without deleting work" {
        Set-WorkTestPlans @(
            (New-WorkTestOrientation @((New-WorkTestOrder))),
            @{result="No findings."}, (New-WorkTestAdvice), (New-WorkTestFix $true), (New-WorkTestAssessment $false))
        $first = Invoke-CodexReviewLoop @arguments -TaskContext "Accept fractional percentages"
        $state = Read-ReviewLoopState $first.StatePath
        $state.TaskContext | Should Be "Accept fractional percentages"
        Set-WorkTestPlans @(
            (New-WorkTestOrientation),
            @{result="No findings."},(New-WorkTestAssessment))
        $second = Invoke-CodexReviewLoop @arguments -TaskContext ""
        $second.Status | Should Be "limit_reached"
        $new = Read-ReviewLoopState $second.StatePath
        $new.TaskContext | Should Be ""
        $new.ArchitectWork.Revision | Should BeGreaterThan $state.ArchitectWork.Revision
        @($new.ArchitectWork.Orders).Count | Should Be 1
        $new.CleanPasses | Should Be 0
        Set-WorkTestPlans @(@{result="No findings."})
        (Invoke-CodexReviewLoop @arguments).Status | Should Be "completed"
    }

    It "delivers shared context to mechanical classification without replacing native review evidence" {
        Set-WorkTestPlans @(
            @{result="The overall implementation seems reasonable."},
            @{result='{"schemaVersion":"1.0","hasFindings":false}'})
        $result = Invoke-CodexReviewLoop @arguments -TaskContext "Keep the public percentage contract"
        $result.Status | Should Be "completed"
        $classifier = @((Get-WorkTestCalls) | Where-Object schemaPath -Match "review-classification")[0]
        $classifier.prompt | Should Not Match "Keep the public percentage contract"
        $classifier.prompt | Should Match "shared task never overrides reported findings"
        $classifier.prompt | Should Match "The overall implementation seems reasonable"
        @((Get-WorkTestCalls) | Where-Object schemaPath -Match "fixer").Count | Should Be 0
    }

    It "does not close work when a repository gate fails" {
        $profile = Get-Content -Raw $arguments.ConfigPath
        $profile.Replace("HostGates = @()", "HostGates = @(@{Name='reject';FilePath='pwsh';Arguments=@('-NoProfile','-Command','exit 1')})") | Set-Content $arguments.ConfigPath
        Set-WorkTestPlans @(
            (New-WorkTestOrientation @((New-WorkTestOrder))),
            @{result="No findings."}, (New-WorkTestAdvice), (New-WorkTestFix), (New-WorkTestAssessment))
        $result = Invoke-CodexReviewLoop @arguments
        $state = Read-ReviewLoopState $result.StatePath
        $state.ArchitectWork.Orders[0].status | Should Be "open"
        $state.ArchitectWork.OverallAssessment | Should BeNullOrEmpty
        $result.Status | Should Not Be "completed"
    }

    It "requires completion evidence again after a task change even with completed lessons" {
        Set-WorkTestPlans @(@{result="No findings."})
        $first = Invoke-CodexReviewLoop @arguments -TaskContext "Original contract"
        $state = Read-ReviewLoopState $first.StatePath
        $state.LessonsLearned.Status = "completed"
        $state.LessonsLearned.CompletedHead = $state.CurrentHead
        $state.LessonsLearned.TriggerHead = $state.CurrentHead
        Write-ReviewLoopState $first.StatePath $state | Out-Null
        Set-WorkTestPlans @(@{result="No findings."})
        $second = Invoke-CodexReviewLoop @arguments -TaskContext "Updated contract"
        $second.Status | Should Be "completed"
        @((Get-WorkTestCalls) | Where-Object callKind -EQ "review").Count | Should Be 2
        @((Get-WorkTestCalls) | Where-Object schemaPath -Match "orientation").Count | Should Be 2
    }

    It "reevaluates previously closed orders instead of deleting them after a task change" {
        Set-WorkTestPlans @(
            (New-WorkTestOrientation @((New-WorkTestOrder))), @{result="No findings."},
            (New-WorkTestAdvice), (New-WorkTestFix), (New-WorkTestAssessment))
        $first = Invoke-CodexReviewLoop @arguments -TaskContext "Original percentage contract"
        $prior = Read-ReviewLoopState $first.StatePath
        $prior.ArchitectWork.Orders[0].status | Should Be "accepted"
        Set-WorkTestPlans @(
            (New-WorkTestOrientation), @{result="No findings."},
            (New-WorkTestAdvice), (New-WorkTestFix), (New-WorkTestAssessment $true "withdrawn"))
        $second = Invoke-CodexReviewLoop @arguments -TaskContext "Reevaluate the percentage contract"
        $state = Read-ReviewLoopState $second.StatePath
        @($state.ArchitectWork.Orders).Count | Should Be 1
        $state.ArchitectWork.Orders[0].id | Should Be "W-1"
        $state.ArchitectWork.Orders[0].status | Should Be "withdrawn"
        $state.ArchitectWork.Orders[0].outcomeEvidence | Should Not BeNullOrEmpty
        $state.ArchitectWork.Revision | Should BeGreaterThan $prior.ArchitectWork.Revision
    }

    It "resumes overall goal assessment without another review after interruption" {
        Set-WorkTestPlans @(
            @{result="No findings."},
            @{phase="completion";result="invalid structured output"})
        $first = Invoke-CodexReviewLoop @arguments
        $first.ExitCode | Should Be 2
        Set-WorkTestPlans @()
        $second = Invoke-CodexReviewLoop @arguments
        $second.Status | Should Be "completed"
        @((Get-WorkTestCalls) | Where-Object callKind -EQ "review").Count | Should Be 1
    }

    It "requires explicit outcomes, preserves omitted orders and invalidates stale assessments" {
        Set-WorkTestPlans @(@{result="No findings."})
        $result = Invoke-CodexReviewLoop @arguments
        $state = Read-ReviewLoopState $result.StatePath
        & (Get-Module CodexReviewLoop) {
            param($s,$order)
            Merge-ReviewLoopWorkOrders $s @($order)
            Merge-ReviewLoopWorkOrders $s @()
            @(Get-ReviewLoopOpenWork $s).Count | Should Be 1
            Set-ReviewLoopWorkSelection $s @("W-1")
            $assessment = @{accept=$true;goalComplete=$false;newOrders=@();workOutcomes=@()}
            $rejected = $false
            try { Register-ReviewLoopWorkAssessment $s $assessment } catch { $rejected = $true }
            $rejected | Should Be $true
            $assessment.workOutcomes = @(@{id="W-1";status="withdrawn";evidence="The updated goal supersedes this work"})
            Register-ReviewLoopWorkAssessment $s $assessment
            $s.ArchitectWork.Revision++
            Complete-ReviewLoopArchitectureWork $s $assessment $s.RepoPath
            @(Get-ReviewLoopOpenWork $s).Count | Should Be 1
            Test-ReviewLoopGoalAccepted $s | Should Be $false
        } $state (New-WorkTestOrder)
    }

    It "leaves work unchanged when an assessment with new orders fails validation" {
        Set-WorkTestPlans @(@{result="No findings."})
        $result = Invoke-CodexReviewLoop @arguments
        $state = Read-ReviewLoopState $result.StatePath
        & (Get-Module CodexReviewLoop) {
            param($s,$order)
            Merge-ReviewLoopWorkOrders $s @($order)
            Set-ReviewLoopWorkSelection $s @('W-1')
            $before = ConvertTo-ReviewLoopJsonCompact $s
            $newOrder = [pscustomobject]@{id='W-2';objective='Additional work';rationale='Required by the goal';doneWhen='Evidence agrees';evidence=@('README.md')}
            $valid = @{id='W-1';status='accepted';evidence='Inspected source'}
            $cases = @(
                @{accept=$false;goalComplete=$false;newOrders=@($newOrder);workOutcomes=@(@{id='unknown';status='accepted';evidence='Inspected source'})},
                @{accept=$false;goalComplete=$false;newOrders=@($newOrder);workOutcomes=@($valid,$valid)},
                @{accept=$false;goalComplete=$false;newOrders=@($newOrder);workOutcomes=@(@{id='W-1';status='accepted';evidence=''})},
                @{accept=$true;goalComplete=$false;newOrders=@($newOrder);workOutcomes=@()},
                @{accept=$false;goalComplete=$true;newOrders=@($newOrder);workOutcomes=@($valid)},
                @{accept=$true;goalComplete=$true;newOrders=@($newOrder);workOutcomes=@($valid)},
                @{accept=$false;goalComplete=$false;newOrders=@($newOrder,$newOrder);workOutcomes=@($valid)}
            )
            foreach($assessment in $cases) {
                $copy = $before | ConvertFrom-Json -DateKind String
                $rejected = $false
                try { Register-ReviewLoopWorkAssessment $copy $assessment } catch { $rejected = $true }
                $rejected | Should Be $true
                (ConvertTo-ReviewLoopJsonCompact $copy) | Should Be $before
            }
        } $state (New-WorkTestOrder)
    }

    It "upgrades legacy state only at an inactive clean boundary and retains provenance" {
        Set-WorkTestPlans @(@{result="No findings."})
        $result = Invoke-CodexReviewLoop @arguments
        $state = Read-ReviewLoopState $result.StatePath
        $state.SchemaVersion = "1.0"
        foreach($property in @("TaskContext","ArchitectWork","ActiveWorkIds","ActiveFixAttempt","RetainedCandidate","LastReview","CompletionRequalificationRequired")){
            $state.PSObject.Properties.Remove($property)
        }
        Write-ReviewLoopState $result.StatePath $state | Out-Null
        $runId=$state.RunId
        Set-WorkTestPlans @(@{result="No findings."})
        $resumed = Invoke-CodexReviewLoop @arguments
        $resumed.Status | Should Be "completed"
        $new = Read-ReviewLoopState $result.StatePath
        $new.SchemaVersion | Should Be "2.0"
        $new.RunId | Should Be $runId
        $new.ReviewBaseCommit | Should Be $state.ReviewBaseCommit
        @($new.RoleCalls).Count | Should BeGreaterThan @($state.RoleCalls).Count
        Test-Path "$($result.StatePath).before-work-state-2.0.json" | Should Be $true
        $new.SchemaVersion="1.0"
        Set-Content (Join-Path $arguments.RepoPath "unexpected.txt") "external work"
        $rejected = $false
        try { & (Get-Module CodexReviewLoop) {param($s,$p) ConvertTo-ReviewLoopWorkState $s $p $s.RepoPath} $new $result.StatePath } catch { $rejected = $true }
        $rejected | Should Be $true
    }

    It "lets the overall assessment initiate necessary work after clean reviews" {
        $order = New-WorkTestOrder
        $pending = (New-WorkTestAssessment $false).result | ConvertFrom-Json
        $pending.newOrders = @($order)
        Set-WorkTestPlans @(
            @{result="No findings."}, @{phase="completion";result=(ConvertTo-Json $pending -Depth 20)},
            (New-WorkTestAdvice), (New-WorkTestFix), (New-WorkTestAssessment))
        $first = Invoke-CodexReviewLoop @arguments
        $first.Status | Should Be "limit_reached"
        $state = Read-ReviewLoopState $first.StatePath
        $state.ArchitectWork.Orders[0].status | Should Be "accepted"
        $state.CleanPasses | Should Be 0
        Set-WorkTestPlans @(@{result="No findings."})
        (Invoke-CodexReviewLoop @arguments).Status | Should Be "completed"
    }

    It "inherits the saved nonempty task on resumed sessions" {
        Set-WorkTestPlans @(
            (New-WorkTestOrientation @((New-WorkTestOrder))), @{result="No findings."},
            (New-WorkTestAdvice), (New-WorkTestFix), (New-WorkTestAssessment))
        $first = Invoke-CodexReviewLoop @arguments -TaskContext "Keep the public whole-number contract"
        Set-WorkTestPlans @(@{result="No findings."})
        $second = Invoke-CodexReviewLoop @arguments
        $second.Status | Should Be "completed"
        (Read-ReviewLoopState $second.StatePath).TaskContext | Should Be "Keep the public whole-number contract"
        @((Get-WorkTestCalls) | Where-Object { $_.prompt -match 'Keep the public whole-number contract' }).Count | Should BeGreaterThan 0
        @((Get-WorkTestCalls) | Where-Object { $_.callKind -eq 'review' -and $_.prompt }).Count | Should Be 0
        @((Get-WorkTestCalls) | Where-Object callKind -EQ "resume").Count | Should BeGreaterThan 0
    }

    It "reuses valid prepared work-only acceptance under current gates" {
        (Get-Content -Raw $arguments.ConfigPath).Replace(" HostGates = @()", " AutoCommit = `$false`n HostGates = @()") | Set-Content $arguments.ConfigPath
        Set-WorkTestPlans @(
            (New-WorkTestOrientation @((New-WorkTestOrder))), @{result="No findings."},
            (New-WorkTestAdvice), (New-WorkTestFix $true), (New-WorkTestAssessment))
        $first = Invoke-CodexReviewLoop @arguments
        $pending = Read-ReviewLoopState $first.StatePath
        $pending.PendingCommit.Verification.workOutcomes[0].id | Should Be "W-1"
        $pending.ArchitectWork.Orders[0].status | Should Be "open"
        (Get-Content -Raw $arguments.ConfigPath).Replace('AutoCommit = $false', 'AutoCommit = $true') | Set-Content $arguments.ConfigPath
        Set-WorkTestPlans @(@{result="No findings."})
        $second = Invoke-CodexReviewLoop @arguments
        $second.Status | Should Be "completed"
        (Read-ReviewLoopState $second.StatePath).ArchitectWork.Orders[0].status | Should Be "accepted"
        @(& git -C $arguments.RepoPath status --porcelain).Count | Should Be 0
        @((Get-WorkTestCalls) | Where-Object schemaPath -Match "fixer").Count | Should Be 1
    }

    It "reassesses a prepared work-only commit after an explicit task change" {
        (Get-Content -Raw $arguments.ConfigPath).Replace(" HostGates = @()", " AutoCommit = `$false`n HostGates = @()") | Set-Content $arguments.ConfigPath
        Set-WorkTestPlans @(
            (New-WorkTestOrientation @((New-WorkTestOrder))), @{result="No findings."},
            (New-WorkTestAdvice), (New-WorkTestFix $true), (New-WorkTestAssessment))
        $first = Invoke-CodexReviewLoop @arguments
        (Read-ReviewLoopState $first.StatePath).PendingCommit | Should Not BeNullOrEmpty
        (Get-Content -Raw $arguments.ConfigPath).Replace('AutoCommit = $false', 'AutoCommit = $true') | Set-Content $arguments.ConfigPath
        Set-WorkTestPlans @((New-WorkTestOrientation), (New-WorkTestAssessment), @{result="No findings."})
        $second = Invoke-CodexReviewLoop @arguments -TaskContext "Keep the percentage contract; verify the public entry point explicitly."
        $second.Status | Should Be "completed"
        $state = Read-ReviewLoopState $second.StatePath
        $state.ArchitectWork.Orders[0].status | Should Be "accepted"
        $state.ArchitectWork.Goal | Should Not BeNullOrEmpty
        @(& git -C $arguments.RepoPath status --porcelain).Count | Should Be 0
        @((Get-WorkTestCalls) | Where-Object schemaPath -Match "assessment-v2").Count | Should Be 2
        @((Get-WorkTestCalls) | Where-Object schemaPath -Match "fixer").Count | Should Be 1
    }

    It "preserves split index state and new files through native Reviewer cleanup" {
        Set-WorkTestPlans @(@{result="No findings."})
        $first = Invoke-CodexReviewLoop @arguments
        $state = Read-ReviewLoopState $first.StatePath
        $repo = $arguments.RepoPath
        $original = [IO.File]::ReadAllText((Join-Path $repo "README.md"))
        Set-Content (Join-Path $repo "README.md") "staged intermediate content"
        & git -C $repo add README.md
        [IO.File]::WriteAllText((Join-Path $repo "README.md"), $original)
        Set-Content (Join-Path $repo "new.txt") "owned progress"
        Disable-InProcessCodexRoleCalls -Module (Get-Module CodexReviewLoop)
        Set-WorkTestPlans @(@{result="No findings.";mutations=@(@{path="new.txt";content="Reviewer mutation"})})
        & (Get-Module CodexReviewLoop) {
            param($s,$options,$statePath,$ledgerPath)
            $snapshot = Get-ReviewLoopRepositorySnapshot $s.RepoPath
            $s.Status="running"; $s.ActiveClusterId="retained-split"
            $s.LastFixerResult = [pscustomobject]@{Success=$true;StructuredResult=@{summary="Partial repair"};RepositorySnapshot=$snapshot}
            $ledger=Read-ReviewLoopLedger $ledgerPath
            Restart-ReviewLoopReviewRound -State $s -StatePath $statePath -Ledger $ledger -LedgerPath $ledgerPath -Findings @() -RepoPath $s.RepoPath -RunRoot $s.RunRoot -Attempt 1
            $artifact=$s.RetainedCandidate.Artifact
            (Get-FileHash (Join-Path $artifact.Root "index")).Hash | Should Be $artifact.IndexSha256
            Test-Path (Join-Path $artifact.Root "files/new.txt") | Should Be $true
            $config=Import-ReviewLoopConfig -ConfigPath $options.ConfigPath -RepoPath $s.RepoPath
            $s.ReviewCycle++
            $review=Invoke-ReviewLoopReview -Config $config -State $s -StatePath $statePath -Ledger $ledger -RepoPath $s.RepoPath -Speed standard -RunRoot $s.RunRoot -CodexPath $options.CodexPath
            $review.Result.clean | Should Be $true
            Assert-ReviewLoopRepositoryUnchanged -RepoPath $s.RepoPath -Snapshot $snapshot -Operation "Native review recovery"
        } $state $arguments $first.StatePath $first.LedgerPath
        (Get-Content (Join-Path $repo "new.txt")) | Should Be "owned progress"
        (& git -C $repo diff --cached -- README.md) -join "\n" | Should Match "staged intermediate"
    }

    It "rejects incomplete version-2 state rather than silently resetting work" {
        Set-WorkTestPlans @(@{result="No findings."})
        $first = Invoke-CodexReviewLoop @arguments
        $state=Read-ReviewLoopState $first.StatePath
        $state.PSObject.Properties.Remove("ArchitectWork")
        $rejected=$false
        try { Write-ReviewLoopState $first.StatePath $state | Out-Null } catch { $rejected=$true }
        $rejected | Should Be $true
    }

    It "atomically rejects invalid plan orientation and completion without changing any state" {
        $state = New-ReviewLoopState -RepoPath $arguments.RepoPath -ReviewBase HEAD -Speed standard `
            -RunRoot (Split-Path $arguments.ConfigPath)
        & (Get-Module CodexReviewLoop) {
            param($s)
            Merge-ReviewLoopWorkOrders -State $s -Orders @([pscustomobject]@{
                id='CLOSED';objective='Original work';rationale='Evidence';doneWhen='Verified';evidence=@('README.md')
            })
            $s.ArchitectWork.Orders[0].status='accepted'
        } $state
        $state.ArchitectWork.Goal=[pscustomobject]@{statement='Original goal';sources=@('README.md');uncertainties=@()}
        $newOrder=[pscustomobject]@{id='NEW';objective='New work';rationale='New evidence';doneWhen='Verified';evidence=@('README.md')}
        $closedOrder=$newOrder.PSObject.Copy();$closedOrder.id='CLOSED'
        $goal=[pscustomobject]@{statement='Replacement goal';sources=@('README.md');uncertainties=@()}
        $cases=@(
            @{Kind='plan';Result=[pscustomobject]@{orders=@($newOrder,$closedOrder);selectedWorkIds=@('NEW')};Reason='already closed'},
            @{Kind='plan';Result=[pscustomobject]@{orders=@($newOrder);selectedWorkIds=@('MISSING')};Reason='unknown open'},
            @{Kind='plan';Result=[pscustomobject]@{orders=@($newOrder);selectedWorkIds=@('NEW','NEW')};Reason='duplicate'},
            @{Kind='plan';Result=[pscustomobject]@{orders=@($newOrder);selectedWorkIds=@()};Reason='must select'},
            @{Kind='orientation';Result=[pscustomobject]@{goal=$goal;orders=@($newOrder,$closedOrder)};Reason='already closed'},
            @{Kind='orientation';Result=[pscustomobject]@{goal=$goal;orders=@($newOrder,$newOrder)};Reason='Duplicate architecture'},
            @{Kind='goal';Result=[pscustomobject]@{accept=$false;goalComplete=$false;newOrders=@();workOutcomes=@()};Reason='without identifying'}
        )
        foreach($case in $cases){
            $before=$state|ConvertTo-Json -Depth 50 -Compress
            $resultBefore=$case.Result|ConvertTo-Json -Depth 30 -Compress
            $failure=$null
            try {
                & (Get-Module CodexReviewLoop) {
                    param($s,$c)
                    switch($c.Kind){
                        plan {Register-ReviewLoopWorkPlan -State $s -Result $c.Result -RequireSelection}
                        orientation {Register-ReviewLoopOrientation -State $s -Result $c.Result}
                        goal {Register-ReviewLoopWorkAssessment -State $s -Result $c.Result -RequireGoalDecision}
                    }
                } $state $case
            }catch{$failure=$_}
            $failure.Exception.Message|Should Match $case.Reason
            ($state|ConvertTo-Json -Depth 50 -Compress)|Should Be $before
            ($case.Result|ConvertTo-Json -Depth 30 -Compress)|Should Be $resultBefore
        }
        & (Get-Module CodexReviewLoop) {
            param($s,$g,$o)
            Register-ReviewLoopOrientation -State $s -Result ([pscustomobject]@{goal=$g;orders=@($o)})
        } $state $goal $newOrder
        $state.ArchitectWork.Goal.statement|Should Be 'Replacement goal'
        $state.ArchitectWork.OrientationRequired|Should Be $false
        @($state.ArchitectWork.Orders|Where-Object id -eq NEW).Count|Should Be 1
        $state.ArchitectWork.Orders[0].status|Should Be 'accepted'
    }

    It "validates the new closed role schemas including required evidence and statuses" {
        $values = @(
            @{Name="architecture-orientation-v1";Result=(New-WorkTestOrientation).result},
            @{Name="architecture-advice-v3";Result=(New-WorkTestAdvice).result},
            @{Name="architecture-assessment-v2";Result=(New-WorkTestAssessment).result})
        foreach($item in $values){
            $schema=Join-Path $root "schemas/$($item.Name).schema.json"
            $item.Result | Test-Json -SchemaFile $schema | Should Be $true
            $bad=$item.Result | ConvertFrom-Json
            $bad | Add-Member -NotePropertyName extra -NotePropertyValue $true
            ConvertTo-Json $bad -Depth 20 | Test-Json -SchemaFile $schema -ErrorAction SilentlyContinue | Should Be $false
        }
        $bad = (New-WorkTestAssessment).result | ConvertFrom-Json
        $bad.workOutcomes[0].status = "implicitly_done"
        ConvertTo-Json $bad -Depth 20 | Test-Json -SchemaFile (Join-Path $root "schemas/architecture-assessment-v2.schema.json") -ErrorAction SilentlyContinue | Should Be $false
    }
}
