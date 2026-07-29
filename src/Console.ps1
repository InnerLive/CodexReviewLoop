$script:ReviewLoopConsole = [ordered]@{
    OutputMode       = "compact"
    HeartbeatSeconds = 30
    ColorMode        = "Host"
    HostOutputEnabled = $true
    TranscriptPath   = ""
    CapturePending   = $false
    PendingLines     = [System.Collections.Generic.List[string]]::new()
    InlineActive     = $false
    InlineWidth      = 0
}

function Initialize-ReviewLoopConsole {
    param(
        [ValidateSet("compact", "balanced", "detailed")]
        [string]$OutputMode = "compact",
        [ValidateRange(0, 3600)]
        [int]$HeartbeatSeconds = 30,
        [ValidateSet("Host", "Ansi", "Always", "Auto", "Never")]
        [string]$ColorMode = "Host",
        [bool]$HostOutputEnabled = $true,
        [string]$TranscriptPath = ""
    )

    $script:ReviewLoopConsole.OutputMode = $OutputMode
    $script:ReviewLoopConsole.HeartbeatSeconds = $HeartbeatSeconds
    $script:ReviewLoopConsole.ColorMode = $ColorMode
    $script:ReviewLoopConsole.HostOutputEnabled = $HostOutputEnabled
    $script:ReviewLoopConsole.TranscriptPath = $TranscriptPath
    $script:ReviewLoopConsole.InlineActive = $false
    $script:ReviewLoopConsole.InlineWidth = 0
    if ([string]::IsNullOrWhiteSpace($TranscriptPath)) {
        $script:ReviewLoopConsole.PendingLines.Clear()
        $script:ReviewLoopConsole.CapturePending = $true
    }
    else {
        $parent = Split-Path -Parent $TranscriptPath
        [System.IO.Directory]::CreateDirectory($parent) | Out-Null
        if (-not (Test-Path -LiteralPath $TranscriptPath)) {
            Write-ReviewLoopUtf8File -Path $TranscriptPath -Content ""
        }
        foreach ($pending in $script:ReviewLoopConsole.PendingLines) {
            [System.IO.File]::AppendAllText($TranscriptPath, $pending, [System.Text.UTF8Encoding]::new($false))
        }
        $script:ReviewLoopConsole.PendingLines.Clear()
        $script:ReviewLoopConsole.CapturePending = $false
    }
}

function Get-ReviewLoopConsoleOption {
    param([Parameter(Mandatory = $true)][string]$Name)
    return $script:ReviewLoopConsole[$Name]
}

function Test-ReviewLoopOutputLevel {
    param([ValidateSet("compact", "balanced", "detailed")][string]$Minimum)

    $rank = @{ compact = 0; balanced = 1; detailed = 2 }
    return $rank[[string]$script:ReviewLoopConsole.OutputMode] -ge $rank[$Minimum]
}

function Format-ReviewLoopDuration {
    param([Parameter(Mandatory = $true)][TimeSpan]$Duration)

    if ($Duration.TotalHours -ge 1) {
        $hours = [int][Math]::Floor($Duration.TotalHours)
        return "{0:00}:{1:00}:{2:00}" -f $hours, $Duration.Minutes, $Duration.Seconds
    }
    $minutes = [int][Math]::Floor($Duration.TotalMinutes)
    return "{0:00}:{1:00}" -f $minutes, $Duration.Seconds
}

function Get-ReviewLoopConsoleWidth {
    try {
        $width = [Console]::WindowWidth
        if ($width -ge 60) {
            return [Math]::Min(140, $width - 2)
        }
    }
    catch {
        # Non-interactive hosts do not expose a reliable window width.
    }
    return 100
}

function Remove-ReviewLoopAnsi {
    param([AllowNull()][string]$Text)
    return [regex]::Replace(($Text ?? ""), "`e\[[0-9;]*m", "")
}

function Add-ReviewLoopTranscriptLine {
    param([AllowNull()][string]$Text)

    $path = [string]$script:ReviewLoopConsole.TranscriptPath
    $plain = ConvertTo-ReviewLoopRedactedText (Remove-ReviewLoopAnsi $Text)
    $record = "{0} {1}{2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), $plain, [Environment]::NewLine
    if ([string]::IsNullOrWhiteSpace($path)) {
        if ([bool]$script:ReviewLoopConsole.CapturePending) {
            [void]$script:ReviewLoopConsole.PendingLines.Add($record)
        }
        return
    }
    [System.IO.File]::AppendAllText($path, $record, [System.Text.UTF8Encoding]::new($false))
}

