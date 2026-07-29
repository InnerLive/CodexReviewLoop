$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
$modulePath = Join-Path $root "CodexReviewLoop.psd1"
$fakeCodex = Join-Path $here "FakeCodex.ps1"

Import-Module $modulePath -Force

function New-TestRepo {
    param([string]$Path)
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    & git -C $Path init -q
    & git -C $Path config user.email "review-loop-tests@example.invalid"
    & git -C $Path config user.name "Review Loop Tests"
    Set-Content -LiteralPath (Join-Path $Path "README.txt") -Value "test"
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

function New-TestFinding {
    param(
        [string]$Path = "src/A.cs",
        [string]$Component = "cache",
        [string]$RootCause = "missing dependency",
        [string]$Invariant = "cache invalidates",
        [string[]]$FixPaths = @("src/A.cs")
    )
    return [pscustomobject]@{
        priority = "P1"
        title = "test finding"
        path = $Path
        line = 10
        component = $Component
        rootCause = $RootCause
        invariant = $Invariant
        evidence = "evidence"
        reproduction = "reproduction"
        suggestedFix = "fix"
        suggestedTest = "test"
        fixPaths = $FixPaths
    }
}

function Test-Throws {
    param([scriptblock]$Script)
    try {
        & $Script | Out-Null
        return $false
    }
    catch {
        return $true
    }
}

function New-TestConfig {
    param(
        [string]$Path,
        [string]$LogRoot,
        [switch]$WithHostGate
    )
    $gate = if ($WithHostGate) {
        '@{ Name = "fake gate"; FilePath = "pwsh"; Arguments = @("-NoProfile", "-Command", "exit 0") }'
    }
    else {
        ""
    }
    $content = @"
@{
    Name = "TestRepo"
    ReviewBase = "HEAD"
    LogRoot = "$($LogRoot.Replace("\", "\\"))"
    CleanPassesRequired = 2
    MaxReviewCycles = 6
    MaxFixAttempts = 2
    MaxArchitectureRevisions = 1
    AutoCommit = `$true
    CommitMessagePrefix = "Test Review Loop"
    HostGates = @($gate)
    Roles = @{
        Reviewer = @{ Model = "fake"; Thinking = "high" }
        TriggerJudge = @{ Model = "fake"; Thinking = "low" }
        TriggerConfirm = @{ Model = "fake"; Thinking = "low" }
        TriggerTieBreak = @{ Model = "fake"; Thinking = "medium" }
        Architect = @{ Model = "fake"; Thinking = "max" }
        ArchitectureCritic = @{ Model = "fake"; Thinking = "medium" }
        ArchitectureVeto = @{ Model = "fake"; Thinking = "medium" }
        ArchitectureTieBreak = @{ Model = "fake"; Thinking = "high" }
        PointFixer = @{ Model = "fake"; Thinking = "high" }
        ArchitectureFixer = @{ Model = "fake"; Thinking = "max" }
        FindingVerifier = @{ Model = "fake"; Thinking = "low" }
        VerifierConfirm = @{ Model = "fake"; Thinking = "low" }
        VerifierTieBreak = @{ Model = "fake"; Thinking = "medium" }
    }
}
"@
    Set-Content -LiteralPath $Path -Value $content -Encoding UTF8
    return $Path
}

function Write-FakeResultSequence {
    param([string]$Path, [string[]]$Results)
    Set-Content -LiteralPath $Path -Value ($Results | ConvertTo-Json -Depth 20) -Encoding UTF8
}

function New-TestActiveCheckpoint {
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [ValidateSet("standard", "fast")][string]$Speed = "standard"
    )

    return & (Get-Module CodexReviewLoop) {
        param($repository, $profilePath, $runSpeed)

        $config = Import-ReviewLoopConfig -ConfigPath $profilePath -RepoPath $repository
        $baseCommit = Get-ReviewLoopGitValue -RepoPath $repository -Arguments @(
            "rev-parse", "--verify", "$($config.ReviewBase)^{commit}"
        )
        $paths = New-ReviewLoopRunPaths `
            -Config $config `
            -RepoPath $repository `
            -ReviewBaseCommit $baseCommit
        Initialize-ReviewLoopRunPaths -Paths $paths | Out-Null
        $state = New-ReviewLoopState `
            -RepoPath $repository `
            -ReviewBase ([string]$config.ReviewBase) `
            -ReviewBaseCommit $baseCommit `
            -ExecutionFingerprint (Get-ReviewLoopExecutionFingerprint -ConfigPath $profilePath) `
            -Speed $runSpeed `
            -RunRoot $paths.RunRoot
        Write-ReviewLoopState -Path $paths.StatePath -State $state | Out-Null
        return [pscustomobject]@{
            RunRoot = $paths.RunRoot
            StatePath = $paths.StatePath
        }
    } $RepoPath $ConfigPath $Speed
}

Describe "Codex Review Loop module" {
    It "imports the module" {
        Get-Module CodexReviewLoop | Should Not BeNullOrEmpty
    }

    It "exports the main command" {
        Get-Command Invoke-CodexReviewLoop -ErrorAction Stop | Should Not BeNullOrEmpty
    }

    It "exports the CLI adapter" {
        Get-Command Invoke-CodexCliRole -ErrorAction Stop | Should Not BeNullOrEmpty
    }

    It "ships no repository-specific profiles" {
        $trackedProfiles = @(& git -C $root ls-files -- "profiles/*.psd1")
        @($trackedProfiles | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count | Should Be 0
    }

    It "defines every planned role in generated profiles" {
        $repo = New-TestRepo (Join-Path $TestDrive "role-profile-repo")
        $profilePath = Join-Path $TestDrive "generated\roles.psd1"
        $module = Get-Module CodexReviewLoop
        $generated = & $module {
            param($repository, $path)
            New-ReviewLoopProfile -RepoPath $repository -Path $path
        } $repo $profilePath
        $profile = Import-PowerShellDataFile -LiteralPath $generated
        $profile.Roles.Keys.Count | Should Be 13
    }
}

Describe "Optional profiles and command help" {
    It "does not require ConfigPath on the module command" {
        $parameter = (Get-Command Invoke-CodexReviewLoop).Parameters["ConfigPath"]
        $mandatory = @($parameter.Attributes | Where-Object {
            $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory
        })
        $mandatory.Count | Should Be 0
    }

    It "prefers a repository-local profile" {
        $repo = New-TestRepo (Join-Path $TestDrive "local-profile-repo")
        $localProfile = New-TestConfig `
            -Path (Join-Path $repo ".codex-review-loop.psd1") `
            -LogRoot (Join-Path $TestDrive "local-logs")
        $profilesRoot = Join-Path $TestDrive "profiles"
        $module = Get-Module CodexReviewLoop

        $resolved = & $module {
            param($repository, $profiles)
            Resolve-ReviewLoopConfigPath -RepoPath $repository -ProfilesRoot $profiles
        } $repo $profilesRoot

        (Split-Path -Leaf $resolved) | Should Be ".codex-review-loop.psd1"
        (Test-Path -LiteralPath $resolved -PathType Leaf) | Should Be $true
        (Test-Path -LiteralPath $profilesRoot) | Should Be $false
    }

    It "creates a commented named profile when none exists" {
        $repo = New-TestRepo (Join-Path $TestDrive "automatic-profile-repo")
        $profilesRoot = Join-Path $TestDrive "profiles"
        $module = Get-Module CodexReviewLoop

        $resolved = & $module {
            param($repository, $profiles)
            Resolve-ReviewLoopConfigPath -RepoPath $repository -ProfilesRoot $profiles
        } $repo $profilesRoot

        (Split-Path -Leaf $resolved) | Should Be "automatic-profile-repo-001.psd1"
        (Test-Path -LiteralPath $resolved -PathType Leaf) | Should Be $true
        $content = Get-Content -Raw -LiteralPath $resolved
        $content | Should Match "# Role settings:"
        $content | Should Match "# Host gates"
        $profile = Import-PowerShellDataFile -LiteralPath $resolved
        $profile.Name | Should Be "automatic-profile-repo"
        $canonicalRepo = & $module {
            param($repository)
            Get-ReviewLoopRepositoryRoot -RepoPath $repository
        } $repo
        $profile.RepositoryPath | Should Be $canonicalRepo
        $profile.LogRoot | Should Be ".\runs"
        $profile.Roles.Keys.Count | Should Be 13
        @($profile.HostGates).Count | Should Be 1
        $imported = & $module {
            param($path)
            Import-ReviewLoopConfig -ConfigPath $path
        } $resolved
        $imported.LogRoot | Should Be (Join-Path $root "runs")
    }

    It "reuses the profile matched by canonical repository path" {
        $repo = New-TestRepo (Join-Path $TestDrive "canonical-profile-repo")
        $subdirectory = Join-Path $repo "src"
        New-Item -ItemType Directory -Path $subdirectory | Out-Null
        $profilesRoot = Join-Path $TestDrive "canonical-profiles"
        $module = Get-Module CodexReviewLoop

        $first = & $module {
            param($repository, $profiles)
            Resolve-ReviewLoopConfigPath -RepoPath $repository -ProfilesRoot $profiles
        } $repo $profilesRoot
        $fromSubdirectory = & $module {
            param($repository, $profiles)
            Resolve-ReviewLoopConfigPath -RepoPath $repository -ProfilesRoot $profiles
        } $subdirectory $profilesRoot

        $fromSubdirectory | Should Be $first
        @(Get-ChildItem -LiteralPath $profilesRoot -Filter "*.psd1").Count | Should Be 1
    }

    It "numbers profiles separately for equal repository names" {
        $firstRepo = New-TestRepo (Join-Path $TestDrive "first\SharedRepo")
        $secondRepo = New-TestRepo (Join-Path $TestDrive "second\SharedRepo")
        $profilesRoot = Join-Path $TestDrive "numbered-profiles"
        $module = Get-Module CodexReviewLoop

        $first = & $module {
            param($repository, $profiles)
            Resolve-ReviewLoopConfigPath -RepoPath $repository -ProfilesRoot $profiles
        } $firstRepo $profilesRoot
        $second = & $module {
            param($repository, $profiles)
            Resolve-ReviewLoopConfigPath -RepoPath $repository -ProfilesRoot $profiles
        } $secondRepo $profilesRoot

        (Split-Path -Leaf $first) | Should Be "SharedRepo-001.psd1"
        (Split-Path -Leaf $second) | Should Be "SharedRepo-002.psd1"
        $firstProfile = Import-PowerShellDataFile -LiteralPath $first
        $secondProfile = Import-PowerShellDataFile -LiteralPath $second
        $canonicalFirst = & $module {
            param($repository)
            Get-ReviewLoopRepositoryRoot -RepoPath $repository
        } $firstRepo
        $canonicalSecond = & $module {
            param($repository)
            Get-ReviewLoopRepositoryRoot -RepoPath $repository
        } $secondRepo
        $firstProfile.RepositoryPath | Should Be $canonicalFirst
        $secondProfile.RepositoryPath | Should Be $canonicalSecond
    }

    It "rejects an explicit profile bound to another repository" {
        $firstRepo = New-TestRepo (Join-Path $TestDrive "bound-first")
        $secondRepo = New-TestRepo (Join-Path $TestDrive "bound-second")
        $profilePath = Join-Path $TestDrive "bound\profile.psd1"
        $module = Get-Module CodexReviewLoop

        & $module {
            param($repository, $path)
            Resolve-ReviewLoopConfigPath -RepoPath $repository -ConfigPath $path
        } $firstRepo $profilePath | Out-Null

        (Test-Throws {
            & $module {
                param($repository, $path)
                Resolve-ReviewLoopConfigPath -RepoPath $repository -ConfigPath $path
            } $secondRepo $profilePath
        }) | Should Be $true
    }

    It "creates an explicitly requested missing profile" {
        $repo = New-TestRepo (Join-Path $TestDrive "explicit-profile-repo")
        $requested = Join-Path $TestDrive "custom\review.psd1"
        $module = Get-Module CodexReviewLoop

        $resolved = & $module {
            param($repository, $configPath)
            Resolve-ReviewLoopConfigPath -RepoPath $repository -ConfigPath $configPath
        } $repo $requested

        (Split-Path -Leaf $resolved) | Should Be "review.psd1"
        (Test-Path -LiteralPath $requested -PathType Leaf) | Should Be $true
        (Import-PowerShellDataFile -LiteralPath $requested).Name | Should Be "explicit-profile-repo"
    }

    It "shows help without requiring a repository" {
        $entryPoint = Join-Path $root "codex-review-loop.ps1"
        $output = & pwsh -NoLogo -NoProfile -NonInteractive -File $entryPoint -Help 2>&1
        $exitCode = $LASTEXITCODE

        $exitCode | Should Be 0
        ($output -join "`n") | Should Match "ConfigPath"
        ($output -join "`n") | Should Match "automatically"
        ($output -join "`n") | Should Match "NewRun"
        ($output -join "`n") | Should Match "OutputMode"
        ($output -join "`n") | Should Match "HeartbeatSeconds"
        ($output -join "`n") | Should Match "ColorMode"
        ($output -join "`n") | Should Match "Json"
    }

    It "shows actionable guidance when RepoPath is missing" {
        $entryPoint = Join-Path $root "codex-review-loop.ps1"
        $output = & pwsh -NoLogo -NoProfile -NonInteractive -File $entryPoint 2>&1
        $exitCode = $LASTEXITCODE
        $text = $output -join "`n"

        $exitCode | Should Be 1
        $text | Should Match "repository path is required"
        $text | Should Match "Recommended"
        $text | Should Match "-RepoPath"
        $text | Should Not Match '"Status"\s*:'
        $text | Should Not Match "CategoryInfo|ScriptStackTrace"
    }

    It "emits only JSON for a missing RepoPath when requested" {
        $entryPoint = Join-Path $root "codex-review-loop.ps1"
        $output = & pwsh -NoLogo -NoProfile -NonInteractive `
            -File $entryPoint -Json 2>&1
        $exitCode = $LASTEXITCODE
        $text = $output -join "`n"
        $result = $text | ConvertFrom-Json

        $exitCode | Should Be 1
        $result.Status | Should Be "failed"
        $result.ExitCode | Should Be 1
        ($result.NextSteps -join "`n") | Should Match "-RepoPath"
        $text | Should Not Match "\[X\]|Recommended|Alternative"
    }
}

Describe "Global CLI arguments" {
    BeforeEach {
        $repo = New-Item -ItemType Directory -Path (Join-Path $TestDrive ([Guid]::NewGuid().ToString("N"))) -Force
        $schema = Join-Path $root "schemas\review-result-v1.schema.json"
        $result = Join-Path $TestDrive "result.json"
    }

    It "uses the requested model" {
        $args = Get-CodexRoleArguments -RepoPath $repo.FullName -Model "test-model" -Thinking high
        ($args -contains "test-model") | Should Be $true
    }

    It "uses the requested thinking level" {
        $args = Get-CodexRoleArguments -RepoPath $repo.FullName -Model m -Thinking max
        ($args -join " ") | Should Match 'model_reasoning_effort="max"'
    }

    It "maps standard to the default tier explicitly" {
        $args = Get-CodexRoleArguments -RepoPath $repo.FullName -Model m -Thinking low -Speed standard
        ($args -join " ") | Should Match 'service_tier="default"'
    }

    It "maps fast to the fast tier explicitly" {
        $args = Get-CodexRoleArguments -RepoPath $repo.FullName -Model m -Thinking low -Speed fast
        ($args -join " ") | Should Match 'service_tier="fast"'
    }

    It "enables fast mode for fast" {
        $args = Get-CodexRoleArguments -RepoPath $repo.FullName -Model m -Thinking low -Speed fast
        ($args -join " ") | Should Match '--enable fast_mode'
    }

    It "does not enable fast mode for standard" {
        $args = Get-CodexRoleArguments -RepoPath $repo.FullName -Model m -Thinking low -Speed standard
        ($args -join " ") | Should Not Match 'fast_mode'
    }

    It "uses unattended full access for every call" {
        $args = Get-CodexRoleArguments -RepoPath $repo.FullName -Model m -Thinking low
        ($args -join " ") | Should Match 'dangerously-bypass-approvals-and-sandbox'
    }

    It "ignores Codex exec rules and never emits a managed sandbox" {
        $args = Get-CodexRoleArguments -RepoPath $repo.FullName -Model m -Thinking low
        ($args -contains "--ignore-rules") | Should Be $true
        ($args -contains "--sandbox") | Should Be $false
    }

    It "adds structured output paths" {
        $args = Get-CodexRoleArguments -RepoPath $repo.FullName -Model m -Thinking low -SchemaPath $schema -ResultPath $result
        ($args -contains "--output-schema") | Should Be $true
        ($args -contains "-o") | Should Be $true
    }

    It "rejects unsupported Codex Structured Output schema keywords locally" {
        $unsupportedSchema = Join-Path $TestDrive "unsupported-schema.json"
        Set-Content -LiteralPath $unsupportedSchema -Encoding UTF8 -Value @'
{"type":"array","items":{"type":"string"},"uniqueItems":true}
'@
        (Test-Throws {
            Get-CodexRoleArguments `
                -RepoPath $repo.FullName -Model m -Thinking low `
                -SchemaPath $unsupportedSchema -ResultPath $result
        }) | Should Be $true
    }

    It "builds resume arguments with the same tier" {
        $args = Get-CodexRoleArguments -RepoPath $repo.FullName -Model m -Thinking medium -Speed fast -Mode Resume -ThreadId thread-1
        ($args -join " ") | Should Match 'service_tier="fast".*resume thread-1 -$'
    }

    It "requires a thread id for resume" {
        (Test-Throws { Get-CodexRoleArguments -RepoPath $repo.FullName -Model m -Thinking low -Mode Resume }) | Should Be $true
    }
}

Describe "Finding identity and ledger" {
    BeforeEach {
        $repo = New-TestRepo (Join-Path $TestDrive ([Guid]::NewGuid().ToString("N")))
        $ledger = New-ReviewLoopLedger -RepoPath $repo
    }

    It "creates a versioned empty ledger" {
        $ledger.SchemaVersion | Should Be "2.0"
        @($ledger.Findings).Count | Should Be 0
    }

    It "creates deterministic finding ids" {
        $one = Get-ReviewLoopFindingId -Path "src\A.cs" -Component Cache -RootCause Missing -Invariant Fresh
        $two = Get-ReviewLoopFindingId -Path "src/A.cs" -Component cache -RootCause missing -Invariant fresh
        $one | Should Be $two
    }

    It "changes ids when the invariant changes" {
        $one = Get-ReviewLoopFindingId -Path A -Component C -RootCause R -Invariant I1
        $two = Get-ReviewLoopFindingId -Path A -Component C -RootCause R -Invariant I2
        $one | Should Not Be $two
    }

    It "changes ids when the cause changes" {
        $one = Get-ReviewLoopFindingId -Path A -Component C -RootCause R1 -Invariant I
        $two = Get-ReviewLoopFindingId -Path A -Component C -RootCause R2 -Invariant I
        $one | Should Not Be $two
    }

    It "merges a new finding" {
        Merge-ReviewLoopFindings -Ledger $ledger -Findings @((New-TestFinding)) -ReviewId r1 -Head h1 | Out-Null
        @($ledger.Findings).Count | Should Be 1
        $ledger.Findings[0].Status | Should Be "open"
    }

    It "deduplicates the same finding" {
        Merge-ReviewLoopFindings -Ledger $ledger -Findings @((New-TestFinding)) -ReviewId r1 -Head h1 | Out-Null
        Merge-ReviewLoopFindings -Ledger $ledger -Findings @((New-TestFinding)) -ReviewId r2 -Head h2 | Out-Null
        @($ledger.Findings).Count | Should Be 1
        $ledger.Findings[0].LastSeenReview | Should Be "r2"
    }

    It "reopens a resolved recurring finding" {
        Merge-ReviewLoopFindings -Ledger $ledger -Findings @((New-TestFinding)) -ReviewId r1 -Head h1 | Out-Null
        $ledger.Findings[0].Status = "resolved"
        $ledger.Findings[0].Verification = [pscustomobject]@{ verdict = "resolved" }
        Merge-ReviewLoopFindings -Ledger $ledger -Findings @((New-TestFinding)) -ReviewId r2 -Head h2 | Out-Null
        $ledger.Findings[0].Status | Should Be "open"
        $ledger.Findings[0].RecurrenceCount | Should Be 1
        $ledger.Findings[0].VerifiedRecurrenceCount | Should Be 1
    }

    It "reopens a recurring duplicate instead of hiding a live finding" {
        Merge-ReviewLoopFindings -Ledger $ledger -Findings @((New-TestFinding)) -ReviewId r1 -Head h1 | Out-Null
        $ledger.Findings[0].Status = "duplicate"
        Merge-ReviewLoopFindings -Ledger $ledger -Findings @((New-TestFinding)) -ReviewId r2 -Head h2 | Out-Null
        $ledger.Findings[0].Status | Should Be "open"
        $ledger.Findings[0].RecurrenceCount | Should Be 1
    }

    It "reopens a superseded finding when the reviewer reproduces it" {
        Merge-ReviewLoopFindings -Ledger $ledger -Findings @((New-TestFinding)) -ReviewId r1 -Head h1 | Out-Null
        $ledger.Findings[0].Status = "superseded"
        Merge-ReviewLoopFindings -Ledger $ledger -Findings @((New-TestFinding)) -ReviewId r2 -Head h2 | Out-Null
        $ledger.Findings[0].Status | Should Be "open"
    }

    It "persists and reads the ledger" {
        $path = Join-Path $TestDrive "ledger.json"
        Write-ReviewLoopLedger -Path $path -Ledger $ledger | Out-Null
        $read = Read-ReviewLoopLedger -Path $path
        $read.SchemaVersion | Should Be "2.0"
    }

    It "migrates a v1 ledger in memory" {
        Merge-ReviewLoopFindings -Ledger $ledger -Findings @((New-TestFinding)) `
            -ReviewId r1 -Head h1 | Out-Null
        $ledger.SchemaVersion = "1.0"
        foreach ($finding in $ledger.Findings) {
            [void]$finding.PSObject.Properties.Remove("Relations")
            [void]$finding.PSObject.Properties.Remove("IdentityHistory")
            [void]$finding.PSObject.Properties.Remove("LastBlockedHead")
        }
        $path = Join-Path $TestDrive "ledger-v1.json"
        Set-Content -LiteralPath $path -Value (
            ConvertTo-Json -InputObject $ledger -Depth 30
        ) -Encoding UTF8

        $migrated = Read-ReviewLoopLedger -Path $path

        $migrated.SchemaVersion | Should Be "2.0"
        @($migrated.Findings[0].Relations).Count | Should Be 0
        @($migrated.Findings[0].IdentityHistory).Count | Should Be 1
        $migrated.Findings[0].LastBlockedHead | Should Be ""
    }

    It "increments ledger revisions" {
        $path = Join-Path $TestDrive "ledger.json"
        Write-ReviewLoopLedger -Path $path -Ledger $ledger | Out-Null
        Write-ReviewLoopLedger -Path $path -Ledger $ledger | Out-Null
        $ledger.Revision | Should Be 2
    }

    It "creates a missing ledger when repo is supplied" {
        $read = Read-ReviewLoopLedger -Path (Join-Path $TestDrive "missing.json") -RepoPath $repo
        $read.SchemaVersion | Should Be "2.0"
    }

    It "rejects a missing ledger without repo" {
        (Test-Throws { Read-ReviewLoopLedger -Path (Join-Path $TestDrive "missing.json") }) | Should Be $true
    }

    It "records all declared fix paths" {
        Merge-ReviewLoopFindings -Ledger $ledger -Findings @((New-TestFinding -FixPaths @("src/A.cs", "tests/A.Tests.cs"))) -ReviewId r1 -Head h1 | Out-Null
        @($ledger.Findings[0].FixPaths).Count | Should Be 2
    }

    It "does not allow resolved without verification" {
        Merge-ReviewLoopFindings -Ledger $ledger -Findings @((New-TestFinding)) -ReviewId r1 -Head h1 | Out-Null
        $ledger.Findings[0].Status = "resolved"
        (Test-Throws { Write-ReviewLoopLedger -Path (Join-Path $TestDrive "ledger.json") -Ledger $ledger }) | Should Be $true
    }
}

Describe "Semantic trigger candidates" {
    BeforeEach {
        $repo = New-TestRepo (Join-Path $TestDrive ([Guid]::NewGuid().ToString("N")))
        $ledger = New-ReviewLoopLedger -RepoPath $repo
    }

    It "selects the same component" {
        Merge-ReviewLoopFindings -Ledger $ledger -Findings @(
            (New-TestFinding -Path a -Component cache -RootCause one -Invariant x),
            (New-TestFinding -Path b -Component cache -RootCause two -Invariant y)
        ) -ReviewId r -Head h | Out-Null
        @(Get-ReviewLoopTriggerCandidates -Finding $ledger.Findings[0] -Ledger $ledger).Count | Should Be 1
    }

    It "selects the same root cause" {
        Merge-ReviewLoopFindings -Ledger $ledger -Findings @(
            (New-TestFinding -Path a -Component one -RootCause shared -Invariant x),
            (New-TestFinding -Path b -Component two -RootCause shared -Invariant y)
        ) -ReviewId r -Head h | Out-Null
        @(Get-ReviewLoopTriggerCandidates -Finding $ledger.Findings[0] -Ledger $ledger).Count | Should Be 1
    }

    It "selects the same invariant" {
        Merge-ReviewLoopFindings -Ledger $ledger -Findings @(
            (New-TestFinding -Path a -Component one -RootCause x -Invariant shared),
            (New-TestFinding -Path b -Component two -RootCause y -Invariant shared)
        ) -ReviewId r -Head h | Out-Null
        @(Get-ReviewLoopTriggerCandidates -Finding $ledger.Findings[0] -Ledger $ledger).Count | Should Be 1
    }

    It "does not select the same primary path without another semantic signal" {
        Merge-ReviewLoopFindings -Ledger $ledger -Findings @(
            (New-TestFinding -Path same -Component one -RootCause x -Invariant a -FixPaths @("same")),
            (New-TestFinding -Path same -Component two -RootCause y -Invariant b -FixPaths @("same"))
        ) -ReviewId r -Head h | Out-Null
        @(Get-ReviewLoopTriggerCandidates -Finding $ledger.Findings[0] -Ledger $ledger).Count | Should Be 0
    }

    It "excludes duplicate findings" {
        Merge-ReviewLoopFindings -Ledger $ledger -Findings @(
            (New-TestFinding -Path a -Component cache -RootCause x -Invariant a),
            (New-TestFinding -Path b -Component cache -RootCause y -Invariant b)
        ) -ReviewId r -Head h | Out-Null
        $ledger.Findings[1].Status = "duplicate"
        @(Get-ReviewLoopTriggerCandidates -Finding $ledger.Findings[0] -Ledger $ledger).Count | Should Be 0
    }

    It "reports overlapping paths only as supporting evidence" {
        Merge-ReviewLoopFindings -Ledger $ledger -Findings @(
            (New-TestFinding -Path a -Component cache -RootCause x -Invariant a -FixPaths @("shared")),
            (New-TestFinding -Path b -Component cache -RootCause y -Invariant b -FixPaths @("shared"))
        ) -ReviewId r -Head h | Out-Null
        $candidate = @(Get-ReviewLoopTriggerCandidates -Finding $ledger.Findings[0] -Ledger $ledger)[0]
        $candidate.OverlappingFixPaths | Should Be $true
    }
}

Describe "Verifier evidence matching" {
    It "accepts resolved only with orchestrator-owned passing test evidence" {
        $repo = New-TestRepo (Join-Path $TestDrive ([Guid]::NewGuid().ToString("N")))
        $module = Get-Module CodexReviewLoop
        $matches = & $module {
            param($repository)
            $fixer = [pscustomobject]@{ testExecution = [pscustomobject]@{ Passed = $true } }
            $verification = [pscustomobject]@{
                verdict = "resolved"
                patchSafety = "safe"
                confidence = "high"
                regressions = @()
                evidence = @([pscustomobject]@{ path = "README.txt"; line = 1; claim = "fixed" })
            }
            Test-ReviewLoopResolvedWithTestEvidence `
                -FixerResult $fixer -VerificationResult $verification -RepoPath $repository
        } $repo

        $matches | Should Be $true
    }

    It "rejects resolved when the orchestrator-owned test failed" {
        $repo = New-TestRepo (Join-Path $TestDrive ([Guid]::NewGuid().ToString("N")))
        $module = Get-Module CodexReviewLoop
        $matches = & $module {
            param($repository)
            Test-ReviewLoopResolvedWithTestEvidence `
                -FixerResult ([pscustomobject]@{
                    testExecution = [pscustomobject]@{ Passed = $false }
                }) `
                -VerificationResult ([pscustomobject]@{
                    verdict = "resolved"
                    patchSafety = "safe"
                    confidence = "high"
                    regressions = @()
                    evidence = @([pscustomobject]@{ path = "README.txt"; line = 1; claim = "claimed" })
                }) `
                -RepoPath $repository
        } $repo

        $matches | Should Be $false
    }
}

Describe "Run state" {
    BeforeEach {
        $repo = New-TestRepo (Join-Path $TestDrive ([Guid]::NewGuid().ToString("N")))
        $runRoot = Join-Path $TestDrive "run"
        New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
        $reviewBaseCommit = & git -C $repo rev-parse HEAD
        $state = New-ReviewLoopState `
            -RepoPath $repo -ReviewBase HEAD -Speed standard -RunRoot $runRoot `
            -ReviewBaseCommit $reviewBaseCommit -ExecutionFingerprint "test-execution-fingerprint"
    }

    It "captures the branch and head" {
        $state.Branch | Should Not BeNullOrEmpty
        $state.StartHead.Length | Should Be 40
    }

    It "starts at zero clean passes" {
        $state.CleanPasses | Should Be 0
        $state.ActiveRoleCall | Should BeNullOrEmpty
    }

    It "stores the global speed" {
        $state.Speed | Should Be "standard"
    }

    It "pins the review base and execution fingerprint" {
        $state.ReviewBaseCommit | Should Be $reviewBaseCommit
        $state.ExecutionFingerprint | Should Be "test-execution-fingerprint"
    }

    It "persists and reads state" {
        $path = Join-Path $TestDrive "state.json"
        Write-ReviewLoopState -Path $path -State $state | Out-Null
        (Read-ReviewLoopState -Path $path).RunId | Should Be $state.RunId
    }

    It "retains the active cluster" {
        $state.ActiveClusterId = "C-test"
        $path = Join-Path $TestDrive "state.json"
        Write-ReviewLoopState -Path $path -State $state | Out-Null
        (Read-ReviewLoopState -Path $path).ActiveClusterId | Should Be "C-test"
    }

    It "retains fixer resume data" {
        $state.LastFixerResult = [pscustomobject]@{ ThreadId = "thread-1"; Attempt = 1 }
        $path = Join-Path $TestDrive "state.json"
        Write-ReviewLoopState -Path $path -State $state | Out-Null
        (Read-ReviewLoopState -Path $path).LastFixerResult.ThreadId | Should Be "thread-1"
    }

    It "rejects unknown state versions" {
        $state.SchemaVersion = "2.0"
        (Test-Throws { Write-ReviewLoopState -Path (Join-Path $TestDrive "state.json") -State $state }) | Should Be $true
    }

    It "provides safe default guidance for resumable and blocked failures" {
        $guidance = & (Get-Module CodexReviewLoop) {
            $exception = [System.InvalidOperationException]::new("test failure")
            [pscustomobject]@{
                Failed = @(Get-ReviewLoopFailureNextSteps -Exception $exception -Context failed)
                Blocked = @(Get-ReviewLoopFailureNextSteps -Exception $exception -Context blocked)
            }
        }

        ($guidance.Failed -join "`n") | Should Match "same command"
        ($guidance.Failed -join "`n") | Should Match "-NewRun"
        ($guidance.Blocked -join "`n") | Should Match "without blindly discarding"
        ($guidance.Blocked -join "`n") | Should Match "-NewRun"
    }
}

Describe "Fake Codex integration" {
    BeforeEach {
        $repo = New-Item -ItemType Directory -Path (Join-Path $TestDrive ([Guid]::NewGuid().ToString("N"))) -Force
        $logRoot = Join-Path $TestDrive "logs"
        $env:CODEX_REVIEW_LOOP_FAKE_LOG = Join-Path $TestDrive ("calls-{0}.jsonl" -f ([Guid]::NewGuid().ToString("N")))
        $env:CODEX_REVIEW_LOOP_FAKE_RESULT = ""
        $env:CODEX_REVIEW_LOOP_FAKE_EXIT_CODE = ""
        $env:CODEX_REVIEW_LOOP_FAKE_STDERR = ""
        $env:CODEX_REVIEW_LOOP_FAKE_THREAD = "fake-thread-123"
        $env:CODEX_REVIEW_LOOP_FAKE_EVENT_DELAY_MS = ""
        $env:CODEX_REVIEW_LOOP_FAKE_STDERR_DELAY_MS = ""
        $env:CODEX_REVIEW_LOOP_FAKE_COMMAND_EXIT_CODE = ""
        $env:CODEX_REVIEW_LOOP_FAKE_COMMAND_OUTPUT = ""
        $env:CODEX_REVIEW_LOOP_FAKE_INVOCATION_SEQUENCE = ""
        $env:CODEX_REVIEW_LOOP_FAKE_NULL_USAGE = ""
        $env:CODEX_REVIEW_LOOP_FAKE_HANG_MS = ""
        $env:CODEX_REVIEW_LOOP_FAKE_TAIL_DELAY_MS = ""
        $env:CODEX_REVIEW_LOOP_FAKE_PID_FILE = ""
    }

    AfterEach {
        Remove-Item Env:\CODEX_REVIEW_LOOP_FAKE_LOG -ErrorAction SilentlyContinue
        Remove-Item Env:\CODEX_REVIEW_LOOP_FAKE_RESULT -ErrorAction SilentlyContinue
        Remove-Item Env:\CODEX_REVIEW_LOOP_FAKE_EXIT_CODE -ErrorAction SilentlyContinue
        Remove-Item Env:\CODEX_REVIEW_LOOP_FAKE_STDERR -ErrorAction SilentlyContinue
        Remove-Item Env:\CODEX_REVIEW_LOOP_FAKE_THREAD -ErrorAction SilentlyContinue
        Remove-Item Env:\CODEX_REVIEW_LOOP_FAKE_EVENT_DELAY_MS -ErrorAction SilentlyContinue
        Remove-Item Env:\CODEX_REVIEW_LOOP_FAKE_STDERR_DELAY_MS -ErrorAction SilentlyContinue
        Remove-Item Env:\CODEX_REVIEW_LOOP_FAKE_COMMAND_EXIT_CODE -ErrorAction SilentlyContinue
        Remove-Item Env:\CODEX_REVIEW_LOOP_FAKE_COMMAND_OUTPUT -ErrorAction SilentlyContinue
        Remove-Item Env:\CODEX_REVIEW_LOOP_FAKE_INVOCATION_SEQUENCE -ErrorAction SilentlyContinue
        Remove-Item Env:\CODEX_REVIEW_LOOP_FAKE_NULL_USAGE -ErrorAction SilentlyContinue
        Remove-Item Env:\CODEX_REVIEW_LOOP_FAKE_HANG_MS -ErrorAction SilentlyContinue
        Remove-Item Env:\CODEX_REVIEW_LOOP_FAKE_TAIL_DELAY_MS -ErrorAction SilentlyContinue
        Remove-Item Env:\CODEX_REVIEW_LOOP_FAKE_PID_FILE -ErrorAction SilentlyContinue
    }

    It "runs a structured role through the CLI" {
        $call = Invoke-CodexCliRole -Role Test -RepoPath $repo.FullName -Model model -Thinking low -Prompt p -LogRoot $logRoot -SchemaPath (Join-Path $root "schemas\review-result-v1.schema.json") -CodexPath $fakeCodex
        $call.Success | Should Be $true
    }

    It "captures the thread id" {
        $call = Invoke-CodexCliRole -Role Test -RepoPath $repo.FullName -Model model -Thinking low -Prompt p -LogRoot $logRoot -CodexPath $fakeCodex
        $call.ThreadId | Should Be "fake-thread-123"
    }

    It "captures usage" {
        $call = Invoke-CodexCliRole -Role Test -RepoPath $repo.FullName -Model model -Thinking low -Prompt p -LogRoot $logRoot -CodexPath $fakeCodex
        $call.Usage.InputTokens | Should Be 100
        $call.Usage.CachedInputTokens | Should Be 80
    }

    It "separates new, cached, and output tokens in terminal usage" {
        $transcript = Join-Path $TestDrive "usage-terminal.log"
        $module = Get-Module CodexReviewLoop
        & $module {
            param($path)
            Initialize-ReviewLoopConsole -OutputMode compact -HeartbeatSeconds 0 -ColorMode Never -TranscriptPath $path
        } $transcript

        Invoke-CodexCliRole `
            -Role Test -RepoPath $repo.FullName -Model model -Thinking low `
            -Prompt p -LogRoot $logRoot -CodexPath $fakeCodex | Out-Null

        (Get-Content -Raw -LiteralPath $transcript) |
            Should Match "20 new input · 80 cached input · 20 output tokens"
    }

    It "passes the prompt over stdin" {
        Invoke-CodexCliRole -Role Test -RepoPath $repo.FullName -Model model -Thinking low -Prompt "hello prompt" -LogRoot $logRoot -CodexPath $fakeCodex | Out-Null
        $record = Get-Content -LiteralPath $env:CODEX_REVIEW_LOOP_FAKE_LOG | Select-Object -Last 1 | ConvertFrom-Json
        $record.prompt | Should Be "hello prompt"
    }

    It "passes standard to the fake CLI" {
        Invoke-CodexCliRole -Role Test -RepoPath $repo.FullName -Model model -Thinking low -Speed standard -Prompt p -LogRoot $logRoot -CodexPath $fakeCodex | Out-Null
        (Get-Content -Raw $env:CODEX_REVIEW_LOOP_FAKE_LOG) | Should Match 'service_tier=\\?"default'
    }

    It "passes fast to the fake CLI" {
        Invoke-CodexCliRole -Role Test -RepoPath $repo.FullName -Model model -Thinking low -Speed fast -Prompt p -LogRoot $logRoot -CodexPath $fakeCodex | Out-Null
        (Get-Content -Raw $env:CODEX_REVIEW_LOOP_FAKE_LOG) | Should Match 'service_tier=\\?"fast'
    }

    It "passes fast to resume calls" {
        Invoke-CodexCliRole -Role Fixer -RepoPath $repo.FullName -Model model -Thinking high -Speed fast -Prompt p -LogRoot $logRoot -Mode Resume -ThreadId thread-1 -CodexPath $fakeCodex | Out-Null
        $text = Get-Content -Raw $env:CODEX_REVIEW_LOOP_FAKE_LOG
        $text | Should Match 'resume'
        $text | Should Match 'service_tier=\\?"fast'
    }

    It "classifies fast unavailability without fallback" {
        $env:CODEX_REVIEW_LOOP_FAKE_EXIT_CODE = "1"
        $env:CODEX_REVIEW_LOOP_FAKE_STDERR = "Fast mode is not available for this model"
        $call = Invoke-CodexCliRole -Role Test -RepoPath $repo.FullName -Model model -Thinking low -Speed fast -Prompt p -LogRoot $logRoot -CodexPath $fakeCodex
        $call.Success | Should Be $false
        $call.FailureKind | Should Be "fast_unavailable"
        @($call.Attempts).Count | Should Be 1
    }

    It "classifies authentication failures" {
        $env:CODEX_REVIEW_LOOP_FAKE_EXIT_CODE = "1"
        $env:CODEX_REVIEW_LOOP_FAKE_STDERR = "Not logged in; login required"
        $call = Invoke-CodexCliRole -Role Test -RepoPath $repo.FullName -Model model -Thinking low -Prompt p -LogRoot $logRoot -CodexPath $fakeCodex
        $call.FailureKind | Should Be "authentication"
    }

    It "fails invalid structured output" {
        $env:CODEX_REVIEW_LOOP_FAKE_RESULT = "not json"
        $call = Invoke-CodexCliRole -Role Test -RepoPath $repo.FullName -Model model -Thinking low -Prompt p -LogRoot $logRoot -SchemaPath (Join-Path $root "schemas\review-result-v1.schema.json") -CodexPath $fakeCodex
        $call.Success | Should Be $false
        $call.FailureKind | Should Be "invalid_structured_output"
    }

    It "writes JSONL and result logs" {
        $call = Invoke-CodexCliRole -Role Test -RepoPath $repo.FullName -Model model -Thinking low -Prompt p -LogRoot $logRoot -CodexPath $fakeCodex
        Test-Path $call.JsonlPath | Should Be $true
        Test-Path $call.ResultPath | Should Be $true
    }
}

Describe "Live terminal and streaming process observation" {
    BeforeEach {
        $repo = New-TestRepo (Join-Path $TestDrive ([Guid]::NewGuid().ToString("N")))
        $caseRoot = Join-Path $TestDrive ([Guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $caseRoot | Out-Null
        $logRoot = Join-Path $caseRoot "logs"
        $env:CODEX_REVIEW_LOOP_FAKE_LOG = Join-Path $caseRoot "calls.jsonl"
        $env:CODEX_REVIEW_LOOP_FAKE_RESULT = ""
        $env:CODEX_REVIEW_LOOP_FAKE_EXIT_CODE = ""
        $env:CODEX_REVIEW_LOOP_FAKE_STDERR = ""
        $env:CODEX_REVIEW_LOOP_FAKE_EVENT_DELAY_MS = ""
        $env:CODEX_REVIEW_LOOP_FAKE_STDERR_DELAY_MS = ""
        $env:CODEX_REVIEW_LOOP_FAKE_COMMAND_EXIT_CODE = ""
        $env:CODEX_REVIEW_LOOP_FAKE_COMMAND_OUTPUT = ""
        $env:CODEX_REVIEW_LOOP_FAKE_INVOCATION_SEQUENCE = ""
        $env:CODEX_REVIEW_LOOP_FAKE_NULL_USAGE = ""
        $env:CODEX_REVIEW_LOOP_FAKE_HANG_MS = ""
        $env:CODEX_REVIEW_LOOP_FAKE_TAIL_DELAY_MS = ""
        $env:CODEX_REVIEW_LOOP_FAKE_PID_FILE = ""
    }

    AfterEach {
        @(
            "CODEX_REVIEW_LOOP_FAKE_LOG",
            "CODEX_REVIEW_LOOP_FAKE_RESULT",
            "CODEX_REVIEW_LOOP_FAKE_EXIT_CODE",
            "CODEX_REVIEW_LOOP_FAKE_STDERR",
            "CODEX_REVIEW_LOOP_FAKE_EVENT_DELAY_MS",
            "CODEX_REVIEW_LOOP_FAKE_STDERR_DELAY_MS",
            "CODEX_REVIEW_LOOP_FAKE_COMMAND_EXIT_CODE",
            "CODEX_REVIEW_LOOP_FAKE_COMMAND_OUTPUT",
            "CODEX_REVIEW_LOOP_FAKE_INVOCATION_SEQUENCE",
            "CODEX_REVIEW_LOOP_FAKE_NULL_USAGE",
            "CODEX_REVIEW_LOOP_FAKE_HANG_MS",
            "CODEX_REVIEW_LOOP_FAKE_TAIL_DELAY_MS",
            "CODEX_REVIEW_LOOP_FAKE_PID_FILE"
        ) | ForEach-Object { Remove-Item "Env:\$_" -ErrorAction SilentlyContinue }
    }

    It "grows JSONL while the Codex process is still running" {
        $env:CODEX_REVIEW_LOOP_FAKE_EVENT_DELAY_MS = "2500"
        $job = Start-Job -ScriptBlock {
            param($importPath, $repoPath, $logs, $fake)
            Import-Module $importPath -Force
            Invoke-CodexCliRole `
                -Role Test -RepoPath $repoPath -Model model -Thinking low `
                -Prompt p -LogRoot $logs -CodexPath $fake -CallId "stream-live"
        } -ArgumentList $modulePath, $repo, $logRoot, $fakeCodex
        try {
            $jsonlPath = Join-Path $logRoot "stream-live-test.jsonl"
            $deadline = [DateTime]::UtcNow.AddSeconds(8)
            while ([DateTime]::UtcNow -lt $deadline -and
                (-not (Test-Path -LiteralPath $jsonlPath) -or
                 (Get-Item -LiteralPath $jsonlPath -ErrorAction SilentlyContinue).Length -eq 0)) {
                Start-Sleep -Milliseconds 100
            }
            Test-Path -LiteralPath $jsonlPath | Should Be $true
            (Get-Content -Raw -LiteralPath $jsonlPath) | Should Match "thread.started"
            $job.State | Should Be "Running"
            Wait-Job -Job $job -Timeout 15 | Out-Null
            $job.State | Should Be "Completed"
            Receive-Job -Job $job | Out-Null
        }
        finally {
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        }
    }

    It "checkpoints a role thread before the Codex process finishes" {
        $env:CODEX_REVIEW_LOOP_FAKE_EVENT_DELAY_MS = "2500"
        $configPath = New-TestConfig -Path (Join-Path $caseRoot "checkpoint.psd1") -LogRoot $logRoot
        $statePath = Join-Path $logRoot "run-v1.json"
        $job = Start-Job -ScriptBlock {
            param($importPath, $profilePath, $repoPath, $logs, $checkpointPath, $fake)
            Import-Module $importPath -Force
            $config = Import-PowerShellDataFile -LiteralPath $profilePath
            $config["__ExecutionFingerprint"] = "checkpoint-fingerprint"
            $head = & git -C $repoPath rev-parse HEAD
            $state = New-ReviewLoopState -RepoPath $repoPath -ReviewBase HEAD -Speed standard `
                -RunRoot $logs -ReviewBaseCommit $head -ExecutionFingerprint "checkpoint-fingerprint"
            $state.Stage = "reviewing"
            Write-ReviewLoopState -Path $checkpointPath -State $state | Out-Null
            & (Get-Module CodexReviewLoop) {
                param($profile, $loopState, $loopStatePath, $repository, $runRoot, $fakePath)
                Invoke-ConfiguredCodexRole -Config $profile -Role Reviewer -RepoPath $repository `
                    -Speed standard -Prompt review -LogRoot $runRoot `
                    -SchemaName "review-result-v1.schema.json" -CallId "review-01" `
                    -State $loopState -StatePath $loopStatePath -CodexPath $fakePath
            } $config $state $checkpointPath $repoPath $logs $fake | Out-Null
        } -ArgumentList $modulePath, $configPath, $repo, $logRoot, $statePath, $fakeCodex
        try {
            $deadline = [DateTime]::UtcNow.AddSeconds(8)
            $checkpoint = $null
            while ([DateTime]::UtcNow -lt $deadline) {
                if (Test-Path -LiteralPath $statePath) {
                    try {
                        $checkpoint = Read-ReviewLoopState -Path $statePath
                        if (-not [string]::IsNullOrWhiteSpace(
                                [string]$checkpoint.ActiveRoleCall.ThreadId)) {
                            break
                        }
                    }
                    catch {
                        $checkpoint = $null
                    }
                }
                Start-Sleep -Milliseconds 100
            }
            $checkpoint.ActiveRoleCall.CallId | Should Be "review-01"
            $checkpoint.ActiveRoleCall.ThreadId | Should Be "fake-thread-001"
            $job.State | Should Be "Running"
            Wait-Job -Job $job -Timeout 15 | Out-Null
            $job.State | Should Be "Completed"
            Receive-Job -Job $job | Out-Null
            $completed = Read-ReviewLoopState -Path $statePath
            $completed.ActiveRoleCall | Should BeNullOrEmpty
            @($completed.RoleCalls).Count | Should Be 1
        }
        finally {
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        }
    }

    It "writes a heartbeat for a long-running role" {
        $transcript = Join-Path $caseRoot "terminal.log"
        $env:CODEX_REVIEW_LOOP_FAKE_EVENT_DELAY_MS = "1700"
        $env:CODEX_REVIEW_LOOP_FAKE_COMMAND_EXIT_CODE = "0"
        $module = Get-Module CodexReviewLoop
        & $module {
            param($path)
            Initialize-ReviewLoopConsole -OutputMode compact -HeartbeatSeconds 1 -ColorMode Never -TranscriptPath $path
        } $transcript

        Invoke-CodexCliRole `
            -Role Reviewer -RepoPath $repo -Model model -Thinking high `
            -Prompt p -LogRoot $logRoot -CodexPath $fakeCodex | Out-Null

        $text = Get-Content -Raw -LiteralPath $transcript
        $text | Should Match "Reviewer running for 00:01"
        $text | Should Match "1 CLI actions"
        $text | Should Match "last activity"
    }

    It "rewrites consecutive heartbeats on one terminal line" {
        $transcript = Join-Path $caseRoot "inline-heartbeats.log"
        $module = Get-Module CodexReviewLoop
        $rendered = & $module {
            param($path)
            Initialize-ReviewLoopConsole -OutputMode compact -HeartbeatSeconds 30 -ColorMode Never -TranscriptPath $path
            Write-ReviewLoopStatus -Message "Reviewer running for 00:30" -Kind Progress -Inline
            $activeAfterFirst = [bool]$script:ReviewLoopConsole.InlineActive
            Write-ReviewLoopStatus -Message "Reviewer running for 01:00" -Kind Progress -Inline
            Write-ReviewLoopStatus -Message "Reviewer completed" -Kind Success
            "$activeAfterFirst|$([bool]$script:ReviewLoopConsole.InlineActive)"
        } $transcript 6>&1

        $rendered[0].ToString().StartsWith("`r") | Should Be $true
        $rendered[1].ToString().StartsWith("`r") | Should Be $true
        ($rendered | ForEach-Object { $_.ToString() }) -contains "True|False" | Should Be $true
        $text = Get-Content -Raw -LiteralPath $transcript
        $text | Should Match "Reviewer running for 00:30"
        $text | Should Match "Reviewer running for 01:00"
        $text | Should Match "Reviewer completed"
    }

    It "formats elapsed time without rounding into future minutes or hours" {
        $module = Get-Module CodexReviewLoop
        $formatted = & $module {
            @(
                Format-ReviewLoopDuration -Duration ([TimeSpan]::FromSeconds(30))
                Format-ReviewLoopDuration -Duration ([TimeSpan]::FromSeconds(90))
                Format-ReviewLoopDuration -Duration ([TimeSpan]::new(0, 1, 30, 5))
            )
        }

        $formatted[0] | Should Be "00:30"
        $formatted[1] | Should Be "01:30"
        $formatted[2] | Should Be "01:30:05"
    }

    It "hides skill-description context compression in compact mode" {
        $transcript = Join-Path $caseRoot "context-warning.log"
        $module = Get-Module CodexReviewLoop
        & $module {
            param($path)
            Initialize-ReviewLoopConsole -OutputMode compact -HeartbeatSeconds 0 -ColorMode Never -TranscriptPath $path
            $activity = [pscustomobject]@{
                ActionCount = 0
                ThreadId = ""
            }
            $event = [pscustomobject]@{
                type = "item.completed"
                item = [pscustomobject]@{
                    type = "error"
                    message = "Skill descriptions were shortened to fit the 2% skills context budget."
                }
            } | ConvertTo-Json -Depth 5 -Compress
            Update-ReviewLoopCodexActivity -Line $event -Activity $activity
        } $transcript

        $text = Get-Content -Raw -LiteralPath $transcript
        $text | Should Not Match "Skill descriptions were shortened"
    }

    It "shows dropped app-server events as a warning" {
        $transcript = Join-Path $caseRoot "event-lag-warning.log"
        $module = Get-Module CodexReviewLoop
        & $module {
            param($path)
            Initialize-ReviewLoopConsole -OutputMode compact -HeartbeatSeconds 0 -ColorMode Never -TranscriptPath $path
            $activity = [pscustomobject]@{ ActionCount = 0; ThreadId = "" }
            $event = [pscustomobject]@{
                type = "item.completed"
                item = [pscustomobject]@{
                    type = "error"
                    message = "in-process app-server event stream lagged; dropped 390 events"
                }
            } | ConvertTo-Json -Depth 5 -Compress
            Update-ReviewLoopCodexActivity -Line $event -Activity $activity
        } $transcript

        $text = Get-Content -Raw -LiteralPath $transcript
        $text | Should Match "\[!\] in-process app-server event stream lagged"
        $text | Should Not Match "\[X\] in-process app-server event stream lagged"
    }

    It "keeps the cause and tail of long failure output" {
        $module = Get-Module CodexReviewLoop
        $excerpt = & $module {
            Get-ReviewLoopTextExcerpt `
                -Text ("root cause`nframe 1`nframe 2`nframe 3`nframe 4`nfinal frame") `
                -MaxLines 4
        }

        $excerpt[0] | Should Be "root cause"
        ($excerpt -join "`n") | Should Match "line\(s\) omitted"
        $excerpt[-1] | Should Be "final frame"
    }

    It "hides internal command results in compact and shows failures in balanced output" {
        $module = Get-Module CodexReviewLoop
        $successTranscript = Join-Path $caseRoot "compact-success.log"
        & $module {
            param($path)
            Initialize-ReviewLoopConsole -OutputMode compact -HeartbeatSeconds 0 -ColorMode Never -TranscriptPath $path
        } $successTranscript
        $env:CODEX_REVIEW_LOOP_FAKE_COMMAND_EXIT_CODE = "0"
        Invoke-CodexCliRole `
            -Role Test -RepoPath $repo -Model model -Thinking low `
            -Prompt p -LogRoot $logRoot -CodexPath $fakeCodex -CallId success | Out-Null
        (Get-Content -Raw -LiteralPath $successTranscript) | Should Not Match "Get-Location"

        $failureTranscript = Join-Path $caseRoot "compact-failure.log"
        & $module {
            param($path)
            Initialize-ReviewLoopConsole -OutputMode compact -HeartbeatSeconds 0 -ColorMode Never -TranscriptPath $path
        } $failureTranscript
        $env:CODEX_REVIEW_LOOP_FAKE_COMMAND_EXIT_CODE = "7"
        $call = Invoke-CodexCliRole `
            -Role Test -RepoPath $repo -Model model -Thinking low `
            -Prompt p -LogRoot $logRoot -CodexPath $fakeCodex -CallId failure -MaxAttempts 1
        $call.Success | Should Be $true
        @($call.Attempts).Count | Should Be 1
        $failureText = Get-Content -Raw -LiteralPath $failureTranscript
        $failureText | Should Not Match "Agent command failed"
        $failureText | Should Not Match "exit code 7"

        $balancedTranscript = Join-Path $caseRoot "balanced-failure.log"
        & $module {
            param($path)
            Initialize-ReviewLoopConsole -OutputMode balanced -HeartbeatSeconds 0 -ColorMode Never -TranscriptPath $path
        } $balancedTranscript
        Invoke-CodexCliRole `
            -Role Test -RepoPath $repo -Model model -Thinking low `
            -Prompt p -LogRoot $logRoot -CodexPath $fakeCodex -CallId balanced-failure -MaxAttempts 1 | Out-Null
        $balancedText = Get-Content -Raw -LiteralPath $balancedTranscript
        $balancedText | Should Match "Agent command failed; role continues"
        $balancedText | Should Match "exit code 7"
    }

    It "keeps terminal.log ANSI-free and applies the requested color style" {
        $transcript = Join-Path $caseRoot "colors.log"
        $module = Get-Module CodexReviewLoop
        $rendered = & $module {
            param($path)
            Initialize-ReviewLoopConsole -OutputMode compact -HeartbeatSeconds 0 -ColorMode Ansi -TranscriptPath $path
            Write-ReviewLoopStatus -Message "passed" -Kind Success
            $style = Get-ReviewLoopConsoleStyle -Kind Success
            "$(Test-ReviewLoopUseAnsi)|$($style.Color)|$($style.Ansi)"
        } $transcript 6>&1

        ($rendered | Out-String) | Should Match "True\|Green\|32"
        $plain = Get-Content -Raw -LiteralPath $transcript
        $plain | Should Match "\[OK\] passed"
        $plain | Should Not Match ([regex]::Escape("`e["))
    }

    It "redacts secrets before stderr and terminal logs are written" {
        $secret = "test-secret-value-1234567890"
        $transcript = Join-Path $caseRoot "redacted-terminal.log"
        $module = Get-Module CodexReviewLoop
        & $module {
            param($path)
            Initialize-ReviewLoopConsole -OutputMode compact -HeartbeatSeconds 0 -ColorMode Never -TranscriptPath $path
        } $transcript
        $env:CODEX_REVIEW_LOOP_FAKE_EXIT_CODE = "1"
        $env:CODEX_REVIEW_LOOP_FAKE_STDERR = "authorization=$secret"
        $call = Invoke-CodexCliRole `
            -Role Test -RepoPath $repo -Model model -Thinking low `
            -Prompt p -LogRoot $logRoot -CodexPath $fakeCodex -CallId redacted -MaxAttempts 1

        $call.Success | Should Be $false
        (Get-Content -Raw -LiteralPath $call.JsonlPath) | Should Not Match $secret
        (Get-Content -Raw -LiteralPath (Join-Path $logRoot "redacted-test.stderr.txt")) | Should Not Match $secret
        (Get-Content -Raw -LiteralPath $transcript) | Should Not Match $secret
        (Get-Content -Raw -LiteralPath $transcript) | Should Match "\[redacted"
    }

    It "kills the child process when observation is stopped and preserves the checkpoint" {
        $env:CODEX_REVIEW_LOOP_FAKE_TAIL_DELAY_MS = "30000"
        $pidFile = Join-Path $caseRoot "child.pid"
        $env:CODEX_REVIEW_LOOP_FAKE_PID_FILE = $pidFile
        $runRoot = Join-Path $caseRoot "run"
        New-Item -ItemType Directory -Path $runRoot | Out-Null
        $statePath = Join-Path $runRoot "run-v1.json"
        $state = New-ReviewLoopState -RepoPath $repo -ReviewBase HEAD -Speed standard -RunRoot $runRoot
        Write-ReviewLoopState -Path $statePath -State $state | Out-Null

        $powerShell = [PowerShell]::Create()
        $scriptText = @"
Import-Module '$($modulePath.Replace("'", "''"))' -Force
Invoke-CodexCliRole -Role Test -RepoPath '$($repo.Replace("'", "''"))' -Model model -Thinking low -Prompt p -LogRoot '$($logRoot.Replace("'", "''"))' -CodexPath '$($fakeCodex.Replace("'", "''"))' -CallId interrupt | Out-Null
"@
        [void]$powerShell.AddScript($scriptText)
        $async = $powerShell.BeginInvoke()
        try {
            $deadline = [DateTime]::UtcNow.AddSeconds(8)
            while (-not (Test-Path -LiteralPath $pidFile) -and [DateTime]::UtcNow -lt $deadline) {
                Start-Sleep -Milliseconds 100
            }
            Test-Path -LiteralPath $pidFile | Should Be $true
            $childPid = [int](Get-Content -Raw -LiteralPath $pidFile)
            Get-Process -Id $childPid -ErrorAction Stop | Should Not BeNullOrEmpty

            $powerShell.Stop()
            $deadline = [DateTime]::UtcNow.AddSeconds(8)
            while ($null -ne (Get-Process -Id $childPid -ErrorAction SilentlyContinue) -and
                [DateTime]::UtcNow -lt $deadline) {
                Start-Sleep -Milliseconds 100
            }
            Get-Process -Id $childPid -ErrorAction SilentlyContinue | Should BeNullOrEmpty
            { Read-ReviewLoopState -Path $statePath } | Should Not Throw
        }
        finally {
            if (-not $async.IsCompleted) {
                $powerShell.Stop()
            }
            $powerShell.Dispose()
        }
    }
}

Describe "Schemas, prompts, and CLI-only invariants" {
    It "parses every JSON schema" {
        $schemas = Get-ChildItem -LiteralPath (Join-Path $root "schemas") -Filter "*.json"
        foreach ($schema in $schemas) {
            { Get-Content -Raw $schema.FullName | ConvertFrom-Json } | Should Not Throw
        }
    }

    It "uses closed object schemas" {
        $schemas = Get-ChildItem -LiteralPath (Join-Path $root "schemas") -Filter "*.json"
        foreach ($schema in $schemas) {
            (Get-Content -Raw $schema.FullName) | Should Match '"additionalProperties"\s*:\s*false'
        }
    }

    It "uses only Codex-compatible array uniqueness constraints" {
        $schemas = Get-ChildItem -LiteralPath (Join-Path $root "schemas") -Filter "*.json"
        foreach ($schema in $schemas) {
            (Get-Content -Raw $schema.FullName) | Should Not Match '"uniqueItems"\s*:'
        }
    }

    It "contains every production prompt" {
        @("trigger-judge.md", "architect.md", "architecture-critic.md", "fixer.md", "verifier.md") |
            ForEach-Object { Test-Path (Join-Path $root "prompts\$_") | Should Be $true }
    }

    It "replaces only placeholders from the original prompt template" {
        $values = @{
            FINDINGS = 'Finding contains {{DIFF}}.'
            FIXER_RESULT = 'Generated code contains {{heading}}.'
        }
        $rendered = & (Get-Module CodexReviewLoop) {
            param($promptValues)
            Get-ReviewLoopPrompt -Name "verifier.md" -Values $promptValues
        } $values

        $rendered | Should Match ([regex]::Escape("Finding contains {{DIFF}}."))
        $rendered | Should Match ([regex]::Escape("Generated code contains {{heading}}."))
    }

    It "reports missing original prompt placeholders by name" {
        $message = ""
        try {
            & (Get-Module CodexReviewLoop) {
                Get-ReviewLoopPrompt -Name "verifier.md" -Values @{
                    FINDINGS = "findings"
                }
            } | Out-Null
        }
        catch {
            $message = $_.Exception.Message
        }

        $message | Should Match "missing values"
        $message | Should Match "FIXER_RESULT"
    }

    It "keeps analysis commands narrow and reserves full gates for the orchestrator" {
        $roles = Get-Content -Raw -LiteralPath (Join-Path $root "src\Roles.ps1")
        $roles | Should Match 'authoritative and owned by the orchestrator'
        $roles | Should Match 'do not run a full repository or solution test suite'
        $roles | Should Match 'must not edit repository files'
        $roles | Should Match 'Preserve tracked and untracked repository state'
    }

    It "uses the orchestrator-owned verifier test result" {
        $verifier = Get-Content -Raw -LiteralPath (Join-Path $root "prompts\verifier.md")
        $verifier | Should Match 'orchestrator supplies the independently executed targeted-test result'
    }

    It "keeps fixer tests targeted while retaining independent orchestration" {
        $fixer = Get-Content -Raw -LiteralPath (Join-Path $root "prompts\fixer.md")
        $fixer | Should Match 'narrowest useful project or filtered regression tests'
        $fixer | Should Match 'Do not run the configured full repository host gates'
        $fixer | Should Match 'exactly one structured `targetedTest`'
        $fixer | Should Match 'independent execution by the orchestrator'
    }

    It "has no direct HTTP model invocation in active code" {
        $active = Get-ChildItem -Recurse -File -LiteralPath $root |
            Where-Object { $_.FullName -notmatch '\\archive\\|\\tests\\|\\eval-results\\|\\runs\\|\\profiles\\|\\.git\\' }
        $text = ($active | ForEach-Object { Get-Content -Raw $_.FullName }) -join "`n"
        $text | Should Not Match 'Invoke-WebRequest|Invoke-RestMethod|/v1/responses'
    }

    It "has no direct API credential dependency in active code" {
        $active = Get-ChildItem -Recurse -File -LiteralPath $root |
            Where-Object { $_.FullName -notmatch '\\archive\\|\\tests\\|\\eval-results\\|\\runs\\|\\profiles\\|\\.git\\' }
        $text = ($active | ForEach-Object { Get-Content -Raw $_.FullName }) -join "`n"
        $credentialName = "OPENAI" + "_API_KEY"
        $text | Should Not Match $credentialName
    }

    It "does not retain legacy architecture switches" {
        $active = Get-ChildItem -Recurse -File -LiteralPath $root |
            Where-Object { $_.FullName -notmatch '\\archive\\|\\tests\\|\\eval-results\\|\\runs\\|\\profiles\\|\\.git\\' }
        $text = ($active | ForEach-Object { Get-Content -Raw $_.FullName }) -join "`n"
        $text | Should Not Match 'ArchitectureAutoApplyAll|InteractiveArchitectureGate|ArchitectureHotspot'
    }

    It "has no active PKonf-specific coupling" {
        $active = Get-ChildItem -Recurse -File -LiteralPath $root |
            Where-Object { $_.FullName -notmatch '\\archive\\|\\tests\\|\\eval-results\\|\\runs\\|\\profiles\\|\\.git\\' }
        $text = ($active | ForEach-Object { Get-Content -Raw $_.FullName }) -join "`n"
        $text | Should Not Match '(?i)\bPKonf\b'
    }

}

Describe "End-to-end orchestration with fake Codex" {
    BeforeEach {
        $repo = New-TestRepo (Join-Path $TestDrive ([Guid]::NewGuid().ToString("N")))
        $caseRoot = Join-Path $TestDrive ([Guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $caseRoot | Out-Null
        $configPath = New-TestConfig -Path (Join-Path $caseRoot "profile.psd1") -LogRoot (Join-Path $caseRoot "logs")
        $env:CODEX_REVIEW_LOOP_FAKE_LOG = Join-Path $caseRoot "calls.jsonl"
        $env:CODEX_REVIEW_LOOP_FAKE_RESULT_SEQUENCE = Join-Path $caseRoot "results.json"
        $env:CODEX_REVIEW_LOOP_FAKE_THREAD = "cluster-thread"
        $env:CODEX_REVIEW_LOOP_FAKE_RESULT = ""
        $env:CODEX_REVIEW_LOOP_FAKE_EXIT_CODE = ""
        $env:CODEX_REVIEW_LOOP_FAKE_STDERR = ""
        $env:CODEX_REVIEW_LOOP_FAKE_MUTATE_ON_SCHEMA = ""
        $env:CODEX_REVIEW_LOOP_FAKE_INVOCATION_SEQUENCE = ""
        $env:CODEX_REVIEW_LOOP_FAKE_NULL_USAGE = ""
        $env:CODEX_REVIEW_LOOP_FAKE_HANG_MS = ""
    }

    AfterEach {
        @(
            "CODEX_REVIEW_LOOP_FAKE_LOG",
            "CODEX_REVIEW_LOOP_FAKE_RESULT_SEQUENCE",
            "CODEX_REVIEW_LOOP_FAKE_THREAD",
            "CODEX_REVIEW_LOOP_FAKE_RESULT",
            "CODEX_REVIEW_LOOP_FAKE_EXIT_CODE",
            "CODEX_REVIEW_LOOP_FAKE_STDERR",
            "CODEX_REVIEW_LOOP_FAKE_MUTATE_ON_SCHEMA"
            "CODEX_REVIEW_LOOP_FAKE_INVOCATION_SEQUENCE"
            "CODEX_REVIEW_LOOP_FAKE_NULL_USAGE"
            "CODEX_REVIEW_LOOP_FAKE_HANG_MS"
        ) | ForEach-Object { Remove-Item "Env:\$_" -ErrorAction SilentlyContinue }
    }

    It "rejects an unavailable host gate before starting a reviewer" {
        $configPath = New-TestConfig `
            -Path $configPath -LogRoot (Join-Path $caseRoot "logs") -WithHostGate
        $missingExecutable = "missing-review-loop-host-gate-$([Guid]::NewGuid().ToString('N')).exe"
        $content = (Get-Content -Raw -LiteralPath $configPath).Replace(
            'FilePath = "pwsh"',
            "FilePath = `"$missingExecutable`"")
        Set-Content -LiteralPath $configPath -Value $content -Encoding UTF8

        $result = Invoke-CodexReviewLoop `
            -RepoPath $repo -ConfigPath $configPath -Speed standard `
            -CodexPath $fakeCodex -NewRun -ColorMode Never

        $result.Status | Should Be "failed"
        $result.Reason | Should Match "Host gate"
        ($result.NextSteps -join "`n") | Should Match "FilePath"
        ($result.NextSteps -join "`n") | Should Match "same command"
        Test-Path -LiteralPath $env:CODEX_REVIEW_LOOP_FAKE_LOG | Should Be $false
    }

    It "explains how to resolve a resumed speed mismatch" {
        New-TestActiveCheckpoint `
            -RepoPath $repo `
            -ConfigPath $configPath `
            -Speed fast | Out-Null

        $result = Invoke-CodexReviewLoop `
            -RepoPath $repo `
            -ConfigPath $configPath `
            -Speed standard `
            -CodexPath $fakeCodex `
            -HeartbeatSeconds 0 `
            -ColorMode Never

        $result.Status | Should Be "failed"
        $result.Reason | Should Match "cannot change speed"
        ($result.NextSteps -join "`n") | Should Match "-Speed fast"
        ($result.NextSteps -join "`n") | Should Match "-Speed standard -NewRun"
        Test-Path -LiteralPath $env:CODEX_REVIEW_LOOP_FAKE_LOG | Should Be $false
    }

    It "keeps an immediate compact failure short and non-duplicative" {
        New-TestActiveCheckpoint `
            -RepoPath $repo `
            -ConfigPath $configPath `
            -Speed fast | Out-Null
        $entryPoint = Join-Path $root "codex-review-loop.ps1"
        $output = & pwsh -NoLogo -NoProfile -NonInteractive `
            -File $entryPoint `
            -RepoPath $repo `
            -ConfigPath $configPath `
            -Speed standard `
            -CodexPath $fakeCodex `
            -HeartbeatSeconds 0 `
            -ColorMode Never 2>&1
        $exitCode = $LASTEXITCODE
        $text = $output -join "`n"
        $lines = @($output | Where-Object {
            -not [string]::IsNullOrWhiteSpace([string]$_)
        })

        $exitCode | Should Be 2
        $lines.Count | Should Not BeGreaterThan 8
        [regex]::Matches($text, "cannot change speed").Count | Should Be 1
        $text | Should Match "Recommended"
        $text | Should Match "Alternative"
        $text | Should Not Match "Repository:|Checkpoint:|Ledger:|`"Status`"\s*:"
    }

    It "emits only one JSON result for an immediate runtime failure" {
        New-TestActiveCheckpoint `
            -RepoPath $repo `
            -ConfigPath $configPath `
            -Speed fast | Out-Null
        $entryPoint = Join-Path $root "codex-review-loop.ps1"
        $output = & pwsh -NoLogo -NoProfile -NonInteractive `
            -File $entryPoint `
            -RepoPath $repo `
            -ConfigPath $configPath `
            -Speed standard `
            -CodexPath $fakeCodex `
            -HeartbeatSeconds 0 `
            -ColorMode Never `
            -Json 2>&1
        $exitCode = $LASTEXITCODE
        $text = $output -join "`n"
        $result = $text | ConvertFrom-Json

        $exitCode | Should Be 2
        $result.Status | Should Be "failed"
        $result.Reason | Should Match "cannot change speed"
        ($result.NextSteps -join "`n") | Should Match "-Speed fast"
        $text | Should Not Match "\[X\]|\[!\]|Codex Review Loop"
    }

    It "gives a concrete compact recovery command for a dirty legacy blocked checkpoint" {
        $checkpoint = New-TestActiveCheckpoint `
            -RepoPath $repo `
            -ConfigPath $configPath `
            -Speed standard
        $state = Read-ReviewLoopState -Path $checkpoint.StatePath
        $state.Status = "failed"
        $state.ExitCode = 2
        $state.Stage = "cluster_blocked"
        Write-ReviewLoopState -Path $checkpoint.StatePath -State $state | Out-Null
        Set-Content -LiteralPath (Join-Path $repo "legacy-fixer.txt") -Value "unverified"
        $entryPoint = Join-Path $root "codex-review-loop.ps1"

        $output = & pwsh -NoLogo -NoProfile -NonInteractive `
            -File $entryPoint `
            -RepoPath $repo `
            -ConfigPath $configPath `
            -Speed standard `
            -CodexPath $fakeCodex `
            -HeartbeatSeconds 0 `
            -ColorMode Never 2>&1
        $exitCode = $LASTEXITCODE
        $text = $output -join "`n"

        $exitCode | Should Be 2
        $text | Should Match "legacy checkpoint"
        $text | Should Match "1 file"
        $text | Should Match "stash push -u"
        $text | Should Match "-NewRun"
        $text | Should Not Match "Repository:|Checkpoint:|Ledger:|`"Status`"\s*:"
    }

    It "explains both safe choices when HEAD moved after a checkpoint" {
        $checkpoint = New-TestActiveCheckpoint `
            -RepoPath $repo `
            -ConfigPath $configPath `
            -Speed standard
        Set-Content -LiteralPath (Join-Path $repo "external.txt") -Value "intentional"
        & git -C $repo add external.txt
        & git -C $repo commit -q -m "external change"

        $result = Invoke-CodexReviewLoop `
            -RepoPath $repo `
            -ConfigPath $configPath `
            -Speed standard `
            -CodexPath $fakeCodex `
            -HeartbeatSeconds 0 `
            -ColorMode Never

        $result.Status | Should Be "failed"
        $result.Reason | Should Match "repository moved after the checkpoint"
        ($result.NextSteps -join "`n") | Should Match "-NewRun"
        ($result.NextSteps -join "`n") | Should Match ([regex]::Escape(
            (Read-ReviewLoopState -Path $checkpoint.StatePath).CurrentHead
        ))
        (Get-Content -Raw -LiteralPath (Join-Path $checkpoint.RunRoot "terminal.log")) |
            Should Match "Recommended"
        Test-Path -LiteralPath $env:CODEX_REVIEW_LOOP_FAKE_LOG | Should Be $false
    }

    It "completes after two clean reviews on unchanged HEAD" {
        Write-FakeResultSequence -Path $env:CODEX_REVIEW_LOOP_FAKE_RESULT_SEQUENCE -Results @(
            '{"schemaVersion":"1.0","classification":"clean","summary":"clean","findings":[]}',
            '{"schemaVersion":"1.0","classification":"clean","summary":"clean","findings":[]}'
        )
        $result = Invoke-CodexReviewLoop -RepoPath $repo -ConfigPath $configPath -Speed standard -CodexPath $fakeCodex -NewRun
        $result.Status | Should Be "completed"
        $result.CleanPasses | Should Be 2
        $result.ReviewCycles | Should Be 2
        $terminal = Get-Content -Raw -LiteralPath (Join-Path $result.RunRoot "terminal.log")
        $terminal | Should Match "Review cycle 1/6"
        $terminal | Should Match "Reviewer"
        $terminal | Should Match "Clean pass 2/2"
        $terminal | Should Match "Review Loop completed"
    }

    It "emits one JSON document and no human dashboard when requested" {
        Write-FakeResultSequence -Path $env:CODEX_REVIEW_LOOP_FAKE_RESULT_SEQUENCE -Results @(
            '{"schemaVersion":"1.0","classification":"clean","summary":"clean","findings":[]}',
            '{"schemaVersion":"1.0","classification":"clean","summary":"clean","findings":[]}'
        )
        $entryPoint = Join-Path $root "codex-review-loop.ps1"
        $output = & pwsh -NoLogo -NoProfile -NonInteractive `
            -File $entryPoint `
            -RepoPath $repo `
            -ConfigPath $configPath `
            -Speed standard `
            -CodexPath $fakeCodex `
            -NewRun `
            -HeartbeatSeconds 0 `
            -ColorMode Never `
            -Json 2>&1
        $exitCode = $LASTEXITCODE
        $text = $output -join "`n"
        $result = $text | ConvertFrom-Json

        $exitCode | Should Be 0
        $result.Status | Should Be "completed"
        $result.CleanPasses | Should Be 2
        @($result.NextSteps).Count | Should Be 0
        $text | Should Not Match "\[OK\]|\[\.\.\]|Codex Review Loop"
        (Get-Content -Raw -LiteralPath (Join-Path $result.RunRoot "terminal.log")) |
            Should Match "Review Loop completed"
    }

    It "does not append JSON to normal human output" {
        Write-FakeResultSequence -Path $env:CODEX_REVIEW_LOOP_FAKE_RESULT_SEQUENCE -Results @(
            '{"schemaVersion":"1.0","classification":"clean","summary":"clean","findings":[]}',
            '{"schemaVersion":"1.0","classification":"clean","summary":"clean","findings":[]}'
        )
        $entryPoint = Join-Path $root "codex-review-loop.ps1"
        $output = & pwsh -NoLogo -NoProfile -NonInteractive `
            -File $entryPoint `
            -RepoPath $repo `
            -ConfigPath $configPath `
            -Speed standard `
            -CodexPath $fakeCodex `
            -NewRun `
            -HeartbeatSeconds 0 `
            -ColorMode Never 2>&1
        $exitCode = $LASTEXITCODE
        $text = $output -join "`n"

        $exitCode | Should Be 0
        $text | Should Match "Review Loop completed"
        $text | Should Not Match '"Status"\s*:|"RunRoot"\s*:'
        $text | Should Not Match "Repository:|Checkpoint:|Ledger:"
    }

    It "propagates fast to every role in a complete run" {
        Write-FakeResultSequence -Path $env:CODEX_REVIEW_LOOP_FAKE_RESULT_SEQUENCE -Results @(
            '{"schemaVersion":"1.0","classification":"clean","summary":"clean","findings":[]}',
            '{"schemaVersion":"1.0","classification":"clean","summary":"clean","findings":[]}'
        )
        $result = Invoke-CodexReviewLoop `
            -RepoPath $repo -ConfigPath $configPath -Speed fast -CodexPath $fakeCodex -NewRun `
            -OutputMode detailed -HeartbeatSeconds 0 -ColorMode Never
        $result.Status | Should Be "completed"
        $records = Get-Content -LiteralPath $env:CODEX_REVIEW_LOOP_FAKE_LOG | ForEach-Object { $_ | ConvertFrom-Json }
        @($records | Where-Object { ($_.arguments -join " ") -notmatch 'service_tier="fast"' }).Count | Should Be 0
        (Get-Content -Raw -LiteralPath (Join-Path $result.RunRoot "terminal.log")) |
            Should Match "Output:\s+detailed · heartbeat 0s · Never"
    }

    It "uses exactly two fixer attempts and resumes only the cluster thread" {
        $configPath = New-TestConfig -Path $configPath -LogRoot (Join-Path $caseRoot "logs") -WithHostGate
        $env:CODEX_REVIEW_LOOP_FAKE_MUTATE_ON_SCHEMA = "fixer-result-v1.schema.json"
        $findingReview = '{"schemaVersion":"1.0","classification":"findings","summary":"one","findings":[{"priority":"P1","title":"cache defect","path":"src/A.cs","line":10,"component":"cache","rootCause":"missing dependency","invariant":"cache invalidates","evidence":"e","reproduction":"r","suggestedFix":"f","suggestedTest":"t","fixPaths":["src/A.cs","tests/A.Tests.cs"]}]}'
        $fixChanged = '{"schemaVersion":"1.0","outcome":"changed","summary":"fixed","changedPaths":["fake-review-loop-change.test.txt","fake-review-loop-change.test.txt"],"targetedTest":{"filePath":"dotnet","arguments":["test",".\\review-loop-test.proj","--no-restore","--nologo"],"rationale":"targeted regression"},"remainingRisk":""}'
        $stillOpen = '{"schemaVersion":"2.0","verdict":"reproduced","patchSafety":"safe","confidence":"high","rationale":"still open","regressions":[],"evidence":[{"path":"README.txt","line":1,"claim":"the defect remains"}]}'
        $resolved = '{"schemaVersion":"2.0","verdict":"resolved","patchSafety":"safe","confidence":"high","rationale":"fixed","regressions":[],"evidence":[{"path":"README.txt","line":1,"claim":"the defect is fixed"}]}'
        Write-FakeResultSequence -Path $env:CODEX_REVIEW_LOOP_FAKE_RESULT_SEQUENCE -Results @(
            $findingReview,
            $fixChanged, $stillOpen,
            $fixChanged, $resolved,
            '{"schemaVersion":"1.0","classification":"clean","summary":"clean","findings":[]}',
            '{"schemaVersion":"1.0","classification":"clean","summary":"clean","findings":[]}'
        )

        $result = Invoke-CodexReviewLoop -RepoPath $repo -ConfigPath $configPath -Speed standard -CodexPath $fakeCodex -NewRun
        $result.Status | Should Be "completed"
        $ledger = Read-ReviewLoopLedger -Path $result.LedgerPath
        $ledger.Findings[0].Status | Should Be "resolved"
        $ledger.Findings[0].FixAttempts | Should Be 2
        $records = Get-Content -LiteralPath $env:CODEX_REVIEW_LOOP_FAKE_LOG | ForEach-Object { $_ | ConvertFrom-Json }
        @($records | Where-Object { ($_.arguments -join " ") -match ' resume cluster-thread -' }).Count | Should Be 1
        $terminal = Get-Content -Raw -LiteralPath (Join-Path $result.RunRoot "terminal.log")
        $terminal | Should Match "Finding-Cluster"
        $terminal | Should Match "Fixer · attempt 2/2 · resuming thread"
        $terminal | Should Match "Fixer: changed · 1 changed paths"
        $terminal | Should Match "Verifier: resolved"
        $terminal | Should Match "Host-Gate: fake gate"
        $terminal | Should Match "Committed"
    }

    It "rolls back an exhausted cluster before committing an independent cluster" {
        $findingReview = '{"schemaVersion":"1.0","classification":"findings","summary":"two independent findings","findings":[{"priority":"P1","title":"first defect","path":"src/A.cs","line":10,"component":"first","rootCause":"first cause","invariant":"first invariant","evidence":"e","reproduction":"r","suggestedFix":"f","suggestedTest":"t","fixPaths":["src/A.cs"]},{"priority":"P1","title":"second defect","path":"src/B.cs","line":20,"component":"second","rootCause":"second cause","invariant":"second invariant","evidence":"e","reproduction":"r","suggestedFix":"f","suggestedTest":"t","fixPaths":["src/B.cs"]}]}'
        $fixChanged = '{"schemaVersion":"1.0","outcome":"changed","summary":"changed","changedPaths":[],"targetedTest":{"filePath":"pwsh","arguments":["-NoProfile","-Command","exit 0"],"rationale":"targeted regression"},"remainingRisk":""}'
        $reproduced = '{"schemaVersion":"2.0","verdict":"reproduced","patchSafety":"safe","confidence":"high","rationale":"still open","regressions":[],"evidence":[{"path":"README.txt","line":1,"claim":"still present"}]}'
        $resolved = '{"schemaVersion":"2.0","verdict":"resolved","patchSafety":"safe","confidence":"high","rationale":"fixed","regressions":[],"evidence":[{"path":"README.txt","line":1,"claim":"fixed"}]}'
        $clean = '{"schemaVersion":"1.0","classification":"clean","summary":"clean","findings":[]}'
        $plans = @(
            [pscustomobject]@{ result = $findingReview },
            [pscustomobject]@{
                result = $fixChanged
                mutations = @([pscustomobject]@{ path = "first.txt"; content = "abandoned attempt one" })
            },
            [pscustomobject]@{ result = $reproduced },
            [pscustomobject]@{
                result = $fixChanged
                mutations = @([pscustomobject]@{ path = "first.txt"; content = "abandoned attempt two" })
            },
            [pscustomobject]@{ result = $reproduced },
            [pscustomobject]@{
                result = $fixChanged
                mutations = @([pscustomobject]@{ path = "second.txt"; content = "independent verified fix" })
            },
            [pscustomobject]@{ result = $resolved },
            [pscustomobject]@{ result = $clean }
        )
        $invocationPlanPath = Join-Path $caseRoot "rollback-invocations.json"
        Set-Content -LiteralPath $invocationPlanPath `
            -Value (ConvertTo-Json -InputObject $plans -Depth 20) -Encoding UTF8
        $env:CODEX_REVIEW_LOOP_FAKE_INVOCATION_SEQUENCE = $invocationPlanPath

        $result = Invoke-CodexReviewLoop `
            -RepoPath $repo -ConfigPath $configPath -Speed standard -CodexPath $fakeCodex -NewRun `
            -HeartbeatSeconds 0 -ColorMode Never

        $result.Status | Should Be "blocked"
        (& git -C $repo status --porcelain) | Should BeNullOrEmpty
        Test-Path -LiteralPath (Join-Path $repo "first.txt") | Should Be $false
        (Get-Content -Raw -LiteralPath (Join-Path $repo "second.txt")) | Should Match "independent verified fix"
        $committedPaths = @(& git -C $repo show --format= --name-only HEAD -- | Where-Object { $_ })
        $committedPaths | Should Be @("second.txt")
        $ledger = Read-ReviewLoopLedger -Path $result.LedgerPath
        $blockedFinding = @($ledger.Findings | Where-Object {
            $_.Status -eq "blocked" -and $_.FixAttempts -eq 2
        })[0]
        $blockedFinding | Should Not BeNullOrEmpty
        Test-Path -LiteralPath $blockedFinding.BlockedArtifactRoot | Should Be $true
        @($ledger.Findings | Where-Object { $_.Status -eq "resolved" -and $_.FixAttempts -eq 1 }).Count | Should Be 1
        $records = Get-Content -LiteralPath $env:CODEX_REVIEW_LOOP_FAKE_LOG | ForEach-Object { $_ | ConvertFrom-Json }
        @($records | Where-Object {
            [System.IO.Path]::GetFileName([string]$_.schemaPath) -eq "fixer-result-v1.schema.json"
        }).Count | Should Be 3
        @($records | Where-Object {
            [System.IO.Path]::GetFileName([string]$_.schemaPath) -eq "architecture-proposal-v1.schema.json"
        }).Count | Should Be 0
    }

    It "leaves the target repository unchanged during prompt-independent clean orchestration" {
        $before = & git -C $repo rev-parse HEAD
        Write-FakeResultSequence -Path $env:CODEX_REVIEW_LOOP_FAKE_RESULT_SEQUENCE -Results @(
            '{"schemaVersion":"1.0","classification":"clean","summary":"clean","findings":[]}',
            '{"schemaVersion":"1.0","classification":"clean","summary":"clean","findings":[]}'
        )
        Invoke-CodexReviewLoop -RepoPath $repo -ConfigPath $configPath -Speed standard -CodexPath $fakeCodex -NewRun | Out-Null
        (& git -C $repo rev-parse HEAD) | Should Be $before
        (& git -C $repo status --porcelain) | Should BeNullOrEmpty
    }

    It "requires critic and veto agreement for a semantic finding cluster" {
        $env:CODEX_REVIEW_LOOP_FAKE_MUTATE_ON_SCHEMA = "fixer-result-v1.schema.json"
        $twoFindings = '{"schemaVersion":"1.0","classification":"findings","summary":"two","findings":[{"priority":"P1","title":"first","path":"src/A.cs","line":10,"component":"shared","rootCause":"cause-a","invariant":"invariant-a","evidence":"e","reproduction":"r","suggestedFix":"f","suggestedTest":"t","fixPaths":["src/A.cs"]},{"priority":"P1","title":"second","path":"src/B.cs","line":20,"component":"shared","rootCause":"cause-b","invariant":"invariant-b","evidence":"e","reproduction":"r","suggestedFix":"f","suggestedTest":"t","fixPaths":["src/B.cs"]}]}'
        $firstId = Get-ReviewLoopFindingId `
            -Path "src/A.cs" -Component "shared" -RootCause "cause-a" -Invariant "invariant-a"
        $triggerArchitecture = '{"schemaVersion":"2.0","decisions":[{"candidateFindingId":"' + $firstId + '","relation":"same_contract_different_edge","candidateStatus":"active","confidence":"high","rationale":"shared contract","evidence":[{"path":"README.txt","line":1,"claim":"the findings share a contract"}]}]}'
        $architectureId = Get-ReviewLoopFindingId `
            -Path "src/B.cs" -Component "shared" -RootCause "cause-b" -Invariant "invariant-b"
        $proposal = '{"schemaVersion":"1.0","recommendation":"consolidation","summary":"shared","sharedRootCause":"contract","minimalAlternative":"two points","findings":[{"findingId":"' + $firstId + '","disposition":"fixed","reproduction":"r","regressionTest":"test"},{"findingId":"' + $architectureId + '","disposition":"fixed","reproduction":"r","regressionTest":"test"}],"steps":[{"path":"src/Shared.cs","change":"centralize","productionCode":true,"findingIds":["' + $firstId + '","' + $architectureId + '"],"regressionTest":"test"}],"risks":[],"breaksPublicContract":false}'
        $approve = '{"schemaVersion":"1.0","decision":"approve","confidence":"high","rationale":"complete","coherentRootCause":true,"allFindingsCovered":true,"allRequiredPathsCovered":true,"minimalEnough":true,"missingPaths":[],"requiredChanges":[]}'
        $reject = '{"schemaVersion":"1.0","decision":"reject_to_point_fix","confidence":"high","rationale":"artificial","coherentRootCause":false,"allFindingsCovered":true,"allRequiredPathsCovered":true,"minimalEnough":false,"missingPaths":[],"requiredChanges":[]}'
        $fixChanged = '{"schemaVersion":"1.0","outcome":"changed","summary":"fixed","changedPaths":["fake-review-loop-change.test.txt"],"targetedTest":{"filePath":"dotnet","arguments":["test",".\\review-loop-test.proj","--no-restore","--nologo"],"rationale":"targeted regression"},"remainingRisk":""}'
        $resolved = '{"schemaVersion":"2.0","verdict":"resolved","patchSafety":"safe","confidence":"high","rationale":"fixed","regressions":[],"evidence":[{"path":"README.txt","line":1,"claim":"the defect is fixed"}]}'
        Write-FakeResultSequence -Path $env:CODEX_REVIEW_LOOP_FAKE_RESULT_SEQUENCE -Results @(
            $twoFindings,
            $triggerArchitecture, $triggerArchitecture,
            $proposal, $approve, $reject, $reject,
            $fixChanged, $resolved,
            $fixChanged, $resolved,
            '{"schemaVersion":"1.0","classification":"clean","summary":"clean","findings":[]}',
            '{"schemaVersion":"1.0","classification":"clean","summary":"clean","findings":[]}'
        )

        $result = Invoke-CodexReviewLoop -RepoPath $repo -ConfigPath $configPath -Speed standard -CodexPath $fakeCodex -NewRun
        $result.Status | Should Be "completed"
        $records = Get-Content -LiteralPath $env:CODEX_REVIEW_LOOP_FAKE_LOG | ForEach-Object { $_ | ConvertFrom-Json }
        $architectCalls = @($records | Where-Object {
            [System.IO.Path]::GetFileName([string]$_.schemaPath) -eq "architecture-proposal-v1.schema.json"
        })
        $architectCalls.Count | Should Be 1
        [regex]::Matches([string]$architectCalls[0].prompt, '"Id":"F-[^"]+"').Count | Should Be 2
        @($records | Where-Object { [System.IO.Path]::GetFileName([string]$_.schemaPath) -eq "architecture-critique-v1.schema.json" }).Count | Should Be 3
        $terminal = Get-Content -Raw -LiteralPath (Join-Path $result.RunRoot "terminal.log")
        $terminal | Should Match "Trigger: same_contract_different_edge · multiple_active_findings"
        $terminal | Should Match "Proposal r0: consolidation"
        $terminal | Should Match "Terra-Critic: approve"
        $terminal | Should Match "Sol-Veto: reject_to_point_fix"
        $terminal | Should Match "Terra-Tie-Break: reject_to_point_fix"
    }

    It "falls back to point fixing after the single allowed architecture revision" {
        $env:CODEX_REVIEW_LOOP_FAKE_MUTATE_ON_SCHEMA = "fixer-result-v1.schema.json"
        $twoFindings = '{"schemaVersion":"1.0","classification":"findings","summary":"two","findings":[{"priority":"P1","title":"first","path":"src/A.cs","line":10,"component":"shared","rootCause":"cause-a","invariant":"invariant-a","evidence":"e","reproduction":"r","suggestedFix":"f","suggestedTest":"t","fixPaths":["src/A.cs"]},{"priority":"P1","title":"second","path":"src/B.cs","line":20,"component":"shared","rootCause":"cause-b","invariant":"invariant-b","evidence":"e","reproduction":"r","suggestedFix":"f","suggestedTest":"t","fixPaths":["src/B.cs"]}]}'
        $firstId = Get-ReviewLoopFindingId `
            -Path "src/A.cs" -Component "shared" -RootCause "cause-a" -Invariant "invariant-a"
        $triggerArchitecture = '{"schemaVersion":"2.0","decisions":[{"candidateFindingId":"' + $firstId + '","relation":"same_contract_different_edge","candidateStatus":"active","confidence":"high","rationale":"shared contract","evidence":[{"path":"README.txt","line":1,"claim":"the findings share a contract"}]}]}'
        $architectureId = Get-ReviewLoopFindingId `
            -Path "src/B.cs" -Component "shared" -RootCause "cause-b" -Invariant "invariant-b"
        $proposal = '{"schemaVersion":"1.0","recommendation":"consolidation","summary":"shared","sharedRootCause":"contract","minimalAlternative":"two points","findings":[{"findingId":"' + $firstId + '","disposition":"fixed","reproduction":"r","regressionTest":"test"},{"findingId":"' + $architectureId + '","disposition":"fixed","reproduction":"r","regressionTest":"test"}],"steps":[{"path":"src/Shared.cs","change":"centralize","productionCode":true,"findingIds":["' + $firstId + '","' + $architectureId + '"],"regressionTest":"test"}],"risks":[],"breaksPublicContract":false}'
        $revise = '{"schemaVersion":"1.0","decision":"revise","confidence":"high","rationale":"missing path","coherentRootCause":true,"allFindingsCovered":false,"allRequiredPathsCovered":false,"minimalEnough":true,"missingPaths":["src/Missing.cs"],"requiredChanges":["add missing path"]}'
        $fixChanged = '{"schemaVersion":"1.0","outcome":"changed","summary":"fixed","changedPaths":["fake-review-loop-change.test.txt"],"targetedTest":{"filePath":"dotnet","arguments":["test",".\\review-loop-test.proj","--no-restore","--nologo"],"rationale":"targeted regression"},"remainingRisk":""}'
        $resolved = '{"schemaVersion":"2.0","verdict":"resolved","patchSafety":"safe","confidence":"high","rationale":"fixed","regressions":[],"evidence":[{"path":"README.txt","line":1,"claim":"the defect is fixed"}]}'
        Write-FakeResultSequence -Path $env:CODEX_REVIEW_LOOP_FAKE_RESULT_SEQUENCE -Results @(
            $twoFindings,
            $triggerArchitecture, $triggerArchitecture,
            $proposal, $revise,
            $proposal, $revise,
            $fixChanged, $resolved,
            '{"schemaVersion":"1.0","classification":"clean","summary":"clean","findings":[]}',
            '{"schemaVersion":"1.0","classification":"clean","summary":"clean","findings":[]}'
        )

        $result = Invoke-CodexReviewLoop -RepoPath $repo -ConfigPath $configPath -Speed standard -CodexPath $fakeCodex -NewRun
        $result.Status | Should Be "completed"
        $records = Get-Content -LiteralPath $env:CODEX_REVIEW_LOOP_FAKE_LOG | ForEach-Object { $_ | ConvertFrom-Json }
        @($records | Where-Object { [System.IO.Path]::GetFileName([string]$_.schemaPath) -eq "fixer-result-v1.schema.json" }).Count | Should Be 1
        (Get-Content -Raw -LiteralPath (Join-Path $result.RunRoot "terminal.log")) |
            Should Match "falling back to point fixing"
    }

    It "recovers an interrupted dirty fix and uses only the remaining attempt" {
        $env:CODEX_REVIEW_LOOP_FAKE_MUTATE_ON_SCHEMA = "fixer-result-v1.schema.json"
        $config = Import-PowerShellDataFile -LiteralPath $configPath
        $profileRoot = & (Get-Module CodexReviewLoop) {
            param($profile, $repository)
            (New-ReviewLoopRunPaths -Config $profile -RepoPath $repository).ProfileRoot
        } $config $repo
        $runRoot = Join-Path $profileRoot "99999999-active"
        New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
        $statePath = Join-Path $runRoot "run-v1.json"
        $ledgerPath = Join-Path $profileRoot "ledger-v2.json"
        $ledger = New-ReviewLoopLedger -RepoPath $repo
        Merge-ReviewLoopFindings -Ledger $ledger -Findings @((New-TestFinding)) -ReviewId r1 -Head (& git -C $repo rev-parse HEAD) | Out-Null
        $finding = $ledger.Findings[0]
        $finding.Status = "fixing"
        $finding.FixAttempts = 1
        $finding.FixerThreadId = "cluster-thread"
        $finding.FixPaths = @($finding.FixPaths) + "interrupted.txt"
        Write-ReviewLoopLedger -Path $ledgerPath -Ledger $ledger | Out-Null

        $reviewBaseCommit = & git -C $repo rev-parse HEAD
        $executionFingerprint = & (Get-Module CodexReviewLoop) {
            param($path)
            Get-ReviewLoopExecutionFingerprint -ConfigPath $path
        } $configPath
        $state = New-ReviewLoopState `
            -RepoPath $repo -ReviewBase HEAD -Speed standard -RunRoot $runRoot `
            -ReviewBaseCommit $reviewBaseCommit -ExecutionFingerprint $executionFingerprint
        $state.Stage = "fix_attempted"
        $state.ActiveClusterId = $finding.ClusterId
        $state.ActiveFindingIds = @($finding.Id)
        $state.LastFixerResult = [pscustomobject]@{
            StructuredResult = [pscustomobject]@{
                schemaVersion = "1.0"
                outcome = "changed"
                summary = "interrupted"
                changedPaths = @("interrupted.txt")
                targetedTest = [pscustomobject]@{
                    filePath = "dotnet"
                    arguments = @("test", ".\review-loop-test.proj", "--no-restore", "--nologo")
                    rationale = "targeted regression"
                }
                remainingRisk = ""
            }
            ThreadId = "cluster-thread"
            Attempt = 1
        }
        Write-ReviewLoopState -Path $statePath -State $state | Out-Null
        Set-Content -LiteralPath (Join-Path $repo "interrupted.txt") -Value "dirty"

        $stillOpen = '{"schemaVersion":"2.0","verdict":"reproduced","patchSafety":"safe","confidence":"high","rationale":"still open","regressions":[],"evidence":[{"path":"README.txt","line":1,"claim":"the defect remains"}]}'
        $fixChanged = '{"schemaVersion":"1.0","outcome":"changed","summary":"fixed","changedPaths":["fake-review-loop-change.test.txt"],"targetedTest":{"filePath":"dotnet","arguments":["test",".\\review-loop-test.proj","--no-restore","--nologo"],"rationale":"targeted regression"},"remainingRisk":""}'
        $resolved = '{"schemaVersion":"2.0","verdict":"resolved","patchSafety":"safe","confidence":"high","rationale":"fixed","regressions":[],"evidence":[{"path":"README.txt","line":1,"claim":"the defect is fixed"}]}'
        Write-FakeResultSequence -Path $env:CODEX_REVIEW_LOOP_FAKE_RESULT_SEQUENCE -Results @(
            $stillOpen, $fixChanged, $resolved,
            '{"schemaVersion":"1.0","classification":"clean","summary":"clean","findings":[]}',
            '{"schemaVersion":"1.0","classification":"clean","summary":"clean","findings":[]}'
        )

        $result = Invoke-CodexReviewLoop `
            -RepoPath $repo -ConfigPath $configPath -Speed standard -CodexPath $fakeCodex `
            -OutputMode balanced -HeartbeatSeconds 0 -ColorMode Never
        $result.Status | Should Be "completed"
        $updated = Read-ReviewLoopLedger -Path $ledgerPath
        $updated.Findings[0].FixAttempts | Should Be 2
        $updated.Findings[0].Status | Should Be "resolved"
        $records = Get-Content -LiteralPath $env:CODEX_REVIEW_LOOP_FAKE_LOG | ForEach-Object { $_ | ConvertFrom-Json }
        @($records | Where-Object { ($_.arguments -join " ") -match ' resume cluster-thread -' }).Count | Should Be 1
        (Get-Content -Raw -LiteralPath (Join-Path $result.RunRoot "terminal.log")) |
            Should Match "Output:\s+balanced · heartbeat 0s · Never"
    }

    It "resumes a failed verifier checkpoint without rerunning the completed fixer attempt" {
        $config = Import-PowerShellDataFile -LiteralPath $configPath
        $profileRoot = & (Get-Module CodexReviewLoop) {
            param($profile, $repository)
            (New-ReviewLoopRunPaths -Config $profile -RepoPath $repository).ProfileRoot
        } $config $repo
        $runRoot = Join-Path $profileRoot "99999999-failed"
        New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
        $statePath = Join-Path $runRoot "run-v1.json"
        $ledgerPath = Join-Path $profileRoot "ledger-v2.json"
        $ledger = New-ReviewLoopLedger -RepoPath $repo
        Merge-ReviewLoopFindings -Ledger $ledger -Findings @((New-TestFinding)) -ReviewId r1 -Head (& git -C $repo rev-parse HEAD) | Out-Null
        $finding = $ledger.Findings[0]
        $finding.Status = "fixing"
        $finding.FixAttempts = 1
        $finding.FixerThreadId = "cluster-thread"
        $finding.FixPaths = @($finding.FixPaths) + "interrupted.txt"
        Write-ReviewLoopLedger -Path $ledgerPath -Ledger $ledger | Out-Null

        $reviewBaseCommit = & git -C $repo rev-parse HEAD
        $executionFingerprint = & (Get-Module CodexReviewLoop) {
            param($path)
            Get-ReviewLoopExecutionFingerprint -ConfigPath $path
        } $configPath
        $state = New-ReviewLoopState `
            -RepoPath $repo -ReviewBase HEAD -Speed standard -RunRoot $runRoot `
            -ReviewBaseCommit $reviewBaseCommit -ExecutionFingerprint $executionFingerprint
        $state.Status = "failed"
        $state.ExitCode = 2
        $state.Stage = "stopped"
        $state.BlockedReason = "Prompt 'verifier.md' contains unreplaced placeholders."
        $state.ActiveClusterId = $finding.ClusterId
        $state.ActiveFindingIds = @($finding.Id)
        $state.LastFixerResult = [pscustomobject]@{
            StructuredResult = [pscustomobject]@{
                schemaVersion = "1.0"
                outcome = "changed"
                summary = "fix already completed"
                changedPaths = @("interrupted.txt")
                targetedTest = [pscustomobject]@{
                    filePath = "dotnet"
                    arguments = @("test", ".\review-loop-test.proj", "--no-restore", "--nologo")
                    rationale = "targeted regression"
                }
                remainingRisk = ""
            }
            ThreadId = "cluster-thread"
            Attempt = 1
        }
        Write-ReviewLoopState -Path $statePath -State $state | Out-Null
        Set-Content -LiteralPath (Join-Path $repo "interrupted.txt") -Value "dirty"

        $resolved = '{"schemaVersion":"2.0","verdict":"resolved","patchSafety":"safe","confidence":"high","rationale":"fixed","regressions":[],"evidence":[{"path":"README.txt","line":1,"claim":"the defect is fixed"}]}'
        Write-FakeResultSequence -Path $env:CODEX_REVIEW_LOOP_FAKE_RESULT_SEQUENCE -Results @(
            $resolved,
            '{"schemaVersion":"1.0","classification":"clean","summary":"clean","findings":[]}',
            '{"schemaVersion":"1.0","classification":"clean","summary":"clean","findings":[]}'
        )

        $result = Invoke-CodexReviewLoop `
            -RepoPath $repo -ConfigPath $configPath -Speed standard -CodexPath $fakeCodex `
            -HeartbeatSeconds 0 -ColorMode Never

        $result.Status | Should Be "completed"
        $records = Get-Content -LiteralPath $env:CODEX_REVIEW_LOOP_FAKE_LOG | ForEach-Object { $_ | ConvertFrom-Json }
        @($records | Where-Object {
            [System.IO.Path]::GetFileName([string]$_.schemaPath) -eq "fixer-result-v1.schema.json"
        }).Count | Should Be 0
        $terminal = Get-Content -Raw -LiteralPath (Join-Path $result.RunRoot "terminal.log")
        $terminal | Should Not Match "Resuming the previous failed checkpoint at stage 'fix_attempted'"
        $terminal | Should Match "Resuming interrupted fix cluster"
    }
}
