[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$SkillsPath = (Join-Path (
        [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    ) ".agents\skills")
)

$ErrorActionPreference = "Stop"
$sourceRoot = Join-Path $PSScriptRoot "skills"
$skillNames = @("prompting", "review-loop")

foreach ($skillName in $skillNames) {
    $manifest = Join-Path $sourceRoot "$skillName\SKILL.md"
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
        throw "The bundled skill was not found: $manifest"
    }
}

New-Item -ItemType Directory -Path $SkillsPath -Force | Out-Null
foreach ($skillName in $skillNames) {
    Copy-Item -LiteralPath (Join-Path $sourceRoot $skillName) `
        -Destination $SkillsPath -Recurse -Force
    if ($skillName -eq "review-loop") {
        @{ repositoryPath = $PSScriptRoot } | ConvertTo-Json |
            Set-Content -LiteralPath (Join-Path $SkillsPath "review-loop\installation.json") `
                -Encoding utf8NoBOM
    }
    Write-Output "Updated $(Join-Path $SkillsPath $skillName)"
}
