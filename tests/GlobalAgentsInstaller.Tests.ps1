$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$powerShellInstaller = Join-Path $root "install-global-agents.ps1"
$bashInstaller = Join-Path $root "install-global-agents.sh"
$rulesPath = Join-Path $root "docs\smallest-complete-work.md"
$startMarker = "<!-- codex-smallest-complete-work:start -->"
$endMarker = "<!-- codex-smallest-complete-work:end -->"
$bashPath = @(
    "C:\Program Files\Git\bin\bash.exe",
    "C:\Program Files\Git\usr\bin\bash.exe"
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if ($null -eq $bashPath -and -not $IsWindows) {
    $bashPath = (Get-Command bash -ErrorAction SilentlyContinue).Source
}

Describe "Global AGENTS.md installers" {
    BeforeEach {
        $originalCodexHome = $env:CODEX_HOME
        $codexHome = Join-Path $TestDrive (
            "custom home $([Guid]::NewGuid().ToString('N'))")
        New-Item -ItemType Directory -Path $codexHome | Out-Null
        $env:CODEX_HOME = $codexHome
    }

    AfterEach {
        $env:CODEX_HOME = $originalCodexHome
    }

    It "ships one valid English managed rules block" {
        $rules = Get-Content -Raw -LiteralPath $rulesPath
        ([regex]::Matches($rules, [regex]::Escape($startMarker))).Count |
            Should Be 1
        ([regex]::Matches($rules, [regex]::Escape($endMarker))).Count |
            Should Be 1
        $rules | Should Match "# Smallest Complete Work"
        $rules | Should Not Match "vollstaendig|massgeblich|Aenderung"
    }

    It "prepends, preserves, and idempotently refreshes with PowerShell" {
        $agentsPath = Join-Path $codexHome "AGENTS.md"
        [System.IO.File]::WriteAllText(
            $agentsPath,
            "# Existing guidance`n`n- Preserve this rule without a trailing newline.")

        & $powerShellInstaller | Out-Null

        $first = [System.IO.File]::ReadAllText($agentsPath)
        $first.StartsWith($startMarker) | Should Be $true
        $first | Should Match "# Existing guidance"
        $first | Should Match "Preserve this rule without a trailing newline\."
        ([regex]::Matches($first, [regex]::Escape($startMarker))).Count |
            Should Be 1

        & $powerShellInstaller | Out-Null
        [System.IO.File]::ReadAllText($agentsPath) | Should BeExactly $first
    }

    It "moves duplicate managed blocks to one block at the beginning" {
        $rules = Get-Content -Raw -LiteralPath $rulesPath
        $agentsPath = Join-Path $codexHome "AGENTS.md"
        $content = "# Before`n`n$rules`n# Between`n`n$rules`n# After`n"
        [System.IO.File]::WriteAllText($agentsPath, $content)

        & $powerShellInstaller | Out-Null

        $updated = [System.IO.File]::ReadAllText($agentsPath)
        $updated.StartsWith($startMarker) | Should Be $true
        ([regex]::Matches($updated, [regex]::Escape($startMarker))).Count |
            Should Be 1
        $updated | Should Match "# Before"
        $updated | Should Match "# Between"
        $updated | Should Match "# After"
    }

    It "refuses an incomplete managed block without changing the file" {
        $agentsPath = Join-Path $codexHome "AGENTS.md"
        $original = "$startMarker`n# Incomplete"
        [System.IO.File]::WriteAllText($agentsPath, $original)

        $failure = $null
        try {
            & $powerShellInstaller | Out-Null
        }
        catch {
            $failure = $_
        }
        $failure | Should Not BeNullOrEmpty
        $failure.Exception.Message | Should Match "incomplete"
        [System.IO.File]::ReadAllText($agentsPath) | Should BeExactly $original
    }

    It "warns when a global override prevents the installed rules from loading" {
        Set-Content -LiteralPath (Join-Path $codexHome "AGENTS.override.md") `
            -Value "# Temporary override"

        $messages = & $powerShellInstaller 3>&1 | Out-String

        $messages | Should Match "takes precedence"
        Test-Path -LiteralPath (Join-Path $codexHome "AGENTS.md") |
            Should Be $true
    }

    It "creates, prepends, and refreshes idempotently with Bash" `
        -Skip:($null -eq $bashPath) {
        $agentsPath = Join-Path $codexHome "AGENTS.md"
        if ($IsWindows) {
            $posixHome = (& $bashPath -lc 'cygpath -u "$1"' _ $codexHome).Trim()
            $posixInstaller = (& $bashPath -lc 'cygpath -u "$1"' _ $bashInstaller).Trim()
        }
        else {
            $posixHome = $codexHome
            $posixInstaller = $bashInstaller
        }
        $env:CODEX_HOME = $posixHome

        & $bashPath -lc 'bash "$1"' _ $posixInstaller | Out-Null
        $LASTEXITCODE | Should Be 0
        Test-Path -LiteralPath $agentsPath | Should Be $true
        [System.IO.File]::AppendAllText(
            $agentsPath, "`n# Existing Bash guidance`n")

        & $bashPath -lc 'bash "$1"' _ $posixInstaller | Out-Null
        $LASTEXITCODE | Should Be 0
        $first = [System.IO.File]::ReadAllText($agentsPath)
        & $bashPath -lc 'bash "$1"' _ $posixInstaller | Out-Null
        $LASTEXITCODE | Should Be 0

        $first.StartsWith($startMarker) | Should Be $true
        $first | Should Match "# Existing Bash guidance"
        ([regex]::Matches($first, [regex]::Escape($startMarker))).Count |
            Should Be 1
        [System.IO.File]::ReadAllText($agentsPath) | Should BeExactly $first
    }
}
