# Proves the M7 stack follows its rules: compose file (no ports, pinned images, memory limits) and the live containers on the server.
# Records memory for the evidence: docker stats and free -m.
# Run: powershell -File scripts\check-prod-stack.ps1 [-StaticOnly] [-ComposeFile <copy>]   Exit 0 = ok, 1 = problem.
# Prove it can fail: -StaticOnly -ComposeFile <copy with ports:, :latest or no mem_limit>. Live: start a throwaway container with a published 127.0.0.1 port.
param(
    [string]$ComposeFile = (Join-Path (Split-Path -Parent $PSScriptRoot) 'docker-compose.prod.yml'),
    [switch]$StaticOnly
)
$ErrorActionPreference = 'Stop'
$failed = 0
function Write-Step([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { Write-Host "[PASS] $Name" -ForegroundColor Green -NoNewline } else { Write-Host "[FAIL] $Name" -ForegroundColor Red -NoNewline; $script:failed++ }
    if ($Detail) { Write-Host " - $Detail" } else { Write-Host '' }
}

# Static: comments dropped, so a rule explained in a comment cannot trip or satisfy a check.
$lines = @([IO.File]::ReadAllLines((Resolve-Path -LiteralPath $ComposeFile)) | ForEach-Object { $_ -replace '^\s*#.*$', '' })
$portLines = @($lines | Where-Object { $_ -match '^\s+ports\s*:' })
Write-Step 'compose: no ports section' ($portLines.Count -eq 0) "$($portLines.Count) found"
$images = @($lines | Where-Object { $_ -match '^\s+image\s*:' } | ForEach-Object { ($_ -split 'image\s*:', 2)[1].Trim() })
$unpinned = @($images | Where-Object { $_ -notmatch ':[^/:]+$' -or $_ -match ':latest$' -or $_ -match ':\d+(-[a-z]+)?$' })
Write-Step 'compose: every image pinned to a version' ($images.Count -gt 0 -and $unpinned.Count -eq 0) $(if ($unpinned.Count) { $unpinned -join ', ' } else { "$($images.Count) images" })
$limits = @($lines | Where-Object { $_ -match '^\s+mem_limit\s*:' })
Write-Step 'compose: mem_limit on every service' ($limits.Count -eq $images.Count) "$($limits.Count) of $($images.Count)"
if ($StaticOnly) { if ($failed -gt 0) { exit 1 }; exit 0 }

$sh = @'
for c in $(docker ps -aq); do
  docker inspect --format '{{.Name}}|{{.State.Status}}|{{.Config.Image}}|{{json .HostConfig.PortBindings}}|{{.HostConfig.Memory}}' "$c" | sed 's/^\///'
done | sed 's/^/container=/'
for i in $(docker ps --format '{{.Image}}' | sort -u); do
  echo "imagearch=$i|$(docker image inspect --format '{{.Architecture}}' "$i")"
done
ss -H -tln | awk '{print "listen=" $4}'
echo '--- memory'
docker stats --no-stream --format 'table {{.Name}}\t{{.MemUsage}}\t{{.CPUPerc}}'
free -m
'@
$out = @(& "$PSScriptRoot\server-sh.ps1" -Script $sh)
if ($LASTEXITCODE -ne 0) { Write-Step 'server reachable over Tailscale' $false "exit $LASTEXITCODE"; exit 1 }

$expected = 'n8n', 'postgres', 'mailpit', 'gotenberg'
$containers = @($out | Where-Object { "$_" -like 'container=*' } | ForEach-Object {
    $p = "$_".Substring(10) -split '\|'
    [pscustomobject]@{ Name = $p[0]; Status = $p[1]; Image = $p[2]; Ports = $p[3]; Memory = $p[4] }
})
foreach ($name in $expected) {
    $c = @($containers | Where-Object { $_.Name -eq $name })
    Write-Step "$name running" ($c.Count -eq 1 -and $c[0].Status -eq 'running') $(if ($c.Count) { $c[0].Image } else { 'not found' })
}
# Every container, not only the expected ones: a stray container with a published port is exactly what this must catch.
$published = @($containers | Where-Object { $_.Ports -notin 'null', '{}' })
Write-Step 'no container publishes a port' ($published.Count -eq 0) $(if ($published.Count) { ($published | ForEach-Object { $_.Name }) -join ', ' } else { "$($containers.Count) containers" })
$noLimit = @($containers | Where-Object { $_.Memory -eq '0' })
Write-Step 'every container has a memory limit' ($noLimit.Count -eq 0) $(if ($noLimit.Count) { ($noLimit | ForEach-Object { $_.Name }) -join ', ' })
$badImage = @($containers | Where-Object { $_.Image -notmatch ':[^/:]+$' -or $_.Image -match ':latest$' })
Write-Step 'every running image is pinned' ($badImage.Count -eq 0) $(if ($badImage.Count) { ($badImage | ForEach-Object { $_.Image }) -join ', ' })
$arches = @($out | Where-Object { "$_" -like 'imagearch=*' })
$notArm = @($arches | Where-Object { "$_" -notmatch '\|arm64$' })
Write-Step 'every image is arm64' ($arches.Count -gt 0 -and $notArm.Count -eq 0) $(if ($notArm.Count) { $notArm -join ', ' })

# Allowed on all addresses: sshd only (the Security List and iptables close it). Loopback and Tailscale addresses are not public.
$listen = @($out | Where-Object { "$_" -like 'listen=*' } | ForEach-Object { "$_".Substring(7) })
$unexpected = @($listen | Where-Object { $_ -notmatch '^(127\.|\[::1\]|100\.|\[fd7a:)' -and $_ -notin '0.0.0.0:22', '[::]:22', '*:22' })
Write-Step 'nothing unexpected listens on a public address' ($unexpected.Count -eq 0) $(if ($unexpected.Count) { $unexpected -join ', ' } else { "$($listen.Count) sockets" })

$i = [array]::IndexOf($out, '--- memory')
if ($i -ge 0) { $out[$i..($out.Count - 1)] | ForEach-Object { Write-Host "$_" } }

if ($failed -gt 0) { exit 1 }
exit 0
