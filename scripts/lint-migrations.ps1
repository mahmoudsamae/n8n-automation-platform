# Fails if any migration uses ON DELETE CASCADE. Financial/legal tables must use ON DELETE RESTRICT (see CLAUDE.md Rules).
# Run: powershell -File scripts\lint-migrations.ps1 [-Dir <folder>]   Exit 0 = clean, 1 = violation.
param([string]$Dir = (Join-Path $PSScriptRoot '..\migrations'))
$ErrorActionPreference = 'Stop'

$files = @(Get-ChildItem -LiteralPath $Dir -Filter '*.sql' -File)
if ($files.Count -eq 0) { Write-Host "[FAIL] no .sql files found in $Dir (wrong folder?)" -ForegroundColor Red; exit 1 }

$violations = 0
foreach ($f in $files) {
    $n = 0
    foreach ($line in Get-Content -LiteralPath $f.FullName) {
        $n++
        $code = $line -replace '--.*$', ''   # comments may mention CASCADE
        if ($code -match '(?i)\bON\s+DELETE\s+CASCADE\b') {
            Write-Host ("[FAIL] {0}:{1} uses ON DELETE CASCADE, use RESTRICT" -f $f.Name, $n) -ForegroundColor Red
            $violations++
        }
    }
}

if ($violations -gt 0) { exit 1 }
Write-Host ("[PASS] {0} migration file(s), no ON DELETE CASCADE" -f $files.Count) -ForegroundColor Green
exit 0
