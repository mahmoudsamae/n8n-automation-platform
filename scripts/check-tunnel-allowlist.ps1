# Proves from OUTSIDE that the public hostname serves only POST /webhook/stripe-intake (M7b-5b). Run it from the laptop, not the server.
# Run: powershell -File scripts\check-tunnel-allowlist.ps1 [-ExpectWaf] [-BaseUrl https://invoice.mahmud-alhussen.de]   Exit 0 = ok, 1 = problem.
# Two layers, told apart by their answer:
#   WAF       the Cloudflare custom rule m7-invoice-allowlist: 403 with Cloudflare's block page ("Sorry, you have been blocked").
#   tunnel    cloudflared's catch-all in infra/cloudflared.yml: 404 with an EMPTY body. n8n's own 404s have a body, so they never count.
# Default: every probe must be refused by one of the two. -ExpectWaf: every probe must be refused by the WAF (it sits in front, so with the
# rule on, cloudflared never sees them). Control in both modes: a POST with a bad signature reaches the Intake and gets 400.
# Known gap of cloudflared alone (found in M7b-5b): it matches its path regex against the DECODED path, so an encoded alias of the allowed
# path (/webhook%2fstripe-intake, /%77ebhook/stripe-intake) reaches n8n, which routes on the raw path: 404 for POST, the editor's static
# shell for GET (no data: its assets, /rest and login are refused). Only the WAF refuses those, so they count only with -ExpectWaf
# (what e2e runs) and print as WARN in the default mode.
# Prove it can fail: disable the WAF rule -> -ExpectWaf FAILs while the default still passes (cloudflared alone holds); with the rule
# still off, a catch-all of http_status:200 in the tunnel config -> the default FAILs (docs/evidence.md, M7b-5b).
# curl.exe with --path-as-is, because PowerShell's web cmdlets resolve "/../" before sending and the traversal probes would test nothing.
# -Demo (M7c): Closed = the WAF rule m7-demo-closed is on, so every demo page and API path must be refused like everything else. Open = the
# rule is off: the pages and assets answer 200 from demo-web, POST /api/demo/result with an empty body reaches n8n through Caddy (404
# not_found), and only those. In both modes the n8n demo webhooks called directly, other methods, unlisted files and aliases stay refused.
# Prove it can fail: -Demo Open while the rule is on (pages are 403), and -Demo Closed with the rule off (pages are 200).
param(
    [string]$BaseUrl = 'https://invoice.mahmud-alhussen.de',
    [switch]$ExpectWaf,
    [ValidateSet('Closed', 'Open')][string]$Demo = 'Closed'
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\http-reason.ps1"
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
    @('GET', '/signin'), @('GET', '/home/workflows'), @('GET', '/rest/settings'), @('POST', '/rest/login'),
    @('GET', '/api/v1/workflows'), @('POST', '/mcp-server/http'), @('GET', '/healthz'), @('GET', '/metrics'),
    @('POST', '/webhook-test/stripe-intake'), @('POST', '/webhook/other'), @('POST', '/webhook-waiting/1'), @('GET', '/form/x'),
    @('GET', '/api/v1/messages'), @('GET', '/api/v1/info'),
    @('POST', '/webhook/stripe-intake/'), @('POST', '/webhook/stripe-intakex'), @('POST', '/webhook/Stripe-Intake'),
    @('POST', '/webhook/stripe-intake/../../rest/settings'), @('POST', '/webhook/stripe-intake/%2e%2e/%2e%2e/rest/settings'),
    @('POST', '/webhook/stripe-intake%2f..%2f..%2frest%2fsettings')
)
$aliases = @(@('POST', '/webhook%2fstripe-intake'), @('GET', '/webhook%2fstripe-intake'), @('GET', '/%77ebhook/stripe-intake'),
    @('POST', '/%77ebhook/demo-result'), @('POST', '/webhook%2fdemo-checkout'))
