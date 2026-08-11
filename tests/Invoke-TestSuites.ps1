[CmdletBinding()]
param(
    [ValidateSet("Fast", "Full")]
    [string]$Mode = "Full"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$testsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$mainSuite = Join-Path $testsRoot "CodexReviewLoop.Tests.ps1"
$reliabilitySuite = Join-Path $testsRoot "Reliability.Tests.ps1"
$laneWorker = Join-Path $testsRoot "Invoke-PesterLane.ps1"
$resultRoot = Join-Path ([System.IO.Path]::GetTempPath()) `
    ("codex-review-loop-tests-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $resultRoot | Out-Null

function New-TestLane {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Script,
        [string]$Tag = "",
        [string]$TestName = ""
    )

    return [pscustomobject]@{
        Name = $Name
        Script = $Script
        Tag = $Tag
        TestName = $TestName
    }
}

function Invoke-TestLaneGroup {
    param(
        [Parameter(Mandatory = $true)][object[]]$Lanes,
        [switch]$Parallel
    )

    if (-not $Parallel) {
        Import-Module Pester -RequiredVersion 3.4.0 -Force
        return @($Lanes | ForEach-Object {
            $lane = $_
            $arguments = @{
                Script = [string]$lane.Script
                PassThru = $true
                Quiet = $true
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$lane.Tag)) {
                $arguments.Tag = [string]$lane.Tag
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$lane.TestName)) {
                $arguments.TestName = [string]$lane.TestName
            }
            $laneStarted = [DateTimeOffset]::UtcNow
            $result = Invoke-Pester @arguments
            [pscustomobject]@{
                Name = [string]$lane.Name
                Total = [int]$result.TotalCount
                Passed = [int]$result.PassedCount
                Failed = [int]$result.FailedCount
                Skipped = [int]$result.SkippedCount
                Seconds = [Math]::Round(
                    ([DateTimeOffset]::UtcNow - $laneStarted).TotalSeconds, 2)
                Error = ""
            }
        })
    }

    $workers = @()
    foreach ($lane in $Lanes) {
        $safeName = ([string]$lane.Name) -replace '[^A-Za-z0-9_.-]', '-'
        $resultPath = Join-Path $resultRoot "$safeName.xml"
        $logPath = Join-Path $resultRoot "$safeName.log"
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = (Get-Command pwsh.exe -ErrorAction Stop |
            Select-Object -First 1).Source
        $startInfo.UseShellExecute = $false
        foreach ($argument in @(
            "-NoLogo", "-NoProfile", "-NonInteractive", "-File", $laneWorker,
            "-Script", [string]$lane.Script,
            "-ResultPath", $resultPath,
            "-LogPath", $logPath
        )) {
            [void]$startInfo.ArgumentList.Add($argument)
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$lane.Tag)) {
            [void]$startInfo.ArgumentList.Add("-Tag")
            [void]$startInfo.ArgumentList.Add([string]$lane.Tag)
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$lane.TestName)) {
            [void]$startInfo.ArgumentList.Add("-TestName")
            [void]$startInfo.ArgumentList.Add([string]$lane.TestName)
        }
        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        if (-not $process.Start()) {
            throw "Could not start test lane '$($lane.Name)'."
        }
        $workers += [pscustomobject]@{
            Lane = $lane
            Process = $process
            ResultPath = $resultPath
            LogPath = $logPath
            StartedAt = [DateTimeOffset]::UtcNow
        }
    }

    return @($workers | ForEach-Object {
        $_.Process.WaitForExit()
        $seconds = [Math]::Round(
            ([DateTimeOffset]::UtcNow - $_.StartedAt).TotalSeconds, 2)
        if (-not (Test-Path -LiteralPath $_.ResultPath -PathType Leaf)) {
            $errorText = if (Test-Path -LiteralPath $_.LogPath -PathType Leaf) {
                (Get-Content -LiteralPath $_.LogPath -Tail 30) -join [Environment]::NewLine
            }
            else { "The worker produced neither a result nor a log." }
            return [pscustomobject]@{
                Name = [string]$_.Lane.Name
                Total = 0; Passed = 0; Failed = 1; Skipped = 0
                Seconds = $seconds; Error = $errorText
            }
        }
        [xml]$document = Get-Content -Raw -LiteralPath $_.ResultPath
        $summary = $document.'test-results'
        $total = [int]$summary.total
        $failed = [int]$summary.failures + [int]$summary.errors
        $skipped = [int]$summary.'not-run'
        return [pscustomobject]@{
            Name = [string]$_.Lane.Name
            Total = $total
            Passed = $total - $failed - $skipped
            Failed = $failed
            Skipped = $skipped
            Seconds = $seconds
            Error = if ($failed -gt 0 -or $_.Process.ExitCode -ne 0) {
                (Get-Content -LiteralPath $_.LogPath -Tail 60) -join [Environment]::NewLine
            } else { "" }
        }
    })
}

function Get-DeclaredTestCount {
    param([Parameter(Mandatory = $true)][string[]]$Path)

    $count = 0
    foreach ($file in $Path) {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $file, [ref]$tokens, [ref]$errors)
        if ($errors) {
            throw "Cannot count tests because '$file' does not parse."
        }
        $count += @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq "It"
        }, $true)).Count
    }
    return $count
}

$started = [DateTimeOffset]::UtcNow
$results = @()

if ($Mode -eq "Fast") {
    $results += Invoke-TestLaneGroup -Lanes @(
        New-TestLane -Name "fast" -Script $mainSuite -Tag "Fast"
    )
}
else {
    $results += Invoke-TestLaneGroup -Parallel -Lanes @(
        New-TestLane -Name "orchestration-1" -Script $mainSuite `
            -TestName "End-to-end orchestration with fake Codex"
        New-TestLane -Name "orchestration-2" -Script $mainSuite `
            -TestName "End-to-end orchestration with fake Codex 2"
        New-TestLane -Name "orchestration-3" -Script $mainSuite `
            -TestName "End-to-end orchestration with fake Codex 3"
        New-TestLane -Name "orchestration-4" -Script $mainSuite `
            -TestName "End-to-end orchestration with fake Codex 4"
        New-TestLane -Name "git-safety-a" -Script $reliabilitySuite -Tag "GitSafetyA"
        New-TestLane -Name "git-safety-b" -Script $reliabilitySuite -Tag "GitSafetyB"
    )

    $results += Invoke-TestLaneGroup -Parallel -Lanes @(
        New-TestLane -Name "fast-static" -Script $mainSuite -Tag "FullLocal"
        New-TestLane -Name "main-process" -Script $mainSuite -Tag "Process"
        New-TestLane -Name "reliability-process" -Script $reliabilitySuite -Tag "Process"
    )

    $declared = Get-DeclaredTestCount -Path @($mainSuite, $reliabilitySuite)
    $executed = [int](($results | Measure-Object -Property Total -Sum).Sum)
    if ($executed -ne $declared) {
        Remove-Item -LiteralPath $resultRoot -Recurse -Force `
            -ErrorAction SilentlyContinue
        throw "Full test partition executed $executed tests, but $declared tests are declared."
    }
}

$results | Format-Table Name, Total, Passed, Failed, Skipped, Seconds -AutoSize
$failures = @($results | Where-Object { [int]$_.Failed -gt 0 })
Remove-Item -LiteralPath $resultRoot -Recurse -Force -ErrorAction SilentlyContinue
foreach ($failure in $failures) {
    if (-not [string]::IsNullOrWhiteSpace([string]$failure.Error)) {
        Write-Error "$($failure.Name): $($failure.Error)"
    }
}
if ($failures.Count -gt 0) {
    throw "$($failures.Count) test lane(s) failed."
}

$elapsed = [Math]::Round(([DateTimeOffset]::UtcNow - $started).TotalSeconds, 2)
Write-Host "Test mode '$Mode' passed in ${elapsed}s."
