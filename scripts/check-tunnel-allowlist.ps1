# Proves from OUTSIDE that the public hostname serves only POST /webhook/stripe-intake (M7b-5b). Run it from the laptop, not the server.
# Run: powershell -File scripts\check-tunnel-allowlist.ps1 [-ExpectWaf] [-BaseUrl https://invoice.mahmud-alhussen.de]   Exit 0 = ok, 1 = problem.
# Two layers, told apart by their answer:
#   WAF       the Cloudflare custom rule m7-invoice-allowlist: 403 with Cloudflare's block page ("Sorry, you have been blocked").
#   tunnel    cloudflared's catch-all in infra/cloudflared.yml: 404 with an EMPTY body. n8n's own 404s have a body, so they never count.
# Default: every probe must be refused by one of the two. -ExpectWaf: every probe must be refused by the WAF (it sits in front, so with the
# rule on, cloudflared never sees them). Control in both modes: a POST with a bad signature reaches the Intake and gets 400.
# Prove it can fail: disable the WAF rule -> -ExpectWaf FAILs while the default still passes (cloudflared alone holds); with the rule
# still off, a catch-all of http_status:200 in the tunnel config -> the default FAILs (docs/evidence.md, M7b-5b).
# curl.exe with --path-as-is, because PowerShell's web cmdlets resolve "/../" before sending and the traversal probes would test nothing.
param(
    [string]$BaseUrl = 'https://invoice.mahmud-alhussen.de',
    [switch]$ExpectWaf
)
$ErrorActionPreference = 'Stop'
$failed = 0
function Write-Step([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { Write-Host "[PASS] $Name" -ForegroundColor Green -NoNewline } else { Write-Host "[FAIL] $Name" -ForegroundColor Red -NoNewline; $script:failed++ }
    if ($Detail) { Write-Host " - $Detail" } else { Write-Host '' }
}

$curl = Join-Path $env:WINDIR 'System32\curl.exe'
$bodyFile = [IO.Path]::GetTempFileName()
# Returns @{ Code; Body; Layer = 'waf' | 'tunnel' | 'other' }.
function Invoke-Probe([string]$Method, [string]$Path, [string[]]$Headers = @()) {
    $a = @('-s', '--path-as-is', '--max-time', '20', '-o', $bodyFile, '-w', '%{http_code}', '-X', $Method)
    foreach ($h in $Headers) { $a += @('-H', $h) }
    if ($Method -eq 'POST') { $a += @('-H', 'Content-Type: application/json', '--data', '{}') }
    $code = "$(& $curl @a "$BaseUrl$Path")".Trim()
    $body = [IO.File]::ReadAllText($bodyFile)
    $layer = 'other'
    if ($code -eq '403' -and $body -match 'Sorry, you have been blocked') { $layer = 'waf' }
    elseif ($code -eq '404' -and $body.Length -eq 0) { $layer = 'tunnel' }
    return @{ Code = $code; Body = $body; Layer = $layer }
}

# Everything n8n or Mailpit would answer, plus traversal and encoding variants of the one allowed path.
$probes = @(
    @('GET', '/'), @('GET', '/signin'), @('GET', '/home/workflows'), @('GET', '/rest/settings'), @('POST', '/rest/login'),
    @('GET', '/api/v1/workflows'), @('POST', '/mcp-server/http'), @('GET', '/healthz'), @('GET', '/metrics'),
    @('POST', '/webhook-test/stripe-intake'), @('POST', '/webhook/other'), @('POST', '/webhook-waiting/1'), @('GET', '/form/x'),
    @('GET', '/api/v1/messages'), @('GET', '/api/v1/info'),
    @('POST', '/webhook/stripe-intake/'), @('POST', '/webhook/stripe-intakex'), @('POST', '/webhook/Stripe-Intake'),
    @('POST', '/webhook/stripe-intake/../../rest/settings'), @('POST', '/webhook/stripe-intake/%2e%2e/%2e%2e/rest/settings'),
    @('POST', '/webhook%2fstripe-intake'), @('POST', '/webhook/stripe-intake%2f..%2f..%2frest%2fsettings')
)
# The allowed path with another method reaches n8n when only cloudflared is in front (it cannot filter methods), so only the WAF refuses it.
if ($ExpectWaf) { $probes += @(@('GET', '/webhook/stripe-intake'), @('PUT', '/webhook/stripe-intake'), @('DELETE', '/webhook/stripe-intake')) }

$want = if ($ExpectWaf) { 'WAF 403' } else { 'WAF 403 or tunnel 404' }
$layers = @{}
try {
    foreach ($p in $probes) {
        $r = Invoke-Probe $p[0] $p[1]
        $ok = if ($ExpectWaf) { $r.Layer -eq 'waf' } else { $r.Layer -in 'waf', 'tunnel' }
        $layers[$r.Layer] = 1 + [int]$layers[$r.Layer]
        Write-Step "$($p[0]) $($p[1]) refused ($want)" $ok "$($r.Code) $($r.Layer)"
    }
    # The control: the allowed request still reaches the Intake, which refuses the signature. A stale t= is fine, the signature fails first.
    $r = Invoke-Probe 'POST' '/webhook/stripe-intake' @('Stripe-Signature: t=1,v1=00')
    Write-Step 'POST /webhook/stripe-intake with a bad signature reaches the Intake and gets 400' ($r.Code -eq '400' -and $r.Body -match 'invalid signature') "$($r.Code) $($r.Body)"
} finally {
    Remove-Item -LiteralPath $bodyFile -ErrorAction SilentlyContinue
}

Write-Host ("answered by: waf={0} tunnel={1} other={2}" -f [int]$layers['waf'], [int]$layers['tunnel'], [int]$layers['other'])
Write-Output ("{0} failed" -f $failed)
if ($failed -gt 0) { exit 1 }
exit 0
