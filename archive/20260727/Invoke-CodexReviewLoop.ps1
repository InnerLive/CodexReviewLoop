param(
    [Parameter(Position = 0)]
    [string]$RepoPath = "",
    [int]$MaxIterations = 16,
    [int]$PassesRequired = 2,
    [string]$Model = "gpt-5.6-sol",
    [Alias("Thinking", "ReasoningEffort")]
    [ValidateSet("low", "medium", "high", "xhigh", "max", "ultra")]
    [string]$ReviewThinking = "high",
    [ValidateSet("low", "medium", "high", "xhigh", "max", "ultra")]
    [string]$FixerThinking = "high",
    [Alias("Tempo", "ServiceTier")]
    [ValidateSet("standard", "fast", "priority")]
    [string]$Speed = "standard",
    [string]$BaseBranch = "",
    [string]$LogRoot = "",
    [string]$ReviewPrompt = "",
    [string]$FixPromptPrefix = "Review. Löse die Probleme produktgetrieben, nachhaltig, wartbar und denke gründlich über die Auswirkungen deiner Änderungen nach. Denke produktgetrieben und vorraus, damit wir vielleicht ein paar Reviews sparen können.",
    [string]$FixerThreadId = "",
    [string]$CommitMessageFallback = "Fix review findings",
    [string]$ReviewClassifierModel = "gpt-5.4-nano",
    [int]$ReviewClassifierMaxRateLimitWaitSeconds = 900,
    [switch]$RespectCodexRules,
    [switch]$UseCodexSandbox,
    [switch]$AllowDirtyWorktree,
    [switch]$DisableModelReviewClassifier,
    [switch]$DisableRestartGuard,
    [switch]$DisableLastUnfixedReviewRecovery,
    [ValidateSet("Legacy", "Dual", "Structured")]
    [string]$ReviewResultMode = "Dual",
    [ValidateSet("Off", "Observe", "Enforce")]
    [string]$ArchitectureMode = "Enforce",
    [ValidateRange(2, 20)]
    [int]$ArchitectureRepeatThreshold = 2,
    [ValidateRange(1, 20)]
    [int]$ArchitectureHotspotFixThreshold = 2,
    [string]$ArchitectureModel = "",
    [ValidateSet("low", "medium", "high", "xhigh", "max", "ultra")]
    [string]$ArchitectureThinking = "max",
    [ValidateSet("low", "medium", "high", "xhigh", "max", "ultra")]
    [string]$ArchitectureFixerThinking = "max",
    [string]$ArchitectureDecisionPath = "",
    [switch]$ArchitectureAutoApplyLocal = $true,
    [switch]$ArchitectureAutoApplyAll,
    [switch]$DisableArchitectureAutoApplyLocal,
    [switch]$DisableInteractiveArchitectureGate,
    [ValidateSet("Host", "Ansi", "Always", "Auto", "Never")]
    [string]$ColorMode = "Host",
    [switch]$Help
)

$ErrorActionPreference = "Stop"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$env:PYTHONIOENCODING = "utf-8"
$env:LC_ALL = "C.UTF-8"
$env:LANG = "C.UTF-8"
$script:RespectCodexRulesSetting = [bool]$RespectCodexRules
$script:RestartGuard = $null
$script:RunState = $null
$script:InvocationBoundParameters = @{} + $PSBoundParameters

function Get-ConsoleWidth {
    try {
        $width = [Console]::WindowWidth
        if ($width -gt 0) {
            return [Math]::Min(120, [Math]::Max(72, $width - 1))
        }
    } catch {
    }

    return 88
}

