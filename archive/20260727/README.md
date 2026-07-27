# Archiv des Review Loop v2

Dieses Verzeichnis enthält den am 27.07.2026 ersetzten monolithischen
Ausführungspfad und seine Tests.

Archiviert wurden:

- `Invoke-CodexReviewLoop.ps1`
- `Invoke-CodexReviewLoop.Tests.ps1`

Vor der Archivierung bestanden die neue Pester-Suite, Fake-Codex-Integration,
CLI-only-Negativprüfung, PowerShell-Parserprüfung und die begrenzte
Standard-Speed-Qualifikation mit historischen PKonf-Fällen.

Die Dateien bleiben als schreibgeschützter historischer Nachweis erhalten. Es
gibt keinen Legacy-Shim; der aktive Einstiegspunkt ist
`C:\dev\CodexReviewLoop\codex-review-loop.ps1`.
