# Proves an encrypted backup downloaded from the bucket really restores, without touching the server's database.
# Decrypts in WSL and restores into a throwaway container with NO network (same pattern as restore-check.ps1), then compares row counts with the server.
# Also checks on the server: the upload URL cannot read, no private key, no plaintext dump, timer active.
# Run: powershell -File scripts\check-offsite-restore.ps1 -File <automation-...dump.age> [-KeyFile <WSL path>]   Exit 0 = restore works and matches, 1 = problem.
# Prove it can fail: a copy with one byte flipped, a wrong -KeyFile, a row added after the dump. An empty server database fails the count comparison too.
param(
    [Parameter(Mandatory = $true)][string]$File,
    [string]$KeyFile = '~/.config/age/m7-backup.key'
)
$ErrorActionPreference = 'Stop'

$Name = 'pg-offsite-restore-check'
$Db = 'restorecheck'
$Image = 'postgres:17.11-alpine'
$CountsSql = "select (select count(*) from stripe_events) || ',' || (select count(*) from side_effects) || ',' || (select count(*) from invoices) || ',' || (select count(*) from event_replays) || ',' || (select last_value || '/' || is_called from invoice_number_seq);"
$Labels = 'stripe_events', 'side_effects', 'invoices', 'event_replays', 'invoice_number_seq'

$script:failed = $false
function Write-Step([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { Write-Host "[PASS] $Name" -ForegroundColor Green -NoNewline } else { Write-Host "[FAIL] $Name" -ForegroundColor Red -NoNewline; $script:failed = $true }
    if ($Detail) { Write-Host " - $Detail" } else { Write-Host '' }
}

$full = (Resolve-Path -LiteralPath $File).Path
if ($full -match "'" -or $KeyFile -match "'") { throw 'paths must not contain a single quote' }
$winPath = $full -replace '\\', '/'
$keyExpr = $KeyFile -replace '^~', '"$HOME"'

try {
    $sh = @"
set -euo pipefail
file="`$(wslpath -u '$winPath')"
key=$keyExpr
echo "header=`$(head -c 21 "`$file")"
docker rm -f $Name >/dev/null 2>&1 || true
docker run -d --rm --name $Name --network none -e POSTGRES_HOST_AUTH_METHOD=trust $Image >/dev/null
for i in `$(seq 1 30); do docker exec $Name pg_isready -q -h localhost -U postgres && break; sleep 2; done
docker exec $Name pg_isready -q -h localhost -U postgres
docker exec $Name createdb -h localhost -U postgres $Db
age -d -i "`$key" "`$file" | docker exec -i $Name pg_restore -h localhost -U postgres -d $Db --no-owner --exit-on-error
echo "restored=yes"
echo "counts=`$(docker exec $Name psql -h localhost -U postgres -d $Db -tAc "$CountsSql")"
"@
    $out = @(& "$PSScriptRoot\wsl-sh.ps1" -Script $sh)
    $code = $LASTEXITCODE
    $header = ("$(@($out | Where-Object { "$_" -like 'header=*' }))" -replace '^header=', '')
    Write-Step 'file is age-encrypted' ($header -eq 'age-encryption.org/v1') $header
    $restored = (@($out | Where-Object { "$_" -eq 'restored=yes' }).Count -eq 1)
    Write-Step 'decrypted and restored into a no-network throwaway' ($restored -and $code -eq 0) "exit $code"
    if (-not $restored) { throw 'decrypt or restore failed' }
    $restoredCounts = ("$(@($out | Where-Object { "$_" -like 'counts=*' }))" -replace '^counts=', '') -split ','

    $b64Sql = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($CountsSql))
    $remote = @(& "$PSScriptRoot\server-sh.ps1" -Script "echo $b64Sql | base64 -d | docker exec -i postgres psql -U automation -d automation -tA")
    if ($LASTEXITCODE -ne 0) { throw 'could not read the counts from the server (empty database?)' }
    $liveCounts = ("$(@($remote | Where-Object { "$_".Trim() }))".Trim()) -split ','
    for ($i = 0; $i -lt $Labels.Count; $i++) {
        Write-Step ("{0}: restored matches server" -f $Labels[$i]) ($liveCounts[$i] -eq $restoredCounts[$i]) ("server={0} restored={1}" -f $liveCounts[$i], $restoredCounts[$i])
    }

    # The URL is read inside the server script and only the HTTP code leaves it.
    # The GET asks for the REAL object: a 404 for a made-up name would prove nothing, because a readable URL returns 404 for that too.
    $objectName = Split-Path -Leaf $full
    if ($objectName -notmatch '^automation-\d{8}T\d{6}Z\.dump\.age$') { throw "keep the file's bucket name, got: $objectName" }
    # The regex needs real key characters, so it cannot match its own text in the clone of this repository.
    $serverSh = @'
url="$(grep -m1 '^BACKUP_PAR_URL=' ~/n8n-workflows/.env | cut -d= -f2-)"
echo "parget=$(printf 'url = "%s__OBJECT__"\n' "$url" | curl --config - -s -o /dev/null -w '%{http_code}' --max-time 20)"
echo "parlist=$(printf 'url = "%s"\n' "$url" | curl --config - -s -o /dev/null -w '%{http_code}' --max-time 20)"
echo "keys=$(sudo find / -xdev -type f \( -name '*.agekey' -o -name 'm7-backup.key' \) 2>/dev/null | wc -l)"
echo "agesecret=$(sudo grep -rlE 'AGE-SECRET-KEY-1[A-Z0-9]{50,}' /home /root /etc 2>/dev/null | wc -l)"
echo "dumps=$(sudo find / -xdev -type f \( -name '*.dump' -o -name 'automation-*.tmp' \) 2>/dev/null | wc -l)"
echo "timer=$(systemctl is-active backup-offsite.timer)"
'@
    $sv = @(& "$PSScriptRoot\server-sh.ps1" -Script ($serverSh -replace '__OBJECT__', $objectName))
    $v = @{}
    foreach ($line in $sv) { $j = "$line".IndexOf('='); if ($j -gt 0) { $v["$line".Substring(0, $j)] = "$line".Substring($j + 1).Trim() } }
    Write-Step 'upload URL cannot read an object' ($v.parget -match '^4') "HTTP $($v.parget)"
    Write-Step 'upload URL cannot list the bucket' ($v.parlist -match '^4') "HTTP $($v.parlist)"
    Write-Step 'no age private key on the server' ($v.keys -eq '0' -and $v.agesecret -eq '0') "$($v.keys) key files, $($v.agesecret) files with key text"
    Write-Step 'no plaintext dump on the server disk' ($v.dumps -eq '0') "$($v.dumps) found"
    Write-Step 'backup timer active' ($v.timer -eq 'active') $v.timer
}
catch {
    Write-Step 'offsite restore check aborted' $false $_.Exception.Message
}
finally {
    $null = & "$PSScriptRoot\wsl-sh.ps1" -Script "docker rm -f $Name >/dev/null 2>&1 || true"
}

if ($script:failed) { exit 1 }
exit 0