function Enable-AnsiConsoleColor {
    param([string]$Mode = "Always")

    if ($Mode -in @("Host", "Never")) {
        return $false
    }

    if ($Mode -eq "Auto") {
        if (-not [string]::IsNullOrWhiteSpace($env:NO_COLOR)) {
            return $false
        }
        if ($env:TERM -eq "dumb") {
            return $false
        }
        if ([Console]::IsOutputRedirected -and [Console]::IsErrorRedirected) {
            return $false
        }
    }

    try {
        if ($null -ne (Get-Variable -Name PSStyle -Scope Global -ErrorAction SilentlyContinue)) {
            $global:PSStyle.OutputRendering = "Ansi"
        }

        if (-not ([System.Management.Automation.PSTypeName]"CodexReviewLoopConsole").Type) {
            Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class CodexReviewLoopConsole {
    private const int STD_OUTPUT_HANDLE = -11;
    private const int STD_ERROR_HANDLE = -12;
    private const int ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004;

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GetStdHandle(int nStdHandle);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetConsoleMode(IntPtr hConsoleHandle, out int lpMode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetConsoleMode(IntPtr hConsoleHandle, int dwMode);

    public static void EnableVirtualTerminalProcessing() {
        EnableForHandle(STD_OUTPUT_HANDLE);
        EnableForHandle(STD_ERROR_HANDLE);
    }

    private static void EnableForHandle(int handleId) {
        IntPtr handle = GetStdHandle(handleId);
        int mode;
        if (handle == IntPtr.Zero || !GetConsoleMode(handle, out mode)) {
            return;
        }
        SetConsoleMode(handle, mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
    }
}
"@
        }

        [CodexReviewLoopConsole]::EnableVirtualTerminalProcessing()
    } catch {
    }

    return $true
}

$script:UseAnsiColor = Enable-AnsiConsoleColor -Mode $ColorMode
$script:UseHostColor = ($ColorMode -eq "Host" -or (
    $ColorMode -eq "Auto" -and
    [string]::IsNullOrWhiteSpace($env:NO_COLOR) -and
    $env:TERM -ne "dumb" -and
    (-not [Console]::IsOutputRedirected -or -not [Console]::IsErrorRedirected)
))
$script:AnsiReset = "$([char]27)[0m"

function Get-AnsiForegroundCode {
    param([ConsoleColor]$Color)

    switch ($Color) {
        ([ConsoleColor]::Black) { return 30 }
        ([ConsoleColor]::DarkRed) { return 31 }
        ([ConsoleColor]::DarkGreen) { return 32 }
        ([ConsoleColor]::DarkYellow) { return 33 }
        ([ConsoleColor]::DarkBlue) { return 34 }
        ([ConsoleColor]::DarkMagenta) { return 35 }
        ([ConsoleColor]::DarkCyan) { return 36 }
        ([ConsoleColor]::Gray) { return 37 }
        ([ConsoleColor]::DarkGray) { return 90 }
        ([ConsoleColor]::Red) { return 91 }
        ([ConsoleColor]::Green) { return 92 }
        ([ConsoleColor]::Yellow) { return 93 }
        ([ConsoleColor]::Blue) { return 94 }
        ([ConsoleColor]::Magenta) { return 95 }
        ([ConsoleColor]::Cyan) { return 96 }
        default { return 97 }
    }
}

function Format-AnsiText {
    param(
        [AllowNull()][string]$Text,
        [Nullable[ConsoleColor]]$ForegroundColor = $null,
        [Nullable[ConsoleColor]]$BackgroundColor = $null,
        [switch]$Bold
    )

    if (-not $script:UseAnsiColor) {
        return $Text
    }

    $codes = New-Object System.Collections.Generic.List[string]
    if ($Bold) {
        $codes.Add("1") | Out-Null
    }
    if ($ForegroundColor.HasValue) {
        $codes.Add([string](Get-AnsiForegroundCode $ForegroundColor.Value)) | Out-Null
    }
    if ($BackgroundColor.HasValue) {
        $codes.Add([string]((Get-AnsiForegroundCode $BackgroundColor.Value) + 10)) | Out-Null
    }

    if ($codes.Count -eq 0) {
        return $Text
    }

    return "$([char]27)[" + ($codes -join ";") + "m" + $Text + $script:AnsiReset
}

function Write-ConsoleLine {
    param(
        [AllowNull()][string]$Text = "",
        [Nullable[ConsoleColor]]$ForegroundColor = $null,
        [Nullable[ConsoleColor]]$BackgroundColor = $null,
        [switch]$ErrorStream,
        [switch]$Bold
    )

    $writer = if ($ErrorStream) { [Console]::Error } else { [Console]::Out }
    if ($script:UseHostColor) {
        $parameters = @{}
        if ($ForegroundColor.HasValue) {
            $parameters.ForegroundColor = $ForegroundColor.Value
        }
        if ($BackgroundColor.HasValue) {
            $parameters.BackgroundColor = $BackgroundColor.Value
        }
        Write-Host $Text @parameters
        return
    }

    if ($script:UseAnsiColor) {
        $writer.WriteLine((Format-AnsiText -Text $Text -ForegroundColor $ForegroundColor -BackgroundColor $BackgroundColor -Bold:$Bold))
        return
    }

    $previousForeground = [Console]::ForegroundColor
    $previousBackground = [Console]::BackgroundColor

    try {
        if ($ForegroundColor.HasValue) {
            [Console]::ForegroundColor = $ForegroundColor.Value
        }
        if ($BackgroundColor.HasValue) {
            [Console]::BackgroundColor = $BackgroundColor.Value
        }
        $writer.WriteLine($Text)
    } finally {
        [Console]::ForegroundColor = $previousForeground
        [Console]::BackgroundColor = $previousBackground
    }
}

function Write-ConsoleSegments {
    param(
        [object[]]$Segments,
        [switch]$ErrorStream
    )

    $writer = if ($ErrorStream) { [Console]::Error } else { [Console]::Out }
    if ($script:UseHostColor) {
        foreach ($segment in @($Segments)) {
            $text = if ($null -eq $segment.Text) { "" } else { [string]$segment.Text }
            $parameters = @{ NoNewline = $true }
            if ($segment.ContainsKey("ForegroundColor") -and $null -ne $segment.ForegroundColor) {
                $parameters.ForegroundColor = $segment.ForegroundColor
            }
            if ($segment.ContainsKey("BackgroundColor") -and $null -ne $segment.BackgroundColor) {
                $parameters.BackgroundColor = $segment.BackgroundColor
            }
            Write-Host $text @parameters
        }
        Write-Host ""
        return
    }

    if ($script:UseAnsiColor) {
        foreach ($segment in @($Segments)) {
            $text = if ($null -eq $segment.Text) { "" } else { [string]$segment.Text }
            $color = if ($segment.ContainsKey("ForegroundColor")) { $segment.ForegroundColor } else { $null }
            $background = if ($segment.ContainsKey("BackgroundColor")) { $segment.BackgroundColor } else { $null }
            $bold = if ($segment.ContainsKey("Bold")) { [bool]$segment.Bold } else { $false }
            $writer.Write((Format-AnsiText -Text $text -ForegroundColor $color -BackgroundColor $background -Bold:$bold))
        }
        $writer.WriteLine("")
        return
    }

    $previousForeground = [Console]::ForegroundColor
    $previousBackground = [Console]::BackgroundColor
    try {
        foreach ($segment in @($Segments)) {
            if ($segment.ContainsKey("ForegroundColor") -and $null -ne $segment.ForegroundColor) {
                [Console]::ForegroundColor = $segment.ForegroundColor
            } else {
                [Console]::ForegroundColor = $previousForeground
            }
            if ($segment.ContainsKey("BackgroundColor") -and $null -ne $segment.BackgroundColor) {
                [Console]::BackgroundColor = $segment.BackgroundColor
            } else {
                [Console]::BackgroundColor = $previousBackground
            }

            $writer.Write($(if ($null -eq $segment.Text) { "" } else { [string]$segment.Text }))
        }
        $writer.WriteLine("")
    } finally {
        [Console]::ForegroundColor = $previousForeground
        [Console]::BackgroundColor = $previousBackground
    }
}

function Get-DisplayColor {
    param([string]$Kind = "Info")

    switch ($Kind.ToLowerInvariant()) {
        "success" { return [ConsoleColor]::Green }   # erledigt/sauber
        "warning" { return [ConsoleColor]::Yellow }  # Aufmerksamkeit/Funde/Retry
        "error" { return [ConsoleColor]::Red }       # Fehler/Abbruch
        "review" { return [ConsoleColor]::Magenta }  # externe Reviewer-Meldung
        "architecture" { return [ConsoleColor]::Cyan } # Architekturbericht/-entscheidung
        "fixer" { return [ConsoleColor]::Blue }      # Fixer-Antwort
        "git" { return [ConsoleColor]::DarkYellow }  # Git-Ausgaben
        "step" { return [ConsoleColor]::Cyan }       # Phase/Iteration/Fortschritt
        "summary" { return [ConsoleColor]::Green }   # Abschluss/Zusammenfassung
        "info" { return [ConsoleColor]::Gray }
        "muted" { return [ConsoleColor]::DarkGray }
        "output" { return [ConsoleColor]::Gray }
        default { return [ConsoleColor]::White }
    }
}

function Get-StatusMessageColor {
    param([string]$Kind = "Info")

    switch ($Kind.ToLowerInvariant()) {
        "success" { return [ConsoleColor]::Green }
        "warning" { return [ConsoleColor]::Yellow }
        "error" { return [ConsoleColor]::Red }
        "review" { return [ConsoleColor]::Magenta }
        "progress" { return [ConsoleColor]::Cyan }
        "info" { return [ConsoleColor]::Gray }
        default { return [ConsoleColor]::White }
    }
}

function Get-BoxLineStyle {
    param(
        [string]$Line,
        [string]$Kind,
        [string]$LineRole = ""
    )

    $baseColor = Get-DisplayColor $Kind
    $trimmed = if ($null -eq $Line) { "" } else { $Line.Trim() }

    if ($Kind -eq "Error") {
        switch ($LineRole) {
            "Cause" { return @{ LabelColor = [ConsoleColor]::Yellow; ValueColor = [ConsoleColor]::Red; BoldLabel = $true; BoldValue = $true } }
            "ErrorHeader" { return @{ LabelColor = [ConsoleColor]::Red; ValueColor = [ConsoleColor]::Red; BoldLabel = $true; BoldValue = $true } }
            "ErrorDetail" { return @{ LabelColor = [ConsoleColor]::Red; ValueColor = [ConsoleColor]::Red; BoldLabel = $true; BoldValue = $true } }
            "WarningHeader" { return @{ LabelColor = [ConsoleColor]::Yellow; ValueColor = [ConsoleColor]::Yellow; BoldLabel = $true; BoldValue = $true } }
            "WarningDetail" { return @{ LabelColor = [ConsoleColor]::Yellow; ValueColor = [ConsoleColor]::Yellow; BoldLabel = $true; BoldValue = $false } }
            "Advice" { return @{ LabelColor = [ConsoleColor]::Green; ValueColor = [ConsoleColor]::White; BoldLabel = $true; BoldValue = $false } }
            "Details" { return @{ LabelColor = [ConsoleColor]::Cyan; ValueColor = [ConsoleColor]::White; BoldLabel = $true; BoldValue = $false } }
            "Summary" { return @{ LabelColor = [ConsoleColor]::Red; ValueColor = [ConsoleColor]::White; BoldLabel = $false; BoldValue = $true } }
        }

        if ($trimmed -match "^(Fehlerdetails|Fehlgeschlagene interne Befehle|Wahrscheinliche Ursache):") {
            return @{ LabelColor = [ConsoleColor]::Yellow; ValueColor = [ConsoleColor]::Red; BoldLabel = $true; BoldValue = $true }
        }
        if ($trimmed -match "^(Nächster Schritt):") {
            return @{ LabelColor = [ConsoleColor]::Green; ValueColor = [ConsoleColor]::White; BoldLabel = $true; BoldValue = $false }
        }
        if ($trimmed -match "^(Details|Codex-Thread):") {
            return @{ LabelColor = [ConsoleColor]::Cyan; ValueColor = [ConsoleColor]::White; BoldLabel = $true; BoldValue = $false }
        }
        if ($trimmed -match "^(Hinweise):") {
            return @{ LabelColor = [ConsoleColor]::Yellow; ValueColor = [ConsoleColor]::White; BoldLabel = $true; BoldValue = $false }
        }
        if ($trimmed -match "^\- ") {
            return @{ LabelColor = [ConsoleColor]::Red; ValueColor = [ConsoleColor]::White; BoldLabel = $true; BoldValue = $true }
        }
        return @{ LabelColor = [ConsoleColor]::Red; ValueColor = [ConsoleColor]::White; BoldLabel = $false; BoldValue = $true }
    }

    if ($Kind -eq "Review") {
        if ($trimmed -match "^\-\s*(\[[A-Z]+\d+\])?") {
            return @{ LabelColor = [ConsoleColor]::Yellow; ValueColor = [ConsoleColor]::White; BoldLabel = $true; BoldValue = $false }
        }
        if ($trimmed -match "^(Full review comments?|Review comments?|Findings?|Funde):") {
            return @{ LabelColor = [ConsoleColor]::Magenta; ValueColor = [ConsoleColor]::Magenta; BoldLabel = $true; BoldValue = $true }
        }
        return @{ LabelColor = [ConsoleColor]::Magenta; ValueColor = [ConsoleColor]::White; BoldLabel = $false; BoldValue = $false }
    }

    if ($Kind -eq "Architecture") {
        switch ($LineRole) {
            "ArchitectureTitle" {
                return @{ LabelColor = [ConsoleColor]::Cyan; ValueColor = [ConsoleColor]::White; BoldLabel = $true; BoldValue = $true }
            }
            "ArchitectureSection" {
                return @{ LabelColor = [ConsoleColor]::Cyan; ValueColor = [ConsoleColor]::Cyan; BoldLabel = $true; BoldValue = $true }
            }
            "ArchitectureRecommendation" {
                $recommendationColor = if ($trimmed -match "(?i)\bapprove_strategy\b") {
                    [ConsoleColor]::Green
                } elseif ($trimmed -match "(?i)\babort\b") {
                    [ConsoleColor]::Red
                } else {
                    [ConsoleColor]::Yellow
                }
                return @{ LabelColor = $recommendationColor; ValueColor = $recommendationColor; BoldLabel = $true; BoldValue = $true }
            }
            "ArchitectureScope" {
                $scopeColor = if ($trimmed -match "(?i)^Scope:\s*local\s*$") {
                    [ConsoleColor]::Green
                } else {
                    [ConsoleColor]::Yellow
                }
                return @{ LabelColor = [ConsoleColor]::Cyan; ValueColor = $scopeColor; BoldLabel = $true; BoldValue = $true }
            }
            "ArchitectureLabel" {
                return @{ LabelColor = [ConsoleColor]::Cyan; ValueColor = [ConsoleColor]::White; BoldLabel = $true; BoldValue = $false }
            }
            "ArchitectureSubsection" {
                return @{ LabelColor = [ConsoleColor]::Cyan; ValueColor = [ConsoleColor]::Cyan; BoldLabel = $true; BoldValue = $true }
            }
            "ArchitectureNumbered" {
                return @{ LabelColor = [ConsoleColor]::Cyan; ValueColor = [ConsoleColor]::White; BoldLabel = $true; BoldValue = $true }
            }
            "ArchitecturePath" {
                return @{ LabelColor = [ConsoleColor]::DarkYellow; ValueColor = [ConsoleColor]::DarkYellow; BoldLabel = $true; BoldValue = $false }
            }
            "ArchitectureRisk" {
                return @{ LabelColor = [ConsoleColor]::Yellow; ValueColor = [ConsoleColor]::Yellow; BoldLabel = $true; BoldValue = $false }
            }
            "ArchitectureBullet" {
                return @{ LabelColor = [ConsoleColor]::Yellow; ValueColor = [ConsoleColor]::White; BoldLabel = $true; BoldValue = $false }
            }
        }
        return @{ LabelColor = [ConsoleColor]::Cyan; ValueColor = [ConsoleColor]::White; BoldLabel = $false; BoldValue = $false }
    }

    if ($Kind -eq "Fixer") {
        if ($trimmed -match "^(Commit|Commit message|Commit-Message|Titel|Title):") {
            return @{ LabelColor = [ConsoleColor]::Green; ValueColor = [ConsoleColor]::Green; BoldLabel = $true; BoldValue = $true }
        }
        if ($trimmed -match "^(Tests?|Prüfung|Zusammenfassung|Summary|Geändert|Changed):") {
            return @{ LabelColor = [ConsoleColor]::Cyan; ValueColor = [ConsoleColor]::White; BoldLabel = $true; BoldValue = $false }
        }
        if ($trimmed -match "^\- ") {
            return @{ LabelColor = [ConsoleColor]::Cyan; ValueColor = [ConsoleColor]::White; BoldLabel = $true; BoldValue = $false }
        }
        return @{ LabelColor = [ConsoleColor]::Blue; ValueColor = [ConsoleColor]::White; BoldLabel = $false; BoldValue = $false }
    }

    if ($Kind -eq "Git") {
        if ($trimmed -match "(?i)\b(error|fatal|failed|conflict)\b") {
            return @{ LabelColor = [ConsoleColor]::Red; ValueColor = [ConsoleColor]::Red; BoldLabel = $true; BoldValue = $true }
        }
        if ($trimmed -match "(?i)\b(warning|warnung)\b") {
            return @{ LabelColor = [ConsoleColor]::Yellow; ValueColor = [ConsoleColor]::Yellow; BoldLabel = $true; BoldValue = $false }
        }
        return @{ LabelColor = [ConsoleColor]::DarkYellow; ValueColor = [ConsoleColor]::White; BoldLabel = $false; BoldValue = $false }
    }

    return @{ LabelColor = $baseColor; ValueColor = $baseColor; BoldLabel = $false; BoldValue = $false }
}

function Write-BoxContentLine {
    param(
        [string]$Line,
        [int]$InnerWidth,
        [string]$Kind,
        [string]$LineRole = "",
        [switch]$ErrorStream
    )

    $borderColor = Get-DisplayColor $Kind
    $style = Get-BoxLineStyle -Line $Line -Kind $Kind -LineRole $LineRole
    $paddedLine = $Line.PadRight($InnerWidth)
    $segments = New-Object System.Collections.Generic.List[object]
    $segments.Add(@{ Text = "| "; ForegroundColor = $borderColor; Bold = $true }) | Out-Null

    $labelMatch = [regex]::Match($Line, "^(\s*[^:]{1,36}:)(\s*)(.*)$")
    if ($labelMatch.Success -and $Kind -in @("Error", "Output", "Success", "Warning", "Review", "Architecture", "Fixer", "Git")) {
        $label = $labelMatch.Groups[1].Value
        $spacing = $labelMatch.Groups[2].Value
        $value = $labelMatch.Groups[3].Value
        $remainingPadding = " " * [Math]::Max(0, $InnerWidth - $Line.Length)
        $segments.Add(@{ Text = $label; ForegroundColor = $style.LabelColor; Bold = $style.BoldLabel }) | Out-Null
        $segments.Add(@{ Text = $spacing; ForegroundColor = $style.ValueColor; Bold = $style.BoldValue }) | Out-Null
        $segments.Add(@{ Text = $value + $remainingPadding; ForegroundColor = $style.ValueColor; Bold = $style.BoldValue }) | Out-Null
    } elseif (
        $Kind -eq "Architecture" -and
        $LineRole -eq "ArchitectureNumbered" -and
        $Line -match "^(\s*\d+\.\s*)(.*)$"
    ) {
        $marker = $Matches[1]
        $rest = $Matches[2]
        $remainingPadding = " " * [Math]::Max(0, $InnerWidth - $Line.Length)
        $segments.Add(@{ Text = $marker; ForegroundColor = [ConsoleColor]::Cyan; Bold = $true }) | Out-Null
        $segments.Add(@{ Text = $rest + $remainingPadding; ForegroundColor = [ConsoleColor]::White; Bold = $true }) | Out-Null
    } elseif (
        $Kind -eq "Architecture" -and
        $LineRole -in @("ArchitectureBullet", "ArchitecturePath", "ArchitectureRisk") -and
        $Line -match "^(\s*-\s*)(.*)$"
    ) {
        $marker = $Matches[1]
        $rest = $Matches[2]
        $markerColor = if ($LineRole -eq "ArchitecturePath") { [ConsoleColor]::DarkYellow } else { [ConsoleColor]::Yellow }
        $valueColor = switch ($LineRole) {
            "ArchitecturePath" { [ConsoleColor]::DarkYellow }
            "ArchitectureRisk" { [ConsoleColor]::Yellow }
            default { [ConsoleColor]::White }
        }
        $remainingPadding = " " * [Math]::Max(0, $InnerWidth - $Line.Length)
        $segments.Add(@{ Text = $marker; ForegroundColor = $markerColor; Bold = $true }) | Out-Null
        $segments.Add(@{ Text = $rest + $remainingPadding; ForegroundColor = $valueColor; Bold = $false }) | Out-Null
    } elseif ($Kind -eq "Review" -and $Line.TrimStart() -match "^\-") {
        $markerLength = $Line.Length - $Line.TrimStart().Length + 1
        $marker = $Line.Substring(0, [Math]::Min($markerLength, $Line.Length))
        $rest = if ($Line.Length -gt $marker.Length) { $Line.Substring($marker.Length) } else { "" }
        $remainingPadding = " " * [Math]::Max(0, $InnerWidth - $Line.Length)
        $segments.Add(@{ Text = $marker; ForegroundColor = [ConsoleColor]::Yellow; Bold = $true }) | Out-Null
        $segments.Add(@{ Text = $rest + $remainingPadding; ForegroundColor = [ConsoleColor]::White; Bold = $false }) | Out-Null
    } else {
        $segments.Add(@{ Text = $paddedLine; ForegroundColor = $style.ValueColor; Bold = $style.BoldValue }) | Out-Null
    }

    $segments.Add(@{ Text = " |"; ForegroundColor = $borderColor; Bold = $true }) | Out-Null
    Write-ConsoleSegments -Segments $segments.ToArray() -ErrorStream:([bool]$ErrorStream)
}

function ConvertTo-WrappedConsoleLines {
    param(
        [AllowNull()][string]$Text,
        [int]$Width,
        [int]$ContinuationIndent = 0,
        [switch]$BreakOnPathSeparators
    )

    if ($Width -lt 20) {
        $Width = 20
    }

    if ($null -eq $Text) {
        return @("")
    }

    $result = New-Object System.Collections.Generic.List[string]
    $normalized = ($Text -replace "`r`n", "`n") -replace "`r", "`n"
    foreach ($rawLine in ($normalized -split "`n")) {
        $line = $rawLine.TrimEnd()
        if ([string]::IsNullOrWhiteSpace($line)) {
            $result.Add("") | Out-Null
            continue
        }

        while ($line.Length -gt $Width) {
            $limit = [Math]::Min($Width, $line.Length)
            $breakAt = -1
            for ($i = $limit; $i -gt 0; $i--) {
                if ([char]::IsWhiteSpace($line[$i - 1])) {
                    $breakAt = $i - 1
                    break
                }
            }

            if ($breakAt -lt 20 -and $BreakOnPathSeparators) {
                for ($i = $limit; $i -gt 0; $i--) {
                    if ($line[$i - 1] -in @("/", "\")) {
                        $breakAt = $i
                        break
                    }
                }
            }

            if ($breakAt -lt 20) {
                $breakAt = $limit
            }

            $result.Add($line.Substring(0, $breakAt).TrimEnd()) | Out-Null
            $continuationPrefix = " " * [Math]::Max(0, $ContinuationIndent)
            $line = $continuationPrefix + $line.Substring($breakAt).TrimStart()
        }

        $result.Add($line) | Out-Null
    }

    return @($result)
}

function Write-Rule {
    param(
        [string]$Title = "",
        [string]$Kind = "Step"
    )

    Write-ConsoleLine ""
    $width = Get-ConsoleWidth
    $color = Get-DisplayColor $Kind
    if (-not [string]::IsNullOrWhiteSpace($Title)) {
        $label = "== $Title "
        $fill = "=" * [Math]::Max(4, $width - $label.Length)
        Write-ConsoleLine ($label + $fill) -ForegroundColor $color -Bold
        return
    }

    Write-ConsoleLine ("-" * $width) -ForegroundColor (Get-DisplayColor "Muted")
}

function Write-KeyValue {
    param(
        [string]$Key,
        [string]$Value
    )

    $text = if ($null -eq $Value) { "" } else { [string]$Value }
    $label = "  {0,-28} " -f ($Key + ":")
    $valueWidth = [Math]::Max(20, (Get-ConsoleWidth) - $label.Length)
    $lines = @(ConvertTo-WrappedConsoleLines -Text $text -Width $valueWidth)
    if ($lines.Count -eq 0) {
        $lines = @("")
    }

    Write-ConsoleSegments -Segments @(
        @{ Text = $label; ForegroundColor = [ConsoleColor]::Cyan; Bold = $true },
        @{ Text = $lines[0]; ForegroundColor = [ConsoleColor]::White; Bold = $false }
    )
    foreach ($line in @($lines | Select-Object -Skip 1)) {
        Write-ConsoleSegments -Segments @(
            @{ Text = " " * $label.Length; ForegroundColor = [ConsoleColor]::DarkGray; Bold = $false },
            @{ Text = $line; ForegroundColor = [ConsoleColor]::White; Bold = $false }
        )
    }
}

function Write-Paragraph {
    param(
        [string]$Text,
        [int]$Indent = 2,
        [string]$Kind = "Info"
    )

    $prefix = " " * $Indent
    $lineWidth = [Math]::Max(20, (Get-ConsoleWidth) - $Indent)
    $color = Get-DisplayColor $Kind

    foreach ($line in (ConvertTo-WrappedConsoleLines -Text $Text -Width $lineWidth)) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            Write-ConsoleLine ""
            continue
        }
        Write-ConsoleLine ($prefix + $line) -ForegroundColor $color
    }
}

function Write-MenuChoice {
    param(
        [string]$Key,
        [string]$Text,
        [ConsoleColor]$Color
    )

    Write-ConsoleSegments -Segments @(
        @{ Text = "  [$Key]"; ForegroundColor = $Color; Bold = $true },
        @{ Text = " $Text"; ForegroundColor = [ConsoleColor]::White; Bold = $false }
    )
}

function Write-TextBlock {
    param(
        [string]$Title,
        [string]$Text,
        [string]$Kind = "Output"
    )

    if ($Kind -in @("Architecture", "Fixer", "Git", "Warning", "Error", "Success")) {
        Write-BoxedText -Title $Title -Text $Text -Kind $Kind -ErrorStream:($Kind -eq "Error")
        return
    }

    Write-Rule $Title $Kind
    if ([string]::IsNullOrWhiteSpace($Text)) {
        Write-Paragraph "(keine Ausgabe)" -Kind "Muted"
        return
    }

    Write-Paragraph $Text -Kind $Kind
}

function Write-BoxedText {
    param(
        [string]$Title,
        [string]$Text,
        [string]$Kind = "Review",
        [switch]$ErrorStream
    )

    $width = Get-ConsoleWidth
    $innerWidth = [Math]::Max(30, $width - 4)
    $color = Get-DisplayColor $Kind
    $streamSwitch = @{ ErrorStream = [bool]$ErrorStream }

    Write-ConsoleLine "" @streamSwitch
    $label = " $Title "
    $topFill = "-" * [Math]::Max(0, $width - $label.Length - 2)
    Write-ConsoleLine ("+" + $label + $topFill + "+") -ForegroundColor $color -Bold @streamSwitch

    $content = if ([string]::IsNullOrWhiteSpace($Text)) { "(keine Ausgabe)" } else { $Text }
    $normalized = ($content -replace "`r`n", "`n") -replace "`r", "`n"
    $currentErrorSection = ""
    $currentArchitectureSection = ""
    $currentArchitectureSubsection = ""
    $architectureTitleSeen = $false
    foreach ($rawLine in ($normalized -split "`n")) {
        $lineRole = ""
        if ($Kind -eq "Error") {
            $trimmed = $rawLine.Trim()
            if ($trimmed -match "^Wahrscheinliche Ursache:") {
                $lineRole = "Cause"
                $currentErrorSection = "Cause"
            } elseif ($trimmed -match "^(Fehlerdetails|Fehlgeschlagene interne Befehle):") {
                $lineRole = "ErrorHeader"
                $currentErrorSection = "Errors"
            } elseif ($trimmed -match "^Hinweise:") {
                $lineRole = "WarningHeader"
                $currentErrorSection = "Warnings"
            } elseif ($trimmed -match "^Nächster Schritt:") {
                $lineRole = "Advice"
                $currentErrorSection = "Advice"
            } elseif ($trimmed -match "^(Details|Codex-Thread):") {
                $lineRole = "Details"
                $currentErrorSection = "Details"
            } elseif ($trimmed -match "^- " -and $currentErrorSection -eq "Errors") {
                $lineRole = "ErrorDetail"
            } elseif ($trimmed -match "^- " -and $currentErrorSection -eq "Warnings") {
                $lineRole = "WarningDetail"
            } elseif (-not [string]::IsNullOrWhiteSpace($trimmed)) {
                $lineRole = "Summary"
            }
        } elseif ($Kind -eq "Architecture") {
            $trimmed = $rawLine.Trim()
            if (-not $architectureTitleSeen -and -not [string]::IsNullOrWhiteSpace($trimmed)) {
                $lineRole = "ArchitectureTitle"
                $architectureTitleSeen = $true
            } elseif ($trimmed -match "^(URSACHE|EVIDENZ|INVARIANTEN|STRATEGIE|RISIKEN|KOMPATIBILITÄT|ROLLBACK)$") {
                $lineRole = "ArchitectureSection"
                $currentArchitectureSection = $trimmed
                $currentArchitectureSubsection = ""
            } elseif ($trimmed -match "^Empfehlung:") {
                $lineRole = "ArchitectureRecommendation"
            } elseif ($trimmed -match "^Scope:") {
                $lineRole = "ArchitectureScope"
            } elseif ($trimmed -match "^(Szenarien|Verifikation|Schritte|Pfade):$") {
                $lineRole = "ArchitectureSubsection"
                $currentArchitectureSubsection = $Matches[1]
            } elseif ($trimmed -match "^(Begründung|Ansatz|Erwartetes Verhalten|Test|Erwartung):") {
                $lineRole = "ArchitectureLabel"
            } elseif ($trimmed -match "^\d+\.\s+") {
                $lineRole = "ArchitectureNumbered"
                if ($currentArchitectureSection -eq "STRATEGIE") {
                    $currentArchitectureSubsection = "Schritte"
                }
            } elseif ($trimmed -match "^- ") {
                if ($currentArchitectureSubsection -eq "Pfade") {
                    $lineRole = "ArchitecturePath"
                } elseif ($currentArchitectureSection -eq "RISIKEN") {
                    $lineRole = "ArchitectureRisk"
                } else {
                    $lineRole = "ArchitectureBullet"
                }
            }
        }

        $continuationIndent = 0
        $breakOnPathSeparators = $false
        if ($Kind -eq "Architecture") {
            if ($rawLine -match "^(\s*(?:-\s+|\d+\.\s+))") {
                $continuationIndent = $Matches[1].Length
            } elseif (
                $lineRole -in @(
                    "ArchitectureLabel",
                    "ArchitectureRecommendation",
                    "ArchitectureScope"
                ) -and
                $rawLine -match "^(\s*[^:]+:\s*)"
            ) {
                $continuationIndent = $Matches[1].Length
            } elseif ($rawLine -match "^(\s+)") {
                $continuationIndent = $Matches[1].Length
            }
            $breakOnPathSeparators = $rawLine.Contains("/") -or $rawLine.Contains("\")
        }

        foreach ($line in (
            ConvertTo-WrappedConsoleLines `
                -Text $rawLine `
                -Width $innerWidth `
                -ContinuationIndent $continuationIndent `
                -BreakOnPathSeparators:$breakOnPathSeparators
        )) {
            Write-BoxContentLine -Line $line -InnerWidth $innerWidth -Kind $Kind -LineRole $lineRole @streamSwitch
        }
    }

    Write-ConsoleLine ("+" + ("-" * ($width - 2)) + "+") -ForegroundColor $color -Bold @streamSwitch
}

function Write-ReviewBlock {
    param(
        [string]$Title,
        [string]$Text
    )

    Write-BoxedText -Title $Title -Text $Text -Kind "Review"
}

function Write-ArchitectureReportBlock {
    param(
        [string]$Title,
        [object]$Report
    )

    Write-TextBlock `
        -Title $Title `
        -Text (ConvertTo-ArchitectureReportText -Report $Report) `
        -Kind "Architecture"
}

function Write-ErrorBlock {
    param(
        [string]$Title,
        [string]$Text
    )

    Write-BoxedText -Title $Title -Text $Text -Kind "Error" -ErrorStream
}

function Write-Status {
    param(
        [string]$Message,
        [ValidateSet("Info", "Progress", "Success", "Warning", "Error", "Review")]
        [string]$Kind = "Info",
        [int]$Indent = 2
    )

    $prefix = switch ($Kind) {
        "Progress" { "[..]" }
        "Success" { "[OK]" }
        "Warning" { "[!]" }
        "Error" { "[X]" }
        "Review" { "[REVIEW]" }
        default { "[i]" }
    }

    $effectiveKind = if ($Kind -eq "Progress") { "Step" } else { $Kind }
    $prefixColor = Get-DisplayColor $effectiveKind
    $messageColor = Get-StatusMessageColor $Kind
    $padding = " " * $Indent
    $lineWidth = [Math]::Max(20, (Get-ConsoleWidth) - $Indent - $prefix.Length - 1)
    $lines = @(ConvertTo-WrappedConsoleLines -Text $Message -Width $lineWidth)
    if ($lines.Count -eq 0) {
        $lines = @("")
    }

    Write-ConsoleSegments -Segments @(
        @{ Text = $padding; ForegroundColor = [ConsoleColor]::DarkGray },
        @{ Text = $prefix; ForegroundColor = $prefixColor; Bold = $true },
        @{ Text = " " + $lines[0]; ForegroundColor = $messageColor; Bold = ($Kind -in @("Success", "Warning", "Error", "Review")) }
    )
    foreach ($line in @($lines | Select-Object -Skip 1)) {
        Write-ConsoleSegments -Segments @(
            @{ Text = $padding + (" " * ($prefix.Length + 1)); ForegroundColor = [ConsoleColor]::DarkGray },
            @{ Text = $line; ForegroundColor = $messageColor; Bold = ($Kind -in @("Success", "Warning", "Error", "Review")) }
        )
    }
}

function Write-FatalMessage {
    param(
        [string]$Message,
        [int]$ExitCode = 1,
        [string]$Status = "failed",
        [string]$CompletionReason = "failed"
    )

    if ($null -ne $script:RunState) {
        $script:RunState.status = $Status
        $script:RunState.completionReason = $CompletionReason
        $script:RunState.exitCode = $ExitCode
        $script:RunState.lastError = $Message
        try {
            Save-ReviewLoopCheckpoint -State $script:RunState
        } catch {
        }
    }
    Stop-RestartGuard -Guard $script:RestartGuard
    Write-ErrorBlock "FEHLER" $Message
    exit $ExitCode
}

function Write-Utf8File {
    param(
        [string]$Path,
        [string[]]$Lines
    )

    [System.IO.File]::WriteAllLines($Path, $Lines, $Utf8NoBom)
}

function Write-Utf8TextFile {
    param(
        [string]$Path,
        [string]$Text
    )

    [System.IO.File]::WriteAllText($Path, $Text, $Utf8NoBom)
}

function Write-AtomicUtf8TextFile {
    param(
        [string]$Path,
        [string]$Text
    )

    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $temporaryPath = "$Path.$PID.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [System.IO.File]::WriteAllText($temporaryPath, $Text, $Utf8NoBom)
        [System.IO.File]::Move($temporaryPath, $Path, $true)
    } finally {
        if ([System.IO.File]::Exists($temporaryPath)) {
            [System.IO.File]::Delete($temporaryPath)
        }
    }
}

function Get-ReviewCauseCategories {
    return @(
        "identity_binding",
        "contract_mismatch",
        "state_consistency",
        "representation_parsing",
        "resource_bound",
        "cancellation",
        "error_propagation",
        "concurrency",
        "security_boundary",
        "data_leakage",
        "compatibility",
        "observability",
        "test_gap",
        "other"
    )
}

function Get-ReviewResultSchemaObject {
    $componentSchema = @{
        type = "object"
        additionalProperties = $false
        properties = @{
            kind = @{ type = "string"; enum = @("file", "type", "function", "module", "workflow") }
            id = @{ type = "string"; minLength = 1; maxLength = 300 }
        }
        required = @("kind", "id")
    }

    $findingSchema = @{
        type = "object"
        additionalProperties = $false
        properties = @{
            finding_id = @{ type = "string"; pattern = "^F[0-9]{2}$" }
            title = @{ type = "string"; minLength = 1; maxLength = 200 }
            priority = @{ type = "string"; enum = @("P0", "P1", "P2", "P3") }
            cause_category = @{ type = "string"; enum = @(Get-ReviewCauseCategories) }
            component = $componentSchema
            git_path = @{ type = "string"; minLength = 1; maxLength = 1024 }
            line_start = @{ type = "integer"; minimum = 1 }
            line_end = @{ type = "integer"; minimum = 1 }
            invariant = @{ type = "string"; minLength = 1; maxLength = 1000 }
            explanation = @{ type = "string"; minLength = 1; maxLength = 4000 }
            remediation = @{ type = "string"; minLength = 1; maxLength = 2000 }
        }
        required = @(
            "finding_id", "title", "priority", "cause_category", "component",
            "git_path", "line_start", "line_end", "invariant", "explanation", "remediation"
        )
    }

    return @{
        type = "object"
        additionalProperties = $false
        properties = @{
            schema_version = @{ type = "string"; enum = @("codex_review_result_v1") }
            classification = @{ type = "string"; enum = @("clean", "finding") }
            summary = @{ type = "string"; minLength = 1; maxLength = 2000 }
            findings = @{ type = "array"; maxItems = 50; items = $findingSchema }
        }
        required = @("schema_version", "classification", "summary", "findings")
    }
}

function Get-ArchitectureResultSchemaObject {
    $stringArray = @{ type = "array"; items = @{ type = "string" } }
    $nonEmptyStringArray = @{ type = "array"; minItems = 1; items = @{ type = "string" } }

    $verificationSchema = @{
        type = "object"; additionalProperties = $false
        properties = @{
            level = @{ type = "string"; enum = @("unit", "integration", "contract", "system", "static") }
            target = @{ type = "string"; minLength = 1 }
            test = @{ type = "string"; minLength = 1 }
            expected_result = @{ type = "string"; minLength = 1 }
        }
        required = @("level", "target", "test", "expected_result")
    }

    return @{
        type = "object"
        additionalProperties = $false
        properties = @{
            schema_version = @{ type = "string"; enum = @("codex_review_architecture_v2") }
            root_cause = @{ type = "string"; minLength = 1 }
            evidence = $nonEmptyStringArray
            invariants = @{
                type = "array"; minItems = 1
                items = @{
                    type = "object"; additionalProperties = $false
                    properties = @{
                        statement = @{ type = "string"; minLength = 1 }
                        scenarios = @{
                            type = "array"; minItems = 1
                            items = @{
                                type = "object"; additionalProperties = $false
                                properties = @{
                                    dimension = @{ type = "string"; minLength = 1 }
                                    members = $nonEmptyStringArray
                                    required_behavior = @{ type = "string"; minLength = 1 }
                                }
                                required = @("dimension", "members", "required_behavior")
                            }
                        }
                        verification = @{ type = "array"; minItems = 1; items = $verificationSchema }
                    }
                    required = @("statement", "scenarios", "verification")
                }
            }
            strategy = @{
                type = "object"; additionalProperties = $false
                properties = @{
                    title = @{ type = "string"; minLength = 1 }
                    scope = @{ type = "string"; enum = @("local", "component", "cross_component", "contract_breaking") }
                    approach = @{ type = "string"; minLength = 1 }
                    steps = @{
                        type = "array"; minItems = 1
                        items = @{
                            type = "object"; additionalProperties = $false
                            properties = @{
                                git_paths = $nonEmptyStringArray
                                action = @{ type = "string"; minLength = 1 }
                            }
                            required = @("git_paths", "action")
                        }
                    }
                    risks = $stringArray
                    compatibility_plan = @{ type = "string"; minLength = 1 }
                    rollback_plan = @{ type = "string"; minLength = 1 }
                }
                required = @("title", "scope", "approach", "steps", "risks", "compatibility_plan", "rollback_plan")
            }
            recommendation = @{
                type = "object"; additionalProperties = $false
                properties = @{
                    action = @{ type = "string"; enum = @("approve_strategy", "revise_strategy", "continue_point_fixes", "abort") }
                    reason = @{ type = "string"; minLength = 1 }
                }
                required = @("action", "reason")
            }
        }
        required = @(
            "schema_version", "root_cause", "evidence", "invariants", "strategy", "recommendation"
        )
    }
}

function Get-ArchitectureDecisionSchemaObject {
    return @{
        type = "object"
        additionalProperties = $false
        properties = @{
            schema_version = @{ type = "string"; enum = @("codex_review_architecture_decision_v2") }
            report_sha256 = @{ type = "string"; pattern = "^[A-Fa-f0-9]{64}$" }
            expected_head = @{ type = "string"; minLength = 7; maxLength = 64 }
            decision = @{ type = "string"; enum = @("approve_strategy", "revise_strategy", "continue_point_fixes", "abort") }
            decided_by = @{ type = "string"; minLength = 1 }
            decided_at = @{ type = "string"; minLength = 1 }
            note = @{ type = "string" }
            max_additional_point_fixes = @{ type = "integer"; minimum = 0; maximum = 20 }
        }
        required = @(
            "schema_version", "report_sha256", "expected_head", "decision",
            "decided_by", "decided_at", "note", "max_additional_point_fixes"
        )
    }
}

function Assert-CodexStructuredOutputSchemaCompatibility {
    param(
        [object]$Schema,
        [string]$Context = "root"
    )

    $supportedKeywords = @(
        "type", "additionalProperties", "properties", "required", "items", "enum",
        "minLength", "maxLength", "minItems", "maxItems", "pattern", "minimum", "maximum"
    )
    if ($Schema -isnot [System.Collections.IDictionary]) {
        throw "JSON-Schema an '$Context' ist kein Objekt."
    }
    foreach ($keyword in @($Schema.Keys)) {
        if ([string]$keyword -notin $supportedKeywords) {
            throw "JSON-Schema verwendet an '$Context' die vom Structured-Output-Vertrag nicht freigegebene Eigenschaft '$keyword'."
        }
    }
    if ($Schema.Contains("properties")) {
        foreach ($propertyName in @($Schema.properties.Keys)) {
            Assert-CodexStructuredOutputSchemaCompatibility `
                -Schema $Schema.properties[$propertyName] `
                -Context "$Context.properties.$propertyName"
        }
    }
    if ($Schema.Contains("items")) {
        Assert-CodexStructuredOutputSchemaCompatibility -Schema $Schema.items -Context "$Context.items"
    }
}

function Write-ReviewLoopSchemaFiles {
    param([string]$LogRoot)

    $reviewSchemaPath = Join-Path $LogRoot "review-result-v1.schema.json"
    $architectureSchemaPath = Join-Path $LogRoot "architecture-result-v2.schema.json"
    $decisionSchemaPath = Join-Path $LogRoot "architecture-decision-v2.schema.json"

    $reviewSchema = Get-ReviewResultSchemaObject
    $architectureSchema = Get-ArchitectureResultSchemaObject
    $decisionSchema = Get-ArchitectureDecisionSchemaObject
    Assert-CodexStructuredOutputSchemaCompatibility -Schema $reviewSchema -Context "review"
    Assert-CodexStructuredOutputSchemaCompatibility -Schema $architectureSchema -Context "architecture"
    Assert-CodexStructuredOutputSchemaCompatibility -Schema $decisionSchema -Context "decision"
    Write-AtomicUtf8TextFile -Path $reviewSchemaPath -Text ($reviewSchema | ConvertTo-Json -Depth 30)
    Write-AtomicUtf8TextFile -Path $architectureSchemaPath -Text ($architectureSchema | ConvertTo-Json -Depth 30)
    Write-AtomicUtf8TextFile -Path $decisionSchemaPath -Text ($decisionSchema | ConvertTo-Json -Depth 20)

    return [PSCustomObject]@{
        Review = $reviewSchemaPath
        Architecture = $architectureSchemaPath
        Decision = $decisionSchemaPath
    }
}

function Get-FileSha256 {
    param([string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-ArchitectureContextDigest {
    param(
        [object[]]$ReviewLedger,
        [object[]]$FixCommitRecords,
        [string]$EpochId
    )

    $reviews = @($ReviewLedger | Where-Object { $_.epochId -eq $EpochId } | ForEach-Object {
        [ordered]@{
            reviewId = [string]$_.reviewId
            reviewHead = [string]$_.reviewHead
            classification = [string]$_.classification
            fixCommit = [string]$_.fixCommit
            fixMode = [string]$_.fixMode
            signatures = @($_.findings | ForEach-Object { [string]$_.signature } | Sort-Object -Unique)
        }
    } | Sort-Object { $_.reviewId })
    $fixes = @($FixCommitRecords | Where-Object { $_.epochId -eq $EpochId } | ForEach-Object {
        [ordered]@{
            commitSha = [string]$_.commitSha
            mode = [string]$_.mode
            reviewId = [string]$_.reviewId
            gitPaths = @($_.gitPaths | ForEach-Object { [string]$_ } | Sort-Object -Unique)
        }
    } | Sort-Object { $_.commitSha })
    $payload = [ordered]@{
        epochId = $EpochId
        reviews = $reviews
        fixes = $fixes
    } | ConvertTo-Json -Depth 15 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return (($sha256.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join "")
    } finally {
        $sha256.Dispose()
    }
}

function Save-ReviewLoopCheckpoint {
    param([object]$State = $script:RunState)

    if ($null -eq $State -or [string]::IsNullOrWhiteSpace([string]$State.logRoot)) {
        return
    }

    $State.updatedAt = (Get-Date).ToString("o")
    $json = $State | ConvertTo-Json -Depth 30
    Write-AtomicUtf8TextFile -Path (Join-Path $State.logRoot "state.json") -Text $json
    Write-AtomicUtf8TextFile -Path (Join-Path $State.logRoot "summary.json") -Text $json
}

function Assert-NativeCommandAvailable {
    param([string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "$Name wurde nicht im PATH gefunden."
    }
}

function Get-FirstOutputLine {
    param([object[]]$Lines)

    $firstLine = @($Lines | ForEach-Object { "$_" } | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    } | Select-Object -First 1)

    if ($firstLine.Count -eq 0) {
        return ""
    }

    return ([string]$firstLine[0]).Trim()
}

function Test-RunningAsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Add-PowerManagementType {
    if (([System.Management.Automation.PSTypeName]"CodexReviewLoopPower").Type) {
        return
    }

    Add-Type -TypeDefinition @"
using System.Runtime.InteropServices;

public static class CodexReviewLoopPower {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern uint SetThreadExecutionState(uint esFlags);
}
"@
}

function Start-RestartGuard {
    param([int]$AbortIntervalSeconds = 10)

    $messages = New-Object System.Collections.Generic.List[string]
    $policyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
    $policyName = "NoAutoRebootWithLoggedOnUsers"

    $guard = [PSCustomObject]@{
        SleepGuardActive = $false
        AbortJob = $null
        WindowsUpdatePolicyApplied = $false
        PolicyPath = $policyPath
        PolicyName = $policyName
        PolicyValueExisted = $false
        PolicyPreviousValue = $null
        Messages = $messages
    }

    try {
        Add-PowerManagementType
        $executionState = ([uint32]2147483648) -bor ([uint32]1)
        $previousState = [CodexReviewLoopPower]::SetThreadExecutionState($executionState)
        if ($previousState -eq 0) {
            $messages.Add("System-Wachhaltesignal konnte nicht gesetzt werden.") | Out-Null
        } else {
            $guard.SleepGuardActive = $true
            $messages.Add("System-Wachhaltesignal ist aktiv.") | Out-Null
        }
    } catch {
        $messages.Add("System-Wachhaltesignal fehlgeschlagen: $($_.Exception.Message)") | Out-Null
    }

    try {
        $jobName = "CodexReviewLoop-RestartAbort-$PID-$([guid]::NewGuid().ToString('N'))"
        $guard.AbortJob = Start-Job -Name $jobName -ScriptBlock {
            param([int]$IntervalSeconds)

            $shutdownExe = Join-Path $env:SystemRoot "System32\shutdown.exe"
            while ($true) {
                try {
                    & $shutdownExe /a *> $null
                } catch {
                }
                Start-Sleep -Seconds $IntervalSeconds
            }
        } -ArgumentList $AbortIntervalSeconds
        $messages.Add("Shutdown-Abbruchwächter läuft alle $AbortIntervalSeconds Sekunden.") | Out-Null
    } catch {
        $messages.Add("Shutdown-Abbruchwächter konnte nicht gestartet werden: $($_.Exception.Message)") | Out-Null
    }

    if (Test-RunningAsAdministrator) {
        try {
            $existing = Get-ItemProperty -LiteralPath $policyPath -Name $policyName -ErrorAction SilentlyContinue
            if ($existing -and ($existing.PSObject.Properties.Name -contains $policyName)) {
                $guard.PolicyValueExisted = $true
                $guard.PolicyPreviousValue = $existing.$policyName
            }

            New-Item -Path $policyPath -Force | Out-Null
            New-ItemProperty -LiteralPath $policyPath -Name $policyName -Value 1 -PropertyType DWord -Force | Out-Null
            $guard.WindowsUpdatePolicyApplied = $true
            $messages.Add("Windows-Update Auto-Neustart ist temporaer fuer angemeldete Benutzer blockiert.") | Out-Null
        } catch {
            $messages.Add("Windows-Update Neustart-Richtlinie konnte nicht gesetzt werden: $($_.Exception.Message)") | Out-Null
        }
    } else {
        $messages.Add("Windows-Update Neustart-Richtlinie nicht gesetzt, weil das Script nicht als Administrator laeuft.") | Out-Null
    }

    return $guard
}

function Stop-RestartGuard {
    param([object]$Guard = $script:RestartGuard)

    if ($null -eq $Guard) {
        return
    }

    if ($Guard.AbortJob) {
        Stop-Job -Job $Guard.AbortJob -ErrorAction SilentlyContinue | Out-Null
        Remove-Job -Job $Guard.AbortJob -Force -ErrorAction SilentlyContinue | Out-Null
    }

    if ($Guard.SleepGuardActive) {
        try {
            [CodexReviewLoopPower]::SetThreadExecutionState([uint32]2147483648) | Out-Null
        } catch {
        }
    }

    if ($Guard.WindowsUpdatePolicyApplied) {
        try {
            if ($Guard.PolicyValueExisted) {
                New-Item -Path $Guard.PolicyPath -Force | Out-Null
                New-ItemProperty `
                    -LiteralPath $Guard.PolicyPath `
                    -Name $Guard.PolicyName `
                    -Value ([int]$Guard.PolicyPreviousValue) `
                    -PropertyType DWord `
                    -Force | Out-Null
            } else {
                Remove-ItemProperty `
                    -LiteralPath $Guard.PolicyPath `
                    -Name $Guard.PolicyName `
                    -ErrorAction SilentlyContinue
            }
        } catch {
        }
    }

    if ($Guard -eq $script:RestartGuard) {
        $script:RestartGuard = $null
    }
}

function Show-Help {
    Write-Rule "Codex Review-Loop Hilfe"
    Write-Paragraph "Startet einen automatisierten Codex-Review/Fix-Loop für ein Git-Repository. Der Reviewer nutzt den nativen Codex-Review-Modus gegen eine Base-Branch. Der Fixer behebt Funde, danach committed das Skript automatisch. Der Loop endet nach der gewünschten Zahl sauberer Reviews oder nach mehreren Läufen ohne Commit."

    Write-Rule "Syntax"
    Write-Paragraph "C:\Dev\Invoke-CodexReviewLoop.ps1 <RepositoryOrdner> [Optionen]"

    Write-Rule "Beispiele"
    Write-Paragraph "C:\Dev\Invoke-CodexReviewLoop.ps1 C:\Dev\FlowKonto"
    Write-Paragraph "C:\Dev\Invoke-CodexReviewLoop.ps1 C:\Dev\FlowKonto -BaseBranch origin/master -FixerThreadId `"019ddff7-212c-7b30-af58-61725bde8995`""
    Write-Paragraph "C:\Dev\Invoke-CodexReviewLoop.ps1 C:\Dev\FlowKonto -ReviewPrompt `"Fokussiere besonders auf Race Conditions und Persistenzfehler.`""
    Write-Paragraph "C:\Dev\Invoke-CodexReviewLoop.ps1 C:\Dev\FlowKonto -Model gpt-5.6-sol -ReviewThinking high -FixerThinking high -Speed standard"
    Write-Paragraph "C:\Dev\Invoke-CodexReviewLoop.ps1 C:\Dev\FlowKonto -MaxIterations 16 -PassesRequired 2"

    Write-Rule "Wichtige Optionen"
    Write-KeyValue "<RepositoryOrdner>" "Pflichtangabe positional. Ohne Angabe wird diese Hilfe angezeigt."
    Write-KeyValue "-Model" "Optional. Modell für Reviewer und Fixer. Default: gpt-5.6-sol."
    Write-KeyValue "-ReviewThinking" "Optional. Reasoning/Thinking-Level des Reviewers. Für gpt-5.6-sol: low, medium, high, xhigh, max oder ultra. Default: high. -Thinking und -ReasoningEffort sind Aliase."
    Write-KeyValue "-FixerThinking" "Optional. Reasoning/Thinking-Level des Fixers. Für gpt-5.6-sol: low, medium, high, xhigh, max oder ultra. Default: high."
    Write-KeyValue "-Speed" "Optional. Geschwindigkeit: standard, fast oder priority. Default: standard."
    Write-KeyValue "-FixerThreadId" "Optional. Bestehende Codex-Session für den Fixer. Ohne Angabe übernimmt Auto-Recovery eine bekannte Fixer-Session oder startet neu."
    Write-KeyValue "-BaseBranch" "Optional. Default wird automatisch aus origin/main, origin/master, main oder master gewählt."
    Write-KeyValue "-ReviewPrompt" "Optional. Einzeilige Custom Instructions für den nativen Codex-Review."
    Write-KeyValue "-MaxIterations" "Default: 16."
    Write-KeyValue "-PassesRequired" "Default: 2. Gemeinsamer Schwellenwert für saubere Reviews und Läufe hintereinander ohne Commit."
    Write-KeyValue "-LogRoot" "Optional. Default: C:\Dev\codex-review-loop\<RepoName>\<Timestamp>."
    Write-KeyValue "-UseCodexSandbox" "Optional. Aktiviert wieder die Codex-Sandbox. Default ist ohne Sandbox/Approvals."
    Write-KeyValue "-AllowDirtyWorktree" "Optional. Erlaubt Start trotz vorhandener Änderungen."
    Write-KeyValue "-ReviewClassifierModel" "Optional. Modell für unklare Review-Antworten. Default: gpt-5.4-nano."
    Write-KeyValue "-ReviewClassifierMaxRateLimitWaitSeconds" "Optional. Wartebudget für echte Rate-Limits des Modell-Fallbacks. Default: 900."
    Write-KeyValue "-DisableModelReviewClassifier" "Optional. Deaktiviert den Modell-Fallback; unklare Reviews brechen ab."
    Write-Paragraph "Diese drei Klassifiziereroptionen sind deprecated und wirken nur in ReviewResultMode=Legacy. In Dual läuft ausschließlich die lokale Regex-Klassifizierung als Shadow."
    Write-KeyValue "-DisableRestartGuard" "Optional. Deaktiviert den Laufzeit-Schutz gegen Schlafmodus und automatische Neustarts."
    Write-KeyValue "-DisableLastUnfixedReviewRecovery" "Optional. Deaktiviert die automatische Rettung des letzten ungefixten Reviews aus einer vorherigen Log-Session. Die Rettung erfolgt nur bei exakt passendem Repository, Branch, Review-Base und HEAD-Commit."
    Write-KeyValue "-ReviewResultMode" "Legacy, Dual oder Structured. Default dieser Rollout-Version: Dual; strukturierte Ausgabe ist autoritativ, Legacy läuft nur als Shadow."
    Write-KeyValue "-ArchitectureMode" "Off, Observe oder Enforce. Default: Enforce. Observe ist ein ausdrücklich gewählter Diagnosemodus und übergibt Berichte nicht an den Fixer."
    Write-KeyValue "-ArchitectureRepeatThreshold" "Gleicher kanonischer Git-Pfad ab diesem Finding-Zähler. Default: 2."
    Write-KeyValue "-ArchitectureHotspotFixThreshold" "Vorherige Fix-Commits am selben Git-Pfad vor dem Hotspot-Fallback. Default: 2."
    Write-KeyValue "-ArchitectureModel" "Optional. Default: Wert von -Model."
    Write-KeyValue "-ArchitectureThinking" "Reasoning für den read-only Architekturlauf. Default: max."
    Write-KeyValue "-ArchitectureFixerThinking" "Reasoning für einen freigegebenen frischen Architektur-Fixer. Default: max."
    Write-KeyValue "-ArchitectureDecisionPath" "Optional für automatisierte Läufe: v2-JSON-Entscheidungsdatei, gebunden an Architekturbericht-Hash und exakten Git-HEAD. Interaktive Konsolenläufe fragen die Entscheidung direkt ab."
    Write-KeyValue "-ArchitectureAutoApplyLocal" "Aktiviert Auto-Apply für kleine lokale Architekturstrategien. Bereits standardmäßig aktiv: scope=local, maximal drei Pfade im selben bereits Git-verfolgten Unterordner."
    Write-KeyValue "-ArchitectureAutoApplyAll" "Gibt im Enforce-Modus jede validierte Architekturstrategie automatisch frei. Deaktiviert das menschliche Gate auch für große oder nicht lokale Strategien und ist daher nur für bewusst unbeaufsichtigte Läufe gedacht."
    Write-KeyValue "-DisableArchitectureAutoApplyLocal" "Deaktiviert das standardmäßige Auto-Apply kleiner lokaler Architekturstrategien und leitet auch diese in das menschliche Gate."
    Write-KeyValue "-DisableInteractiveArchitectureGate" "Deaktiviert die direkte Konsolenabfrage. Ohne Entscheidungsdatei wird das Gate dann gespeichert und der Lauf endet wie bisher mit Exitcode 7."
    Write-KeyValue "-ColorMode" "Optional. Host, Ansi, Always, Auto oder Never. Default: Host nutzt PowerShell-native Write-Host-Farben; Ansi/Always erzwingen Escape-Sequenzen."
    Write-KeyValue "-Help" "Zeigt diese Hilfe."

    Write-Rule "Hinweis"
    Write-Paragraph "Die verfügbaren Thinking-Stufen sind modellabhängig. gpt-5.6-sol unterstützt low, medium, high, xhigh, max und ultra. Andere Modelle können max oder ultra ablehnen."
    Write-Paragraph "Wenn du -FixerThreadId vergisst, ist das kein Fehler. Der Loop übernimmt bei Auto-Recovery eine bekannte Fixer-Session oder erzeugt beim ersten Fix automatisch eine neue und zeigt deren Thread-ID in der Ausgabe."
    Write-Paragraph "Fixer-Recovery ist aktiv: Bei rettbaren Fixer-Fehlern startet der Loop einmal eine frische Fixer-Session, statt sofort abzubrechen."
    Write-Paragraph "Architektur-Gate Exitcodes: 7 Entscheidung erforderlich, 8 stale/ungültige Entscheidung oder Scope-Verletzung, 9 ungültige strukturierte Ausgabe, 10 menschlicher Abbruch."
}

function Invoke-CodexJson {
    param(
        [string[]]$Arguments,
        [string]$JsonlPath,
        [string]$TextPath,
        [string]$OutputLastMessagePath = "",
        [string]$StdinText = $null
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        if ($null -ne $StdinText) {
            $rawOutput = $StdinText | & codex @Arguments 2>&1
        } else {
            $rawOutput = & codex @Arguments 2>&1
        }
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    $lines = @($rawOutput | ForEach-Object { "$_" })

    Write-Utf8File -Path $JsonlPath -Lines $lines

    $threadId = $null
    $messages = New-Object System.Collections.Generic.List[string]

    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        try {
            $codexEvent = $line | ConvertFrom-Json
        } catch {
            continue
        }

        if ($codexEvent.type -eq "thread.started" -and $codexEvent.thread_id) {
            $threadId = [string]$codexEvent.thread_id
        }

        if ($codexEvent.type -eq "item.completed" -and $codexEvent.item.type -eq "agent_message" -and $codexEvent.item.text) {
            $messages.Add([string]$codexEvent.item.text) | Out-Null
        }
    }

    $finalMessage = ""
    if (-not [string]::IsNullOrWhiteSpace($OutputLastMessagePath) -and (Test-Path -LiteralPath $OutputLastMessagePath)) {
        $finalMessage = Get-Content -LiteralPath $OutputLastMessagePath -Raw
    } elseif ($messages.Count -gt 0) {
        $finalMessage = $messages[$messages.Count - 1]
    }

    Write-Utf8TextFile -Path $TextPath -Text $finalMessage

    return [PSCustomObject]@{
        ExitCode = $exitCode
        ThreadId = $threadId
        Text = $finalMessage
        Output = @($lines)
        JsonlPath = $JsonlPath
        TextPath = $TextPath
        OutputLastMessagePath = $OutputLastMessagePath
        Diagnostics = Get-CodexRunDiagnostics -Lines $lines -ExitCode $exitCode
    }
}

function ConvertTo-DiagnosticLine {
    param([AllowNull()][string]$Text)

    if ($null -eq $Text) {
        return ""
    }

    $clean = $Text -replace "\x1B\[[0-?]*[ -/]*[@-~]", ""
    $clean = ConvertTo-RedactedOpenAIText $clean
    $clean = ($clean -replace "\s+", " ").Trim()
    if ($clean.Length -gt 1000) {
        return $clean.Substring(0, 1000).TrimEnd() + " ... (gekürzt)"
    }

    return $clean
}

function Add-DiagnosticLine {
    param(
        [object]$List,
        [AllowNull()][string]$Line
    )

    $clean = ConvertTo-DiagnosticLine $Line
    if ([string]::IsNullOrWhiteSpace($clean)) {
        return
    }

    if (-not @($List).Contains($clean)) {
        $List.Add($clean) | Out-Null
    }
}

function Get-DiagnosticExcerpt {
    param(
        [AllowNull()][string]$Text,
        [int]$MaxLines = 6,
        [int]$MaxChars = 900
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ""
    }

    $lines = @($Text -split "`r?`n" | ForEach-Object {
        ConvertTo-DiagnosticLine $_
    } | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    })

    if ($lines.Count -eq 0) {
        return ""
    }

    if ($lines.Count -gt $MaxLines) {
        $lines = @($lines | Select-Object -Last $MaxLines)
    }

    $joined = $lines -join " | "
    if ($joined.Length -gt $MaxChars) {
        return $joined.Substring(0, $MaxChars).TrimEnd() + " ... (gekürzt)"
    }

    return $joined
}

function Get-CodexFailureCategory {
    param(
        [string]$Text,
        [bool]$HasFailedCommand
    )

    if ($Text -match "(?im)(spend cap|insufficient_quota|current quota|billing quota|run out of credits|no balance|credits? (are|is) exhausted)") {
        return "API-Budget/Spend-Cap erschöpft"
    }
    if ($Text -match "(?im)(the argument '.+' cannot be used with|unexpected argument|usage:\s*codex)") {
        return "Codex-CLI-Argumentkonflikt"
    }
    if ($Text -match "(?im)(invalid_json_schema|invalid schema for response_format|schema.*is not permitted)") {
        return "Codex-Structured-Output-Schema ungültig"
    }
    if ($Text -match "(?im)(rate_limit_exceeded|rate limit|requests per minute|tokens per minute|too many requests|\b429\b)") {
        return "API-Rate-Limit"
    }
    if ($Text -match "(?im)(invalid_api_key|\b401\b|unauthorized|authentication|api key|OPENAI_API_KEY)") {
        return "API-Authentifizierung"
    }
    if ($Text -match "(?im)(model_not_found|\b403\b|does not have access|permission|project|organization|workspace)") {
        return "Modell-/Projekt-/Workspace-Zugriff"
    }
    if ($Text -match "(?im)(dns|timed out|timeout|connection refused|connection reset|tls|certificate|proxy|network)") {
        return "Netzwerk/Verbindung"
    }
    if ($Text -match "(?im)(thread/resume|failed to read thread|thread-store|session metadata)") {
        return "Codex-Resume/Session defekt"
    }
    if ($Text -match "(?im)(context length|maximum context|token limit|too many tokens|context window)") {
        return "Kontext-/Tokenlimit"
    }
    if ($Text -match "(?im)(internal error|code -32603)") {
        return "Interner Codex-Fehler"
    }
    if ($HasFailedCommand) {
        return "Befehl im Codex-Lauf fehlgeschlagen"
    }

    return "Unbekannt"
}

function Get-CodexFailureAdvice {
    param([string]$Category)

    switch ($Category) {
        "Codex-CLI-Argumentkonflikt" {
            return "Die vom Skript erzeugten Codex-CLI-Argumente passen nicht zur installierten CLI-Version. Skript und Codex-CLI-Syntax abgleichen; ein unveränderter Retry hilft nicht."
        }
        "Codex-Structured-Output-Schema ungültig" {
            return "Das angegebene JSON-Schema verwendet eine vom Structured-Output-Endpunkt nicht unterstützte Eigenschaft. Schema korrigieren; ein unveränderter Retry hilft nicht."
        }
        "API-Budget/Spend-Cap erschöpft" {
            return "Platform-/Workspace-Owner muss Billing, Credits, Spend-Cap oder Usage-Limit erhöhen. Warten oder Retry hilft hier nicht; ChatGPT/Codex-Abo und API-Billing können getrennt sein."
        }
        "API-Rate-Limit" {
            return "Später erneut starten oder Last reduzieren. Wenn die API Retry-After/Reset-Header liefert, wartet der Modell-Klassifizierer darauf; der native Codex-Review muss nach einem CLI-Abbruch neu gestartet werden."
        }
        "API-Authentifizierung" {
            return "OPENAI_API_KEY, Codex-Login und Projektzuordnung prüfen."
        }
        "Modell-/Projekt-/Workspace-Zugriff" {
            return "Modellname, Workspace-/Projektzugriff, Organisation und API-Key-Scope prüfen."
        }
        "Netzwerk/Verbindung" {
            return "Netzwerk, Proxy, TLS/Zertifikate und Zugriff auf api.openai.com prüfen."
        }
        "Codex-Resume/Session defekt" {
            return "Ohne bestehende Fixer-Session neu starten oder -FixerThreadId weglassen; der Loop versucht bei Fixer-Resume bereits eine frische Session."
        }
        "Kontext-/Tokenlimit" {
            return "Diff, Prompt oder Zusatzkontext verkleinern oder den Review in kleinere Schritte teilen."
        }
        "Befehl im Codex-Lauf fehlgeschlagen" {
            return "Die fehlgeschlagene interne Befehlsausgabe prüfen; häufig ist das ein Test-, Build- oder Shell-Fehler innerhalb des Codex-Laufs."
        }
        default {
            return "Details im JSONL-Log prüfen; das Skript konnte keine bekannte Fehlerklasse sicher ableiten."
        }
    }
}

function Get-CodexRunDiagnostics {
    param(
        [string[]]$Lines,
        [int]$ExitCode
    )

    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    $failedCommands = New-Object System.Collections.Generic.List[string]
    $rawErrorLines = New-Object System.Collections.Generic.List[string]

    foreach ($line in @($Lines)) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $codexEvent = $null
        try {
            $codexEvent = $line | ConvertFrom-Json
        } catch {
            if ($line -match "(?im)^\s*(error|fatal|panic|exception)\b|failed|quota|spend cap|rate limit|unauthorized|forbidden|timeout|connection") {
                Add-DiagnosticLine -List $rawErrorLines -Line $line
            }
            continue
        }

        if ($codexEvent.type -eq "error" -and $codexEvent.message) {
            Add-DiagnosticLine -List $errors -Line ([string]$codexEvent.message)
        }

        if ($codexEvent.type -eq "turn.failed" -and $codexEvent.error -and $codexEvent.error.message) {
            Add-DiagnosticLine -List $errors -Line ([string]$codexEvent.error.message)
        }

        if ($codexEvent.error -and $codexEvent.error.message) {
            Add-DiagnosticLine -List $errors -Line ([string]$codexEvent.error.message)
        }

        if ($codexEvent.type -eq "item.completed" -and $codexEvent.item) {
            $item = $codexEvent.item
            if ($item.type -eq "error" -and $item.message) {
                if ($item.message -match "(?i)skill descriptions were shortened") {
                    Add-DiagnosticLine -List $warnings -Line ([string]$item.message)
                } else {
                    Add-DiagnosticLine -List $errors -Line ([string]$item.message)
                }
            }

            $exitCodeValue = $null
            if ($null -ne $item.exit_code) {
                $exitCodeValue = [int]$item.exit_code
            }
            $commandFailed = (($null -ne $exitCodeValue -and $exitCodeValue -ne 0) -or ([string]$item.status -eq "failed"))
            if ($item.type -eq "command_execution" -and $commandFailed) {
                $command = ConvertTo-DiagnosticLine ([string]$item.command)
                if ($command.Length -gt 350) {
                    $command = $command.Substring(0, 350).TrimEnd() + " ... (gekürzt)"
                }

                $outputExcerpt = Get-DiagnosticExcerpt -Text ([string]$item.aggregated_output)
                $commandLine = "Befehl fehlgeschlagen"
                if ($null -ne $exitCodeValue) {
                    $commandLine += " (Exitcode $exitCodeValue)"
                }
                if (-not [string]::IsNullOrWhiteSpace($command)) {
                    $commandLine += ": $command"
                }
                if (-not [string]::IsNullOrWhiteSpace($outputExcerpt)) {
                    $commandLine += " | Letzte Ausgabe: $outputExcerpt"
                }
                Add-DiagnosticLine -List $failedCommands -Line $commandLine
            }
        }
    }

    if ($errors.Count -eq 0) {
        foreach ($rawLine in @($rawErrorLines)) {
            Add-DiagnosticLine -List $errors -Line $rawLine
        }
    }

    if ($errors.Count -eq 0 -and $failedCommands.Count -eq 0 -and $ExitCode -ne 0) {
        Add-DiagnosticLine -List $errors -Line "Codex hat den Prozess ohne strukturierte Fehlermeldung mit Exitcode $ExitCode beendet."
    }

    $combined = (@($errors) + @($warnings) + @($failedCommands)) -join "`n"
    $category = Get-CodexFailureCategory -Text $combined -HasFailedCommand ($failedCommands.Count -gt 0)

    return [PSCustomObject]@{
        Category = $category
        Advice = Get-CodexFailureAdvice -Category $category
        Errors = @($errors)
        Warnings = @($warnings)
        FailedCommands = @($failedCommands)
    }
}

function Get-CodexFailureHeadline {
    param([object]$Result)

    if ($null -eq $Result -or $null -eq $Result.Diagnostics) {
        return "keine Diagnose verfügbar"
    }

    $diagnostics = $Result.Diagnostics
    $firstDetail = @($diagnostics.Errors + $diagnostics.FailedCommands | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    } | Select-Object -First 1)

    $headline = [string]$diagnostics.Category
    if ($firstDetail.Count -gt 0) {
        $detail = [string]$firstDetail[0]
        if ($detail.Length -gt 240) {
            $detail = $detail.Substring(0, 240).TrimEnd() + " ..."
        }
        $headline += ": $detail"
    }

    return $headline
}

function New-CodexFailureMessage {
    param(
        [string]$Actor,
        [object]$Result,
        [string]$Context = ""
    )

    $exitCode = if ($null -ne $Result) { $Result.ExitCode } else { 1 }
    $details = if ($null -ne $Result) { $Result.JsonlPath } else { "" }
    $diagnostics = if ($null -ne $Result) { $Result.Diagnostics } else { $null }

    $lines = New-Object System.Collections.Generic.List[string]
    $header = "$Actor ist mit Exitcode $exitCode fehlgeschlagen"
    if (-not [string]::IsNullOrWhiteSpace($Context)) {
        $header += " ($Context)"
    }
    $lines.Add($header + ".") | Out-Null

    if ($null -ne $Result -and -not [string]::IsNullOrWhiteSpace($Result.ThreadId)) {
        $lines.Add("Codex-Thread: $($Result.ThreadId)") | Out-Null
    }

    if ($null -ne $diagnostics) {
        if (-not [string]::IsNullOrWhiteSpace($diagnostics.Category)) {
            $lines.Add("Wahrscheinliche Ursache: $($diagnostics.Category)") | Out-Null
        }

        if ($diagnostics.Errors.Count -gt 0) {
            $lines.Add("Fehlerdetails:") | Out-Null
            foreach ($errorLine in @($diagnostics.Errors | Select-Object -First 6)) {
                $lines.Add("- $errorLine") | Out-Null
            }
        }

        if ($diagnostics.FailedCommands.Count -gt 0) {
            $lines.Add("Fehlgeschlagene interne Befehle:") | Out-Null
            foreach ($commandLine in @($diagnostics.FailedCommands | Select-Object -First 3)) {
                $lines.Add("- $commandLine") | Out-Null
            }
        }

        if ($diagnostics.Warnings.Count -gt 0) {
            $lines.Add("Hinweise:") | Out-Null
            foreach ($warningLine in @($diagnostics.Warnings | Select-Object -First 3)) {
                $lines.Add("- $warningLine") | Out-Null
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($diagnostics.Advice)) {
            $lines.Add("Nächster Schritt: $($diagnostics.Advice)") | Out-Null
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($details)) {
        $lines.Add("Details: $details") | Out-Null
    }

    return ($lines -join "`n")
}

function Add-CodexRuleArgument {
    param([string[]]$Arguments)

    if ($script:RespectCodexRulesSetting) {
        return $Arguments
    }

    return @($Arguments + @("--ignore-rules"))
}

function Resolve-CodexServiceTier {
    param([string]$RequestedSpeed)

    switch ($RequestedSpeed.ToLowerInvariant()) {
        "fast" { return "priority" }
        "priority" { return "priority" }
        default { return "standard" }
    }
}

function Add-CodexRunOptionArguments {
    param(
        [string[]]$Arguments,
        [string]$Model,
        [string]$Thinking,
        [string]$Speed
    )

    $result = @($Arguments)

    if (-not [string]::IsNullOrWhiteSpace($Model)) {
        $result += @("-m", $Model)
    }

    if (-not [string]::IsNullOrWhiteSpace($Thinking)) {
        $result += @("-c", "model_reasoning_effort=`"$($Thinking.ToLowerInvariant())`"")
    }

    if (-not [string]::IsNullOrWhiteSpace($Speed)) {
        $serviceTier = Resolve-CodexServiceTier -RequestedSpeed $Speed
        if ($serviceTier -ne "standard") {
            $result += @("-c", "service_tier=`"$serviceTier`"")
        }
    }

    return $result
}

function Add-CodexDeveloperInstructionsArgument {
    param(
        [string[]]$Arguments,
        [string]$Instructions
    )

    if ([string]::IsNullOrWhiteSpace($Instructions)) {
        return @($Arguments)
    }

    # JSON string literals are also valid TOML basic strings. This preserves
    # newlines and quotes without turning the instructions into a positional
    # review prompt, which would conflict with `review --base`.
    $tomlString = ConvertTo-Json -InputObject $Instructions -Compress
    return @($Arguments + @("-c", "developer_instructions=$tomlString"))
}

function Get-CodexExecArgumentList {
    param(
        [string]$RepoPath,
        [string]$Sandbox
    )

    if ($UseCodexSandbox) {
        return Add-CodexRuleArgument @("exec", "--json", "--sandbox", $Sandbox, "-C", $RepoPath)
    }

    return @("exec", "--json", "--dangerously-bypass-approvals-and-sandbox", "-C", $RepoPath)
}

function Get-CodexReadOnlyArchitectureArgumentList {
    param([string]$RepoPath)

    $arguments = @("exec", "--json", "--sandbox", "read-only", "-C", $RepoPath)
    return Add-CodexRuleArgument $arguments
}

function Get-CodexResumeArgumentList {
    param(
        [string]$RepoPath,
        [string]$Sandbox
    )

    if ($UseCodexSandbox) {
        $codexArguments = @("exec", "--json", "--sandbox", $Sandbox, "-C", $RepoPath)
        $codexArguments = Add-CodexRuleArgument $codexArguments
        return @($codexArguments + @("resume"))
    }

    return @("exec", "--json", "--dangerously-bypass-approvals-and-sandbox", "-C", $RepoPath, "resume")
}

function Get-CodexFixerArgumentList {
    param(
        [string]$RepoPath,
        [string]$Sandbox,
        [string]$Model,
        [string]$Thinking,
        [string]$Speed,
        [string]$FixerThreadId = ""
    )

    if ([string]::IsNullOrWhiteSpace($FixerThreadId)) {
        $arguments = Get-CodexExecArgumentList -RepoPath $RepoPath -Sandbox $Sandbox
        $arguments = Add-CodexRunOptionArguments -Arguments $arguments -Model $Model -Thinking $Thinking -Speed $Speed
    } else {
        $arguments = Get-CodexResumeArgumentList -RepoPath $RepoPath -Sandbox $Sandbox
        $arguments = Add-CodexRunOptionArguments -Arguments $arguments -Model $Model -Thinking $Thinking -Speed $Speed
        $arguments += $FixerThreadId
    }

    return @($arguments + "-")
}

function Test-CodexResumeFailure {
    param([object]$Result)

    $outputText = (@($Result.Output) + @($Result.Text)) -join "`n"
    return ($outputText -match "(?im)(thread/resume failed|failed to read thread|thread-store internal error|does not start with session metadata)")
}

function Get-FixAttemptLogStem {
    param(
        [string]$LogRoot,
        [string]$IterationLabel,
        [int]$RetryIndex
    )

    if ($RetryIndex -le 0) {
        return Join-Path $LogRoot "fix-$IterationLabel"
    }

    return Join-Path $LogRoot ("fix-$IterationLabel-retry{0:D2}" -f $RetryIndex)
}

function New-FixerRecoveryPrompt {
    param(
        [string]$FixPrompt,
        [int]$ExitCode,
        [string]$Reason
    )

    return @(
        "Ein vorheriger Fixer-Lauf ist mit Exitcode $ExitCode fehlgeschlagen.",
        $Reason,
        "Pruefe vorhandene Arbeitsbaum-Aenderungen und den aktuellen Diff, rette nur sinnvolle Teilarbeit und behebe den Review-Fund vollstaendig.",
        "Committe nicht selbst; der Orchestrator committet erst nach deinem erfolgreichen Lauf.",
        "",
        $FixPrompt
    ) -join "`n"
}

function New-ReviewFixPrompt {
    param(
        [string]$FixPromptPrefix,
        [string]$ReviewBase,
        [string]$ReviewText
    )

    return @(
        $FixPromptPrefix,
        "",
        "Behebe ausschließlich die folgenden Codex-/review-Funde aus dem PR-Review gegen $ReviewBase.",
        "Arbeite minimal, aber nachhaltig. Committe nicht selbst; der Orchestrator committet nach deinem Lauf.",
        "Beginne deine abschließende Antwort mit einer aussagekräftigen Commit-Zeile im Format: Commit: <imperativer Titel mit maximal 72 Zeichen>.",
        "",
        $ReviewText
    ) -join "`n"
}

function New-StructuredReviewPrompt {
    param([string]$CustomPrompt = "")

    $lines = @(
        "Return the final review result exclusively in the supplied JSON schema.",
        "Use classification=clean only when there is no actionable correctness finding.",
        "For every finding choose one cause_category from the schema as the root cause, not the symptom.",
        "Use a stable repository component identity, for example a type, function, module, or workflow name.",
        "git_path must be the exact slash-normalized Git-relative path reported by git ls-files; never return an absolute path.",
        "State the violated invariant independently of the proposed remediation.",
        "Do not duplicate the same invariant violation within one review."
    )
    if (-not [string]::IsNullOrWhiteSpace($CustomPrompt)) {
        $lines += @("", "Additional user review instructions:", $CustomPrompt)
    }
    return $lines -join "`n"
}

function New-StructuredReviewNormalizationPrompt {
    param(
        [string]$NativeReviewText,
        [string]$PreviousResult = "",
        [string]$ValidationError = ""
    )

    $lines = @(
        "Convert the completed native Codex review below into the supplied JSON schema.",
        "Treat the native review as the only source of findings. Do not perform a new review and do not add findings.",
        "Preserve each actionable finding's meaning, priority, Git path, and line range.",
        "Use classification=clean only when the native review contains no actionable finding.",
        "For every finding choose the best matching cause_category from the schema and identify the stable repository component.",
        "git_path must be slash-normalized and Git-relative. Remove any absolute repository prefix from a path.",
        "Return only the schema-conforming JSON result.",
        "",
        "BEGIN NATIVE REVIEW",
        $NativeReviewText,
        "END NATIVE REVIEW"
    )
    if (-not [string]::IsNullOrWhiteSpace($ValidationError)) {
        $lines += @(
            "",
            "The previous conversion was invalid only for this contract reason:",
            $ValidationError,
            "Repair only that contract error. Preserve the native review meaning and do not add or remove findings.",
            "",
            "BEGIN PREVIOUS INVALID RESULT",
            $PreviousResult,
            "END PREVIOUS INVALID RESULT"
        )
    }
    return $lines -join "`n"
}

function New-StructuredReviewFixPrompt {
    param(
        [string]$FixPromptPrefix,
        [string]$ReviewBase,
        [object]$StructuredReview
    )

    return @(
        $FixPromptPrefix,
        "",
        "Behebe ausschließlich die folgenden strukturierten Review-Funde gegen $ReviewBase.",
        "Wahre insbesondere jede angegebene Invariante. Committe nicht selbst; der Orchestrator committet nach deinem Lauf.",
        "Beginne deine abschließende Antwort mit: Commit: <imperativer Titel mit maximal 72 Zeichen>.",
        "",
        ($StructuredReview | ConvertTo-Json -Depth 15)
    ) -join "`n"
}

function New-ArchitectureAnalysisPrompt {
    param(
        [object]$Trigger,
        [object]$CurrentReviewRecord,
        [object[]]$ReviewLedger,
        [object[]]$FixCommitRecords,
        [string]$RevisionGuidance = "",
        [string]$PreviousResult = "",
        [string]$ValidationError = ""
    )

    $lines = @(
        "Arbeite ausschließlich read-only. Verändere keine Datei und führe keine schreibenden Git-Befehle aus.",
        "Analysiere ausschließlich die bereitgestellten, triggerrelevanten Findings und Fixes.",
        "Entwirf eine Architekturstrategie, die die Invarianten über direkt eingebettete Szenarien und Prüfungen absichert.",
        "Alle git_paths müssen exakt Git-relativ sein; neue Dateien dürfen nur unter einem bereits Git-verfolgten Verzeichnis deklariert werden.",
        "strategy.steps[].git_paths ist die einzige verbindliche Liste erlaubter Änderungspfade.",
        "Erfinde keine IDs und kopiere Trigger, Review-IDs oder Commit-SHAs nicht in den Bericht.",
        "Klassifiziere strategy.scope ehrlich nach der fachlichen Reichweite; local ist ausschließlich eine lokal begrenzte Strategie.",
        "recommendation ist nur eine Empfehlung. Behaupte niemals, eine menschliche Freigabe erhalten zu haben.",
        "Gib ausschließlich JSON gemäß dem bereitgestellten Architekturschema zurück.",
        "",
        "Trigger:",
        ($Trigger | ConvertTo-Json -Depth 12),
        "",
        "Aktuelles Review:",
        ($CurrentReviewRecord | ConvertTo-Json -Depth 15),
        "",
        "Triggerrelevante frühere Reviews:",
        (@($ReviewLedger) | ConvertTo-Json -Depth 15),
        "",
        "Triggerrelevante Fix-Commits:",
        (@($FixCommitRecords) | ConvertTo-Json -Depth 10)
    )
    if (-not [string]::IsNullOrWhiteSpace($RevisionGuidance)) {
        $lines += @(
            "",
            "Verbindlicher Hinweis aus der menschlichen Revisionsentscheidung:",
            $RevisionGuidance
        )
    }
    if (-not [string]::IsNullOrWhiteSpace($ValidationError)) {
        $lines += @(
            "",
            "Der vorherige Bericht war ausschließlich aus folgendem Vertragsgrund ungültig:",
            $ValidationError,
            "Repariere nur diesen Vertragsfehler. Behalte Diagnose, Strategie und Pfade inhaltlich bei und erfinde keine neue Analyse.",
            "",
            "Vorheriger ungültiger Bericht:",
            $PreviousResult
        )
    }
    return $lines -join "`n"
}

function New-ArchitectureFixPrompt {
    param(
        [string]$FixPromptPrefix,
        [object]$ArchitectureReport,
        [object]$CurrentReviewRecord
    )

    return @(
        $FixPromptPrefix,
        "",
        "Setze die freigegebene Architekturstrategie um. Halte dich an ihre Invarianten, Szenarien und eingebetteten Prüfungen.",
        "Ändere ausschließlich die im Bericht deklarierten Git-Pfade. Committe nicht selbst.",
        "Beginne die Abschlussantwort mit: Commit: <imperativer Titel mit maximal 72 Zeichen>.",
        "",
        "Architekturbericht:",
        ($ArchitectureReport | ConvertTo-Json -Depth 25),
        "",
        "Auslösendes Review:",
        ($CurrentReviewRecord | ConvertTo-Json -Depth 15)
    ) -join "`n"
}

function Resolve-RepositoryPath {
    param([string]$RequestedPath)

    if ([string]::IsNullOrWhiteSpace($RequestedPath)) {
        return ""
    }

    $candidate = $RequestedPath

    if (-not (Test-Path $candidate)) {
        throw "Der Repository-Ordner wurde nicht gefunden: $candidate"
    }

    $resolved = (Resolve-Path $candidate).Path
    $result = Invoke-GitCaptured -RepoPath $resolved -Arguments @("rev-parse", "--show-toplevel")
    if ($result.ExitCode -eq 0) {
        $topLevel = Get-FirstOutputLine $result.Output
        if (-not [string]::IsNullOrWhiteSpace($topLevel)) {
            return $topLevel
        }
    }

    throw "Kein Git-Repository gefunden. Übergib den Repository-Ordner als erstes Argument."
}

function Get-DefaultRepoLogRoot {
    param([string]$RepoPath)

    $repoName = Split-Path -Leaf $RepoPath.TrimEnd("\", "/")
    return Join-Path "C:\Dev\codex-review-loop" $repoName
}

function Get-DefaultLogRoot {
    param([string]$RepoPath)

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    return Join-Path (Get-DefaultRepoLogRoot -RepoPath $RepoPath) $timestamp
}

function Get-RepoLogRoot {
    param(
        [string]$RepoPath,
        [string]$LogRoot
    )

    if (-not [string]::IsNullOrWhiteSpace($LogRoot)) {
        $fullLogRoot = [System.IO.Path]::GetFullPath($LogRoot)
        $parent = Split-Path -Parent $fullLogRoot
        if (-not [string]::IsNullOrWhiteSpace($parent)) {
            return $parent
        }
    }

    return Get-DefaultRepoLogRoot -RepoPath $RepoPath
}

function ConvertTo-ComparablePath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }

    try {
        if (Test-Path -LiteralPath $Path) {
            return ((Resolve-Path -LiteralPath $Path).Path.TrimEnd("\", "/")).ToLowerInvariant()
        }
    } catch {
    }

    return ([System.IO.Path]::GetFullPath($Path).TrimEnd("\", "/")).ToLowerInvariant()
}

function Test-CodexJsonlHasRunFailure {
    param([string]$JsonlPath)

    if ([string]::IsNullOrWhiteSpace($JsonlPath) -or -not (Test-Path -LiteralPath $JsonlPath)) {
        return $false
    }

    $lastTurnState = ""
    $hasNonTerminalFailure = $false

    foreach ($line in Get-Content -LiteralPath $JsonlPath) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        try {
            $codexEvent = $line | ConvertFrom-Json
        } catch {
            continue
        }

        if ($codexEvent.type -eq "turn.completed") {
            $lastTurnState = "completed"
            continue
        }

        if ($codexEvent.type -eq "turn.failed") {
            $lastTurnState = "failed"
            continue
        }

        if ($codexEvent.type -eq "error") {
            $hasNonTerminalFailure = $true
            continue
        }

        if ($codexEvent.type -eq "item.completed" -and $codexEvent.item -and $codexEvent.item.type -eq "error") {
            $message = [string]$codexEvent.item.message
            if ($message -notmatch "(?i)skill descriptions were shortened") {
                $hasNonTerminalFailure = $true
            }
        }
    }

    # Codex kann nicht-fatale Diagnosemeldungen als Error-Items ausgeben und den
    # Turn danach trotzdem erfolgreich abschließen. Der terminale Turn-Status ist
    # deshalb maßgeblich; nur ohne terminalen Status greifen die Error-Events.
    if ($lastTurnState -eq "completed") {
        return $false
    }
    if ($lastTurnState -eq "failed") {
        return $true
    }

    return $hasNonTerminalFailure
}

function Get-CodexThreadIdFromJsonl {
    param([string]$JsonlPath)

    if ([string]::IsNullOrWhiteSpace($JsonlPath) -or -not (Test-Path -LiteralPath $JsonlPath)) {
        return ""
    }

    $threadId = ""
    foreach ($line in Get-Content -LiteralPath $JsonlPath) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        try {
            $codexEvent = $line | ConvertFrom-Json
        } catch {
            continue
        }

        if ($codexEvent.type -eq "thread.started" -and $codexEvent.thread_id) {
            $threadId = [string]$codexEvent.thread_id
        }
    }

    return $threadId
}

function Test-FixTextLogSucceeded {
    param([string]$FixTextPath)

    if ([string]::IsNullOrWhiteSpace($FixTextPath) -or -not (Test-Path -LiteralPath $FixTextPath)) {
        return $false
    }

    $fixText = Get-Content -LiteralPath $FixTextPath -Raw
    if ([string]::IsNullOrWhiteSpace($fixText)) {
        return $false
    }

    $fixJsonlPath = [System.IO.Path]::ChangeExtension($FixTextPath, ".jsonl")
    return (-not (Test-CodexJsonlHasRunFailure -JsonlPath $fixJsonlPath))
}

function Test-FixLogSucceeded {
    param(
        [string]$SessionPath,
        [string]$ReviewLabel
    )

    if ([string]::IsNullOrWhiteSpace($SessionPath) -or [string]::IsNullOrWhiteSpace($ReviewLabel)) {
        return $false
    }
    if (-not (Test-Path -LiteralPath $SessionPath)) {
        return $false
    }

    $escapedLabel = [regex]::Escape($ReviewLabel)
    $fixPattern = "^fix-$escapedLabel(?:-retry\d+)?$"
    $fixTextFiles = @(Get-ChildItem -LiteralPath $SessionPath -Filter "fix-$ReviewLabel*.txt" -File -ErrorAction SilentlyContinue | Where-Object {
        $_.BaseName -match $fixPattern
    } | Sort-Object Name)

    foreach ($fixTextFile in $fixTextFiles) {
        if (Test-FixTextLogSucceeded -FixTextPath $fixTextFile.FullName) {
            return $true
        }
    }

    return $false
}

function Get-SessionSummaryFixerThreadId {
    param([string]$SessionPath)

    if ([string]::IsNullOrWhiteSpace($SessionPath)) {
        return ""
    }

    $summaryPath = Join-Path $SessionPath "summary.json"
    if (-not (Test-Path -LiteralPath $summaryPath)) {
        return ""
    }

    try {
        $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
        if ($summary.fixerThreadId) {
            return [string]$summary.fixerThreadId
        }
    } catch {
    }

    return ""
}

function Get-RecoverableFixerThreadId {
    param([string]$SessionPath)

    $summaryThreadId = Get-SessionSummaryFixerThreadId -SessionPath $SessionPath
    if (-not [string]::IsNullOrWhiteSpace($summaryThreadId)) {
        return $summaryThreadId
    }

    if ([string]::IsNullOrWhiteSpace($SessionPath) -or -not (Test-Path -LiteralPath $SessionPath)) {
        return ""
    }

    $fixTextFiles = @(Get-ChildItem -LiteralPath $SessionPath -Filter "fix-*.txt" -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime, Name -Descending)
    foreach ($fixTextFile in $fixTextFiles) {
        if (-not (Test-FixTextLogSucceeded -FixTextPath $fixTextFile.FullName)) {
            continue
        }

        $threadId = Get-CodexThreadIdFromJsonl -JsonlPath ([System.IO.Path]::ChangeExtension($fixTextFile.FullName, ".jsonl"))
        if (-not [string]::IsNullOrWhiteSpace($threadId)) {
            return $threadId
        }
    }

    return ""
}

function Test-ReviewRecoveredInLaterSession {
    param(
        [string]$RepoLogRoot,
        [string]$CurrentLogRoot,
        [string]$SourceSessionName,
        [string]$ReviewLabel
    )

    if (
        [string]::IsNullOrWhiteSpace($RepoLogRoot) -or
        [string]::IsNullOrWhiteSpace($SourceSessionName) -or
        [string]::IsNullOrWhiteSpace($ReviewLabel) -or
        -not (Test-Path -LiteralPath $RepoLogRoot)
    ) {
        return $false
    }

    $currentComparablePath = ConvertTo-ComparablePath -Path $CurrentLogRoot
    $recoveryBaseName = "fix-recovered-$SourceSessionName-$ReviewLabel"
    $summaryReviewPathSuffix = Join-Path $SourceSessionName "review-$ReviewLabel.txt"

    $laterSessions = @(Get-ChildItem -LiteralPath $RepoLogRoot -Directory -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -gt $SourceSessionName -and
        (ConvertTo-ComparablePath -Path $_.FullName) -ne $currentComparablePath
    } | Sort-Object Name -Descending)

    foreach ($laterSession in $laterSessions) {
        $recoveryTextPath = Join-Path $laterSession.FullName "$recoveryBaseName.txt"
        if (Test-FixTextLogSucceeded -FixTextPath $recoveryTextPath) {
            return $true
        }

        $summaryPath = Join-Path $laterSession.FullName "summary.json"
        if (-not (Test-Path -LiteralPath $summaryPath)) {
            continue
        }

        try {
            $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
            foreach ($recoveredReview in @($summary.recoveredReviews)) {
                $reviewLogPath = [string]$recoveredReview.reviewLogPath
                $matchesReview = (
                    [string]::Equals([string]$recoveredReview.sourceSession, $SourceSessionName, [StringComparison]::OrdinalIgnoreCase) -and
                    [string]::Equals([string]$recoveredReview.reviewLabel, $ReviewLabel, [StringComparison]::OrdinalIgnoreCase)
                ) -or $reviewLogPath.EndsWith($summaryReviewPathSuffix, [StringComparison]::OrdinalIgnoreCase)

                if ($matchesReview -and -not [string]::IsNullOrWhiteSpace([string]$recoveredReview.commit)) {
                    return $true
                }
            }
        } catch {
        }
    }

    return $false
}

function Get-SessionRecoveryAttemptEntries {
    param([string]$SessionPath)

    if ([string]::IsNullOrWhiteSpace($SessionPath) -or -not (Test-Path -LiteralPath $SessionPath)) {
        return @()
    }

    return @(Get-ChildItem -LiteralPath $SessionPath -Filter "fix-recovered-*.txt" -File -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.BaseName -match "^fix-recovered-(\d{8}-\d{6})-(\d+)(?:-retry\d+)?$") {
            [PSCustomObject]@{
                SourceSessionName = $Matches[1]
                ReviewLabel = $Matches[2]
                TextPath = $_.FullName
                Succeeded = Test-FixTextLogSucceeded -FixTextPath $_.FullName
                LastWriteTime = $_.LastWriteTime
            }
        }
    } | Sort-Object LastWriteTime, TextPath -Descending)
}

function Get-ReviewLogEntries {
    param([string]$SessionPath)

    if ([string]::IsNullOrWhiteSpace($SessionPath) -or -not (Test-Path -LiteralPath $SessionPath)) {
        return @()
    }

    return @(Get-ChildItem -LiteralPath $SessionPath -Filter "review-*.txt" -File -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.BaseName -match "^review-(\d+)$") {
            [PSCustomObject]@{
                Label = $Matches[1]
                Number = [int]$Matches[1]
                TextPath = $_.FullName
                JsonlPath = [System.IO.Path]::ChangeExtension($_.FullName, ".jsonl")
                ResultPath = Join-Path $_.DirectoryName ("review-{0}.result.json" -f $Matches[1])
                RecordPath = Join-Path $_.DirectoryName ("review-{0}.record.json" -f $Matches[1])
            }
        }
    } | Sort-Object Number -Descending)
}

