@{
    # Anzeigename des Profils. Er bildet den Unterordner für Ledger und Runs.
    Name = "PKonf"

    # Beliebige gültige Git-Revision, z. B. origin/main, origin/master oder main.
    ReviewBase = "origin/master"

    # Verzeichnis für Ledger, Checkpoints, JSONL- und Ergebnislogs.
    LogRoot = "C:\dev\codex-review-loop-v3"

    # Zwei Clean-Passes auf unverändertem HEAD sind der empfohlene Abschluss.
    CleanPassesRequired = 2

    # Harte Grenzen gegen endlose Review-, Fix- und Architektur-Schleifen.
    MaxReviewCycles = 12
    MaxFixAttempts = 2
    MaxArchitectureRevisions = 1
    MaxArchitecturePaths = 15
    MaxProductionPaths = 8

    # $true erstellt nach Verifikation und bestandenen Host-Gates einen Commit.
    AutoCommit = $true
    CommitMessagePrefix = "Review-Loop"

    # Jedes Gate besteht aus Name, ausführbarer Datei und einer Argumentliste.
    # Weitere projektspezifische Prüfungen können als zusätzliche Hashtables folgen.
    HostGates = @(
        @{
            Name = "PKonf solution tests"
            FilePath = "dotnet"
            Arguments = @("test", ".\PKonf.sln")
        },
        @{
            Name = "Git diff check"
            FilePath = "git"
            Arguments = @("diff", "--check")
        }
    )

    # Rollenwerte:
    # - Model: eine von der installierten Codex-CLI unterstützte Modell-ID.
    # - Thinking: low, medium, high, xhigh oder max.
    # - Sandbox: read-only, workspace-write oder danger-full-access.
    # Fixer benötigen Schreibzugriff; alle beurteilenden Rollen bleiben read-only.
    Roles = @{
        Reviewer = @{ Model = "gpt-5.6-sol"; Thinking = "high"; Sandbox = "read-only" }
        Normalizer = @{ Model = "gpt-5.6-luna"; Thinking = "low"; Sandbox = "read-only" }
        TriggerJudge = @{ Model = "gpt-5.6-luna"; Thinking = "low"; Sandbox = "read-only" }
        TriggerConfirm = @{ Model = "gpt-5.6-sol"; Thinking = "low"; Sandbox = "read-only" }
        TriggerTieBreak = @{ Model = "gpt-5.6-terra"; Thinking = "medium"; Sandbox = "read-only" }
        Architect = @{ Model = "gpt-5.6-sol"; Thinking = "max"; Sandbox = "read-only" }
        ArchitectureCritic = @{ Model = "gpt-5.6-terra"; Thinking = "medium"; Sandbox = "read-only" }
        ArchitectureVeto = @{ Model = "gpt-5.6-sol"; Thinking = "medium"; Sandbox = "read-only" }
        ArchitectureTieBreak = @{ Model = "gpt-5.6-terra"; Thinking = "high"; Sandbox = "read-only" }
        PointFixer = @{ Model = "gpt-5.6-sol"; Thinking = "high"; Sandbox = "danger-full-access" }
        ArchitectureFixer = @{ Model = "gpt-5.6-sol"; Thinking = "max"; Sandbox = "danger-full-access" }
        FindingVerifier = @{ Model = "gpt-5.6-luna"; Thinking = "low"; Sandbox = "read-only" }
        VerifierConfirm = @{ Model = "gpt-5.6-sol"; Thinking = "low"; Sandbox = "read-only" }
        VerifierTieBreak = @{ Model = "gpt-5.6-terra"; Thinking = "medium"; Sandbox = "read-only" }
    }
}
