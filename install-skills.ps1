[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$SkillsPath = (Join-Path (
        [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    ) ".agents\skills")
)

$ErrorActionPreference = "Stop"
$repositoryRoot = $PSScriptRoot
if (Test-Path -LiteralPath (Join-Path $repositoryRoot '.git') -PathType Leaf) {
    $worktrees = @(& git -C $repositoryRoot worktree list --porcelain)
    if ($LASTEXITCODE -ne 0 -or $worktrees.Count -eq 0 -or
        -not $worktrees[0].StartsWith('worktree ')) {
        throw 'Could not locate the primary ReviewLoop checkout.'
    }
    $repositoryRoot = [IO.Path]::GetFullPath($worktrees[0].Substring(9))
}
$sourceRoot = Join-Path $repositoryRoot "skills"
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
        @{ repositoryPath = $repositoryRoot } | ConvertTo-Json |
            Set-Content -LiteralPath (Join-Path $SkillsPath "review-loop\installation.json") `
                -Encoding utf8NoBOM
    }
    Write-Output "Updated $(Join-Path $SkillsPath $skillName)"
}
