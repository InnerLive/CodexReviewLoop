#!/usr/bin/env bash
set -euo pipefail

start_marker='<!-- codex-smallest-complete-work:start -->'
end_marker='<!-- codex-smallest-complete-work:end -->'
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
rules_path="$script_dir/docs/smallest-complete-work.md"

if [[ ! -f "$rules_path" ]]; then
    printf 'The managed rules file was not found: %s\n' "$rules_path" >&2
    exit 1
fi

if ! awk -v start="$start_marker" -v end="$end_marker" '
    {
        line = $0
        sub(/\r$/, "", line)
        if (line == start) { starts++; if (inside) invalid = 1; inside = 1 }
        if (line == end) { ends++; if (!inside) invalid = 1; inside = 0 }
    }
    END { exit !(starts == 1 && ends == 1 && !inside && !invalid) }
' "$rules_path"; then
    printf '%s\n' 'The managed rules file must contain exactly one valid start marker and one valid end marker.' >&2
    exit 1
fi

if [[ -n "${CODEX_HOME:-}" ]]; then
    codex_home="$CODEX_HOME"
elif [[ -n "${HOME:-}" ]]; then
    codex_home="$HOME/.codex"
else
    printf '%s\n' "Neither CODEX_HOME nor the current user's home directory is available." >&2
    exit 1
fi

if [[ ! -d "$codex_home" ]]; then
    mkdir -p -- "$codex_home"
fi
codex_home="$(cd -- "$codex_home" && pwd -P)"
agents_path="$codex_home/AGENTS.md"
override_path="$codex_home/AGENTS.override.md"
if [[ (-e "$agents_path" || -L "$agents_path") && ! -f "$agents_path" ]]; then
    printf 'The AGENTS.md path is not a regular file: %s\n' "$agents_path" >&2
    exit 1
fi
temporary_path="$(mktemp "$codex_home/.AGENTS.md.XXXXXX")"
remaining_path="$(mktemp "$codex_home/.AGENTS.remaining.XXXXXX")"
cleanup() {
    rm -f -- "$temporary_path" "$remaining_path"
}
trap cleanup EXIT

if [[ -f "$agents_path" ]]; then
    if ! awk -v start="$start_marker" -v end="$end_marker" '
        {
            line = $0
            sub(/\r$/, "", line)
            marker_line = line
            sub(/^[[:space:]]+/, "", marker_line)
            sub(/[[:space:]]+$/, "", marker_line)
            if (marker_line == start) {
                starts++
                if (inside) invalid = 1
                inside = 1
                next
            }
            if (marker_line == end) {
                ends++
                if (!inside) invalid = 1
                inside = 0
                next
            }
            if (!inside) {
                if (!emitted && line ~ /^[[:space:]]*$/) next
                print
                emitted = 1
            }
        }
        END {
            if (inside || invalid || starts != ends) exit 2
        }
    ' "$agents_path" > "$remaining_path"; then
        printf '%s\n' 'The existing AGENTS.md contains incomplete, malformed, or nested managed rules markers.' >&2
        exit 1
    fi
    cp -p -- "$agents_path" "$temporary_path"
fi

awk '{ sub(/\r$/, ""); print }' "$rules_path" > "$temporary_path"
if [[ -s "$remaining_path" ]]; then
    printf '\n' >> "$temporary_path"
    cat "$remaining_path" >> "$temporary_path"
fi

if [[ -L "$agents_path" ]]; then
    cat "$temporary_path" > "$agents_path"
else
    mv -f -- "$temporary_path" "$agents_path"
fi

if [[ -f "$override_path" ]] && grep -q '[^[:space:]]' "$override_path"; then
    printf '%s\n' 'Warning: A non-empty global AGENTS.override.md takes precedence over AGENTS.md, so Codex will not load these rules until the override is removed or emptied.' >&2
fi

printf 'Updated %s\n' "$agents_path"
