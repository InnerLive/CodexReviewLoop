<#
.SYNOPSIS
Reads a compact JSON status for the exact observed run without changing it.
.DESCRIPTION
Saved contains checkpoint facts, not proof of a live process. Observed reports
only available evidence. A held repository lease does not identify its owner.
Missing facts are omitted. No role, recovery, request import or config reload runs.
Since accepts the previous Cursor and returns up to 50 new terminal.log lines
with Changes.HasMore. Keep the returned Cursor for the next page or query.
.EXAMPLE
.\operator-status.ps1 $runRoot
.EXAMPLE
.\operator-status.ps1 $runRoot -Since $cursor
#>
[CmdletBinding()]
param([Parameter(Position = 0)][string]$RunRoot, [string]$Since = '', [switch]$Help)
$ErrorActionPreference = 'Stop'
if ($Help) { Get-Help $PSCommandPath -Detailed; exit 0 }
try {
    Import-Module (Join-Path $PSScriptRoot 'CodexReviewLoop.psd1') -Force
    Get-ReviewLoopOperatorStatus -RunRoot $RunRoot -Since $Since | ConvertTo-Json -Depth 12 -Compress
}
catch {
    $reason = 'Status unavailable.'
    $module = Get-Module CodexReviewLoop
    if ($null -ne $module) {
        $reason = & $module { param($message) ConvertTo-ReviewLoopRedactedText ($message -split '\r?\n')[0] } $_.Exception.Message
    }
    @{ Error = $reason } | ConvertTo-Json -Compress
    exit 1
}
