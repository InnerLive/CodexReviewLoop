$scriptPath = Join-Path $PSScriptRoot "Invoke-CodexReviewLoop.ps1"
. $scriptPath

function New-TestGitRepository {
    param([string]$Path)

    New-Item -ItemType Directory -Path (Join-Path $Path "src") -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $Path "src/sample.cs"), "class Sample {}`n")
    & git -C $Path init --quiet
    & git -C $Path config user.email "review-loop-tests@example.invalid"
    & git -C $Path config user.name "Review Loop Tests"
    & git -C $Path config core.autocrlf false
    & git -C $Path add -- src/sample.cs
    & git -C $Path commit --quiet -m "Initial"
    if ($LASTEXITCODE -ne 0) {
        throw "Test-Repository konnte nicht initialisiert werden."
    }
}

function Write-TestJson {
    param([string]$Path, [object]$Value)
    [System.IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 30), [System.Text.UTF8Encoding]::new($false))
}

function Test-CommandThrows {
    param([scriptblock]$Action)

    try {
        $null = & $Action
        return $false
    } catch {
        return $true
    }
}

function New-TestFinding {
    param(
        [string]$Cause = "state_consistency",
        [string]$Path = "src/sample.cs",
        [string]$ComponentId = "Sample"
    )

    return [ordered]@{
        finding_id = "F01"
        title = "State is inconsistent"
        priority = "P2"
        cause_category = $Cause
        component = [ordered]@{ kind = "type"; id = $ComponentId }
        git_path = $Path
        line_start = 1
        line_end = 1
        invariant = "The state remains consistent."
        explanation = "The current branch violates the invariant."
        remediation = "Centralize the state transition."
    }
}

function New-TestReviewResult {
    param(
        [ValidateSet("clean", "finding")][string]$Classification = "finding",
        [object[]]$Findings = $null
    )

    if ($null -eq $Findings) {
        if ($Classification -eq "clean") {
            $Findings = [object[]]@()
        } else {
            $Findings = [object[]]@(New-TestFinding)
        }
    }
    return [ordered]@{
        schema_version = "codex_review_result_v1"
        classification = $Classification
        summary = if ($Classification -eq "clean") { "No findings." } else { "One actionable finding." }
        findings = @($Findings)
    }
}

function New-TestReviewRecord {
    param(
        [string]$Id,
        [string]$Epoch = "epoch-1",
        [string]$Cause = "state_consistency",
        [string]$Path = "src/sample.cs",
        [string]$Commit = ""
    )

    $finding = [PSCustomObject](New-TestFinding -Cause $Cause -Path $Path)
    $finding | Add-Member -NotePropertyName signature -NotePropertyValue (New-FindingSignature -Finding $finding)
    return [PSCustomObject]@{
        reviewId = $Id
        reviewHead = ("a" * 40)
        epochId = $Epoch
        classification = "finding"
        findings = @($finding)
        fixCommit = $Commit
        fixMode = if ($Commit) { "normal" } else { "" }
    }
}

function New-TestFixRecord {
    param(
        [string]$Commit,
        [string[]]$Paths = @("src/sample.cs"),
        [string]$Epoch = "epoch-1"
    )

    return [PSCustomObject]@{
        commitSha = $Commit
        gitPaths = $Paths
        mode = "normal"
        epochId = $Epoch
        reviewId = "review-$Commit"
    }
}

function New-TestArchitectureResult {
    param(
        [string[]]$GitPaths = @("src/sample.cs"),
        [string]$Scope = "component"
    )

    return [ordered]@{
        schema_version = "codex_review_architecture_v2"
        root_cause = "State transitions are enforced at multiple inconsistent boundaries."
        evidence = @("The same Git path produced another finding after a committed fix.")
        invariants = @([ordered]@{
            statement = "State transitions have one enforcement point."
            scenarios = @([ordered]@{
                dimension = "input state"
                members = @("valid", "invalid")
                required_behavior = "Both classes are handled deterministically."
            })
            verification = @([ordered]@{
                level = "unit"
                target = "Sample"
                test = "Exercise valid and invalid state."
                expected_result = "One enforcement path is used."
            })
        })
        strategy = [ordered]@{
            title = "Centralize state transitions"
            scope = $Scope
            approach = "Move enforcement to Sample."
            steps = @([ordered]@{
                git_paths = $GitPaths
                action = "Centralize the transition."
            })
            risks = @("A state transition may be missed during refactoring.")
            compatibility_plan = "Preserve the public behavior."
            rollback_plan = "Revert the architecture commit."
        }
        recommendation = [ordered]@{
            action = "approve_strategy"
            reason = "It addresses the repeated root cause."
        }
    }
}

function New-FakeCodexExecutable {
    param([string]$Directory)

    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    $fakePath = Join-Path $Directory "codex.ps1"
    $scriptText = @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$RemainingArguments)
$stdinText = @($input | ForEach-Object { [string]$_ }) -join "`n"
$outputPath = ""
$isNativeReview = $RemainingArguments -contains "review"
for ($index = 0; $index -lt $RemainingArguments.Count; $index++) {
    if ($RemainingArguments[$index] -eq "--output-last-message" -and $index + 1 -lt $RemainingArguments.Count) {
        $outputPath = $RemainingArguments[$index + 1]
    }
}
if (-not [string]::IsNullOrWhiteSpace($env:FAKE_CODEX_ARGUMENTS_PATH)) {
    [System.IO.File]::WriteAllLines($env:FAKE_CODEX_ARGUMENTS_PATH, $RemainingArguments)
}
if (-not [string]::IsNullOrWhiteSpace($env:FAKE_CODEX_STDIN_PATH)) {
    [System.IO.File]::WriteAllText($env:FAKE_CODEX_STDIN_PATH, $stdinText)
}
if ($isNativeReview -and -not [string]::IsNullOrWhiteSpace($env:FAKE_CODEX_NATIVE_ARGUMENTS_PATH)) {
    [System.IO.File]::WriteAllLines($env:FAKE_CODEX_NATIVE_ARGUMENTS_PATH, $RemainingArguments)
}
if ($isNativeReview -and -not [string]::IsNullOrWhiteSpace($env:FAKE_CODEX_REVIEW_REPO)) {
    [System.IO.File]::AppendAllText(
        (Join-Path $env:FAKE_CODEX_REVIEW_REPO "src/sample.cs"),
        "// reviewer mutation`n"
    )
    [System.IO.File]::WriteAllText(
        (Join-Path $env:FAKE_CODEX_REVIEW_REPO "reviewer-temp.txt"),
        "temporary reviewer output"
    )
}
$result = $env:FAKE_CODEX_RESULT
if ($isNativeReview -and -not [string]::IsNullOrWhiteSpace($env:FAKE_CODEX_NATIVE_RESULT)) {
    $result = $env:FAKE_CODEX_NATIVE_RESULT
}
if (-not [string]::IsNullOrWhiteSpace($env:FAKE_CODEX_COUNTER_PATH)) {
    [System.IO.File]::AppendAllText($env:FAKE_CODEX_COUNTER_PATH, "1")
}
if (-not [string]::IsNullOrWhiteSpace($env:FAKE_CODEX_EXIT_CODE)) {
    [Console]::Error.WriteLine($env:FAKE_CODEX_ERROR)
    exit [int]$env:FAKE_CODEX_EXIT_CODE
}
$invalidMarkerPath = "$($env:FAKE_CODEX_COUNTER_PATH).invalid-first"
if (
    -not $isNativeReview -and
    -not [string]::IsNullOrWhiteSpace($env:FAKE_CODEX_INVALID_FIRST) -and
    -not [System.IO.File]::Exists($invalidMarkerPath)
) {
    [System.IO.File]::WriteAllText($invalidMarkerPath, "1")
    $result = "{}"
}
if ([string]::IsNullOrWhiteSpace($outputPath)) {
    [Console]::Error.WriteLine("missing --output-last-message")
    exit 2
}
[System.IO.File]::WriteAllText($outputPath, $result, [System.Text.UTF8Encoding]::new($false))
'{"type":"thread.started","thread_id":"fake-thread"}'
'{"type":"turn.completed"}'
exit 0
'@
    [System.IO.File]::WriteAllText($fakePath, $scriptText, [System.Text.UTF8Encoding]::new($false))
    return $fakePath
}

