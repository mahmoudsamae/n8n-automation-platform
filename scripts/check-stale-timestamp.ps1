# Proves Intake's replay window: a correctly SIGNED request whose timestamp is older than 5 minutes must get 400 and must not be stored.
# A control with a fresh timestamp, signed the same way, must be accepted and stored once. The control is what makes the 400 meaningful:
# without it a broken signing helper would also produce 400 and the check would pass for the wrong reason.
#   powershell -File scripts\check-stale-timestamp.ps1 [-AgeSeconds 400] [-CorruptSignature]
# Exit 0 = all four checks pass, 1 = a check failed.
# Failure paths for proving the check can fail (test only): -AgeSeconds 0 makes the "stale" request fresh, so it is accepted and the stale checks FAIL;
# -CorruptSignature breaks the control's signature, so the control is rejected and its checks FAIL.
# The signing secret is read from ~/n8n/.env INSIDE WSL and only the derived HMAC comes back; the secret is never printed or held in this process.
# Rows use ids evt_test_e2e_stale_* (event type e2e.stale_timestamp, stored as 'ignored') and are removed with clean-test-event.ps1 before and after.
# -Target Server: the secret comes from the server's .env (computed there), the requests go to the PUBLIC URL (through Cloudflare and the
# tunnel). The rows cannot be removed there: DELETE through server-sh.ps1 is refused by the guard, by design. So each run uses its own ids
# (suffix = unix time) and leaves its two 'ignored' rows for the nightly demo reset (M7c).
param(
    [int]$AgeSeconds = 400,
    [switch]$CorruptSignature,
    [ValidateSet('Laptop', 'Server')][string]$Target = 'Laptop'
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\target.ps1"
$T = Get-Target $Target

$IntakeUrl = $T.IntakeUrl
$suffix = if ($Target -eq 'Server') { '_' + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() } else { '' }
$StaleId = 'evt_test_e2e_stale_old' + $suffix
$FreshId = 'evt_test_e2e_stale_fresh' + $suffix
$failed = 0

function Write-Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    $tag = if ($Ok) { 'PASS' } else { 'FAIL' }
    $color = if ($Ok) { 'Green' } else { 'Red' }
    if (-not $Ok) { $script:failed++ }
    Write-Host ("[{0}] {1}" -f $tag, $Name) -ForegroundColor $color -NoNewline
    if ($Detail) { Write-Host (" - {0}" -f $Detail) } else { Write-Host '' }
}

function Get-EventBody([string]$Id) { return '{"id":"' + $Id + '","type":"e2e.stale_timestamp"}' }

# HMAC-SHA256 of "<timestamp>.<body>" with STRIPE_WEBHOOK_SECRET, computed on the target (same scheme Stripe and Intake use).
function Get-Signature([long]$Timestamp, [string]$Body) {
    $template = @'
secret=$(grep '^STRIPE_WEBHOOK_SECRET=' __ENVFILE__ | head -n1 | cut -d= -f2-)
secret=${secret%\"}; secret=${secret#\"}
if [ -z "$secret" ]; then echo NOSECRET; exit 3; fi
S="$secret" TS='__TS__' BODY='__BODY__' python3 -c 'import hmac,hashlib,os; print(hmac.new(os.environ["S"].encode(), (os.environ["TS"] + "." + os.environ["BODY"]).encode(), hashlib.sha256).hexdigest())'
'@
    $script = $template.Replace('__TS__', "$Timestamp").Replace('__BODY__', $Body).Replace('__ENVFILE__', $T.EnvFile)
    $out = @(@(Invoke-TargetSh $T $script) | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
    if ($LASTEXITCODE -ne 0 -or $out.Count -ne 1 -or $out[0] -notmatch '^[0-9a-f]{64}$') { throw "could not compute the signature (STRIPE_WEBHOOK_SECRET missing in $($T.EnvFile) on $Target?)" }
    return $out[0]
}

function Send-Signed([string]$Id, [long]$Timestamp, [bool]$Corrupt) {
    $body = Get-EventBody $Id
    $sig = Get-Signature $Timestamp $body
    if ($Corrupt) { $sig = ($(if ($sig[0] -eq '0') { '1' } else { '0' })) + $sig.Substring(1) }
    try {
        $r = Invoke-WebRequest -Uri $IntakeUrl -Method Post -UseBasicParsing -ContentType 'application/json' `
            -Headers @{ 'Stripe-Signature' = "t=$Timestamp,v1=$sig" } -Body $body
        return [int]$r.StatusCode
    } catch {
        if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode }
        throw
    }
}

function Get-RowCount([string]$Id) {
    $q = 'docker exec postgres psql -U automation -d automation -tAc "select count(*) from stripe_events where event_id = ''' + $Id + '''"'
    $out = @(@(Invoke-TargetSh $T $q) | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
    if ($out.Count -ne 1 -or $out[0] -notmatch '^\d+$') { throw "unexpected psql output while counting $Id" }
    return [int]$out[0]
}

function Remove-Rows {
    if ($Target -ne 'Laptop') { return }
    foreach ($id in $StaleId, $FreshId) { $null = & "$PSScriptRoot\clean-test-event.ps1" -Id $id }
}

try {
    Remove-Rows
    # Not Get-Date -UFormat %s: in Windows PowerShell 5.1 it returns the LOCAL epoch (3600 s ahead in Berlin), which put the "stale" timestamp in the future.
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    $staleCode = Send-Signed $StaleId ($now - $AgeSeconds) $false
    Write-Check "validly signed request $AgeSeconds s old is rejected with 400" ($staleCode -eq 400) "got $staleCode"
    $staleRows = Get-RowCount $StaleId
    Write-Check 'the stale event was not stored' ($staleRows -eq 0) "found $staleRows"

    $freshCode = Send-Signed $FreshId $now ([bool]$CorruptSignature)
    Write-Check 'control: the same signing with a fresh timestamp is accepted with 200' ($freshCode -eq 200) "got $freshCode"
    $freshRows = Get-RowCount $FreshId
    Write-Check 'control: the fresh event was stored exactly once' ($freshRows -eq 1) "found $freshRows"
}
catch {
    Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
    $failed++
}
finally {
    Remove-Rows
}

if ($failed -gt 0) { exit 1 }
exit 0
