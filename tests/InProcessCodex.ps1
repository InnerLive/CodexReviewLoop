function Get-InProcessCodexPlanValue {
    param(
        [AllowNull()][object]$Plan,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][object]$Default = $null
    )

    if ($null -ne $Plan -and $Plan.PSObject.Properties.Name -contains $Name) {
        return $Plan.$Name
    }
    return $Default
}

function Read-InProcessCodexSequenceValue {
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    $sequence = @(Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json)
    if ($sequence.Count -eq 0) {
        throw "In-process Codex sequence is empty: '$Path'."
    }
    $value = $sequence[0]
    $remaining = if ($sequence.Count -gt 1) { @($sequence[1..($sequence.Count - 1)]) } else { @() }
    [System.IO.File]::WriteAllText(
        $Path,
        (ConvertTo-Json -InputObject $remaining -Depth 30),
        [System.Text.UTF8Encoding]::new($false))
    return $value
}

function Invoke-InProcessCodexMutation {
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [AllowNull()][object[]]$Mutations
    )

    $repoRoot = [System.IO.Path]::GetFullPath($RepoPath)
    $repoPrefix = [System.IO.Path]::TrimEndingDirectorySeparator($repoRoot) +
        [System.IO.Path]::DirectorySeparatorChar
    foreach ($mutation in @($Mutations)) {
        $relative = [string](Get-InProcessCodexPlanValue -Plan $mutation -Name "path" -Default "")
        if ([string]::IsNullOrWhiteSpace($relative) -or [System.IO.Path]::IsPathRooted($relative) -or
            $relative -match '(^|[\\/])\.\.([\\/]|$)') {
            throw "In-process Codex mutation path is invalid: '$relative'."
        }
        $absolute = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $relative))
        if (-not $absolute.StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "In-process Codex mutation escapes the repository: '$relative'."
        }
        $parent = Split-Path -Parent $absolute
        if (-not [string]::IsNullOrWhiteSpace($parent)) {
            [System.IO.Directory]::CreateDirectory($parent) | Out-Null
        }
        $delete = [bool](Get-InProcessCodexPlanValue `
            -Plan $mutation -Name "delete" -Default $false)
        if ($delete) {
            if (Test-Path -LiteralPath $absolute -PathType Leaf) {
                Remove-Item -LiteralPath $absolute -Force
            }
            continue
        }
        $content = [string](Get-InProcessCodexPlanValue -Plan $mutation -Name "content" -Default "")
        $append = [bool](Get-InProcessCodexPlanValue -Plan $mutation -Name "append" -Default $false)
        if ($append) {
            [System.IO.File]::AppendAllText($absolute, $content, [System.Text.UTF8Encoding]::new($false))
        }
        else {
            [System.IO.File]::WriteAllText($absolute, $content, [System.Text.UTF8Encoding]::new($false))
        }
    }
}

function Invoke-InProcessCodexProfileMutation {
    param([AllowNull()][object]$Mutation)

    if ($null -eq $Mutation) {
        return
    }
    $path = [string](Get-InProcessCodexPlanValue -Plan $Mutation -Name "path" -Default "")
    if ([string]::IsNullOrWhiteSpace($path) -or
        [System.IO.Path]::GetExtension($path) -ne ".psd1" -or
        -not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "In-process Codex profile mutation path is invalid: '$path'."
    }
    $text = [System.IO.File]::ReadAllText($path)
    foreach ($replacement in @(Get-InProcessCodexPlanValue `
        -Plan $Mutation -Name "replacements" -Default @())) {
        $old = [string](Get-InProcessCodexPlanValue -Plan $replacement -Name "old" -Default "")
        $new = [string](Get-InProcessCodexPlanValue -Plan $replacement -Name "new" -Default "")
        if ([string]::IsNullOrEmpty($old) -or -not $text.Contains($old)) {
            throw "In-process Codex profile mutation did not find the requested text."
        }
        $text = $text.Replace($old, $new)
    }
    [System.IO.File]::WriteAllText($path, $text, [System.Text.UTF8Encoding]::new($false))
}

