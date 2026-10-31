# Proves the M7 VM is what infra/cloud-init.yaml describes, and that SSH is limited to Tailscale at the OS layer.
# Run: powershell -File scripts\check-server-base.ps1   Exit 0 = ok, 1 = problem.
# Prove it can fail: -CloudInitFile <edited copy>, -ExpectedMemoryGb 12. Before infra/harden-ssh.sh ran, the iptables and sshd lines fail on their own.
param(
    [string]$CloudInitFile = (Join-Path (Split-Path -Parent $PSScriptRoot) 'infra\cloud-init.yaml'),
    [int]$ExpectedOcpus = 1,
    [int]$ExpectedMemoryGb = 6,
    [string]$ExpectedShape = 'VM.Standard.A1.Flex'
)
$ErrorActionPreference = 'Stop'
$failed = 0
function Write-Step([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { Write-Host "[PASS] $Name" -ForegroundColor Green -NoNewline } else { Write-Host "[FAIL] $Name" -ForegroundColor Red -NoNewline; $script:failed++ }
    if ($Detail) { Write-Host " - $Detail" } else { Write-Host '' }
}

# Normalised the same way on both sides: no CR, no trailing newlines, then exactly one. The auth key is swapped back on the server and never leaves it.
$text = ([IO.File]::ReadAllText((Resolve-Path -LiteralPath $CloudInitFile)) -replace "`r", '').TrimEnd("`n") + "`n"
$sha = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash((New-Object Text.UTF8Encoding($false)).GetBytes($text))).Replace('-', '').ToLower()

$sh = @'
imds() { curl -fsS --max-time 10 -H "Authorization: Bearer Oracle" "http://169.254.169.254/opc/v2/instance/$1"; }
echo "cloudinit=$(cloud-init status 2>/dev/null | awk '/^status:/{print $2}')"
echo "arch=$(uname -m)"
meta="$(imds "" | jq -c '{shape, ocpus: .shapeConfig.ocpus, mem: .shapeConfig.memoryInGBs}')"
echo "shape=$(echo "$meta" | jq -r .shape)"
echo "ocpus=$(echo "$meta" | jq -r .ocpus)"
echo "mem=$(echo "$meta" | jq -r .mem)"
normalised="$(imds metadata/user_data | base64 -d | tr -d '\r' | sed -E 's/tskey-[A-Za-z0-9-]+/__TAILSCALE_AUTHKEY__/')"
echo "userdata=$(printf '%s\n' "$normalised" | sha256sum | cut -d' ' -f1)"
echo "docker=$(docker version --format '{{.Server.Version}}' 2>/dev/null)"
echo "tailscale=$(tailscale status --json 2>/dev/null | jq -r .BackendState)"
echo "swap=$(swapon --show=SIZE --noheadings | head -1 | tr -d ' ')"
echo "timezone=$(timedatectl show -p Timezone --value)"
echo "dockerlogs=$(jq -r '.["log-opts"]["max-size"]' /etc/docker/daemon.json 2>/dev/null)"
echo "journald=$(grep -h '^SystemMaxUse=' /etc/systemd/journald.conf.d/m7-limits.conf 2>/dev/null | cut -d= -f2)"
echo "upgrades=$(grep -c 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null)"
echo "upgradesunit=$(systemctl is-enabled unattended-upgrades 2>/dev/null)"
rules22="$(sudo iptables -S INPUT | grep -- '--dport 22' || true)"
echo "ssh22total=$(printf '%s' "$rules22" | grep -c . || true)"
echo "ssh22public=$(printf '%s' "$rules22" | grep -vc -- '-i tailscale0' || true)"
echo "sshpassword=$(sudo sshd -T 2>/dev/null | awk '/^passwordauthentication/{print $2}')"
'@

$out = @(& "$PSScriptRoot\server-sh.ps1" -Script $sh)
if ($LASTEXITCODE -ne 0 -and $out.Count -eq 0) { Write-Step 'server reachable over Tailscale' $false "ssh exit $LASTEXITCODE"; exit 1 }
$v = @{}
foreach ($line in $out) { $i = "$line".IndexOf('='); if ($i -gt 0) { $v["$line".Substring(0, $i)] = "$line".Substring($i + 1).Trim() } }

Write-Step 'cloud-init finished' ($v.cloudinit -eq 'done') $v.cloudinit
Write-Step 'VM user-data equals the repository file' ($v.userdata -eq $sha) (Split-Path -Leaf $CloudInitFile)
Write-Step 'shape' ($v.shape -eq $ExpectedShape) $v.shape
# Compared as numbers: the metadata service says 1.0 and 6.0.
Write-Step 'OCPUs' ([double]$v.ocpus -eq $ExpectedOcpus) $v.ocpus
Write-Step 'memory (GB)' ([double]$v.mem -eq $ExpectedMemoryGb) $v.mem
Write-Step 'architecture aarch64' ($v.arch -eq 'aarch64') $v.arch
Write-Step 'Docker Engine running' ([bool]$v.docker) $v.docker
Write-Step 'Tailscale running' ($v.tailscale -eq 'Running') $v.tailscale
Write-Step 'swap present' ([bool]$v.swap) $v.swap
Write-Step 'timezone Europe/Berlin' ($v.timezone -eq 'Europe/Berlin') $v.timezone
Write-Step 'Docker log limit' ($v.dockerlogs -eq '10m') $v.dockerlogs
Write-Step 'journald limit' ($v.journald -eq '200M') $v.journald
Write-Step 'unattended-upgrades on' ($v.upgrades -eq '1' -and $v.upgradesunit -eq 'enabled') $v.upgradesunit
Write-Step 'iptables: port 22 only on tailscale0' ($v.ssh22total -ne '0' -and $v.ssh22public -eq '0') "$($v.ssh22total) rule(s), $($v.ssh22public) public"
Write-Step 'sshd: password login off' ($v.sshpassword -eq 'no') $v.sshpassword

if ($failed -gt 0) { exit 1 }
exit 0
