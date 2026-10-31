# Proves the M7 server's public IP exposes nothing, from OUTSIDE (a check on the server itself would not count).
# Run with Tailscale off:  powershell -File scripts\check-public-ports.ps1 -Mode Public -Ip <public ip> -Scope Full|Top1000|ControlPort [-Port <n>] -WindowStart <date> -WindowEnd <date> -SourceIp <ip>
# Run with Tailscale on:   powershell -File scripts\check-public-ports.ps1 -Mode Tailnet -Ip <public ip>     (one SSH attempt each way, no nmap)
# Oracle requires a filed testing notification: testing starts 5 business days after submission, at most once per service per calendar year, at most 10 consecutive days,
# non-aggressive (hence the low rate). So -Mode Public refuses to run nmap outside the filed window or from a source IP the form does not list.
# Prove it can fail: inside the window, -Scope ControlPort against a temporary listener reports it open (runbook, Server section). That also proves
# this laptop's network path can see an open port, so "filtered" afterwards means something. Before the Security List rule is deleted, -Mode Tailnet reports public SSH reachable.
# Exit 0 = ok, 1 = problem.
param(
    [Parameter(Mandatory = $true)][ValidateSet('Public', 'Tailnet')][string]$Mode,
    [Parameter(Mandatory = $true)][ValidatePattern('^\d{1,3}(\.\d{1,3}){3}$')][string]$Ip,
    [ValidateSet('Full', 'Top1000', 'ControlPort')][string]$Scope,
    [ValidateRange(1, 65535)][int]$Port,
    [datetime]$WindowStart,
    [datetime]$WindowEnd,
    [ValidatePattern('^\d{1,3}(\.\d{1,3}){3}$')][string]$SourceIp,
    [string]$KeyFile = (Join-Path $HOME '.ssh\oci_m7')
)
$ErrorActionPreference = 'Stop'
$failed = 0
function Write-Step([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { Write-Host "[PASS] $Name" -ForegroundColor Green -NoNewline } else { Write-Host "[FAIL] $Name" -ForegroundColor Red -NoNewline; $script:failed++ }
    if ($Detail) { Write-Host " - $Detail" } else { Write-Host '' }
}
# ssh exit 255 with a timeout means nothing answered. Host key checks are off because this probe only asks whether the port answers.
function Test-PublicSsh {
    $ErrorActionPreference = 'Continue'   # PowerShell 5.1 turns a native command's redirected stderr into errors
    $text = (& ssh -i $KeyFile -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL "ubuntu@$Ip" exit 2>&1 | Out-String)
    return @{ Answered = ($text -notmatch 'timed out|No route to host|Connection refused'); Text = $text }
}
function Get-TailscaleStatus([string]$Exe) {
    $ErrorActionPreference = 'Continue'
    return (& $Exe status 2>&1 | Out-String)
}

if ($Mode -eq 'Tailnet') {
    $null = & "$PSScriptRoot\server-sh.ps1" -Script 'true'
    Write-Step 'SSH to m7-server over Tailscale works' ($LASTEXITCODE -eq 0) "exit $LASTEXITCODE"
    $probe = Test-PublicSsh
    Write-Step 'SSH to the public IP does not answer' (-not $probe.Answered)
    if ($failed -gt 0) { exit 1 }
    exit 0
}

if (-not $Scope) { throw '-Mode Public needs -Scope Full, Top1000 or ControlPort' }
if ($Scope -eq 'ControlPort' -and -not $Port) { throw '-Scope ControlPort needs -Port' }

# Oracle's testing window: nothing below runs without it.
if (-not $WindowStart -or -not $WindowEnd -or -not $SourceIp) { Write-Step 'Oracle testing window given' $false 'needs -WindowStart, -WindowEnd and -SourceIp from the filed form; no nmap was run'; exit 1 }
$now = Get-Date
$inWindow = ($now -ge $WindowStart -and $now -lt $WindowEnd.Date.AddDays(1))
Write-Step 'inside the filed Oracle testing window' $inWindow ("{0:yyyy-MM-dd} to {1:yyyy-MM-dd}" -f $WindowStart, $WindowEnd)
if (-not $inWindow) { Write-Host 'no nmap was run'; exit 1 }
$actualSource = "$(Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 15)".Trim()
Write-Step 'source IP is the one on the form' ($actualSource -eq $SourceIp) $(if ($actualSource -eq $SourceIp) { $SourceIp } else { 'it changed: tell Oracle the new one first; no nmap was run' })
if ($failed -gt 0) { exit 1 }

# Off the tailnet, so this is the view of a stranger.
$tsCmd = Get-Command tailscale -ErrorAction SilentlyContinue
$tsExe = if ($tsCmd) { $tsCmd.Source } else { 'C:\Program Files\Tailscale\tailscale.exe' }
if (Test-Path -LiteralPath $tsExe) {
    $tsText = Get-TailscaleStatus $tsExe
    Write-Step 'laptop is off the tailnet' ($tsText -match 'stopped|not running|Logged out') 'run: tailscale down'
    if ($failed -gt 0) { exit 1 }
} else {
    Write-Step 'laptop is off the tailnet' $true 'tailscale is not installed here'
}

$portArg = switch ($Scope) { 'Full' { '-p-' } 'Top1000' { '--top-ports 1000' } 'ControlPort' { "-p $Port" } }
$expected = switch ($Scope) { 'Full' { 65535 } 'Top1000' { 1000 } 'ControlPort' { 1 } }
$out = @(& "$PSScriptRoot\wsl-sh.ps1" -Script "nmap -Pn -sT --max-rate 100 $portArg -oG - $Ip")
if ($LASTEXITCODE -ne 0) { Write-Step 'nmap ran' $false "exit $LASTEXITCODE"; exit 1 }
$portsLine = @($out | Where-Object { "$_" -match '^Host: .*(Ports|Ignored State):' })
$done = @($out | Where-Object { "$_" -match '^# Nmap done' })
Write-Step 'nmap finished' ($done.Count -eq 1 -and $portsLine.Count -ge 1) ($done -join ' ')

$open = @(); $listed = 0; $ignored = 0
foreach ($line in $portsLine) {
    foreach ($m in [regex]::Matches("$line", '(\d+)/(open|closed|filtered|open\|filtered)/tcp')) {
        $listed++
        if ($m.Groups[2].Value -eq 'open') { $open += $m.Groups[1].Value }
    }
    $mi = [regex]::Match("$line", 'Ignored State: \S+ \((\d+)\)')
    if ($mi.Success) { $ignored = [int]$mi.Groups[1].Value }
}
# A cut-short scan must not look like a clean one.
Write-Step "scan covered $expected TCP ports" (($listed + $ignored) -eq $expected) "$($listed + $ignored) seen"
Write-Step 'no open TCP port on the public IP' ($open.Count -eq 0) $(if ($open.Count) { "OPEN: $($open -join ', ')" } else { "scope $Scope" })

if ($Scope -eq 'ControlPort') { if ($failed -gt 0) { exit 1 }; exit 0 }

$probe = Test-PublicSsh
Write-Step 'SSH to the public IP does not answer' (-not $probe.Answered)

if ($Scope -eq 'Top1000') { Write-Host 'full-port scan: NOT PROVEN (only the top 1000 TCP ports were scanned)' -ForegroundColor Yellow }
Write-Host 'UDP: NOT PROVEN by nmap (it reports open|filtered). The proof is the Security List having no UDP rule.' -ForegroundColor Yellow

if ($failed -gt 0) { exit 1 }
exit 0
