<#
.SYNOPSIS
Startet die unattended Codex Review Loop v3 für ein Git-Repository.

.DESCRIPTION
Alle Modellinteraktionen laufen ausschließlich über die lokal installierte
Codex-CLI. Die Loop prüft den Branch, führt verifizierte Fixes aus und beendet
sich erst nach den im Profil konfigurierten Clean-Passes.

ConfigPath ist optional. Ohne expliziten Pfad wird in dieser Reihenfolge gesucht:
1. <RepoPath>\.codex-review-loop.psd1
2. <RepoPath>\.codex\review-loop.psd1
3. <Toolverzeichnis>\profiles\<Repositoryname>.psd1

Wird kein Profil gefunden, legt das Tool automatisch ein kommentiertes Profil
unter <Toolverzeichnis>\profiles\<Repositoryname>.psd1 an und setzt den Lauf
damit fort.

.PARAMETER RepoPath
Pfad zum Git-Repository, das geprüft und gegebenenfalls korrigiert wird.

.PARAMETER ConfigPath
Optionaler Pfad zu einer PSD1-Profildatei. Existiert der explizit angegebene
Pfad noch nicht, wird dort automatisch ein kommentiertes Profil angelegt.

.PARAMETER Speed
Globaler Service-Tier für ausnahmslos alle Rollen und Resume-Aufrufe.
Zulässige Werte sind standard und fast. Der Default ist standard.

.PARAMETER CodexPath
Optionaler Pfad zu einer bestimmten Codex-CLI. Ohne Angabe wird die installierte
Codex-CLI automatisch aufgelöst.

.PARAMETER NewRun
Startet einen neuen Run, statt den jüngsten fortsetzbaren Checkpoint zu verwenden.

.PARAMETER OutputMode
Steuert die fachliche Detailtiefe der Terminalausgabe:
compact zeigt Phasen, Entscheidungen, Findings und Fehler (Default);
balanced ergänzt interne CLI-Aktivitäten in Kurzform;
detailed ergänzt Start und Abschluss erfolgreicher interner Befehle.
Interne Reasoning-Inhalte werden in keinem Modus angezeigt.

.PARAMETER HeartbeatSeconds
Intervall für Laufzeitmeldungen bei länger laufenden Codex-Rollen und Host-Gates.
Default ist 30 Sekunden. Der Wert 0 deaktiviert Heartbeats.

.PARAMETER ColorMode
Steuert die Farbausgabe:
Host verwendet native PowerShell-Hostfarben (Default);
Ansi und Always schreiben ANSI-Farbcodes;
Auto verwendet ANSI nur in einem geeigneten interaktiven Terminal;
Never deaktiviert Farben.
Die Datei terminal.log bleibt unabhängig davon immer frei von Farbcodes.

.PARAMETER Help
Zeigt diese Hilfe an, ohne ein Profil anzulegen oder den Review-Loop zu starten.

.EXAMPLE
C:\dev\CodexReviewLoop\codex-review-loop.ps1 -RepoPath C:\dev\PKonf

Verwendet automatisch profiles\PKonf.psd1 und Standard-Speed.

.EXAMPLE
C:\dev\CodexReviewLoop\codex-review-loop.ps1 `
    -RepoPath C:\dev\Projekt `
    -ConfigPath C:\Konfigurationen\Projekt.psd1 `
    -Speed fast `
    -NewRun

Verwendet ein explizites Profil und aktiviert Fast für alle Rollen.

.EXAMPLE
C:\dev\CodexReviewLoop\codex-review-loop.ps1 C:\dev\Projekt `
    -OutputMode balanced `
    -HeartbeatSeconds 15 `
    -ColorMode Host

Zeigt zusätzlich kurze CLI-Aktivitäten und meldet alle 15 Sekunden den Fortschritt.

.EXAMPLE
C:\dev\CodexReviewLoop\codex-review-loop.ps1 -Help

Zeigt die vollständige Kommandohilfe an.

.NOTES
Ledger, Checkpoints und Rollenlogs werden unter dem im Profil angegebenen
LogRoot abgelegt. AutoCommit und HostGates werden ebenfalls vom Profil gesteuert.
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
    Write-Error "RepoPath ist erforderlich. Verwende -Help für Beispiele und Parameter."
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