Describe "Codex review result schema and host validation" {
    BeforeEach {
        $caseRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $repoPath = Join-Path $caseRoot "repo"
        New-Item -ItemType Directory -Path $repoPath -Force | Out-Null
        New-TestGitRepository -Path $repoPath
        $schemaPaths = Write-ReviewLoopSchemaFiles -LogRoot $caseRoot
    }

    It "accepts a valid clean result" {
        $resultPath = Join-Path $caseRoot "clean.json"
        Write-TestJson -Path $resultPath -Value (New-TestReviewResult -Classification clean)

        $result = Read-StructuredReviewResult -ResultPath $resultPath -SchemaPath $schemaPaths.Review -RepoPath $repoPath -ReviewBase HEAD

        $result.classification | Should Be "clean"
        @($result.findings).Count | Should Be 0
    }

    It "accepts and canonicalizes a valid finding" {
        $resultPath = Join-Path $caseRoot "finding.json"
        Write-TestJson -Path $resultPath -Value (New-TestReviewResult)

        $result = Read-StructuredReviewResult -ResultPath $resultPath -SchemaPath $schemaPaths.Review -RepoPath $repoPath -ReviewBase HEAD

        $result.findings[0].git_path | Should Be "src/sample.cs"
        $result.findings[0].signature | Should Be "codex_review_path_v2|src/sample.cs"
    }

    It "rejects additional fields" {
        $invalid = New-TestReviewResult -Classification clean
        $invalid["unexpected"] = $true
        $resultPath = Join-Path $caseRoot "additional.json"
        Write-TestJson -Path $resultPath -Value $invalid

        (Test-CommandThrows { Read-StructuredReviewResult -ResultPath $resultPath -SchemaPath $schemaPaths.Review -RepoPath $repoPath -ReviewBase HEAD }) | Should Be $true
    }

    It "rejects a clean classification containing findings" {
        $invalid = New-TestReviewResult -Classification clean -Findings @(New-TestFinding)
        $resultPath = Join-Path $caseRoot "cross-field.json"
        Write-TestJson -Path $resultPath -Value $invalid

        (Test-CommandThrows { Read-StructuredReviewResult -ResultPath $resultPath -SchemaPath $schemaPaths.Review -RepoPath $repoPath -ReviewBase HEAD }) | Should Be $true
    }

    It "rejects invalid line ranges" {
        $finding = New-TestFinding
        $finding.line_start = 3
        $finding.line_end = 2
        $resultPath = Join-Path $caseRoot "lines.json"
        Write-TestJson -Path $resultPath -Value (New-TestReviewResult -Findings @($finding))

        (Test-CommandThrows { Read-StructuredReviewResult -ResultPath $resultPath -SchemaPath $schemaPaths.Review -RepoPath $repoPath -ReviewBase HEAD }) | Should Be $true
    }

    It "rejects line ranges beyond the referenced file" {
        $finding = New-TestFinding
        $finding.line_start = 2
        $finding.line_end = 2
        $resultPath = Join-Path $caseRoot "line-outside-file.json"
        Write-TestJson -Path $resultPath -Value (New-TestReviewResult -Findings @($finding))

        (Test-CommandThrows { Read-StructuredReviewResult -ResultPath $resultPath -SchemaPath $schemaPaths.Review -RepoPath $repoPath -ReviewBase HEAD }) | Should Be $true
    }

    It "rejects absolute, traversal, backslash, and unknown paths" {
        foreach ($invalidPath in @("C:/repo/src/sample.cs", "../sample.cs", "src\sample.cs", "src/missing.cs")) {
            $resultPath = Join-Path $caseRoot (([guid]::NewGuid().ToString("N")) + ".json")
            Write-TestJson -Path $resultPath -Value (New-TestReviewResult -Findings @(New-TestFinding -Path $invalidPath))
            (Test-CommandThrows { Read-StructuredReviewResult -ResultPath $resultPath -SchemaPath $schemaPaths.Review -RepoPath $repoPath -ReviewBase HEAD }) | Should Be $true
        }
    }

    It "builds the repetition signature exclusively from the canonical Git path" {
        $first = [PSCustomObject](New-TestFinding)
        $second = [PSCustomObject](New-TestFinding -Cause other -ComponentId "DifferentComponent")
        $second.title = "Entirely different wording"
        $second.line_start = 50
        $second.line_end = 70
        $second.invariant = "Different prose"
        $second.explanation = "Different prose"

        (New-FindingSignature -Finding $first) | Should Be (New-FindingSignature -Finding $second)
        (New-FindingSignature -Finding $first) | Should Not Be (New-FindingSignature -Finding ([PSCustomObject](New-TestFinding -Path "src/other.cs")))
    }
}

Describe "Architecture path triggers" {
    It "triggers repeat_path on the second committed occurrence of the same path" {
        $prior = New-TestReviewRecord -Id "review-1" -Commit ("1" * 40)
        $current = New-TestReviewRecord -Id "review-2" -Cause other

        $trigger = Get-ArchitectureTrigger -CurrentReviewRecord $current -ReviewLedger @($prior, $current) -FixCommitRecords @() -RepeatThreshold 2 -HotspotFixThreshold 2

        ($trigger.triggerTypes -join ",") | Should Match "repeat_path"
        $trigger.schemaVersion | Should Be "codex_review_architecture_trigger_v2"
    }

    It "counts duplicate findings in one prior iteration only once" {
        $prior = New-TestReviewRecord -Id "review-1" -Commit ("1" * 40)
        $prior.findings = @($prior.findings[0], $prior.findings[0])
        $current = New-TestReviewRecord -Id "review-2"

        $trigger = Get-ArchitectureTrigger -CurrentReviewRecord $current -ReviewLedger @($prior, $current) -FixCommitRecords @() -RepeatThreshold 3 -HotspotFixThreshold 2

        $trigger | Should BeNullOrEmpty
    }

    It "includes the other category in path repetition" {
        $prior = New-TestReviewRecord -Id "review-1" -Cause other -Commit ("1" * 40)
        $current = New-TestReviewRecord -Id "review-2" -Cause other

        $trigger = Get-ArchitectureTrigger -CurrentReviewRecord $current -ReviewLedger @($prior, $current) -FixCommitRecords @() -RepeatThreshold 2 -HotspotFixThreshold 2

        ($trigger.triggerTypes -join ",") | Should Match "repeat_path"
    }

    It "triggers at the next finding after two fixes at the same hotspot" {
        $current = New-TestReviewRecord -Id "review-3" -Cause other
        $fixes = @(
            (New-TestFixRecord -Commit ("1" * 40)),
            (New-TestFixRecord -Commit ("2" * 40))
        )

        $trigger = Get-ArchitectureTrigger -CurrentReviewRecord $current -ReviewLedger @($current) -FixCommitRecords $fixes -RepeatThreshold 2 -HotspotFixThreshold 2

        ($trigger.triggerTypes -join ",") | Should Match "hotspot_fallback"
    }

    It "does not trigger from a count of unrelated fix commits" {
        $current = New-TestReviewRecord -Id "review-4" -Cause other -Path "src/other.cs"
        $fixes = @(
            (New-TestFixRecord -Commit ("1" * 40) -Paths @("src/a.cs")),
            (New-TestFixRecord -Commit ("2" * 40) -Paths @("src/b.cs")),
            (New-TestFixRecord -Commit ("3" * 40) -Paths @("src/c.cs"))
        )

        $trigger = Get-ArchitectureTrigger -CurrentReviewRecord $current -ReviewLedger @($current) -FixCommitRecords $fixes -RepeatThreshold 2 -HotspotFixThreshold 2

        $trigger | Should BeNullOrEmpty
    }

    It "does not trigger architecture work for a clean pass" {
        $current = [PSCustomObject]@{ classification = "clean" }

        $trigger = Get-ArchitectureTrigger -CurrentReviewRecord $current -ReviewLedger @() -FixCommitRecords @() -RepeatThreshold 2 -HotspotFixThreshold 2

        $trigger | Should BeNullOrEmpty
    }

    It "does not carry a repetition trigger across an architecture epoch" {
        $prior = New-TestReviewRecord -Id "review-old" -Epoch "epoch-old" -Commit ("1" * 40)
        $current = New-TestReviewRecord -Id "review-new" -Epoch "epoch-new"

        $trigger = Get-ArchitectureTrigger -CurrentReviewRecord $current -ReviewLedger @($prior, $current) -FixCommitRecords @() -RepeatThreshold 2 -HotspotFixThreshold 2

        $trigger | Should BeNullOrEmpty
    }

    It "replays the long P3-04 P3-05 and P3-08 hotspot patterns without review text" {
        foreach ($fixture in @(
            [PSCustomObject]@{ name = "P3-04"; count = 13; path = "src/validator.cs" },
            [PSCustomObject]@{ name = "P3-05"; count = 17; path = "src/state.cs" },
            [PSCustomObject]@{ name = "P3-08"; count = 14; path = "src/literal-validator.cs" }
        )) {
            $current = New-TestReviewRecord -Id "$($fixture.name)-next" -Cause other -Path $fixture.path
            $fixes = @()
            for ($index = 1; $index -le $fixture.count; $index++) {
                $fixes += New-TestFixRecord -Commit ($index.ToString("x40")) -Paths @($fixture.path)
            }
            $trigger = Get-ArchitectureTrigger -CurrentReviewRecord $current -ReviewLedger @($current) -FixCommitRecords $fixes -RepeatThreshold 2 -HotspotFixThreshold 2
            ($trigger.triggerTypes -join ",") | Should Match "hotspot_fallback"
        }
    }
}

