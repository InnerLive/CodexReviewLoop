$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
$modulePath = Join-Path $root "CodexReviewLoop.psd1"
$fakeCodex = Join-Path $here "FakeCodex.ps1"
$inProcessCodex = Join-Path $here "InProcessCodex.ps1"

Import-Module $modulePath -Force
. $inProcessCodex

function New-TestRepo {
    param([string]$Path)
    $template = Join-Path $TestDrive "repo-template-main"
    if (-not (Test-Path -LiteralPath (Join-Path $template ".git") -PathType Container)) {
        New-Item -ItemType Directory -Path $template -Force | Out-Null
        & git -C $template init -q
        & git -C $template config user.email "review-loop-tests@example.invalid"
        & git -C $template config user.name "Review Loop Tests"
        & git -C $template config core.autocrlf false
        Set-Content -LiteralPath (Join-Path $template "README.txt") -Value "test"
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
        throw "Test repository clone failed: '$Path'."
    }
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
    $locations = @([pscustomobject]@{
        path = $Path
        line = 10
    })
    foreach ($fixPath in @($FixPaths | Where-Object { $_ -ne $Path })) {
        $locations += [pscustomobject]@{ path = $fixPath; line = 0 }
    }
    return [pscustomobject]@{
        title = "test finding"
        description = "$Component · $RootCause · $Invariant"
        locations = $locations
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
        [switch]$WithHostGate,
        [ValidateRange(1, 100)][int]$CleanPassesRequired = 2
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
    ReviewerInstructions = ""
    LogRoot = "$($LogRoot.Replace("\", "\\"))"
    CleanPassesRequired = $CleanPassesRequired
    MaxReviewCycles = 6
    LessonsLearnedCommitThreshold = 6
    ReviewAfterLessonsLearnedCommit = `$false
    MaxFixAttempts = 2
    InactivityTimeoutMinutes = 30
    TargetedTestRepositoryChanges = @{
        Mode = 'Fail'
    }
    AutoCommit = `$true
    CommitMessagePrefix = "Test Review Loop"
    HostGates = @($gate)
    Roles = @{
        Reviewer = @{ Model = "fake"; Thinking = "high" }
        Architect = @{ Model = "fake"; Thinking = "high" }
        Fixer = @{ Model = "fake"; Thinking = "high" }
        Verifier = @{ Model = "fake"; Thinking = "low" }
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
            LedgerPath = $paths.LedgerPath
        }
    } $RepoPath $ConfigPath $Speed
}

function Enable-TestLessonsLearnedCheckpoint {
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [ValidateSet("standard", "fast")][string]$Speed = "standard"
    )

    $checkpoint = New-TestActiveCheckpoint `
        -RepoPath $RepoPath -ConfigPath $ConfigPath -Speed $Speed
    $historyTemplate = Join-Path $TestDrive "repo-template-lessons-history"
    if (-not (Test-Path -LiteralPath (Join-Path $historyTemplate ".git") -PathType Container)) {
        New-TestRepo -Path $historyTemplate | Out-Null
        for ($index = 1; $index -le 6; $index++) {
            $path = if ($index -eq 1) { "AGENTS.md" } else { "loop-$index.txt" }
            $content = if ($index -eq 1) {
                "# Repository instructions`n"
            }
            else {
                "verified loop change $index`n"
            }
            Set-Content -LiteralPath (Join-Path $historyTemplate $path) `
                -Value $content -NoNewline
            if ($index -eq 1) {
                $obsolete = Join-Path $historyTemplate ".agents/skills/obsolete/SKILL.md"
                New-Item -ItemType Directory -Path (Split-Path -Parent $obsolete) `
                    -Force | Out-Null
                Set-Content -LiteralPath $obsolete `
                    -Value "---`nname: obsolete`ndescription: Obsolete fixture workflow.`n---`n"
            }
            & git -C $historyTemplate add -- $path
            if ($index -eq 1) {
                & git -C $historyTemplate add -- ".agents/skills/obsolete/SKILL.md"
            }
            & git -C $historyTemplate commit -q -m "verified loop change $index"
        }
    }
    $startingHead = & git -C $RepoPath rev-parse HEAD
    & git -C $RepoPath fetch -q --no-tags -- $historyTemplate HEAD
    if ($LASTEXITCODE -ne 0) {
        throw "Lessons-learned history fixture could not be imported."
    }
    $commits = @(& git -C $RepoPath rev-list --reverse "$startingHead..FETCH_HEAD")
    & git -C $RepoPath reset -q --hard FETCH_HEAD
    $state = Read-ReviewLoopState -Path $checkpoint.StatePath
    $state.CurrentHead = & git -C $RepoPath rev-parse HEAD
    $state.LoopCommits = @($commits)
    $state.LoopCommitsInitialized = $true
    Write-ReviewLoopState -Path $checkpoint.StatePath -State $state | Out-Null
    return $checkpoint
}

function New-EndToEndTestCase {
    $repo = New-TestRepo (Join-Path $TestDrive ([Guid]::NewGuid().ToString("N")))
    $caseRoot = Join-Path $TestDrive ([Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $caseRoot | Out-Null
    $configPath = New-TestConfig `
        -Path (Join-Path $caseRoot "profile.psd1") `
        -LogRoot (Join-Path $caseRoot "logs") `
        -CleanPassesRequired 1
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
    return [pscustomobject]@{
        Repo = $repo
        CaseRoot = $caseRoot
        ConfigPath = $configPath
    }
}

function Clear-EndToEndTestCase {
    @(
        "CODEX_REVIEW_LOOP_FAKE_LOG",
        "CODEX_REVIEW_LOOP_FAKE_RESULT_SEQUENCE",
        "CODEX_REVIEW_LOOP_FAKE_THREAD",
        "CODEX_REVIEW_LOOP_FAKE_RESULT",
        "CODEX_REVIEW_LOOP_FAKE_EXIT_CODE",
        "CODEX_REVIEW_LOOP_FAKE_STDERR",
        "CODEX_REVIEW_LOOP_FAKE_MUTATE_ON_SCHEMA",
        "CODEX_REVIEW_LOOP_FAKE_INVOCATION_SEQUENCE",
        "CODEX_REVIEW_LOOP_FAKE_NULL_USAGE",
        "CODEX_REVIEW_LOOP_FAKE_HANG_MS"
    ) | ForEach-Object { Remove-Item "Env:\$_" -ErrorAction SilentlyContinue }
}

Describe "Codex Review Loop module" -Tags @("Fast", "FullLocal") {
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
        $profile.LessonsLearnedCommitThreshold | Should Be 6
        $profile.ReviewAfterLessonsLearnedCommit | Should Be $false
        $profile.Roles.Keys.Count | Should Be 5
        @($profile.Roles.Keys | Sort-Object) | Should Be @(
            "Architect", "Fixer", "LessonsLearned", "ReviewClassifier", "Reviewer")
    }
}

