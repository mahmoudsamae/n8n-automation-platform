# Dot-sourced by scripts\wsl-sh.ps1 and scripts\server-sh.ps1: refuses a script that matches scripts\lib\destructive-patterns.json BEFORE it is encoded and sent.
# Why: the helpers send the script as base64, so no permission rule and no hook can see a DROP or a `down -v` inside a file or a variable.
# A match prints the pattern id on stderr and exits 3; nothing is sent. There is no override switch: the owner runs a truly destructive command by hand.
# A missing or broken pattern file also refuses (fail closed). These guards stop mistakes, not a determined attacker (see PLAN.md, "Safety guards").
$script:DestructivePatternsFile = Join-Path $PSScriptRoot 'destructive-patterns.json'

function Assert-NotDestructive([string]$Text) {
    try {
        $patterns = @(([IO.File]::ReadAllText($script:DestructivePatternsFile) | ConvertFrom-Json).patterns)
        if ($patterns.Count -eq 0) { throw 'no patterns' }
    } catch {
        [Console]::Error.WriteLine("destructive-guard refused: cannot read $script:DestructivePatternsFile ($($_.Exception.Message)); nothing was sent")
        exit 3
    }
    # One line at a time, as in the hook: `.` never crosses a line, so both engines agree.
    $hits = @(foreach ($p in $patterns) {
        foreach ($line in ($Text -split "`r?`n")) {
            if ([regex]::IsMatch($line, $p.regex, 'IgnoreCase')) { "$($p.id) ($($p.why))"; break }
        }
    })
    if ($hits.Count -gt 0) {
        [Console]::Error.WriteLine("destructive-guard refused: $($hits -join '; '). Nothing was sent. No override: if this is really needed, the owner runs it by hand.")
        exit 3
    }
}
