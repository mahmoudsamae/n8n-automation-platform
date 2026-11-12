# Proves the outside probe (.github/workflows/outside-probe.yml) is harmless to the pipeline: a bad-signature POST through Cloudflare
# gets 400, runs the Intake to a SUCCESSFUL execution (Respond 400 Invalid Signature is a normal branch), stores no stripe_events row,
# and starts no Error Handler or Send Alert execution. The Monitor alerts only on stripe_events rows, so no row means no alert.
# Sends -Count requests exactly like the probe, then compares the server's counts before and after (names and counts only).
#   powershell -File scripts\check-probe-quiet.ps1 [-Count 3] [-Url <public intake URL>]   Exit 0 = quiet, 1 = problem.
# Prove it can fail: -Url with another path (the WAF answers 403, no Intake execution, so the positive signal "Intake success +N" fails).
param(
    [ValidateRange(1, 20)][int]$Count = 3,
    [string]$Url = 'https://invoice.mahmud-alhussen.de/webhook/stripe-intake',
    [ValidateRange(10, 600)][int]$WaitSeconds = 75
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\http-reason.ps1"
$failed = 0
function Write-Step([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { Write-Host "[PASS] $Name" -ForegroundColor Green -NoNewline } else { Write-Host "[FAIL] $Name" -ForegroundColor Red -NoNewline; $script:failed++ }
    if ($Detail) { Write-Host " - $Detail" } else { Write-Host '' }
}

$js = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'lib\n8n-execution-counts.js'))
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($js -replace "`r", '')))
$snapSh = "echo $b64 | base64 -d | docker exec -i n8n node - && echo rows=`$(docker exec postgres psql -U automation -d automation -tAc 'select count(*) from stripe_events')"
function Get-Snapshot {
    $out = @(& "$PSScriptRoot\server-sh.ps1" -Script $snapSh)
    if ($LASTEXITCODE -ne 0) { throw "server snapshot failed (exit $LASTEXITCODE)" }
    $s = @{}
    foreach ($l in $out) {
        if ("$l" -match '^exec=(.+)\|(\w+)\|(\d+)$') { $s["$($Matches[1])|$($Matches[2])"] = [int]$Matches[3] }
        elseif ("$l" -match '^rows=(\d+)$') { $s['rows'] = [int]$Matches[1] }
    }
    if (-not $s.ContainsKey('rows')) { throw 'server snapshot has no stripe_events count' }
    return $s
}
function Get-Delta($a, $b, [string]$k) { $(if ($b.ContainsKey($k)) { $b[$k] } else { 0 }) - $(if ($a.ContainsKey($k)) { $a[$k] } else { 0 }) }

$body = Join-Path $env:TEMP "probe-body-$PID.json"
[IO.File]::WriteAllText($body, '{"id":"evt_probe_quiet","type":"probe"}')
try {
    $before = Get-Snapshot
    $codes = @()
    for ($i = 1; $i -le $Count; $i++) {
        # The same request as the probe: a current timestamp (so the 5-minute check passes) and a signature that cannot match.
        $t = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $resp = Join-Path $env:TEMP "probe-resp-$PID.txt"
        $code = & curl.exe -s -o $resp -w '%{http_code}' --max-time 20 -X POST -H 'Content-Type: application/json' -H "Stripe-Signature: t=$t,v1=$('0' * 64)" --data-binary "@$body" $Url
        $text = if (Test-Path $resp) { [IO.File]::ReadAllText($resp) } else { '' }
        $codes += "$code $(Get-HttpReason $text)"   # never the body itself (scripts\lib\http-reason.ps1)
    }
    $want = '400 error: invalid signature'
    $bad = @($codes | Where-Object { $_ -ne $want })
    Write-Step "$Count probe POSTs got 400 invalid signature" ($bad.Count -eq 0) $(if ($bad.Count) { ($bad | Select-Object -Unique) -join '; ' } else { $want })
    Start-Sleep -Seconds $WaitSeconds   # long enough for an Error Handler run to appear if one were triggered
    $after = Get-Snapshot

    $ok = Get-Delta $before $after 'Stripe Intake|success'
    Write-Step "Intake: +$Count successful executions (the probes ran)" ($ok -eq $Count) "+$ok"
    $err = Get-Delta $before $after 'Stripe Intake|error'
    Write-Step 'Intake: no new error execution' ($err -eq 0) "+$err"
    foreach ($w in 'Stripe Error Handler', 'Stripe Send Alert') {
        $n = 0; foreach ($k in $after.Keys) { if ($k -like "$w|*") { $n += Get-Delta $before $after $k } }
        Write-Step "${w}: no new execution" ($n -eq 0) "+$n"
    }
    $rows = $after['rows'] - $before['rows']
    Write-Step 'stripe_events: no new row' ($rows -eq 0) "+$rows"
}
catch {
    Write-Step 'probe quiet check aborted' $false $_.Exception.Message
}
finally {
    Remove-Item -LiteralPath $body -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $env:TEMP "probe-resp-$PID.txt") -ErrorAction SilentlyContinue
}
Write-Output ("{0} failed" -f $failed)
if ($failed -gt 0) { exit 1 }
exit 0
