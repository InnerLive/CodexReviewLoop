<#
.SYNOPSIS
Starts the unattended Codex Review Loop for a Git repository.

.DESCRIPTION
All model interactions run exclusively through the locally installed Codex CLI.
The loop reviews the branch, applies verified fixes, and only completes after
the number of clean passes configured in the profile.

ConfigPath is optional. Without an explicit path, profiles are resolved in this
order:
1. <RepoPath>\.codex-review-loop.psd1
2. <RepoPath>\.codex\review-loop.psd1
3. A profile under <tool directory>\profiles whose RepositoryPath exactly
   matches the canonical Git root.

If no profile is found, the tool creates a commented profile using the next
available number under <tool directory>\profiles, for example
MyProject-001.psd1 or MyProject-002.psd1, and continues the run.

.PARAMETER RepoPath
Path to the Git repository to review and, when needed, fix.

.PARAMETER ConfigPath
Optional path to a PSD1 profile. If the explicitly requested path does not
exist, a commented profile bound to the canonical RepositoryPath is created
there automatically.

.PARAMETER Speed
Global service tier for every role and resume call without exception.
Accepted values are standard and fast. The default is standard.

.PARAMETER CodexPath
Optional path to a specific Codex CLI executable. When omitted, the installed
Codex CLI is resolved automatically.

.PARAMETER NewRun
Starts a new run instead of using the most recent resumable checkpoint.

.PARAMETER OutputMode
Controls the level of terminal detail:
compact shows phases, decisions, findings, and role or loop failures while hiding
internal agent-command diagnostics (default);
balanced adds internal agent-command starts and failures;
detailed also adds successful completions and no-result searches.
Internal reasoning is never displayed.

.PARAMETER HeartbeatSeconds
Refresh interval for the in-place progress status shown for long-running Codex
roles and host gates. The default is 30 seconds. Set to 0 to disable heartbeats.

.PARAMETER ColorMode
Controls color output:
Host uses native PowerShell host colors (default);
Ansi and Always emit ANSI color codes;
Auto uses ANSI only in a suitable interactive terminal;
Never disables colors.
The terminal.log file never contains color codes.

.PARAMETER Help
Shows this help without creating a profile or starting the review loop.

.EXAMPLE
C:\Tools\CodexReviewLoop\codex-review-loop.ps1 -RepoPath C:\dev\MyProject

Creates a commented profile when needed and uses standard speed.

.EXAMPLE
C:\dev\CodexReviewLoop\codex-review-loop.ps1 `
    -RepoPath C:\dev\Project `
    -ConfigPath C:\Configs\Project.psd1 `
    -Speed fast `
    -NewRun

Uses an explicit profile and enables fast mode for every role.

.EXAMPLE
C:\dev\CodexReviewLoop\codex-review-loop.ps1 C:\dev\Project `
    -OutputMode balanced `
    -HeartbeatSeconds 15 `
    -ColorMode Host

Adds concise CLI activity and reports progress every 15 seconds.

.EXAMPLE
C:\dev\CodexReviewLoop\codex-review-loop.ps1 -Help

Shows the full command help.

.NOTES
The ledger, checkpoints, and role logs are stored under the profile's LogRoot.
AutoCommit and HostGates are controlled by the profile as well.
#>
[CmdletBinding()]
param(
    [string]$RepoPath = "",

    [string]$ConfigPath = "",

    [ValidateSet("standard", "fast")]
    [string]$Speed = "standard",

    [string]$CodexPath = "",

    [switch]$NewRun,

    [ValidateSet("compact", "balanced", "detailed")]
    [string]$OutputMode = "compact",

    [ValidateRange(0, 3600)]
    [int]$HeartbeatSeconds = 30,

    [ValidateSet("Host", "Ansi", "Always", "Auto", "Never")]
    [string]$ColorMode = "Host",

    [Alias("h")]
    [switch]$Help
)

$ErrorActionPreference = "Stop"

if ($Help) {
    Get-Help $PSCommandPath -Detailed
    exit 0
}
if ([string]::IsNullOrWhiteSpace($RepoPath)) {
    Write-Error "RepoPath is required. Use -Help for examples and parameters."
    exit 1
}

$modulePath = Join-Path $PSScriptRoot "CodexReviewLoop.psd1"
Import-Module $modulePath -Force

$arguments = @{
    RepoPath = $RepoPath
    Speed = $Speed
    NewRun = $NewRun
    OutputMode = $OutputMode
    HeartbeatSeconds = $HeartbeatSeconds
    ColorMode = $ColorMode
}
if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
    $arguments.ConfigPath = $ConfigPath
}
if (-not [string]::IsNullOrWhiteSpace($CodexPath)) {
    $arguments.CodexPath = $CodexPath
}

$result = Invoke-CodexReviewLoop @arguments
$result | ConvertTo-Json -Depth 20
exit ([int]$result.ExitCode)
