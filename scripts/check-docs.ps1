# Fails on doc rot that no other check sees: CLAUDE.md over its length limit, or a relative link or image in the README or docs/*.md
# that points at a file which does not exist.
# Files that are referenced but not there yet can be listed in -KnownMissing (empty today): they print as WARN and do not fail.
# The list cleans itself: once such a file exists, the check FAILS until it is removed from the list.
# Also fails on any public IPv4 address in a tracked file (docs write `<public-ip>`; the M7 server's and the owner's home IP must never be in git).
# Allowed: private, loopback, link-local (the metadata service), Tailscale's 100.64.0.0/10, 0.0.0.0 and the documentation ranges 192.0.2/24,
# 198.51.100/24, 203.0.113/24. A version string that looks like an address goes in -AllowedIps. Hits print masked (a.x.x.x), never in full.
# Run: powershell -File scripts\check-docs.ps1 [-Root <repo>] [-MaxClaudeLines 100]   Exit 0 = ok, 1 = problem.
# Prove the IP check can fail: -ExtraFile <file holding a public address> FAILS; the same file with 192.0.2.5 passes.
param(
    [string]$Root = (Split-Path -Parent $PSScriptRoot),
    [int]$MaxClaudeLines = 100,
    [string[]]$KnownMissing = @(),
    [string[]]$AllowedIps = @(),
    [string]$ExtraFile
)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$failed = 0
# GetFullPath expands 8.3 names (MAHMUD~1) in the link targets below; use the same form of the root for the relative display.
$rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')

$claude = Join-Path $Root 'CLAUDE.md'
$lines = @([IO.File]::ReadAllLines($claude, $utf8)).Count
if ($lines -le $MaxClaudeLines) { Write-Host "[PASS] CLAUDE.md has $lines lines (limit $MaxClaudeLines)" -ForegroundColor Green }
else { Write-Host "[FAIL] CLAUDE.md has $lines lines, limit is $MaxClaudeLines" -ForegroundColor Red; $failed++ }

# Paths are built from $Root only (Get-ChildItem FullName can switch between 8.3 and long names, which breaks the relative display below).
$files = @(Join-Path $Root 'README.md') + @(Get-ChildItem -Path (Join-Path $Root 'docs') -Filter '*.md' -File | ForEach-Object { Join-Path $Root (Join-Path 'docs' $_.Name) })
$checked = 0
$missing = @{}
foreach ($f in $files) {
    $dir = Split-Path -Parent $f
    $text = [IO.File]::ReadAllText($f, $utf8)
    # [text](target) and ![alt](target); skip absolute URLs, mailto and pure anchors; drop #anchor and "title"
    foreach ($m in [regex]::Matches($text, '!?\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)')) {
        $t = $m.Groups[1].Value
        if ($t -match '^(https?:|mailto:|#)') { continue }
        $t = ($t -split '#')[0]
        if (-not $t) { continue }
        $checked++
        $full = [IO.Path]::GetFullPath((Join-Path $dir $t))
        if (-not (Test-Path -LiteralPath $full)) {
            $rel = $full.Substring($rootFull.Length + 1).Replace('\', '/')
            $missing[$rel] = $true
            if ($KnownMissing -notcontains $rel) {
                Write-Host ("[FAIL] {0} links to {1}, which does not exist" -f ([IO.Path]::GetFullPath($f).Substring($rootFull.Length + 1).Replace('\', '/')), $rel) -ForegroundColor Red
                $failed++
            }
        }
    }
}
Write-Host "checked $checked relative links in $($files.Count) files"
foreach ($k in $KnownMissing) {
    if ($missing.ContainsKey($k)) { Write-Host "[WARN] known missing, owner has to add it: $k" -ForegroundColor Yellow }
    elseif (-not (Test-Path -LiteralPath (Join-Path $Root $k))) { Write-Host "[FAIL] $k is in -KnownMissing but nothing links to it and it does not exist: remove it from the list" -ForegroundColor Red; $failed++ }
    else { Write-Host "[FAIL] $k now exists: remove it from -KnownMissing in scripts\check-docs.ps1" -ForegroundColor Red; $failed++ }
}
if ($failed -eq 0) { Write-Host '[PASS] every relative link and image resolves (known-missing files aside)' -ForegroundColor Green }

function Test-PublicIp([string]$Ip) {
    $o = @($Ip.Split('.') | ForEach-Object { [int]$_ })
    if (@($o | Where-Object { $_ -gt 255 }).Count) { return $false }   # 1.2.3.999 is not an address
    if ($AllowedIps -contains $Ip) { return $false }
    $private = $o[0] -eq 10 -or $o[0] -eq 127 -or $Ip -eq '0.0.0.0' -or
        ($o[0] -eq 172 -and $o[1] -ge 16 -and $o[1] -le 31) -or ($o[0] -eq 192 -and $o[1] -eq 168) -or
        ($o[0] -eq 169 -and $o[1] -eq 254) -or ($o[0] -eq 100 -and $o[1] -ge 64 -and $o[1] -le 127) -or
        ($o[0] -eq 192 -and $o[1] -eq 0 -and $o[2] -eq 2) -or ($o[0] -eq 198 -and $o[1] -eq 51 -and $o[2] -eq 100) -or ($o[0] -eq 203 -and $o[1] -eq 0 -and $o[2] -eq 113)
    return -not $private
}
# git grep -I: tracked text files only. Each line is file:line:text.
$ipLines = @(git -C $Root grep -I -n -E '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
if ($LASTEXITCODE -gt 1) { Write-Host "[FAIL] git grep failed in $Root (exit $LASTEXITCODE); is it a git checkout?" -ForegroundColor Red; $failed++ }
if ($ExtraFile) { $n = 0; $ipLines += @([IO.File]::ReadAllLines($ExtraFile, $utf8) | ForEach-Object { $n++; "$ExtraFile`:$n`:$_" }) }
$ipHits = 0
foreach ($l in $ipLines) {
    # the location is printed, never the text
    $loc = ($l -split ':', 3)[0..1] -join ':'
    if ($l -match '^[A-Za-z]:\\') { $loc = ($l -split ':', 4)[0..2] -join ':' }   # -ExtraFile with a drive letter
    foreach ($m in [regex]::Matches($l, '(?<![\d.])(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})(?!\.?\d)')) {
        if (Test-PublicIp $m.Groups[1].Value) {
            Write-Host ("[FAIL] public IPv4 {0}.x.x.x in {1} (write <public-ip>, or add a version string to -AllowedIps)" -f $m.Groups[1].Value.Split('.')[0], $loc) -ForegroundColor Red
            $ipHits++; $failed++
        }
    }
}
if ($ipHits -eq 0) { Write-Host "[PASS] no public IPv4 address in tracked files ($($ipLines.Count) lines with a dotted quad checked)" -ForegroundColor Green }
if ($failed -gt 0) { exit 1 }
exit 0
