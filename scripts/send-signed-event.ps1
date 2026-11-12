# POSTs one Stripe-signed event to a target's Intake and prints the HTTP status. For proofs where Stripe cannot deliver (the server
# before its tunnel is public, M7b-5a) or must not (a test body).
#   powershell -File scripts\send-signed-event.ps1 -Target Server -BodyFile <event.json>     # a real event, e.g. from `stripe events retrieve`
#   powershell -File scripts\send-signed-event.ps1 -Target Server -TestId evt_test_...        # a minimal {"id","type"} body (stored as ignored)
# The signature is computed ON the target from STRIPE_WEBHOOK_SECRET in its .env (the same value as the n8n crypto credential); only the
# hex HMAC comes back, the secret never reaches this machine. The body travels as base64, so no shell quoting touches it.
# Server: posts to n8n through its own SSH tunnel (Open-TargetTunnel, closed at the end), not the public URL. Laptop: localhost.
# Output: 'status=<code>' and the response body (Intake answers small JSON). Exit 0 when a status was received, 1 on an error.
param(
    [ValidateSet('Laptop', 'Server')][string]$Target = 'Server',
    [string]$BodyFile = '',
    [string]$TestId = '',
    [string]$TestType = 'e2e.signed_test'
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\target.ps1"
. "$PSScriptRoot\lib\http-reason.ps1"
$T = Get-Target $Target

if (($BodyFile -and $TestId) -or (-not $BodyFile -and -not $TestId)) { throw 'give exactly one of: -BodyFile, -TestId' }
if ($TestId) {
    if ($TestId -notmatch '^evt_test_[A-Za-z0-9_]+$') { throw 'a -TestId must start with evt_test_ (test rows use that prefix)' }
    $body = '{"id":"' + $TestId + '","type":"' + $TestType + '"}'
} else {
    $body = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $BodyFile)).Trim()
}
$bodyBytes = (New-Object Text.UTF8Encoding($false)).GetBytes($body)
$ts = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

# Same scheme as Stripe and Intake: HMAC-SHA256 of "<timestamp>.<raw body>".
$sh = @'
secret=$(grep '^STRIPE_WEBHOOK_SECRET=' __ENVFILE__ | head -n1 | cut -d= -f2-)
secret=${secret%\"}; secret=${secret#\"}
if [ -z "$secret" ]; then echo NOSECRET; exit 3; fi
umask 077   # a real event body holds customer name, email and address
printf '%s' '__B64__' | base64 -d > /tmp/signed-body.$$
S="$secret" TS='__TS__' F=/tmp/signed-body.$$ python3 -c 'import hmac,hashlib,os; b=open(os.environ["F"],"rb").read(); print(hmac.new(os.environ["S"].encode(), os.environ["TS"].encode() + b"." + b, hashlib.sha256).hexdigest())'
rm -f /tmp/signed-body.$$
'@
$sh = $sh.Replace('__ENVFILE__', $T.EnvFile).Replace('__TS__', "$ts").Replace('__B64__', [Convert]::ToBase64String($bodyBytes))
$sig = @(@(Invoke-TargetSh $T $sh) | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
if ($LASTEXITCODE -ne 0 -or $sig.Count -ne 1 -or $sig[0] -notmatch '^[0-9a-f]{64}$') { throw "could not compute the signature on $Target" }

$tunnel = $null
try {
    $tunnel = Open-TargetTunnel $T
    $url = "$($T.N8nUrl)/webhook/stripe-intake"
    try {
        $r = Invoke-WebRequest -Uri $url -Method Post -UseBasicParsing -ContentType 'application/json' -Headers @{ 'Stripe-Signature' = "t=$ts,v1=$($sig[0])" } -Body $bodyBytes -TimeoutSec 30
        # Status and a short reason only, never the body (scripts\lib\http-reason.ps1).
        Write-Output "status=$([int]$r.StatusCode) $(Get-HttpReason $r.Content)"
    } catch {
        if (-not $_.Exception.Response) { throw }
        $resp = $_.Exception.Response
        $text = try { (New-Object IO.StreamReader($resp.GetResponseStream())).ReadToEnd() } catch { '' }
        Write-Output "status=$([int]$resp.StatusCode) $(Get-HttpReason $text)"
    }
} finally {
    Close-TargetTunnel $tunnel
}
exit 0