Describe "Architecture safety and persistence helpers" {
    It "defaults the normal fixer to high thinking" {
        $FixerThinking | Should Be "high"
    }

    It "defaults architecture processing to Enforce with small local auto-apply" {
        $ArchitectureMode | Should Be "Enforce"
        [bool]$ArchitectureAutoApplyLocal | Should Be $true
        [bool]$ArchitectureAutoApplyAll | Should Be $false
        [bool]$DisableArchitectureAutoApplyLocal | Should Be $false
    }

    It "uses the flat v2 contract without cross-reference or unsupported schema keywords" {
        $repoPath = Join-Path $TestDrive "architecture-schema-repo"
        New-TestGitRepository -Path $repoPath
        $schemaPaths = Write-ReviewLoopSchemaFiles -LogRoot $TestDrive
        $report = New-TestArchitectureResult
        $resultPath = Join-Path $TestDrive "architecture-v2.json"
        Write-TestJson -Path $resultPath -Value $report

        $schemaText = Get-Content -LiteralPath $schemaPaths.Architecture -Raw
        $schemaText | Should Not Match '"uniqueItems"|"strategy_id"|"affected_components"|"verification_matrix"'
        $validated = Read-ValidatedArchitectureResult -ResultPath $resultPath -SchemaPath $schemaPaths.Architecture -RepoPath $repoPath -ReviewBase HEAD
        $validated.Report.schema_version | Should Be "codex_review_architecture_v2"
        $unsupportedSchema = Get-ArchitectureResultSchemaObject
        $unsupportedSchema.properties.strategy.properties.steps.uniqueItems = $true
        (Test-CommandThrows { Assert-CodexStructuredOutputSchemaCompatibility -Schema $unsupportedSchema -Context "architecture" }) | Should Be $true
    }

    It "renders architecture reports as readable text instead of raw JSON" {
        $report = [PSCustomObject](New-TestArchitectureResult)

        $rendered = ConvertTo-ArchitectureReportText -Report $report

        $rendered | Should Match "URSACHE"
        $rendered | Should Match "EVIDENZ"
        $rendered | Should Match "INVARIANTEN"
        $rendered | Should Match "STRATEGIE"
        $rendered | Should Match "KOMPATIBILITÄT"
        $rendered | Should Match "ROLLBACK"
        $rendered | Should Match "src/sample.cs"
        $rendered | Should Not Match '"schema_version"\s*:'
    }

    It "uses a dedicated semantic color style for architecture reports" {
        (Get-DisplayColor -Kind "Architecture") | Should Be ([ConsoleColor]::Cyan)

        $sectionStyle = Get-BoxLineStyle -Line "URSACHE" -Kind "Architecture" -LineRole "ArchitectureSection"
        $sectionStyle.ValueColor | Should Be ([ConsoleColor]::Cyan)
        $sectionStyle.BoldValue | Should Be $true

        $recommendationStyle = Get-BoxLineStyle -Line "Empfehlung: approve_strategy" -Kind "Architecture" -LineRole "ArchitectureRecommendation"
        $recommendationStyle.ValueColor | Should Be ([ConsoleColor]::Green)
        $recommendationStyle.BoldValue | Should Be $true

        $pathStyle = Get-BoxLineStyle -Line "   - src/sample.cs" -Kind "Architecture" -LineRole "ArchitecturePath"
        $pathStyle.ValueColor | Should Be ([ConsoleColor]::DarkYellow)

        $riskStyle = Get-BoxLineStyle -Line "- State may drift." -Kind "Architecture" -LineRole "ArchitectureRisk"
        $riskStyle.ValueColor | Should Be ([ConsoleColor]::Yellow)
    }

    It "renders the complete architecture box readably without colors" {
        $report = [PSCustomObject](New-TestArchitectureResult)
        $previousUseHostColor = $script:UseHostColor
        $previousUseAnsiColor = $script:UseAnsiColor
        $previousWriter = [Console]::Out
        $writer = New-Object System.IO.StringWriter
        try {
            $script:UseHostColor = $false
            $script:UseAnsiColor = $false
            [Console]::SetOut($writer)

            Write-ArchitectureReportBlock -Title "ARCHITEKTURBERICHT TEST" -Report $report
        } finally {
            [Console]::SetOut($previousWriter)
            $script:UseHostColor = $previousUseHostColor
            $script:UseAnsiColor = $previousUseAnsiColor
        }
        $output = $writer.ToString()

        $output | Should Match ([regex]::Escape("+ ARCHITEKTURBERICHT TEST "))
        $output | Should Match "URSACHE"
        $output | Should Match "INVARIANTEN"
        $output | Should Match "src/sample.cs"
        $output | Should Match "ROLLBACK"
        $output | Should Not Match ([regex]::Escape([string][char]27))
    }

    It "preserves hierarchy when long architecture paths wrap" {
        $pathLine = "   - src/Nora.KnowledgeMesh.Provider.OpenAiCompatible/OpenAiCompatibleChatCompletionTransportTests.cs"

        $wrapped = @(
            ConvertTo-WrappedConsoleLines `
                -Text $pathLine `
                -Width 48 `
                -ContinuationIndent 5 `
                -BreakOnPathSeparators
        )

        $wrapped.Count | Should BeGreaterThan 1
        foreach ($continuation in @($wrapped | Select-Object -Skip 1)) {
            $continuation.StartsWith("     ") | Should Be $true
        }
        ((@($wrapped) | ForEach-Object { $_.Trim() }) -join "") | Should Match "OpenAiCompatibleChatCompletionTransportTests.cs"
    }

    It "canonicalizes and deduplicates only strategy step paths" {
        $repoPath = Join-Path $TestDrive "architecture-path-repo"
        New-TestGitRepository -Path $repoPath
        $schemaPaths = Write-ReviewLoopSchemaFiles -LogRoot $TestDrive
        $report = New-TestArchitectureResult -GitPaths @("src/sample.cs", "src/sample.cs")
        $resultPath = Join-Path $TestDrive "architecture-paths.json"
        Write-TestJson -Path $resultPath -Value $report

        $validated = Read-ValidatedArchitectureResult -ResultPath $resultPath -SchemaPath $schemaPaths.Architecture -RepoPath $repoPath -ReviewBase HEAD
        @($validated.AllowedPaths).Count | Should Be 1
        $validated.AllowedPaths[0] | Should Be "src/sample.cs"
    }

    It "allows local auto-apply for up to three paths in one tracked folder" {
        $repoPath = Join-Path $TestDrive "architecture-auto-local-repo"
        New-TestGitRepository -Path $repoPath
        $report = [PSCustomObject](New-TestArchitectureResult -Scope local)

        $eligibility = Get-ArchitectureLocalAutoApplyEligibility -RepoPath $repoPath -ArchitectureReport $report -AllowedPaths @("src/sample.cs", "src/new-a.cs", "src/new-b.cs")

        $eligibility.Eligible | Should Be $true
    }

    It "automatically approves a small local strategy under the default policy" {
        $repoPath = Join-Path $TestDrive "architecture-default-auto-local-repo"
        New-TestGitRepository -Path $repoPath
        $schemaPaths = Write-ReviewLoopSchemaFiles -LogRoot $TestDrive
        $resultPath = Join-Path $TestDrive "default-auto-local.result.json"
        Write-TestJson -Path $resultPath -Value (New-TestArchitectureResult -Scope local)
        $validated = Read-ValidatedArchitectureResult -ResultPath $resultPath -SchemaPath $schemaPaths.Architecture -RepoPath $repoPath -ReviewBase HEAD
        $record = [PSCustomObject]@{
            expectedHead = (& git -C $repoPath rev-parse HEAD)
            reportSha256 = $validated.Sha256
            createdAt = "2026-07-21T12:00:00Z"
        }
        $ledger = New-Object System.Collections.Generic.List[object]
        $autoApplyEnabled = [bool]$ArchitectureAutoApplyLocal -and -not [bool]$DisableArchitectureAutoApplyLocal

        $resolution = Resolve-ArchitectureGateDecision `
            -RepoPath $repoPath `
            -ValidatedArchitecture $validated `
            -ArchitectureRecord $record `
            -AutoApplyLocal $autoApplyEnabled `
            -DecisionPath "" `
            -DecisionSchemaPath $schemaPaths.Decision `
            -DecisionLedger $ledger `
            -Interactive $false

        $resolution.Action | Should Be "approve_strategy"
        $resolution.RequiresHumanDecision | Should Be $false
        $resolution.Decision | Should BeNullOrEmpty
        $resolution.DecisionSource | Should Be "auto_local"
        $resolution.GateReason | Should BeNullOrEmpty
        $ledger.Count | Should Be 1
        $ledger[0].source | Should Be "auto_local"
    }

    It "automatically approves every validated strategy when explicitly enabled" {
        $repoPath = Join-Path $TestDrive "architecture-auto-all-repo"
        New-TestGitRepository -Path $repoPath
        $schemaPaths = Write-ReviewLoopSchemaFiles -LogRoot $TestDrive
        $resultPath = Join-Path $TestDrive "auto-all.result.json"
        Write-TestJson -Path $resultPath -Value (New-TestArchitectureResult -Scope cross_component)
        $validated = Read-ValidatedArchitectureResult -ResultPath $resultPath -SchemaPath $schemaPaths.Architecture -RepoPath $repoPath -ReviewBase HEAD
        $record = [PSCustomObject]@{
            expectedHead = (& git -C $repoPath rev-parse HEAD)
            reportSha256 = $validated.Sha256
            createdAt = "2026-07-21T12:00:00Z"
        }
        $ledger = New-Object System.Collections.Generic.List[object]

        $resolution = Resolve-ArchitectureGateDecision `
            -RepoPath $repoPath `
            -ValidatedArchitecture $validated `
            -ArchitectureRecord $record `
            -AutoApplyAll $true `
            -AutoApplyLocal $false `
            -DecisionPath "" `
            -DecisionSchemaPath $schemaPaths.Decision `
            -DecisionLedger $ledger `
            -Interactive $false

        $resolution.Action | Should Be "approve_strategy"
        $resolution.RequiresHumanDecision | Should Be $false
        $resolution.DecisionSource | Should Be "auto_all"
        $resolution.GateReason | Should BeNullOrEmpty
        $resolution.AutoApplyEligibility.Eligible | Should Be $false
        $ledger.Count | Should Be 1
        $ledger[0].source | Should Be "auto_all"
        $ledger[0].decidedBy | Should Be "ArchitectureAutoApplyAll"
        $ledger[0].note | Should Match "Jede validierte Architekturstrategie"
    }

    It "routes four paths, mixed folders, and repository-root paths to a human gate" {
        $repoPath = Join-Path $TestDrive "architecture-auto-human-repo"
        New-TestGitRepository -Path $repoPath
        $report = [PSCustomObject](New-TestArchitectureResult -Scope local)

        (Get-ArchitectureLocalAutoApplyEligibility -RepoPath $repoPath -ArchitectureReport $report -AllowedPaths @("src/a.cs", "src/b.cs", "src/c.cs", "src/d.cs")).Eligible | Should Be $false
        (Get-ArchitectureLocalAutoApplyEligibility -RepoPath $repoPath -ArchitectureReport $report -AllowedPaths @("src/a.cs", "tests/a.cs")).Eligible | Should Be $false
        (Get-ArchitectureLocalAutoApplyEligibility -RepoPath $repoPath -ArchitectureReport $report -AllowedPaths @("root.cs")).Eligible | Should Be $false
    }

    It "always builds a read-only architecture invocation without a sandbox bypass" {
        $arguments = Get-CodexReadOnlyArchitectureArgumentList -RepoPath "C:\repo"
        $joined = $arguments -join " "

        $joined | Should Match "--sandbox read-only"
        $joined | Should Not Match "dangerously-bypass"
        $arguments[0] | Should Be "exec"
    }

    It "computes a stable context digest and detects ledger changes" {
        $review = New-TestReviewRecord -Id "review-1" -Commit ("1" * 40)
        $fix = New-TestFixRecord -Commit ("1" * 40)

        $first = Get-ArchitectureContextDigest -ReviewLedger @($review) -FixCommitRecords @($fix) -EpochId "epoch-1"
        $second = Get-ArchitectureContextDigest -ReviewLedger @($review) -FixCommitRecords @($fix) -EpochId "epoch-1"
        $changed = Get-ArchitectureContextDigest -ReviewLedger @($review) -FixCommitRecords @($fix, (New-TestFixRecord -Commit ("2" * 40))) -EpochId "epoch-1"

        $first | Should Be $second
        $changed | Should Not Be $first
    }

    It "passes only trigger-referenced reviews, commits, paths, and current findings to analysis" {
        $current = New-TestReviewRecord -Id "review-current" -Path "src/sample.cs"
        $otherFinding = [PSCustomObject](New-TestFinding -Path "src/unrelated.cs")
        $otherFinding | Add-Member -NotePropertyName signature -NotePropertyValue (New-FindingSignature -Finding $otherFinding)
        $current.findings += $otherFinding
        $referenced = New-TestReviewRecord -Id "review-referenced" -Commit ("1" * 40)
        $unrelated = New-TestReviewRecord -Id "review-unrelated" -Path "src/unrelated.cs" -Commit ("2" * 40)
        $trigger = [PSCustomObject]@{
            reviewIds = @("review-referenced", "review-current")
            fixCommits = @(("1" * 40))
            gitPaths = @("src/sample.cs")
        }

        $context = Get-ArchitectureEvidenceContext -Trigger $trigger -CurrentReviewRecord $current -ReviewLedger @($referenced, $unrelated, $current) -FixCommitRecords @((New-TestFixRecord -Commit ("1" * 40)), (New-TestFixRecord -Commit ("2" * 40) -Paths @("src/unrelated.cs")))

        @($context.CurrentReview.findings).Count | Should Be 1
        @($context.Reviews).Count | Should Be 1
        $context.Reviews[0].reviewId | Should Be "review-referenced"
        @($context.Fixes).Count | Should Be 1
    }

    It "builds repair prompts from the exact prior result and validation error" {
        $reviewPrompt = New-StructuredReviewNormalizationPrompt -NativeReviewText "Native finding" -PreviousResult "{bad-review}" -ValidationError "exact review error"
        $architecturePrompt = New-ArchitectureAnalysisPrompt -Trigger ([PSCustomObject]@{}) -CurrentReviewRecord ([PSCustomObject]@{}) -ReviewLedger @() -FixCommitRecords @() -PreviousResult "{bad-architecture}" -ValidationError "exact architecture error"

        $reviewPrompt | Should Match ([regex]::Escape("{bad-review}"))
        $reviewPrompt | Should Match "exact review error"
        $architecturePrompt | Should Match ([regex]::Escape("{bad-architecture}"))
        $architecturePrompt | Should Match "exact architecture error"
    }

    It "rejects architecture changes outside declared paths before staging" {
        $repoPath = Join-Path $TestDrive "scope-repo"
        New-TestGitRepository -Path $repoPath
        [System.IO.File]::WriteAllText((Join-Path $repoPath "src/other.cs"), "class Other {}`n")

        (Test-CommandThrows { Save-FixChange -RepoPath $repoPath -IterationLabel "01" -ReviewLogPath "review.json" -FixSummary "Architecture change" -CommitMessageFallback "Architecture change" -IgnoredPaths @() -Mode architecture -AllowedPaths @("src/sample.cs") }) | Should Be $true
        (& git -C $repoPath diff --cached --name-only) | Should BeNullOrEmpty
    }

    It "requires both sides of a rename to be declared" {
        $repoPath = Join-Path $TestDrive "rename-repo"
        New-TestGitRepository -Path $repoPath
        [System.IO.File]::Move((Join-Path $repoPath "src/sample.cs"), (Join-Path $repoPath "src/renamed.cs"))

        (Test-CommandThrows { Save-FixChange -RepoPath $repoPath -IterationLabel "01" -ReviewLogPath "review.json" -FixSummary "Rename architecture" -CommitMessageFallback "Rename architecture" -IgnoredPaths @() -Mode architecture -AllowedPaths @("src/renamed.cs") }) | Should Be $true
        (& git -C $repoPath diff --cached --name-only) | Should BeNullOrEmpty
    }

    It "validates decision binding and rejects a stale HEAD" {
        $schemaPaths = Write-ReviewLoopSchemaFiles -LogRoot $TestDrive
        $decisionPath = Join-Path $TestDrive "decision.json"
        $decision = [ordered]@{
            schema_version = "codex_review_architecture_decision_v2"
            report_sha256 = ("a" * 64)
            expected_head = ("b" * 40)
            decision = "approve_strategy"
            decided_by = "tester"
            decided_at = "2026-07-21T12:00:00Z"
            note = "Approved for test."
            max_additional_point_fixes = 0
        }
        Write-TestJson -Path $decisionPath -Value $decision

        $validated = Read-ValidatedArchitectureDecision -DecisionPath $decisionPath -SchemaPath $schemaPaths.Decision -ExpectedReportSha256 ("a" * 64) -ExpectedHead ("b" * 40)
        $validated.decision | Should Be "approve_strategy"
        (Test-CommandThrows { Read-ValidatedArchitectureDecision -DecisionPath $decisionPath -SchemaPath $schemaPaths.Decision -ExpectedReportSha256 ("a" * 64) -ExpectedHead ("c" * 40) }) | Should Be $true
        (Test-CommandThrows { Read-ValidatedArchitectureDecision -DecisionPath $decisionPath -SchemaPath $schemaPaths.Decision -ExpectedReportSha256 ("a" * 64) -ExpectedHead ("b" * 40) -ExpectedReportCreatedAt "2026-07-21T12:01:00Z" }) | Should Be $true

        $decision.decision = "continue_point_fixes"
        $decision.max_additional_point_fixes = 0
        Write-TestJson -Path $decisionPath -Value $decision
        (Test-CommandThrows { Read-ValidatedArchitectureDecision -DecisionPath $decisionPath -SchemaPath $schemaPaths.Decision -ExpectedReportSha256 ("a" * 64) -ExpectedHead ("b" * 40) }) | Should Be $true

        $decision.schema_version = "codex_review_architecture_decision_v1"
        $decision.decision = "approve_strategy"
        $decision.max_additional_point_fixes = 0
        Write-TestJson -Path $decisionPath -Value $decision
        (Test-CommandThrows { Read-ValidatedArchitectureDecision -DecisionPath $decisionPath -SchemaPath $schemaPaths.Decision -ExpectedReportSha256 ("a" * 64) -ExpectedHead ("b" * 40) }) | Should Be $true
    }

    It "collects an interactive revision decision with a required note" {
        $answers = New-Object System.Collections.Queue
        @("x", "2", "", "Bitte auch den Cache-Lebenszyklus vereinheitlichen.") | ForEach-Object {
            $answers.Enqueue($_)
        }
        $reader = {
            param([string]$Prompt)
            return [string]$answers.Dequeue()
        }.GetNewClosure()
        $validated = [PSCustomObject]@{
            Sha256 = ("a" * 64)
            Report = [PSCustomObject](New-TestArchitectureResult)
        }
        $record = [PSCustomObject]@{ expectedHead = ("b" * 40) }

        $decision = Read-InteractiveArchitectureDecision `
            -ValidatedArchitecture $validated `
            -ArchitectureRecord $record `
            -InputReader $reader

        $decision.schema_version | Should Be "codex_review_architecture_decision_v2"
        $decision.decision | Should Be "revise_strategy"
        $decision.note | Should Be "Bitte auch den Cache-Lebenszyklus vereinheitlichen."
        $decision.report_sha256 | Should Be ("a" * 64)
        $decision.expected_head | Should Be ("b" * 40)
        $decision.max_additional_point_fixes | Should Be 0
    }

    It "uses an interactive gate in-process and persists its bound decision artifact" {
        $repoPath = Join-Path $TestDrive "architecture-interactive-gate-repo"
        New-TestGitRepository -Path $repoPath
        $schemaPaths = Write-ReviewLoopSchemaFiles -LogRoot $TestDrive
        $resultPath = Join-Path $TestDrive "interactive-gate.result.json"
        $recordPath = Join-Path $TestDrive "interactive-gate.record.json"
        Write-TestJson -Path $resultPath -Value (New-TestArchitectureResult)
        $validated = Read-ValidatedArchitectureResult -ResultPath $resultPath -SchemaPath $schemaPaths.Architecture -RepoPath $repoPath -ReviewBase HEAD
        $record = [PSCustomObject]@{
            expectedHead = (& git -C $repoPath rev-parse HEAD)
            reportSha256 = $validated.Sha256
            createdAt = "2026-07-21T12:00:00Z"
            recordPath = $recordPath
        }
        $answers = New-Object System.Collections.Queue
        @("1", "Einverstanden.") | ForEach-Object { $answers.Enqueue($_) }
        $reader = {
            param([string]$Prompt)
            return [string]$answers.Dequeue()
        }.GetNewClosure()
        $ledger = New-Object System.Collections.Generic.List[object]

        $resolution = Resolve-ArchitectureGateDecision `
            -RepoPath $repoPath `
            -ValidatedArchitecture $validated `
            -ArchitectureRecord $record `
            -AutoApplyLocal $true `
            -DecisionPath "" `
            -DecisionSchemaPath $schemaPaths.Decision `
            -DecisionLedger $ledger `
            -Interactive $true `
            -InteractiveInputReader $reader

        $resolution.RequiresHumanDecision | Should Be $false
        $resolution.Action | Should Be "approve_strategy"
        $resolution.Decision.note | Should Be "Einverstanden."
        $resolution.DecisionSource | Should Be "human_interactive"
        $resolution.GateReason | Should Match "Scope ist nicht local"
        $ledger.Count | Should Be 1
        $ledger[0].source | Should Be "human_interactive"
        (Test-Path (Join-Path $TestDrive "interactive-gate.decision.json")) | Should Be $true
    }

    It "keeps the saved headless gate when interactivity is disabled" {
        (Test-InteractiveArchitectureGate -Disabled $true) | Should Be $false

        $repoPath = Join-Path $TestDrive "architecture-headless-gate-repo"
        New-TestGitRepository -Path $repoPath
        $schemaPaths = Write-ReviewLoopSchemaFiles -LogRoot $TestDrive
        $resultPath = Join-Path $TestDrive "headless-gate.result.json"
        Write-TestJson -Path $resultPath -Value (New-TestArchitectureResult)
        $validated = Read-ValidatedArchitectureResult -ResultPath $resultPath -SchemaPath $schemaPaths.Architecture -RepoPath $repoPath -ReviewBase HEAD
        $ledger = New-Object System.Collections.Generic.List[object]
        $record = [PSCustomObject]@{
            expectedHead = (& git -C $repoPath rev-parse HEAD)
            reportSha256 = $validated.Sha256
            createdAt = "2026-07-21T12:00:00Z"
        }

        $resolution = Resolve-ArchitectureGateDecision -RepoPath $repoPath -ValidatedArchitecture $validated -ArchitectureRecord $record -AutoApplyLocal $false -DecisionPath "" -DecisionSchemaPath $schemaPaths.Decision -DecisionLedger $ledger -Interactive $false

        $resolution.RequiresHumanDecision | Should Be $true
        $resolution.DecisionSource | Should Be "pending"
        $resolution.GateReason | Should Match "deaktiviert"
        $ledger.Count | Should Be 0
    }

    It "builds unambiguous gate messages for manual, automatic, and headless decisions" {
        $eligibility = [PSCustomObject]@{
            Eligible = $false
            Reason = "Strategie-Scope ist nicht local."
        }

        (Get-ArchitectureManualGateReason -AutoApplyLocal $true -Eligibility $eligibility) | Should Be "Strategie-Scope ist nicht local"
        (Get-ArchitectureManualGateReason -AutoApplyLocal $false -Eligibility $eligibility) | Should Match "deaktiviert"
        (Get-ArchitectureApprovalStatusMessage -DecisionSource "human_interactive") | Should Be "Architekturstrategie freigegeben; Architektur-Fixer startet."
        (Get-ArchitectureApprovalStatusMessage -DecisionSource "auto_local") | Should Match "automatisch umgesetzt"
        (Get-ArchitectureApprovalStatusMessage -DecisionSource "auto_all") | Should Match "ArchitectureAutoApplyAll"
        $pendingMessage = Get-ArchitecturePendingGateMessage -Reason "Strategie-Scope ist nicht local" -ResultPath "architecture.result.json"
        $pendingMessage | Should Match "Strategie-Scope ist nicht local"
        $pendingMessage | Should Match "Exitcode 7"
    }

    It "returns revision, waiver, and abort through the shared gate handler without a strategy id" {
        $repoPath = Join-Path $TestDrive "architecture-gate-actions-repo"
        New-TestGitRepository -Path $repoPath
        $schemaPaths = Write-ReviewLoopSchemaFiles -LogRoot $TestDrive
        $resultPath = Join-Path $TestDrive "gate-report.json"
        Write-TestJson -Path $resultPath -Value (New-TestArchitectureResult)
        $validated = Read-ValidatedArchitectureResult -ResultPath $resultPath -SchemaPath $schemaPaths.Architecture -RepoPath $repoPath -ReviewBase HEAD
        $record = [PSCustomObject]@{
            expectedHead = ("b" * 40)
            reportSha256 = $validated.Sha256
            createdAt = "2026-07-21T12:00:00Z"
        }
        $ledger = New-Object System.Collections.Generic.List[object]
        foreach ($action in @("revise_strategy", "continue_point_fixes", "abort")) {
            $decisionPath = Join-Path $TestDrive "gate-$action.json"
            Write-TestJson -Path $decisionPath -Value ([ordered]@{
                schema_version = "codex_review_architecture_decision_v2"
                report_sha256 = $validated.Sha256
                expected_head = ("b" * 40)
                decision = $action
                decided_by = "tester"
                decided_at = "2026-07-21T12:01:00Z"
                note = "Test $action."
                max_additional_point_fixes = if ($action -eq "continue_point_fixes") { 2 } else { 0 }
            })
            $resolution = Resolve-ArchitectureGateDecision -RepoPath $repoPath -ValidatedArchitecture $validated -ArchitectureRecord $record -AutoApplyLocal $false -DecisionPath $decisionPath -DecisionSchemaPath $schemaPaths.Decision -DecisionLedger $ledger
            $resolution.Action | Should Be $action
            $resolution.DecisionSource | Should Be "human_file"
        }
        $ledger.Count | Should Be 3
    }

    It "rebuilds a v2 trigger for an exact v1 gate and fails closed for stale or incomplete context" {
        $repoPath = Join-Path $TestDrive "architecture-v1-migration-repo"
        New-TestGitRepository -Path $repoPath
        $prior = New-TestReviewRecord -Id "review-1" -Commit ("1" * 40)
        $current = New-TestReviewRecord -Id "review-2"
        $record = [PSCustomObject]@{
            schemaVersion = "codex_review_architecture_record_v1"
            repoPath = $repoPath
            branch = "main"
            reviewBase = "HEAD"
            epochId = "epoch-1"
            expectedHead = ("b" * 40)
            ledgerDigest = ("c" * 64)
            trigger = [PSCustomObject]@{ triggerTypes = @("repeat_signature") }
            currentReviewRecord = $current
        }

        (Test-CommandThrows { Assert-ArchitecturePendingContext -ArchitectureRecord $record -RepoPath $repoPath -Branch main -ReviewBase HEAD -EpochId "epoch-1" -Head ("b" * 40) -LedgerDigest ("c" * 64) }) | Should Be $false
        $trigger = Get-PendingV1MigrationTrigger -ArchitectureRecord $record -ReviewLedger @($prior, $current) -FixCommitRecords @() -RepeatThreshold 2 -HotspotFixThreshold 2
        $trigger.schemaVersion | Should Be "codex_review_architecture_trigger_v2"
        ($trigger.triggerTypes -join ",") | Should Match "repeat_path"
        (Test-CommandThrows { Assert-ArchitecturePendingContext -ArchitectureRecord $record -RepoPath $repoPath -Branch other -ReviewBase HEAD -EpochId "epoch-1" -Head ("b" * 40) -LedgerDigest ("c" * 64) }) | Should Be $true
        $record.currentReviewRecord = $null
        (Test-CommandThrows { Get-PendingV1MigrationTrigger -ArchitectureRecord $record -ReviewLedger @($prior) -FixCommitRecords @() -RepeatThreshold 2 -HotspotFixThreshold 2 }) | Should Be $true
    }

    It "supersedes a pending architecture report after a clean HEAD advance" {
        $record = [PSCustomObject]@{
            iterationLabel = "02"
            expectedHead = ("a" * 40)
            status = "fixing"
        }
        $runs = New-Object System.Collections.Generic.List[object]

        $resolved = Resolve-StalePendingArchitecture `
            -ArchitectureRecord $record `
            -CurrentHead ("b" * 40) `
            -GitStatus @() `
            -ArchitectureRuns $runs

        $resolved | Should Be $true
        $record.status | Should Be "superseded"
        $record.supersededReason | Should Be "git_head_changed"
        $record.supersededByHead | Should Be ("b" * 40)
        $runs.Count | Should Be 1
    }

    It "keeps stale pending architecture strict while the worktree is dirty" {
        $record = [PSCustomObject]@{
            iterationLabel = "02"
            expectedHead = ("a" * 40)
            status = "fixing"
        }
        $runs = New-Object System.Collections.Generic.List[object]

        $resolved = Resolve-StalePendingArchitecture `
            -ArchitectureRecord $record `
            -CurrentHead ("b" * 40) `
            -GitStatus @(" M src/sample.cs") `
            -ArchitectureRuns $runs

        $resolved | Should Be $false
        $record.status | Should Be "fixing"
        $runs.Count | Should Be 0
    }

    It "shows a revised report and returns to the interactive gate in the same process" {
        $originalRecord = [PSCustomObject]@{
            status = "pending"
            iterationLabel = "03"
            trigger = [PSCustomObject]@{ triggerTypes = @("repeat_path") }
            currentReviewRecord = [PSCustomObject]@{ reviewId = "review-03" }
        }
        $revisedRecord = [PSCustomObject]@{
            status = "generated"
            iterationLabel = ""
            recordPath = ""
            resultPath = "architecture-03-revision01.result.json"
            expectedHead = ("b" * 40)
            reportSha256 = ("a" * 64)
            createdAt = "2026-07-21T12:00:00Z"
        }
        $revisedArchitecture = [PSCustomObject]@{
            Sha256 = ("a" * 64)
            AllowedPaths = @("src/sample.cs")
            Report = [PSCustomObject](New-TestArchitectureResult)
        }
        $decision = [PSCustomObject]@{
            decision = "revise_strategy"
            note = "Bitte den Cache-Lebenszyklus ergänzen."
            max_additional_point_fixes = 0
        }
        $runs = New-Object System.Collections.Generic.List[object]
        $decisions = New-Object System.Collections.Generic.List[object]
        $decisions.Add($decision)
        $script:RunState = [PSCustomObject]@{
            status = "architecture_gate_pending"
            pendingArchitecture = $originalRecord
            completionReason = "architecture_decision_required"
            exitCode = 7
        }

        Mock Set-ArchitectureRunLedgerEntry {}
        Mock Save-ReviewLoopCheckpoint {}
        Mock Invoke-ArchitectureAnalysisWithRetry {
            return [PSCustomObject]@{
                Succeeded = $true
                Record = $revisedRecord
                Architecture = $revisedArchitecture
            }
        }
        Mock Resolve-ArchitectureGateDecision {
            return [PSCustomObject]@{
                Action = "approve_strategy"
                Decision = [PSCustomObject]@{ decision = "approve_strategy"; note = "Passt jetzt." }
                RequiresHumanDecision = $false
                AutoApplyEligibility = [PSCustomObject]@{ Eligible = $false; Reason = "" }
                DecisionSource = "human_interactive"
                GateReason = "Strategie-Scope ist nicht local"
            }
        }

        $result = Invoke-ArchitectureGateNonApprovalAction `
            -Action "revise_strategy" `
            -Decision $decision `
            -ArchitectureRecord $originalRecord `
            -RepoPath "C:\repo" `
            -Branch "feature/test" `
            -ReviewBase "origin/main" `
            -EpochId "epoch-1" `
            -LogRoot $TestDrive `
            -SchemaPath "architecture.schema.json" `
            -Model "test-model" `
            -Thinking "high" `
            -Speed "standard" `
            -ReviewLedger @() `
            -FixCommitRecords @() `
            -IgnoredPaths @() `
            -ArchitectureRuns $runs `
            -ArchitectureDecisions $decisions `
            -DecisionSchemaPath "decision.schema.json" `
            -InteractiveGate $true `
            -AutoApplyLocal $false

        $result.NextAction | Should Be "approve_strategy"
        $result.DecisionSource | Should Be "human_interactive"
        $result.ArchitectureRecord.status | Should Be "pending"
        $result.ValidatedArchitecture | Should Be $revisedArchitecture
        Assert-MockCalled Invoke-ArchitectureAnalysisWithRetry -Times 1 -Exactly
        Assert-MockCalled Resolve-ArchitectureGateDecision -Times 1 -Exactly
    }
}

