# Fails on doc rot that no other check sees: CLAUDE.md over its length limit, or a relative link or image in the README or docs/*.md
# that points at a file which does not exist.
# Files that are referenced but not there yet can be listed in -KnownMissing (empty today): they print as WARN and do not fail.
# The list cleans itself: once such a file exists, the check FAILS until it is removed from the list.
# Run: powershell -File scripts\check-docs.ps1 [-Root <repo>] [-MaxClaudeLines 100]   Exit 0 = ok, 1 = problem.
param(
    [string]$Root = (Split-Path -Parent $PSScriptRoot),
    [int]$MaxClaudeLines = 100,
    [string[]]$KnownMissing = @()
)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$failed = 0
# GetFullPath expands 8.3 names (MAHMUD~1) in the link targets below; use the same form of the root for the relative display.
$rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')

$claude = Join-Path $Root 'CLAUDE.md'
$lines = @([IO.File]::ReadAllLines($claude, $utf8)).Count
if ($lines -le $MaxClaudeLines) { Write-Host "[PASS] CLAUDE.md has $lines lines (limit $MaxClaudeLines)" -ForegroundColor Green }
else { Write-Host "[FAIL] CLAUDE.md has $lines lines, limit is $MaxClaudeLines" -ForegroundColor Red; $failed++ }

# Paths are built from $Root only (Get-ChildItem FullName can switch between 8.3 and long names, which breaks the relative display below).
$files = @(Join-Path $Root 'README.md') + @(Get-ChildItem -Path (Join-Path $Root 'docs') -Filter '*.md' -File | ForEach-Object { Join-Path $Root (Join-Path 'docs' $_.Name) })
$checked = 0
$missing = @{}
foreach ($f in $files) {
    $dir = Split-Path -Parent $f
    $text = [IO.File]::ReadAllText($f, $utf8)
    # [text](target) and ![alt](target); skip absolute URLs, mailto and pure anchors; drop #anchor and "title"
    foreach ($m in [regex]::Matches($text, '!?\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)')) {
        $t = $m.Groups[1].Value
        if ($t -match '^(https?:|mailto:|#)') { continue }
        $t = ($t -split '#')[0]
        if (-not $t) { continue }
        $checked++
        $full = [IO.Path]::GetFullPath((Join-Path $dir $t))
        if (-not (Test-Path -LiteralPath $full)) {
            $rel = $full.Substring($rootFull.Length + 1).Replace('\', '/')
            $missing[$rel] = $true
            if ($KnownMissing -notcontains $rel) {
                Write-Host ("[FAIL] {0} links to {1}, which does not exist" -f ([IO.Path]::GetFullPath($f).Substring($rootFull.Length + 1).Replace('\', '/')), $rel) -ForegroundColor Red
                $failed++
            }
        }
    }
}
Write-Host "checked $checked relative links in $($files.Count) files"
foreach ($k in $KnownMissing) {
    if ($missing.ContainsKey($k)) { Write-Host "[WARN] known missing, owner has to add it: $k" -ForegroundColor Yellow }
    elseif (-not (Test-Path -LiteralPath (Join-Path $Root $k))) { Write-Host "[FAIL] $k is in -KnownMissing but nothing links to it and it does not exist: remove it from the list" -ForegroundColor Red; $failed++ }
    else { Write-Host "[FAIL] $k now exists: remove it from -KnownMissing in scripts\check-docs.ps1" -ForegroundColor Red; $failed++ }
}
if ($failed -eq 0) { Write-Host '[PASS] every relative link and image resolves (known-missing files aside)' -ForegroundColor Green }
if ($failed -gt 0) { exit 1 }
exit 0
