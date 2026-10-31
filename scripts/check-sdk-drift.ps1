# Fails if a live n8n workflow differs from its .sdk.ts file (nodes, parameters, credentials, onError, connections).
# CLAUDE.md rule: every change to a live workflow is exported to its .sdk.ts in the same session. This is the check for it.
# Each .sdk.ts is compiled with the pinned @n8n/workflow-sdk (scripts\sdk-drift) and compared with `n8n export:workflow` of the live workflow.
# Settings the file cannot carry (errorWorkflow) are covered by check-error-workflows.ps1, not here.
# Run: powershell -File scripts\check-sdk-drift.ps1 [-SdkDir <folder with the .sdk.ts files>]   Exit 0 = no drift, 1 = drift or error.
# -SdkDir lets you prove the failure path with an edited copy, without touching a live workflow.
# First run installs the pinned SDK (npm ci in scripts\sdk-drift, needs the network once).
param([string]$SdkDir = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'

$tool = Join-Path $PSScriptRoot 'sdk-drift'
if (-not (Test-Path (Join-Path $tool 'node_modules\@n8n\workflow-sdk'))) {
    Write-Host 'installing the pinned @n8n/workflow-sdk (npm ci in scripts\sdk-drift) ...'
    Push-Location $tool
    try { & npm ci --no-audit --no-fund 2>&1 | Out-Null; if ($LASTEXITCODE -ne 0) { Write-Host '[FAIL] npm ci failed' -ForegroundColor Red; exit 1 } } finally { Pop-Location }
}

# id, source file
$workflows = @(
    @{ Id = '3j0pWVoxvDY2sdO5'; File = 'stripe-intake.sdk.ts' }
    @{ Id = 'ylR2t9B0ZAH1cLfq'; File = 'stripe-processor.sdk.ts' }
    @{ Id = 'yeSlEcPp87vCJT7D'; File = 'stripe-monitor.sdk.ts' }
    @{ Id = 'c2NT8k3JGpuS3r6I'; File = 'stripe-error-handler.sdk.ts' }
    @{ Id = 'WO2ebvkZGK5NxzVo'; File = 'stripe-send-alert.sdk.ts' }
    @{ Id = '3dvdSRSD6ObBVsxy'; File = 'stripe-render-invoice.sdk.ts' }
    @{ Id = 'Yel7C2ufq8wR5s3W'; File = 'stripe-send-telegram.sdk.ts' }
)

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('sdk-drift-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$failed = 0
try {
    foreach ($w in $workflows) {
        $src = Join-Path $SdkDir $w.File
        if (-not (Test-Path $src)) { Write-Host "[FAIL] $($w.File) : file not found" -ForegroundColor Red; $failed++; continue }

        # Exported by id, written to a file (the CLI can print warnings before the JSON array; compare.mjs cuts at the first '[').
        $exportFile = Join-Path $tmp ($w.Id + '.raw')
        $raw = (@(wsl -d Ubuntu docker exec n8n n8n export:workflow "--id=$($w.Id)" 2>$null) -join "`n")
        if ($raw.IndexOf('[') -lt 0) { Write-Host "[FAIL] $($w.File) : no workflow JSON from n8n export" -ForegroundColor Red; $failed++; continue }
        [IO.File]::WriteAllText($exportFile, $raw, (New-Object System.Text.UTF8Encoding($false)))

        $compiled = Join-Path $tmp ($w.Id + '.json')
        $out = @(& node (Join-Path $tool 'compile.mjs') $src $compiled 2>&1)
        if ($LASTEXITCODE -ne 0) { Write-Host "[FAIL] $($w.File) : does not compile" -ForegroundColor Red; $out | Select-Object -First 5 | ForEach-Object { Write-Host "        $_" }; $failed++; continue }

        $cmp = @(& node (Join-Path $tool 'compare.mjs') $compiled $exportFile 2>&1)
        $diffLines = @($cmp | Where-Object { "$_" -match '^DIFF|^        ' })
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[PASS] $($w.File) : no differences from live ($($w.Id))" -ForegroundColor Green
        } else {
            Write-Host "[FAIL] $($w.File) : differs from live ($($w.Id))" -ForegroundColor Red
            $diffLines | Select-Object -First 8 | ForEach-Object { Write-Host "        $_" }
            $failed++
        }
    }
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failed -gt 0) { exit 1 }
exit 0