function Get-ReviewLoopConsoleStyle {
    param([Parameter(Mandatory = $true)][string]$Kind)

    $style = switch ($Kind) {
        "Success"      { [pscustomobject]@{ Prefix = "[OK]"; Color = "Green"; Ansi = 32 } }
        "Warning"      { [pscustomobject]@{ Prefix = "[!]"; Color = "Yellow"; Ansi = 33 } }
        "Error"        { [pscustomobject]@{ Prefix = "[X]"; Color = "Red"; Ansi = 31 } }
        "Review"       { [pscustomobject]@{ Prefix = "[REVIEW]"; Color = "Magenta"; Ansi = 35 } }
        "Architecture" { [pscustomobject]@{ Prefix = "[ARCH]"; Color = "Cyan"; Ansi = 36 } }
        "Progress"     { [pscustomobject]@{ Prefix = "[..]"; Color = "Cyan"; Ansi = 36 } }
        "Muted"        { [pscustomobject]@{ Prefix = "    "; Color = "DarkGray"; Ansi = 90 } }
        default        { [pscustomobject]@{ Prefix = "[i]"; Color = "Gray"; Ansi = 37 } }
    }
    return $style
}

function Test-ReviewLoopUseAnsi {
    $mode = [string]$script:ReviewLoopConsole.ColorMode
    if ($mode -in @("Ansi", "Always")) {
        return $true
    }
    if ($mode -ne "Auto") {
        return $false
    }
    if (-not [string]::IsNullOrWhiteSpace($env:NO_COLOR) -or $env:TERM -eq "dumb") {
        return $false
    }
    try {
        return -not [Console]::IsOutputRedirected
    }
    catch {
        return $false
    }
}

function Write-ReviewLoopConsoleLine {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][object]$Style
    )

    Complete-ReviewLoopInlineStatus
    $safe = ConvertTo-ReviewLoopRedactedText $Text
    Add-ReviewLoopTranscriptLine -Text $safe
    if (-not [bool]$script:ReviewLoopConsole.HostOutputEnabled) {
        return
    }
    $mode = [string]$script:ReviewLoopConsole.ColorMode
    if ($mode -eq "Never") {
        Write-Host $safe
    }
    elseif (Test-ReviewLoopUseAnsi) {
        Write-Host ("`e[{0}m{1}`e[0m" -f $Style.Ansi, $safe)
    }
    else {
        Write-Host $safe -ForegroundColor $Style.Color
    }
}

function Complete-ReviewLoopInlineStatus {
    if (-not [bool]$script:ReviewLoopConsole.InlineActive) {
        return
    }

    if ([bool]$script:ReviewLoopConsole.HostOutputEnabled) {
        Write-Host ""
    }
    $script:ReviewLoopConsole.InlineActive = $false
    $script:ReviewLoopConsole.InlineWidth = 0
}

function Write-ReviewLoopInlineStatus {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][object]$Style
    )

    $safe = ConvertTo-ReviewLoopRedactedText ($Text -replace "\r?\n", " ")
    $maxWidth = [Math]::Max(30, (Get-ReviewLoopConsoleWidth))
    if ($safe.Length -gt $maxWidth) {
        $safe = $safe.Substring(0, $maxWidth - 1) + "…"
    }
    Add-ReviewLoopTranscriptLine -Text $safe
    if (-not [bool]$script:ReviewLoopConsole.HostOutputEnabled) {
        return
    }

    $renderWidth = [Math]::Max([int]$script:ReviewLoopConsole.InlineWidth, $safe.Length)
    $rendered = "`r$($safe.PadRight($renderWidth))"
    $mode = [string]$script:ReviewLoopConsole.ColorMode
    if ($mode -eq "Never") {
        Write-Host $rendered -NoNewline
    }
    elseif (Test-ReviewLoopUseAnsi) {
        Write-Host ("`r`e[{0}m{1}`e[0m" -f $Style.Ansi, $safe.PadRight($renderWidth)) -NoNewline
    }
    else {
        Write-Host $rendered -NoNewline -ForegroundColor $Style.Color
    }
    $script:ReviewLoopConsole.InlineActive = $true
    $script:ReviewLoopConsole.InlineWidth = $safe.Length
}

