# Restores an encrypted offsite backup into the M7 server's Postgres. The server has no private key, so the laptop decrypts and streams over SSH.
# Plaintext only exists in the pipe. Refuses if the server's database already has a stripe_events table: this never overwrites data.
# Run: powershell -File scripts\server-restore.ps1 -File <automation-...dump.age> [-KeyFile <WSL path>]   Exit 0 = restored, 1 = problem.
param(
    [Parameter(Mandatory = $true)][string]$File,
    [string]$KeyFile = '~/.config/age/m7-backup.key',
    [string]$Target = 'ubuntu@m7-server',
    [string]$SshKey = (Join-Path $HOME '.ssh\oci_m7')
)
$ErrorActionPreference = 'Stop'
$full = (Resolve-Path -LiteralPath $File).Path
# These go inside single-quoted bash strings below.
if ($full -match "'" -or $SshKey -match "'" -or $KeyFile -match "'") { throw 'paths must not contain a single quote' }
$winPath = $full -replace '\\', '/'

# Windows ssh.exe from inside WSL: it has the laptop's Tailscale and ssh-agent, and a WSL pipe is binary-safe (PowerShell 5.1's is not).
$sh = @"
set -euo pipefail
file="`$(wslpath -u '$winPath')"
key=$($KeyFile -replace '^~', '"$HOME"')
remote() { /mnt/c/Windows/System32/OpenSSH/ssh.exe -i '$SshKey' -o BatchMode=yes -o ConnectTimeout=15 '$Target' "`$@"; }
empty="`$(echo "select to_regclass('public.stripe_events') is null;" | remote 'docker exec -i postgres psql -U automation -d automation -tA' | tr -d '\r')"
if [ "`$empty" != "t" ]; then echo "[FAIL] the server's database is not empty (or not reachable), refusing to restore" >&2; exit 1; fi
age -d -i "`$key" "`$file" | remote 'docker exec -i postgres pg_restore -U automation -d automation --no-owner --exit-on-error'
echo "[PASS] restored `$(basename "`$file")"
"@
& "$PSScriptRoot\wsl-sh.ps1" -Script $sh
exit $LASTEXITCODE
