<#
.SYNOPSIS
Publishes one operator message or controlled pause request to an existing run.
.DESCRIPTION
RunRoot pins the observed run. To explicitly selects Reviewer, Architect and/or
Fixer. RequireDelivery requests these roles before the next unsealed commit or
completion; use it sparingly. Reuse Id only to retry the identical request.
PauseAt selects AfterRole, AfterRound, BeforeCommit or BeforeCompletion.
Publication is not a reached-pause receipt. Wait for process exit before takeover.
.EXAMPLE
.\operator-message.ps1 $runRoot -To Architect -Message 'Check the new evidence.'
.EXAMPLE
.\operator-message.ps1 $runRoot -To Reviewer,Fixer -Message 'Recheck recovery.' -RequireDelivery
.EXAMPLE
.\operator-message.ps1 $runRoot -PauseAt AfterRole -Message 'Inspect the current result.'
#>
[CmdletBinding(DefaultParameterSetName = 'Message')]
param(
    [Parameter(Position = 0)][string]$RunRoot,
    [Parameter(Position = 1, ParameterSetName = 'Message')]
    [string[]]$To,
    [Parameter(ParameterSetName = 'Pause')]
    [ValidateSet('AfterRole','AfterRound','BeforeCommit','BeforeCompletion')][string]$PauseAt,
    [Parameter(Position = 2)][string]$Message,
    [Parameter(Position = 3)][string]$Id = ([guid]::NewGuid().ToString('D')),
    [Parameter(ParameterSetName = 'Message')][switch]$RequireDelivery,
    [switch]$Help
)
$ErrorActionPreference = 'Stop'
if ($Help) { Get-Help $PSCommandPath -Detailed; exit 0 }
try {
    Import-Module (Join-Path $PSScriptRoot 'CodexReviewLoop.psd1') -Force
    $arguments = @{ RunRoot = $RunRoot; Message = $Message; Id = $Id }
    if ($PauseAt) { $arguments.PauseAt = $PauseAt }
    else { $arguments.To = $To; $arguments.RequireDelivery = $RequireDelivery }
    $published = Send-ReviewLoopOperatorMessage @arguments
    if ($PauseAt) { Write-Output "$published requested $PauseAt (publication only)" }
    else { Write-Output $published }
}
catch {
    $reason = ($_.Exception.Message -split '\r?\n')[0]
    Write-Output "$Id rejected: $reason"
    exit 1
}
