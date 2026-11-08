# Proves containers on the M7 server cannot reach the instance metadata service (169.254.169.254), while DNS and outbound HTTPS still work.
# Run: powershell -File scripts\check-imds-blocked.ps1   Exit 0 = blocked, 1 = reachable or a control failed.
# Tests from the n8n container, from a throwaway container on the stack network and from one on Docker's default bridge. The host itself must still reach it (Oracle Cloud Agent).
# Prove it can fail (owner approves): sudo iptables -D DOCKER-USER -j M7-IMDS, run this (expect FAIL, exit 1), then sudo systemctl restart docker-imds-block and run it again.
$ErrorActionPreference = 'Stop'
$failed = 0
function Write-Step([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { Write-Host "[PASS] $Name" -ForegroundColor Green -NoNewline } else { Write-Host "[FAIL] $Name" -ForegroundColor Red -NoNewline; $script:failed++ }
    if ($Detail) { Write-Host " - $Detail" } else { Write-Host '' }
}

# Each probe prints one key=value line. "reachable" means any HTTP answer came back; the metadata body is never printed.
$sh = @'
v1=http://169.254.169.254/opc/v1/instance/
v2=http://169.254.169.254/opc/v2/instance/
probe() { if "$@" >/dev/null 2>&1; then echo reachable; else echo blocked; fi; }
echo "n8n_v1=$(probe docker exec n8n wget -q -T 5 -O - $v1)"
echo "n8n_v2=$(probe docker exec n8n wget -q -T 5 -O - --header 'Authorization: Bearer Oracle' $v2)"
img=postgres:17.11-alpine
echo "stacknet_v2=$(probe docker run --rm --network m7_default --entrypoint wget $img -q -T 5 -O - --header 'Authorization: Bearer Oracle' $v2)"
echo "bridge_v2=$(probe docker run --rm --network bridge --entrypoint wget $img -q -T 5 -O - --header 'Authorization: Bearer Oracle' $v2)"
echo "host_v2=$(probe curl -s -f -m 5 -o /dev/null -H 'Authorization: Bearer Oracle' $v2)"
echo "n8n_dns=$(probe docker exec n8n node -e "require('dns').lookup('api.telegram.org', (e) => process.exit(e ? 1 : 0))")"
echo "stacknet_dns=$(probe docker run --rm --network m7_default --entrypoint nslookup $img api.telegram.org)"
echo "n8n_https=$(probe docker exec n8n node -e "fetch('https://api.telegram.org', { signal: AbortSignal.timeout(8000) }).then(() => process.exit(0), () => process.exit(1))")"
if sudo iptables -w -C DOCKER-USER -j M7-IMDS 2>/dev/null; then echo hook=yes; else echo hook=no; fi
echo "unit_enabled=$(systemctl is-enabled docker-imds-block.service 2>&1)"
'@
$out = @(& "$PSScriptRoot\server-sh.ps1" -Script $sh)
if ($LASTEXITCODE -ne 0) { Write-Step 'server reachable over Tailscale' $false "exit $LASTEXITCODE"; exit 1 }
$r = @{}
foreach ($line in $out) { $p = "$line" -split '=', 2; if ($p.Count -eq 2) { $r[$p[0].Trim()] = $p[1].Trim() } }

Write-Step 'n8n container: metadata v1 blocked' ($r['n8n_v1'] -eq 'blocked') $r['n8n_v1']
Write-Step 'n8n container: metadata v2 (with the Oracle header) blocked' ($r['n8n_v2'] -eq 'blocked') $r['n8n_v2']
Write-Step 'throwaway container on m7_default: metadata blocked' ($r['stacknet_v2'] -eq 'blocked') $r['stacknet_v2']
Write-Step 'throwaway container on the default bridge: metadata blocked' ($r['bridge_v2'] -eq 'blocked') $r['bridge_v2']
# Controls: without them a broken network would look like a working block.
Write-Step 'control: the host still reaches the metadata service' ($r['host_v2'] -eq 'reachable') $r['host_v2']
Write-Step 'control: n8n resolves api.telegram.org' ($r['n8n_dns'] -eq 'reachable') $r['n8n_dns']
Write-Step 'control: a container on m7_default resolves api.telegram.org' ($r['stacknet_dns'] -eq 'reachable') $r['stacknet_dns']
Write-Step 'control: n8n reaches https://api.telegram.org' ($r['n8n_https'] -eq 'reachable') $r['n8n_https']
Write-Step 'M7-IMDS chain hooked into DOCKER-USER' ($r['hook'] -eq 'yes') $r['hook']
Write-Step 'docker-imds-block.service enabled' ($r['unit_enabled'] -eq 'enabled') $r['unit_enabled']

Write-Host ("{0} failed" -f $failed)
if ($failed -gt 0) { exit 1 }
exit 0