Describe "Saved review recovery context" {
    $repoPath = Join-Path $TestDrive "recovery-context-repo"
    $head = "a" * 40
    $matchingContext = [PSCustomObject]@{
        repoPath = $repoPath
        branch = "feature/recovery"
        reviewBase = "origin/main"
        reviewHead = $head
    }

    It "accepts only a fully matching structured review context" {
        (Test-ReviewRecoveryContextMatches `
            -Context $matchingContext `
            -RepoPath $repoPath `
            -Branch "feature/recovery" `
            -ReviewBase "origin/main" `
            -CurrentHead $head `
            -HeadProperty "reviewHead") | Should Be $true
    }

    It "rejects a saved review from another branch" {
        (Test-ReviewRecoveryContextMatches `
            -Context $matchingContext `
            -RepoPath $repoPath `
            -Branch "feature/other" `
            -ReviewBase "origin/main" `
            -CurrentHead $head `
            -HeadProperty "reviewHead") | Should Be $false
    }

    It "rejects a saved review after HEAD advanced" {
        (Test-ReviewRecoveryContextMatches `
            -Context $matchingContext `
            -RepoPath $repoPath `
            -Branch "feature/recovery" `
            -ReviewBase "origin/main" `
            -CurrentHead ("b" * 40) `
            -HeadProperty "reviewHead") | Should Be $false
    }

    It "rejects old records without a recorded review commit" {
        $contextWithoutHead = [PSCustomObject]@{
            repoPath = $repoPath
            branch = "feature/recovery"
            reviewBase = "origin/main"
        }

        (Test-ReviewRecoveryContextMatches `
            -Context $contextWithoutHead `
            -RepoPath $repoPath `
            -Branch "feature/recovery" `
            -ReviewBase "origin/main" `
            -CurrentHead $head `
            -HeadProperty "reviewHead") | Should Be $false
    }

    It "does not select an otherwise matching review from an older commit" {
        $repoLogRoot = Join-Path $TestDrive "recovery-selector-logs"
        $sessionPath = Join-Path $repoLogRoot "20260722-100000"
        $currentLogRoot = Join-Path $repoLogRoot "20260722-110000"
        New-Item -ItemType Directory -Path $sessionPath, $currentLogRoot -Force | Out-Null
        [System.IO.File]::WriteAllText(
            (Join-Path $sessionPath "review-01.txt"),
            "Findings:`n- [P2] Fix this"
        )
        Write-TestJson -Path (Join-Path $sessionPath "review-01.record.json") -Value ([ordered]@{
            repoPath = $repoPath
            branch = "feature/recovery"
            reviewBase = "origin/main"
            reviewHead = $head
            classification = "finding"
            fixCommit = ""
        })

        $exactCandidate = Get-UnfixedReviewCandidateInSession `
            -RepoLogRoot $repoLogRoot `
            -CurrentLogRoot $currentLogRoot `
            -SessionPath $sessionPath `
            -SessionName "20260722-100000" `
            -RepoPath $repoPath `
            -Branch "feature/recovery" `
            -ReviewBase "origin/main" `
            -CurrentHead $head
        $staleCandidate = Get-UnfixedReviewCandidateInSession `
            -RepoLogRoot $repoLogRoot `
            -CurrentLogRoot $currentLogRoot `
            -SessionPath $sessionPath `
            -SessionName "20260722-100000" `
            -RepoPath $repoPath `
            -Branch "feature/recovery" `
            -ReviewBase "origin/main" `
            -CurrentHead ("b" * 40)

        $exactCandidate | Should Not BeNullOrEmpty
        $staleCandidate | Should BeNullOrEmpty
    }
}