function Split-ReviewLoopWrappedText {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][int]$Width
    )

    $result = [System.Collections.Generic.List[string]]::new()
    foreach ($sourceLine in @($Text -split "\r?\n")) {
        $remaining = $sourceLine.TrimEnd()
        if ($remaining.Length -eq 0) {
            [void]$result.Add("")
            continue
        }
        while ($remaining.Length -gt $Width) {
            $cut = $remaining.LastIndexOf(" ", $Width)
            if ($cut -lt [Math]::Floor($Width / 2)) {
                $cut = $Width
            }
            [void]$result.Add($remaining.Substring(0, $cut).TrimEnd())
            $remaining = $remaining.Substring($cut).TrimStart()
        }
        [void]$result.Add($remaining)
    }
    return $result.ToArray()
}

function Write-ReviewLoopStatus {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet("Info", "Progress", "Success", "Warning", "Error", "Review", "Architecture", "Muted")]
        [string]$Kind = "Info",
        [int]$Indent = 0,
        [switch]$Inline
    )

    $style = Get-ReviewLoopConsoleStyle -Kind $Kind
    $indentText = "  " * [Math]::Max(0, $Indent)
    $firstPrefix = "$indentText$($style.Prefix) "
    if ($Inline) {
        Write-ReviewLoopInlineStatus -Text "$firstPrefix$Message" -Style $style
        return
    }
    $nextPrefix = "$indentText$(" " * ($style.Prefix.Length + 1))"
    $width = [Math]::Max(30, (Get-ReviewLoopConsoleWidth) - $firstPrefix.Length)
    $lines = @(Split-ReviewLoopWrappedText -Text $Message -Width $width)
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $prefix = if ($index -eq 0) { $firstPrefix } else { $nextPrefix }
        Write-ReviewLoopConsoleLine -Text "$prefix$($lines[$index])" -Style $style
    }
}

function Write-ReviewLoopNextSteps {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Steps,
        [ValidateRange(0, 100)]
        [int]$RecommendedCount = 1
    )

    $items = @($Steps | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_)
    })
    if ($items.Count -eq 0) {
        return
    }

    $recommended = [Math]::Min($items.Count, $RecommendedCount)
    if ($recommended -gt 0) {
        Write-ReviewLoopStatus -Message "Recommended:" -Kind Warning
    }
    for ($index = 0; $index -lt $recommended; $index++) {
        Write-ReviewLoopStatus `
            -Message $(if ($recommended -eq 1) {
                $items[$index]
            }
            else {
                "{0}. {1}" -f ($index + 1), $items[$index]
            }) `
            -Kind Muted `
            -Indent 1
    }
    if ($items.Count -gt $recommended) {
        Write-ReviewLoopStatus -Message "Alternative:" -Kind Info
        for ($index = $recommended; $index -lt $items.Count; $index++) {
            Write-ReviewLoopStatus `
                -Message $items[$index] `
                -Kind Muted `
                -Indent 1
        }
    }
}

function Write-ReviewLoopRule {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [ValidateSet("Info", "Progress", "Success", "Warning", "Error", "Review", "Architecture")]
        [string]$Kind = "Progress"
    )

    $width = Get-ReviewLoopConsoleWidth
    $label = " $Title "
    $remaining = [Math]::Max(3, $width - $label.Length)
    $left = [Math]::Floor($remaining / 2)
    $right = $remaining - $left
    $style = Get-ReviewLoopConsoleStyle -Kind $Kind
    Write-ReviewLoopConsoleLine -Text "$(("-" * $left))$label$(("-" * $right))" -Style $style
}

function Write-ReviewLoopKeyValue {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][object]$Value,
        [int]$Indent = 1
    )
    Write-ReviewLoopStatus -Message ("{0,-16} {1}" -f "${Name}:", [string]$Value) -Kind Muted -Indent $Indent
}

function Write-ReviewLoopResultBlock {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Values,
        [ValidateSet("Success", "Warning", "Error", "Review")][string]$Kind = "Success"
    )

    Write-ReviewLoopRule -Title $Title -Kind $Kind
    foreach ($entry in $Values.GetEnumerator()) {
        Write-ReviewLoopKeyValue -Name ([string]$entry.Key) -Value $entry.Value
    }
}

