# Proves scripts\wsl-sh.ps1 and scripts\server-sh.ps1 refuse destructive text before sending it (scripts\lib\destructive-guard.ps1).
# Every pattern's harmless `sample` from scripts\lib\destructive-patterns.json (an echo) goes through -Script, -File and piped input (wsl-sh only):
# each must exit 3 with no output (an echo that ran would print). A control `echo ok` must pass through every route and print ok.
# Harmless even if a guard is broken: the samples only echo. -Target server needs Tailscale; e2e runs -Target wsl.
# Run: powershell -File scripts\check-destructive-guard.ps1 [-Target wsl|server|both]   Exit 0 = ok, 1 = problem.
# Prove it can fail: -ProveFailure expects the control to be refused, so every control line must FAIL.
param(
    [ValidateSet('wsl', 'server', 'both')][string]$Target = 'wsl',
    [switch]$ProveFailure
)
$ErrorActionPreference = 'Stop'
$failed = 0
function Write-Step([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { Write-Host "[PASS] $Name" -ForegroundColor Green -NoNewline } else { Write-Host "[FAIL] $Name" -ForegroundColor Red -NoNewline; $script:failed++ }
    if ($Detail) { Write-Host " - $Detail" } else { Write-Host '' }
}

$patterns = @(([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'lib\destructive-patterns.json')) | ConvertFrom-Json).patterns)
$helpers = @()
if ($Target -in 'wsl', 'both') { $helpers += , @('wsl-sh.ps1', @('Script', 'File', 'Piped')) }
if ($Target -in 'server', 'both') { $helpers += , @('server-sh.ps1', @('Script', 'File')) }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("destructive-guard-{0}.sh" -f [Guid]::NewGuid().ToString('N'))

# Runs one text through one helper and route; returns exit code and the non-empty output lines.
function Invoke-Route([string]$Helper, [string]$Route, [string]$Text) {
    $path = Join-Path $PSScriptRoot $Helper
    $global:LASTEXITCODE = 0
    $out = switch ($Route) {
        'Script' { @(& $path -Script $Text) }
        'File' { [IO.File]::WriteAllText($tmp, $Text + "`n", (New-Object Text.UTF8Encoding($false))); @(& $path -File $tmp) }
        'Piped' { @($Text | & $path) }
    }
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = @($out | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) }
}

try {
    foreach ($h in $helpers) {
        $helper, $routes = $h
        foreach ($route in $routes) {
            foreach ($p in $patterns) {
                $r = Invoke-Route $helper $route $p.sample
                Write-Step "$helper -$route refuses $($p.id)" ($r.Code -eq 3 -and $r.Out.Count -eq 0) "exit $($r.Code), $($r.Out.Count) output line(s)"
            }
            $c = Invoke-Route $helper $route 'echo ok'
            $passed = $c.Code -eq 0 -and ($c.Out -join '|') -eq 'ok'
            Write-Step "$helper -$route passes the control 'echo ok'" ($passed -ne [bool]$ProveFailure) "exit $($c.Code), output '$($c.Out -join '|')'$(if ($ProveFailure) { ' (-ProveFailure expects a refusal)' })"
        }
    }
} finally {
    Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
}
if ($failed -gt 0) { exit 1 }
exit 0
