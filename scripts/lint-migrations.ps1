# Fails if any migration uses ON DELETE CASCADE (financial/legal tables must use ON DELETE RESTRICT, see CLAUDE.md Rules),
# or if a migration from 008 on creates a table without a GRANT to n8n_app.
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

# From 008 on, a migration that creates a table must grant on it to n8n_app (migration 007 set no default privileges on purpose),
# or n8n fails on the new table at runtime, which is how a forgotten grant would otherwise show up.
foreach ($f in $files) {
    if ($f.Name -notmatch '^(\d+)_' -or [int]$Matches[1] -lt 8) { continue }
    $code = (Get-Content -LiteralPath $f.FullName | ForEach-Object { $_ -replace '--.*$', '' }) -join "`n"
    if ($code -match '(?i)\bCREATE\s+TABLE\b' -and $code -notmatch '(?i)\bGRANT\b[^;]*\bTO\s+n8n_app\b') {
        Write-Host ("[FAIL] {0} creates a table but grants nothing to n8n_app (see migration 007)" -f $f.Name) -ForegroundColor Red
        $violations++
    }
}

if ($violations -gt 0) { exit 1 }
Write-Host ("[PASS] {0} migration file(s), no ON DELETE CASCADE, new tables granted to n8n_app" -f $files.Count) -ForegroundColor Green
exit 0
