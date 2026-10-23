<#
.SYNOPSIS
Publishes one operator message to an existing ReviewLoop run.
.DESCRIPTION
RunRoot pins the observed run. To explicitly selects Reviewer, Architect and/or
Fixer. RequireDelivery requests these roles before the next unsealed commit or
completion; use it sparingly. Reuse Id only to retry the identical request.
.EXAMPLE
.\operator-message.ps1 $runRoot -To Architect -Message 'Check the new evidence.'
.EXAMPLE
.\operator-message.ps1 $runRoot -To Reviewer,Fixer -Message 'Recheck recovery.' -RequireDelivery
#>
[CmdletBinding()]
param(
    [string]$RunRoot,
    [string[]]$To,
    [string]$Message,
    [string]$Id = ([guid]::NewGuid().ToString('D')),
    [switch]$RequireDelivery,
    [switch]$Help
)
$ErrorActionPreference = 'Stop'
if ($Help) { Get-Help $PSCommandPath -Detailed; exit 0 }
try {
    Import-Module (Join-Path $PSScriptRoot 'CodexReviewLoop.psd1') -Force
    Send-ReviewLoopOperatorMessage -RunRoot $RunRoot -To $To -Message $Message `
        -Id $Id -RequireDelivery:$RequireDelivery
}
catch {
    $reason = ($_.Exception.Message -split '\r?\n')[0]
    Write-Output "$Id rejected: $reason"
    exit 1
}
