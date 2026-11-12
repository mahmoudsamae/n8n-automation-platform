# Fails if a live n8n workflow differs from its .sdk.ts file (nodes, parameters, credentials, onError, connections).
# CLAUDE.md rule: every change to a live workflow is exported to its .sdk.ts in the same session. This is the check for it.
# Each .sdk.ts is compiled with the pinned @n8n/workflow-sdk (scripts\sdk-drift) and compared with `n8n export:workflow` of the live workflow.
# Settings the file cannot carry (errorWorkflow) are covered by check-error-workflows.ps1, not here.
# Run: powershell -File scripts\check-sdk-drift.ps1 [-SdkDir <folder with the .sdk.ts files>]   Exit 0 = no drift, 1 = drift or error.
# -SdkDir lets you prove the failure path with an edited copy, without touching a live workflow.
# It also fails when a workflow has an unpublished draft: n8n 2.x edits change the draft, and the live trigger keeps running the
# published version, so a file can match the draft while production runs something older (found in M7b-3).
# -PublishedOnlyIds <id,...> checks only that for the given workflows, to prove the failure path on a workflow with a draft.
# -Target Server exports from the server n8n and maps the laptop's credential and data table ids in each compiled file to the server's
# (infra\n8n-ids.server.json, sdk-drift\apply-ids.mjs) before comparing. Workflow ids are the same on both (import keeps them).
# First run installs the pinned SDK (npm ci in scripts\sdk-drift, needs the network once).
param([string]$SdkDir = (Split-Path -Parent $PSScriptRoot), [string[]]$PublishedOnlyIds = @(), [ValidateSet('Laptop', 'Server')][string]$Target = 'Laptop')
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\target.ps1"
. "$PSScriptRoot\lib\workflows.ps1"
$T = Get-Target $Target
function Export-Workflow([string]$Id) { return (@(Invoke-TargetSh $T "docker exec n8n n8n export:workflow --id=$Id 2>/dev/null") -join "`n") }

$tool = Join-Path $PSScriptRoot 'sdk-drift'
if (-not (Test-Path (Join-Path $tool 'node_modules\@n8n\workflow-sdk'))) {
    Write-Host 'installing the pinned @n8n/workflow-sdk (npm ci in scripts\sdk-drift) ...'
    Push-Location $tool
    try { & npm ci --no-audit --no-fund 2>&1 | Out-Null; if ($LASTEXITCODE -ne 0) { Write-Host '[FAIL] npm ci failed' -ForegroundColor Red; exit 1 } } finally { Pop-Location }
}

# id, source file (scripts\lib\workflows.ps1)
$workflows = Get-Workflows

# Draft and published version ids come from the same export; versionId is the draft, activeVersionId what the trigger runs.
function Test-Published([string]$Id, [string]$Raw) {
    $wf = @($Raw.Substring($Raw.IndexOf('[')) | ConvertFrom-Json)[0]
    return ($wf.activeVersionId -and $wf.versionId -eq $wf.activeVersionId)
}
# powershell -File passes "a,b" as one string: split it here.
$PublishedOnlyIds = @($PublishedOnlyIds | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($PublishedOnlyIds.Count -gt 0) {
    $bad = 0
    foreach ($id in $PublishedOnlyIds) {
        $raw = Export-Workflow $id
        if ($raw.IndexOf('[') -lt 0) { Write-Host "[FAIL] $id : no workflow JSON from n8n export" -ForegroundColor Red; $bad++; continue }
        if (Test-Published $id $raw) { Write-Host "[PASS] $id : published version is the current draft" -ForegroundColor Green }
        else { Write-Host "[FAIL] $id : unpublished draft (live runs an older version, or the workflow is not published)" -ForegroundColor Red; $bad++ }
    }
    if ($bad -gt 0) { exit 1 }; exit 0
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('sdk-drift-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$failed = 0
try {
    foreach ($w in $workflows) {
        $src = Join-Path $SdkDir $w.File
        if (-not (Test-Path $src)) { Write-Host "[FAIL] $($w.File) : file not found" -ForegroundColor Red; $failed++; continue }

        # Exported by id, written to a file (the CLI can print warnings before the JSON array; compare.mjs cuts at the first '[').
        $exportFile = Join-Path $tmp ($w.Id + '.raw')
        $raw = Export-Workflow $w.Id
        if ($raw.IndexOf('[') -lt 0) { Write-Host "[FAIL] $($w.File) : no workflow JSON from n8n export" -ForegroundColor Red; $failed++; continue }
        [IO.File]::WriteAllText($exportFile, $raw, (New-Object System.Text.UTF8Encoding($false)))

        $compiled = Join-Path $tmp ($w.Id + '.json')
        $out = @(& node (Join-Path $tool 'compile.mjs') $src $compiled 2>&1)
        if ($LASTEXITCODE -ne 0) { Write-Host "[FAIL] $($w.File) : does not compile" -ForegroundColor Red; $out | Select-Object -First 5 | ForEach-Object { Write-Host "        $_" }; $failed++; continue }

        if ($T.IdMap) {
            $mapped = Join-Path $tmp ($w.Id + '.mapped.json')
            $out = @(& node (Join-Path $tool 'apply-ids.mjs') $T.IdMap $compiled $mapped 2>&1)
            if ($LASTEXITCODE -ne 0) { Write-Host "[FAIL] $($w.File) : ids cannot be mapped to $Target" -ForegroundColor Red; $out | Select-Object -First 3 | ForEach-Object { Write-Host "        $_" }; $failed++; continue }
            $compiled = $mapped
        }
        $cmp = @(& node (Join-Path $tool 'compare.mjs') $compiled $exportFile 2>&1)
        $diffLines = @($cmp | Where-Object { "$_" -match '^DIFF|^        ' })
        $cmpExit = $LASTEXITCODE
        if (-not (Test-Published $w.Id $raw)) {
            Write-Host "[FAIL] $($w.File) : unpublished draft in n8n ($($w.Id)): publish it, the live trigger runs an older version" -ForegroundColor Red
            $failed++
        }
        if ($cmpExit -eq 0) {
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

# Write-Output: e2e reads this line.
Write-Output ("{0} failed" -f $failed)
if ($failed -gt 0) { exit 1 }
exit 0