# The allowed path with another method reaches n8n when only cloudflared is in front (it cannot filter methods), so only the WAF refuses it.
if ($ExpectWaf) { $probes += @(@('GET', '/webhook/stripe-intake'), @('PUT', '/webhook/stripe-intake'), @('DELETE', '/webhook/stripe-intake')) }
# Demo paths that are never served, open or closed: n8n's demo webhooks directly, the pages' files by name, unlisted files, other methods.
$probes += @(
    @('POST', '/webhook/demo-checkout'), @('POST', '/webhook/demo-result'), @('GET', '/index.html'), @('GET', '/r.html'),
    @('GET', '/assets/x.html'), @('GET', '/assets/../index.html'), @('POST', '/api/demo/other'), @('GET', '/api/demo/result'),
    @('POST', '/api/demo/result/'), @('PUT', '/api/demo/checkout'), @('POST', '/impressum')
)
# The demo surface. Closed: refused like everything else. Open: checked below for the right answer.
$demoPages = @(@('/', 'Demo-Zahlung starten'), @('/r', 'Ihr Demo-Ergebnis'), @('/impressum', 'Impressum'), @('/datenschutz', 'Datenschutz'),
    @('/assets/style.css', '--accent'), @('/assets/start.js', '/api/demo/checkout'), @('/assets/result.js', '/api/demo/result'))
if ($Demo -eq 'Closed') {
    $probes += @($demoPages | ForEach-Object { , @('GET', $_[0]) })
    $probes += @(@('POST', '/api/demo/checkout'), @('POST', '/api/demo/result'))
}

$want = if ($ExpectWaf) { 'WAF 403' } else { 'WAF 403 or tunnel 404' }
$layers = @{}
try {
    foreach ($p in $probes) {
        $r = Invoke-Probe $p[0] $p[1]
        $ok = if ($ExpectWaf) { $r.Layer -eq 'waf' } else { $r.Layer -in 'waf', 'tunnel' }
        $layers[$r.Layer] = 1 + [int]$layers[$r.Layer]
        Write-Step "$($p[0]) $($p[1]) refused ($want)" $ok "$($r.Code) $($r.Layer)"
    }
    foreach ($p in $aliases) {
        $r = Invoke-Probe $p[0] $p[1]
        $layers[$r.Layer] = 1 + [int]$layers[$r.Layer]
        if ($ExpectWaf -or $r.Layer -eq 'waf') { Write-Step "$($p[0]) $($p[1]) (encoded alias) refused (WAF 403)" ($r.Layer -eq 'waf') "$($r.Code) $($r.Layer)" }
        else { Write-Host "[WARN] $($p[0]) $($p[1]) (encoded alias) reaches n8n without the WAF - $($r.Code) $($r.Layer), known gap, not counted" -ForegroundColor Yellow }
    }
    if ($Demo -eq 'Open') {
        foreach ($p in $demoPages) {
            $r = Invoke-Probe 'GET' $p[0]
            Write-Step "GET $($p[0]) is served by demo-web (200, expected content)" ($r.Code -eq '200' -and $r.Body.Contains($p[1])) "$($r.Code) $($r.Layer)"
        }
        # An empty body is not a valid token request: n8n's Demo Result answers 404 not_found, so this proves the proxy path without
        # creating anything. POST /api/demo/checkout is never probed here: it would create a real Stripe session and use up the daily cap.
        $r = Invoke-Probe 'POST' '/api/demo/result'
        Write-Step 'POST /api/demo/result reaches Demo Result through demo-web (404 not_found)' ($r.Code -eq '404' -and $r.Body -match '"not_found"') "$($r.Code) $(Get-HttpReason $r.Body)"
    }
    # The control: the allowed request still reaches the Intake, which refuses the signature. A stale t= is fine, the signature fails first.
    $r = Invoke-Probe 'POST' '/webhook/stripe-intake' @('Stripe-Signature: t=1,v1=00')
    Write-Step 'POST /webhook/stripe-intake with a bad signature reaches the Intake and gets 400' ($r.Code -eq '400' -and $r.Body -match 'invalid signature') "$($r.Code) $(Get-HttpReason $r.Body)"
} finally {
    Remove-Item -LiteralPath $bodyFile -ErrorAction SilentlyContinue
}

Write-Host ("answered by: waf={0} tunnel={1} other={2}" -f [int]$layers['waf'], [int]$layers['tunnel'], [int]$layers['other'])
Write-Output ("{0} failed" -f $failed)
if ($failed -gt 0) { exit 1 }
exit 0