function Test-ReviewRecoveryContextMatches {
    param(
        [object]$Context,
        [string]$RepoPath,
        [string]$Branch,
        [string]$ReviewBase,
        [string]$CurrentHead,
        [string]$HeadProperty
    )

    if (
        $null -eq $Context -or
        [string]::IsNullOrWhiteSpace($RepoPath) -or
        [string]::IsNullOrWhiteSpace($Branch) -or
        [string]::IsNullOrWhiteSpace($ReviewBase) -or
        [string]::IsNullOrWhiteSpace($CurrentHead) -or
        [string]::IsNullOrWhiteSpace($HeadProperty)
    ) {
        return $false
    }

    $headPropertyValue = $Context.PSObject.Properties[$HeadProperty]
    $contextHead = if ($null -ne $headPropertyValue) { [string]$headPropertyValue.Value } else { "" }
    if (
        [string]::IsNullOrWhiteSpace([string]$Context.repoPath) -or
        [string]::IsNullOrWhiteSpace([string]$Context.branch) -or
        [string]::IsNullOrWhiteSpace([string]$Context.reviewBase) -or
        [string]::IsNullOrWhiteSpace($contextHead)
    ) {
        return $false
    }

    return (
        (ConvertTo-ComparablePath -Path ([string]$Context.repoPath)) -eq (ConvertTo-ComparablePath -Path $RepoPath) -and
        [string]::Equals([string]$Context.branch, $Branch, [StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals([string]$Context.reviewBase, $ReviewBase, [StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals($contextHead, $CurrentHead, [StringComparison]::OrdinalIgnoreCase)
    )
}

function Test-LegacyReviewRecoveryContextMatches {
    param(
        [string]$SessionPath,
        [string]$RepoPath,
        [string]$Branch,
        [string]$ReviewBase,
        [string]$CurrentHead
    )

    foreach ($contextFileName in @("state.json", "summary.json")) {
        $contextPath = Join-Path $SessionPath $contextFileName
        if (-not (Test-Path -LiteralPath $contextPath)) {
            continue
        }

        try {
            $context = Get-Content -LiteralPath $contextPath -Raw | ConvertFrom-Json -Depth 30
            return Test-ReviewRecoveryContextMatches `
                -Context $context `
                -RepoPath $RepoPath `
                -Branch $Branch `
                -ReviewBase $ReviewBase `
                -CurrentHead $CurrentHead `
                -HeadProperty "lastHead"
        } catch {
            return $false
        }
    }

    return $false
}

function Get-UnfixedReviewCandidateInSession {
    param(
        [string]$RepoLogRoot,
        [string]$CurrentLogRoot,
        [string]$SessionPath,
        [string]$SessionName,
        [string]$RepoPath = "",
        [string]$Branch = "",
        [string]$ReviewBase = "",
        [string]$CurrentHead = ""
    )

    foreach ($reviewLog in Get-ReviewLogEntries -SessionPath $SessionPath) {
        $reviewText = Get-Content -LiteralPath $reviewLog.TextPath -Raw
        $structuredRecord = $null
        if (Test-Path -LiteralPath $reviewLog.RecordPath) {
            try {
                $structuredRecord = Get-Content -LiteralPath $reviewLog.RecordPath -Raw | ConvertFrom-Json -Depth 30
            } catch {
                $structuredRecord = $null
            }
        }
        if ($null -ne $structuredRecord) {
            if (-not (Test-ReviewRecoveryContextMatches `
                -Context $structuredRecord `
                -RepoPath $RepoPath `
                -Branch $Branch `
                -ReviewBase $ReviewBase `
                -CurrentHead $CurrentHead `
                -HeadProperty "reviewHead")) {
                continue
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$structuredRecord.fixCommit)) {
                continue
            }
            $classification = New-ReviewClassification `
                -Classification ([string]$structuredRecord.classification) `
                -Source "output-schema" `
                -Reason "Host-validiertes strukturiertes Review-Record."
        } else {
            if (-not (Test-LegacyReviewRecoveryContextMatches `
                -SessionPath $SessionPath `
                -RepoPath $RepoPath `
                -Branch $Branch `
                -ReviewBase $ReviewBase `
                -CurrentHead $CurrentHead)) {
                continue
            }
            $classification = Get-LegacyLocalReviewClassification -ReviewText $reviewText
        }

        if ($classification.classification -eq "clean") {
            continue
        }
        if ($classification.classification -ne "finding") {
            continue
        }
        if (Test-FixLogSucceeded -SessionPath $SessionPath -ReviewLabel $reviewLog.Label) {
            continue
        }
        if (Test-ReviewRecoveredInLaterSession `
            -RepoLogRoot $RepoLogRoot `
            -CurrentLogRoot $CurrentLogRoot `
            -SourceSessionName $SessionName `
            -ReviewLabel $reviewLog.Label) {
            continue
        }

        return [PSCustomObject]@{
            SessionName = $SessionName
            SessionPath = $SessionPath
            ReviewLabel = $reviewLog.Label
            ReviewNumber = $reviewLog.Number
            ReviewTextPath = $reviewLog.TextPath
            ReviewJsonlPath = $reviewLog.JsonlPath
            ReviewText = $reviewText
            Classification = $classification
            StructuredRecord = $structuredRecord
            RecoveredFixerThreadId = Get-RecoverableFixerThreadId -SessionPath $SessionPath
        }
    }

    return $null
}

function Find-LastUnfixedReview {
    param(
        [string]$RepoLogRoot,
        [string]$CurrentLogRoot,
        [string]$RepoPath = "",
        [string]$Branch = "",
        [string]$ReviewBase = "",
        [string]$CurrentHead = ""
    )

    if ([string]::IsNullOrWhiteSpace($RepoLogRoot) -or -not (Test-Path -LiteralPath $RepoLogRoot)) {
        return $null
    }

    $currentComparablePath = ConvertTo-ComparablePath -Path $CurrentLogRoot
    $sessionDirectories = @(Get-ChildItem -LiteralPath $RepoLogRoot -Directory -ErrorAction SilentlyContinue | Where-Object {
        (ConvertTo-ComparablePath -Path $_.FullName) -ne $currentComparablePath
    } | Sort-Object Name -Descending)

    foreach ($sessionDirectory in $sessionDirectories) {
        $sessionStatePath = Join-Path $sessionDirectory.FullName "state.json"
        if (-not (Test-Path -LiteralPath $sessionStatePath)) {
            $sessionStatePath = Join-Path $sessionDirectory.FullName "summary.json"
        }
        if (Test-Path -LiteralPath $sessionStatePath) {
            try {
                $sessionState = Get-Content -LiteralPath $sessionStatePath -Raw | ConvertFrom-Json -Depth 30
                if (
                    -not [string]::IsNullOrWhiteSpace([string]$sessionState.repoPath) -and
                    (
                        (ConvertTo-ComparablePath -Path ([string]$sessionState.repoPath)) -ne (ConvertTo-ComparablePath -Path $RepoPath) -or
                        -not [string]::Equals([string]$sessionState.branch, $Branch, [StringComparison]::OrdinalIgnoreCase) -or
                        -not [string]::Equals([string]$sessionState.reviewBase, $ReviewBase, [StringComparison]::OrdinalIgnoreCase)
                    )
                ) {
                    continue
                }
                if (
                    -not [string]::IsNullOrWhiteSpace($RepoPath) -and
                    -not [string]::IsNullOrWhiteSpace([string]$sessionState.lastHead) -and
                    -not [string]::IsNullOrWhiteSpace($CurrentHead)
                ) {
                    $sessionAncestor = Invoke-GitCaptured -RepoPath $RepoPath -Arguments @(
                        "merge-base", "--is-ancestor", [string]$sessionState.lastHead, $CurrentHead
                    )
                    if ($sessionAncestor.ExitCode -ne 0) {
                        continue
                    }
                }
            } catch {
                # Strukturierte Review-Records werden anschließend gegen ihren eigenen Kontext geprüft.
            }
        }

        $reviewLogs = @(Get-ReviewLogEntries -SessionPath $sessionDirectory.FullName)
        if ($reviewLogs.Count -gt 0) {
            $candidate = Get-UnfixedReviewCandidateInSession `
                -RepoLogRoot $RepoLogRoot `
                -CurrentLogRoot $CurrentLogRoot `
                -SessionPath $sessionDirectory.FullName `
                -SessionName $sessionDirectory.Name `
                -RepoPath $RepoPath `
                -Branch $Branch `
                -ReviewBase $ReviewBase `
                -CurrentHead $CurrentHead
            if ($null -ne $candidate) {
                return $candidate
            }
        }

        $recoveryAttempts = @(Get-SessionRecoveryAttemptEntries -SessionPath $sessionDirectory.FullName)
        if ($recoveryAttempts.Count -eq 0) {
            continue
        }

        foreach ($recoveryAttempt in $recoveryAttempts) {
            if ($recoveryAttempt.Succeeded) {
                continue
            }

            $sourceSessionPath = Join-Path $RepoLogRoot $recoveryAttempt.SourceSessionName
            if (-not (Test-Path -LiteralPath $sourceSessionPath)) {
                continue
            }

            $sourceCandidate = Get-UnfixedReviewCandidateInSession `
                -RepoLogRoot $RepoLogRoot `
                -CurrentLogRoot $CurrentLogRoot `
                -SessionPath $sourceSessionPath `
                -SessionName $recoveryAttempt.SourceSessionName `
                -RepoPath $RepoPath `
                -Branch $Branch `
                -ReviewBase $ReviewBase `
                -CurrentHead $CurrentHead

            if ($null -ne $sourceCandidate -and $sourceCandidate.ReviewLabel -eq $recoveryAttempt.ReviewLabel) {
                return $sourceCandidate
            }
        }
    }

    return $null
}

function Select-GitSignalLine {
    param([object[]]$Lines)

    return @($Lines | ForEach-Object { "$_" } | Where-Object {
        $_ -notmatch "LF will be replaced by CRLF" -and
        $_ -notmatch "warning: in the working copy of '.+'"
    })
}

function Invoke-NativeCaptured {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    function ConvertTo-ProcessArgument {
        param([string]$Argument)

        if ($null -eq $Argument) {
            return '""'
        }

        if ($Argument -notmatch '[\s"]') {
            return $Argument
        }

        $escaped = $Argument -replace '(\\*)"', '$1$1\"'
        $escaped = $escaped -replace '(\\+)$', '$1$1'
        return '"' + $escaped + '"'
    }

    $processInfo = New-Object System.Diagnostics.ProcessStartInfo
    $processInfo.FileName = $FilePath
    $argumentListProperty = $processInfo.GetType().GetProperty("ArgumentList")
    if ($argumentListProperty) {
        foreach ($argument in $Arguments) {
            [void]$processInfo.ArgumentList.Add($argument)
        }
    } else {
        $processInfo.Arguments = (($Arguments | ForEach-Object { ConvertTo-ProcessArgument $_ }) -join " ")
    }
    $processInfo.UseShellExecute = $false
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError = $true
    $processInfo.CreateNoWindow = $true
    $processInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $processInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $processInfo
    [void]$process.Start()
    $stdoutText = $process.StandardOutput.ReadToEnd()
    $stderrText = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    $stdout = if ([string]::IsNullOrEmpty($stdoutText)) { @() } else { $stdoutText -split "`r?`n" }
    $stderr = if ([string]::IsNullOrEmpty($stderrText)) { @() } else { $stderrText -split "`r?`n" }

    return [PSCustomObject]@{
        ExitCode = $process.ExitCode
        Output = @(($stdout + $stderr) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
}

function Invoke-GitCaptured {
    param(
        [string]$RepoPath,
        [string[]]$Arguments
    )

    $gitArguments = @("-C", $RepoPath) + $Arguments
    return Invoke-NativeCaptured -FilePath "git" -Arguments $gitArguments
}

function Get-GitOutputLine {
    param(
        [string]$RepoPath,
        [string[]]$Arguments,
        [string]$ErrorMessage
    )

    $result = Invoke-GitCaptured -RepoPath $RepoPath -Arguments $Arguments
    $output = Select-GitSignalLine $result.Output
    if ($result.ExitCode -ne 0) {
        if ($output.Count -gt 0) {
            Write-TextBlock "Git" ($output -join "`n") -Kind "Git"
            throw ($ErrorMessage + "`nGit-Ausgabe:`n" + ($output -join "`n"))
        }
        throw $ErrorMessage
    }

    return @($output)
}

function New-ReviewClassification {
    param(
        [string]$Classification,
        [string]$Source,
        [string]$Reason,
        [Nullable[double]]$Confidence = $null,
        [string]$Model = ""
    )

    return [PSCustomObject]@{
        classification = $Classification
        source = $Source
        confidence = $Confidence
        reason = $Reason
        model = $Model
    }
}

function Write-ReviewClassificationLog {
    param(
        [object]$Classification,
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    $logEntry = [PSCustomObject]@{
        createdAt = (Get-Date).ToString("o")
        classification = $Classification.classification
        source = $Classification.source
        confidence = $Classification.confidence
        reason = $Classification.reason
        model = $Classification.model
    }
    Write-Utf8TextFile -Path $Path -Text ($logEntry | ConvertTo-Json -Depth 4)
}

function ConvertTo-RedactedOpenAIText {
    param([AllowNull()][string]$Text)

    if ($null -eq $Text) {
        return ""
    }

    $redacted = (($Text -replace "org-[A-Za-z0-9_-]+", "org-redacted") -replace "proj[_-][A-Za-z0-9_-]+", "proj-redacted")
    $redacted = $redacted -replace "sk-(proj-)?[A-Za-z0-9_-]{12,}", "sk-redacted"
    $redacted = $redacted -replace "(?i)Bearer\s+[A-Za-z0-9._~+/-]+=*", "Bearer redacted"
    return $redacted
}

function Get-HttpHeaderValue {
    param(
        [object]$Headers,
        [string]$Name
    )

    if ($null -eq $Headers -or [string]::IsNullOrWhiteSpace($Name)) {
        return ""
    }

    foreach ($key in $Headers.Keys) {
        if ([string]::Equals([string]$key, $Name, [StringComparison]::OrdinalIgnoreCase)) {
            return [string]::Join(", ", @($Headers[$key]))
        }
    }

    return ""
}

function ConvertTo-DurationSeconds {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $trimmed = $Value.Trim()
    $seconds = 0.0
    if ([double]::TryParse(
            $trimmed,
            [System.Globalization.NumberStyles]::Float,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [ref]$seconds
        )) {
        return [Math]::Max(1, [int][Math]::Ceiling($seconds))
    }

    $retryAt = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse($trimmed, [ref]$retryAt)) {
        $secondsUntilRetry = [int][Math]::Ceiling(($retryAt - [DateTimeOffset]::Now).TotalSeconds)
        return [Math]::Max(1, $secondsUntilRetry)
    }

    $compact = $trimmed -replace "\s+", ""
    $matches = [regex]::Matches($compact, "(?i)(?<value>\d+(?:\.\d+)?)(?<unit>ms|s|m|h)")
    if ($matches.Count -eq 0) {
        return $null
    }

    $totalSeconds = 0.0
    foreach ($match in $matches) {
        $amount = 0.0
        if (-not [double]::TryParse(
                $match.Groups["value"].Value,
                [System.Globalization.NumberStyles]::Float,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [ref]$amount
            )) {
            continue
        }

        switch ($match.Groups["unit"].Value.ToLowerInvariant()) {
            "ms" { $totalSeconds += ($amount / 1000.0) }
            "s" { $totalSeconds += $amount }
            "m" { $totalSeconds += ($amount * 60.0) }
            "h" { $totalSeconds += ($amount * 3600.0) }
        }
    }

    if ($totalSeconds -le 0) {
        return $null
    }

    return [Math]::Max(1, [int][Math]::Ceiling($totalSeconds))
}

function Get-TryAgainSecondsFromMessage {
    param([string]$Message)

    if ([string]::IsNullOrWhiteSpace($Message)) {
        return $null
    }

    $match = [regex]::Match(
        $Message,
        "(?i)try again in\s+(?<value>\d+(?:\.\d+)?)\s*(?<unit>ms|milliseconds?|s|sec|secs|seconds?|m|min|mins|minutes?|h|hours?)"
    )
    if (-not $match.Success) {
        return $null
    }

    $amount = 0.0
    if (-not [double]::TryParse(
            $match.Groups["value"].Value,
            [System.Globalization.NumberStyles]::Float,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [ref]$amount
        )) {
        return $null
    }

    $unit = $match.Groups["unit"].Value.ToLowerInvariant()
    if ($unit -like "ms*" -or $unit -like "millisecond*") {
        return [Math]::Max(1, [int][Math]::Ceiling($amount / 1000.0))
    }
    if ($unit -like "m*" -or $unit -like "min*") {
        return [Math]::Max(1, [int][Math]::Ceiling($amount * 60.0))
    }
    if ($unit -like "h*" -or $unit -like "hour*") {
        return [Math]::Max(1, [int][Math]::Ceiling($amount * 3600.0))
    }

    return [Math]::Max(1, [int][Math]::Ceiling($amount))
}

function Get-OpenAIErrorInfo {
    param([string]$Content)

    $empty = [PSCustomObject]@{
        type = ""
        code = ""
        message = ""
    }

    if ([string]::IsNullOrWhiteSpace($Content)) {
        return $empty
    }

    try {
        $parsed = $Content | ConvertFrom-Json
        if ($null -eq $parsed.error) {
            return $empty
        }

        return [PSCustomObject]@{
            type = ConvertTo-RedactedOpenAIText ([string]$parsed.error.type)
            code = ConvertTo-RedactedOpenAIText ([string]$parsed.error.code)
            message = ConvertTo-RedactedOpenAIText ([string]$parsed.error.message)
        }
    } catch {
        return [PSCustomObject]@{
            type = ""
            code = ""
            message = ConvertTo-RedactedOpenAIText ($Content.Substring(0, [Math]::Min(500, $Content.Length)))
        }
    }
}

function Get-OpenAIRateLimitHeaderSummary {
    param([object]$Headers)

    $headerNames = @(
        "x-ratelimit-limit-requests",
        "x-ratelimit-remaining-requests",
        "x-ratelimit-reset-requests",
        "x-ratelimit-limit-tokens",
        "x-ratelimit-remaining-tokens",
        "x-ratelimit-reset-tokens",
        "retry-after"
    )

    $parts = @()
    foreach ($headerName in $headerNames) {
        $value = Get-HttpHeaderValue -Headers $Headers -Name $headerName
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $parts += "$headerName=$value"
        }
    }

    return ($parts -join "; ")
}

function Get-OpenAIRetryDelaySeconds {
    param(
        [object]$Headers,
        [string]$Message,
        [int]$Attempt
    )

    $retryAfter = Get-HttpHeaderValue -Headers $Headers -Name "retry-after"
    $retryAfterSeconds = ConvertTo-DurationSeconds -Value $retryAfter
    if ($null -ne $retryAfterSeconds) {
        return $retryAfterSeconds
    }

    $resetSeconds = @()
    foreach ($headerName in @("x-ratelimit-reset-requests", "x-ratelimit-reset-tokens")) {
        $resetValue = Get-HttpHeaderValue -Headers $Headers -Name $headerName
        $durationSeconds = ConvertTo-DurationSeconds -Value $resetValue
        if ($null -ne $durationSeconds) {
            $resetSeconds += $durationSeconds
        }
    }

    if ($resetSeconds.Count -gt 0) {
        return [Math]::Max(1, [int](($resetSeconds | Measure-Object -Maximum).Maximum))
    }

    $messageSeconds = Get-TryAgainSecondsFromMessage -Message $Message
    if ($null -ne $messageSeconds) {
        return $messageSeconds
    }

    return [Math]::Min(60, [int](2 * [Math]::Pow(2, [Math]::Max(0, $Attempt - 1))))
}

function New-OpenAIHttpFailureReason {
    param(
        [int]$StatusCode,
        [object]$ErrorInfo,
        [object]$Headers
    )

    $reason = "OpenAI API HTTP $StatusCode"
    if (-not [string]::IsNullOrWhiteSpace($ErrorInfo.message)) {
        $reason += ": $($ErrorInfo.message)"
    } elseif (-not [string]::IsNullOrWhiteSpace($ErrorInfo.code)) {
        $reason += ": $($ErrorInfo.code)"
    } elseif (-not [string]::IsNullOrWhiteSpace($ErrorInfo.type)) {
        $reason += ": $($ErrorInfo.type)"
    }

    return $reason
}

function Get-LegacyLocalReviewClassification {
    param([string]$ReviewText)

    if ([string]::IsNullOrWhiteSpace($ReviewText)) {
        return New-ReviewClassification `
            -Classification "ambiguous" `
            -Source "local" `
            -Reason "Reviewer-Antwort ist leer."
    }

    $findingPatterns = @(
        "(?im)^\s*(full review comments?|review comments?|review comment|findings?)\s*:\s*$",
        "(?im)^\s*-\s*\[[A-Z]+\d+\]\s+",
        "(?im)\bshould be fixed\b"
    )

    foreach ($pattern in $findingPatterns) {
        if ($ReviewText -match $pattern) {
            return New-ReviewClassification `
                -Classification "finding" `
                -Source "local" `
                -Reason "Konkrete Review-Funde erkannt."
        }
    }

    $cleanPatterns = @(
        "(?im)^\s*(no findings|no issues|no problems|nothing to report)\b",
        "(?im)^\s*keine\s+(funde|probleme|beanstandungen|regressionen)\b",
        "(?im)\bno\s+(discrete,?\s+)?((newly\s+)?introduced\s+)?(actionable\s+)?((correctness|runtime|test-breaking)\s+)?(issues?|regressions?|defects?|bugs?|problems?)(\s+or\s+(blocking\s+)?(issues?|regressions?|defects?|bugs?|problems?))?\s+(were\s+)?(found|identified)\b",
        "(?im)\bno actionable ((correctness|runtime|test-breaking)\s+)?(regressions|findings|issues)\b",
        "(?im)\bi did not (identify|find)\s+(any|a)\s+(clear,?\s+)?(discrete,?\s+)?((newly\s+)?introduced\s+)?(actionable\s+)?((correctness|runtime|test-breaking)\s+or\s+)+((correctness|runtime|test-breaking)\s+)?(issues?|issue|regressions?|regression|defects?|defect|bugs?|bug|problems?|problem)\b",
        "(?im)\bi did not (identify|find)\s+(any|a)\s+(clear,?\s+)?(discrete,?\s+)?((newly\s+)?introduced\s+)?(actionable\s+)?((correctness|runtime|test-breaking)\s+)?(issues?|issue|regressions?|regression|defects?|defect|bugs?|bug|problems?|problem)\b",
        "(?im)\bi found no\b",
        "(?im)\bno discrete,\s*actionable\b",
        "(?im)\bwithout introducing a clear\s+(functional\s+)?(correctness\s+)?regression\b",
        "(?im)\bdo(es)? not introduce a clear,?\s+actionable correctness issue\b",
        "(?im)\bkeine diskreten,\s*umsetzbaren\b",
        "(?im)\bkeine umsetzbaren (regressionen|funde|probleme)\b"
    )

    foreach ($pattern in $cleanPatterns) {
        if ($ReviewText -match $pattern) {
            return New-ReviewClassification `
                -Classification "clean" `
                -Source "local" `
                -Reason "Reviewer meldet keine umsetzbaren Funde."
        }
    }

    return New-ReviewClassification `
        -Classification "ambiguous" `
        -Source "local" `
        -Reason "Keine eindeutigen lokalen Clean- oder Finding-Signale erkannt."
}

function Invoke-ReviewClassificationModel {
    param(
        [string]$ReviewText,
        [string]$Model,
        [string]$ClassificationPath,
        [int]$MaxRateLimitWaitSeconds = 900
    )

    if ([string]::IsNullOrWhiteSpace($env:OPENAI_API_KEY)) {
        $result = New-ReviewClassification `
            -Classification "ambiguous" `
            -Source "model-unavailable" `
            -Reason "OPENAI_API_KEY ist nicht gesetzt."
        Write-ReviewClassificationLog -Classification $result -Path $ClassificationPath
        return $result
    }

    if ([string]::IsNullOrWhiteSpace($Model)) {
        $Model = "gpt-5.4-nano"
    }

    $schema = @{
        type = "object"
        additionalProperties = $false
        properties = @{
            classification = @{
                type = "string"
                enum = @("clean", "finding", "ambiguous")
            }
            confidence = @{
                type = "number"
            }
            reason = @{
                type = "string"
            }
        }
        required = @("classification", "confidence", "reason")
    }

    $prompt = @"
Classify this Codex code review result.

Return clean if the review explicitly says no actionable, discrete issue, regression, defect, or bug was found.
Return finding only if the review asks for a code change or contains concrete review findings/comments.
Return ambiguous if neither is clear.

Review text:
$ReviewText
"@

    $body = @{
        model = $Model
        input = $prompt
        max_output_tokens = 160
        text = @{
            format = @{
                type = "json_schema"
                name = "review_classification"
                strict = $true
                schema = $schema
            }
        }
    } | ConvertTo-Json -Depth 12

    $headers = @{
        Authorization = "Bearer $env:OPENAI_API_KEY"
        "Content-Type" = "application/json"
    }
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    $maxAttempts = 20
    $waitedSeconds = 0

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            $response = Invoke-WebRequest `
                -Method Post `
                -Uri "https://api.openai.com/v1/responses" `
                -Headers $headers `
                -Body $bodyBytes `
                -SkipHttpErrorCheck

            $statusCode = [int]$response.StatusCode
            if ($statusCode -lt 200 -or $statusCode -ge 300) {
                $errorInfo = Get-OpenAIErrorInfo -Content ([string]$response.Content)
                $errorType = ([string]$errorInfo.type).ToLowerInvariant()
                $errorCode = ([string]$errorInfo.code).ToLowerInvariant()
                $failureReason = New-OpenAIHttpFailureReason `
                    -StatusCode $statusCode `
                    -ErrorInfo $errorInfo `
                    -Headers $response.Headers

                if ($statusCode -eq 429 -and ($errorType -eq "insufficient_quota" -or $errorCode -eq "insufficient_quota")) {
                    $result = New-ReviewClassification `
                        -Classification "ambiguous" `
                        -Source "model-quota-error" `
                        -Reason "Modellklassifizierung nicht möglich: API-Kontingent, Credits oder Usage-Limit sind erschöpft ($failureReason). Warten hilft hier nicht." `
                        -Model $Model
                    Write-ReviewClassificationLog -Classification $result -Path $ClassificationPath
                    return $result
                }

                $isRateLimit = $statusCode -eq 429 -and (
                    $errorType -eq "rate_limit_exceeded" -or
                    $errorCode -eq "rate_limit_exceeded" -or
                    $errorInfo.message -match "(?i)rate limit|requests per|tokens per"
                )
                $isRetryable = $isRateLimit -or $statusCode -in @(408, 409, 500, 502, 503, 504)

                if (-not $isRetryable -or $attempt -ge $maxAttempts) {
                    $attemptText = if ($attempt -gt 1) { " nach $attempt Versuchen" } else { "" }
                    $result = New-ReviewClassification `
                        -Classification "ambiguous" `
                        -Source "model-error" `
                        -Reason "Modellklassifizierung fehlgeschlagen$($attemptText): $failureReason" `
                        -Model $Model
                    Write-ReviewClassificationLog -Classification $result -Path $ClassificationPath
                    return $result
                }

                $retryAfterSeconds = Get-OpenAIRetryDelaySeconds `
                    -Headers $response.Headers `
                    -Message $errorInfo.message `
                    -Attempt $attempt
                if ($waitedSeconds + $retryAfterSeconds -gt $MaxRateLimitWaitSeconds) {
                    $result = New-ReviewClassification `
                        -Classification "ambiguous" `
                        -Source "model-rate-limit" `
                        -Reason "Modellklassifizierung wartet nicht weiter: Wartebudget $MaxRateLimitWaitSeconds Sekunden wäre überschritten. Letzter Fehler: $failureReason" `
                        -Model $Model
                    Write-ReviewClassificationLog -Classification $result -Path $ClassificationPath
                    return $result
                }

                $waitedSeconds += $retryAfterSeconds
                Write-Status "Modell-Klassifizierung wartet wegen HTTP ${statusCode}: Retry in $retryAfterSeconds Sekunden ($attempt/$maxAttempts, bisher $waitedSeconds Sekunden)." -Kind "Warning"
                Start-Sleep -Seconds $retryAfterSeconds
                continue
            }

            $responseObject = $response.Content | ConvertFrom-Json

            $responseText = ""
            if ($responseObject.output_text) {
                $responseText = [string]$responseObject.output_text
            } else {
                $responseText = (($responseObject.output | ForEach-Object {
                    $_.content
                } | ForEach-Object {
                    $_.text
                }) -join "")
            }

            if ([string]::IsNullOrWhiteSpace($responseText)) {
                throw "Modellantwort enthielt keinen Klassifizierungstext."
            }

            $parsed = $responseText | ConvertFrom-Json
            $classification = ([string]$parsed.classification).ToLowerInvariant()
            if ($classification -notin @("clean", "finding", "ambiguous")) {
                throw "Unerwartete Klassifizierung: $($parsed.classification)"
            }

            $confidence = $null
            if ($null -ne $parsed.confidence) {
                $confidence = [double]$parsed.confidence
            }

            $result = New-ReviewClassification `
                -Classification $classification `
                -Source "model" `
                -Confidence $confidence `
                -Reason ([string]$parsed.reason) `
                -Model $Model

            if (-not [string]::IsNullOrWhiteSpace($ClassificationPath)) {
                Write-ReviewClassificationLog -Classification $result -Path $ClassificationPath
            }

            return $result
        } catch {
            $result = New-ReviewClassification `
                -Classification "ambiguous" `
                -Source "model-error" `
                -Reason "Modellklassifizierung fehlgeschlagen: $($_.Exception.Message)" `
                -Model $Model
            Write-ReviewClassificationLog -Classification $result -Path $ClassificationPath
            return $result
        }
    }
}

function Get-ReviewClassification {
    param(
        [string]$ReviewText,
        [string]$Model,
        [string]$ClassificationPath,
        [int]$MaxRateLimitWaitSeconds = 900,
        [switch]$DisableModelClassifier
    )

    $localResult = Get-LegacyLocalReviewClassification -ReviewText $ReviewText
    if ($localResult.classification -ne "ambiguous") {
        return $localResult
    }

    if ($DisableModelClassifier) {
        return New-ReviewClassification `
            -Classification "ambiguous" `
            -Source "local" `
            -Reason "$($localResult.reason) Modell-Fallback ist deaktiviert."
    }

    return Invoke-ReviewClassificationModel `
        -ReviewText $ReviewText `
        -Model $Model `
        -ClassificationPath $ClassificationPath `
        -MaxRateLimitWaitSeconds $MaxRateLimitWaitSeconds
}

function Get-ReviewClassificationDisplayName {
    param([string]$Classification)

    switch ($Classification) {
        "clean" { return "sauber" }
        "finding" { return "Funde" }
        "ambiguous" { return "unklar" }
        default { return $Classification }
    }
}

function Get-ReviewClassificationStatusKind {
    param([string]$Classification)

    switch ($Classification) {
        "clean" { return "Success" }
        "finding" { return "Warning" }
        "ambiguous" { return "Error" }
        default { return "Info" }
    }
}

function Test-GitRef {
    param(
        [string]$RepoPath,
        [string]$Ref
    )

    $result = Invoke-GitCaptured -RepoPath $RepoPath -Arguments @("rev-parse", "--verify", "--quiet", $Ref)
    return ($result.ExitCode -eq 0)
}

function Resolve-ReviewBase {
    param(
        [string]$RepoPath,
        [string]$RequestedBase
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedBase)) {
        if (-not (Test-GitRef -RepoPath $RepoPath -Ref $RequestedBase)) {
            throw "Die angegebene Base-Branch wurde nicht gefunden: $RequestedBase"
        }

        return $RequestedBase
    }

    $currentBranch = Get-FirstOutputLine (Get-GitOutputLine -RepoPath $RepoPath -Arguments @("branch", "--show-current") -ErrorMessage "Git-Branch konnte nicht gelesen werden.")
    $candidates = @("origin/main", "origin/master", "main", "master")

    foreach ($candidate in $candidates) {
        if ($candidate -ne $currentBranch -and (Test-GitRef -RepoPath $RepoPath -Ref $candidate)) {
            return $candidate
        }
    }

    return ""
}

function Read-JsonFileAgainstSchema {
    param(
        [string]$JsonPath,
        [string]$SchemaPath,
        [string]$ArtifactName
    )

    if (-not (Test-Path -LiteralPath $JsonPath)) {
        throw "$ArtifactName fehlt: $JsonPath"
    }
    if ((Get-Item -LiteralPath $JsonPath).Length -eq 0) {
        throw "$ArtifactName ist leer: $JsonPath"
    }

    try {
        $isValid = Test-Json -LiteralPath $JsonPath -SchemaFile $SchemaPath -ErrorAction Stop
    } catch {
        throw "$ArtifactName entspricht nicht dem JSON-Schema: $($_.Exception.Message)"
    }
    if (-not $isValid) {
        throw "$ArtifactName entspricht nicht dem JSON-Schema: $JsonPath"
    }

    try {
        return Get-Content -LiteralPath $JsonPath -Raw | ConvertFrom-Json -Depth 50
    } catch {
        throw "$ArtifactName konnte nicht als JSON gelesen werden: $($_.Exception.Message)"
    }
}

function Resolve-CanonicalReviewGitPath {
    param(
        [string]$RepoPath,
        [string]$ReviewBase,
        [string]$Path,
        [switch]$AllowNewPath
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Review-Finding enthält keinen Git-Pfad."
    }

    $candidate = $Path.Trim()
    if (
        $candidate.Contains("\") -or
        [System.IO.Path]::IsPathRooted($candidate) -or
        $candidate -match "^[A-Za-z]:" -or
        $candidate.StartsWith("/") -or
        $candidate.StartsWith("//")
    ) {
        throw "Review-Finding enthält keinen relativen slash-normalisierten Git-Pfad: $Path"
    }

    $segments = @($candidate -split "/")
    if ($segments.Count -eq 0 -or @($segments | Where-Object { $_ -in @("", ".", "..") }).Count -gt 0) {
        throw "Review-Finding enthält einen nicht kanonischen Git-Pfad: $Path"
    }

    $trackedResult = Invoke-GitCaptured -RepoPath $RepoPath -Arguments @("ls-files", "--full-name", "--", $candidate)
    if ($trackedResult.ExitCode -eq 0) {
        $exact = @($trackedResult.Output | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -ceq $candidate })
        if ($exact.Count -eq 1) {
            return $exact[0]
        }
    }

    foreach ($gitRef in @("HEAD", $ReviewBase)) {
        if ([string]::IsNullOrWhiteSpace($gitRef)) {
            continue
        }
        $objectResult = Invoke-GitCaptured -RepoPath $RepoPath -Arguments @("cat-file", "-e", "${gitRef}:$candidate")
        if ($objectResult.ExitCode -eq 0) {
            return $candidate
        }
    }

    if ($AllowNewPath) {
        $parentPath = Split-Path -Parent $candidate
        if ([string]::IsNullOrWhiteSpace($parentPath)) {
            $parentPath = "."
        }
        $parentPattern = if ($parentPath -eq ".") { "*" } else { ($parentPath -replace "\\", "/") + "/*" }
        $parentResult = Invoke-GitCaptured -RepoPath $RepoPath -Arguments @("ls-files", "--", $parentPattern)
        if ($parentResult.ExitCode -eq 0 -and @($parentResult.Output).Count -gt 0) {
            return $candidate
        }
    }

    throw "Review-Finding verweist auf keinen exakten Git-Pfad in Index, HEAD oder Review-Base: $candidate"
}

function New-FindingSignature {
    param([object]$Finding)

    return @(
        "codex_review_path_v2",
        ([string]$Finding.git_path).Trim().ToLowerInvariant()
    ) -join "|"
}

function Get-GitPathLineCount {
    param(
        [string]$RepoPath,
        [string]$ReviewBase,
        [string]$GitPath
    )

    $worktreePath = Join-Path $RepoPath ($GitPath -replace "/", [System.IO.Path]::DirectorySeparatorChar)
    if ([System.IO.File]::Exists($worktreePath)) {
        return [System.IO.File]::ReadAllLines($worktreePath).Length
    }
    foreach ($gitRef in @("HEAD", $ReviewBase)) {
        if ([string]::IsNullOrWhiteSpace($gitRef)) {
            continue
        }
        $content = Invoke-GitCaptured -RepoPath $RepoPath -Arguments @("show", "${gitRef}:$GitPath")
        if ($content.ExitCode -eq 0) {
            return @($content.Output).Count
        }
    }
    return 0
}

function Read-StructuredReviewResult {
    param(
        [string]$ResultPath,
        [string]$SchemaPath,
        [string]$RepoPath,
        [string]$ReviewBase
    )

    $parsed = Read-JsonFileAgainstSchema `
        -JsonPath $ResultPath `
        -SchemaPath $SchemaPath `
        -ArtifactName "Strukturiertes Review-Ergebnis"

    $classification = ([string]$parsed.classification).ToLowerInvariant()
    $rawFindings = @($parsed.findings)
    if ($classification -eq "clean" -and $rawFindings.Count -ne 0) {
        throw "Clean-Review darf keine Findings enthalten."
    }
    if ($classification -eq "finding" -and $rawFindings.Count -eq 0) {
        throw "Finding-Review muss mindestens ein Finding enthalten."
    }

    $findingIds = @{}
    $normalizedFindings = New-Object System.Collections.Generic.List[object]
    foreach ($finding in $rawFindings) {
        if ([int]$finding.line_end -lt [int]$finding.line_start) {
            throw "Finding $($finding.finding_id) enthält einen ungültigen Zeilenbereich."
        }
        $findingId = [string]$finding.finding_id
        if ($findingIds.ContainsKey($findingId)) {
            throw "Finding-ID kommt mehrfach vor: $findingId"
        }
        $findingIds[$findingId] = $true

        $canonicalPath = Resolve-CanonicalReviewGitPath `
            -RepoPath $RepoPath `
            -ReviewBase $ReviewBase `
            -Path ([string]$finding.git_path)
        $lineCount = Get-GitPathLineCount -RepoPath $RepoPath -ReviewBase $ReviewBase -GitPath $canonicalPath
        if ($lineCount -lt 1 -or [int]$finding.line_end -gt $lineCount) {
            throw "Finding $findingId verweist außerhalb des gültigen Zeilenbereichs von $canonicalPath (1-$lineCount)."
        }

        $normalized = [PSCustomObject]@{
            finding_id = $findingId
            title = [string]$finding.title
            priority = ([string]$finding.priority).ToUpperInvariant()
            cause_category = ([string]$finding.cause_category).ToLowerInvariant()
            component = [PSCustomObject]@{
                kind = ([string]$finding.component.kind).ToLowerInvariant()
                id = ([string]$finding.component.id).Trim()
            }
            git_path = $canonicalPath
            line_start = [int]$finding.line_start
            line_end = [int]$finding.line_end
            invariant = [string]$finding.invariant
            explanation = [string]$finding.explanation
            remediation = [string]$finding.remediation
            signature = ""
        }
        $normalized.signature = New-FindingSignature -Finding $normalized
        $normalizedFindings.Add($normalized) | Out-Null
    }

    return [PSCustomObject]@{
        schema_version = "codex_review_result_v1"
        classification = $classification
        summary = [string]$parsed.summary
        findings = $normalizedFindings.ToArray()
        resultPath = $ResultPath
    }
}

function ConvertTo-StructuredReviewText {
    param([object]$Review)

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add([string]$Review.summary) | Out-Null
    if ($Review.classification -eq "clean") {
        $lines.Add("") | Out-Null
        $lines.Add("No findings.") | Out-Null
        return $lines -join "`n"
    }

    $lines.Add("") | Out-Null
    $lines.Add("Full review comments:") | Out-Null
    foreach ($finding in @($Review.findings)) {
        $lineRange = if ($finding.line_start -eq $finding.line_end) {
            [string]$finding.line_start
        } else {
            "$($finding.line_start)-$($finding.line_end)"
        }
        $lines.Add("") | Out-Null
        $lines.Add("- [$($finding.priority)] $($finding.title) — $($finding.git_path):$lineRange") | Out-Null
        $lines.Add("  Ursache: $($finding.cause_category); Komponente: $($finding.component.kind):$($finding.component.id)") | Out-Null
        $lines.Add("  Invariante: $($finding.invariant)") | Out-Null
        $lines.Add("  $($finding.explanation)") | Out-Null
        $lines.Add("  Empfehlung: $($finding.remediation)") | Out-Null
    }

    return $lines -join "`n"
}

function ConvertTo-ArchitectureReportText {
    param([object]$Report)

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add([string]$Report.strategy.title) | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("Scope: $($Report.strategy.scope)") | Out-Null
    $lines.Add("Empfehlung: $($Report.recommendation.action)") | Out-Null
    $lines.Add("Begründung: $($Report.recommendation.reason)") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("URSACHE") | Out-Null
    $lines.Add([string]$Report.root_cause) | Out-Null

    $lines.Add("") | Out-Null
    $lines.Add("EVIDENZ") | Out-Null
    foreach ($evidence in @($Report.evidence)) {
        $lines.Add("- $evidence") | Out-Null
    }

    $lines.Add("") | Out-Null
    $lines.Add("INVARIANTEN") | Out-Null
    $invariantNumber = 0
    foreach ($invariant in @($Report.invariants)) {
        $invariantNumber++
        $lines.Add("") | Out-Null
        $lines.Add("$invariantNumber. $($invariant.statement)") | Out-Null
        $lines.Add("   Szenarien:") | Out-Null
        foreach ($scenario in @($invariant.scenarios)) {
            $members = @($scenario.members) -join "; "
            $lines.Add("   - $($scenario.dimension): $members") | Out-Null
            $lines.Add("     Erwartetes Verhalten: $($scenario.required_behavior)") | Out-Null
        }
        $lines.Add("   Verifikation:") | Out-Null
        foreach ($verification in @($invariant.verification)) {
            $lines.Add("   - [$($verification.level)] $($verification.target)") | Out-Null
            $lines.Add("     Test: $($verification.test)") | Out-Null
            $lines.Add("     Erwartung: $($verification.expected_result)") | Out-Null
        }
    }

    $lines.Add("") | Out-Null
    $lines.Add("STRATEGIE") | Out-Null
    $lines.Add("Ansatz: $($Report.strategy.approach)") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("Schritte:") | Out-Null
    $stepNumber = 0
    foreach ($step in @($Report.strategy.steps)) {
        $stepNumber++
        $lines.Add("$stepNumber. $($step.action)") | Out-Null
        $lines.Add("   Pfade:") | Out-Null
        foreach ($gitPath in @($step.git_paths)) {
            $lines.Add("   - $gitPath") | Out-Null
        }
    }

    $lines.Add("") | Out-Null
    $lines.Add("RISIKEN") | Out-Null
    if (@($Report.strategy.risks).Count -eq 0) {
        $lines.Add("- Keine angegeben.") | Out-Null
    } else {
        foreach ($risk in @($Report.strategy.risks)) {
            $lines.Add("- $risk") | Out-Null
        }
    }

    $lines.Add("") | Out-Null
    $lines.Add("KOMPATIBILITÄT") | Out-Null
    $lines.Add([string]$Report.strategy.compatibility_plan) | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("ROLLBACK") | Out-Null
    $lines.Add([string]$Report.strategy.rollback_plan) | Out-Null

    return $lines -join "`n"
}

function Read-ValidatedArchitectureResult {
    param(
        [string]$ResultPath,
        [string]$SchemaPath,
        [string]$RepoPath,
        [string]$ReviewBase
    )

    $report = Read-JsonFileAgainstSchema `
        -JsonPath $ResultPath `
        -SchemaPath $SchemaPath `
        -ArtifactName "Architekturbericht"

    $allowedPaths = New-Object System.Collections.Generic.List[string]
    $allowedPathSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($step in @($report.strategy.steps)) {
        $stepPathSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $canonicalPaths = New-Object System.Collections.Generic.List[string]
        foreach ($rawPath in @($step.git_paths)) {
            $path = Resolve-CanonicalReviewGitPath `
                -RepoPath $RepoPath `
                -ReviewBase $ReviewBase `
                -Path ([string]$rawPath) `
                -AllowNewPath
            if ($stepPathSet.Add($path)) {
                $canonicalPaths.Add($path) | Out-Null
            }
            if ($allowedPathSet.Add($path)) {
                $allowedPaths.Add($path) | Out-Null
            }
        }
        $step.git_paths = $canonicalPaths.ToArray()
    }
    if ($allowedPaths.Count -eq 0) {
        throw "Architekturstrategie enthält keine erlaubten Git-Pfade."
    }

    return [PSCustomObject]@{
        Report = $report
        AllowedPaths = $allowedPaths.ToArray()
        ResultPath = $ResultPath
        Sha256 = Get-FileSha256 -Path $ResultPath
    }
}

function Get-ArchitectureLocalAutoApplyEligibility {
    param(
        [string]$RepoPath,
        [object]$ArchitectureReport,
        [string[]]$AllowedPaths
    )

    if ([string]$ArchitectureReport.strategy.scope -ne "local") {
        return [PSCustomObject]@{ Eligible = $false; Reason = "Strategie-Scope ist nicht local." }
    }
    $paths = @($AllowedPaths | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
    if ($paths.Count -lt 1 -or $paths.Count -gt 3) {
        return [PSCustomObject]@{ Eligible = $false; Reason = "Lokales Auto-Apply erlaubt ein bis drei Git-Pfade." }
    }

    $parents = @($paths | ForEach-Object {
        $parent = Split-Path -Parent ([string]$_)
        if ([string]::IsNullOrWhiteSpace($parent)) { "." } else { $parent -replace "\\", "/" }
    } | Select-Object -Unique)
    if ($parents.Count -ne 1 -or $parents[0] -eq ".") {
        return [PSCustomObject]@{ Eligible = $false; Reason = "Alle Pfade müssen im selben bestehenden Unterordner liegen." }
    }

    $tracked = Invoke-GitCaptured -RepoPath $RepoPath -Arguments @("ls-files", "--", "$($parents[0])/*")
    if ($tracked.ExitCode -ne 0 -or @($tracked.Output).Count -eq 0) {
        return [PSCustomObject]@{ Eligible = $false; Reason = "Der gemeinsame Ordner enthält keine Git-verfolgte Datei." }
    }

    return [PSCustomObject]@{ Eligible = $true; Reason = "Local-Scope mit höchstens drei Pfaden in einem Git-verfolgten Ordner." }
}

function Read-ValidatedArchitectureDecision {
    param(
        [string]$DecisionPath,
        [string]$SchemaPath,
        [string]$ExpectedReportSha256,
        [string]$ExpectedHead,
        [string]$ExpectedReportCreatedAt = ""
    )

    $decision = Read-JsonFileAgainstSchema `
        -JsonPath $DecisionPath `
        -SchemaPath $SchemaPath `
        -ArtifactName "Architekturentscheidung"

    if (-not [string]::Equals([string]$decision.report_sha256, $ExpectedReportSha256, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Architekturentscheidung gehört nicht zum aktuellen Bericht."
    }
    if (-not [string]::Equals([string]$decision.expected_head, $ExpectedHead, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Architekturentscheidung ist für einen anderen Git-HEAD ausgestellt."
    }
    if ($decision.decision -eq "continue_point_fixes" -and [int]$decision.max_additional_point_fixes -lt 1) {
        throw "continue_point_fixes erfordert mindestens einen zusätzlich erlaubten Punktfix."
    }
    if ($decision.decision -ne "continue_point_fixes" -and [int]$decision.max_additional_point_fixes -ne 0) {
        throw "max_additional_point_fixes muss außerhalb von continue_point_fixes den Wert 0 haben."
    }
    [DateTimeOffset]$decisionTimestamp = [DateTimeOffset]::MinValue
    $hasValidDecisionTimestamp = if ($decision.decided_at -is [DateTime] -or $decision.decided_at -is [DateTimeOffset]) {
        $decisionTimestamp = [DateTimeOffset]$decision.decided_at
        $true
    } else {
        [DateTimeOffset]::TryParse([string]$decision.decided_at, [ref]$decisionTimestamp)
    }
    if (-not $hasValidDecisionTimestamp) {
        throw "Architekturentscheidung enthält keinen gültigen Zeitpunkt."
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedReportCreatedAt)) {
        [DateTimeOffset]$reportCreatedAt = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse($ExpectedReportCreatedAt, [ref]$reportCreatedAt)) {
            throw "Architekturbericht enthält keinen gültigen Erstellungszeitpunkt."
        }
        if ($decisionTimestamp -lt $reportCreatedAt) {
            throw "Architekturentscheidung ist älter als der aktuelle Architekturbericht."
        }
    }
    $decision.decided_at = $decisionTimestamp.ToUniversalTime().ToString("o")

    return $decision
}

function Test-InteractiveArchitectureGate {
    param([bool]$Disabled = $false)

    if ($Disabled -or -not [Environment]::UserInteractive) {
        return $false
    }

    try {
        if ([Console]::IsInputRedirected) {
            return $false
        }
    } catch {
        return $false
    }

    try {
        return $null -ne $Host -and $null -ne $Host.UI
    } catch {
        return $false
    }
}

function Invoke-InteractiveInputNotification {
    try {
        [Console]::Beep(392, 180)
        Start-Sleep -Milliseconds 100
        [Console]::Beep(523, 280)
    } catch {
        # Eine fehlende oder deaktivierte Audioausgabe darf den Review-Loop nicht unterbrechen.
    }
}

function Read-InteractiveArchitectureDecision {
    param(
        [object]$ValidatedArchitecture,
        [object]$ArchitectureRecord,
        [scriptblock]$InputReader
    )

    $usesDefaultInputReader = $null -eq $InputReader
    if ($null -eq $InputReader) {
        $InputReader = {
            param([string]$Prompt)
            Read-Host -Prompt $Prompt
        }
    }

    $recommendation = $ValidatedArchitecture.Report.recommendation
    Write-Rule "Architekturentscheidung" "Step"
    if ($null -ne $recommendation) {
        Write-KeyValue "Empfehlung" ([string]$recommendation.action)
        Write-Paragraph ([string]$recommendation.reason)
    }
    Write-MenuChoice -Key "1" -Text "Strategie genehmigen und durch den Architektur-Fixer umsetzen" -Color ([ConsoleColor]::Green)
    Write-MenuChoice -Key "2" -Text "Strategie mit eigener Anmerkung überarbeiten lassen" -Color ([ConsoleColor]::Yellow)
    Write-MenuChoice -Key "3" -Text "Architekturstrategie vorerst zurückstellen und weitere Punktfixes zulassen" -Color ([ConsoleColor]::Cyan)
    Write-MenuChoice -Key "4" -Text "Lauf abbrechen" -Color ([ConsoleColor]::Red)

    if ($usesDefaultInputReader) {
        Invoke-InteractiveInputNotification
    }

    $action = ""
    while ([string]::IsNullOrWhiteSpace($action)) {
        $selection = [string](& $InputReader "Auswahl [1-4]")
        switch ($selection.Trim().ToLowerInvariant()) {
            { $_ -in @("1", "approve", "approve_strategy", "ja", "j") } {
                $action = "approve_strategy"
                break
            }
            { $_ -in @("2", "revise", "revise_strategy", "überarbeiten", "ueberarbeiten") } {
                $action = "revise_strategy"
                break
            }
            { $_ -in @("3", "continue", "continue_point_fixes", "punktfixes") } {
                $action = "continue_point_fixes"
                break
            }
            { $_ -in @("4", "abort", "abbrechen", "nein", "n") } {
                $action = "abort"
                break
            }
            default {
                Write-Status "Ungültige Auswahl. Bitte 1, 2, 3 oder 4 eingeben." -Kind "Warning"
            }
        }
    }

    $maxAdditionalPointFixes = 0
    if ($action -eq "continue_point_fixes") {
        while ($maxAdditionalPointFixes -lt 1) {
            $rawLimit = [string](& $InputReader "Wie viele weitere Punktfixes sind erlaubt? [1-20]")
            [int]$parsedLimit = 0
            if (
                -not [int]::TryParse($rawLimit.Trim(), [ref]$parsedLimit) -or
                $parsedLimit -lt 1 -or
                $parsedLimit -gt 20
            ) {
                Write-Status "Bitte eine ganze Zahl zwischen 1 und 20 eingeben." -Kind "Warning"
                continue
            }
            $maxAdditionalPointFixes = $parsedLimit
        }
    }

    $note = ""
    while ($true) {
        $notePrompt = if ($action -eq "revise_strategy") {
            "Anmerkung für die Überarbeitung (erforderlich)"
        } else {
            "Anmerkung (optional; Enter überspringt)"
        }
        $note = [string](& $InputReader $notePrompt)
        if ($action -ne "revise_strategy" -or -not [string]::IsNullOrWhiteSpace($note)) {
            break
        }
        Write-Status "Für eine Überarbeitung ist eine konkrete Anmerkung erforderlich." -Kind "Warning"
    }

    $decidedBy = if (-not [string]::IsNullOrWhiteSpace([string]$env:USERNAME)) {
        [string]$env:USERNAME
    } elseif (-not [string]::IsNullOrWhiteSpace([string]$env:USER)) {
        [string]$env:USER
    } else {
        "interactive-user"
    }

    return [PSCustomObject]@{
        schema_version = "codex_review_architecture_decision_v2"
        report_sha256 = [string]$ValidatedArchitecture.Sha256
        expected_head = [string]$ArchitectureRecord.expectedHead
        decision = $action
        decided_by = $decidedBy
        decided_at = (Get-Date).ToUniversalTime().ToString("o")
        note = $note.Trim()
        max_additional_point_fixes = $maxAdditionalPointFixes
    }
}

function Add-ArchitectureDecisionLedgerEntry {
    param(
        [System.Collections.Generic.List[object]]$Ledger,
        [string]$Source,
        [string]$DecisionPath,
        [object]$Decision,
        [object]$ArchitectureRecord
    )

    $automaticMetadata = if ($Source -eq "auto_all") {
        @{
            DecidedBy = "ArchitectureAutoApplyAll"
            Note = "Explizite Laufpolicy: Jede validierte Architekturstrategie wird automatisch freigegeben."
        }
    } else {
        @{
            DecidedBy = "ArchitectureAutoApplyLocal"
            Note = "Standardpolicy für kleine lokale Architekturstrategien: validierter scope=local innerhalb der Host-Grenzen."
        }
    }

    $entry = [PSCustomObject]@{
        source = $Source
        decisionPath = $DecisionPath
        decision = if ($null -ne $Decision) { [string]$Decision.decision } else { "approve_strategy" }
        decidedBy = if ($null -ne $Decision) { [string]$Decision.decided_by } else { $automaticMetadata.DecidedBy }
        decidedAt = if ($null -ne $Decision) { [string]$Decision.decided_at } else { (Get-Date).ToString("o") }
        note = if ($null -ne $Decision) { [string]$Decision.note } else { $automaticMetadata.Note }
        maxAdditionalPointFixes = if ($null -ne $Decision) { [int]$Decision.max_additional_point_fixes } else { 0 }
        reportSha256 = [string]$ArchitectureRecord.reportSha256
        expectedHead = [string]$ArchitectureRecord.expectedHead
        recordedAt = (Get-Date).ToString("o")
    }
    $dedupeKey = "$($entry.source)|$($entry.decisionPath)|$($entry.decision)|$($entry.decidedAt)|$($entry.reportSha256)"
    $alreadyRecorded = @($Ledger | Where-Object {
        "$($_.source)|$($_.decisionPath)|$($_.decision)|$($_.decidedAt)|$($_.reportSha256)" -eq $dedupeKey
    }).Count -gt 0
    if (-not $alreadyRecorded) {
        $Ledger.Add($entry) | Out-Null
    }
}

function Get-ArchitectureManualGateReason {
    param(
        [bool]$AutoApplyLocal,
        [object]$Eligibility
    )

    if (-not $AutoApplyLocal) {
        return "Automatische Umsetzung kleiner lokaler Strategien ist deaktiviert"
    }
    if ($null -eq $Eligibility) {
        return "Automatische Umsetzung ist für diesen Bericht nicht verfügbar"
    }
    if (-not $Eligibility.Eligible -and -not [string]::IsNullOrWhiteSpace([string]$Eligibility.Reason)) {
        return ([string]$Eligibility.Reason).Trim().TrimEnd(".")
    }
    return "Dieser Bericht benötigt eine menschliche Entscheidung"
}

function Get-ArchitectureApprovalStatusMessage {
    param([string]$DecisionSource)

    switch ($DecisionSource) {
        "auto_all" {
            return "Architekturstrategie wird durch -ArchitectureAutoApplyAll automatisch umgesetzt; Architektur-Fixer startet."
        }
        "auto_local" {
            return "Kleine lokale Architekturstrategie erfüllt die Host-Grenzen und wird automatisch umgesetzt; Architektur-Fixer startet."
        }
        "human_file" {
            return "Architekturstrategie wurde durch die gebundene Entscheidung freigegeben; Architektur-Fixer startet."
        }
        "human_interactive" {
            return "Architekturstrategie freigegeben; Architektur-Fixer startet."
        }
        default {
            return "Architekturstrategie freigegeben; Architektur-Fixer startet."
        }
    }
}

function Write-ArchitectureGateApprovalStatus {
    param([string]$DecisionSource)

    Write-Status (Get-ArchitectureApprovalStatusMessage -DecisionSource $DecisionSource) -Kind "Success"
}

function Get-ArchitecturePendingGateMessage {
    param(
        [string]$Reason,
        [string]$ResultPath
    )

    $reasonText = if ([string]::IsNullOrWhiteSpace($Reason)) {
        "Menschliche Freigabe ist erforderlich"
    } else {
        "Menschliche Freigabe ist erforderlich: $($Reason.Trim().TrimEnd('.'))"
    }
    return "$reasonText. Bericht: $ResultPath. Der Lauf wird mit Exitcode 7 angehalten."
}

function Resolve-ArchitectureGateDecision {
    param(
        [string]$RepoPath,
        [object]$ValidatedArchitecture,
        [object]$ArchitectureRecord,
        [bool]$AutoApplyAll,
        [bool]$AutoApplyLocal,
        [string]$DecisionPath,
        [string]$DecisionSchemaPath,
        [System.Collections.Generic.List[object]]$DecisionLedger,
        [bool]$Interactive = $false,
        [scriptblock]$InteractiveInputReader
    )

    $eligibility = Get-ArchitectureLocalAutoApplyEligibility `
        -RepoPath $RepoPath `
        -ArchitectureReport $ValidatedArchitecture.Report `
        -AllowedPaths $ValidatedArchitecture.AllowedPaths
    $manualGateReason = Get-ArchitectureManualGateReason `
        -AutoApplyLocal $AutoApplyLocal `
        -Eligibility $eligibility
    if ($AutoApplyAll) {
        Add-ArchitectureDecisionLedgerEntry `
            -Ledger $DecisionLedger `
            -Source "auto_all" `
            -DecisionPath "" `
            -Decision $null `
            -ArchitectureRecord $ArchitectureRecord
        return [PSCustomObject]@{
            Action = "approve_strategy"
            Decision = $null
            RequiresHumanDecision = $false
            AutoApplyEligibility = $eligibility
            DecisionSource = "auto_all"
            GateReason = ""
        }
    }
    if ($AutoApplyLocal -and $eligibility.Eligible) {
        Add-ArchitectureDecisionLedgerEntry `
            -Ledger $DecisionLedger `
            -Source "auto_local" `
            -DecisionPath "" `
            -Decision $null `
            -ArchitectureRecord $ArchitectureRecord
        return [PSCustomObject]@{
            Action = "approve_strategy"
            Decision = $null
            RequiresHumanDecision = $false
            AutoApplyEligibility = $eligibility
            DecisionSource = "auto_local"
            GateReason = ""
        }
    }

    if ([string]::IsNullOrWhiteSpace($DecisionPath) -and -not $Interactive) {
        return [PSCustomObject]@{
            Action = ""
            Decision = $null
            RequiresHumanDecision = $true
            AutoApplyEligibility = $eligibility
            DecisionSource = "pending"
            GateReason = $manualGateReason
        }
    }

    $decisionSource = "human_file"
    $resolvedDecisionPath = $DecisionPath
    if ($Interactive -and [string]::IsNullOrWhiteSpace($DecisionPath)) {
        Write-Status "Menschliche Freigabe erforderlich: $manualGateReason." -Kind "Info"
        $decision = Read-InteractiveArchitectureDecision `
            -ValidatedArchitecture $ValidatedArchitecture `
            -ArchitectureRecord $ArchitectureRecord `
            -InputReader $InteractiveInputReader
        $decisionSource = "human_interactive"

        $recordPath = [string]$ArchitectureRecord.recordPath
        if (-not [string]::IsNullOrWhiteSpace($recordPath)) {
            if ($recordPath.EndsWith(".record.json", [StringComparison]::OrdinalIgnoreCase)) {
                $resolvedDecisionPath = $recordPath.Substring(0, $recordPath.Length - ".record.json".Length) + ".decision.json"
            } else {
                $resolvedDecisionPath = "$recordPath.decision.json"
            }
            Write-AtomicUtf8TextFile -Path $resolvedDecisionPath -Text ($decision | ConvertTo-Json -Depth 10)
        }
    } else {
        $decision = Read-ValidatedArchitectureDecision `
            -DecisionPath $DecisionPath `
            -SchemaPath $DecisionSchemaPath `
            -ExpectedReportSha256 $ValidatedArchitecture.Sha256 `
            -ExpectedHead ([string]$ArchitectureRecord.expectedHead) `
            -ExpectedReportCreatedAt ([string]$ArchitectureRecord.createdAt)
    }
    Add-ArchitectureDecisionLedgerEntry `
        -Ledger $DecisionLedger `
        -Source $decisionSource `
        -DecisionPath $resolvedDecisionPath `
        -Decision $decision `
        -ArchitectureRecord $ArchitectureRecord
    return [PSCustomObject]@{
        Action = [string]$decision.decision
        Decision = $decision
        RequiresHumanDecision = $false
        AutoApplyEligibility = $eligibility
        DecisionSource = $decisionSource
        GateReason = $manualGateReason
    }
}

function Set-ArchitectureRunLedgerEntry {
    param(
        [System.Collections.Generic.List[object]]$Ledger,
        [object]$Record
    )

    for ($index = 0; $index -lt $Ledger.Count; $index++) {
        if (
            -not [string]::IsNullOrWhiteSpace([string]$Record.recordPath) -and
            [string]::Equals([string]$Ledger[$index].recordPath, [string]$Record.recordPath, [StringComparison]::OrdinalIgnoreCase)
        ) {
            $Ledger[$index] = $Record
            if (-not [string]::IsNullOrWhiteSpace([string]$Record.recordPath)) {
                Write-AtomicUtf8TextFile -Path ([string]$Record.recordPath) -Text ($Record | ConvertTo-Json -Depth 30)
            }
            return
        }
    }
    $Ledger.Add($Record) | Out-Null
    if (-not [string]::IsNullOrWhiteSpace([string]$Record.recordPath)) {
        Write-AtomicUtf8TextFile -Path ([string]$Record.recordPath) -Text ($Record | ConvertTo-Json -Depth 30)
    }
}

function ConvertTo-GitRelativePath {
    param(
        [string]$RepoPath,
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path $Path)) {
        return ""
    }

    $repoFullPath = (Resolve-Path $RepoPath).Path.TrimEnd("\", "/") + "\"
    $fileFullPath = (Resolve-Path $Path).Path
    if (-not $fileFullPath.StartsWith($repoFullPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        return ""
    }

    $repoUri = New-Object System.Uri($repoFullPath)
    $fileUri = New-Object System.Uri($fileFullPath)
    return [System.Uri]::UnescapeDataString($repoUri.MakeRelativeUri($fileUri).ToString())
}

function Get-PorcelainPath {
    param([string]$StatusLine)

    if ($StatusLine.Length -le 3) {
        return ""
    }

    $path = $StatusLine.Substring(3).Trim()
    if ($path -match "\s+->\s+(.+)$") {
        return $Matches[1].Trim()
    }

    return $path.Trim('"')
}

function Get-PorcelainPaths {
    param([string]$StatusLine)

    if ($StatusLine.Length -le 3) {
        return @()
    }
    $pathText = $StatusLine.Substring(3).Trim()
    if ($pathText -match "^(.+?)\s+->\s+(.+)$") {
        return @($Matches[1].Trim().Trim('"'), $Matches[2].Trim().Trim('"'))
    }
    return @($pathText.Trim('"'))
}

function Test-GitPathHasWhitespaceOnlySegment {
    param([string]$Path)

    if ([string]::IsNullOrEmpty($Path)) {
        return $false
    }

    foreach ($segment in ($Path -split "/")) {
        if ($segment.Length -gt 0 -and [string]::IsNullOrWhiteSpace($segment)) {
            return $true
        }
    }

    return $false
}

function Get-RelevantGitStatus {
    param(
        [string]$RepoPath,
        [string[]]$IgnoredPaths
    )

    $ignored = @{}
    foreach ($ignoredPath in $IgnoredPaths) {
        if (-not [string]::IsNullOrWhiteSpace($ignoredPath)) {
            $ignored[$ignoredPath] = $true
        }
    }

    $status = Get-GitOutputLine -RepoPath $RepoPath -Arguments @("status", "--porcelain") -ErrorMessage "Git-Status konnte nicht gelesen werden."

    return @($status | Where-Object {
        $paths = @(Get-PorcelainPaths -StatusLine ([string]$_))
        @($paths | Where-Object { -not $ignored.ContainsKey($_) }).Count -gt 0
    })
}

function Invoke-FixerWithRecovery {
    param(
        [string]$RepoPath,
        [string]$IterationLabel,
        [string]$LogRoot,
        [string]$FixPrompt,
        [string]$FixerThreadId,
        [string]$Model,
        [string]$Thinking,
        [string]$Speed,
        [string[]]$IgnoredPaths
    )

    $currentFixerThreadId = $FixerThreadId
    $promptForAttempt = $FixPrompt
    $retryIndex = 0
    $lastResult = $null

    while ($true) {
        $usingResume = -not [string]::IsNullOrWhiteSpace($currentFixerThreadId)
        $logStem = Get-FixAttemptLogStem -LogRoot $LogRoot -IterationLabel $IterationLabel -RetryIndex $retryIndex

        if ($retryIndex -gt 0) {
            Write-Status "Fixer-Recovery startet eine frische Session (Retry $retryIndex/1)." -Kind "Warning"
        }

        $fixArgs = Get-CodexFixerArgumentList `
            -RepoPath $RepoPath `
            -Sandbox "workspace-write" `
            -Model $Model `
            -Thinking $Thinking `
            -Speed $Speed `
            -FixerThreadId $currentFixerThreadId

        $fixResult = Invoke-CodexJson `
            -Arguments $fixArgs `
            -JsonlPath "${logStem}.jsonl" `
            -TextPath "${logStem}.txt" `
            -StdinText $promptForAttempt

        $lastResult = $fixResult

        if ($fixResult.ExitCode -eq 0) {
            $nextFixerThreadId = $currentFixerThreadId
            if (-not [string]::IsNullOrWhiteSpace($fixResult.ThreadId)) {
                $nextFixerThreadId = $fixResult.ThreadId
            }

            return [PSCustomObject]@{
                Succeeded = $true
                Result = $fixResult
                FixerThreadId = $nextFixerThreadId
                RetryCount = $retryIndex
                ErrorMessage = ""
                ExitCode = 0
            }
        }

        if ($retryIndex -ge 1) {
            break
        }

        $statusAfterFailure = Get-RelevantGitStatus -RepoPath $RepoPath -IgnoredPaths $IgnoredPaths

        if ($usingResume -and (Test-CodexResumeFailure -Result $fixResult)) {
            Write-Status "Fixer-Resume fehlgeschlagen; starte frische Session. Ursache: $(Get-CodexFailureHeadline -Result $fixResult)" -Kind "Warning"
            Write-KeyValue "Log" $fixResult.JsonlPath
            $currentFixerThreadId = $null
            $promptForAttempt = $FixPrompt
            $retryIndex++
            continue
        }

        if ($statusAfterFailure.Count -eq 0) {
            Write-Status "Fixer fehlgeschlagen ohne Änderungen; starte frische Session. Ursache: $(Get-CodexFailureHeadline -Result $fixResult)" -Kind "Warning"
            Write-KeyValue "Log" $fixResult.JsonlPath
            $currentFixerThreadId = $null
            $promptForAttempt = $FixPrompt
            $retryIndex++
            continue
        }

        Write-Status "Fixer fehlgeschlagen, Änderungen vorhanden; Recovery prüft den aktuellen Diff. Ursache: $(Get-CodexFailureHeadline -Result $fixResult)" -Kind "Warning"
        Write-KeyValue "Log" $fixResult.JsonlPath
        $currentFixerThreadId = $null
        $promptForAttempt = New-FixerRecoveryPrompt `
            -FixPrompt $FixPrompt `
            -ExitCode $fixResult.ExitCode `
            -Reason "Der vorherige Lauf hat Dateiänderungen im Arbeitsbaum hinterlassen."
        $retryIndex++
    }

    $exitCode = 1
    $details = ""
    if ($null -ne $lastResult) {
        $exitCode = $lastResult.ExitCode
        $details = $lastResult.JsonlPath
    }

    $errorMessage = if ($null -ne $lastResult) {
        New-CodexFailureMessage -Actor "Fixer" -Result $lastResult -Context "auch nach Recovery-Retry"
    } else {
        "Fixer ist fehlgeschlagen, auch nach Recovery-Retry. Details: $details"
    }

    return [PSCustomObject]@{
        Succeeded = $false
        Result = $lastResult
        FixerThreadId = $currentFixerThreadId
        RetryCount = $retryIndex
        ErrorMessage = $errorMessage
        ExitCode = $exitCode
    }
}

function Get-CommitTitle {
    param(
        [string]$FixSummary,
        [string]$Fallback
    )

    $candidate = $null
    $lines = @($FixSummary -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    foreach ($line in $lines) {
        if ($line -match "^(Commit|Commit message|Commit-Message|Titel|Title):\s*(.+)$") {
            $candidate = $Matches[2].Trim()
            break
        }
    }

    if (-not $candidate) {
        foreach ($line in $lines) {
            if ($line -notmatch "^(Tests?|Prüfung|Zusammenfassung|Summary|Geändert|Changed):\b" -and $line.Length -ge 12) {
                $candidate = $line
                break
            }
        }
    }

    if (-not $candidate) {
        $candidate = $Fallback
    }

    $candidate = $candidate -replace "^[`"']|[`"']$", ""
    $candidate = $candidate -replace "\s+", " "

    if ($candidate.Length -gt 72) {
        $candidate = $candidate.Substring(0, 72).TrimEnd()
    }

    if ([string]::IsNullOrWhiteSpace($candidate)) {
        return $Fallback
    }

    return $candidate
}

function Save-FixChange {
    param(
        [string]$RepoPath,
        [string]$IterationLabel,
        [string]$ReviewLogPath,
        [string]$FixSummary,
        [string]$CommitMessageFallback,
        [string[]]$IgnoredPaths,
        [ValidateSet("normal", "architecture", "recovery")]
        [string]$Mode = "normal",
        [string[]]$AllowedPaths = @()
    )

    $status = Get-RelevantGitStatus -RepoPath $RepoPath -IgnoredPaths $IgnoredPaths
    if ($status.Count -eq 0) {
        Write-Status "Fixer hat keine Dateiänderungen erzeugt; Commit wird übersprungen." -Kind "Info"
        return $null
    }

    $skippedStatus = @($status | Where-Object {
        @((Get-PorcelainPaths -StatusLine ([string]$_)) | Where-Object {
            Test-GitPathHasWhitespaceOnlySegment $_
        }).Count -gt 0
    })
    if ($skippedStatus.Count -gt 0) {
        Write-TextBlock "Git add überspringt ungültige Pfade" ($skippedStatus -join "`n") -Kind "Warning"
    }

    $stagingPaths = @($status | ForEach-Object {
        Get-PorcelainPaths -StatusLine ([string]$_)
    } | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_) -and
        -not (Test-GitPathHasWhitespaceOnlySegment $_)
    } | Select-Object -Unique)

    if ($stagingPaths.Count -eq 0) {
        Write-Status "Nach dem Ausschließen ungültiger Pfade bleiben keine Commit-Änderungen übrig." -Kind "Info"
        return $null
    }

    if ($AllowedPaths.Count -gt 0) {
        $allowed = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($allowedPath in $AllowedPaths) {
            [void]$allowed.Add($allowedPath)
        }
        $outsideScope = @($stagingPaths | Where-Object { -not $allowed.Contains($_) })
        if ($outsideScope.Count -gt 0) {
            throw "Architektur-Fixer hat nicht freigegebene Git-Pfade geändert: $($outsideScope -join ', ')"
        }
    } elseif ($Mode -eq "architecture") {
        throw "Architektur-Fixer besitzt keine freigegebenen Git-Pfade."
    }

    $gitAddArguments = @("-C", $RepoPath, "add", "-A", "--") + $stagingPaths
    $gitAddResult = Invoke-NativeCaptured -FilePath "git" -Arguments $gitAddArguments
    $gitAddOutput = Select-GitSignalLine $gitAddResult.Output
    if ($gitAddOutput.Count -gt 0) {
        Write-TextBlock "Git add" ($gitAddOutput -join "`n") -Kind "Git"
    }

    if ($gitAddResult.ExitCode -ne 0) {
        $details = if ($gitAddOutput.Count -gt 0) { "`nGit-Ausgabe:`n" + ($gitAddOutput -join "`n") } else { "" }
        throw "Git add ist mit Exitcode $($gitAddResult.ExitCode) fehlgeschlagen.$details"
    }

    foreach ($ignoredPath in $IgnoredPaths) {
        if (-not [string]::IsNullOrWhiteSpace($ignoredPath)) {
            $restoreResult = Invoke-GitCaptured -RepoPath $RepoPath -Arguments @("restore", "--staged", "--", $ignoredPath)
            if ($restoreResult.ExitCode -ne 0) {
                Invoke-GitCaptured -RepoPath $RepoPath -Arguments @("reset", "-q", "--", $ignoredPath) | Out-Null
            }
        }
    }

    $stagedStatus = Get-GitOutputLine -RepoPath $RepoPath -Arguments @("diff", "--cached", "--name-only") -ErrorMessage "Git-Index konnte nach dem Staging nicht geprüft werden."

    if ($stagedStatus.Count -eq 0) {
        Write-Status "Nach dem Ausschließen lokaler Hilfsdateien bleiben keine Commit-Änderungen übrig." -Kind "Info"
        return $null
    }

    $message = Get-CommitTitle -FixSummary $FixSummary -Fallback $CommitMessageFallback
    $body = @(
        "Automatischer Commit aus dem Codex Review-Loop.",
        "Iteration: $IterationLabel",
        "Review-Log: $ReviewLogPath",
        "",
        "Fixer-Zusammenfassung:",
        $FixSummary
    ) -join "`n"

    $commitResult = Invoke-NativeCaptured -FilePath "git" -Arguments @("-C", $RepoPath, "commit", "-m", $message, "-m", $body)
    $commitOutput = Select-GitSignalLine $commitResult.Output

    if ($commitResult.ExitCode -ne 0) {
        if ($commitOutput.Count -gt 0) {
            Write-TextBlock "Git commit" ($commitOutput -join "`n") -Kind "Error"
        }
        $details = if ($commitOutput.Count -gt 0) { "`nGit-Ausgabe:`n" + ($commitOutput -join "`n") } else { "" }
        throw "Git commit ist mit Exitcode $($commitResult.ExitCode) fehlgeschlagen.$details"
    }

    $commitSha = Get-FirstOutputLine (Get-GitOutputLine -RepoPath $RepoPath -Arguments @("rev-parse", "--short", "HEAD") -ErrorMessage "Commit-Hash konnte nicht gelesen werden.")
    if ([string]::IsNullOrWhiteSpace($commitSha)) {
        throw "Commit-Hash konnte nicht gelesen werden."
    }

    Write-Status "Fix-Commit erstellt: $commitSha - $message" -Kind "Success"
    return [PSCustomObject]@{
        CommitSha = $commitSha
        GitPaths = @($stagedStatus)
        Mode = $Mode
        Message = $message
    }
}

function Get-CurrentGitHead {
    param([string]$RepoPath)

    return Get-FirstOutputLine (Get-GitOutputLine `
        -RepoPath $RepoPath `
        -Arguments @("rev-parse", "HEAD") `
        -ErrorMessage "Git-HEAD konnte nicht gelesen werden.")
}

function Restore-ReviewerWorktree {
    param(
        [string]$RepoPath,
        [string]$ExpectedHead
    )

    if ([string]::IsNullOrWhiteSpace($ExpectedHead)) {
        return
    }

    $reset = Invoke-GitCaptured -RepoPath $RepoPath -Arguments @("reset", "--hard", $ExpectedHead)
    if ($reset.ExitCode -ne 0) {
        throw "Reviewer-Änderungen konnten nicht auf HEAD $ExpectedHead zurückgesetzt werden."
    }

    $clean = Invoke-GitCaptured -RepoPath $RepoPath -Arguments @("clean", "-fd")
    if ($clean.ExitCode -ne 0) {
        throw "Vom Reviewer erzeugte untracked Dateien konnten nicht entfernt werden."
    }
}

function Invoke-CodexReviewerJson {
    param(
        [string]$RepoPath,
        [string[]]$Arguments,
        [string]$JsonlPath,
        [string]$TextPath,
        [string]$OutputLastMessagePath = "",
        [string]$StdinText = $null
    )

    $reviewHead = ""
    $statusResult = Invoke-GitCaptured -RepoPath $RepoPath -Arguments @("status", "--porcelain")
    if ($statusResult.ExitCode -ne 0) {
        throw "Git-Status vor dem Reviewer konnte nicht gelesen werden."
    }
    $statusBefore = @($statusResult.Output | Where-Object {
        [string]$_ -match "^[ MADRCU?!]{2} "
    })
    if ($statusBefore.Count -eq 0) {
        $reviewHead = Get-CurrentGitHead -RepoPath $RepoPath
    }

    try {
        return Invoke-CodexJson `
            -Arguments $Arguments `
            -JsonlPath $JsonlPath `
            -TextPath $TextPath `
            -OutputLastMessagePath $OutputLastMessagePath `
            -StdinText $StdinText
    } finally {
        Restore-ReviewerWorktree -RepoPath $RepoPath -ExpectedHead $reviewHead
    }
}

function New-StructuredReviewRecord {
    param(
        [string]$RepoPath,
        [string]$Branch,
        [string]$ReviewBase,
        [string]$IterationLabel,
        [string]$EpochId,
        [string]$ReviewHead,
        [object]$StructuredReview,
        [string]$TextPath,
        [string]$ResultPath,
        [string]$JsonlPath
    )

    return [PSCustomObject]@{
        schemaVersion = "codex_review_record_v1"
        reviewId = "$(Split-Path -Leaf $RepoPath):$($Branch):$($IterationLabel):$ReviewHead"
        iterationLabel = $IterationLabel
        epochId = $EpochId
        repoPath = $RepoPath
        branch = $Branch
        reviewBase = $ReviewBase
        reviewHead = $ReviewHead
        classification = $StructuredReview.classification
        summary = $StructuredReview.summary
        findings = @($StructuredReview.findings)
        textPath = $TextPath
        resultPath = $ResultPath
        recordPath = Join-Path (Split-Path -Parent $ResultPath) ((Split-Path -Leaf $ResultPath) -replace "\.result\.json$", ".record.json")
        jsonlPath = $JsonlPath
        fixCommit = ""
        fixMode = ""
        architectureTrigger = $null
        createdAt = (Get-Date).ToString("o")
    }
}

function Get-ArchitectureTrigger {
    param(
        [object]$CurrentReviewRecord,
        [object[]]$ReviewLedger,
        [object[]]$FixCommitRecords,
        [int]$RepeatThreshold,
        [int]$HotspotFixThreshold
    )

    if ($null -eq $CurrentReviewRecord -or $CurrentReviewRecord.classification -ne "finding") {
        return $null
    }

    $triggerTypes = New-Object System.Collections.Generic.List[string]
    $reviewIds = New-Object System.Collections.Generic.List[string]
    $commits = New-Object System.Collections.Generic.List[string]
    $paths = New-Object System.Collections.Generic.List[string]
    $signatures = New-Object System.Collections.Generic.List[string]

    foreach ($currentFinding in @($CurrentReviewRecord.findings)) {
        $priorMatches = New-Object System.Collections.Generic.List[object]
        foreach ($review in @($ReviewLedger)) {
            if (
                $review.reviewId -eq $CurrentReviewRecord.reviewId -or
                [string]::IsNullOrWhiteSpace([string]$review.fixCommit) -or
                $review.epochId -ne $CurrentReviewRecord.epochId
            ) {
                continue
            }
            foreach ($priorFinding in @($review.findings)) {
                if ([string]::Equals([string]$priorFinding.signature, [string]$currentFinding.signature, [StringComparison]::OrdinalIgnoreCase)) {
                    $priorMatches.Add($review) | Out-Null
                    break
                }
            }
        }

        if (($priorMatches.Count + 1) -ge $RepeatThreshold) {
            if (-not $triggerTypes.Contains("repeat_path")) {
                $triggerTypes.Add("repeat_path") | Out-Null
            }
            if (-not $paths.Contains([string]$currentFinding.git_path)) {
                $paths.Add([string]$currentFinding.git_path) | Out-Null
            }
            if (-not $signatures.Contains([string]$currentFinding.signature)) {
                $signatures.Add([string]$currentFinding.signature) | Out-Null
            }
            foreach ($match in $priorMatches.ToArray()) {
                if (-not $reviewIds.Contains([string]$match.reviewId)) {
                    $reviewIds.Add([string]$match.reviewId) | Out-Null
                }
                if (-not $commits.Contains([string]$match.fixCommit)) {
                    $commits.Add([string]$match.fixCommit) | Out-Null
                }
            }
        }
    }

    $normalFixes = @($FixCommitRecords | Where-Object {
        $_.mode -in @("normal", "recovery") -and $_.epochId -eq $CurrentReviewRecord.epochId
    })
    foreach ($path in @($CurrentReviewRecord.findings.git_path | Select-Object -Unique)) {
        $hotspotFixes = @($normalFixes | Where-Object {
            @($_.gitPaths | Where-Object { [string]::Equals([string]$_, [string]$path, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
        })
        if ($hotspotFixes.Count -ge $HotspotFixThreshold) {
            if (-not $triggerTypes.Contains("hotspot_fallback")) {
                $triggerTypes.Add("hotspot_fallback") | Out-Null
            }
            if (-not $paths.Contains([string]$path)) {
                $paths.Add([string]$path) | Out-Null
            }
            foreach ($fix in $hotspotFixes) {
                if (-not $commits.Contains([string]$fix.commitSha)) {
                    $commits.Add([string]$fix.commitSha) | Out-Null
                }
            }
        }
    }

    if ($triggerTypes.Count -eq 0) {
        return $null
    }
    if (-not $reviewIds.Contains([string]$CurrentReviewRecord.reviewId)) {
        $reviewIds.Add([string]$CurrentReviewRecord.reviewId) | Out-Null
    }

    return [PSCustomObject]@{
        schemaVersion = "codex_review_architecture_trigger_v2"
        triggerTypes = $triggerTypes.ToArray()
        reviewIds = $reviewIds.ToArray()
        fixCommits = $commits.ToArray()
        gitPaths = $paths.ToArray()
        signatures = $signatures.ToArray()
        epochId = $CurrentReviewRecord.epochId
        createdAt = (Get-Date).ToString("o")
    }
}

function Assert-ArchitecturePendingContext {
    param(
        [object]$ArchitectureRecord,
        [string]$RepoPath,
        [string]$Branch,
        [string]$ReviewBase,
        [string]$EpochId,
        [string]$Head,
        [string]$LedgerDigest
    )

    if (
        (ConvertTo-ComparablePath -Path ([string]$ArchitectureRecord.repoPath)) -ne (ConvertTo-ComparablePath -Path $RepoPath) -or
        -not [string]::Equals([string]$ArchitectureRecord.branch, $Branch, [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([string]$ArchitectureRecord.reviewBase, $ReviewBase, [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([string]$ArchitectureRecord.epochId, $EpochId, [StringComparison]::Ordinal) -or
        [string]::IsNullOrWhiteSpace($LedgerDigest) -or
        -not [string]::Equals([string]$ArchitectureRecord.ledgerDigest, $LedgerDigest, [StringComparison]::OrdinalIgnoreCase)
    ) {
        throw "Ausstehender Architekturbericht passt nicht mehr zu Repository, Branch, Base, Epoch oder Ledger."
    }
    if (-not [string]::Equals([string]$ArchitectureRecord.expectedHead, $Head, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Ausstehender Architekturbericht ist für einen anderen Git-HEAD ausgestellt."
    }
}

function Resolve-StalePendingArchitecture {
    param(
        [object]$ArchitectureRecord,
        [string]$CurrentHead,
        [object[]]$GitStatus,
        [System.Collections.Generic.List[object]]$ArchitectureRuns
    )

    if (
        $null -eq $ArchitectureRecord -or
        $GitStatus.Count -gt 0 -or
        [string]::Equals(
            [string]$ArchitectureRecord.expectedHead,
            $CurrentHead,
            [StringComparison]::OrdinalIgnoreCase)
    ) {
        return $false
    }

    $ArchitectureRecord.status = "superseded"
    $ArchitectureRecord | Add-Member -NotePropertyName supersededAt -NotePropertyValue (Get-Date).ToString("o") -Force
    $ArchitectureRecord | Add-Member -NotePropertyName supersededReason -NotePropertyValue "git_head_changed" -Force
    $ArchitectureRecord | Add-Member -NotePropertyName supersededByHead -NotePropertyValue $CurrentHead -Force
    Set-ArchitectureRunLedgerEntry -Ledger $ArchitectureRuns -Record $ArchitectureRecord
    return $true
}

function Get-PendingV1MigrationTrigger {
    param(
        [object]$ArchitectureRecord,
        [object[]]$ReviewLedger,
        [object[]]$FixCommitRecords,
        [int]$RepeatThreshold,
        [int]$HotspotFixThreshold
    )

    if ($null -eq $ArchitectureRecord.currentReviewRecord -or $null -eq $ArchitectureRecord.trigger) {
        throw "Offenes v1-Architektur-Gate kann nicht migriert werden: gespeicherter Trigger oder Reviewkontext fehlt."
    }
    foreach ($finding in @($ArchitectureRecord.currentReviewRecord.findings)) {
        $finding | Add-Member `
            -NotePropertyName signature `
            -NotePropertyValue (New-FindingSignature -Finding $finding) `
            -Force
    }
    $trigger = Get-ArchitectureTrigger `
        -CurrentReviewRecord $ArchitectureRecord.currentReviewRecord `
        -ReviewLedger $ReviewLedger `
        -FixCommitRecords $FixCommitRecords `
        -RepeatThreshold $RepeatThreshold `
        -HotspotFixThreshold $HotspotFixThreshold
    if ($null -eq $trigger) {
        throw "Offenes v1-Architektur-Gate kann nicht als v2 neu analysiert werden: der gespeicherte Kontext löst keinen v2-Trigger aus."
    }
    return $trigger
}

function Invoke-StructuredReviewWithRetry {
    param(
        [string]$RepoPath,
        [string]$Branch,
        [string]$ReviewBase,
        [string]$IterationLabel,
        [string]$EpochId,
        [string]$LogRoot,
        [string]$SchemaPath,
        [string]$Model,
        [string]$Thinking,
        [string]$Speed,
        [string]$CustomPrompt
    )

    $resultPath = Join-Path $LogRoot "review-$IterationLabel.result.json"
    $textPath = Join-Path $LogRoot "review-$IterationLabel.txt"
    $nativeTextPath = Join-Path $LogRoot "review-$IterationLabel.native.txt"
    $recordPath = Join-Path $LogRoot "review-$IterationLabel.record.json"
    $lastValidationError = ""
    $lastRun = $null
    $structured = $null
    $structuredJsonlPath = ""
    $previousInvalidResult = ""

    $nativeJsonlPath = Join-Path $LogRoot "review-$IterationLabel.jsonl"
    $reviewArgs = Get-CodexExecArgumentList -RepoPath $RepoPath -Sandbox "read-only"
    $reviewArgs = Add-CodexRunOptionArguments -Arguments $reviewArgs -Model $Model -Thinking $Thinking -Speed $Speed
    $reviewArgs = Add-CodexDeveloperInstructionsArgument -Arguments $reviewArgs -Instructions $CustomPrompt
    $reviewArgs += @("review", "--base", $ReviewBase, "--output-last-message", $nativeTextPath)

    $nativeRun = Invoke-CodexReviewerJson `
        -RepoPath $RepoPath `
        -Arguments $reviewArgs `
        -JsonlPath $nativeJsonlPath `
        -TextPath $nativeTextPath `
        -OutputLastMessagePath $nativeTextPath
    $lastRun = $nativeRun

    if ($nativeRun.ExitCode -ne 0) {
        return [PSCustomObject]@{
            Succeeded = $false; ExitCode = $nativeRun.ExitCode; Result = $nativeRun
            ErrorMessage = New-CodexFailureMessage -Actor "Reviewer" -Result $nativeRun
        }
    }

    $nativeReviewText = [string]$nativeRun.Text
    if ([string]::IsNullOrWhiteSpace($nativeReviewText)) {
        return [PSCustomObject]@{
            Succeeded = $false; ExitCode = 9; Result = $nativeRun
            ErrorMessage = "Der native Reviewer hat keine auswertbare Abschlussmeldung erzeugt."
        }
    }

    Write-Status "Nativer Review-Text wird in das strukturierte Ergebnisschema überführt." -Kind "Info"
    for ($attempt = 0; $attempt -le 1; $attempt++) {
        $attemptNumber = $attempt + 1
        $suffix = if ($attempt -eq 0) { "-structure" } else { "-structure-retry01" }
        $structureJsonlPath = Join-Path $LogRoot "review-$IterationLabel$suffix.jsonl"
        $attemptResultPath = Join-Path $LogRoot ("review-$IterationLabel.structure-attempt{0:D2}.result.json" -f $attemptNumber)
        $structureArgs = Get-CodexExecArgumentList -RepoPath $RepoPath -Sandbox "read-only"
        $structureArgs = Add-CodexRunOptionArguments -Arguments $structureArgs -Model $Model -Thinking $Thinking -Speed $Speed
        $structureArgs += @("--output-schema", $SchemaPath, "--output-last-message", $attemptResultPath, "-")
        $structureRun = Invoke-CodexReviewerJson `
            -RepoPath $RepoPath `
            -Arguments $structureArgs `
            -JsonlPath $structureJsonlPath `
            -TextPath $textPath `
            -OutputLastMessagePath $attemptResultPath `
            -StdinText (New-StructuredReviewNormalizationPrompt `
                -NativeReviewText $nativeReviewText `
                -PreviousResult $previousInvalidResult `
                -ValidationError $lastValidationError)
        $lastRun = $structureRun

        if ($structureRun.ExitCode -ne 0) {
            return [PSCustomObject]@{
                Succeeded = $false; ExitCode = $structureRun.ExitCode; Result = $structureRun
                ErrorMessage = New-CodexFailureMessage -Actor "Review-Strukturierung" -Result $structureRun
            }
        }

        try {
            $structured = Read-StructuredReviewResult `
                -ResultPath $attemptResultPath `
                -SchemaPath $SchemaPath `
                -RepoPath $RepoPath `
                -ReviewBase $ReviewBase
            $structuredJsonlPath = $structureJsonlPath
            Write-AtomicUtf8TextFile -Path $resultPath -Text (Get-Content -LiteralPath $attemptResultPath -Raw)
            $structured.resultPath = $resultPath
            break
        } catch {
            $lastValidationError = $_.Exception.Message
            $previousInvalidResult = if (Test-Path -LiteralPath $attemptResultPath) {
                Get-Content -LiteralPath $attemptResultPath -Raw
            } else { "" }
            Write-Status "Strukturierung des Review-Ergebnisses ist ungültig: $lastValidationError" -Kind "Warning"
            if ($attempt -eq 0) {
                Write-Status "Review-Strukturierung repariert den Vertragsfehler einmal mit konkretem Fehlerkontext." -Kind "Warning"
            }
        }
    }

    if ($null -eq $structured) {
        return [PSCustomObject]@{
            Succeeded = $false; ExitCode = 9; Result = $lastRun
            ErrorMessage = "Review-Strukturierung blieb nach einem Retry ungültig: $lastValidationError"
        }
    }

    $rendered = ConvertTo-StructuredReviewText -Review $structured
    Write-Utf8TextFile -Path $textPath -Text $rendered
    $reviewHead = Get-CurrentGitHead -RepoPath $RepoPath
    $record = New-StructuredReviewRecord `
        -RepoPath $RepoPath `
        -Branch $Branch `
        -ReviewBase $ReviewBase `
        -IterationLabel $IterationLabel `
        -EpochId $EpochId `
        -ReviewHead $reviewHead `
        -StructuredReview $structured `
        -TextPath $textPath `
        -ResultPath $resultPath `
        -JsonlPath $structuredJsonlPath
    $record | Add-Member -NotePropertyName nativeReviewJsonlPath -NotePropertyValue $nativeJsonlPath -Force
    if (Test-Path -LiteralPath $nativeTextPath) {
        $record | Add-Member -NotePropertyName nativeReviewTextPath -NotePropertyValue $nativeTextPath -Force
    }
    Write-AtomicUtf8TextFile -Path $recordPath -Text ($record | ConvertTo-Json -Depth 20)
    return [PSCustomObject]@{
        Succeeded = $true; ExitCode = 0; Result = $lastRun
        StructuredReview = $structured; Record = $record
        Text = $rendered; TextPath = $textPath; RecordPath = $recordPath; ResultPath = $resultPath
    }
}

function Get-ArchitectureEvidenceContext {
    param(
        [object]$Trigger,
        [object]$CurrentReviewRecord,
        [object[]]$ReviewLedger,
        [object[]]$FixCommitRecords
    )

    $pathSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in @($Trigger.gitPaths)) {
        [void]$pathSet.Add([string]$path)
    }
    $reviewIdSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($reviewId in @($Trigger.reviewIds)) {
        [void]$reviewIdSet.Add([string]$reviewId)
    }
    $commitSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($commit in @($Trigger.fixCommits)) {
        [void]$commitSet.Add([string]$commit)
    }

    $current = [PSCustomObject]@{
        reviewId = [string]$CurrentReviewRecord.reviewId
        reviewHead = [string]$CurrentReviewRecord.reviewHead
        summary = [string]$CurrentReviewRecord.summary
        findings = @($CurrentReviewRecord.findings | Where-Object { $pathSet.Contains([string]$_.git_path) })
    }
    $reviews = @($ReviewLedger | Where-Object {
        $_.reviewId -ne $CurrentReviewRecord.reviewId -and $reviewIdSet.Contains([string]$_.reviewId)
    } | ForEach-Object {
        [PSCustomObject]@{
            reviewId = [string]$_.reviewId
            reviewHead = [string]$_.reviewHead
            fixCommit = [string]$_.fixCommit
            findings = @($_.findings | Where-Object { $pathSet.Contains([string]$_.git_path) })
        }
    })
    $fixes = @($FixCommitRecords | Where-Object { $commitSet.Contains([string]$_.commitSha) } | ForEach-Object {
        [PSCustomObject]@{
            commitSha = [string]$_.commitSha
            reviewId = [string]$_.reviewId
            gitPaths = @($_.gitPaths | Where-Object { $pathSet.Contains([string]$_) })
        }
    })

    return [PSCustomObject]@{
        CurrentReview = $current
        Reviews = $reviews
        Fixes = $fixes
    }
}

function Invoke-ArchitectureAnalysisWithRetry {
    param(
        [string]$RepoPath,
        [string]$Branch,
        [string]$ReviewBase,
        [string]$EpochId,
        [string]$IterationLabel,
        [string]$LogRoot,
        [string]$SchemaPath,
        [string]$Model,
        [string]$Thinking,
        [string]$Speed,
        [object]$Trigger,
        [object]$CurrentReviewRecord,
        [object[]]$ReviewLedger,
        [object[]]$FixCommitRecords,
        [string[]]$IgnoredPaths,
        [string]$RevisionGuidance = ""
    )

    $resultPath = Join-Path $LogRoot "architecture-$IterationLabel.result.json"
    $textPath = Join-Path $LogRoot "architecture-$IterationLabel.txt"
    $recordPath = Join-Path $LogRoot "architecture-$IterationLabel.record.json"
    $lastValidationError = ""
    $lastRun = $null
    $previousInvalidResult = ""
    $evidence = Get-ArchitectureEvidenceContext `
        -Trigger $Trigger `
        -CurrentReviewRecord $CurrentReviewRecord `
        -ReviewLedger $ReviewLedger `
        -FixCommitRecords $FixCommitRecords

    for ($attempt = 0; $attempt -le 1; $attempt++) {
        $attemptNumber = $attempt + 1
        $suffix = if ($attempt -eq 0) { "" } else { "-retry01" }
        $jsonlPath = Join-Path $LogRoot "architecture-$IterationLabel$suffix.jsonl"
        $attemptResultPath = Join-Path $LogRoot ("architecture-$IterationLabel.attempt{0:D2}.result.json" -f $attemptNumber)
        $statusBefore = @(Get-RelevantGitStatus -RepoPath $RepoPath -IgnoredPaths $IgnoredPaths | Sort-Object)
        $args = Get-CodexReadOnlyArchitectureArgumentList -RepoPath $RepoPath
        $args = Add-CodexRunOptionArguments -Arguments $args -Model $Model -Thinking $Thinking -Speed $Speed
        $args += @("--output-schema", $SchemaPath, "--output-last-message", $attemptResultPath, "-")
        $run = Invoke-CodexReviewerJson `
            -RepoPath $RepoPath `
            -Arguments $args `
            -JsonlPath $jsonlPath `
            -TextPath $textPath `
            -OutputLastMessagePath $attemptResultPath `
            -StdinText (New-ArchitectureAnalysisPrompt `
                -Trigger $Trigger `
                -CurrentReviewRecord $evidence.CurrentReview `
                -ReviewLedger $evidence.Reviews `
                -FixCommitRecords $evidence.Fixes `
                -RevisionGuidance $RevisionGuidance `
                -PreviousResult $previousInvalidResult `
                -ValidationError $lastValidationError)
        $lastRun = $run
        $statusAfter = @(Get-RelevantGitStatus -RepoPath $RepoPath -IgnoredPaths $IgnoredPaths | Sort-Object)
        if (($statusBefore -join "`n") -cne ($statusAfter -join "`n")) {
            return [PSCustomObject]@{
                Succeeded = $false; ExitCode = 8; Result = $run
                ErrorMessage = "Read-only Architekturlauf hat den Arbeitsbaum verändert."
            }
        }
        if ($run.ExitCode -ne 0) {
            return [PSCustomObject]@{
                Succeeded = $false; ExitCode = $run.ExitCode; Result = $run
                ErrorMessage = New-CodexFailureMessage -Actor "Architekturanalyse" -Result $run
            }
        }

        try {
            $validated = Read-ValidatedArchitectureResult `
                -ResultPath $attemptResultPath `
                -SchemaPath $SchemaPath `
                -RepoPath $RepoPath `
                -ReviewBase $ReviewBase
            Write-AtomicUtf8TextFile -Path $resultPath -Text (Get-Content -LiteralPath $attemptResultPath -Raw)
            $validated.ResultPath = $resultPath
            $expectedHead = Get-CurrentGitHead -RepoPath $RepoPath
            $record = [PSCustomObject]@{
                schemaVersion = "codex_review_architecture_record_v2"
                architectureContractVersion = 2
                repoPath = $RepoPath
                branch = $Branch
                reviewBase = $ReviewBase
                epochId = $EpochId
                expectedHead = $expectedHead
                ledgerDigest = Get-ArchitectureContextDigest `
                    -ReviewLedger $ReviewLedger `
                    -FixCommitRecords $FixCommitRecords `
                    -EpochId $EpochId
                reportSha256 = $validated.Sha256
                scope = [string]$validated.Report.strategy.scope
                resultPath = $resultPath
                recordPath = $recordPath
                allowedPaths = @($validated.AllowedPaths)
                trigger = $Trigger
                status = "analyzed"
                createdAt = (Get-Date).ToString("o")
            }
            Write-AtomicUtf8TextFile -Path $textPath -Text ($validated.Report | ConvertTo-Json -Depth 30)
            Write-AtomicUtf8TextFile -Path $recordPath -Text ($record | ConvertTo-Json -Depth 20)
            return [PSCustomObject]@{
                Succeeded = $true; ExitCode = 0; Result = $run
                Architecture = $validated; Record = $record; TextPath = $textPath; RecordPath = $recordPath
            }
        } catch {
            $lastValidationError = $_.Exception.Message
            $previousInvalidResult = if (Test-Path -LiteralPath $attemptResultPath) {
                Get-Content -LiteralPath $attemptResultPath -Raw
            } else { "" }
            Write-Status "Architekturbericht ist ungültig: $lastValidationError" -Kind "Warning"
            if ($attempt -eq 0) {
                Write-Status "Architekturbericht repariert den Vertragsfehler einmal mit konkretem Fehlerkontext." -Kind "Warning"
            }
        }
    }

    return [PSCustomObject]@{
        Succeeded = $false; ExitCode = 9; Result = $lastRun
        ErrorMessage = "Architekturbericht blieb nach einem Retry ungültig: $lastValidationError"
    }
}

function Get-LatestCompatibleReviewLoopState {
    param(
        [string]$RepoPath,
        [string]$RepoLogRoot,
        [string]$CurrentLogRoot,
        [string]$Branch,
        [string]$ReviewBase,
        [string]$CurrentHead
    )

    if (-not (Test-Path -LiteralPath $RepoLogRoot)) {
        return $null
    }
    $currentComparable = ConvertTo-ComparablePath -Path $CurrentLogRoot
    foreach ($session in @(Get-ChildItem -LiteralPath $RepoLogRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
        if ((ConvertTo-ComparablePath -Path $session.FullName) -eq $currentComparable) {
            continue
        }
        $statePath = Join-Path $session.FullName "state.json"
        if (-not (Test-Path -LiteralPath $statePath)) {
            $statePath = Join-Path $session.FullName "summary.json"
        }
        if (-not (Test-Path -LiteralPath $statePath)) {
            continue
        }
        try {
            $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -Depth 50
        } catch {
            continue
        }
        if (
            (ConvertTo-ComparablePath -Path ([string]$state.repoPath)) -ne (ConvertTo-ComparablePath -Path $RepoPath) -or
            -not [string]::Equals([string]$state.branch, $Branch, [StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals([string]$state.reviewBase, $ReviewBase, [StringComparison]::OrdinalIgnoreCase)
        ) {
            continue
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$state.lastHead)) {
            $ancestor = Invoke-GitCaptured -RepoPath $RepoPath -Arguments @("merge-base", "--is-ancestor", [string]$state.lastHead, $CurrentHead)
            if ($ancestor.ExitCode -ne 0) {
                continue
            }
        }
        return $state
    }
    return $null
}

function Invoke-ApprovedArchitectureFix {
    param(
        [string]$RepoPath,
        [string]$IterationLabel,
        [string]$LogRoot,
        [string]$FixPromptPrefix,
        [object]$ArchitectureReport,
        [object]$ArchitectureRecord,
        [object]$CurrentReviewRecord,
        [string]$Model,
        [string]$Thinking,
        [string]$Speed,
        [string]$CommitMessageFallback,
        [string[]]$IgnoredPaths
    )

    $fixPrompt = New-ArchitectureFixPrompt `
        -FixPromptPrefix $FixPromptPrefix `
        -ArchitectureReport $ArchitectureReport `
        -CurrentReviewRecord $CurrentReviewRecord
    $fixRun = Invoke-FixerWithRecovery `
        -RepoPath $RepoPath `
        -IterationLabel "architecture-$IterationLabel" `
        -LogRoot $LogRoot `
        -FixPrompt $fixPrompt `
        -FixerThreadId "" `
        -Model $Model `
        -Thinking $Thinking `
        -Speed $Speed `
        -IgnoredPaths $IgnoredPaths

    if (-not $fixRun.Succeeded) {
        return [PSCustomObject]@{
            Succeeded = $false; ExitCode = $fixRun.ExitCode; ErrorMessage = $fixRun.ErrorMessage
            FixerThreadId = $fixRun.FixerThreadId; CommitRecord = $null
        }
    }

    Write-TextBlock "ARCHITEKTUR-FIXER-ANTWORT $IterationLabel" $fixRun.Result.Text -Kind "Fixer"
    try {
        $commitRecord = Save-FixChange `
            -RepoPath $RepoPath `
            -IterationLabel "architecture-$IterationLabel" `
            -ReviewLogPath $ArchitectureRecord.resultPath `
            -FixSummary $fixRun.Result.Text `
            -CommitMessageFallback $CommitMessageFallback `
            -IgnoredPaths $IgnoredPaths `
            -Mode "architecture" `
            -AllowedPaths @($ArchitectureRecord.allowedPaths)
    } catch {
        return [PSCustomObject]@{
            Succeeded = $false; ExitCode = 8; ErrorMessage = $_.Exception.Message
            FixerThreadId = $fixRun.FixerThreadId; CommitRecord = $null
        }
    }

    if ($null -eq $commitRecord) {
        return [PSCustomObject]@{
            Succeeded = $false; ExitCode = 8
            ErrorMessage = "Freigegebener Architektur-Fixer hat keinen Commit erzeugt."
            FixerThreadId = $fixRun.FixerThreadId; CommitRecord = $null
        }
    }

    return [PSCustomObject]@{
        Succeeded = $true; ExitCode = 0; ErrorMessage = ""
        FixerThreadId = $fixRun.FixerThreadId; CommitRecord = $commitRecord
    }
}

function Invoke-ArchitectureGateNonApprovalAction {
    param(
        [string]$Action,
        [object]$Decision,
        [object]$ArchitectureRecord,
        [string]$RepoPath,
        [string]$Branch,
        [string]$ReviewBase,
        [string]$EpochId,
        [string]$LogRoot,
        [string]$SchemaPath,
        [string]$Model,
        [string]$Thinking,
        [string]$Speed,
        [object[]]$ReviewLedger,
        [object[]]$FixCommitRecords,
        [string[]]$IgnoredPaths,
        [System.Collections.Generic.List[object]]$ArchitectureRuns,
        [System.Collections.Generic.List[object]]$ArchitectureDecisions,
        [string]$DecisionSchemaPath,
        [bool]$InteractiveGate = $false,
        [bool]$AutoApplyAll = $false,
        [bool]$AutoApplyLocal = $false
    )

    switch ($Action) {
        "abort" {
            Write-FatalMessage `
                "Architekturänderung wurde durch die menschliche Entscheidung abgebrochen." `
                10 `
                -Status "aborted" `
                -CompletionReason "architecture_aborted_by_human"
        }
        "revise_strategy" {
            if ($null -eq $Decision) {
                Write-FatalMessage "Für eine Architekturrevision fehlt die validierte menschliche Entscheidung." 8
            }
            $currentReviewRecord = $ArchitectureRecord.currentReviewRecord
            if ($null -eq $currentReviewRecord) {
                Write-FatalMessage "Ausstehendem Architekturbericht fehlt das auslösende Review-Record." 8
            }
            $ArchitectureRecord.status = "revision_requested"
            Set-ArchitectureRunLedgerEntry -Ledger $ArchitectureRuns -Record $ArchitectureRecord
            $revisionNumber = @($ArchitectureDecisions | Where-Object { $_.decision -eq "revise_strategy" }).Count
            $revisionLabel = "{0}-revision{1:D2}" -f ([string]$ArchitectureRecord.iterationLabel), [Math]::Max(1, $revisionNumber)
            $script:RunState.status = "architecture_analysis"
            Save-ReviewLoopCheckpoint -State $script:RunState
            $revisionAnalysis = Invoke-ArchitectureAnalysisWithRetry `
                -RepoPath $RepoPath `
                -Branch $Branch `
                -ReviewBase $ReviewBase `
                -EpochId $EpochId `
                -IterationLabel $revisionLabel `
                -LogRoot $LogRoot `
                -SchemaPath $SchemaPath `
                -Model $Model `
                -Thinking $Thinking `
                -Speed $Speed `
                -Trigger $ArchitectureRecord.trigger `
                -CurrentReviewRecord $currentReviewRecord `
                -ReviewLedger $ReviewLedger `
                -FixCommitRecords $FixCommitRecords `
                -IgnoredPaths $IgnoredPaths `
                -RevisionGuidance ([string]$Decision.note)
            if (-not $revisionAnalysis.Succeeded) {
                Write-FatalMessage $revisionAnalysis.ErrorMessage $revisionAnalysis.ExitCode
            }
            $revisedRecord = $revisionAnalysis.Record
            $revisedRecord | Add-Member -NotePropertyName iterationLabel -NotePropertyValue $revisionLabel -Force
            $revisedRecord | Add-Member -NotePropertyName currentReviewRecord -NotePropertyValue $currentReviewRecord -Force
            $revisedRecord.status = "pending"
            Set-ArchitectureRunLedgerEntry -Ledger $ArchitectureRuns -Record $revisedRecord
            $script:RunState.pendingArchitecture = $revisedRecord
            $script:RunState.status = "architecture_gate_pending"
            $script:RunState.completionReason = "architecture_decision_required"
            $script:RunState.exitCode = 7
            Save-ReviewLoopCheckpoint -State $script:RunState
            Write-ArchitectureReportBlock `
                -Title "ÜBERARBEITETER ARCHITEKTURBERICHT $revisionLabel" `
                -Report $revisionAnalysis.Architecture.Report
            if ($InteractiveGate) {
                try {
                    $revisedGateResolution = Resolve-ArchitectureGateDecision `
                        -RepoPath $RepoPath `
                        -ValidatedArchitecture $revisionAnalysis.Architecture `
                        -ArchitectureRecord $revisedRecord `
                        -AutoApplyAll $AutoApplyAll `
                        -AutoApplyLocal $AutoApplyLocal `
                        -DecisionPath "" `
                        -DecisionSchemaPath $DecisionSchemaPath `
                        -DecisionLedger $ArchitectureDecisions `
                        -Interactive $true
                } catch {
                    Write-FatalMessage "Architekturentscheidung ist ungültig oder stale: $($_.Exception.Message)" 8
                }
                if ($revisedGateResolution.RequiresHumanDecision) {
                    Write-FatalMessage "Interaktives Architektur-Gate konnte keine Entscheidung erfassen." 8
                }
                return [PSCustomObject]@{
                    WaiverRemaining = $null
                    NextAction = [string]$revisedGateResolution.Action
                    Decision = $revisedGateResolution.Decision
                    ArchitectureRecord = $revisedRecord
                    ValidatedArchitecture = $revisionAnalysis.Architecture
                    DecisionSource = [string]$revisedGateResolution.DecisionSource
                    GateReason = [string]$revisedGateResolution.GateReason
                }
            }
            Write-Status "Überarbeiteter read-only Architekturbericht benötigt eine neue Entscheidung: $($revisedRecord.resultPath)" -Kind "Warning"
            Stop-RestartGuard -Guard $script:RestartGuard
            exit 7
        }
        "continue_point_fixes" {
            if ($null -eq $Decision) {
                Write-FatalMessage "Für den Architektur-Waiver fehlt die validierte menschliche Entscheidung." 8
            }
            $waiverRemaining = [int]$Decision.max_additional_point_fixes
            $ArchitectureRecord.status = "waived"
            Set-ArchitectureRunLedgerEntry -Ledger $ArchitectureRuns -Record $ArchitectureRecord
            $script:RunState.architectureWaiverRemaining = $waiverRemaining
            $script:RunState.pendingArchitecture = $null
            $script:RunState.status = "running"
            $script:RunState.completionReason = ""
            $script:RunState.exitCode = $null
            Save-ReviewLoopCheckpoint -State $script:RunState
            Write-Status "Human-Waiver erlaubt $waiverRemaining weitere Punktfixes." -Kind "Warning"
            return [PSCustomObject]@{
                WaiverRemaining = $waiverRemaining
                NextAction = ""
                Decision = $Decision
                ArchitectureRecord = $ArchitectureRecord
                ValidatedArchitecture = $null
                DecisionSource = ""
                GateReason = ""
            }
        }
        default {
            return [PSCustomObject]@{
                WaiverRemaining = $null
                NextAction = ""
                Decision = $Decision
                ArchitectureRecord = $ArchitectureRecord
                ValidatedArchitecture = $null
                DecisionSource = ""
                GateReason = ""
            }
        }
    }
}

function Invoke-CodexReviewLoopMain {

trap {
    Stop-RestartGuard -Guard $script:RestartGuard
    $message = if ($_.Exception -and -not [string]::IsNullOrWhiteSpace($_.Exception.Message)) {
        $_.Exception.Message
    } else {
        [string]$_
    }
    if ($null -ne $script:RunState) {
        $script:RunState.status = "failed"
        $script:RunState.completionReason = "unhandled_error"
        $script:RunState.exitCode = 1
        $script:RunState.lastError = $message
        try {
            Save-ReviewLoopCheckpoint -State $script:RunState
        } catch {
        }
    }
    Write-ErrorBlock "FEHLER" $message
    exit 1
}

if ($Help) {
    Show-Help
    exit 0
}

if ([string]::IsNullOrWhiteSpace($RepoPath)) {
    Show-Help
    exit 0
}

Assert-NativeCommandAvailable "git"
Assert-NativeCommandAvailable "codex"

$RepoPath = Resolve-RepositoryPath $RepoPath
$scriptRelativePath = ConvertTo-GitRelativePath -RepoPath $RepoPath -Path $PSCommandPath
$ignoredCommitPaths = @($scriptRelativePath, "scripts/Invoke-CodexReviewLoop.ps1") | Where-Object {
    -not [string]::IsNullOrWhiteSpace($_)
} | Select-Object -Unique

$gitStatus = Get-RelevantGitStatus -RepoPath $RepoPath -IgnoredPaths $ignoredCommitPaths

$repoLogRoot = Get-RepoLogRoot -RepoPath $RepoPath -LogRoot $LogRoot
if ([string]::IsNullOrWhiteSpace($LogRoot)) {
    $LogRoot = Get-DefaultLogRoot -RepoPath $RepoPath
}

New-Item -ItemType Directory -Path $LogRoot -Force | Out-Null
$schemaPaths = Write-ReviewLoopSchemaFiles -LogRoot $LogRoot

$reviewBase = Resolve-ReviewBase -RepoPath $RepoPath -RequestedBase $BaseBranch
if ([string]::IsNullOrWhiteSpace($reviewBase)) {
    Write-FatalMessage "Keine Base-Branch für den PR-Review gefunden. Übergib -BaseBranch, z. B. -BaseBranch origin/master." 6
}

$currentBranch = Get-FirstOutputLine (Get-GitOutputLine -RepoPath $RepoPath -Arguments @("branch", "--show-current") -ErrorMessage "Git-Branch konnte nicht gelesen werden.")
if ([string]::IsNullOrWhiteSpace($currentBranch)) {
    $currentBranch = Get-FirstOutputLine (Get-GitOutputLine -RepoPath $RepoPath -Arguments @("rev-parse", "--short", "HEAD") -ErrorMessage "Commit-Hash konnte nicht gelesen werden.")
}

if ([string]::IsNullOrWhiteSpace($ArchitectureModel)) {
    $ArchitectureModel = $Model
}
$architectureAutoApplyAllEnabled = [bool]$ArchitectureAutoApplyAll
$architectureAutoApplyLocalEnabled = [bool]$ArchitectureAutoApplyLocal -and -not [bool]$DisableArchitectureAutoApplyLocal
$interactiveArchitectureGate = Test-InteractiveArchitectureGate -Disabled ([bool]$DisableInteractiveArchitectureGate)
$currentHead = Get-CurrentGitHead -RepoPath $RepoPath
$previousState = Get-LatestCompatibleReviewLoopState `
    -RepoPath $RepoPath `
    -RepoLogRoot $repoLogRoot `
    -CurrentLogRoot $LogRoot `
    -Branch $currentBranch `
    -ReviewBase $reviewBase `
    -CurrentHead $currentHead

$architectureWorktreeRecovery = $false
$architectureRecoveryScopeViolation = $false
if ($gitStatus -and -not $AllowDirtyWorktree) {
    $previousPendingArchitecture = if ($null -ne $previousState) { $previousState.pendingArchitecture } else { $null }
    $mayRecoverArchitectureWorktree = (
        $ArchitectureMode -eq "Enforce" -and
        $null -ne $previousPendingArchitecture -and
        ([string]$previousPendingArchitecture.status -eq "fixing" -or [string]$previousState.status -eq "architecture_fixing")
    )
    if ($mayRecoverArchitectureWorktree) {
        $allowedRecoveryPaths = @($previousPendingArchitecture.allowedPaths | ForEach-Object { ([string]$_).ToLowerInvariant() })
        $dirtyRecoveryPaths = @($gitStatus | ForEach-Object {
            Get-PorcelainPaths -StatusLine ([string]$_)
        } | ForEach-Object { ([string]$_).ToLowerInvariant() } | Select-Object -Unique)
        $outOfScopeRecoveryPaths = @($dirtyRecoveryPaths | Where-Object { $_ -notin $allowedRecoveryPaths })
        if ($outOfScopeRecoveryPaths.Count -eq 0) {
            $architectureWorktreeRecovery = $true
        } else {
            $architectureRecoveryScopeViolation = $true
        }
    }
    if (-not $architectureWorktreeRecovery) {
        if ($architectureRecoveryScopeViolation) {
            Write-FatalMessage "Unterbrochener Architekturfix enthält nicht deklarierte Git-Pfade: $($outOfScopeRecoveryPaths -join ', ')" 8
        }
        Write-FatalMessage "Der Arbeitsbaum ist nicht sauber. Starte erneut mit -AllowDirtyWorktree, wenn der Loop vorhandene Änderungen berücksichtigen darf." 3
    }
}

if (-not $DisableRestartGuard) {
    $script:RestartGuard = Start-RestartGuard
}

$fixerThreadId = if ([string]::IsNullOrWhiteSpace($FixerThreadId)) { $null } else { $FixerThreadId }
$cleanPasses = 0
$noCommitPasses = 0
$iteration = 0
$fixCommits = New-Object System.Collections.Generic.List[string]
$recoveredReviews = New-Object System.Collections.Generic.List[object]
$reviewLedger = New-Object System.Collections.Generic.List[object]
$fixCommitRecords = New-Object System.Collections.Generic.List[object]
$architectureTriggers = New-Object System.Collections.Generic.List[object]
$architectureRuns = New-Object System.Collections.Generic.List[object]
$architectureDecisions = New-Object System.Collections.Generic.List[object]
$architectureFixerThreadIds = New-Object System.Collections.Generic.List[string]
$activeEpochId = [guid]::NewGuid().ToString("N")
$architectureWaiverRemaining = 0
$pendingArchitecture = $null
$skipLastUnfixedReviewRecoveryForRun = $false
$loadedLegacyContextDigest = ""

if ($null -ne $previousState) {
    if (-not [string]::IsNullOrWhiteSpace([string]$previousState.activeEpochId)) {
        $activeEpochId = [string]$previousState.activeEpochId
    }
    foreach ($entry in @($previousState.reviewLedger)) {
        $reviewLedger.Add($entry) | Out-Null
    }
    foreach ($entry in @($previousState.fixCommitRecords)) {
        $fixCommitRecords.Add($entry) | Out-Null
    }
    $loadedLegacyContextDigest = Get-ArchitectureContextDigest `
        -ReviewLedger $reviewLedger.ToArray() `
        -FixCommitRecords $fixCommitRecords.ToArray() `
        -EpochId $activeEpochId
    foreach ($review in $reviewLedger.ToArray()) {
        foreach ($finding in @($review.findings)) {
            $finding | Add-Member `
                -NotePropertyName signature `
                -NotePropertyValue (New-FindingSignature -Finding $finding) `
                -Force
        }
    }
    foreach ($entry in @($previousState.architectureTriggers)) {
        $architectureTriggers.Add($entry) | Out-Null
    }
    foreach ($entry in @($previousState.architectureRuns)) {
        $architectureRuns.Add($entry) | Out-Null
    }
    foreach ($entry in @($previousState.architectureDecisions)) {
        $architectureDecisions.Add($entry) | Out-Null
    }
    if ($null -ne $previousState.architectureWaiverRemaining) {
        $architectureWaiverRemaining = [int]$previousState.architectureWaiverRemaining
    }
    if (
        $null -ne $previousState.pendingArchitecture -and
        (
            $previousState.status -in @("architecture_gate_pending", "architecture_revision_requested", "architecture_fixing", "failed") -or
            [string]$previousState.pendingArchitecture.status -in @("pending", "revision_requested", "fixing")
        )
    ) {
        $pendingArchitecture = $previousState.pendingArchitecture
    }
}

$script:RunState = [PSCustomObject]@{
    summarySchemaVersion = 2
    repoPath = $RepoPath
    logRoot = $LogRoot
    branch = $currentBranch
    reviewBase = $reviewBase
    model = $Model
    thinking = $ReviewThinking
    reviewThinking = $ReviewThinking
    fixerThinking = $FixerThinking
    architectureModel = $ArchitectureModel
    architectureThinking = $ArchitectureThinking
    architectureFixerThinking = $ArchitectureFixerThinking
    speed = $Speed
    serviceTier = Resolve-CodexServiceTier -RequestedSpeed $Speed
    reviewResultMode = $ReviewResultMode
    architectureMode = $ArchitectureMode
    architectureRepeatThreshold = $ArchitectureRepeatThreshold
    architectureHotspotFixThreshold = $ArchitectureHotspotFixThreshold
    architectureAutoApplyAll = $architectureAutoApplyAllEnabled
    architectureAutoApplyLocal = $architectureAutoApplyLocalEnabled
    interactiveArchitectureGate = $interactiveArchitectureGate
    activeEpochId = $activeEpochId
    architectureWaiverRemaining = $architectureWaiverRemaining
    normalFixerThreadId = $fixerThreadId
    fixerThreadId = $fixerThreadId
    architectureFixerThreadIds = $architectureFixerThreadIds
    fixCommits = $fixCommits
    fixCommitRecords = $fixCommitRecords
    reviewLedger = $reviewLedger
    architectureTriggers = $architectureTriggers
    architectureRuns = $architectureRuns
    architectureDecisions = $architectureDecisions
    recoveredReviews = $recoveredReviews
    pendingArchitecture = $pendingArchitecture
    iterations = 0
    cleanPasses = 0
    cleanPassesRequired = $PassesRequired
    noCommitPasses = 0
    noCommitPassesRequired = $PassesRequired
    passesRequired = $PassesRequired
    completed = $false
    completionReason = ""
    status = "running"
    exitCode = $null
    lastError = ""
    lastHead = $currentHead
    legacyClassificationUsed = $false
    createdAt = (Get-Date).ToString("o")
    updatedAt = (Get-Date).ToString("o")
}
Save-ReviewLoopCheckpoint -State $script:RunState

Write-Rule "Codex Review-Loop"
Write-KeyValue "Repository" $RepoPath
Write-KeyValue "Branch" $currentBranch
Write-KeyValue "Review-Base" $reviewBase
Write-KeyValue "Repo-LogRoot" $repoLogRoot
Write-KeyValue "Logs" $LogRoot
Write-KeyValue "Ziel" "$PassesRequired saubere Reviews oder Läufe ohne Commit, maximal $MaxIterations Iterationen"
Write-KeyValue "Codex-Modell" $Model
Write-KeyValue "Reviewer-Thinking" $ReviewThinking
Write-KeyValue "Fixer-Thinking" $FixerThinking
Write-KeyValue "Geschwindigkeit" $Speed
Write-KeyValue "Farben" "$ColorMode (Hostfarben $(if ($script:UseHostColor) { 'aktiv' } else { 'aus' }), ANSI $(if ($script:UseAnsiColor) { 'aktiv' } else { 'aus' }))"
Write-KeyValue "Review-Ergebnismodus" $ReviewResultMode
if ($ReviewResultMode -eq "Legacy") {
    if ($DisableModelReviewClassifier) {
        Write-KeyValue "Legacy-Klassifizierung" "lokal, Modell-Fallback deaktiviert"
    } else {
        Write-KeyValue "Legacy-Klassifizierung" "lokal mit Modell-Fallback ($ReviewClassifierModel)"
        Write-KeyValue "Legacy-Wartebudget" "$ReviewClassifierMaxRateLimitWaitSeconds Sekunden"
    }
} elseif ($ReviewResultMode -eq "Dual") {
    Write-KeyValue "Legacy-Klassifizierung" "nur Shadow; strukturierte Ausgabe ist autoritativ"
} else {
    Write-KeyValue "Legacy-Klassifizierung" "nur Recovery alter Sessions"
}
Write-KeyValue "Architekturmodus" $ArchitectureMode
Write-KeyValue "Architektur-Trigger" "repeat_path=$ArchitectureRepeatThreshold; hotspot_fallback=$ArchitectureHotspotFixThreshold"
Write-KeyValue "Architektur-Modell" $ArchitectureModel
Write-KeyValue "Architektur-Thinking" $ArchitectureThinking
Write-KeyValue "Architektur-Fixer-Thinking" $ArchitectureFixerThinking
Write-KeyValue "Globale Auto-Anwendung" $(if ($architectureAutoApplyAllEnabled) { "aktiv (alle validierten Strategien)" } else { "aus" })
Write-KeyValue "Lokale Auto-Anwendung" $(if ($architectureAutoApplyLocalEnabled) { "aktiv (Standardpolicy für kleine lokale Strategien)" } else { "aus" })
Write-KeyValue "Interaktives Architektur-Gate" $(if ($interactiveArchitectureGate) { "aktiv" } else { "aus" })
Write-KeyValue "Aktives Architektur-Epoch" $activeEpochId
if (
    $ReviewResultMode -ne "Legacy" -and
    @("ReviewClassifierModel", "ReviewClassifierMaxRateLimitWaitSeconds", "DisableModelReviewClassifier" | Where-Object {
        $script:InvocationBoundParameters.ContainsKey($_)
    }).Count -gt 0
) {
    Write-Status "Deprecated Klassifiziererparameter sind außerhalb von ReviewResultMode=Legacy nicht autoritativ; Dual verwendet nur den lokalen Shadow." -Kind "Warning"
}
if ($fixerThreadId) {
    Write-KeyValue "Fixer-Session" $fixerThreadId
}
Write-KeyValue "Fixer-Recovery" "aktiv (max. 1 frischer Retry bei rettbaren Fixer-Fehlern)"
if ($DisableLastUnfixedReviewRecovery) {
    Write-KeyValue "Letztes ungefixtes Review" "Auto-Recovery deaktiviert"
} else {
    Write-KeyValue "Letztes ungefixtes Review" "Auto-Recovery aktiv"
}
if ($UseCodexSandbox) {
    Write-KeyValue "Codex-Sandbox" "aktiviert"
} else {
    Write-KeyValue "Codex-Sandbox" "aus (Default)"
}
if ($DisableRestartGuard) {
    Write-KeyValue "Neustartschutz" "deaktiviert"
} else {
    Write-KeyValue "Neustartschutz" "aktiv"
    foreach ($guardMessage in $script:RestartGuard.Messages) {
        Write-Status $guardMessage -Kind "Info"
    }
}
Write-Rule

if ($architectureWorktreeRecovery) {
    Write-Status "Unterbrochener Architekturfix erkannt; die vorhandenen Änderungen liegen vollständig im deklarierten Pfad-Scope." -Kind "Warning"
}

if (
    Resolve-StalePendingArchitecture `
        -ArchitectureRecord $pendingArchitecture `
        -CurrentHead $currentHead `
        -GitStatus $gitStatus `
        -ArchitectureRuns $architectureRuns
) {
    Write-Status "Ausstehender Architekturbericht gehört zu einem früheren Git-HEAD und wird durch einen frischen Review-Lauf ersetzt." -Kind "Warning"
    $activeEpochId = [guid]::NewGuid().ToString("N")
    $fixerThreadId = $null
    $pendingArchitecture = $null
    $skipLastUnfixedReviewRecoveryForRun = $true
    $script:RunState.activeEpochId = $activeEpochId
    $script:RunState.fixerThreadId = $null
    $script:RunState.normalFixerThreadId = $null
    $script:RunState.pendingArchitecture = $null
    Save-ReviewLoopCheckpoint -State $script:RunState
}

if ($null -ne $pendingArchitecture) {
    Write-Rule "Ausstehendes Architektur-Gate" "Step"
    if ($ArchitectureMode -ne "Enforce") {
        Write-Status "Ein bestehendes Enforce-Gate bleibt unabhängig vom aktuell gewählten Architekturmodus verbindlich." -Kind "Warning"
    }
    $isV1PendingArchitecture = [string]$pendingArchitecture.schemaVersion -eq "codex_review_architecture_record_v1"
    $currentLedgerDigest = Get-ArchitectureContextDigest `
        -ReviewLedger $reviewLedger.ToArray() `
        -FixCommitRecords $fixCommitRecords.ToArray() `
        -EpochId $activeEpochId
    $contextDigestForPending = if ($isV1PendingArchitecture) { $loadedLegacyContextDigest } else { $currentLedgerDigest }
    try {
        Assert-ArchitecturePendingContext `
            -ArchitectureRecord $pendingArchitecture `
            -RepoPath $RepoPath `
            -Branch $currentBranch `
            -ReviewBase $reviewBase `
            -EpochId $activeEpochId `
            -Head $currentHead `
            -LedgerDigest $contextDigestForPending
    } catch {
        Write-FatalMessage $_.Exception.Message 8
    }

    if ($isV1PendingArchitecture) {
        if ([string]$pendingArchitecture.status -eq "fixing") {
            Write-FatalMessage "Unterbrochener v1-Architekturfix kann nicht sicher migriert werden; nur ein noch offenes Gate darf als v2 neu analysiert werden." 8
        }
        try {
            $migrationTrigger = Get-PendingV1MigrationTrigger `
                -ArchitectureRecord $pendingArchitecture `
                -ReviewLedger $reviewLedger.ToArray() `
                -FixCommitRecords $fixCommitRecords.ToArray() `
                -RepeatThreshold $ArchitectureRepeatThreshold `
                -HotspotFixThreshold $ArchitectureHotspotFixThreshold
        } catch {
            Write-FatalMessage $_.Exception.Message 8
        }

        $supersededArchitecture = $pendingArchitecture
        $supersededArchitecture.status = "superseded"
        $supersededArchitecture | Add-Member -NotePropertyName supersededAt -NotePropertyValue (Get-Date).ToString("o") -Force
        Set-ArchitectureRunLedgerEntry -Ledger $architectureRuns -Record $supersededArchitecture
        $migrationLabel = "{0}-migration-v2" -f ([string]$supersededArchitecture.iterationLabel)
        Write-Status "Offenes v1-Gate wird aus exakt passendem Trigger- und Reviewkontext als v2 neu analysiert." -Kind "Warning"
        $migrationAnalysis = Invoke-ArchitectureAnalysisWithRetry `
            -RepoPath $RepoPath `
            -Branch $currentBranch `
            -ReviewBase $reviewBase `
            -EpochId $activeEpochId `
            -IterationLabel $migrationLabel `
            -LogRoot $LogRoot `
            -SchemaPath $schemaPaths.Architecture `
            -Model $ArchitectureModel `
            -Thinking $ArchitectureThinking `
            -Speed $Speed `
            -Trigger $migrationTrigger `
            -CurrentReviewRecord $supersededArchitecture.currentReviewRecord `
            -ReviewLedger $reviewLedger.ToArray() `
            -FixCommitRecords $fixCommitRecords.ToArray() `
            -IgnoredPaths $ignoredCommitPaths
        if (-not $migrationAnalysis.Succeeded) {
            Write-FatalMessage "v1-Architektur-Gate konnte nicht als v2 neu analysiert werden: $($migrationAnalysis.ErrorMessage)" $migrationAnalysis.ExitCode
        }
        $pendingArchitecture = $migrationAnalysis.Record
        $pendingArchitecture | Add-Member -NotePropertyName iterationLabel -NotePropertyValue $migrationLabel -Force
        $pendingArchitecture | Add-Member -NotePropertyName currentReviewRecord -NotePropertyValue $supersededArchitecture.currentReviewRecord -Force
        $pendingArchitecture.status = "pending"
        Set-ArchitectureRunLedgerEntry -Ledger $architectureRuns -Record $pendingArchitecture
        $script:RunState.pendingArchitecture = $pendingArchitecture
        Save-ReviewLoopCheckpoint -State $script:RunState
    } elseif ([string]$pendingArchitecture.schemaVersion -ne "codex_review_architecture_record_v2") {
        Write-FatalMessage "Ausstehender Architekturbericht verwendet einen unbekannten Vertragsstand und kann nicht migriert werden." 8
    }

    try {
        $pendingValidated = Read-ValidatedArchitectureResult `
            -ResultPath ([string]$pendingArchitecture.resultPath) `
            -SchemaPath $schemaPaths.Architecture `
            -RepoPath $RepoPath `
            -ReviewBase $reviewBase
    } catch {
        Write-FatalMessage "Ausstehender Architekturbericht ist nicht mehr gültig: $($_.Exception.Message)" 8
    }
    if (-not [string]::Equals($pendingValidated.Sha256, [string]$pendingArchitecture.reportSha256, [StringComparison]::OrdinalIgnoreCase)) {
        Write-FatalMessage "Ausstehender Architekturbericht wurde seit der Gate-Erstellung verändert." 8
    }
    Write-ArchitectureReportBlock `
        -Title "ARCHITEKTURBERICHT $([string]$pendingArchitecture.iterationLabel)" `
        -Report $pendingValidated.Report

    try {
        $gateResolution = Resolve-ArchitectureGateDecision `
            -RepoPath $RepoPath `
            -ValidatedArchitecture $pendingValidated `
            -ArchitectureRecord $pendingArchitecture `
            -AutoApplyAll $architectureAutoApplyAllEnabled `
            -AutoApplyLocal $architectureAutoApplyLocalEnabled `
            -DecisionPath $ArchitectureDecisionPath `
            -DecisionSchemaPath $schemaPaths.Decision `
            -DecisionLedger $architectureDecisions `
            -Interactive $interactiveArchitectureGate
    } catch {
        Write-FatalMessage "Architekturentscheidung ist ungültig oder stale: $($_.Exception.Message)" 8
    }
    $gateAction = [string]$gateResolution.Action
    $pendingDecision = $gateResolution.Decision
    $gateDecisionSource = [string]$gateResolution.DecisionSource
    $gateReason = [string]$gateResolution.GateReason
    if ($gateResolution.RequiresHumanDecision) {
        $script:RunState.status = "architecture_gate_pending"
        $script:RunState.completionReason = "architecture_decision_required"
        $script:RunState.exitCode = 7
        $script:RunState.pendingArchitecture = $pendingArchitecture
        Save-ReviewLoopCheckpoint -State $script:RunState
        Write-Status `
            (Get-ArchitecturePendingGateMessage -Reason $gateReason -ResultPath ([string]$pendingArchitecture.resultPath)) `
            -Kind "Warning"
        Stop-RestartGuard -Guard $script:RestartGuard
        exit 7
    }

    while ($gateAction -ne "approve_strategy") {
        $nonApprovalResult = Invoke-ArchitectureGateNonApprovalAction `
            -Action $gateAction `
            -Decision $pendingDecision `
            -ArchitectureRecord $pendingArchitecture `
            -RepoPath $RepoPath `
            -Branch $currentBranch `
            -ReviewBase $reviewBase `
            -EpochId $activeEpochId `
            -LogRoot $LogRoot `
            -SchemaPath $schemaPaths.Architecture `
            -Model $ArchitectureModel `
            -Thinking $ArchitectureThinking `
            -Speed $Speed `
            -ReviewLedger $reviewLedger.ToArray() `
            -FixCommitRecords $fixCommitRecords.ToArray() `
            -IgnoredPaths $ignoredCommitPaths `
            -ArchitectureRuns $architectureRuns `
            -ArchitectureDecisions $architectureDecisions `
            -DecisionSchemaPath $schemaPaths.Decision `
            -InteractiveGate $interactiveArchitectureGate `
            -AutoApplyAll $architectureAutoApplyAllEnabled `
            -AutoApplyLocal $architectureAutoApplyLocalEnabled
        if ($null -ne $nonApprovalResult.WaiverRemaining) {
            $architectureWaiverRemaining = [int]$nonApprovalResult.WaiverRemaining
            $pendingArchitecture = $null
            break
        }
        if ([string]::IsNullOrWhiteSpace([string]$nonApprovalResult.NextAction)) {
            break
        }
        $pendingArchitecture = $nonApprovalResult.ArchitectureRecord
        $pendingValidated = $nonApprovalResult.ValidatedArchitecture
        $gateAction = [string]$nonApprovalResult.NextAction
        $pendingDecision = $nonApprovalResult.Decision
        $gateDecisionSource = [string]$nonApprovalResult.DecisionSource
        $gateReason = [string]$nonApprovalResult.GateReason
    }
    if ($gateAction -eq "approve_strategy") {
        if ($null -eq $pendingArchitecture.currentReviewRecord) {
            Write-FatalMessage "Ausstehendem Architekturbericht fehlt das auslösende Review-Record." 8
        }
        Write-ArchitectureGateApprovalStatus -DecisionSource $gateDecisionSource
        $script:RunState.status = "architecture_fixing"
        $script:RunState.completionReason = ""
        $script:RunState.exitCode = $null
        $pendingArchitecture.status = "fixing"
        Set-ArchitectureRunLedgerEntry -Ledger $architectureRuns -Record $pendingArchitecture
        $script:RunState.pendingArchitecture = $pendingArchitecture
        Save-ReviewLoopCheckpoint -State $script:RunState
        $architectureFix = Invoke-ApprovedArchitectureFix `
                -RepoPath $RepoPath `
                -IterationLabel ([string]$pendingArchitecture.iterationLabel) `
                -LogRoot $LogRoot `
                -FixPromptPrefix $FixPromptPrefix `
                -ArchitectureReport $pendingValidated.Report `
                -ArchitectureRecord $pendingArchitecture `
                -CurrentReviewRecord $pendingArchitecture.currentReviewRecord `
                -Model $ArchitectureModel `
                -Thinking $ArchitectureFixerThinking `
                -Speed $Speed `
                -CommitMessageFallback $CommitMessageFallback `
                -IgnoredPaths $ignoredCommitPaths
            if (-not [string]::IsNullOrWhiteSpace([string]$architectureFix.FixerThreadId)) {
                $architectureFixerThreadIds.Add([string]$architectureFix.FixerThreadId) | Out-Null
            }
            if (-not $architectureFix.Succeeded) {
                Save-ReviewLoopCheckpoint -State $script:RunState
                Write-FatalMessage $architectureFix.ErrorMessage $architectureFix.ExitCode
            }
            $fixCommits.Add([string]$architectureFix.CommitRecord.CommitSha) | Out-Null
            $pendingArchitecture.currentReviewRecord.fixCommit = $architectureFix.CommitRecord.CommitSha
            $pendingArchitecture.currentReviewRecord.fixMode = "architecture"
            $pendingReviewRecordPath = [string]$pendingArchitecture.currentReviewRecord.recordPath
            if (
                [string]::IsNullOrWhiteSpace($pendingReviewRecordPath) -and
                -not [string]::IsNullOrWhiteSpace([string]$pendingArchitecture.currentReviewRecord.resultPath)
            ) {
                $pendingReviewRecordPath = Join-Path `
                    (Split-Path -Parent ([string]$pendingArchitecture.currentReviewRecord.resultPath)) `
                    ((Split-Path -Leaf ([string]$pendingArchitecture.currentReviewRecord.resultPath)) -replace "\.result\.json$", ".record.json")
            }
            if (-not [string]::IsNullOrWhiteSpace($pendingReviewRecordPath)) {
                Write-AtomicUtf8TextFile `
                    -Path $pendingReviewRecordPath `
                    -Text ($pendingArchitecture.currentReviewRecord | ConvertTo-Json -Depth 20)
            }
            $pendingArchitecture.status = "implemented"
            $pendingArchitecture | Add-Member `
                -NotePropertyName commit `
                -NotePropertyValue $architectureFix.CommitRecord.CommitSha `
                -Force
            Set-ArchitectureRunLedgerEntry -Ledger $architectureRuns -Record $pendingArchitecture
            $activeEpochId = [guid]::NewGuid().ToString("N")
            $fixerThreadId = $null
            $pendingArchitecture = $null
            $skipLastUnfixedReviewRecoveryForRun = $true
            $script:RunState.activeEpochId = $activeEpochId
            $script:RunState.fixerThreadId = $null
            $script:RunState.normalFixerThreadId = $null
            $script:RunState.pendingArchitecture = $null
            $script:RunState.lastHead = Get-CurrentGitHead -RepoPath $RepoPath
            $script:RunState.status = "running"
            $script:RunState.completionReason = ""
            $script:RunState.exitCode = $null
            Save-ReviewLoopCheckpoint -State $script:RunState
            Write-Status "Architekturcommit erstellt; neues Epoch $activeEpochId beginnt." -Kind "Success"
    }
}

if (-not $DisableLastUnfixedReviewRecovery -and -not $skipLastUnfixedReviewRecoveryForRun) {
    $lastUnfixedReview = Find-LastUnfixedReview `
        -RepoLogRoot $repoLogRoot `
        -CurrentLogRoot $LogRoot `
        -RepoPath $RepoPath `
        -Branch $currentBranch `
        -ReviewBase $reviewBase `
        -CurrentHead (Get-CurrentGitHead -RepoPath $RepoPath)
    if ($null -ne $lastUnfixedReview) {
        $recoveryLabel = "recovered-$($lastUnfixedReview.SessionName)-$($lastUnfixedReview.ReviewLabel)"
        $recoveryLogStem = Get-FixAttemptLogStem -LogRoot $LogRoot -IterationLabel $recoveryLabel -RetryIndex 0

        Write-Rule "Letztes ungefixtes Review" "Step"
        Write-Status "Gefundenes Review passt exakt zu Repository, Branch, Review-Base und HEAD-Commit und wird vor der ersten neuen Review-Iteration gefixt." -Kind "Warning"
        Write-KeyValue "Quelle" $lastUnfixedReview.SessionPath
        Write-KeyValue "Review" $lastUnfixedReview.ReviewTextPath
        Write-KeyValue "Ziel-Fix-Log" "$recoveryLogStem.txt"
        if ([string]::IsNullOrWhiteSpace($fixerThreadId) -and -not [string]::IsNullOrWhiteSpace($lastUnfixedReview.RecoveredFixerThreadId)) {
            $fixerThreadId = $lastUnfixedReview.RecoveredFixerThreadId
            Write-KeyValue "Übernommene Fixer-Session" $fixerThreadId
        } elseif (-not [string]::IsNullOrWhiteSpace($fixerThreadId)) {
            Write-KeyValue "Fixer-Session" $fixerThreadId
        }
        Write-ReviewBlock "GERETTETES REVIEW $($lastUnfixedReview.SessionName)/$($lastUnfixedReview.ReviewLabel)" $lastUnfixedReview.ReviewText

        if ($null -ne $lastUnfixedReview.StructuredRecord) {
            $fixPrompt = New-StructuredReviewFixPrompt `
                -FixPromptPrefix $FixPromptPrefix `
                -ReviewBase $reviewBase `
                -StructuredReview $lastUnfixedReview.StructuredRecord
        } else {
            $script:RunState.legacyClassificationUsed = $true
            $fixPrompt = New-ReviewFixPrompt `
                -FixPromptPrefix $FixPromptPrefix `
                -ReviewBase $reviewBase `
                -ReviewText $lastUnfixedReview.ReviewText
        }

        $fixRun = Invoke-FixerWithRecovery `
            -RepoPath $RepoPath `
            -IterationLabel $recoveryLabel `
            -LogRoot $LogRoot `
            -FixPrompt $fixPrompt `
            -FixerThreadId $fixerThreadId `
            -Model $Model `
            -Thinking $FixerThinking `
            -Speed $Speed `
            -IgnoredPaths $ignoredCommitPaths

        if (-not $fixRun.Succeeded) {
            Write-FatalMessage $fixRun.ErrorMessage $fixRun.ExitCode
        }

        $fixResult = $fixRun.Result
        Write-TextBlock "FIXER-ANTWORT $recoveryLabel" $fixResult.Text -Kind "Fixer"

        if ($fixRun.FixerThreadId -and $fixRun.FixerThreadId -ne $fixerThreadId) {
            $fixerThreadId = $fixRun.FixerThreadId
            Write-KeyValue "Fixer-Thread" $fixerThreadId
        }

        $commitRecord = Save-FixChange `
            -RepoPath $RepoPath `
            -IterationLabel $recoveryLabel `
            -ReviewLogPath $lastUnfixedReview.ReviewTextPath `
            -FixSummary $fixResult.Text `
            -CommitMessageFallback $CommitMessageFallback `
            -IgnoredPaths $ignoredCommitPaths `
            -Mode "recovery"
        $commitSha = if ($null -ne $commitRecord) { $commitRecord.CommitSha } else { $null }

        $recoverySummary = [PSCustomObject]@{
            sourceSession = $lastUnfixedReview.SessionName
            reviewLabel = $lastUnfixedReview.ReviewLabel
            reviewLogPath = $lastUnfixedReview.ReviewTextPath
            fixLogPath = "$recoveryLogStem.txt"
            recoveredFixerThreadId = $lastUnfixedReview.RecoveredFixerThreadId
            commit = $commitSha
        }
        $recoveredReviews.Add($recoverySummary) | Out-Null

        if ($commitSha) {
            $fixCommits.Add($commitSha) | Out-Null
            if ($null -ne $lastUnfixedReview.StructuredRecord) {
                $lastUnfixedReview.StructuredRecord.fixCommit = $commitSha
                $lastUnfixedReview.StructuredRecord.fixMode = "recovery"
                $sourceRecordPath = Join-Path `
                    $lastUnfixedReview.SessionPath `
                    ("review-{0}.record.json" -f $lastUnfixedReview.ReviewLabel)
                Write-AtomicUtf8TextFile `
                    -Path $sourceRecordPath `
                    -Text ($lastUnfixedReview.StructuredRecord | ConvertTo-Json -Depth 20)
                $matchingLedgerReview = @($reviewLedger | Where-Object {
                    $_.reviewId -eq $lastUnfixedReview.StructuredRecord.reviewId
                } | Select-Object -First 1)
                if ($matchingLedgerReview.Count -gt 0) {
                    $matchingLedgerReview[0].fixCommit = $commitSha
                    $matchingLedgerReview[0].fixMode = "recovery"
                }
            }
            $fixCommitRecords.Add([PSCustomObject]@{
                commitSha = $commitSha
                gitPaths = @($commitRecord.GitPaths)
                mode = "recovery"
                epochId = $activeEpochId
                reviewId = if ($null -ne $lastUnfixedReview.StructuredRecord) { [string]$lastUnfixedReview.StructuredRecord.reviewId } else { "legacy:$($lastUnfixedReview.SessionName):$($lastUnfixedReview.ReviewLabel)" }
                createdAt = (Get-Date).ToString("o")
            }) | Out-Null
            Write-Status "Gerettetes Review wurde committed; normale Review-Iteration 01 startet danach." -Kind "Success"
        } else {
            Write-Status "Gerettetes Review erzeugte keinen Commit; normale Review-Iteration 01 startet trotzdem." -Kind "Warning"
        }
        if ($architectureWaiverRemaining -gt 0) {
            $architectureWaiverRemaining--
            $script:RunState.architectureWaiverRemaining = $architectureWaiverRemaining
        }
        $script:RunState.fixerThreadId = $fixerThreadId
        $script:RunState.normalFixerThreadId = $fixerThreadId
        $script:RunState.lastHead = Get-CurrentGitHead -RepoPath $RepoPath
        Save-ReviewLoopCheckpoint -State $script:RunState
    } else {
        Write-Status "Kein ungefixtes Review mit exakt passendem Repository-, Branch-, Review-Base- und Commit-Kontext gefunden." -Kind "Info"
    }
}

while (
    $iteration -lt $MaxIterations -and
    $cleanPasses -lt $PassesRequired -and
    $noCommitPasses -lt $PassesRequired
) {
    $iteration++
    $iterationLabel = "{0:D2}" -f $iteration

    Write-Rule "Iteration ${iterationLabel}" "Step"
    Write-Status "Review startet." -Kind "Progress"

    $script:RunState.iterations = $iteration
    $script:RunState.status = "reviewing"
    $script:RunState.lastHead = Get-CurrentGitHead -RepoPath $RepoPath
    Save-ReviewLoopCheckpoint -State $script:RunState

    $structuredReview = $null
    $currentReviewRecord = $null
    $currentReviewRecordPath = ""
    $reviewTextPath = Join-Path $LogRoot "review-$iterationLabel.txt"
    if ($ReviewResultMode -eq "Legacy") {
        $reviewArgs = Get-CodexExecArgumentList -RepoPath $RepoPath -Sandbox "read-only"
        $reviewArgs = Add-CodexRunOptionArguments -Arguments $reviewArgs -Model $Model -Thinking $ReviewThinking -Speed $Speed
        $reviewArgs = Add-CodexDeveloperInstructionsArgument -Arguments $reviewArgs -Instructions $ReviewPrompt
        $reviewArgs += @("review", "--base", $reviewBase)
        $reviewResult = Invoke-CodexReviewerJson `
            -RepoPath $RepoPath `
            -Arguments $reviewArgs `
            -JsonlPath (Join-Path $LogRoot "review-$iterationLabel.jsonl") `
            -TextPath $reviewTextPath
        if ($reviewResult.ExitCode -ne 0) {
            Write-FatalMessage (New-CodexFailureMessage -Actor "Reviewer" -Result $reviewResult) $reviewResult.ExitCode
        }
        $classificationPath = Join-Path $LogRoot "review-$iterationLabel.classification.json"
        $reviewClassification = Get-ReviewClassification `
            -ReviewText $reviewResult.Text `
            -Model $ReviewClassifierModel `
            -ClassificationPath $classificationPath `
            -MaxRateLimitWaitSeconds $ReviewClassifierMaxRateLimitWaitSeconds `
            -DisableModelClassifier:$DisableModelReviewClassifier
        $reviewText = $reviewResult.Text
        $script:RunState.legacyClassificationUsed = $true
    } else {
        $structuredRun = Invoke-StructuredReviewWithRetry `
            -RepoPath $RepoPath `
            -Branch $currentBranch `
            -ReviewBase $reviewBase `
            -IterationLabel $iterationLabel `
            -EpochId $activeEpochId `
            -LogRoot $LogRoot `
            -SchemaPath $schemaPaths.Review `
            -Model $Model `
            -Thinking $ReviewThinking `
            -Speed $Speed `
            -CustomPrompt $ReviewPrompt
        if (-not $structuredRun.Succeeded) {
            Write-FatalMessage $structuredRun.ErrorMessage $structuredRun.ExitCode
        }
        $structuredReview = $structuredRun.StructuredReview
        $currentReviewRecord = $structuredRun.Record
        $currentReviewRecordPath = $structuredRun.RecordPath
        $reviewTextPath = $structuredRun.TextPath
        $reviewText = $structuredRun.Text
        $reviewLedger.Add($currentReviewRecord) | Out-Null
        $reviewClassification = New-ReviewClassification `
            -Classification $structuredReview.classification `
            -Source "output-schema" `
            -Reason "Codex-Review wurde durch JSON-Schema und Host-Invarianten validiert." `
            -Model $Model
        Write-ReviewClassificationLog `
            -Classification $reviewClassification `
            -Path (Join-Path $LogRoot "review-$iterationLabel.classification.json")

        if ($ReviewResultMode -eq "Dual") {
            $shadow = Get-LegacyLocalReviewClassification -ReviewText $reviewText
            $shadowRecord = [PSCustomObject]@{
                createdAt = (Get-Date).ToString("o")
                authoritative = $reviewClassification.classification
                shadow = $shadow.classification
                agrees = ($reviewClassification.classification -eq $shadow.classification)
                shadowReason = $shadow.reason
            }
            Write-AtomicUtf8TextFile `
                -Path (Join-Path $LogRoot "review-$iterationLabel.shadow-classification.json") `
                -Text ($shadowRecord | ConvertTo-Json -Depth 5)
        }
    }

    Write-ReviewBlock "REVIEW-MELDUNG ${iterationLabel}" $reviewText

    $classificationName = Get-ReviewClassificationDisplayName $reviewClassification.classification
    $classificationKind = Get-ReviewClassificationStatusKind $reviewClassification.classification
    Write-Status "Review-Auswertung: $classificationName" -Kind $classificationKind
    if ($reviewClassification.classification -eq "ambiguous" -and -not [string]::IsNullOrWhiteSpace($reviewClassification.reason)) {
        Write-Status "Grund: $($reviewClassification.reason)" -Kind "Warning"
    }

    if ($reviewClassification.classification -eq "clean") {
        $cleanPasses++
        $noCommitPasses++
        $script:RunState.cleanPasses = $cleanPasses
        $script:RunState.noCommitPasses = $noCommitPasses
        $script:RunState.status = "running"
        $script:RunState.lastHead = Get-CurrentGitHead -RepoPath $RepoPath
        Save-ReviewLoopCheckpoint -State $script:RunState
        Write-Status "Sauberer Review $cleanPasses/$PassesRequired." -Kind "Success"
        Write-Status "Ohne Commit $noCommitPasses/$PassesRequired." -Kind "Info"
        continue
    }

    if ($reviewClassification.classification -ne "finding") {
        Write-FatalMessage "Reviewer-Antwort konnte nicht eindeutig ausgewertet werden. Grund: $($reviewClassification.reason). Log: $reviewTextPath" 4
    }

    $cleanPasses = 0
    $script:RunState.cleanPasses = 0

    $architectureTrigger = $null
    if ($ArchitectureMode -ne "Off" -and $null -ne $currentReviewRecord) {
        $architectureTrigger = Get-ArchitectureTrigger `
            -CurrentReviewRecord $currentReviewRecord `
            -ReviewLedger $reviewLedger.ToArray() `
            -FixCommitRecords $fixCommitRecords.ToArray() `
            -RepeatThreshold $ArchitectureRepeatThreshold `
            -HotspotFixThreshold $ArchitectureHotspotFixThreshold
    }
    if ($null -ne $architectureTrigger) {
        $currentReviewRecord.architectureTrigger = $architectureTrigger
        Write-AtomicUtf8TextFile -Path $currentReviewRecordPath -Text ($currentReviewRecord | ConvertTo-Json -Depth 20)
        $triggerAlreadyRecorded = @($architectureTriggers | Where-Object {
            $_.epochId -eq $architectureTrigger.epochId -and
            (@($_.reviewIds) -join "|") -eq (@($architectureTrigger.reviewIds) -join "|") -and
            (@($_.triggerTypes) -join "|") -eq (@($architectureTrigger.triggerTypes) -join "|")
        }).Count -gt 0
        if (-not $triggerAlreadyRecorded) {
            $architectureTriggers.Add($architectureTrigger) | Out-Null
        }
        Save-ReviewLoopCheckpoint -State $script:RunState
    }

    $architectureHandled = $false
    if ($null -ne $architectureTrigger -and $architectureWaiverRemaining -le 0) {
        Write-Status "Architektur-Trigger: $($architectureTrigger.triggerTypes -join ', ')" -Kind "Warning"
        $script:RunState.status = "architecture_analysis"
        Save-ReviewLoopCheckpoint -State $script:RunState
        $architectureAnalysis = Invoke-ArchitectureAnalysisWithRetry `
            -RepoPath $RepoPath `
            -Branch $currentBranch `
            -ReviewBase $reviewBase `
            -EpochId $activeEpochId `
            -IterationLabel $iterationLabel `
            -LogRoot $LogRoot `
            -SchemaPath $schemaPaths.Architecture `
            -Model $ArchitectureModel `
            -Thinking $ArchitectureThinking `
            -Speed $Speed `
            -Trigger $architectureTrigger `
            -CurrentReviewRecord $currentReviewRecord `
            -ReviewLedger $reviewLedger.ToArray() `
            -FixCommitRecords $fixCommitRecords.ToArray() `
            -IgnoredPaths $ignoredCommitPaths

        if (-not $architectureAnalysis.Succeeded) {
            if ($ArchitectureMode -eq "Observe") {
                Write-Status "Architekturanalyse fehlgeschlagen; Observe setzt den Punktfix fort: $($architectureAnalysis.ErrorMessage)" -Kind "Warning"
                $script:RunState.status = "running"
                Save-ReviewLoopCheckpoint -State $script:RunState
            } else {
                Write-FatalMessage $architectureAnalysis.ErrorMessage $architectureAnalysis.ExitCode
            }
        } else {
            $architectureRecord = $architectureAnalysis.Record
            $architectureRecord | Add-Member -NotePropertyName iterationLabel -NotePropertyValue $iterationLabel -Force
            $architectureRecord | Add-Member -NotePropertyName currentReviewRecord -NotePropertyValue $currentReviewRecord -Force
            Write-ArchitectureReportBlock `
                -Title "ARCHITEKTURBERICHT ${iterationLabel}" `
                -Report $architectureAnalysis.Architecture.Report

            if ($ArchitectureMode -eq "Observe") {
                $architectureRecord.status = "observed"
                Set-ArchitectureRunLedgerEntry -Ledger $architectureRuns -Record $architectureRecord
                $script:RunState.status = "running"
                Save-ReviewLoopCheckpoint -State $script:RunState
                Write-Status "Observe-Modus: Architekturtrigger wurde protokolliert; Punktfix wird fortgesetzt." -Kind "Warning"
            } else {
                try {
                    $gateResolution = Resolve-ArchitectureGateDecision `
                        -RepoPath $RepoPath `
                        -ValidatedArchitecture $architectureAnalysis.Architecture `
                        -ArchitectureRecord $architectureRecord `
                        -AutoApplyAll $architectureAutoApplyAllEnabled `
                        -AutoApplyLocal $architectureAutoApplyLocalEnabled `
                        -DecisionPath $ArchitectureDecisionPath `
                        -DecisionSchemaPath $schemaPaths.Decision `
                        -DecisionLedger $architectureDecisions `
                        -Interactive $interactiveArchitectureGate
                } catch {
                    Write-FatalMessage "Architekturentscheidung ist ungültig oder stale: $($_.Exception.Message)" 8
                }
                $gateAction = [string]$gateResolution.Action
                $decision = $gateResolution.Decision
                $gateDecisionSource = [string]$gateResolution.DecisionSource
                $gateReason = [string]$gateResolution.GateReason
                if ($gateResolution.RequiresHumanDecision) {
                    $architectureRecord.status = "pending"
                    $pendingArchitecture = $architectureRecord
                    Set-ArchitectureRunLedgerEntry -Ledger $architectureRuns -Record $architectureRecord
                    $script:RunState.pendingArchitecture = $pendingArchitecture
                    $script:RunState.status = "architecture_gate_pending"
                    $script:RunState.completionReason = "architecture_decision_required"
                    $script:RunState.exitCode = 7
                    Save-ReviewLoopCheckpoint -State $script:RunState
                    Write-Status `
                        (Get-ArchitecturePendingGateMessage -Reason $gateReason -ResultPath ([string]$architectureRecord.resultPath)) `
                        -Kind "Warning"
                    Stop-RestartGuard -Guard $script:RestartGuard
                    exit 7
                }

                $effectiveArchitecture = $architectureAnalysis.Architecture
                while ($gateAction -ne "approve_strategy") {
                    $nonApprovalResult = Invoke-ArchitectureGateNonApprovalAction `
                        -Action $gateAction `
                        -Decision $decision `
                        -ArchitectureRecord $architectureRecord `
                        -RepoPath $RepoPath `
                        -Branch $currentBranch `
                        -ReviewBase $reviewBase `
                        -EpochId $activeEpochId `
                        -LogRoot $LogRoot `
                        -SchemaPath $schemaPaths.Architecture `
                        -Model $ArchitectureModel `
                        -Thinking $ArchitectureThinking `
                        -Speed $Speed `
                        -ReviewLedger $reviewLedger.ToArray() `
                        -FixCommitRecords $fixCommitRecords.ToArray() `
                        -IgnoredPaths $ignoredCommitPaths `
                        -ArchitectureRuns $architectureRuns `
                        -ArchitectureDecisions $architectureDecisions `
                        -DecisionSchemaPath $schemaPaths.Decision `
                        -InteractiveGate $interactiveArchitectureGate `
                        -AutoApplyAll $architectureAutoApplyAllEnabled `
                        -AutoApplyLocal $architectureAutoApplyLocalEnabled
                    if ($null -ne $nonApprovalResult.WaiverRemaining) {
                        $architectureWaiverRemaining = [int]$nonApprovalResult.WaiverRemaining
                        break
                    }
                    if ([string]::IsNullOrWhiteSpace([string]$nonApprovalResult.NextAction)) {
                        break
                    }
                    $architectureRecord = $nonApprovalResult.ArchitectureRecord
                    $effectiveArchitecture = $nonApprovalResult.ValidatedArchitecture
                    $gateAction = [string]$nonApprovalResult.NextAction
                    $decision = $nonApprovalResult.Decision
                    $gateDecisionSource = [string]$nonApprovalResult.DecisionSource
                    $gateReason = [string]$nonApprovalResult.GateReason
                }
                if ($gateAction -eq "approve_strategy") {
                    Write-ArchitectureGateApprovalStatus -DecisionSource $gateDecisionSource
                    $script:RunState.status = "architecture_fixing"
                    $script:RunState.completionReason = ""
                    $script:RunState.exitCode = $null
                    $architectureRecord.status = "fixing"
                    $pendingArchitecture = $architectureRecord
                    Set-ArchitectureRunLedgerEntry -Ledger $architectureRuns -Record $architectureRecord
                    $script:RunState.pendingArchitecture = $pendingArchitecture
                    Save-ReviewLoopCheckpoint -State $script:RunState
                    $architectureFix = Invoke-ApprovedArchitectureFix `
                        -RepoPath $RepoPath `
                        -IterationLabel ([string]$architectureRecord.iterationLabel) `
                        -LogRoot $LogRoot `
                        -FixPromptPrefix $FixPromptPrefix `
                        -ArchitectureReport $effectiveArchitecture.Report `
                        -ArchitectureRecord $architectureRecord `
                        -CurrentReviewRecord $currentReviewRecord `
                        -Model $ArchitectureModel `
                        -Thinking $ArchitectureFixerThinking `
                        -Speed $Speed `
                        -CommitMessageFallback $CommitMessageFallback `
                        -IgnoredPaths $ignoredCommitPaths
                    if (-not [string]::IsNullOrWhiteSpace([string]$architectureFix.FixerThreadId)) {
                        $architectureFixerThreadIds.Add([string]$architectureFix.FixerThreadId) | Out-Null
                    }
                    if (-not $architectureFix.Succeeded) {
                        Save-ReviewLoopCheckpoint -State $script:RunState
                        Write-FatalMessage $architectureFix.ErrorMessage $architectureFix.ExitCode
                    }
                    $commitSha = [string]$architectureFix.CommitRecord.CommitSha
                    $fixCommits.Add($commitSha) | Out-Null
                    $currentReviewRecord.fixCommit = $commitSha
                    $currentReviewRecord.fixMode = "architecture"
                    Write-AtomicUtf8TextFile -Path $currentReviewRecordPath -Text ($currentReviewRecord | ConvertTo-Json -Depth 20)
                    $architectureRecord.status = "implemented"
                    $architectureRecord | Add-Member -NotePropertyName commit -NotePropertyValue $commitSha -Force
                    Set-ArchitectureRunLedgerEntry -Ledger $architectureRuns -Record $architectureRecord
                    $activeEpochId = [guid]::NewGuid().ToString("N")
                    $fixerThreadId = $null
                    $noCommitPasses = 0
                    $script:RunState.activeEpochId = $activeEpochId
                    $script:RunState.fixerThreadId = $null
                    $script:RunState.normalFixerThreadId = $null
                    $script:RunState.pendingArchitecture = $null
                    $script:RunState.noCommitPasses = 0
                    $script:RunState.status = "running"
                    $script:RunState.lastHead = Get-CurrentGitHead -RepoPath $RepoPath
                    Save-ReviewLoopCheckpoint -State $script:RunState
                    Write-Status "Architekturcommit $commitSha erstellt; neues Epoch $activeEpochId beginnt." -Kind "Success"
                    $architectureHandled = $true
                }
            }
        }
    } elseif ($null -ne $architectureTrigger -and $architectureWaiverRemaining -gt 0) {
        Write-Status "Architekturtrigger ist durch Human-Waiver für noch $architectureWaiverRemaining Punktfixes ausgesetzt." -Kind "Warning"
    }

    if ($architectureHandled) {
        continue
    }

    Write-Status "Review hat Funde; Fixer startet." -Kind "Warning"

    if ($null -ne $structuredReview) {
        $fixPrompt = New-StructuredReviewFixPrompt `
            -FixPromptPrefix $FixPromptPrefix `
            -ReviewBase $reviewBase `
            -StructuredReview $structuredReview
    } else {
        $fixPrompt = New-ReviewFixPrompt `
            -FixPromptPrefix $FixPromptPrefix `
            -ReviewBase $reviewBase `
            -ReviewText $reviewText
    }

    $script:RunState.status = "fix_pending"
    Save-ReviewLoopCheckpoint -State $script:RunState

    $fixRun = Invoke-FixerWithRecovery `
        -RepoPath $RepoPath `
        -IterationLabel $iterationLabel `
        -LogRoot $LogRoot `
        -FixPrompt $fixPrompt `
        -FixerThreadId $fixerThreadId `
        -Model $Model `
        -Thinking $FixerThinking `
        -Speed $Speed `
        -IgnoredPaths $ignoredCommitPaths

    if (-not $fixRun.Succeeded) {
        Write-FatalMessage $fixRun.ErrorMessage $fixRun.ExitCode
    }

    $fixResult = $fixRun.Result

    Write-TextBlock "FIXER-ANTWORT ${iterationLabel}" $fixResult.Text -Kind "Fixer"

    if ($fixRun.FixerThreadId -and $fixRun.FixerThreadId -ne $fixerThreadId) {
        $fixerThreadId = $fixRun.FixerThreadId
        Write-KeyValue "Fixer-Thread" $fixerThreadId
    }

    $commitRecord = Save-FixChange `
        -RepoPath $RepoPath `
        -IterationLabel $iterationLabel `
        -ReviewLogPath $reviewTextPath `
        -FixSummary $fixResult.Text `
        -CommitMessageFallback $CommitMessageFallback `
        -IgnoredPaths $ignoredCommitPaths `
        -Mode "normal"
    $commitSha = if ($null -ne $commitRecord) { $commitRecord.CommitSha } else { $null }

    if ($commitSha) {
        $fixCommits.Add($commitSha) | Out-Null
        if ($null -ne $currentReviewRecord) {
            $currentReviewRecord.fixCommit = $commitSha
            $currentReviewRecord.fixMode = "normal"
            Write-AtomicUtf8TextFile -Path $currentReviewRecordPath -Text ($currentReviewRecord | ConvertTo-Json -Depth 20)
            $fixCommitRecords.Add([PSCustomObject]@{
                commitSha = $commitSha
                gitPaths = @($commitRecord.GitPaths)
                mode = "normal"
                epochId = $activeEpochId
                reviewId = $currentReviewRecord.reviewId
                createdAt = (Get-Date).ToString("o")
            }) | Out-Null
        }
        $noCommitPasses = 0
    } else {
        $noCommitPasses++
        Write-Status "Ohne Commit $noCommitPasses/$PassesRequired." -Kind "Info"
    }
    if ($architectureWaiverRemaining -gt 0) {
        $architectureWaiverRemaining--
    }
    $script:RunState.architectureWaiverRemaining = $architectureWaiverRemaining
    $script:RunState.fixerThreadId = $fixerThreadId
    $script:RunState.normalFixerThreadId = $fixerThreadId
    $script:RunState.noCommitPasses = $noCommitPasses
    $script:RunState.status = "running"
    $script:RunState.lastHead = Get-CurrentGitHead -RepoPath $RepoPath
    Save-ReviewLoopCheckpoint -State $script:RunState
}

$script:RunState.fixerThreadId = $fixerThreadId
$script:RunState.normalFixerThreadId = $fixerThreadId
$script:RunState.iterations = $iteration
$script:RunState.cleanPasses = $cleanPasses
$script:RunState.noCommitPasses = $noCommitPasses
$script:RunState.lastHead = Get-CurrentGitHead -RepoPath $RepoPath
$script:RunState.completed = ($cleanPasses -ge $PassesRequired -or $noCommitPasses -ge $PassesRequired)
if ($cleanPasses -ge $PassesRequired) {
    $script:RunState.status = "completed_clean"
    $script:RunState.completionReason = "completed_clean"
    $script:RunState.exitCode = 0
} elseif ($noCommitPasses -ge $PassesRequired) {
    $script:RunState.status = "completed_no_commit"
    $script:RunState.completionReason = "completed_no_commit"
    $script:RunState.exitCode = 0
}
Save-ReviewLoopCheckpoint -State $script:RunState
$summary = $script:RunState

Write-Rule "Zusammenfassung" "Summary"
Write-KeyValue "Repository" $summary.repoPath
Write-KeyValue "Branch" $summary.branch
Write-KeyValue "Logs" $summary.logRoot
Write-KeyValue "Review-Base" $summary.reviewBase
Write-KeyValue "Codex-Modell" $summary.model
Write-KeyValue "Reviewer-Thinking" $summary.reviewThinking
Write-KeyValue "Fixer-Thinking" $summary.fixerThinking
Write-KeyValue "Geschwindigkeit" $summary.speed
Write-KeyValue "Iterationen" ([string]$summary.iterations)
Write-KeyValue "Saubere Reviews" "$($summary.cleanPasses)/$($summary.passesRequired)"
Write-KeyValue "Läufe ohne Commit" "$($summary.noCommitPasses)/$($summary.passesRequired)"
Write-KeyValue "Abgeschlossen" ([string]$summary.completed)
if ($summary.fixCommits.Count -gt 0) {
    Write-TextBlock "Fix-Commits" (($summary.fixCommits | ForEach-Object { "- $_" }) -join "`n") -Kind "Success"
}
if ($summary.recoveredReviews.Count -gt 0) {
    Write-TextBlock "Gerettete Reviews" (($summary.recoveredReviews | ForEach-Object {
        $commitText = if ($_.commit) { $_.commit } else { "kein Commit" }
        "- $($_.sourceSession)/$($_.reviewLabel) -> $commitText"
    }) -join "`n") -Kind "Success"
}

if ($cleanPasses -ge $PassesRequired) {
    Write-Status "Codex Review-Loop erfolgreich abgeschlossen." -Kind "Success"
    Stop-RestartGuard -Guard $script:RestartGuard
    exit 0
}

if ($noCommitPasses -ge $PassesRequired) {
    Write-Status "Codex Review-Loop beendet: $PassesRequired Läufe hintereinander ohne Commit." -Kind "Warning"
    Stop-RestartGuard -Guard $script:RestartGuard
    exit 0
}

Write-FatalMessage "Maximale Iterationszahl erreicht, bevor $PassesRequired saubere Review-Durchläufe oder Läufe ohne Commit erreicht wurden." 5
}

if ($MyInvocation.InvocationName -ne ".") {
    Invoke-CodexReviewLoopMain
}
