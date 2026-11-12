# Server: the nightly offsite backup (infra/backup-offsite.sh, run by backup-offsite.timer) succeeded recently. The server's e2e counterpart
# to the laptop's "non-empty dump younger than 25 h": there are no dump files on the server (pg_dump goes straight into age and the bucket),
# so the evidence is the unit's journal line "[PASS] backup finished, heartbeat pinged", which the script prints only after upload and ping.
#   powershell -File scripts\check-offsite-backup-recent.ps1 [-MaxAgeMinutes 1500]   Exit 0 = ok, 1 = problem.
# Prove it can fail: -MaxAgeMinutes 1 (no success in the last minute). Prints counts and times only.
param([ValidateRange(1, 100000)][int]$MaxAgeMinutes = 1500)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\target.ps1"
$T = Get-Target 'Server'
$failed = 0
function Write-Step([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { Write-Host "[PASS] $Name" -ForegroundColor Green -NoNewline } else { Write-Host "[FAIL] $Name" -ForegroundColor Red -NoNewline; $script:failed++ }
    if ($Detail) { Write-Host " - $Detail" } else { Write-Host '' }
}

$sh = @'
echo "ok=$(journalctl -u backup-offsite --since "-__MIN__ min" --no-pager -o cat 2>/dev/null | grep -c '^\[PASS\] backup finished')"
echo "last=$(journalctl -u backup-offsite --no-pager -o short-iso 2>/dev/null | grep '\[PASS\] backup finished' | tail -1 | cut -d' ' -f1)"
echo "timer=$(systemctl is-active backup-offsite.timer)"
echo "result=$(systemctl show backup-offsite.service -p Result --value)"
'@
$out = @(Invoke-TargetSh $T $sh.Replace('__MIN__', [string]$MaxAgeMinutes))
if ($LASTEXITCODE -ne 0) { Write-Step 'server reachable over Tailscale' $false "exit $LASTEXITCODE"; Write-Output '1 failed'; exit 1 }
function Get-One([string]$Key) { $v = @($out | Where-Object { "$_" -like "$Key=*" } | ForEach-Object { "$_".Substring($Key.Length + 1).Trim() }); if ($v.Count) { $v[0] } else { '' } }

$ok = Get-One 'ok'
Write-Step "offsite backup succeeded in the last $MaxAgeMinutes min" ($ok -match '^\d+$' -and [int]$ok -ge 1) "$ok success line(s); last success $(if (Get-One 'last') { Get-One 'last' } else { 'never' })"
Write-Step 'backup-offsite.timer is active' ((Get-One 'timer') -eq 'active') (Get-One 'timer')
Write-Step 'the last backup-offsite run did not fail' ((Get-One 'result') -eq 'success') "Result=$(Get-One 'result')"

Write-Output ("{0} failed" -f $failed)
if ($failed -gt 0) { exit 1 }
exit 0