Describe "Offline structured Codex integration" {
    BeforeEach {
        $caseRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString("N"))
        $repoPath = Join-Path $caseRoot "repo"
        New-Item -ItemType Directory -Path $repoPath -Force | Out-Null
        New-TestGitRepository -Path $repoPath
        $logRoot = Join-Path $caseRoot "logs"
        New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
        $schemaPaths = Write-ReviewLoopSchemaFiles -LogRoot $logRoot
        $fakeBin = Join-Path $caseRoot "bin"
        New-FakeCodexExecutable -Directory $fakeBin | Out-Null
        $oldPath = $env:PATH
        $env:PATH = "$fakeBin;$oldPath"
        $env:FAKE_CODEX_RESULT = (New-TestReviewResult -Classification clean) | ConvertTo-Json -Depth 30 -Compress
        $env:FAKE_CODEX_NATIVE_RESULT = "No findings."
        $env:FAKE_CODEX_COUNTER_PATH = Join-Path $caseRoot "counter.txt"
        $env:FAKE_CODEX_ARGUMENTS_PATH = Join-Path $caseRoot "arguments.txt"
        $env:FAKE_CODEX_NATIVE_ARGUMENTS_PATH = Join-Path $caseRoot "native-arguments.txt"
        $env:FAKE_CODEX_STDIN_PATH = Join-Path $caseRoot "stdin.txt"
        $env:FAKE_CODEX_INVALID_FIRST = ""
        $env:FAKE_CODEX_EXIT_CODE = ""
        $env:FAKE_CODEX_ERROR = ""
        $env:FAKE_CODEX_REVIEW_REPO = ""
    }

    AfterEach {
        $env:PATH = $oldPath
        Remove-Item Env:FAKE_CODEX_RESULT -ErrorAction SilentlyContinue
        Remove-Item Env:FAKE_CODEX_NATIVE_RESULT -ErrorAction SilentlyContinue
        Remove-Item Env:FAKE_CODEX_COUNTER_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:FAKE_CODEX_ARGUMENTS_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:FAKE_CODEX_NATIVE_ARGUMENTS_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:FAKE_CODEX_STDIN_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:FAKE_CODEX_INVALID_FIRST -ErrorAction SilentlyContinue
        Remove-Item Env:FAKE_CODEX_EXIT_CODE -ErrorAction SilentlyContinue
        Remove-Item Env:FAKE_CODEX_ERROR -ErrorAction SilentlyContinue
        Remove-Item Env:FAKE_CODEX_REVIEW_REPO -ErrorAction SilentlyContinue
    }

    It "writes structured result, deterministic text, record, and JSONL" {
        $run = Invoke-StructuredReviewWithRetry -RepoPath $repoPath -Branch main -ReviewBase HEAD -IterationLabel "01" -EpochId "epoch-1" -LogRoot $logRoot -SchemaPath $schemaPaths.Review -Model "test-model" -Thinking high -Speed standard -CustomPrompt "Focus on race conditions."

        $run.Succeeded | Should Be $true
        $run.Record.classification | Should Be "clean"
        (Test-Path -LiteralPath $run.ResultPath) | Should Be $true
        (Test-Path -LiteralPath $run.RecordPath) | Should Be $true
        (Get-Content -LiteralPath $run.TextPath -Raw) | Should Match "No findings"
        (Get-ChildItem -LiteralPath $logRoot -Filter "review-01*.jsonl").Count | Should Be 2
        (Get-Content -LiteralPath $env:FAKE_CODEX_COUNTER_PATH -Raw).Length | Should Be 2
        (Get-Content -LiteralPath $run.Record.nativeReviewTextPath -Raw) | Should Match "No findings"
        $nativeArgumentLines = @(Get-Content -LiteralPath $env:FAKE_CODEX_NATIVE_ARGUMENTS_PATH)
        $nativeArguments = $nativeArgumentLines -join "`n"
        $nativeArguments | Should Match "(?m)^review$"
        $nativeArguments | Should Not Match "--output-schema"
        $nativeArguments | Should Match "--output-last-message"
        $nativeArguments | Should Not Match "(?m)^--title$"
        $nativeArgumentLines[-1] | Should Not Be "-"
        $nativeArguments | Should Match "developer_instructions="
        $nativeArguments | Should Match "Focus on race conditions"
        $nativeArguments | Should Not Match "service_tier="
        $argumentLines = @(Get-Content -LiteralPath $env:FAKE_CODEX_ARGUMENTS_PATH)
        ($argumentLines -join "`n") | Should Not Match "(?m)^review$"
        $argumentLines[-1] | Should Be "-"
    }

    It "silently reverts tracked and untracked reviewer mutations" {
        $env:FAKE_CODEX_REVIEW_REPO = $repoPath

        $run = Invoke-StructuredReviewWithRetry -RepoPath $repoPath -Branch main -ReviewBase HEAD -IterationLabel "cleanup" -EpochId "epoch-1" -LogRoot $logRoot -SchemaPath $schemaPaths.Review -Model "test-model" -Thinking high -Speed standard -CustomPrompt ""

        $run.Succeeded | Should Be $true
        (Test-Path -LiteralPath (Join-Path $repoPath "reviewer-temp.txt")) | Should Be $false
        $status = @(& git -C $repoPath status --porcelain)
        $status.Count | Should Be 0
    }

    It "uses exactly one fresh retry after an invalid structured result" {
        $env:FAKE_CODEX_INVALID_FIRST = "1"

        $run = Invoke-StructuredReviewWithRetry -RepoPath $repoPath -Branch main -ReviewBase HEAD -IterationLabel "02" -EpochId "epoch-1" -LogRoot $logRoot -SchemaPath $schemaPaths.Review -Model "test-model" -Thinking high -Speed standard -CustomPrompt ""

        $run.Succeeded | Should Be $true
        (Get-Content -LiteralPath $env:FAKE_CODEX_COUNTER_PATH -Raw).Length | Should Be 3
        (Get-ChildItem -LiteralPath $logRoot -Filter "review-02*.jsonl").Count | Should Be 3
    }

    It "returns exit 9 after the single retry also remains invalid" {
        $env:FAKE_CODEX_RESULT = "{}"

        $run = Invoke-StructuredReviewWithRetry -RepoPath $repoPath -Branch main -ReviewBase HEAD -IterationLabel "invalid" -EpochId "epoch-1" -LogRoot $logRoot -SchemaPath $schemaPaths.Review -Model "test-model" -Thinking high -Speed standard -CustomPrompt ""

        $run.Succeeded | Should Be $false
        $run.ExitCode | Should Be 9
        (Get-Content -LiteralPath $env:FAKE_CODEX_COUNTER_PATH -Raw).Length | Should Be 3
        (Get-ChildItem -LiteralPath $logRoot -Filter "review-invalid*.jsonl").Count | Should Be 3
    }

    It "runs architecture analysis through an independently forced read-only invocation" {
        $trigger = [PSCustomObject]@{
            triggerTypes = @("repeat_path")
            reviewIds = @("review-1", "review-2")
            fixCommits = @(("1" * 40))
            gitPaths = @("src/sample.cs")
            epochId = "epoch-1"
        }
        $current = New-TestReviewRecord -Id "review-2"
        $prior = New-TestReviewRecord -Id "review-1" -Commit ("1" * 40)
        $fixes = @((New-TestFixRecord -Commit ("1" * 40)))
        $env:FAKE_CODEX_RESULT = (New-TestArchitectureResult) | ConvertTo-Json -Depth 30 -Compress

        $run = Invoke-ArchitectureAnalysisWithRetry -RepoPath $repoPath -Branch main -ReviewBase HEAD -EpochId "epoch-1" -IterationLabel "03" -LogRoot $logRoot -SchemaPath $schemaPaths.Architecture -Model "test-model" -Thinking max -Speed standard -Trigger $trigger -CurrentReviewRecord $current -ReviewLedger @($prior, $current) -FixCommitRecords $fixes -IgnoredPaths @()

        $run.Succeeded | Should Be $true
        $arguments = Get-Content -LiteralPath $env:FAKE_CODEX_ARGUMENTS_PATH -Raw
        $arguments | Should Match "--sandbox\s+read-only"
        $arguments | Should Not Match "dangerously-bypass"
        $run.Record.ledgerDigest.Length | Should Be 64
        $run.Record.schemaVersion | Should Be "codex_review_architecture_record_v2"
    }

    It "repairs an invalid architecture report once with the prior result and exact error" {
        $trigger = [PSCustomObject]@{
            triggerTypes = @("repeat_path")
            reviewIds = @("review-1", "review-2")
            fixCommits = @(("1" * 40))
            gitPaths = @("src/sample.cs")
            epochId = "epoch-1"
        }
        $current = New-TestReviewRecord -Id "review-2"
        $prior = New-TestReviewRecord -Id "review-1" -Commit ("1" * 40)
        $env:FAKE_CODEX_RESULT = (New-TestArchitectureResult) | ConvertTo-Json -Depth 30 -Compress
        $env:FAKE_CODEX_INVALID_FIRST = "1"

        $run = Invoke-ArchitectureAnalysisWithRetry -RepoPath $repoPath -Branch main -ReviewBase HEAD -EpochId "epoch-1" -IterationLabel "04" -LogRoot $logRoot -SchemaPath $schemaPaths.Architecture -Model "test-model" -Thinking max -Speed standard -Trigger $trigger -CurrentReviewRecord $current -ReviewLedger @($prior, $current) -FixCommitRecords @((New-TestFixRecord -Commit ("1" * 40))) -IgnoredPaths @()

        $run.Succeeded | Should Be $true
        (Get-Content -LiteralPath $env:FAKE_CODEX_COUNTER_PATH -Raw).Length | Should Be 2
        (Test-Path -LiteralPath (Join-Path $logRoot "architecture-04.attempt01.result.json")) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $logRoot "architecture-04.attempt02.result.json")) | Should Be $true
    }

    It "does not retry a deterministic architecture schema API failure" {
        $trigger = [PSCustomObject]@{
            triggerTypes = @("repeat_path")
            reviewIds = @("review-1", "review-2")
            fixCommits = @(("1" * 40))
            gitPaths = @("src/sample.cs")
            epochId = "epoch-1"
        }
        $current = New-TestReviewRecord -Id "review-2"
        $prior = New-TestReviewRecord -Id "review-1" -Commit ("1" * 40)
        $env:FAKE_CODEX_EXIT_CODE = "2"
        $env:FAKE_CODEX_ERROR = "invalid_json_schema"

        $run = Invoke-ArchitectureAnalysisWithRetry -RepoPath $repoPath -Branch main -ReviewBase HEAD -EpochId "epoch-1" -IterationLabel "05" -LogRoot $logRoot -SchemaPath $schemaPaths.Architecture -Model "test-model" -Thinking max -Speed standard -Trigger $trigger -CurrentReviewRecord $current -ReviewLedger @($prior, $current) -FixCommitRecords @((New-TestFixRecord -Commit ("1" * 40))) -IgnoredPaths @()

        $run.Succeeded | Should Be $false
        $run.ExitCode | Should Be 2
        (Get-Content -LiteralPath $env:FAKE_CODEX_COUNTER_PATH -Raw).Length | Should Be 1
        (Get-ChildItem -LiteralPath $logRoot -Filter "architecture-05*.jsonl").Count | Should Be 1
    }
}