function Write-ReviewLoopFailureSummary {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Problem,
        [Parameter(Mandatory = $true)][string]$Status,
        [AllowEmptyCollection()][string[]]$NextSteps = @(),
        [ValidateRange(0, 100)][int]$RecommendedStepCount = 1,
        [int]$Cycles = 0,
        [string]$CleanPasses = "",
        [int]$OpenFindings = 0,
        [int]$BlockedFindings = 0,
        [string]$RunRoot = "",
        [string]$LedgerPath = "",
        [string]$TranscriptPath = ""
    )

    if (Test-ReviewLoopOutputLevel -Minimum detailed) {
        Write-ReviewLoopRule -Title $Title -Kind Error
        Write-ReviewLoopStatus -Message $Problem -Kind Error
        Write-ReviewLoopKeyValue -Name "Status" -Value $Status
        Write-ReviewLoopKeyValue -Name "Cycles" -Value $Cycles
        if (-not [string]::IsNullOrWhiteSpace($CleanPasses)) {
            Write-ReviewLoopKeyValue -Name "Clean passes" -Value $CleanPasses
        }
        Write-ReviewLoopKeyValue -Name "Open findings" -Value $OpenFindings
        Write-ReviewLoopKeyValue -Name "Blocked findings" -Value $BlockedFindings
        if (-not [string]::IsNullOrWhiteSpace($RunRoot)) {
            Write-ReviewLoopKeyValue -Name "Run" -Value $RunRoot
        }
        if (-not [string]::IsNullOrWhiteSpace($LedgerPath)) {
            Write-ReviewLoopKeyValue -Name "Ledger" -Value $LedgerPath
        }
    }
    elseif (Test-ReviewLoopOutputLevel -Minimum balanced) {
        Write-ReviewLoopRule -Title $Title -Kind Error
        Write-ReviewLoopStatus -Message $Problem -Kind Error
        Write-ReviewLoopKeyValue -Name "Status" -Value $Status
        Write-ReviewLoopKeyValue -Name "Cycles" -Value $Cycles
        Write-ReviewLoopKeyValue -Name "Open findings" -Value $OpenFindings
        Write-ReviewLoopKeyValue -Name "Blocked findings" -Value $BlockedFindings
        if (-not [string]::IsNullOrWhiteSpace($RunRoot)) {
            Write-ReviewLoopKeyValue -Name "Run" -Value (Split-Path -Leaf $RunRoot)
        }
    }
    else {
        Write-ReviewLoopStatus -Message "${Title}: $Problem" -Kind Error
    }

    Write-ReviewLoopNextSteps `
        -Steps $NextSteps `
        -RecommendedCount $RecommendedStepCount
    if (-not [string]::IsNullOrWhiteSpace($TranscriptPath)) {
        Write-ReviewLoopStatus -Message "Details: $TranscriptPath" -Kind Muted
    }
}

function Write-ReviewLoopCompletionSummary {
    param(
        [Parameter(Mandatory = $true)][int]$Cycles,
        [Parameter(Mandatory = $true)][string]$CleanPasses,
        [Parameter(Mandatory = $true)][string]$RunRoot,
        [Parameter(Mandatory = $true)][string]$LedgerPath,
        [Parameter(Mandatory = $true)][string]$TranscriptPath
    )

    if (Test-ReviewLoopOutputLevel -Minimum detailed) {
        Write-ReviewLoopResultBlock -Title "Review Loop completed" -Kind Success -Values ([ordered]@{
            Status = "completed"
            Cycles = $Cycles
            "Clean passes" = $CleanPasses
            "Open findings" = 0
            "Blocked findings" = 0
            Run = $RunRoot
            Ledger = $LedgerPath
            Transcript = $TranscriptPath
        })
        return
    }

    Write-ReviewLoopStatus `
        -Message "Review Loop completed · $Cycles cycles · $CleanPasses clean passes" `
        -Kind Success
    if (Test-ReviewLoopOutputLevel -Minimum balanced) {
        Write-ReviewLoopKeyValue -Name "Run" -Value (Split-Path -Leaf $RunRoot)
    }
    Write-ReviewLoopStatus -Message "Details: $TranscriptPath" -Kind Muted
}
