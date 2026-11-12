# Fails if a workflow's errorWorkflow setting is wrong. The setting lives only in n8n (the .sdk.ts files cannot carry it),
# so a workflow recreated from its file would silently lose alerting.
# Intake, Processor and Monitor must point at the Error Handler; the Error Handler and Send Alert must have none
# (a failing alert must never trigger another alert). The two invoice sub-workflows (Render Invoice, Send Telegram) have none either:
# they return their problems to the Processor, which reports the failure, so a second alert for the same thing would only be noise.
# Run: powershell -File scripts\check-error-workflows.ps1 [-ErrorHandlerId <id>] [-Target Laptop|Server]   Exit 0 = all correct, 1 = problem.
# Prints names and ids only. -ErrorHandlerId lets you prove the failure path without editing a live workflow.
# Workflow ids are the same on the server (import:workflow keeps them), so the list below serves both targets.
param([string]$ErrorHandlerId = '', [ValidateSet('Laptop', 'Server')][string]$Target = 'Laptop')
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\target.ps1"
. "$PSScriptRoot\lib\workflows.ps1"
$T = Get-Target $Target
if (-not $ErrorHandlerId) { $ErrorHandlerId = $ErrorHandlerWorkflowId }

# id, expected name, expected errorWorkflow ('' = must have none); the same list import-workflows.ps1 sets them from.
$expected = @(Get-Workflows | ForEach-Object { @{ Id = $_.Id; Name = $_.Name; Target = $(if ($_.ErrorHandler) { $ErrorHandlerId } else { '' }) } })

$failed = 0
foreach ($w in $expected) {
    $label = "{0} ({1})" -f $w.Name, $w.Id
    # The CLI can print warnings before the JSON array, so cut at the first '['.
    $raw = (@(Invoke-TargetSh $T "docker exec n8n n8n export:workflow --id=$($w.Id) 2>/dev/null") -join "`n")
    $start = $raw.IndexOf('[')
    $wf = $null
    if ($start -ge 0) { try { $wf = @($raw.Substring($start) | ConvertFrom-Json)[0] } catch { $wf = $null } }
    if (-not $wf) { Write-Host "[FAIL] $label : no workflow JSON from n8n export" -ForegroundColor Red; $failed++; continue }
    if ($wf.name -ne $w.Name) { Write-Host "[FAIL] $label : live name is '$($wf.name)'" -ForegroundColor Red; $failed++; continue }

    $actual = if ($wf.settings -and $wf.settings.errorWorkflow) { [string]$wf.settings.errorWorkflow } else { '' }
    if ($actual -eq $w.Target) {
        $shown = if ($actual) { "errorWorkflow = $actual" } else { 'no errorWorkflow (correct)' }
        Write-Host "[PASS] $label : $shown" -ForegroundColor Green
    } else {
        $want = if ($w.Target) { $w.Target } else { 'none' }
        $got = if ($actual) { $actual } else { 'none' }
        Write-Host "[FAIL] $label : errorWorkflow is $got, expected $want" -ForegroundColor Red
        $failed++
    }
}

# Write-Output: e2e reads this line.
Write-Output ("{0} failed" -f $failed)
if ($failed -gt 0) { exit 1 }
exit 0
