[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$startMarker = "<!-- codex-smallest-complete-work:start -->"
$endMarker = "<!-- codex-smallest-complete-work:end -->"
$rulesPath = Join-Path $PSScriptRoot "docs\smallest-complete-work.md"

if (-not (Test-Path -LiteralPath $rulesPath -PathType Leaf)) {
    throw "The managed rules file was not found: $rulesPath"
}

$rules = [System.IO.File]::ReadAllText($rulesPath)
$rulesStartCount = ([regex]::Matches($rules, [regex]::Escape($startMarker))).Count
$rulesEndCount = ([regex]::Matches($rules, [regex]::Escape($endMarker))).Count
$validRulesPattern = "(?ms)\A[ \t]*$([regex]::Escape($startMarker))[ \t]*\r?\n.*?^[ \t]*$([regex]::Escape($endMarker))[ \t]*(?:\r?\n)?\z"
if ($rulesStartCount -ne 1 -or $rulesEndCount -ne 1 -or
    -not [regex]::IsMatch($rules, $validRulesPattern)) {
    throw "The managed rules file must contain exactly one start marker and one end marker."
}

$codexHome = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
    [System.IO.Path]::GetFullPath($env:CODEX_HOME)
}
else {
    $userHome = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::UserProfile)
    if ([string]::IsNullOrWhiteSpace($userHome)) {
        throw "Neither CODEX_HOME nor the current user's home directory is available."
    }
    Join-Path $userHome ".codex"
}

New-Item -ItemType Directory -Path $codexHome -Force | Out-Null
$agentsPath = Join-Path $codexHome "AGENTS.md"
if (Test-Path -LiteralPath $agentsPath -PathType Container) {
    throw "The AGENTS.md path is a directory instead of a file: $agentsPath"
}
$existing = if (Test-Path -LiteralPath $agentsPath -PathType Leaf) {
    [System.IO.File]::ReadAllText($agentsPath)
}
else {
    ""
}

$existingStartCount = ([regex]::Matches(
        $existing, [regex]::Escape($startMarker))).Count
$existingEndCount = ([regex]::Matches(
        $existing, [regex]::Escape($endMarker))).Count
if ($existingStartCount -ne $existingEndCount) {
    throw "The existing AGENTS.md contains an incomplete managed rules block. Repair or remove its markers, then run the installer again."
}

$managedBlockPattern = "(?ms)^[ \t]*$([regex]::Escape($startMarker))[ \t]*\r?\n.*?^[ \t]*$([regex]::Escape($endMarker))[ \t]*(?:\r?\n)?"
$remaining = [regex]::Replace($existing, $managedBlockPattern, "")
if ($remaining.Contains($startMarker) -or $remaining.Contains($endMarker)) {
    throw "The existing AGENTS.md contains malformed or nested managed rules markers."
}

$newLine = if ($existing.Contains("`r`n")) {
    "`r`n"
}
elseif ($existing.Contains("`n")) {
    "`n"
}
else {
    [Environment]::NewLine
}
$normalizedRules = $rules.Replace("`r`n", "`n").Replace("`r", "`n").
    TrimEnd([char[]]"`n").Replace("`n", $newLine)
$remaining = $remaining.TrimStart([char[]]"`r`n")
$updated = if ([string]::IsNullOrEmpty($remaining)) {
    "$normalizedRules$newLine"
}
else {
    "$normalizedRules$newLine$newLine$remaining"
}

$temporaryPath = Join-Path $codexHome (
    ".AGENTS.md.$([Guid]::NewGuid().ToString('N')).tmp")
$utf8WithoutBom = [System.Text.UTF8Encoding]::new($false)
try {
    [System.IO.File]::WriteAllText($temporaryPath, $updated, $utf8WithoutBom)
    $target = Get-Item -LiteralPath $agentsPath -Force -ErrorAction SilentlyContinue
    if ($null -ne $target -and $null -ne $target.LinkType) {
        [System.IO.File]::WriteAllText($agentsPath, $updated, $utf8WithoutBom)
        Remove-Item -LiteralPath $temporaryPath -Force
    }
    else {
        [System.IO.File]::Move($temporaryPath, $agentsPath, $true)
    }
}
finally {
    Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
}

$overridePath = Join-Path $codexHome "AGENTS.override.md"
if (Test-Path -LiteralPath $overridePath -PathType Leaf) {
    $override = [System.IO.File]::ReadAllText($overridePath)
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        Write-Warning "A non-empty global AGENTS.override.md takes precedence over AGENTS.md, so Codex will not load these rules until the override is removed or emptied."
    }
}

Write-Output "Updated $agentsPath"
