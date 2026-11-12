# Imports the workflows into the SERVER n8n from their .sdk.ts files, with the server's credential and data table ids, and publishes them.
# The laptop's workflows are edited through the n8n MCP instead (update_workflow + publish_workflow); this script refuses the laptop.
#   powershell -File scripts\import-workflows.ps1 [-Only <id,...>] [-IdMap <map.json>] [-NoPublish]
# Per workflow: compile (pinned SDK, scripts\sdk-drift) -> map ids (apply-ids.mjs, infra\n8n-ids.server.json) -> add the settings the file
# cannot carry (scripts\lib\workflows.ps1: errorWorkflow, executionOrder, binaryMode) -> copy to the server with Windows OpenSSH scp
# (the Processor is about 52 KB, too big for server-sh.ps1's command line) -> `n8n import:workflow` (keeps the id, overwrites an existing
# one) -> `n8n publish:workflow`. Import order: the called workflows first, the Monitor last (its heartbeat starts with it).
# A running n8n only (re)registers triggers of a CLI-published workflow after a restart: -Restart does that at the end.
# Import deactivates a published workflow until the publish and restart: once the server is public (M7b-5b), Stripe deliveries in that
# window get 404 and Stripe retries them (non-2xx). Nothing is lost, but import outside demo hours.
# Workflow JSON holds credential IDS, never secrets. Exit 0 = all imported (and published), 1 = error.
param(
    [string[]]$Only = @(),
    [string]$IdMap = '',
    [switch]$NoPublish,
    [switch]$Restart,
    [ValidateSet('Server')][string]$Target = 'Server'
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\target.ps1"
. "$PSScriptRoot\lib\workflows.ps1"
$T = Get-Target $Target
if (-not $IdMap) { $IdMap = $T.IdMap }
$root = Split-Path -Parent $PSScriptRoot
$tool = Join-Path $PSScriptRoot 'sdk-drift'
if (-not (Test-Path (Join-Path $tool 'node_modules\@n8n\workflow-sdk'))) { throw 'run scripts\check-sdk-drift.ps1 once first (it installs the pinned SDK)' }

$order = 'WO2ebvkZGK5NxzVo', 'c2NT8k3JGpuS3r6I', '3dvdSRSD6ObBVsxy', 'Yel7C2ufq8wR5s3W', '3j0pWVoxvDY2sdO5', 'ylR2t9B0ZAH1cLfq', 'yeSlEcPp87vCJT7D'
$Only = @($Only | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$all = Get-Workflows
$selected = @($order | ForEach-Object { $id = $_; $all | Where-Object { $_.Id -eq $id } } | Where-Object { $Only.Count -eq 0 -or $Only -contains $_.Id })
foreach ($id in $Only) { if (-not ($all | Where-Object { $_.Id -eq $id })) { throw "unknown workflow id $id" } }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('n8n-import-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$failed = 0
try {
    foreach ($w in $selected) {
        $compiled = Join-Path $tmp "$($w.Id).compiled.json"
        $out = @(& node (Join-Path $tool 'compile.mjs') (Join-Path $root $w.File) $compiled 2>&1)
        if ($LASTEXITCODE -ne 0) { $out | Select-Object -First 5 | ForEach-Object { Write-Host "        $_" }; throw "$($w.File) does not compile" }
        $mapped = Join-Path $tmp "$($w.Id).mapped.json"
        $out = @(& node (Join-Path $tool 'apply-ids.mjs') $IdMap $compiled $mapped 2>&1)
        if ($LASTEXITCODE -ne 0) { $out | Select-Object -First 3 | ForEach-Object { Write-Host "        $_" }; throw "$($w.File): ids cannot be mapped" }
        $settings = @{} + $w.Settings
if ($w.ServerSettings) { $settings += $w.ServerSettings }
        if ($w.ErrorHandler) { $settings.errorWorkflow = $ErrorHandlerWorkflowId }
        $settingsFile = Join-Path $tmp "$($w.Id).settings.json"
        [IO.File]::WriteAllText($settingsFile, ($settings | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
        # Settings are set in node, not with ConvertTo-Json: Windows PowerShell 5.1 can wrap deserialized arrays as {"value":[...],"Count":n},
        # which would corrupt the connections. The .sdk.ts files carry a slug id (stripe-intake), so the n8n id is set here; the name must
        # match, so a wrong file can never overwrite another workflow. Errors go to stdout (stderr is a terminating error in PowerShell 5.1).
        $js = "const fs=require('fs');const [m,s,o,id,name]=process.argv.slice(1);const w=JSON.parse(fs.readFileSync(m,'utf8'));" +
            "if(w.name!==name){console.log('compiled to '+w.name);process.exit(1)}" +
            "w.id=id;w.settings=JSON.parse(fs.readFileSync(s,'utf8'));fs.writeFileSync(o,JSON.stringify(w,null,2))"
        $out = @(& node -e $js $mapped $settingsFile (Join-Path $tmp "$($w.Id).json") $w.Id $w.Name 2>&1)
        if ($LASTEXITCODE -ne 0) { throw "$($w.File): $out (expected '$($w.Name)' ($($w.Id)))" }
        Write-Host "[ok]   $($w.Name) ($($w.Id)): compiled, ids mapped, errorWorkflow $(if ($w.ErrorHandler) { $ErrorHandlerWorkflowId } else { 'none' })"
    }

    $null = Invoke-TargetSh $T 'mkdir -p ~/n8n-import && chmod 700 ~/n8n-import'
    $scp = Join-Path $env:WINDIR 'System32\OpenSSH\scp.exe'
    $files = @($selected | ForEach-Object { Join-Path $tmp "$($_.Id).json" })
    & $scp -q -i $T.Tunnel.KeyFile -o BatchMode=yes -o ConnectTimeout=15 @files "$($T.Tunnel.Host):n8n-import/"
    if ($LASTEXITCODE -ne 0) { throw "scp to the server failed (exit $LASTEXITCODE)" }

    foreach ($w in $selected) {
        $publish = if ($NoPublish) { 'echo "publish skipped"' } else { "docker exec n8n n8n publish:workflow --id=$($w.Id) 2>&1 | tail -n 3" }
        $sh = @"
set -eo pipefail
docker cp ~/n8n-import/$($w.Id).json n8n:/tmp/import-$($w.Id).json
docker exec n8n n8n import:workflow --input=/tmp/import-$($w.Id).json 2>&1 | tail -n 3
$publish
docker exec -u root n8n rm -f /tmp/import-$($w.Id).json
rm -f ~/n8n-import/$($w.Id).json
echo IMPORT_OK
"@
        $res = @(Invoke-TargetSh $T $sh)
        $code = $LASTEXITCODE
        $res | Where-Object { "$_" -ne 'IMPORT_OK' } | ForEach-Object { Write-Host "        $_" }
        if ($code -eq 0 -and ($res -contains 'IMPORT_OK')) { Write-Host "[PASS] $($w.Name) imported$(if (-not $NoPublish) { ' and published' })" -ForegroundColor Green }
        else { Write-Host "[FAIL] $($w.Name): import failed (exit $code)" -ForegroundColor Red; $failed++ }
    }

    if ($Restart -and $failed -eq 0) {
        $res = @(Invoke-TargetSh $T "cd $($T.ComposeDir) && docker compose $($T.ComposeArgs) restart n8n 2>&1 | tail -n 2; for i in `$(seq 1 30); do docker exec n8n wget -qO- http://127.0.0.1:5678/healthz >/dev/null 2>&1 && echo HEALTHY && break; sleep 2; done")
        if ($res -contains 'HEALTHY') { Write-Host '[PASS] n8n restarted and healthy' -ForegroundColor Green } else { Write-Host '[FAIL] n8n not healthy after restart' -ForegroundColor Red; $failed++ }
    }
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ("{0} failed" -f $failed)
if ($failed -gt 0) { exit 1 }
exit 0