Describe "Optional profiles and command help" -Tags @("Static", "FullLocal") {
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
        $content | Should Match "TargetedTestRepositoryChanges"
        $content | Should Match "RestoreMatching"
        $content | Should Match "RestoreAll"
        $content | Should Match "Recommended: 2-3 clean passes"
        $content | Should Match "Recommended: 6-30 native review cycles per script invocation"
        $content | Should Match "Recommended: 2-5 fixer calls"
        $profile = Import-PowerShellDataFile -LiteralPath $resolved
        $profile.Name | Should Be "automatic-profile-repo"
        $canonicalRepo = & $module {
            param($repository)
            Get-ReviewLoopRepositoryRoot -RepoPath $repository
        } $repo
        $profile.RepositoryPath | Should Be $canonicalRepo
        $profile.LogRoot | Should Be ".\runs"
        $profile.ReviewerInstructions | Should Be ""
        $profile.InactivityTimeoutMinutes | Should Be 30
        $profile.LessonsLearnedCommitThreshold | Should Be 6
        $profile.ReviewAfterLessonsLearnedCommit | Should Be $false
        $profile.TargetedTestRepositoryChanges.Mode | Should Be "Fail"
        $profile.Roles.Keys.Count | Should Be 5
        @($profile.HostGates).Count | Should Be 1
        $imported = & $module {
            param($path)
            Import-ReviewLoopConfig -ConfigPath $path
        } $resolved
        $imported.LogRoot | Should Be (Join-Path $root "runs")
    }

    It "accepts profile-owner budgets outside the recommended ranges" {
        $repo = New-TestRepo (Join-Path $TestDrive "custom-budget-repo")
        $profilePath = New-TestConfig `
            -Path (Join-Path $TestDrive "custom-budget.psd1") `
            -LogRoot (Join-Path $TestDrive "custom-budget-logs")
        $profile = Import-PowerShellDataFile -LiteralPath $profilePath
        $profile.CleanPassesRequired = 7
        $profile.MaxReviewCycles = 1
        $profile.MaxFixAttempts = 9
        $profile.InactivityTimeoutMinutes = -5
        $profile.AutoCommit = $false
        $failure = $null

        try {
            & (Get-Module CodexReviewLoop) {
                param($config)
                Assert-ReviewLoopConfigValues -Config $config
            } $profile
        }
        catch {
            $failure = $_
        }

        $failure | Should BeNullOrEmpty
        $profile.CleanPassesRequired | Should Be 7
        $profile.MaxReviewCycles | Should Be 1
        $profile.MaxFixAttempts | Should Be 9
        $profile.InactivityTimeoutMinutes | Should Be -5
        (& (Get-Module CodexReviewLoop) {
            param($config)
            Get-ReviewLoopInactivityTimeoutSeconds -Config $config
        } $profile) | Should Be 0
    }

    It "defaults old profiles to a 30-minute inactivity timeout" {
        $profilePath = New-TestConfig `
            -Path (Join-Path $TestDrive "old-timeout-profile.psd1") `
            -LogRoot (Join-Path $TestDrive "old-timeout-logs")
        $content = (Get-Content -Raw -LiteralPath $profilePath).
            Replace("    InactivityTimeoutMinutes = 30`r`n", "").
            Replace("    InactivityTimeoutMinutes = 30`n", "")
        Set-Content -LiteralPath $profilePath -Value $content -Encoding UTF8

        $profile = & (Get-Module CodexReviewLoop) {
            param($path)
            Import-ReviewLoopConfig -ConfigPath $path
        } $profilePath

        $profile.InactivityTimeoutMinutes | Should Be 30
    }

    It "defaults old profiles to empty ReviewerInstructions" {
        $profilePath = New-TestConfig `
            -Path (Join-Path $TestDrive "old-reviewer-instructions-profile.psd1") `
            -LogRoot (Join-Path $TestDrive "old-reviewer-instructions-logs")
        $content = (Get-Content -Raw -LiteralPath $profilePath) -replace
            '(?m)^    ReviewerInstructions = ""\r?\n', ''
        Set-Content -LiteralPath $profilePath -Value $content -Encoding UTF8

        $profile = & (Get-Module CodexReviewLoop) {
            param($path)
            Import-ReviewLoopConfig -ConfigPath $path
        } $profilePath

        $profile.ReviewerInstructions | Should Be ""
    }

    It "defaults old profiles to a six-commit lessons-learned threshold" {
        $profilePath = New-TestConfig `
            -Path (Join-Path $TestDrive "old-lessons-threshold-profile.psd1") `
            -LogRoot (Join-Path $TestDrive "old-lessons-threshold-logs")
        $content = (Get-Content -Raw -LiteralPath $profilePath) -replace
            '(?m)^    LessonsLearnedCommitThreshold = 6\r?\n', ''
        Set-Content -LiteralPath $profilePath -Value $content -Encoding UTF8

        $profile = & (Get-Module CodexReviewLoop) {
            param($path)
            Import-ReviewLoopConfig -ConfigPath $path
        } $profilePath

        $profile.LessonsLearnedCommitThreshold | Should Be 6
    }

    It "defaults old profiles to final lessons-learned completion" {
        $profilePath = New-TestConfig `
            -Path (Join-Path $TestDrive "old-lessons-completion-profile.psd1") `
            -LogRoot (Join-Path $TestDrive "old-lessons-completion-logs")
        $content = (Get-Content -Raw -LiteralPath $profilePath) -replace
            '(?m)^    ReviewAfterLessonsLearnedCommit = \$false\r?\n', ''
        Set-Content -LiteralPath $profilePath -Value $content -Encoding UTF8

        $profile = & (Get-Module CodexReviewLoop) {
            param($path)
            Import-ReviewLoopConfig -ConfigPath $path
        } $profilePath

        $profile.ReviewAfterLessonsLearnedCommit | Should Be $false
    }

    It "validates targeted-test repository-change policies and preserves the safe default" {
        $profilePath = New-TestConfig `
            -Path (Join-Path $TestDrive "targeted-test-policy.psd1") `
            -LogRoot (Join-Path $TestDrive "targeted-test-policy-logs")
        $content = (Get-Content -Raw -LiteralPath $profilePath) -replace
            "(?ms)^    TargetedTestRepositoryChanges = @\{.*?^    \}\r?\n", ""
        Set-Content -LiteralPath $profilePath -Value $content -Encoding UTF8
        $module = Get-Module CodexReviewLoop

        $profile = & $module {
            param($path)
            Import-ReviewLoopConfig -ConfigPath $path
        } $profilePath
        $profile.TargetedTestRepositoryChanges.Mode | Should Be "Fail"
        & $module { param($config) Assert-ReviewLoopConfigValues -Config $config } $profile

        foreach ($policy in @(
            @{ Mode = "Fail" },
            @{ Mode = "RestoreAll" }
        )) {
            $profile.TargetedTestRepositoryChanges = $policy
            (Test-Throws {
                & $module { param($config) Assert-ReviewLoopConfigValues -Config $config } $profile
            }) | Should Be $false
        }

        foreach ($invalidPolicy in @(
            "RestoreAll",
            @{},
            @{ Mode = "Unknown" },
            @{ Mode = "RestoreMatching" },
            @{ Mode = "Fail"; PathRegex = @("^one$") },
            @{ Mode = "RestoreAll"; Unexpected = $true }
        )) {
            $profile.TargetedTestRepositoryChanges = $invalidPolicy
            (Test-Throws {
                & $module { param($config) Assert-ReviewLoopConfigValues -Config $config } $profile
            }) | Should Be $true
        }
    }

    It "validates host-gate repository-change policies and preserves the safe default" {
        $profile = Import-PowerShellDataFile -LiteralPath (New-TestConfig `
            -Path (Join-Path $TestDrive "host-gate-policy.psd1") `
            -LogRoot (Join-Path $TestDrive "host-gate-policy-logs"))
        $gate = @{
            Name = "policy gate"
            FilePath = "pwsh"
            Arguments = @("-NoProfile", "-Command", "exit 0")
        }
        $profile.HostGates = @($gate)
        $module = Get-Module CodexReviewLoop

        & $module { param($config) Assert-ReviewLoopConfigValues -Config $config } $profile
        $defaultPolicy = & $module {
            param($item)
            Get-ReviewLoopHostGateRepositoryChanges -Gate $item
        } $gate
        $defaultPolicy.Mode | Should Be "Fail"
        @($defaultPolicy.PathRegex).Count | Should Be 0

        foreach ($policy in @(
            @{ Mode = "Fail" },
            @{ Mode = "RestoreAll" },
            @{ Mode = "RestoreMatching"; PathRegex = @("^generated/.*[.]lock$") }
        )) {
            $gate.RepositoryChanges = $policy
            (Test-Throws {
                & $module { param($config) Assert-ReviewLoopConfigValues -Config $config } $profile
            }) | Should Be $false
        }
        (& $module {
            param($policy)
            Test-ReviewLoopHostGateMutationAllowed `
                -Policy $policy -Paths @("source/generated.lock")
        } ([pscustomobject]@{
            Mode = "RestoreMatching"
            PathRegex = @("^SOURCE/GENERATED[.]LOCK$")
        })) | Should Be $true

        foreach ($invalidPolicy in @(
            "RestoreAll",
            @{ PathRegex = @("^one$") },
            @{ Mode = "Unknown" },
            @{ Mode = "RestoreMatching" },
            @{ Mode = "RestoreMatching"; PathRegex = @() },
            @{ Mode = "RestoreMatching"; PathRegex = "^one$" },
            @{ Mode = "RestoreMatching"; PathRegex = @(42) },
            @{ Mode = "RestoreMatching"; PathRegex = @("[") },
            @{ Mode = "Fail"; PathRegex = @("^one$") },
            @{ Mode = "RestoreAll"; PathRegex = @("^one$") },
            @{ Mode = "Fail"; Unexpected = $true }
        )) {
            $gate.RepositoryChanges = $invalidPolicy
            (Test-Throws {
                & $module { param($config) Assert-ReviewLoopConfigValues -Config $config } $profile
            }) | Should Be $true
        }
    }

    It "preflights symbolic host-gate executables without changing the profile" {
        $repo = New-TestRepo (Join-Path $TestDrive "host-gate-preflight-repo")
        $profilePath = New-TestConfig `
            -Path (Join-Path $TestDrive "host-gate-preflight.psd1") `
            -LogRoot (Join-Path $TestDrive "host-gate-preflight-logs")
        $content = (Get-Content -Raw -LiteralPath $profilePath).Replace(
            "    HostGates = @()",
            @"
    HostGates = @(
        @{ Name = "Solution tests"; FilePath = "dotnet"; Arguments = @("test", ".\Test.sln") }
        @{ Name = "Git diff check"; FilePath = "git"; Arguments = @("diff", "--check") }
    )
"@.TrimEnd())
        Set-Content -LiteralPath $profilePath -Value $content -Encoding UTF8
        $transcript = Join-Path $TestDrive "host-gate-preflight-terminal.log"
        $config = Import-PowerShellDataFile -LiteralPath $profilePath
        $config["__ConfigPath"] = $profilePath

        & (Get-Module CodexReviewLoop) {
            param($repository, $activeConfig, $terminalPath)
            Initialize-ReviewLoopConsole `
                -OutputMode compact -HeartbeatSeconds 0 -ColorMode Never `
                -TranscriptPath $terminalPath
            Assert-ReviewLoopHostGatePreflight `
                -Config $activeConfig -RepoPath $repository
            Update-ReviewLoopLiveConfig -Config $activeConfig
            Initialize-ReviewLoopConsole `
                -OutputMode compact -HeartbeatSeconds 0 -ColorMode Never `
                -TranscriptPath ""
        } $repo $config $transcript

        @($config.HostGates | ForEach-Object { [string]$_.FilePath }) |
            Should Be @("dotnet", "git")
        (Get-Content -Raw -LiteralPath $transcript) |
            Should Not Match "Reloaded live profile settings"
    }

    It "fails host-gate preflight when an executable cannot be resolved" {
        $repo = New-TestRepo (Join-Path $TestDrive "missing-host-gate-repo")
        $config = @{
            HostGates = @(@{
                Name = "Missing gate"
                FilePath = "review-loop-command-that-does-not-exist"
                Arguments = @()
            })
        }

        (Test-Throws {
            & (Get-Module CodexReviewLoop) {
                param($repository, $activeConfig)
                Assert-ReviewLoopHostGatePreflight `
                    -Config $activeConfig -RepoPath $repository
            } $repo $config
        }) | Should Be $true
    }

    It "renders genuine live profile changes without fingerprint JSON" {
        $profilePath = New-TestConfig `
            -Path (Join-Path $TestDrive "readable-live-reload.psd1") `
            -LogRoot (Join-Path $TestDrive "readable-live-reload-logs") `
            -WithHostGate
        $config = Import-PowerShellDataFile -LiteralPath $profilePath
        $config["__ConfigPath"] = $profilePath
        $content = (Get-Content -Raw -LiteralPath $profilePath).
            Replace("    MaxReviewCycles = 6", "    MaxReviewCycles = 7").
            Replace("    AutoCommit = `$true", "    AutoCommit = `$false").
            Replace(
                '    CommitMessagePrefix = "Test Review Loop"',
                '    CommitMessagePrefix = "private-prefix-value"').
            Replace(
                '    HostGates = @(@{ Name = "fake gate"; FilePath = "pwsh"; Arguments = @("-NoProfile", "-Command", "exit 0") })',
                '    HostGates = @(@{ Name = "Solution tests"; FilePath = "dotnet"; Arguments = @("test", ".\PKonf.sln") })').
            Replace(
                '        Fixer = @{ Model = "fake"; Thinking = "high" }',
                '        Fixer = @{ Model = "fake"; Thinking = "xhigh" }')
        Set-Content -LiteralPath $profilePath -Value $content -Encoding UTF8
        $transcript = Join-Path $TestDrive "readable-live-reload-terminal.log"

        & (Get-Module CodexReviewLoop) {
            param($activeConfig, $terminalPath)
            Initialize-ReviewLoopConsole `
                -OutputMode compact -HeartbeatSeconds 0 -ColorMode Never `
                -TranscriptPath $terminalPath
            Update-ReviewLoopLiveConfig -Config $activeConfig
            Initialize-ReviewLoopConsole `
                -OutputMode compact -HeartbeatSeconds 0 -ColorMode Never `
                -TranscriptPath ""
        } $config $transcript

        $text = Get-Content -Raw -LiteralPath $transcript
        $text | Should Match "Reloaded live profile settings"
        $text | Should Match "MaxReviewCycles: 6 -> 7"
        $text | Should Match "AutoCommit: enabled -> disabled"
        $text | Should Match "CommitMessagePrefix updated"
        $text | Should Not Match "private-prefix-value"
        $text | Should Match "HostGates:"
        $text | Should Match "Before:"
        $text | Should Match "fake gate: pwsh -NoProfile -Command 'exit 0'"
        $text | Should Match "After:"
        $text | Should Match ([regex]::Escape("Solution tests: dotnet test .\PKonf.sln"))
        $text | Should Match "Fixer: fake/high -> fake/xhigh"
        $text | Should Not Match '\[\{'
        $text | Should Not Match '"Arguments"\s*:'
    }

    It "maps the legacy fixer role and ignores old verifier entries" {
        $profile = Import-PowerShellDataFile -LiteralPath (New-TestConfig `
            -Path (Join-Path $TestDrive "legacy-roles.psd1") `
            -LogRoot (Join-Path $TestDrive "legacy-role-logs"))
        $profile.Roles.PointFixer = $profile.Roles.Fixer
        $profile.Roles.FindingVerifier = $profile.Roles.Verifier
        $profile.Roles.Remove("Fixer")
        $resolved = & (Get-Module CodexReviewLoop) {
            param($config)
            Assert-ReviewLoopConfigValues -Config $config
            Get-ReviewLoopRoleConfig -Config $config -Role Fixer
        } $profile
        $resolved.Model | Should Be "fake"
    }

    It "supplies the Luna classifier defaults to existing four-role profiles" {
        $profile = Import-PowerShellDataFile -LiteralPath (New-TestConfig `
            -Path (Join-Path $TestDrive "four-roles.psd1") `
            -LogRoot (Join-Path $TestDrive "four-role-logs"))
        $profile.Roles.ContainsKey("ReviewClassifier") | Should Be $false

        $classifier = & (Get-Module CodexReviewLoop) {
            param($config)
            Assert-ReviewLoopConfigValues -Config $config
            Get-ReviewLoopRoleConfig -Config $config -Role ReviewClassifier
        } $profile

        $classifier.Model | Should Be "gpt-5.6-luna"
        $classifier.Thinking | Should Be "low"
    }

    It "supplies the lessons-learned defaults to existing profiles" {
        $profile = Import-PowerShellDataFile -LiteralPath (New-TestConfig `
            -Path (Join-Path $TestDrive "old-lessons-role.psd1") `
            -LogRoot (Join-Path $TestDrive "old-lessons-role-logs"))
        $profile.Roles.ContainsKey("LessonsLearned") | Should Be $false

        $role = & (Get-Module CodexReviewLoop) {
            param($config)
            Assert-ReviewLoopConfigValues -Config $config
            Get-ReviewLoopRoleConfig -Config $config -Role LessonsLearned
        } $profile

        $role.Model | Should Be "gpt-5.6-sol"
        $role.Thinking | Should Be "high"
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
        ($output -join "`n") | Should Match "ReviewerInstructions"
        ($output -join "`n") | Should Match "empty string"
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

Describe "Global CLI arguments" -Tags @("Fast", "FullLocal") {
    BeforeEach {
        $repo = New-Item -ItemType Directory -Path (Join-Path $TestDrive ([Guid]::NewGuid().ToString("N"))) -Force
        $schema = Join-Path $root "schemas\architecture-advice-v2.schema.json"
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

    It "builds the native Codex review command without an output schema" {
        $args = Get-CodexRoleArguments -RepoPath $repo.FullName -Model m `
            -Thinking high -Mode Review -ReviewBase origin/main
        ($args -join " ") | Should Match "^--dangerously-bypass-approvals-and-sandbox .* review --base origin/main$"
        @($args | Select-Object -Last 3) | Should Be @("review", "--base", "origin/main")
        ($args -contains "exec") | Should Be $false
        ($args -contains "--json") | Should Be $false
        @($args | Where-Object { $_ -eq "--output-schema" }).Count | Should Be 0
        @($args | Where-Object { $_ -eq "-o" }).Count | Should Be 0
        ($args -contains "--dangerously-bypass-approvals-and-sandbox") | Should Be $true
    }

    It "passes multiline quoted Unicode reviewer instructions as TOML-compatible JSON" {
        $instructions = "Check `"quoted`" paths.`nPrüfe Nebenläufigkeit: 你好"
        $encoded = ConvertTo-Json -InputObject $instructions -Compress
        $args = Get-CodexRoleArguments -RepoPath $repo.FullName -Model m `
            -Thinking high -Mode Review -ReviewBase origin/main `
            -DeveloperInstructions $instructions

        @($args | Select-Object -Last 3) | Should Be @("review", "--base", "origin/main")
        @($args | Where-Object { $_ -like "developer_instructions=*" }) |
            Should Be @("developer_instructions=$encoded")
        ($args -contains "--output-schema") | Should Be $false
        ($args -contains "-o") | Should Be $false
    }

    It "requires a thread id for resume" {
        (Test-Throws { Get-CodexRoleArguments -RepoPath $repo.FullName -Model m -Thinking low -Mode Resume }) | Should Be $true
    }

    It "keeps retry delays private and preserves the exponential schedule" {
        ((Get-Command Invoke-CodexCliRole).Parameters.Keys -contains "RetryDelay") |
            Should Be $false
        $delays = [System.Collections.Generic.List[int]]::new()
        & (Get-Module CodexReviewLoop) {
            param($observed)
            $script:ReviewLoopRetryDelayOverride = {
                param([int]$seconds)
                [void]$observed.Add($seconds)
            }
            try {
                Invoke-ReviewLoopRetryDelay -Seconds 2
                Invoke-ReviewLoopRetryDelay -Seconds 4
                Invoke-ReviewLoopRetryDelay -Seconds 8
            }
            finally {
                $script:ReviewLoopRetryDelayOverride = $null
            }
        } $delays
        @($delays) | Should Be @(2, 4, 8)
    }
}

Describe "Finding identity and ledger" -Tags @("Fast", "FullLocal") {
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

    It "reopens a blocked history entry when the native review reports it again" {
        $finding = New-TestFinding
        Merge-ReviewLoopFindings -Ledger $ledger -Findings @($finding) -ReviewId r1 -Head h1 | Out-Null
        $ledger.Findings[0].Status = "blocked"
        Merge-ReviewLoopFindings -Ledger $ledger -Findings @($finding) -ReviewId r2 -Head h1 | Out-Null
        @($ledger.Findings).Count | Should Be 1
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

Describe "Run state" -Tags @("Fast", "FullLocal") {
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
        @($state.LoopCommits).Count | Should Be 0
        $state.LoopCommitsInitialized | Should Be $true
        $state.ActiveFindingSource | Should Be ""
        $state.LessonsLearned.Status | Should Be "pending"
        $state.LessonsLearned.Attempt | Should Be 0
        $state.LessonsLearned.ReviewAfterCommit | Should Be $false
        $state.RoleSessions.Architect | Should Be ""
        $state.RoleSessions.Fixer | Should Be ""
        @($state.RoleSessions.PSObject.Properties.Name -eq "Verifier").Count | Should Be 0
        @($state.RoleSessions.PSObject.Properties.Name -eq "Reviewer").Count | Should Be 0
    }

    It "stores the global speed" {
        $state.Speed | Should Be "standard"
    }

    It "pins the review base and execution fingerprint" {
        $state.ReviewBaseCommit | Should Be $reviewBaseCommit
        $state.ExecutionFingerprint | Should Be "test-execution-fingerprint"
    }

    It "fingerprints execution settings but excludes live profile settings" {
        $repo = New-TestRepo (Join-Path $TestDrive "live-fingerprint-repo")
        $profilePath = New-TestConfig `
            -Path (Join-Path $TestDrive "live-fingerprint.psd1") `
            -LogRoot (Join-Path $TestDrive "live-fingerprint-logs")
        $module = Get-Module CodexReviewLoop
        $initial = & $module {
            param($path)
            Get-ReviewLoopExecutionFingerprint -ConfigPath $path
        } $profilePath

        $content = (Get-Content -Raw -LiteralPath $profilePath).
            Replace("CleanPassesRequired = 2", "CleanPassesRequired = 5").
            Replace("MaxReviewCycles = 6", "MaxReviewCycles = 24").
            Replace("LessonsLearnedCommitThreshold = 6", "LessonsLearnedCommitThreshold = 9").
            Replace("ReviewAfterLessonsLearnedCommit = `$false", "ReviewAfterLessonsLearnedCommit = `$true").
            Replace("MaxFixAttempts = 2", "MaxFixAttempts = 7").
            Replace("Mode = 'Fail'", "Mode = 'RestoreAll'").
            Replace("AutoCommit = `$true", "AutoCommit = `$false").
            Replace(
                'CommitMessagePrefix = "Test Review Loop"',
                'CommitMessagePrefix = "Reloaded"')
        Set-Content -LiteralPath $profilePath -Value $content -Encoding UTF8
        $liveChanged = & $module {
            param($path)
            Get-ReviewLoopExecutionFingerprint -ConfigPath $path
        } $profilePath
        $liveChanged | Should Be $initial

        $content = $content.Replace(
            'ReviewBase = "HEAD"',
            'ReviewBase = "HEAD^"')
        Set-Content -LiteralPath $profilePath -Value $content -Encoding UTF8
        $executionChanged = & $module {
            param($path)
            Get-ReviewLoopExecutionFingerprint -ConfigPath $path
        } $profilePath
        $executionChanged | Should Not Be $initial
    }

    It "fingerprints effective ReviewerInstructions and ignores a shadowed profile value" {
        $profilePath = New-TestConfig `
            -Path (Join-Path $TestDrive "reviewer-instructions-fingerprint.psd1") `
            -LogRoot (Join-Path $TestDrive "reviewer-instructions-fingerprint-logs")
        $module = Get-Module CodexReviewLoop
        $profileInitial = & $module {
            param($path)
            Get-ReviewLoopExecutionFingerprint -ConfigPath $path
        } $profilePath
        $override = "CLI `"override`"`nPrüfung"
        $overrideInitial = & $module {
            param($path, $value)
            Get-ReviewLoopExecutionFingerprint `
                -ConfigPath $path -ReviewerInstructions $value
        } $profilePath $override

        $content = (Get-Content -Raw -LiteralPath $profilePath).Replace(
            'ReviewerInstructions = ""',
            'ReviewerInstructions = "profile changed"')
        Set-Content -LiteralPath $profilePath -Value $content -Encoding UTF8
        $profileChanged = & $module {
            param($path)
            Get-ReviewLoopExecutionFingerprint -ConfigPath $path
        } $profilePath
        $sameOverride = & $module {
            param($path, $value)
            Get-ReviewLoopExecutionFingerprint `
                -ConfigPath $path -ReviewerInstructions $value
        } $profilePath $override
        $differentOverride = & $module {
            param($path)
            Get-ReviewLoopExecutionFingerprint `
                -ConfigPath $path -ReviewerInstructions "different"
        } $profilePath

        $profileChanged | Should Not Be $profileInitial
        $sameOverride | Should Be $overrideInitial
        $differentOverride | Should Not Be $overrideInitial
    }

    It "persists and reads state" {
        $path = Join-Path $TestDrive "state.json"
        Write-ReviewLoopState -Path $path -State $state | Out-Null
        (Read-ReviewLoopState -Path $path).RunId | Should Be $state.RunId
    }

    It "adds lessons-learned state to an older checkpoint" {
        $state.PSObject.Properties.Remove("ActiveFindingSource")
        $state.PSObject.Properties.Remove("LessonsLearned")
        $state.PSObject.Properties.Remove("ActiveHostGateRecovery")
        $path = Join-Path $TestDrive "old-lessons-state.json"
        Write-ReviewLoopState -Path $path -State $state | Out-Null

        $reloaded = Read-ReviewLoopState -Path $path

        $reloaded.ActiveFindingSource | Should Be ""
        $reloaded.LessonsLearned.Status | Should Be "pending"
        $reloaded.LessonsLearned.Attempt | Should Be 0
        $reloaded.LessonsLearned.ReviewAfterCommit | Should Be $false
        $reloaded.ActiveHostGateRecovery | Should BeNullOrEmpty
    }

    It "reconstructs durable role sessions from an older checkpoint" {
        $state.PSObject.Properties.Remove("RoleSessions")
        $state.RoleCalls = @(
            [pscustomobject]@{ Role = "Architect"; Success = $true; ThreadId = "architect-old" },
            [pscustomobject]@{ Role = "Reviewer"; Success = $true; ThreadId = "reviewer-thread" },
            [pscustomobject]@{ Role = "Architect"; Success = $true; ThreadId = "architect-current" },
            [pscustomobject]@{ Role = "Verifier"; Success = $false; ThreadId = "verifier-failed" },
            [pscustomobject]@{ Role = "Fixer"; Success = $true; ThreadId = "fixer-current" }
        )
        $path = Join-Path $TestDrive "old-role-sessions-state.json"
        Write-ReviewLoopState -Path $path -State $state | Out-Null

        $reloaded = Read-ReviewLoopState -Path $path

        $reloaded.RoleSessions.Architect | Should Be "architect-current"
        $reloaded.RoleSessions.Fixer | Should Be "fixer-current"
        @($reloaded.RoleSessions.PSObject.Properties.Name -eq "Verifier").Count | Should Be 0
        @($reloaded.RoleSessions.PSObject.Properties.Name -eq "Reviewer").Count | Should Be 0
    }

    It "qualifies lessons learned only at the threshold with tracked root instructions" {
        $config = @{ LessonsLearnedCommitThreshold = 0 }
        $module = Get-Module CodexReviewLoop
        $disabled = & $module {
            param($profile, $loopState, $repository)
            Get-ReviewLoopLessonsLearnedEligibility `
                -Config $profile -State $loopState -RepoPath $repository
        } $config $state $repo
        $disabled.Eligible | Should Be $false
        $disabled.Reason | Should Match "disabled"

        $config.LessonsLearnedCommitThreshold = 6
        $state.LoopCommits = 1..5 | ForEach-Object { "commit-$_" }
        $below = & $module {
            param($profile, $loopState, $repository)
            Get-ReviewLoopLessonsLearnedEligibility `
                -Config $profile -State $loopState -RepoPath $repository
        } $config $state $repo
        $below.Eligible | Should Be $false
        $below.Reason | Should Match "5 of 6"

        Set-Content -LiteralPath (Join-Path $repo "AGENTS.md") -Value "untracked"
        $state.LoopCommits = 1..6 | ForEach-Object { "commit-$_" }
        $untracked = & $module {
            param($profile, $loopState, $repository)
            Get-ReviewLoopLessonsLearnedEligibility `
                -Config $profile -State $loopState -RepoPath $repository
        } $config $state $repo
        $untracked.Eligible | Should Be $false
        $untracked.Reason | Should Match "not tracked"

        & git -C $repo add AGENTS.md
        & git -C $repo commit -q -m "add repository instructions"
        $tracked = & $module {
            param($profile, $loopState, $repository)
            Get-ReviewLoopLessonsLearnedEligibility `
                -Config $profile -State $loopState -RepoPath $repository
        } $config $state $repo
        $tracked.Eligible | Should Be $true

        $state.LoopCommits += "commit-7"
        $above = & $module {
            param($profile, $loopState, $repository)
            Get-ReviewLoopLessonsLearnedEligibility `
                -Config $profile -State $loopState -RepoPath $repository
        } $config $state $repo
        $above.Eligible | Should Be $true
    }

    It "reconstructs verified commits for a legacy checkpoint" {
        foreach ($value in @("one", "two")) {
            Set-Content -LiteralPath (Join-Path $repo "README.txt") -Value $value
            & git -C $repo add README.txt
            & git -C $repo commit -q -m "change $value"
        }
        $state.CurrentHead = & git -C $repo rev-parse HEAD
        $state.PSObject.Properties.Remove("LoopCommits")
        $state.PSObject.Properties.Remove("LoopCommitsInitialized")
        $path = Join-Path $TestDrive "legacy-state.json"
        Write-ReviewLoopState -Path $path -State $state | Out-Null
        $legacy = Read-ReviewLoopState -Path $path

        & (Get-Module CodexReviewLoop) {
            param($loopState, $statePath, $repository)
            Initialize-ReviewLoopCommitHistory `
                -State $loopState -StatePath $statePath -RepoPath $repository
        } $legacy $path $repo

        $reloaded = Read-ReviewLoopState -Path $path
        $expected = @(& git -C $repo rev-list --reverse --first-parent `
            "$($state.StartHead)..$($state.CurrentHead)")
        @($reloaded.LoopCommits) | Should Be $expected
        $reloaded.LoopCommitsInitialized | Should Be $true
    }

    It "deduplicates verified commit registration" {
        $commit = & git -C $repo rev-parse HEAD
        & (Get-Module CodexReviewLoop) {
            param($loopState, $sha)
            Add-ReviewLoopVerifiedCommit -State $loopState -Commit $sha
            Add-ReviewLoopVerifiedCommit -State $loopState -Commit $sha.ToUpperInvariant()
        } $state $commit

        @($state.LoopCommits) | Should Be @($commit)
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

Describe "Fake Codex integration" -Tags @("Process") {
    BeforeEach {
        & (Get-Module CodexReviewLoop) {
            $script:ReviewLoopRetryDelayOverride = { param([int]$seconds) }
        }
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
        & (Get-Module CodexReviewLoop) { $script:ReviewLoopRetryDelayOverride = $null }
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
        $call = Invoke-CodexCliRole -Role Test -RepoPath $repo.FullName -Model model -Thinking low -Prompt p -LogRoot $logRoot -SchemaPath (Join-Path $root "schemas\architecture-advice-v2.schema.json") -CodexPath $fakeCodex
        $call.Success | Should Be $true
    }

    It "captures the thread id" {
        $call = Invoke-CodexCliRole -Role Test -RepoPath $repo.FullName -Model model -Thinking low -Prompt p -LogRoot $logRoot -CodexPath $fakeCodex
        $call.ThreadId | Should Be "fake-thread-123"
    }

    It "uses one Architect session for advice and assessment while native reviews stay fresh" {
        $repoPath = New-TestRepo $repo.FullName
        $configPath = New-TestConfig `
            -Path (Join-Path $TestDrive "role-sessions.psd1") `
            -LogRoot $logRoot
        $statePath = Join-Path $logRoot "role-sessions-state.json"
        $planPath = Join-Path $TestDrive "role-sessions-invocations.json"
        Set-Content -LiteralPath $planPath -Value (@(
            @{ threadId = "architect-thread" },
            @{ threadId = "architect-thread" },
            @{ threadId = "architect-thread" },
            @{ threadId = "architect-thread" },
            @{},
            @{}
        ) | ConvertTo-Json -Depth 10) -Encoding UTF8
        $env:CODEX_REVIEW_LOOP_FAKE_INVOCATION_SEQUENCE = $planPath

        & (Get-Module CodexReviewLoop) {
            param($profilePath, $repository, $runRoot, $checkpointPath, $fakePath)
            $config = Import-PowerShellDataFile -LiteralPath $profilePath
            $config["__ExecutionFingerprint"] = "role-session-fingerprint"
            $head = & git -C $repository rev-parse HEAD
            $state = New-ReviewLoopState `
                -RepoPath $repository -ReviewBase HEAD -ReviewBaseCommit $head `
                -ExecutionFingerprint "role-session-fingerprint" -Speed standard `
                -RunRoot $runRoot
            Write-ReviewLoopState -Path $checkpointPath -State $state | Out-Null

            foreach ($call in @(
                @{ Role = "Architect"; Schema = "architecture-advice-v2.schema.json"; Id = "architect-advice-1" },
                @{ Role = "Architect"; Schema = "architecture-assessment-v1.schema.json"; Id = "architect-assess-1" },
                @{ Role = "Architect"; Schema = "architecture-advice-v2.schema.json"; Id = "architect-advice-2" },
                @{ Role = "Architect"; Schema = "architecture-assessment-v1.schema.json"; Id = "architect-assess-2" }
            )) {
                Invoke-ConfiguredCodexRole `
                    -Config $config -Role $call.Role -RepoPath $repository -Speed standard `
                    -Prompt "current task" -LogRoot $runRoot -SchemaName $call.Schema `
                    -CodexPath $fakePath -CallId $call.Id -State $state -StatePath $checkpointPath |
                    Out-Null
            }
            foreach ($id in @("review-1", "review-2")) {
                Invoke-ConfiguredCodexRole `
                    -Config $config -Role "Reviewer" -RepoPath $repository -Speed standard `
                    -Prompt "" -LogRoot $runRoot -Mode Review -ReviewBase HEAD `
                    -CodexPath $fakePath -CallId $id -State $state -StatePath $checkpointPath |
                    Out-Null
            }
        } $configPath $repoPath $logRoot $statePath $fakeCodex

        $records = @(Get-Content -LiteralPath $env:CODEX_REVIEW_LOOP_FAKE_LOG |
            ForEach-Object { $_ | ConvertFrom-Json })
        @($records.callKind) | Should Be @("exec", "resume", "resume", "resume", "review", "review")
        $records[1].resumeThreadId | Should Be "architect-thread"
        $records[2].resumeThreadId | Should Be "architect-thread"
        $records[3].resumeThreadId | Should Be "architect-thread"
        $reloaded = Read-ReviewLoopState -Path $statePath
        $reloaded.RoleSessions.Architect | Should Be "architect-thread"
        @($reloaded.RoleSessions.PSObject.Properties.Name -eq "Verifier").Count | Should Be 0
        @($reloaded.RoleSessions.PSObject.Properties.Name -eq "Reviewer").Count | Should Be 0
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

    It "writes role prompts to stdin as BOM-less UTF-8" {
        $inputEncoding = & (Get-Module CodexReviewLoop) {
            param($executable)
            (New-CodexProcessStartInfo -CodexExecutable $executable -Arguments @("exec")).StandardInputEncoding
        } $fakeCodex
        $inputEncoding.WebName | Should Be "utf-8"
        @($inputEncoding.GetPreamble()).Count | Should Be 0

        $prompt = "Umlaute: äöü · punctuation: – · emoji: 🔎"
        Invoke-CodexCliRole -Role Test -RepoPath $repo.FullName -Model model -Thinking low `
            -Prompt $prompt -LogRoot $logRoot -CodexPath $fakeCodex | Out-Null
        $record = Get-Content -LiteralPath $env:CODEX_REVIEW_LOOP_FAKE_LOG |
            Select-Object -Last 1 | ConvertFrom-Json
        $record.prompt | Should Be $prompt
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
        $call = Invoke-CodexCliRole -Role Test -RepoPath $repo.FullName -Model model -Thinking low -Prompt p -LogRoot $logRoot -SchemaPath (Join-Path $root "schemas\architecture-advice-v2.schema.json") -CodexPath $fakeCodex
        $call.Success | Should Be $false
        $call.FailureKind | Should Be "invalid_structured_output"
    }

    It "writes JSONL and result logs" {
        $call = Invoke-CodexCliRole -Role Test -RepoPath $repo.FullName -Model model -Thinking low -Prompt p -LogRoot $logRoot -CodexPath $fakeCodex
        Test-Path $call.JsonlPath | Should Be $true
        Test-Path $call.ResultPath | Should Be $true
    }
}

Describe "Live terminal and streaming process observation" -Tags @("Process") {
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

    It "writes one durable Ctrl+C interruption record to terminal.log" {
        $transcript = Join-Path $caseRoot "ctrl-c-terminal.log"
        $module = Get-Module CodexReviewLoop
        & $module {
            param($path)
            Initialize-ReviewLoopConsole `
                -OutputMode compact -HeartbeatSeconds 0 -ColorMode Never `
                -HostOutputEnabled $false -TranscriptPath $path
            [CodexReviewLoopCancellationLog]::Record()
            [CodexReviewLoopCancellationLog]::Record()
        } $transcript

        $text = Get-Content -Raw -LiteralPath $transcript
        @([regex]::Matches(
            $text,
            "Review Loop interrupted by Ctrl\+C; checkpoint preserved\.")).Count |
            Should Be 1
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
                Invoke-ConfiguredCodexRole -Config $profile -Role Architect -RepoPath $repository `
                    -Speed standard -Prompt review -LogRoot $runRoot `
                    -SchemaName "architecture-advice-v2.schema.json" -CallId "architect-01" `
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
            $checkpoint.ActiveRoleCall.CallId | Should Be "architect-01"
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

Describe "Schemas, prompts, and CLI-only invariants" -Tags @("Static", "FullLocal") {
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
        @("architect.md", "architect-assessment.md", "fixer.md", "lessons-learned.md") |
            ForEach-Object { Test-Path (Join-Path $root "prompts\$_") | Should Be $true }
    }

    It "accepts free architecture advice and an unavailable targeted test" {
        '{"schemaVersion":"2.0","summary":"Any approach.","approach":"Replace the subsystem if useful.","steps":[],"considerations":[]}' |
            Test-Json -SchemaFile (Join-Path $root "schemas\architecture-advice-v2.schema.json") |
            Should Be $true
        '{"schemaVersion":"3.0","summary":"Done.","targetedTest":{"available":false,"executable":"","arguments":[]}}' |
            Test-Json -SchemaFile (Join-Path $root "schemas\fixer-result-v3.schema.json") |
            Should Be $true
        '{"schemaVersion":"3.0","summary":"Done.","targetedTest":{"available":true,"executable":"dotnet","arguments":["test","tests/Project.Tests.csproj"]}}' |
            Test-Json -SchemaFile (Join-Path $root "schemas\fixer-result-v3.schema.json") |
            Should Be $true
        (Test-Throws {
            '{"schemaVersion":"3.0","summary":"Ambiguous.","targetedTest":{"available":true,"filePath":"tests/Project.Tests.csproj","arguments":[]}}' |
                Test-Json -SchemaFile (Join-Path $root "schemas\fixer-result-v3.schema.json") `
                    -ErrorAction Stop
        }) | Should Be $true
        '{"schemaVersion":"1.0","accept":true,"summary":"Accepted.","feedback":[],"commitMessage":{"subject":"Fix the defect","rationale":"Keep the result correct.","changes":["Update the implementation."]}}' |
            Test-Json -SchemaFile (Join-Path $root "schemas\architecture-assessment-v1.schema.json") |
            Should Be $true
        '{"schemaVersion":"1.0","accept":false,"summary":"Continue.","feedback":[],"commitMessage":{"subject":"","rationale":"","changes":[]}}' |
            Test-Json -SchemaFile (Join-Path $root "schemas\architecture-assessment-v1.schema.json") |
            Should Be $true
        (Test-Throws {
            '{"schemaVersion":"1.0","accept":true,"summary":"Accepted.","feedback":[],"commitMessage":{"subject":"Fix the defect","rationale":"Keep the result correct."}}' |
                Test-Json -SchemaFile (Join-Path $root "schemas\architecture-assessment-v1.schema.json") `
                    -ErrorAction Stop
        }) | Should Be $true
        $retrospectiveSchema = Join-Path $root "schemas\lessons-learned-v2.schema.json"
        @'
{"schemaVersion":"2.0","summary":"Improve the reusable guidance set.","diagnosis":{"summary":"Serial findings exposed one reusable gap.","causes":[{"title":"The invariant was discovered incrementally","category":"repository_guidance","explanation":"Existing guidance did not make the decision boundary actionable.","evidence":["cycles 2 and 3 found sibling defects"]},{"title":"Fresh reviews broadened the inspection","category":"review_loop_process","explanation":"A later review found a sibling after a clean result.","evidence":["cycles 4 and 5 shared a HEAD"]},{"title":"The patch grew during correction","category":"change_scope","explanation":"Corrections expanded the reviewed surface.","evidence":["loopGrowth added two files"]}],"guidanceAssessment":[{"target":"AGENTS.md","assessment":"ineffective","explanation":"The rule existed but was not actionable at the decision point.","evidence":["the same class of issue recurred"]}]},"changes":[{"title":"Add a durable boundary","action":"add","surface":"agents_md","targets":["AGENTS.md"],"outcome":"Make the reusable invariant actionable.","rationale":"Different changes cross the same boundary.","futureUse":"Applies to future parser and persistence work.","evidence":["cycles 2 and 3"]},{"title":"Repair an existing workflow","action":"update","surface":"repository_skill","targets":[".agents/skills/validate/SKILL.md"],"outcome":"Move the check to the decision point.","rationale":"The existing procedure was too late.","futureUse":"Applies whenever the workflow runs.","evidence":["cycle 3"]},{"title":"Merge overlapping rules","action":"consolidate","surface":"agents_md","targets":["AGENTS.md","src/AGENTS.md"],"outcome":"Keep one authoritative rule.","rationale":"Two rules competed.","futureUse":"Reduces ambiguity for all source changes.","evidence":["guidance assessment"]},{"title":"Remove obsolete workflow detail","action":"delete","surface":"repository_skill","targets":[".agents/skills/validate/references/obsolete.md"],"outcome":"Remove misleading detail.","rationale":"The procedure no longer exists.","futureUse":"Prevents future branches following stale steps.","evidence":["current skill inspection"]}]}
'@ | Test-Json -SchemaFile $retrospectiveSchema | Should Be $true
        '{"schemaVersion":"2.0","summary":"Diagnosis only.","diagnosis":{"summary":"The cause belongs to the review process.","causes":[{"title":"Review breadth changed","category":"review_loop_process","explanation":"Later inspection found more.","evidence":["same HEAD"]}],"guidanceAssessment":[]},"changes":[]}' |
            Test-Json -SchemaFile $retrospectiveSchema | Should Be $true
        foreach ($invalid in @(
            '{"schemaVersion":"2.0","summary":"Bad action.","diagnosis":{"summary":"x","causes":[],"guidanceAssessment":[]},"changes":[{"title":"Bad","action":"replace","surface":"agents_md","targets":["AGENTS.md"],"outcome":"x","rationale":"x","futureUse":"x","evidence":[]}]}',
            '{"schemaVersion":"2.0","summary":"Bad surface.","diagnosis":{"summary":"x","causes":[],"guidanceAssessment":[]},"changes":[{"title":"Bad","action":"add","surface":"plugin","targets":["AGENTS.md"],"outcome":"x","rationale":"x","futureUse":"x","evidence":[]}]}',
            '{"schemaVersion":"2.0","summary":"Incomplete.","diagnosis":{"summary":"x","causes":[],"guidanceAssessment":[]},"changes":[{"title":"Bad","action":"add","surface":"agents_md","targets":["AGENTS.md"],"outcome":"x","rationale":"x","evidence":[]}]}'
        )) {
            (Test-Throws {
                $invalid | Test-Json -SchemaFile $retrospectiveSchema -ErrorAction Stop
            }) | Should Be $true
        }
    }

    It "keeps the complete free-role prompts stable" {
        $expected = @{
            "architect.md" = @'
Role:
You are the architect responsible for the coherence and integrity of this software system as a whole. You maintain a system-wide perspective across the current findings, repository context, and recent history, and understand individual findings as evidence about the system's design and invariants.

Goal:
Decide how the current findings should be handled so the resulting repository state is coherent, complete, durable, and unlikely to reveal further defects arising from the same changes or underlying concerns. Correctness, security, maintainability, and appropriate scope take precedence. Use your independent judgment to choose the solution.

Current findings:
{{FINDINGS}}

Repository context:
{{REPOSITORY_CONTEXT}}

Recent history:
{{HISTORY}}

Workflow:
Current findings → Architect advice [current role] → Fixer changes → Architect assessment. Rejections return to the Fixer; the orchestrator runs tests and host gates and commits accepted changes.

Result:
Return your advice in the supplied structured format.
'@
            "fixer.md" = @'
Role:
You are the fixer for the current findings.

Goal:
Use your judgment to improve the repository in response to the findings and architectural advice.

Current findings:
{{FINDINGS}}

Architectural advice:
{{ARCHITECT_ADVICE}}

Previous feedback:
{{FEEDBACK}}

Workflow:
Current findings → Architect advice → Fixer changes [current role] → Architect assessment. Rejections return to the Fixer; the orchestrator runs tests and host gates and commits accepted changes.

Targeted test:
`targetedTest.executable` is the program started by the orchestrator, for example `dotnet`, `pwsh`, or a repository wrapper. Project, script, test, and filter values belong in `targetedTest.arguments`; for `dotnet test`, `dotnet` is the executable and `test` is the first argument.

Result:
Return your work summary and targeted-test information in the supplied structured format.
'@
            "architect-assessment.md" = @'
Role:
You are the architect assessing the current solution in the same thread that produced the architectural advice.

Goal:
Decide whether the current repository state is a satisfactory, coherent response to the findings. Assess the result against the findings and repository state, not by whether the Fixer followed your earlier advice. A better deviation may be accepted.

Current findings:
{{FINDINGS}}

Earlier architectural advice:
{{ARCHITECT_ADVICE}}

Fixer result and targeted-test execution:
{{FIXER_RESULT}}

Workflow:
Current findings → Architect advice → Fixer changes → Architect assessment [current role]. Rejections return to the Fixer; the orchestrator runs tests and host gates and commits accepted changes.

Commit message:
When accepting, propose a solution-oriented subject, a brief rationale, and the key changes. Keep the subject concise, ideally within 72 characters before the configured prefix, and follow the repository's established language and style when clear. Leave test and host-gate evidence, Git trailers, and authorship out; the orchestrator adds verified evidence.

When requesting changes, return an empty subject, an empty rationale, and an empty changes list.

Result:
Return your decision, feedback, and commit-message proposal in the supplied structured format.
'@
        }
        foreach ($name in $expected.Keys) {
            $actual = (Get-Content -Raw -LiteralPath (Join-Path $root "prompts\$name")).
                Replace("`r`n", "`n").TrimEnd()
            $actual | Should Be $expected[$name].Replace("`r`n", "`n").TrimEnd()
        }
    }

    It "replaces only placeholders from the original prompt template" {
        $values = @{
            FINDINGS = 'Finding contains {{DIFF}}.'
            ARCHITECT_ADVICE = 'Advice contains {{ROOT}}.'
            FIXER_RESULT = 'Generated code contains {{heading}}.'
        }
        $rendered = & (Get-Module CodexReviewLoop) {
            param($promptValues)
            Get-ReviewLoopPrompt -Name "architect-assessment.md" -Values $promptValues
        } $values

        $rendered | Should Match ([regex]::Escape("Finding contains {{DIFF}}."))
        $rendered | Should Match ([regex]::Escape("Generated code contains {{heading}}."))
    }

    It "reports missing original prompt placeholders by name" {
        $message = ""
        try {
            & (Get-Module CodexReviewLoop) {
                Get-ReviewLoopPrompt -Name "architect-assessment.md" -Values @{
                    FINDINGS = "findings"
                    ARCHITECT_ADVICE = "advice"
                }
            } | Out-Null
        }
        catch {
            $message = $_.Exception.Message
        }

        $message | Should Match "missing values"
        $message | Should Match "FIXER_RESULT"
    }

    It "keeps role instructions factual and leaves decisions to the models" {
        $prompts = @("architect.md", "architect-assessment.md", "fixer.md") | ForEach-Object {
            Get-Content -Raw -LiteralPath (Join-Path $root "prompts\$_")
        }
        $prompts = $prompts -join "`n"
        $prompts | Should Not Match '(?i)\bmust\b|\bnever\b|fail closed|\bprefer\b|\bonly\b|smallest|bounded'
        $prompts | Should Match 'Use your judgment'
    }

    It "gives the Architect assessment the fixer result without requiring advice conformance" {
        $assessment = Get-Content -Raw -LiteralPath (Join-Path $root "prompts\architect-assessment.md")
        $assessment | Should Match 'Fixer result and targeted-test execution'
        $assessment | Should Match 'not by whether the Fixer followed your earlier advice'
        $assessment | Should Match 'A better deviation may be accepted'
    }

    It "keeps the lessons-learned prompt self-contained and read-only" {
        $prompt = Get-Content -Raw -LiteralPath (Join-Path $root "prompts\lessons-learned.md")
        $prompt | Should Match 'Do not modify files, the worktree, the index, Git refs, or repository state'
        $prompt | Should Match '\.agents/skills/<skill-name>/SKILL\.md'
        $prompt | Should Match 'Do not rely on any plugin, installed skill, network access'
        $prompt | Should Match 'Keep AGENTS\.md small and practical'
        $prompt | Should Match 'definition of done'
        $prompt | Should Match '\{\{LOOP_COMMITS\}\}'
        $prompt | Should Match '\{\{RUN_RETROSPECTIVE\}\}'
        $prompt | Should Match 'materially different future tasks and branches'
        $prompt | Should Match 'diagnosis.+does not justify a cross-repository guidance change'
        $prompt | Should Match 'task-specific architecture, product concepts, class and file inventories'
        $prompt | Should Match 'add`, `update`, `consolidate`, or `delete`'
    }

    It "keeps root AGENTS guidance practical and within the default context budget" {
        $instructionsPath = Join-Path $root "AGENTS.md"
        $instructions = Get-Content -Raw -LiteralPath $instructionsPath
        (Get-Item -LiteralPath $instructionsPath).Length | Should BeLessThan 16384
        foreach ($section in @(
            "Repository layout",
            "Development commands",
            "Engineering conventions",
            "Code Review Rules",
            "Definition of done"
        )) {
            $instructions | Should Match ([regex]::Escape("## $section"))
        }
    }

    It "gives each free role the shared workflow and marks its current position" {
        foreach ($name in @("architect.md", "architect-assessment.md", "fixer.md")) {
            $prompt = Get-Content -Raw -LiteralPath (Join-Path $root "prompts\$name")
            $prompt | Should Match 'Current findings.+Architect advice.+Fixer changes.+Architect assessment'
            $prompt | Should Match '\[current role\]'
            $prompt | Should Match 'orchestrator runs tests and host gates and commits accepted changes'
        }
        $fixer = Get-Content -Raw -LiteralPath (Join-Path $root "prompts\fixer.md")
        $fixer | Should Match 'targetedTest\.executable'
    }

    It "describes the deterministic orchestrator and each structured role handoff" {
        $instructions = & (Get-Module CodexReviewLoop) {
            $config = @{ HostGates = @() }
            [pscustomobject]@{
                Architect = Get-ReviewLoopOperationalInstructions -Role Architect -Config $config
                Fixer = Get-ReviewLoopOperationalInstructions -Role Fixer -Config $config
                ReviewClassifier = Get-ReviewLoopOperationalInstructions `
                    -Role ReviewClassifier -Config $config
                LessonsLearned = Get-ReviewLoopOperationalInstructions `
                    -Role LessonsLearned -Config $config
            }
        }

        foreach ($role in @(
            "Architect", "Fixer", "ReviewClassifier", "LessonsLearned"
        )) {
            $instructions.$role | Should Match 'orchestrator is deterministic PowerShell code, not an LLM'
            $instructions.$role | Should Match 'does not interpret prose as instructions'
            $instructions.$role | Should Match 'structured result fields'
        }
        $instructions.Architect | Should Match 'passed unchanged to the Fixer as advice'
        $instructions.Architect | Should Match 'orchestrator does not execute steps from architecture prose'
        $instructions.Architect | Should Match 'accept field selects the implemented workflow transition'
        $instructions.Architect | Should Match 'Rejection feedback is passed to the Fixer'
        $instructions.Fixer | Should Match 'owns worktree edits but not commits or Git refs'
        $instructions.Fixer | Should Match 'targetedTest fields are the interface'
        $instructions.ReviewClassifier | Should Match 'hasFindings field is the classification consumed by the orchestrator'
        $instructions.LessonsLearned | Should Match 'changes array is the only part of the retrospective'
        $instructions.LessonsLearned | Should Match 'complete diagnosis remains evidence for Architect advice and assessment'
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

Describe "Lessons-learned retrospective evidence" -Tags @("Fast", "FullLocal") {
    It "preserves chronological loop evidence while excluding raw diagnostics and prior analyses" {
        $repo = New-TestRepo (Join-Path $TestDrive "retrospective-evidence")
        $base = & git -C $repo rev-parse HEAD
        Set-Content -LiteralPath (Join-Path $repo "initial.txt") -Value "initial scope"
        & git -C $repo add -- initial.txt
        & git -C $repo commit -q -m "start reviewed work"
        $start = & git -C $repo rev-parse HEAD
        Set-Content -LiteralPath (Join-Path $repo "growth.txt") -Value "loop growth"
        & git -C $repo add -- growth.txt
        & git -C $repo commit -q -m "resolve serial finding"
        $current = & git -C $repo rev-parse HEAD

        $roleCalls = @(
            [pscustomobject]@{
                Role = "Reviewer"; CallId = "review-01"; Success = $true
                RepositoryHead = $start; FinalMessage = "No findings."
                JsonlPath = "secret-jsonl-marker"; ResultPath = "secret-result-marker"
                Usage = [pscustomobject]@{ reasoning = "secret-reasoning-marker" }
                Attempts = @("secret-attempt-marker")
            },
            [pscustomobject]@{
                Role = "Reviewer"; CallId = "review-02"; Success = $true
                RepositoryHead = $start
                FinalMessage = "Review comment:`n`n- [P2] Enforce the sibling invariant — src/A.cs:10`n  A related path remains incomplete."
            },
            [pscustomobject]@{
                Role = "Architect"; CallId = "C-test-c2-architect"; Success = $true
                StructuredResult = [pscustomobject]@{ summary = "Handle both sibling paths." }
            },
            [pscustomobject]@{
                Role = "Fixer"; CallId = "C-test-c2-fix-a1-c0"; Success = $true
                StructuredResult = [pscustomobject]@{ summary = "Updated the first path." }
            },
            [pscustomobject]@{
                Role = "Architect"; CallId = "C-test-c2-architect-assess-a1-c0"; Success = $true
                StructuredResult = [pscustomobject]@{
                    accept = $false; summary = "The sibling path is still open."
                    feedback = @("Cover the related path.")
                }
            },
            [pscustomobject]@{
                Role = "Fixer"; CallId = "C-test-c2-fix-a2-c0"; Success = $true
                StructuredResult = [pscustomobject]@{ summary = "Covered the sibling path." }
            },
            [pscustomobject]@{
                Role = "Fixer"; CallId = "C-test-c2-fix-a2-c1"; Success = $false
                FailureKind = "cli_error"; FailureReason = "secret-stderr-marker"
            },
            [pscustomobject]@{
                Role = "Verifier"; CallId = "C-test-c2-verify-a2-c1"; Success = $true
                StructuredResult = [pscustomobject]@{
                    accept = $true; summary = "Both paths are covered."; feedback = @()
                }
            },
            [pscustomobject]@{
                Role = "Reviewer"; CallId = "review-03"; Success = $true
                RepositoryHead = $current; FinalMessage = "No issues found."
            },
            [pscustomobject]@{
                Role = "LessonsLearned"; CallId = "lessons-learned-old"; Success = $true
                FinalMessage = "secret-old-analysis-marker"
                StructuredResult = [pscustomobject]@{ summary = "secret-old-result-marker" }
            }
        )
        $state = [pscustomobject]@{
            ReviewCycle = 3
            ReviewBaseCommit = $base
            StartHead = $start
            RoleCalls = $roleCalls
        }
        $ledger = [pscustomobject]@{
            Findings = @(
                [pscustomobject]@{
                    Title = "Sibling invariant remains incomplete"
                    Description = "The related path was discovered after a clean review."
                    Locations = @([pscustomobject]@{ path = "src/A.cs"; line = 10 })
                    FirstSeenReview = "review-02"
                    LastSeenReview = "review-02"
                    ResolutionCommit = $current
                },
                [pscustomobject]@{
                    Title = "Old retrospective result"
                    Description = "secret-old-finding-marker"
                    Locations = @()
                    FirstSeenReview = "lessons-learned-01"
                    LastSeenReview = "lessons-learned-01"
                    ResolutionCommit = ""
                }
            )
        }

        $evidence = & (Get-Module CodexReviewLoop) {
            param($runState, $runLedger, $repository, $head)
            Get-ReviewLoopRetrospectiveEvidence `
                -State $runState -Ledger $runLedger -RepoPath $repository -CurrentHead $head
        } $state $ledger $repo $current

        $evidence.counts.cycles | Should Be 3
        $evidence.counts.nativeReviews | Should Be 3
        $evidence.counts.cleanReviews | Should Be 2
        $evidence.counts.findingReviews | Should Be 1
        $evidence.counts.fixerCalls | Should Be 3
        $evidence.counts.architectRejections | Should Be 1
        $evidence.counts.technicalFailures | Should Be 1
        @($evidence.cycles | ForEach-Object { $_.cycle }) | Should Be @(1, 2, 3)
        $evidence.cycles[0].head | Should Be $evidence.cycles[1].head
        $evidence.cycles[0].reviewerResult | Should Be "clean"
        $evidence.cycles[1].reviewerResult | Should Be "finding"
        @($evidence.cycles[1].fixerAttempts).Count | Should Be 3
        @($evidence.cycles[1].architectAssessments).Count | Should Be 2
        @($evidence.cycles[1].resolutionCommits) | Should Be @($current)
        $evidence.diff.initial.files | Should Be 1
        $evidence.diff.initial.additions | Should Be 1
        $evidence.diff.loopGrowth.files | Should Be 1
        $evidence.diff.loopGrowth.additions | Should Be 1
        $evidence.diff.final.files | Should Be 2
        $evidence.diff.final.additions | Should Be 2
        $serialized = ConvertTo-Json -InputObject $evidence -Depth 30 -Compress
        foreach ($excluded in @(
            "secret-jsonl-marker",
            "secret-result-marker",
            "secret-reasoning-marker",
            "secret-attempt-marker",
            "secret-stderr-marker",
            "secret-old-analysis-marker",
            "secret-old-result-marker",
            "secret-old-finding-marker"
        )) {
            $serialized | Should Not Match ([regex]::Escape($excluded))
        }
    }
}

Describe "Native review classification" -Tags @("Fast", "FullLocal") {
    It "recognizes current one- and multi-finding Codex review blocks" {
        $texts = @(
            @"
Review comment:

- [P2] Normalize the value — C:\repo\src\A.cs:10-12
  The current value is unstable.
"@,
            @"
Full review comments:

- [P1] Preserve the cache key — C:\repo\src\A.cs:20-22
  The key changes unexpectedly.
- [P2] Validate the fallback — C:\repo\src\B.cs:30-31
  The fallback accepts invalid state.
"@
        )

        foreach ($text in $texts) {
            $classification = & (Get-Module CodexReviewLoop) {
                param($review)
                Get-ReviewLoopLocalReviewClassification -ReviewText $review
            } $text
            $classification.Classification | Should Be "finding"
        }
    }

    It "recognizes proven legacy finding signals" {
        $classification = & (Get-Module CodexReviewLoop) {
            Get-ReviewLoopLocalReviewClassification -ReviewText @"
Findings:
The cache invalidation should be fixed before merge.
"@
        }

        $classification.Classification | Should Be "finding"
    }

    It "recognizes established clean review language" {
        $texts = @(
            "No findings.",
            "I did not identify any clear, actionable correctness issues.",
            "Keine umsetzbaren Regressionen gefunden."
        )

        foreach ($text in $texts) {
            $classification = & (Get-Module CodexReviewLoop) {
                param($review)
                Get-ReviewLoopLocalReviewClassification -ReviewText $review
            } $text
            $classification.Classification | Should Be "clean"
        }
    }

    It "treats empty and explicit Reviewer failure output as invalid" {
        foreach ($text in @("", "Reviewer failed to output a response.")) {
            $classification = & (Get-Module CodexReviewLoop) {
                param($review)
                Get-ReviewLoopLocalReviewClassification -ReviewText $review
            } $text
            $classification.Classification | Should Be "invalid"
        }
    }

    It "gives finding signals precedence over clean language" {
        $classification = & (Get-Module CodexReviewLoop) {
            Get-ReviewLoopLocalReviewClassification -ReviewText @"
No findings were seen in the documentation.

Review comment:

- [P1] Preserve the transaction — C:\repo\src\Store.cs:40-42
  The transaction is committed too early.
"@
        }

        $classification.Classification | Should Be "finding"
    }

    It "leaves unusual prose for the ReviewClassifier" {
        $classification = & (Get-Module CodexReviewLoop) {
            Get-ReviewLoopLocalReviewClassification `
                -ReviewText "The patch appears internally consistent with the surrounding implementation."
        }

        $classification.Classification | Should Be "ambiguous"
    }
}

Describe "ReviewClassifier resources" -Tags @("Static", "FullLocal") {
    It "keeps the complete classifier prompt minimal and stable" {
        $actual = (Get-Content -Raw -LiteralPath (
            Join-Path $root "prompts\review-classifier.md")).Replace("`r`n", "`n").TrimEnd()
        $expected = @'
Role:
You classify the result of a completed Codex code review.

Goal:
Decide whether the review reports at least one finding.

Review output:
{{REVIEW_OUTPUT}}

Result:
Return the decision in the supplied structured format.
'@
        $actual | Should Be $expected.Replace("`r`n", "`n").TrimEnd()
    }

    It "defines only the version and boolean decision in its schema" {
        $schema = Get-Content -Raw -LiteralPath (
            Join-Path $root "schemas\review-classification-v1.schema.json") |
            ConvertFrom-Json

        @($schema.properties.PSObject.Properties.Name | Sort-Object) |
            Should Be @("hasFindings", "schemaVersion")
        @($schema.required | Sort-Object) |
            Should Be @("hasFindings", "schemaVersion")
        $schema.properties.hasFindings.type | Should Be "boolean"
        $schema.additionalProperties | Should Be $false
    }
}

Describe "End-to-end orchestration with fake Codex" -Tags @("Orchestration") {
    BeforeEach {
        Enable-InProcessCodexRoleCalls `
            -Module (Get-Module CodexReviewLoop) -HelperPath $inProcessCodex
        & (Get-Module CodexReviewLoop) {
            $script:ReviewLoopRetryDelayOverride = { param([int]$seconds) }
        }
        $testCase = New-EndToEndTestCase
        $repo = $testCase.Repo
        $caseRoot = $testCase.CaseRoot
        $configPath = $testCase.ConfigPath
    }

    AfterEach {
        Disable-InProcessCodexRoleCalls -Module (Get-Module CodexReviewLoop)
        & (Get-Module CodexReviewLoop) { $script:ReviewLoopRetryDelayOverride = $null }
        Clear-EndToEndTestCase
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

    It "changes speed on the same checkpoint when explicitly requested" {
        $checkpoint = New-TestActiveCheckpoint `
            -RepoPath $repo `
            -ConfigPath $configPath `
            -Speed fast
        Write-FakeResultSequence -Path $env:CODEX_REVIEW_LOOP_FAKE_RESULT_SEQUENCE -Results @(
            "No findings.",
            "No findings."
        )
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
        $state = Read-ReviewLoopState -Path $checkpoint.StatePath
        $records = Get-Content -LiteralPath $env:CODEX_REVIEW_LOOP_FAKE_LOG |
            ForEach-Object { $_ | ConvertFrom-Json }
        $terminal = Get-Content -Raw -LiteralPath (Join-Path $checkpoint.RunRoot "terminal.log")

        $exitCode | Should Be 0
        $result.Status | Should Be "completed"
        $result.StatePath | Should Be $checkpoint.StatePath
        $state.Speed | Should Be "standard"
        @($state.RoleCalls | Where-Object { [string]$_.Speed -ne "standard" }).Count |
            Should Be 0
        @($records | Where-Object {
            ($_.arguments -join " ") -notmatch 'service_tier=\\?"default'
        }).Count | Should Be 0
        $terminal | Should Match "Checkpoint speed changed: fast -> standard"
    }

    It "inherits a resumed checkpoint speed when the CLI option is omitted" {
        $checkpoint = New-TestActiveCheckpoint `
            -RepoPath $repo `
            -ConfigPath $configPath `
            -Speed fast
        Write-FakeResultSequence -Path $env:CODEX_REVIEW_LOOP_FAKE_RESULT_SEQUENCE -Results @(
            "No findings.",
            "No findings."
        )
        $entryPoint = Join-Path $root "codex-review-loop.ps1"
        $output = & pwsh -NoLogo -NoProfile -NonInteractive `
            -File $entryPoint `
            -RepoPath $repo `
            -ConfigPath $configPath `
            -CodexPath $fakeCodex `
            -HeartbeatSeconds 0 `
            -ColorMode Never `
            -Json 2>&1
        $exitCode = $LASTEXITCODE
        $text = $output -join "`n"
        $result = $text | ConvertFrom-Json
        $state = Read-ReviewLoopState -Path $checkpoint.StatePath
        $records = Get-Content -LiteralPath $env:CODEX_REVIEW_LOOP_FAKE_LOG |
            ForEach-Object { $_ | ConvertFrom-Json }

        $exitCode | Should Be 0
        $result.Status | Should Be "completed"
        $result.StatePath | Should Be $checkpoint.StatePath
        $state.Speed | Should Be "fast"
        @($state.RoleCalls | Where-Object { [string]$_.Speed -ne "fast" }).Count |
            Should Be 0
        @($records | Where-Object {
            ($_.arguments -join " ") -notmatch 'service_tier=\\?"fast'
        }).Count | Should Be 0
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
        $before = & git -C $repo rev-parse HEAD
        $content = (Get-Content -Raw -LiteralPath $configPath).
            Replace("CleanPassesRequired = 1", "CleanPassesRequired = 2")
        Set-Content -LiteralPath $configPath -Value $content -Encoding UTF8
        Write-FakeResultSequence -Path $env:CODEX_REVIEW_LOOP_FAKE_RESULT_SEQUENCE -Results @(
            '{"schemaVersion":"1.0","classification":"clean","summary":"clean","findings":[]}',
            '{"schemaVersion":"1.0","classification":"clean","summary":"clean","findings":[]}'
        )
        $result = Invoke-CodexReviewLoop -RepoPath $repo -ConfigPath $configPath -Speed standard -CodexPath $fakeCodex -NewRun
        $result.Status | Should Be "completed"
        $result.CleanPasses | Should Be 2
        $result.ReviewCycles | Should Be 2
        (& git -C $repo rev-parse HEAD) | Should Be $before
        (& git -C $repo status --porcelain) | Should BeNullOrEmpty
        $terminal = Get-Content -Raw -LiteralPath (Join-Path $result.RunRoot "terminal.log")
        $terminal | Should Match "Review cycle 1"
        $terminal | Should Match "Reviewer"
        $terminal | Should Match "Clean pass 2/2"
        $terminal | Should Match "Retrospective skipped: only 0 of 6 verified loop commits exist"
        $terminal | Should Match "Review Loop completed"
    }

    It "implements update, consolidation, and deletion through the normal workflow" {
        $configPath = New-TestConfig `
            -Path $configPath -LogRoot (Join-Path $caseRoot "logs") -WithHostGate
        $content = (Get-Content -Raw -LiteralPath $configPath).
            Replace("CleanPassesRequired = 2", "CleanPassesRequired = 1")
        Set-Content -LiteralPath $configPath -Value $content -Encoding UTF8
        $checkpoint = Enable-TestLessonsLearnedCheckpoint `
            -RepoPath $repo -ConfigPath $configPath -Speed standard
        $analysis = ConvertTo-Json -Compress -Depth 20 ([pscustomobject]@{
            schemaVersion = "2.0"
            summary = "Three net guidance changes are supported by the retrospective."
            diagnosis = [pscustomobject]@{
                summary = "Serial findings exposed ineffective and obsolete guidance."
                causes = @(
                    [pscustomobject]@{
                        title = "Guidance did not prevent sibling findings"
                        category = "repository_guidance"
                        explanation = "The existing workflow did not expose the invariant early."
                        evidence = @("Cycles 1 and 2 found related defects.")
                    },
                    [pscustomobject]@{
                        title = "Broader reviews extended discovery"
                        category = "review_loop_process"
                        explanation = "This remains a tool-process observation, not repository work."
                        evidence = @("A clean review preceded a later finding on one HEAD.")
                    }
                )
                guidanceAssessment = @([pscustomobject]@{
                    target = ".agents/skills/obsolete/SKILL.md"
                    assessment = "obsolete"
                    explanation = "The recorded workflow no longer applies."
                    evidence = @("Repository inspection found no current trigger.")
                })
            }
            changes = @(
                [pscustomobject]@{
                    title = "Update the verification invariant"
                    action = "update"
                    surface = "agents_md"
                    targets = @("AGENTS.md")
                    outcome = "Make the existing invariant actionable."
                    rationale = "The old wording did not guide the decision point."
                    futureUse = "Applies across future orchestration changes."
                    evidence = @("The six verified loop commits repeatedly changed orchestration state.")
                },
                [pscustomobject]@{
                    title = "Consolidate the repeatable review workflow"
                    action = "consolidate"
                    surface = "repository_skill"
                    targets = @(
                        ".agents/skills/review-loop-maintenance/SKILL.md",
                        ".agents/skills/obsolete/SKILL.md"
                    )
                    outcome = "Keep one current workflow."
                    rationale = "The procedures overlap."
                    futureUse = "Future maintenance tasks use one authoritative workflow."
                    evidence = @("verified loop change 6 completed the repeated workflow.")
                },
                [pscustomobject]@{
                    title = "Delete obsolete skill content"
                    action = "delete"
                    surface = "repository_skill"
                    targets = @(".agents/skills/obsolete/SKILL.md")
                    outcome = "Remove the obsolete workflow."
                    rationale = "It conflicts with the consolidated procedure."
                    futureUse = "Future branches cannot follow the stale path."
                    evidence = @("Repository inspection showed it was obsolete.")
                }
            )
        })
        $architecture = '{"schemaVersion":"2.0","summary":"Apply the three net guidance changes only.","approach":"Update, consolidate, and delete repository guidance.","steps":[],"considerations":[]}'
        $fixer = '{"schemaVersion":"3.0","summary":"Added repository guidance.","targetedTest":{"available":false,"executable":"","arguments":[]}}'
        $assessment = '{"schemaVersion":"1.0","accept":true,"summary":"The guidance matches the evidence.","feedback":[],"commitMessage":{"subject":"Capture review-loop lessons","rationale":"Preserve verified maintenance knowledge.","changes":["Update repository instructions.","Add a repository skill."]}}'
        $plans = @(
            [pscustomobject]@{ result = "No findings." },
            [pscustomobject]@{ result = $analysis },
            [pscustomobject]@{ result = $architecture },
            [pscustomobject]@{
                result = $fixer
                mutations = @(
                    [pscustomobject]@{
                        path = "AGENTS.md"
                        content = "# Repository instructions`n`nRun the repository gate after changing the loop.`n"
                    },
                    [pscustomobject]@{
                        path = ".agents/skills/review-loop-maintenance/SKILL.md"
                        content = "---`nname: review-loop-maintenance`ndescription: Maintain the review loop when orchestration changes.`n---`n`nRun the repository-owned verification gate.`n"
                    },
                    [pscustomobject]@{
                        path = ".agents/skills/obsolete/SKILL.md"
                        delete = $true
                    }
                )
            },
            [pscustomobject]@{ result = $assessment }
        )
        $planPath = Join-Path $caseRoot "lessons-workflow.json"
        Set-Content -LiteralPath $planPath `
            -Value (ConvertTo-Json -InputObject $plans -Depth 20) -Encoding UTF8
        $env:CODEX_REVIEW_LOOP_FAKE_INVOCATION_SEQUENCE = $planPath

        $result = Invoke-CodexReviewLoop `
            -RepoPath $repo -ConfigPath $configPath -Speed standard `
            -CodexPath $fakeCodex -HeartbeatSeconds 0 -ColorMode Never

        $result.Status | Should Be "completed"
        $result.ReviewCycles | Should Be 1
        $result.CleanPasses | Should Be 0
        (& git -C $repo status --porcelain) | Should BeNullOrEmpty
        Test-Path -LiteralPath (Join-Path $repo ".agents/skills/review-loop-maintenance/SKILL.md") |
            Should Be $true
        Test-Path -LiteralPath (Join-Path $repo ".agents/skills/obsolete/SKILL.md") |
            Should Be $false
        $state = Read-ReviewLoopState -Path $checkpoint.StatePath
        $state.LessonsLearned.Status | Should Be "completed"
        $state.LessonsLearned.Attempt | Should Be 1
        $state.LessonsLearned.ReviewAfterCommit | Should Be $false
        @($state.LoopCommits).Count | Should Be 7
        $state.ActiveFindingSource | Should Be ""
        $records = @(Get-Content -LiteralPath $env:CODEX_REVIEW_LOOP_FAKE_LOG |
            ForEach-Object { $_ | ConvertFrom-Json })
        $lessonsCalls = @($records | Where-Object {
            [System.IO.Path]::GetFileName([string]$_.schemaPath) -eq
                "lessons-learned-v2.schema.json"
        })
        $lessonsCalls.Count | Should Be 1
        $lessonsCalls[0].prompt | Should Match "Native review cycles completed: 1"
        $lessonsCalls[0].prompt | Should Match "verified loop change 6"
        $lessonsCalls[0].prompt | Should Match '"diff"'
        $architectCall = @($records | Where-Object {
            [System.IO.Path]::GetFileName([string]$_.schemaPath) -eq
                "architecture-advice-v2.schema.json"
        })[0]
        $architectCall.prompt | Should Match "repository_skill"
        $architectCall.prompt | Should Match "Broader reviews extended discovery"
        $assessmentCall = @($records | Where-Object {
            [System.IO.Path]::GetFileName([string]$_.schemaPath) -eq
                "architecture-assessment-v1.schema.json"
        })[0]
        $assessmentCall.prompt | Should Match "Broader reviews extended discovery"
        @((Read-ReviewLoopLedger -Path $checkpoint.LedgerPath).Findings).Count |
            Should Be 3
        @($records | Where-Object { $_.callKind -eq "review" }).Count | Should Be 1
        $terminal = Get-Content -Raw -LiteralPath (Join-Path $result.RunRoot "terminal.log")
        $terminal | Should Match "Retrospective triggered"
        $terminal | Should Match "guidance change\(s\)"
        $terminal | Should Match "Implementing 3 retrospective guidance change"
        $terminal | Should Match "Committed"
        $terminal | Should Match "final retrospective guidance change verified"
        $terminal | Should Not Match "Review cycle 2"
    }

}

Describe "End-to-end orchestration with fake Codex 2" -Tags @("Orchestration") {
    BeforeEach {
        Enable-InProcessCodexRoleCalls `
            -Module (Get-Module CodexReviewLoop) -HelperPath $inProcessCodex
        & (Get-Module CodexReviewLoop) {
            $script:ReviewLoopRetryDelayOverride = { param([int]$seconds) }
        }
        $testCase = New-EndToEndTestCase
        $repo = $testCase.Repo
        $caseRoot = $testCase.CaseRoot
        $configPath = $testCase.ConfigPath
    }

    AfterEach {
        Disable-InProcessCodexRoleCalls -Module (Get-Module CodexReviewLoop)
        & (Get-Module CodexReviewLoop) { $script:ReviewLoopRetryDelayOverride = $null }
        Clear-EndToEndTestCase
    }

    It "runs post-commit native reviews when explicitly configured" {
        $content = (Get-Content -Raw -LiteralPath $configPath).
            Replace("CleanPassesRequired = 2", "CleanPassesRequired = 1").
            Replace(
                "ReviewAfterLessonsLearnedCommit = `$false",
                "ReviewAfterLessonsLearnedCommit = `$true")
        Set-Content -LiteralPath $configPath -Value $content -Encoding UTF8
        $checkpoint = Enable-TestLessonsLearnedCheckpoint `
            -RepoPath $repo -ConfigPath $configPath -Speed standard
        $analysis = '{"schemaVersion":"2.0","summary":"One durable change.","diagnosis":{"summary":"The existing rule was ineffective.","causes":[{"title":"The invariant was missed","category":"repository_guidance","explanation":"The rule was not actionable.","evidence":["verified loop change 6"]}],"guidanceAssessment":[{"target":"AGENTS.md","assessment":"ineffective","explanation":"The wording did not guide the decision.","evidence":["verified loop change 6"]}]},"changes":[{"title":"Record the invariant","action":"update","surface":"agents_md","targets":["AGENTS.md"],"outcome":"Keep the verified invariant actionable.","rationale":"The run proves the gap.","futureUse":"Applies to future repository work.","evidence":["verified loop change 6"]}]}'
        $architecture = '{"schemaVersion":"2.0","summary":"Record it.","approach":"Update guidance.","steps":[],"considerations":[]}'
        $fixer = '{"schemaVersion":"3.0","summary":"Updated guidance.","targetedTest":{"available":false,"executable":"","arguments":[]}}'
        $assessment = '{"schemaVersion":"1.0","accept":true,"summary":"Accepted.","feedback":[],"commitMessage":{"subject":"Record the verified invariant","rationale":"Preserve the lesson.","changes":["Update repository guidance."]}}'
        $plans = @(
            [pscustomobject]@{ result = "No findings." },
            [pscustomobject]@{ result = $analysis },
            [pscustomobject]@{ result = $architecture },
            [pscustomobject]@{
                result = $fixer
                mutations = @([pscustomobject]@{
                    path = "AGENTS.md"
                    content = "# Repository instructions`n`nKeep the verified invariant.`n"
                })
            },
            [pscustomobject]@{ result = $assessment },
            [pscustomobject]@{ result = "No findings." }
        )
        $planPath = Join-Path $caseRoot "lessons-post-review-workflow.json"
        Set-Content -LiteralPath $planPath `
            -Value (ConvertTo-Json -InputObject $plans -Depth 20) -Encoding UTF8
        $env:CODEX_REVIEW_LOOP_FAKE_INVOCATION_SEQUENCE = $planPath

        $result = Invoke-CodexReviewLoop `
            -RepoPath $repo -ConfigPath $configPath -Speed standard `
            -CodexPath $fakeCodex -HeartbeatSeconds 0 -ColorMode Never

        $result.Status | Should Be "completed"
        $result.ReviewCycles | Should Be 2
        $result.CleanPasses | Should Be 1
        $state = Read-ReviewLoopState -Path $checkpoint.StatePath
        $state.LessonsLearned.Status | Should Be "completed"
        $state.LessonsLearned.ReviewAfterCommit | Should Be $true
        @($state.LoopCommits).Count | Should Be 7
        $records = @(Get-Content -LiteralPath $env:CODEX_REVIEW_LOOP_FAKE_LOG |
            ForEach-Object { $_ | ConvertFrom-Json })
        @($records | Where-Object { $_.callKind -eq "review" }).Count | Should Be 2
        $terminal = Get-Content -Raw -LiteralPath (Join-Path $result.RunRoot "terminal.log")
        $terminal | Should Match "Review cycle 2"
        $terminal | Should Match "Retrospective skipped: the lessons-learned phase already completed"
    }

    It "completes directly when fast retrospective analysis returns no guidance changes" {
        $content = (Get-Content -Raw -LiteralPath $configPath).
            Replace("CleanPassesRequired = 2", "CleanPassesRequired = 1")
        Set-Content -LiteralPath $configPath -Value $content -Encoding UTF8
        $checkpoint = Enable-TestLessonsLearnedCheckpoint `
            -RepoPath $repo -ConfigPath $configPath -Speed fast
        Write-FakeResultSequence -Path $env:CODEX_REVIEW_LOOP_FAKE_RESULT_SEQUENCE -Results @(
            "No findings.",
            '{"schemaVersion":"2.0","summary":"No durable guidance change is justified.","diagnosis":{"summary":"The run shows no transferable repository gap.","causes":[{"title":"Review breadth changed","category":"review_loop_process","explanation":"This is a process observation only.","evidence":["same HEAD"]}],"guidanceAssessment":[]},"changes":[]}'
        )

        $result = Invoke-CodexReviewLoop `
            -RepoPath $repo -ConfigPath $configPath -Speed fast `
            -CodexPath $fakeCodex -HeartbeatSeconds 0 -ColorMode Never

        $result.Status | Should Be "completed"
        $result.ReviewCycles | Should Be 1
        $state = Read-ReviewLoopState -Path $checkpoint.StatePath
        $state.LessonsLearned.Status | Should Be "completed"
        @($state.LoopCommits).Count | Should Be 6
        $records = @(Get-Content -LiteralPath $env:CODEX_REVIEW_LOOP_FAKE_LOG |
            ForEach-Object { $_ | ConvertFrom-Json })
        @($records | Where-Object {
            [System.IO.Path]::GetFileName([string]$_.schemaPath) -eq
                "lessons-learned-v2.schema.json" -and
            ($_.arguments -join " ") -match 'service_tier=\\?"?fast'
        }).Count | Should Be 1
        @($records | Where-Object {
            [System.IO.Path]::GetFileName([string]$_.schemaPath) -eq
                "architecture-advice-v2.schema.json"
        }).Count | Should Be 0
    }

    It "fails hard when lessons-learned analysis mutates the repository" {
        $content = (Get-Content -Raw -LiteralPath $configPath).
            Replace("CleanPassesRequired = 2", "CleanPassesRequired = 1")
        Set-Content -LiteralPath $configPath -Value $content -Encoding UTF8
        $checkpoint = Enable-TestLessonsLearnedCheckpoint `
            -RepoPath $repo -ConfigPath $configPath -Speed standard
        $env:CODEX_REVIEW_LOOP_FAKE_MUTATE_ON_SCHEMA =
            "lessons-learned-v2.schema.json"
        Write-FakeResultSequence -Path $env:CODEX_REVIEW_LOOP_FAKE_RESULT_SEQUENCE -Results @(
            "No findings.",
            '{"schemaVersion":"2.0","summary":"No changes.","diagnosis":{"summary":"No reusable gap.","causes":[],"guidanceAssessment":[]},"changes":[]}'
        )

        $result = Invoke-CodexReviewLoop `
            -RepoPath $repo -ConfigPath $configPath -Speed standard `
            -CodexPath $fakeCodex -HeartbeatSeconds 0 -ColorMode Never

        $result.Status | Should Be "failed"
        $result.Reason | Should Match "Read-only role 'LessonsLearned' changed"
        (Read-ReviewLoopState -Path $checkpoint.StatePath).LessonsLearned.Status |
            Should Be "analyzing"
    }

    It "resets the MaxReviewCycles counter when the same command resumes" {
        $content = (Get-Content -Raw -LiteralPath $configPath).
            Replace("CleanPassesRequired = 1", "CleanPassesRequired = 2").
            Replace("MaxReviewCycles = 6", "MaxReviewCycles = 1")
        Set-Content -LiteralPath $configPath -Value $content -Encoding UTF8
        Write-FakeResultSequence -Path $env:CODEX_REVIEW_LOOP_FAKE_RESULT_SEQUENCE -Results @(
            "No findings.",
            "No findings."
        )

        $limited = Invoke-CodexReviewLoop `
            -RepoPath $repo -ConfigPath $configPath -Speed standard `
            -CodexPath $fakeCodex -NewRun -HeartbeatSeconds 0 -ColorMode Never

        $limited.Status | Should Be "limit_reached"
        $limited.ExitCode | Should Be 4
        $limited.ReviewCycles | Should Be 1
        $limited.CleanPasses | Should Be 1
        $limited.Reason | Should Match "review-cycle limit 1"
        @((Read-ReviewLoopLedger -Path $limited.LedgerPath).Findings |
            Where-Object { $_.Status -eq "blocked" }).Count | Should Be 0

        $completed = Invoke-CodexReviewLoop `
            -RepoPath $repo -ConfigPath $configPath -Speed standard `
            -CodexPath $fakeCodex -HeartbeatSeconds 0 -ColorMode Never

        $completed.Status | Should Be "completed"
        $completed.ReviewCycles | Should Be 2
        $state = Read-ReviewLoopState -Path $completed.StatePath
        $state.ReviewCyclesThisInvocation | Should Be 1
        $state.CleanPasses | Should Be 2
    }

    It "resets the MaxReviewCycles counter after any script restart" {
        $content = (Get-Content -Raw -LiteralPath $configPath).
            Replace("CleanPassesRequired = 2", "CleanPassesRequired = 1").
            Replace("MaxReviewCycles = 6", "MaxReviewCycles = 1")
        Set-Content -LiteralPath $configPath -Value $content -Encoding UTF8
        $findingReview = "- [P1] restart budget defect at src/A.cs:10"
        $architecture = '{"schemaVersion":"2.0","summary":"Address it.","approach":"Improve the implementation.","steps":[],"considerations":[]}'
        $fixer = '{"schemaVersion":"3.0","summary":"Handled it.","targetedTest":{"available":false,"executable":"","arguments":[]}}'
        $assessment = '{"schemaVersion":"1.0","accept":true,"summary":"Accepted.","feedback":[],"commitMessage":{"subject":"Fix the restart budget defect","rationale":"Keep restart budgets independent.","changes":["Preserve the resumed review state."]}}'
        $plans = @(
            [pscustomobject]@{ result = $findingReview },
            [pscustomobject]@{
                exitCode = 1
                stderr = "Not logged in; login required"
            },
            [pscustomobject]@{ result = $architecture },
            [pscustomobject]@{ result = $fixer },
            [pscustomobject]@{ result = $assessment },
            [pscustomobject]@{ result = "No findings." }
        )
        $invocationPlanPath = Join-Path $caseRoot "restart-budget-invocations.json"
        Set-Content -LiteralPath $invocationPlanPath `
            -Value (ConvertTo-Json -InputObject $plans -Depth 20) -Encoding UTF8
        $env:CODEX_REVIEW_LOOP_FAKE_INVOCATION_SEQUENCE = $invocationPlanPath

        $failed = Invoke-CodexReviewLoop `
            -RepoPath $repo -ConfigPath $configPath -Speed standard `
            -CodexPath $fakeCodex -NewRun -HeartbeatSeconds 0 -ColorMode Never

        $failed.Status | Should Be "failed"
        (Read-ReviewLoopState -Path $failed.StatePath).ReviewCyclesThisInvocation |
            Should Be 1

        $completed = Invoke-CodexReviewLoop `
            -RepoPath $repo -ConfigPath $configPath -Speed standard `
            -CodexPath $fakeCodex -HeartbeatSeconds 0 -ColorMode Never

        $completed.Status | Should Be "completed"
        $completed.ReviewCycles | Should Be 2
        $state = Read-ReviewLoopState -Path $completed.StatePath
        $state.ReviewCyclesThisInvocation | Should Be 1
        @((Get-Content -LiteralPath $env:CODEX_REVIEW_LOOP_FAKE_LOG |
            ForEach-Object { $_ | ConvertFrom-Json }) |
            Where-Object { $_.callKind -eq "review" }).Count | Should Be 2
    }

    It "reloads live profile settings without stopping the active run" {
        $content = (Get-Content -Raw -LiteralPath $configPath).
            Replace("CleanPassesRequired = 1", "CleanPassesRequired = 2").
            Replace("MaxReviewCycles = 6", "MaxReviewCycles = 2")
        Set-Content -LiteralPath $configPath -Value $content -Encoding UTF8
        $findingReview = "- [P1] live reload defect at src/A.cs:10"
        $architecture = '{"schemaVersion":"2.0","summary":"Address the defect.","approach":"Update the affected behavior.","steps":["Change the implementation."],"considerations":[]}'
        $fixChanged = '{"schemaVersion":"3.0","summary":"Fixed the defect.","targetedTest":{"available":false,"executable":"","arguments":[]}}'
        $resolved = '{"schemaVersion":"1.0","accept":true,"summary":"The solution is acceptable.","feedback":[],"commitMessage":{"subject":"Fix the live reload defect","rationale":"Apply live settings at safe boundaries.","changes":["Reload the configured settings."]}}'
        $clean = "No findings."
        $plans = @(
            [pscustomobject]@{
                result = $findingReview
                profileMutation = [pscustomobject]@{
                    path = $configPath
                    replacements = @(
                        [pscustomobject]@{
                            old = "MaxReviewCycles = 2"
                            new = "MaxReviewCycles = 3"
                        }
                        [pscustomobject]@{
                            old = "InactivityTimeoutMinutes = 30"
                            new = "InactivityTimeoutMinutes = 47"
                        }
                        [pscustomobject]@{
                            old = 'CommitMessagePrefix = "Test Review Loop"'
                            new = 'CommitMessagePrefix = "Reloaded"'
                        }
                    )
                }
            },
            [pscustomobject]@{ result = $architecture },
            [pscustomobject]@{
                result = $fixChanged
                mutations = @([pscustomobject]@{
                    path = "live-reload.txt"
                    content = "verified live reload"
                })
            },
            [pscustomobject]@{ result = $resolved },
            [pscustomobject]@{ result = $clean },
            [pscustomobject]@{ result = $clean }
        )
        $invocationPlanPath = Join-Path $caseRoot "live-reload-invocations.json"
        Set-Content -LiteralPath $invocationPlanPath `
            -Value (ConvertTo-Json -InputObject $plans -Depth 20) -Encoding UTF8
        $env:CODEX_REVIEW_LOOP_FAKE_INVOCATION_SEQUENCE = $invocationPlanPath

        $result = Invoke-CodexReviewLoop `
            -RepoPath $repo -ConfigPath $configPath -Speed standard `
            -CodexPath $fakeCodex -NewRun -HeartbeatSeconds 0 -ColorMode Never

        $result.Status | Should Be "completed"
        $result.ReviewCycles | Should Be 3
        (& git -C $repo show -s --format=%s HEAD) | Should Match "^Reloaded:"
        $terminal = Get-Content -Raw -LiteralPath (Join-Path $result.RunRoot "terminal.log")
        $terminal | Should Match "Reloaded live profile settings"
        $terminal | Should Match "MaxReviewCycles: 2 -> 3"
        $terminal | Should Match "InactivityTimeoutMinutes: 30 -> 47"
        $terminal | Should Match "Review cycle 3"
        $terminal | Should Not Match "active profile changed"
    }

}

Describe "End-to-end orchestration with fake Codex 3" -Tags @("Orchestration") {
    BeforeEach {
        Enable-InProcessCodexRoleCalls `
            -Module (Get-Module CodexReviewLoop) -HelperPath $inProcessCodex
        & (Get-Module CodexReviewLoop) {
            $script:ReviewLoopRetryDelayOverride = { param([int]$seconds) }
        }
        $testCase = New-EndToEndTestCase
        $repo = $testCase.Repo
        $caseRoot = $testCase.CaseRoot
        $configPath = $testCase.ConfigPath
    }

    AfterEach {
        Disable-InProcessCodexRoleCalls -Module (Get-Module CodexReviewLoop)
        & (Get-Module CodexReviewLoop) { $script:ReviewLoopRetryDelayOverride = $null }
        Clear-EndToEndTestCase
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
        $result.CleanPasses | Should Be 1
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

    It "preserves partial fixer work without a thread and completes it in one fresh recovery" {
        $content = (Get-Content -Raw -LiteralPath $configPath).
            Replace("CleanPassesRequired = 2", "CleanPassesRequired = 1")
        Set-Content -LiteralPath $configPath -Value $content -Encoding UTF8
        $findingReview = "- [P1] partial recovery defect at src/A.cs:10"
        $architecture = '{"schemaVersion":"2.0","summary":"Address it.","approach":"Complete the implementation.","steps":[],"considerations":[]}'
        $fixed = '{"schemaVersion":"3.0","summary":"Completed the partial work.","targetedTest":{"available":false,"executable":"","arguments":[]}}'
        $accepted = '{"schemaVersion":"1.0","accept":true,"summary":"Accepted.","feedback":[],"commitMessage":{"subject":"Complete the interrupted fix","rationale":"Preserve completed work across restart.","changes":["Finish the recovered implementation."]}}'
        $plans = @(
            [pscustomobject]@{ result = $findingReview }
            [pscustomobject]@{ result = $architecture }
            [pscustomobject]@{
                emitThread = $false
                result = "not json"
                mutations = @([pscustomobject]@{
                    path = "partial-recovery.txt"
                    content = "partial"
                })
            }
            [pscustomobject]@{
                result = $fixed
                mutations = @([pscustomobject]@{
                    path = "partial-recovery.txt"
                    content = "complete"
                })
            }
            [pscustomobject]@{ result = $accepted }
            [pscustomobject]@{ result = "No findings." }
        )
        $invocationPlanPath = Join-Path $caseRoot "partial-recovery-invocations.json"
        Set-Content -LiteralPath $invocationPlanPath `
            -Value (ConvertTo-Json -InputObject $plans -Depth 20) -Encoding UTF8
        $env:CODEX_REVIEW_LOOP_FAKE_INVOCATION_SEQUENCE = $invocationPlanPath

        $result = Invoke-CodexReviewLoop `
            -RepoPath $repo -ConfigPath $configPath -Speed standard `
            -CodexPath $fakeCodex -NewRun -HeartbeatSeconds 0 -ColorMode Never

        $result.Status | Should Be "completed"
        (Get-Content -Raw -LiteralPath (Join-Path $repo "partial-recovery.txt")) |
            Should Match "complete"
        $ledger = Read-ReviewLoopLedger -Path $result.LedgerPath
        $ledger.Findings[0].FixAttempts | Should Be 1
        $state = Read-ReviewLoopState -Path $result.StatePath
        $state.PartialFixRecovery | Should BeNullOrEmpty
        @(Get-ChildItem -LiteralPath (Join-Path $result.RunRoot "blocked") `
            -Directory -Filter "*-partial-attempt-1").Count | Should Be 1
        $records = @(Get-Content -LiteralPath $env:CODEX_REVIEW_LOOP_FAKE_LOG |
            ForEach-Object { $_ | ConvertFrom-Json })
        $fixerRecords = @($records | Where-Object {
            [System.IO.Path]::GetFileName([string]$_.schemaPath) -eq
                "fixer-result-v3.schema.json"
        })
        $fixerRecords.Count | Should Be 2
        $fixerRecords[1].callKind | Should Be "exec"
        $fixerRecords[1].prompt | Should Match "previous Fixer process ended"
        (Get-Content -Raw -LiteralPath (Join-Path $result.RunRoot "terminal.log")) |
            Should Match "Partial Fixer work was preserved"
    }

    It "restores a failed partial-work recovery and returns to the native Reviewer" {
        $content = (Get-Content -Raw -LiteralPath $configPath).
            Replace("CleanPassesRequired = 2", "CleanPassesRequired = 1").
            Replace("MaxReviewCycles = 6", "MaxReviewCycles = 2")
        Set-Content -LiteralPath $configPath -Value $content -Encoding UTF8
        $findingReview = "- [P1] repeated partial recovery defect at src/A.cs:10"
        $architecture = '{"schemaVersion":"2.0","summary":"Address it.","approach":"Complete the implementation.","steps":[],"considerations":[]}'
        $fixed = '{"schemaVersion":"3.0","summary":"Applied a later clean fix.","targetedTest":{"available":false,"executable":"","arguments":[]}}'
        $accepted = '{"schemaVersion":"1.0","accept":true,"summary":"Accepted.","feedback":[],"commitMessage":{"subject":"Apply the recovered fix","rationale":"Retain the verified recovery result.","changes":["Complete the recovered implementation."]}}'
        $plans = @(
            [pscustomobject]@{ result = $findingReview }
            [pscustomobject]@{ result = $architecture }
            [pscustomobject]@{
                emitThread = $false
                result = "not json"
                mutations = @([pscustomobject]@{
                    path = "failed-partial.txt"
                    content = "partial"
                })
            }
            [pscustomobject]@{ result = "not json" }
            [pscustomobject]@{ result = "No findings." }
        )
        $invocationPlanPath = Join-Path $caseRoot "failed-partial-recovery-invocations.json"
        Set-Content -LiteralPath $invocationPlanPath `
            -Value (ConvertTo-Json -InputObject $plans -Depth 20) -Encoding UTF8
        $env:CODEX_REVIEW_LOOP_FAKE_INVOCATION_SEQUENCE = $invocationPlanPath

        $result = Invoke-CodexReviewLoop `
            -RepoPath $repo -ConfigPath $configPath -Speed standard `
            -CodexPath $fakeCodex -NewRun -HeartbeatSeconds 0 -ColorMode Never

        $result.Status | Should Be "completed"
        Test-Path -LiteralPath (Join-Path $repo "failed-partial.txt") | Should Be $false
        (& git -C $repo status --porcelain) | Should BeNullOrEmpty
        $records = @(Get-Content -LiteralPath $env:CODEX_REVIEW_LOOP_FAKE_LOG |
            ForEach-Object { $_ | ConvertFrom-Json })
        @($records | Where-Object { $_.callKind -eq "review" }).Count | Should Be 2
        @(Get-ChildItem -LiteralPath (Join-Path $result.RunRoot "blocked") `
            -Directory -Filter "*-restart-attempt-1").Count | Should Be 1
        $terminal = Get-Content -Raw -LiteralPath (Join-Path $result.RunRoot "terminal.log")
        $terminal | Should Match "fresh partial-work recovery Fixer also failed"
        $terminal | Should Match "Review cycle 2"
    }

    It "continues a preserved partial-work recovery after a script restart" {
        $content = (Get-Content -Raw -LiteralPath $configPath).
            Replace("CleanPassesRequired = 2", "CleanPassesRequired = 1")
        Set-Content -LiteralPath $configPath -Value $content -Encoding UTF8
        $checkpoint = New-TestActiveCheckpoint `
            -RepoPath $repo -ConfigPath $configPath -Speed standard
        $state = Read-ReviewLoopState -Path $checkpoint.StatePath
        $ledger = New-ReviewLoopLedger -RepoPath $repo
        Merge-ReviewLoopFindings -Ledger $ledger -Findings @((New-TestFinding)) `
            -ReviewId "review-01" -Head $state.CurrentHead | Out-Null
        $finding = $ledger.Findings[0]
        $finding.Status = "fixing"
        $finding.FixAttempts = 1
        $state.ReviewCycle = 1
        $state.ActiveClusterId = [string]$finding.ClusterId
        $state.ActiveFindingIds = @([string]$finding.Id)
        $state.ActiveReviewText = "- [P1] restart recovery defect at src/A.cs:10"
        $state.ActiveStrategy = [pscustomobject]@{
            schemaVersion = "2.0"
            summary = "Complete the existing work."
            approach = "Inspect and finish the current worktree."
            steps = @()
            considerations = @()
        }
        $state.LastFixerResult = [pscustomobject]@{
            Success = $false
            FailureKind = "unsafe_partial_mutation"
            FailureReason = "The process ended before returning a thread ID."
            Attempt = 1
            Correction = 1
        }
        Set-Content -LiteralPath (Join-Path $repo "restart-partial.txt") -Value "partial"
        & (Get-Module CodexReviewLoop) {
            param($loopState, $statePath, $ledgerValue, $ledgerPath, $repository, $runRoot)
            Write-ReviewLoopLedger -Path $ledgerPath -Ledger $ledgerValue | Out-Null
            Save-ReviewLoopPartialFixRecovery `
                -State $loopState -StatePath $statePath `
                -RepoPath $repository -RunRoot $runRoot `
                -Attempt 1 -FailureReason "interrupted" -Correction 1 | Out-Null
        } $state $checkpoint.StatePath $ledger $checkpoint.LedgerPath $repo $checkpoint.RunRoot

        $fixed = '{"schemaVersion":"3.0","summary":"Finished after restart.","targetedTest":{"available":false,"executable":"","arguments":[]}}'
        $accepted = '{"schemaVersion":"1.0","accept":true,"summary":"Accepted.","feedback":[],"commitMessage":{"subject":"Finish the restarted fix","rationale":"Complete the preserved work after restart.","changes":["Apply the remaining correction."]}}'
        $plans = @(
            [pscustomobject]@{
                result = $fixed
                mutations = @([pscustomobject]@{
                    path = "restart-partial.txt"
                    content = "complete"
                })
            }
            [pscustomobject]@{ result = $accepted }
            [pscustomobject]@{ result = "No findings." }
        )
        $invocationPlanPath = Join-Path $caseRoot "restart-recovery-invocations.json"
        Set-Content -LiteralPath $invocationPlanPath `
            -Value (ConvertTo-Json -InputObject $plans -Depth 20) -Encoding UTF8
        $env:CODEX_REVIEW_LOOP_FAKE_INVOCATION_SEQUENCE = $invocationPlanPath

        $result = Invoke-CodexReviewLoop `
            -RepoPath $repo -ConfigPath $configPath -Speed standard `
            -CodexPath $fakeCodex -HeartbeatSeconds 0 -ColorMode Never

        $result.Status | Should Be "completed"
        (Get-Content -Raw -LiteralPath (Join-Path $repo "restart-partial.txt")) |
            Should Match "complete"
        $resumed = Read-ReviewLoopState -Path $result.StatePath
        $resumed.PartialFixRecovery | Should BeNullOrEmpty
        $records = @(Get-Content -LiteralPath $env:CODEX_REVIEW_LOOP_FAKE_LOG |
            ForEach-Object { $_ | ConvertFrom-Json })
        $records[0].callKind | Should Be "exec"
        $records[0].prompt | Should Match "previous Fixer process ended"
    }

}

Describe "End-to-end orchestration with fake Codex 4" -Tags @("Orchestration") {
    BeforeEach {
        Enable-InProcessCodexRoleCalls `
            -Module (Get-Module CodexReviewLoop) -HelperPath $inProcessCodex
        & (Get-Module CodexReviewLoop) {
            $script:ReviewLoopRetryDelayOverride = { param([int]$seconds) }
        }
        $testCase = New-EndToEndTestCase
        $repo = $testCase.Repo
        $caseRoot = $testCase.CaseRoot
        $configPath = $testCase.ConfigPath
    }

    AfterEach {
        Disable-InProcessCodexRoleCalls -Module (Get-Module CodexReviewLoop)
        & (Get-Module CodexReviewLoop) { $script:ReviewLoopRetryDelayOverride = $null }
        Clear-EndToEndTestCase
    }

    It "uses the configured fixer-attempt budget and resumes the durable Fixer thread" {
        $configPath = New-TestConfig -Path $configPath `
            -LogRoot (Join-Path $caseRoot "logs") -WithHostGate `
            -CleanPassesRequired 1
        $content = (Get-Content -Raw -LiteralPath $configPath).
            Replace("MaxFixAttempts = 2", "MaxFixAttempts = 3")
        Set-Content -LiteralPath $configPath -Value $content -Encoding UTF8
        $env:CODEX_REVIEW_LOOP_FAKE_MUTATE_ON_SCHEMA = "fixer-result-v3.schema.json"
        $findingReview = "- [P1] cache defect at src/A.cs:10"
        $architecture = '{"schemaVersion":"2.0","summary":"Address the cache defect.","approach":"Update the affected cache behavior.","steps":[],"considerations":[]}'
        $fixChanged = '{"schemaVersion":"3.0","summary":"Updated the cache.","targetedTest":{"available":false,"executable":"","arguments":[]}}'
        $stillOpen = '{"schemaVersion":"1.0","accept":false,"summary":"The defect remains.","feedback":["Continue the fix."],"commitMessage":{"subject":"","rationale":"","changes":[]}}'
        $resolved = '{"schemaVersion":"1.0","accept":true,"summary":"The defect is resolved.","feedback":[],"commitMessage":{"subject":"Fix the cache defect","rationale":"Keep cache behavior consistent.","changes":["Update the affected cache path."]}}'
        Write-FakeResultSequence -Path $env:CODEX_REVIEW_LOOP_FAKE_RESULT_SEQUENCE -Results @(
            $findingReview,
            $architecture,
            $fixChanged, $stillOpen,
            $fixChanged, $stillOpen,
            $fixChanged, $resolved,
            'No findings.',
            'No findings.'
        )

        $result = Invoke-CodexReviewLoop -RepoPath $repo -ConfigPath $configPath -Speed standard -CodexPath $fakeCodex -NewRun
        $result.Status | Should Be "completed"
        $ledger = Read-ReviewLoopLedger -Path $result.LedgerPath
        $ledger.Findings[0].Status | Should Be "resolved"
        $ledger.Findings[0].FixAttempts | Should Be 3
        $records = Get-Content -LiteralPath $env:CODEX_REVIEW_LOOP_FAKE_LOG | ForEach-Object { $_ | ConvertFrom-Json }
        @($records | Where-Object {
            $_.callKind -eq "resume" -and
            [System.IO.Path]::GetFileName([string]$_.schemaPath) -eq "fixer-result-v3.schema.json"
        }).Count | Should Be 2
        $assessmentCalls = @($records | Where-Object {
            [System.IO.Path]::GetFileName([string]$_.schemaPath) -eq
                "architecture-assessment-v1.schema.json"
        })
        $assessmentCalls.Count | Should Be 3
        @($assessmentCalls | Where-Object { $_.callKind -ne "resume" }).Count | Should Be 0
        @($assessmentCalls.resumeThreadId | Select-Object -Unique).Count | Should Be 1
        @($records | Where-Object {
            [string]$_.schemaPath -match 'confirm|tie'
        }).Count | Should Be 0
        $terminal = Get-Content -Raw -LiteralPath (Join-Path $result.RunRoot "terminal.log")
        $terminal | Should Match "Finding-Cluster"
        $terminal | Should Match "Fixer · call 3 · resuming thread"
        $terminal | Should Match "Fixer: Updated the cache"
        $terminal | Should Match "Architect assessment: accepted"
        $terminal | Should Match "Host-Gate: fake gate"
        $terminal | Should Match "Committed"
    }

    It "starts a new native review round instead of blocking after MaxFixAttempts" {
        $content = (Get-Content -Raw -LiteralPath $configPath).
            Replace("MaxFixAttempts = 2", "MaxFixAttempts = 1")
        Set-Content -LiteralPath $configPath -Value $content -Encoding UTF8
        $findingReview = "- [P1] defect at src/A.cs:10"
        $architecture = '{"schemaVersion":"2.0","summary":"Address it.","approach":"Improve the implementation.","steps":[],"considerations":[]}'
        $fixChanged = '{"schemaVersion":"3.0","summary":"Changed the implementation.","targetedTest":{"available":false,"executable":"","arguments":[]}}'
        $reproduced = '{"schemaVersion":"1.0","accept":false,"summary":"Continue.","feedback":["Try another approach."],"commitMessage":{"subject":"","rationale":"","changes":[]}}'
        $resolved = '{"schemaVersion":"1.0","accept":true,"summary":"Accepted.","feedback":[],"commitMessage":{"subject":"Fix the reproduced defect","rationale":"Address the verified failure mode.","changes":["Apply the corrected implementation."]}}'
        $plans = @(
            [pscustomobject]@{ result = $findingReview },
            [pscustomobject]@{ result = $architecture },
            [pscustomobject]@{
                result = $fixChanged
                mutations = @([pscustomobject]@{ path = "fixed.txt"; content = "attempt one" })
            },
            [pscustomobject]@{ result = $reproduced },
            [pscustomobject]@{ result = $findingReview },
            [pscustomobject]@{ result = $architecture },
            [pscustomobject]@{
                result = $fixChanged
                mutations = @([pscustomobject]@{ path = "fixed.txt"; content = "attempt two" })
            },
            [pscustomobject]@{ result = $resolved },
            [pscustomobject]@{ result = "No findings." },
            [pscustomobject]@{ result = "No findings." }
        )
        $invocationPlanPath = Join-Path $caseRoot "rollback-invocations.json"
        Set-Content -LiteralPath $invocationPlanPath `
            -Value (ConvertTo-Json -InputObject $plans -Depth 20) -Encoding UTF8
        $env:CODEX_REVIEW_LOOP_FAKE_INVOCATION_SEQUENCE = $invocationPlanPath

        $result = Invoke-CodexReviewLoop `
            -RepoPath $repo -ConfigPath $configPath -Speed standard -CodexPath $fakeCodex -NewRun `
            -HeartbeatSeconds 0 -ColorMode Never

        $result.Status | Should Be "completed"
        (& git -C $repo status --porcelain) | Should BeNullOrEmpty
        (Get-Content -Raw -LiteralPath (Join-Path $repo "fixed.txt")) | Should Match "attempt two"
        $ledger = Read-ReviewLoopLedger -Path $result.LedgerPath
        @($ledger.Findings | Where-Object {
            $_.Status -eq "resolved" -and $_.FixAttempts -eq 1
        }).Count | Should Be 1
        @($ledger.Findings | Where-Object { $_.Status -eq "blocked" }).Count | Should Be 0
        $records = Get-Content -LiteralPath $env:CODEX_REVIEW_LOOP_FAKE_LOG | ForEach-Object { $_ | ConvertFrom-Json }
        @($records | Where-Object {
            [System.IO.Path]::GetFileName([string]$_.schemaPath) -eq "fixer-result-v3.schema.json" -and
            $_.callKind -eq "exec"
        }).Count | Should Be 1
        @($records | Where-Object {
            [System.IO.Path]::GetFileName([string]$_.schemaPath) -eq "fixer-result-v3.schema.json" -and
            $_.callKind -eq "resume"
        }).Count | Should Be 1
        @($records | Where-Object { $_.callKind -eq "review" }).Count | Should Be 3
        (Get-Content -Raw -LiteralPath (Join-Path $result.RunRoot "terminal.log")) |
            Should Match "restarting with the native Reviewer"
    }

    It "uses the live-configured Luna helper only for ambiguous clean output" {
        $content = (Get-Content -Raw -LiteralPath $configPath).
            Replace("CleanPassesRequired = 2", "CleanPassesRequired = 1")
        Set-Content -LiteralPath $configPath -Value $content -Encoding UTF8
        $ambiguousReview = "The patch appears internally consistent with its surrounding implementation."
        $plans = @(
            [pscustomobject]@{
                result = $ambiguousReview
                profileMutation = [pscustomobject]@{
                    path = $configPath
                    replacements = @([pscustomobject]@{
                        old = 'Reviewer = @{ Model = "fake"; Thinking = "high" }'
                        new = @'
Reviewer = @{ Model = "fake"; Thinking = "high" }
        ReviewClassifier = @{ Model = "classifier-live"; Thinking = "low" }
'@
                    })
                }
            },
            [pscustomobject]@{
                result = '{"schemaVersion":"1.0","hasFindings":false}'
            }
        )
        $invocationPlanPath = Join-Path $caseRoot "ambiguous-clean-invocations.json"
        Set-Content -LiteralPath $invocationPlanPath `
            -Value (ConvertTo-Json -InputObject $plans -Depth 20) -Encoding UTF8
        $env:CODEX_REVIEW_LOOP_FAKE_INVOCATION_SEQUENCE = $invocationPlanPath

        $result = Invoke-CodexReviewLoop `
            -RepoPath $repo -ConfigPath $configPath -Speed standard `
            -CodexPath $fakeCodex -NewRun -HeartbeatSeconds 0 -ColorMode Never

        $result.Status | Should Be "completed"
        $records = @(Get-Content -LiteralPath $env:CODEX_REVIEW_LOOP_FAKE_LOG |
            ForEach-Object { $_ | ConvertFrom-Json })
        $classifierCalls = @($records | Where-Object {
            [System.IO.Path]::GetFileName([string]$_.schemaPath) -eq
                "review-classification-v1.schema.json"
        })
        $classifierCalls.Count | Should Be 1
        (@($classifierCalls[0].arguments) -contains "classifier-live") |
            Should Be $true
        @($records | Where-Object {
            [System.IO.Path]::GetFileName([string]$_.schemaPath) -eq
                "architecture-advice-v2.schema.json"
        }).Count | Should Be 0
        (& git -C $repo status --porcelain) | Should BeNullOrEmpty
    }

    It "passes ambiguous finding output unchanged after Luna classifies it" {
        $content = (Get-Content -Raw -LiteralPath $configPath).
            Replace("CleanPassesRequired = 2", "CleanPassesRequired = 1")
        Set-Content -LiteralPath $configPath -Value $content -Encoding UTF8
        $ambiguousReview = "The cache lifetime changes when a caller repeats the operation."
        $architectureV2 = '{"schemaVersion":"2.0","summary":"Address it.","approach":"Improve the cache behavior.","steps":[],"considerations":[]}'
        $fixerV3 = '{"schemaVersion":"3.0","summary":"Applied the advice.","targetedTest":{"available":false,"executable":"","arguments":[]}}'
        $assessmentV1 = '{"schemaVersion":"1.0","accept":true,"summary":"Accepted.","feedback":[],"commitMessage":{"subject":"Fix the cache behavior","rationale":"Keep repeated operations consistent.","changes":["Apply the architecture advice."]}}'
        Write-FakeResultSequence -Path $env:CODEX_REVIEW_LOOP_FAKE_RESULT_SEQUENCE -Results @(
            $ambiguousReview,
            '{"schemaVersion":"1.0","hasFindings":true}',
            $architectureV2,
            $fixerV3,
            $assessmentV1,
            "No findings."
        )

        $result = Invoke-CodexReviewLoop `
            -RepoPath $repo -ConfigPath $configPath -Speed standard `
            -CodexPath $fakeCodex -NewRun -HeartbeatSeconds 0 -ColorMode Never

        $result.Status | Should Be "completed"
        $records = @(Get-Content -LiteralPath $env:CODEX_REVIEW_LOOP_FAKE_LOG |
            ForEach-Object { $_ | ConvertFrom-Json })
        @($records | Where-Object {
            [System.IO.Path]::GetFileName([string]$_.schemaPath) -eq
                "review-classification-v1.schema.json"
        }).Count | Should Be 1
        $architectCall = @($records | Where-Object {
            [System.IO.Path]::GetFileName([string]$_.schemaPath) -eq
                "architecture-advice-v2.schema.json"
        })[0]
        ([string]$architectCall.prompt).Replace("`r`n", "`n") |
            Should Match ([regex]::Escape($ambiguousReview))
    }

    It "stops on classifier failure and retries it without rerunning the Reviewer" {
        $content = (Get-Content -Raw -LiteralPath $configPath).
            Replace("CleanPassesRequired = 2", "CleanPassesRequired = 1")
        Set-Content -LiteralPath $configPath -Value $content -Encoding UTF8
        $plans = @(
            [pscustomobject]@{
                result = "The patch appears consistent with the surrounding code."
            },
            [pscustomobject]@{
                exitCode = 1
                stderr = "Not logged in; login required"
            },
            [pscustomobject]@{
                result = '{"schemaVersion":"1.0","hasFindings":false}'
            }
        )
        $invocationPlanPath = Join-Path $caseRoot "classifier-retry-invocations.json"
        Set-Content -LiteralPath $invocationPlanPath `
            -Value (ConvertTo-Json -InputObject $plans -Depth 20) -Encoding UTF8
        $env:CODEX_REVIEW_LOOP_FAKE_INVOCATION_SEQUENCE = $invocationPlanPath

        $failed = Invoke-CodexReviewLoop `
            -RepoPath $repo -ConfigPath $configPath -Speed standard `
            -CodexPath $fakeCodex -NewRun -HeartbeatSeconds 0 -ColorMode Never

        $failed.Status | Should Be "failed"
        $failed.Reason | Should Match "ReviewClassifier"
        $firstRecords = @(Get-Content -LiteralPath $env:CODEX_REVIEW_LOOP_FAKE_LOG |
            ForEach-Object { $_ | ConvertFrom-Json })
        @($firstRecords | Where-Object { $_.callKind -eq "review" }).Count | Should Be 1
        @($firstRecords | Where-Object {
            [System.IO.Path]::GetFileName([string]$_.schemaPath) -eq
                "architecture-advice-v2.schema.json"
        }).Count | Should Be 0

        $completed = Invoke-CodexReviewLoop `
            -RepoPath $repo -ConfigPath $configPath -Speed standard `
            -CodexPath $fakeCodex -HeartbeatSeconds 0 -ColorMode Never

        $completed.Status | Should Be "completed"
        $records = @(Get-Content -LiteralPath $env:CODEX_REVIEW_LOOP_FAKE_LOG |
            ForEach-Object { $_ | ConvertFrom-Json })
        @($records | Where-Object { $_.callKind -eq "review" }).Count | Should Be 1
        @($records | Where-Object {
            [System.IO.Path]::GetFileName([string]$_.schemaPath) -eq
                "review-classification-v1.schema.json"
        }).Count | Should Be 2
        @($records | Where-Object {
            [System.IO.Path]::GetFileName([string]$_.schemaPath) -eq
                "architecture-advice-v2.schema.json"
        }).Count | Should Be 0
    }

    It "retries the native Reviewer after an unusable successful response" {
        $content = (Get-Content -Raw -LiteralPath $configPath).
            Replace("CleanPassesRequired = 2", "CleanPassesRequired = 1")
        Set-Content -LiteralPath $configPath -Value $content -Encoding UTF8
        $plans = @(
            [pscustomobject]@{ result = "Reviewer failed to output a response." },
            [pscustomobject]@{ result = "No findings." }
        )
        $invocationPlanPath = Join-Path $caseRoot "empty-review-retry-invocations.json"
        Set-Content -LiteralPath $invocationPlanPath `
            -Value (ConvertTo-Json -InputObject $plans -Depth 20) -Encoding UTF8
        $env:CODEX_REVIEW_LOOP_FAKE_INVOCATION_SEQUENCE = $invocationPlanPath

        $failed = Invoke-CodexReviewLoop `
            -RepoPath $repo -ConfigPath $configPath -Speed standard `
            -CodexPath $fakeCodex -NewRun -HeartbeatSeconds 0 -ColorMode Never

        $failed.Status | Should Be "failed"
        $failed.Reason | Should Match "technical failure result"
        $stored = Read-ReviewLoopState -Path $failed.StatePath
        $reviewRecord = @($stored.RoleCalls | Where-Object {
            $_.Role -eq "Reviewer"
        })[0]
        $reviewRecord.Success | Should Be $false
        $reviewRecord.FailureKind | Should Be "invalid_output"

        $completed = Invoke-CodexReviewLoop `
            -RepoPath $repo -ConfigPath $configPath -Speed standard `
            -CodexPath $fakeCodex -HeartbeatSeconds 0 -ColorMode Never

        $completed.Status | Should Be "completed"
        $records = @(Get-Content -LiteralPath $env:CODEX_REVIEW_LOOP_FAKE_LOG |
            ForEach-Object { $_ | ConvertFrom-Json })
        @($records | Where-Object { $_.callKind -eq "review" }).Count | Should Be 2
    }

    It "passes native review output and architect advice forward without side roles" {
        $nativeReview = "- [P1] first defect at src/A.cs:10`n- [P2] second defect at src/B.cs:20"
        $architectureV2 = '{"schemaVersion":"2.0","summary":"Use one coherent change.","approach":"Change both affected paths together.","steps":["Update A.","Update B."],"considerations":["Keep the public behavior."]}'
        $fixerV3 = '{"schemaVersion":"3.0","summary":"Applied the advice.","targetedTest":{"available":false,"executable":"","arguments":[]}}'
        $assessmentV1 = '{"schemaVersion":"1.0","accept":true,"summary":"Accepted.","feedback":[],"commitMessage":{"subject":"Fix both affected paths","rationale":"Keep the related behavior coherent.","changes":["Update the first path.","Update the second path."]}}'
        Write-FakeResultSequence -Path $env:CODEX_REVIEW_LOOP_FAKE_RESULT_SEQUENCE -Results @(
            $nativeReview, $architectureV2, $fixerV3, $assessmentV1,
            'No findings.', 'No findings.'
        )

        $result = Invoke-CodexReviewLoop -RepoPath $repo -ConfigPath $configPath -Speed standard -CodexPath $fakeCodex -NewRun
        $result.Status | Should Be "completed"
        $records = Get-Content -LiteralPath $env:CODEX_REVIEW_LOOP_FAKE_LOG | ForEach-Object { $_ | ConvertFrom-Json }
        $architectCalls = @($records | Where-Object {
            [System.IO.Path]::GetFileName([string]$_.schemaPath) -eq "architecture-advice-v2.schema.json"
        })
        $architectCalls.Count | Should Be 1
        ([string]$architectCalls[0].prompt).Replace("`r`n", "`n") |
            Should Match ([regex]::Escape($nativeReview))
        $fixerCall = @($records | Where-Object {
            [System.IO.Path]::GetFileName([string]$_.schemaPath) -eq "fixer-result-v3.schema.json"
        })[0]
        [string]$fixerCall.prompt | Should Match ([regex]::Escape(
            '"approach":"Change both affected paths together."'))
        $assessmentCall = @($records | Where-Object {
            [System.IO.Path]::GetFileName([string]$_.schemaPath) -eq
                "architecture-assessment-v1.schema.json"
        })[0]
        $assessmentCall.callKind | Should Be "resume"
        $assessmentCall.resumeThreadId | Should Be "cluster-thread"
        [string]$assessmentCall.prompt | Should Match 'not by whether the Fixer followed your earlier advice'
        @($records | Where-Object {
            [string]$_.schemaPath -match 'trigger|critique|veto|tie'
        }).Count | Should Be 0
        @($records | Where-Object {
            [System.IO.Path]::GetFileName([string]$_.schemaPath) -eq
                "review-classification-v1.schema.json"
        }).Count | Should Be 0
    }

}