function Get-InProcessCodexDefaultResult {
    param([string]$SchemaName)

    switch ($SchemaName) {
        "architecture-advice-v2.schema.json" {
            return '{"schemaVersion":"2.0","summary":"Use judgment.","approach":"Address the findings in the repository.","steps":[],"considerations":[]}'
        }
        "review-classification-v1.schema.json" {
            return '{"schemaVersion":"1.0","hasFindings":false}'
        }
        "lessons-learned-v2.schema.json" {
            return '{"schemaVersion":"2.0","summary":"No durable guidance change is justified.","diagnosis":{"summary":"The run does not prove a reusable improvement.","causes":[],"guidanceAssessment":[]},"changes":[]}'
        }
        "fixer-result-v3.schema.json" {
            return '{"schemaVersion":"3.0","summary":"No change.","targetedTest":{"available":false,"executable":"","arguments":[]}}'
        }
        "architecture-assessment-v1.schema.json" {
            return '{"schemaVersion":"1.0","accept":false,"summary":"More work is useful.","feedback":[],"commitMessage":{"subject":"","rationale":"","changes":[]}}'
        }
        default { return "No actionable findings." }
    }
}

function Invoke-InProcessCodexRole {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][string]$Role,
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$Speed,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Prompt,
        [Parameter(Mandatory = $true)][string]$LogRoot,
        [string]$SchemaName = "",
        [ValidateSet("Exec", "Resume", "Review")][string]$Mode = "Exec",
        [string]$ThreadId = "",
        [string]$ReviewBase = "",
        [string]$CodexPath = "",
        [string]$CallId = "",
        [object]$State = $null,
        [string]$StatePath = ""
    )

    Update-ReviewLoopLiveConfig -Config $Config
    Assert-ReviewLoopExecutionUnchanged -Config $Config
    $roleConfig = Get-ReviewLoopRoleConfig -Config $Config -Role $Role
    Write-ReviewLoopStatus `
        -Message "$Role · $($roleConfig.Model)/$($roleConfig.Thinking) · $Speed · in-process test call" `
        -Kind Progress
    if ($null -ne $State -and -not [string]::IsNullOrWhiteSpace($CallId)) {
        $executionFingerprint = if ($Config.ContainsKey("__ExecutionFingerprint")) {
            [string]$Config["__ExecutionFingerprint"]
        }
        else { "" }
        $completed = @($State.RoleCalls | Where-Object {
            [bool](Get-ReviewLoopObjectProperty -Object $_ -Name "Success" -Default $false) -and
            [string](Get-ReviewLoopObjectProperty -Object $_ -Name "CallId" -Default "") -eq $CallId -and
            [string](Get-ReviewLoopObjectProperty -Object $_ -Name "Role" -Default "") -eq $Role -and
            [string](Get-ReviewLoopObjectProperty `
                -Object $_ -Name "ExecutionFingerprint" -Default "") -eq $executionFingerprint
        } | Select-Object -Last 1)
        if ($completed.Count -gt 0) {
            return ConvertFrom-ReviewLoopRoleCallRecord -Record $completed[0]
        }
    }
    $effectiveMode = $Mode
    $effectiveThreadId = $ThreadId
    if ($null -ne $State -and $Mode -eq "Exec" -and
        [string]::IsNullOrWhiteSpace($effectiveThreadId)) {
        $effectiveThreadId = Get-ReviewLoopRoleSessionThreadId -State $State -Role $Role
        if (-not [string]::IsNullOrWhiteSpace($effectiveThreadId)) {
            $effectiveMode = "Resume"
        }
    }

    $plan = Read-InProcessCodexSequenceValue `
        -Path ([Environment]::GetEnvironmentVariable("CODEX_REVIEW_LOOP_FAKE_INVOCATION_SEQUENCE"))
    $exitCode = [int](Get-InProcessCodexPlanValue -Plan $plan -Name "exitCode" -Default 0)
    $stderr = [string](Get-InProcessCodexPlanValue -Plan $plan -Name "stderr" -Default "")
    $emitThread = [bool](Get-InProcessCodexPlanValue -Plan $plan -Name "emitThread" -Default $true)
    $plannedThread = [string](Get-InProcessCodexPlanValue -Plan $plan -Name "threadId" -Default "")
    if ([string]::IsNullOrWhiteSpace($plannedThread)) {
        $plannedThread = [Environment]::GetEnvironmentVariable("CODEX_REVIEW_LOOP_FAKE_THREAD")
    }
    if ([string]::IsNullOrWhiteSpace($plannedThread)) {
        $plannedThread = "fake-thread-001"
    }
    $returnedThread = if ($emitThread -and $Mode -ne "Review") { $plannedThread } else { "" }

    $hasPlannedResult = $null -ne $plan -and $plan.PSObject.Properties.Name -contains "result"
    $resultText = if ($hasPlannedResult) {
        [string]$plan.result
    }
    else {
        $sequenceResult = Read-InProcessCodexSequenceValue `
            -Path ([Environment]::GetEnvironmentVariable("CODEX_REVIEW_LOOP_FAKE_RESULT_SEQUENCE"))
        if ($null -ne $sequenceResult) {
            [string]$sequenceResult
        }
        else {
            $override = [Environment]::GetEnvironmentVariable("CODEX_REVIEW_LOOP_FAKE_RESULT")
            if (-not [string]::IsNullOrWhiteSpace($override)) {
                $override
            }
            else {
                Get-InProcessCodexDefaultResult -SchemaName $SchemaName
            }
        }
    }

    $mutations = @(Get-InProcessCodexPlanValue -Plan $plan -Name "mutations" -Default @())
    Invoke-InProcessCodexMutation -RepoPath $RepoPath -Mutations $mutations
    Invoke-InProcessCodexProfileMutation `
        -Mutation (Get-InProcessCodexPlanValue -Plan $plan -Name "profileMutation")
    if ($Role -ne "Fixer" -and $mutations.Count -gt 0) {
        throw "Read-only role '$Role' changed the repository worktree despite its role contract."
    }
    $mutateSchema = [Environment]::GetEnvironmentVariable(
        "CODEX_REVIEW_LOOP_FAKE_MUTATE_ON_SCHEMA")
    if (-not [string]::IsNullOrWhiteSpace($mutateSchema) -and
        $SchemaName -eq $mutateSchema) {
        [System.IO.File]::AppendAllText(
            (Join-Path $RepoPath "fake-review-loop-change.test.txt"),
            ([Guid]::NewGuid().ToString("N") + [Environment]::NewLine),
            [System.Text.UTF8Encoding]::new($false))
        if ($Role -ne "Fixer") {
            throw "Read-only role '$Role' changed the repository worktree despite its role contract."
        }
    }

    if ($Mode -eq "Review" -and $exitCode -eq 0) {
        $legacyReview = $null
        try { $legacyReview = $resultText | ConvertFrom-Json } catch { $legacyReview = $null }
        if ($null -ne $legacyReview -and
            $legacyReview.PSObject.Properties.Name -contains "classification") {
            if ([string]$legacyReview.classification -eq "clean") {
                $resultText = "No findings."
            }
            else {
                $lines = @([string]$legacyReview.summary)
                $lines += @($legacyReview.findings | ForEach-Object {
                    "- $($_.title) ($($_.path):$($_.line)): $($_.evidence)"
                })
                $resultText = $lines -join [Environment]::NewLine
            }
        }
    }

    $callKind = switch ($effectiveMode) {
        "Review" { "review" }
        "Resume" { "resume" }
        default { "exec" }
    }
    $tier = if ($Speed -eq "fast") { "fast" } else { "default" }
    $arguments = @(
        "-m", [string]$roleConfig.Model,
        "-c", "service_tier=`"$tier`""
    )
    if ($effectiveMode -eq "Resume") {
        $arguments += @("resume", $effectiveThreadId)
    }
    elseif ($effectiveMode -eq "Review") {
        $arguments += @("review", "--base", $ReviewBase)
    }
    $schemaPath = $SchemaName
    $logPath = [Environment]::GetEnvironmentVariable("CODEX_REVIEW_LOOP_FAKE_LOG")
    if (-not [string]::IsNullOrWhiteSpace($logPath)) {
        $record = [pscustomobject]@{
            invocationId = [Guid]::NewGuid().ToString("N")
            callKind = $callKind
            resumeThreadId = $effectiveThreadId
            arguments = $arguments
            prompt = $Prompt
            resultPath = ""
            schemaPath = $schemaPath
        }
        [System.IO.File]::AppendAllText(
            $logPath,
            (($record | ConvertTo-Json -Depth 10 -Compress) + [Environment]::NewLine),
            [System.Text.UTF8Encoding]::new($false))
    }

    $structured = $null
    $failureKind = if ($exitCode -eq 0) { "none" } else {
        Get-CodexFailureKind -ExitCode $exitCode -Output $stderr
    }
    $failureReason = if ($exitCode -eq 0) { "" } else { $stderr }
    if ($exitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($SchemaName)) {
        try {
            $structured = $resultText | ConvertFrom-Json
        }
        catch {
            $exitCode = 4
            $failureKind = "invalid_structured_output"
            $failureReason = $_.Exception.Message
        }
    }
    if ($exitCode -ne 0 -and -not $emitThread -and $Role -eq "Fixer" -and
        -not (Test-ReviewLoopGitClean -RepoPath $RepoPath)) {
        $failureKind = "unsafe_partial_mutation"
        $failureReason = "The mutating role changed the worktree but returned no thread ID."
    }

    $now = [DateTimeOffset]::UtcNow.ToString("O")
    $call = [pscustomobject]@{
        Success = $exitCode -eq 0
        CallId = $CallId
        Role = $Role
        Model = [string]$roleConfig.Model
        Thinking = [string]$roleConfig.Thinking
        Speed = $Speed
        ExitCode = $exitCode
        FailureKind = $failureKind
        FailureReason = $failureReason
        ThreadId = $returnedThread
        Usage = [pscustomobject]@{
            InputTokens = 100L; CachedInputTokens = 80L
            OutputTokens = 20L; ReasoningOutputTokens = 5L
        }
        FinalMessage = if ($exitCode -eq 0) { $resultText } else { "" }
        StructuredResult = $structured
        Arguments = $arguments
        JsonlPath = ""
        ResultPath = ""
        Attempts = @([pscustomobject]@{
            Attempt = 1; ExitCode = $exitCode; FailureKind = $failureKind
            ThreadId = $returnedThread; StartedAt = $now; FinishedAt = $now
        })
        StartedAt = $now
        FinishedAt = $now
        ExecutionFingerprint = if ($Config.ContainsKey("__ExecutionFingerprint")) {
            [string]$Config["__ExecutionFingerprint"]
        } else { "" }
        RepositoryHead = ""
        WorktreeFingerprint = ""
    }
    if ($null -ne $State) {
        if ($call.Success) {
            Set-ReviewLoopRoleSessionThreadId -State $State -Role $Role -ThreadId $returnedThread
        }
        Add-ReviewLoopRoleCall -State $State -Call $call | Out-Null
        $State.ActiveRoleCall = $null
        Write-ReviewLoopState -Path $StatePath -State $State | Out-Null
    }
    return $call
}

function Enable-InProcessCodexRoleCalls {
    param(
        [Parameter(Mandatory = $true)][object]$Module,
        [Parameter(Mandatory = $true)][string]$HelperPath
    )

    & $Module {
        param($path)
        . $path
        foreach ($name in @(
            "Get-InProcessCodexPlanValue",
            "Read-InProcessCodexSequenceValue",
            "Invoke-InProcessCodexMutation",
            "Invoke-InProcessCodexProfileMutation",
            "Get-InProcessCodexDefaultResult",
            "Invoke-InProcessCodexRole"
        )) {
            $definition = (Get-Command $name -CommandType Function).ScriptBlock
            Set-Item -LiteralPath "Function:script:$name" -Value $definition
        }
        $script:ReviewLoopRoleCallOverride =
            (Get-Command Invoke-InProcessCodexRole -CommandType Function).ScriptBlock
    } $HelperPath
}

function Disable-InProcessCodexRoleCalls {
    param([Parameter(Mandatory = $true)][object]$Module)
    & $Module { $script:ReviewLoopRoleCallOverride = $null }
}
