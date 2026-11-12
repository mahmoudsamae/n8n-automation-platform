# Test for scripts\lib\http-reason.ps1, run by e2e: no body text and no IP ever comes out of Get-HttpReason, and n8n's short fields do.
#   powershell -File scripts\lib\http-reason.test.ps1 [-ProveFailure]   Exit 0 = ok, 1 = a case failed.
# -ProveFailure runs the same cases against a stub that returns the body unchanged (what the 2026-11-12 bug did); it must FAIL.
param([switch]$ProveFailure)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\http-reason.ps1"
if ($ProveFailure) { function Get-HttpReason([AllowNull()][string]$Body) { return $Body } }

# 192.0.2.x is a documentation range (RFC 5737): a stand-in for a real caller IP.
$block = '<html><span id="cf-footer-ip">192.0.2.55</span><h1>Sorry, you have been blocked</h1></html>'
$cases = @(
    @{ Name = 'Cloudflare block page'; Body = $block; Want = "<non-JSON body, $($block.Length) characters>" }
    @{ Name = 'empty'; Body = ''; Want = '<empty body>' }
    @{ Name = 'Intake 400'; Body = '{"error": "invalid signature"}'; Want = 'error: invalid signature' }
    @{ Name = 'Intake 200 duplicate'; Body = '{"received":true,"duplicate":true}'; Want = 'received: True, duplicate: True' }
    @{ Name = 'other JSON with an IP'; Body = '{"message":"x","client":"192.0.2.55"}'; Want = '<JSON body without error/received/duplicate, 37 characters>' }
    @{ Name = 'overlong error'; Body = ('{"error":"' + ('x' * 200) + '"}'); Want = 'error: <200 characters>' }
)
$failed = 0
foreach ($c in $cases) {
    $got = Get-HttpReason $c.Body
    $ok = $got -eq $c.Want -and $got -notmatch '192\.0\.2\.|<html|blocked'
    if ($ok) { Write-Host "[PASS] $($c.Name)" -ForegroundColor Green } else { Write-Host "[FAIL] $($c.Name): got $($got.Length) characters, expected '$($c.Want)'" -ForegroundColor Red; $failed++ }
}
Write-Output ("{0} failed" -f $failed)
if ($failed -gt 0) { exit 1 }
exit 0
