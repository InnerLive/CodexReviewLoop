[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Script,
    [Parameter(Mandatory = $true)][string]$ResultPath,
    [Parameter(Mandatory = $true)][string]$LogPath,
    [string]$Tag = "",
    [string]$TestName = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Import-Module Pester -RequiredVersion 3.4.0 -Force
$ErrorActionPreference = "Continue"

$arguments = @{
    Script = $Script
    OutputFile = $ResultPath
    OutputFormat = "NUnitXml"
    Quiet = $true
}
if (-not [string]::IsNullOrWhiteSpace($Tag)) {
    $arguments.Tag = $Tag
}
if (-not [string]::IsNullOrWhiteSpace($TestName)) {
    $arguments.TestName = $TestName
}

try {
    & { Invoke-Pester @arguments } *> $LogPath
    [xml]$document = Get-Content -Raw -LiteralPath $ResultPath
    exit [Math]::Min(1, [int]$document.'test-results'.failures)
}
catch {
    $_ | Out-String | Add-Content -LiteralPath $LogPath
    exit 1
}
