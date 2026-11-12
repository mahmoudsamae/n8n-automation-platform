# The ONE way a script describes an HTTP response body: a short reason, never the body itself. Dot-source it:
#   . "$PSScriptRoot\lib\http-reason.ps1";  "$code $(Get-HttpReason $body)"
# Why: a raw body can carry data that must not reach the terminal or a log. Cloudflare's block page holds the caller's public IP (a check
# printed the owner's home IP on 2026-11-12: docs/evidence.md, "Raw response body printed"); an n8n reply can echo request data.
# JSON: only the Intake's own short fields (error, received, duplicate), each value cut to 60 characters. Anything else: its length only.
function Get-HttpReason([AllowNull()][string]$Body) {
    if ([string]::IsNullOrEmpty($Body)) { return '<empty body>' }
    try { $j = $Body | ConvertFrom-Json } catch { return "<non-JSON body, $($Body.Length) characters>" }
    $parts = @(foreach ($k in 'error', 'received', 'duplicate') {
        if ($j -is [pscustomobject] -and $j.PSObject.Properties.Name -contains $k) {
            $v = "$($j.$k)"; if ($v.Length -gt 60) { $v = "<$($v.Length) characters>" }
            "${k}: $v"
        }
    })
    if ($parts.Count) { return ($parts -join ', ') }
    return "<JSON body without error/received/duplicate, $($Body.Length) characters>"
}
