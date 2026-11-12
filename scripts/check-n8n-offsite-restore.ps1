# Proves the encrypted n8n backup (n8n-<UTC>.tar.age from the bucket, M7b-6) restores, without touching the server's n8n.
# Decrypts in WSL into a RAM directory and restores it TWICE, each into a fresh throwaway n8n 2.45.6 with NO network and its database on tmpfs:
#   entities: import:entities (entities.zip)  = the complete restore, the only one that brings the data tables back
#   json:     import:workflow + import:credentials (workflows.json, credentials.json) = the simple path, as import-workflows.ps1 uses
# Checks in each: the 7 workflows with the expected errorWorkflow (scripts\lib\workflows.ps1), the server's credential names and types,
# every credential decrypts with the server's N8N_ENCRYPTION_KEY; entities also: stripe_config and stripe_heartbeat with 1 row and their columns.
# "Decrypts" is tested with export:credentials --decrypted INSIDE the throwaway, into its /dev/shm, and only yes/no leaves it (owner decision
# 2026-11-12). Never prints a credential, a data table value or the key. Plaintext lives only in /dev/shm (WSL and containers), removed at the end.
# The server's key comes from Bitwarden "M7 server N8N_ENCRYPTION_KEY" into a mode-600 WSL file for the drill; the owner shreds it after.
# Run: powershell -File scripts\check-n8n-offsite-restore.ps1 -File <n8n-...tar.age> [-AgeKeyFile <WSL path>] [-N8nKeyFile <WSL path>]
# Exit 0 = restores and matches, 1 = problem. Prove it can fail: -WrongKey (a random key instead of the server's), -TamperErrorWorkflow
# (Intake's errorWorkflow changed in both restore inputs), a copy with one byte flipped.
param(
    [Parameter(Mandatory = $true)][string]$File,
    [string]$AgeKeyFile = '~/.config/age/m7-backup.key',
    [string]$N8nKeyFile = '~/.config/n8n-drill/server-encryption-key',
    [switch]$WrongKey,
    [switch]$TamperErrorWorkflow
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\workflows.ps1"

$Image = 'docker.n8n.io/n8nio/n8n:2.45.6'
$Phases = 'entities', 'json'
$ExpectedTables = @{ stripe_config = 'alert_email_from,alert_email_to,invoice_email_from,telegram_chat_id,telegram_send_pdf'; stripe_heartbeat = 'heartbeat_url' }

$script:failed = 0
function Write-Step([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { Write-Host "[PASS] $Name" -ForegroundColor Green -NoNewline } else { Write-Host "[FAIL] $Name" -ForegroundColor Red -NoNewline; $script:failed++ }
    if ($Detail) { Write-Host " - $Detail" } else { Write-Host '' }
}
function Get-Values([object[]]$Lines, [string]$Key) { @($Lines | Where-Object { "$_" -like "$Key=*" } | ForEach-Object { "$_".Substring($Key.Length + 1).Trim() }) }

$full = (Resolve-Path -LiteralPath $File).Path
if ($full -match "'" -or $AgeKeyFile -match "'" -or $N8nKeyFile -match "'") { throw 'paths must not contain a single quote' }
if ((Split-Path -Leaf $full) -notmatch '^n8n-\d{8}T\d{6}Z\.tar\.age$') { throw "keep the file's bucket name (n8n-<UTC>.tar.age), got: $(Split-Path -Leaf $full)" }
$winPath = $full -replace '\\', '/'
$ageKeyExpr = $AgeKeyFile -replace '^~', '"$HOME"'
$n8nKeyExpr = $N8nKeyFile -replace '^~', '"$HOME"'
$intakeId = (Get-Workflows | Where-Object { $_.Name -eq 'Stripe Intake' }).Id

# Runs inside each throwaway (node:sqlite is built into the image's Node 26). Names, counts and settings only, never values.
$verifyJs = @'
const { DatabaseSync } = require('node:sqlite');
const fs = require('fs');
const db = new DatabaseSync('/home/node/.n8n/database.sqlite', { readOnly: true });
for (const w of db.prepare('select id, settings from workflow_entity where isArchived = 0').all()) {
  let s = {}; try { s = JSON.parse(w.settings || '{}') || {}; } catch (e) {}
  console.log(`wf=${w.id}|${s.errorWorkflow || '-'}`);
}
for (const t of db.prepare('select id, name from data_table').all()) {
  const rows = db.prepare(`select count(*) as n from "data_table_user_${t.id}"`).get().n;
  const cols = db.prepare('select name from data_table_column where dataTableId = ? order by name').all(t.id).map(c => c.name).join(',');
  console.log(`dt=${t.name}|${rows}|${cols}`);
}
let dec = [];
try { dec = JSON.parse(fs.readFileSync('/dev/shm/c.json', 'utf8')); } catch (e) {}
const byId = new Map(dec.map(c => [c.id, c]));
for (const c of db.prepare('select id, name, type from credentials_entity').all()) {
  const d = byId.get(c.id);
  const ok = !!d && d.data && typeof d.data === 'object' && Object.keys(d.data).length > 0;
  console.log(`cred=${c.name}|${c.type}|${ok ? 'yes' : 'no'}`);
}
'@
$verifyB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($verifyJs -replace "`r", '')))

# Changes Intake's errorWorkflow in workflows.json and in entities.zip's workflowentity.jsonl (settings may be a JSON string there).
$tamperPy = @'
import json, sys, zipfile
d, wid = sys.argv[1], sys.argv[2]
def fix(s):
    obj = json.loads(s) if isinstance(s, str) else (s or {})
    obj['errorWorkflow'] = 'tamperedTAMPERED'
    return json.dumps(obj) if isinstance(s, str) else obj
wf = json.load(open(f'{d}/workflows.json'))
for w in wf:
    if w['id'] == wid: w['settings'] = fix(w.get('settings'))
json.dump(wf, open(f'{d}/workflows.json', 'w'))
src = zipfile.ZipFile(f'{d}/entities.zip')
items = [(i, src.read(i)) for i in src.infolist()]
src.close()
with zipfile.ZipFile(f'{d}/entities.zip', 'w', zipfile.ZIP_DEFLATED) as out:
    for i, data in items:
        if i.filename == 'workflowentity.jsonl':
            lines = []
            for line in data.decode().splitlines():
                row = json.loads(line)
                if row.get('id') == wid: row['settings'] = fix(row.get('settings'))
                lines.append(json.dumps(row))
            data = ('\n'.join(lines) + '\n').encode()
        out.writestr(i.filename, data)
print('tampered=yes')
'@
$tamperB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($tamperPy -replace "`r", '')))

$sh = @"
set -euo pipefail
file="`$(wslpath -u '$winPath')"
agekey=$ageKeyExpr
n8nkey=$n8nKeyExpr
ram="`$(mktemp -d -p /dev/shm)"; chmod 700 "`$ram"; mkdir "`$ram/in"
cleanup() { docker rm -f n8n-drill-entities n8n-drill-json >/dev/null 2>&1 || true; rm -rf "`$ram"; }
trap cleanup EXIT
echo "header=`$(head -c 21 "`$file")"
if [ "$([int][bool]$WrongKey)" = 1 ]; then
  n8nkey="`$ram/wrong.key"; head -c 24 /dev/urandom | base64 > "`$n8nkey"; chmod 600 "`$n8nkey"; echo "keymode=600"
else
  [ -r "`$n8nkey" ] || { echo "keymode=missing"; exit 1; }
  echo "keymode=`$(stat -c %a "`$n8nkey")"
fi
age -d -i "`$agekey" "`$file" | tar -x -C "`$ram/in"
echo "files=`$(ls "`$ram/in" | sort | tr '\n' ',')"
if [ "$([int][bool]$TamperErrorWorkflow)" = 1 ]; then echo $tamperB64 | base64 -d | python3 - "`$ram/in" '$intakeId'; fi
echo $verifyB64 | base64 -d > "`$ram/verify.js"
docker image inspect $Image >/dev/null 2>&1 || docker pull -q $Image >/dev/null
for phase in $($Phases -join ' '); do
  c="n8n-drill-`$phase"
  docker run -d --name "`$c" --network none --tmpfs /home/node/.n8n:uid=1000,gid=1000,mode=700 \
    -v "`$ram/in:/restore:ro" -v "`$n8nkey:/run/n8n_key:ro" -e N8N_ENCRYPTION_KEY_FILE=/run/n8n_key \
    --entrypoint node $Image -e 'setInterval(() => {}, 1e9)' >/dev/null
  if [ "`$phase" = entities ]; then
    docker exec "`$c" n8n import:entities --inputDir=/restore >/dev/null 2>&1 && echo "`$phase:import=ok" || echo "`$phase:import=failed"
  else
    docker exec "`$c" sh -c 'n8n import:workflow --input=/restore/workflows.json && n8n import:credentials --input=/restore/credentials.json' >/dev/null 2>&1 \
      && echo "`$phase:import=ok" || echo "`$phase:import=failed"
  fi
  docker exec "`$c" sh -c 'umask 077; n8n export:credentials --all --decrypted --output=/dev/shm/c.json >/dev/null 2>&1 || true'
  docker exec -i "`$c" node - < "`$ram/verify.js" | sed "s/^/`$phase:/" || echo "`$phase:verify=failed"
  docker exec "`$c" rm -f /dev/shm/c.json
  docker rm -f "`$c" >/dev/null
done
echo "drill=done"
"@

try {
    $out = @(& "$PSScriptRoot\wsl-sh.ps1" -Script $sh)
    $code = $LASTEXITCODE
    $header = "$(Get-Values $out 'header')"
    Write-Step 'file is age-encrypted' ($header -eq 'age-encryption.org/v1') $header
    $mode = "$(Get-Values $out 'keymode')"
    Write-Step 'n8n key file present, mode 600 or 400' ($mode -in '600', '400') "mode $mode$(if ($WrongKey) { ' (random wrong key)' })"
    $files = "$(Get-Values $out 'files')"
    Write-Step 'archive holds workflows.json, credentials.json, entities.zip' ($files -eq 'credentials.json,entities.zip,workflows.json,') $files
    Write-Step 'drill ran to the end' ((@($out | Where-Object { "$_" -eq 'drill=done' }).Count -eq 1) -and $code -eq 0) "exit $code"

    # The server's credential names and types, read-only from its SQLite (names only, no CLI process).
    $serverJs = "const { DatabaseSync } = require('node:sqlite'); const db = new DatabaseSync('/home/node/.n8n/database.sqlite', { readOnly: true }); for (const c of db.prepare('select name, type from credentials_entity').all()) console.log('cred=' + c.name + '|' + c.type);"
    $serverB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($serverJs))
    $sv = @(& "$PSScriptRoot\server-sh.ps1" -Script "echo $serverB64 | base64 -d | docker exec -i n8n node -")
    if ($LASTEXITCODE -ne 0) { throw 'could not read the credential list from the server' }
    $serverCreds = @(Get-Values $sv 'cred' | Sort-Object)
    Write-Step 'server credential list read' ($serverCreds.Count -gt 0) "$($serverCreds.Count) credentials"

    foreach ($phase in $Phases) {
        Write-Step "${phase}: import succeeded" ("$(Get-Values $out "${phase}:import")" -eq 'ok') "$(Get-Values $out "${phase}:import")"
        $wf = @(Get-Values $out "${phase}:wf")
        $want = @(Get-Workflows | ForEach-Object { "{0}|{1}" -f $_.Id, $(if ($_.ErrorHandler) { $ErrorHandlerWorkflowId } else { '-' }) } | Sort-Object)
        $got = @($wf | Sort-Object)
        $diff = @(Compare-Object $want $got | ForEach-Object { "$($_.InputObject) $(if ($_.SideIndicator -eq '=>') { 'restored only' } else { 'missing' })" })
        Write-Step "${phase}: 7 workflows with the expected errorWorkflow" ($diff.Count -eq 0 -and $got.Count -eq 7) $(if ($diff.Count) { $diff -join '; ' } else { "$($got.Count) workflows" })
        $creds = @(Get-Values $out "${phase}:cred")
        $names = @($creds | ForEach-Object { ($_ -split '\|')[0..1] -join '|' } | Sort-Object)
        $credDiff = @(Compare-Object $serverCreds $names | ForEach-Object { "$(($_.InputObject -split '\|')[0]) $(if ($_.SideIndicator -eq '=>') { 'restored only' } else { 'missing' })" })
        Write-Step "${phase}: credential names and types match the server" ($credDiff.Count -eq 0 -and $names.Count -gt 0) $(if ($credDiff.Count) { $credDiff -join '; ' } else { "$($names.Count) credentials" })
        $notDec = @($creds | Where-Object { $_ -notlike '*|yes' } | ForEach-Object { ($_ -split '\|')[0] })
        Write-Step "${phase}: every credential decrypts with the given key" ($creds.Count -gt 0 -and $notDec.Count -eq 0) $(if ($notDec.Count) { "not decrypted: $($notDec -join ', ')" } else { "$($creds.Count) of $($creds.Count)" })
        if ($phase -eq 'entities') {
            $dts = @(Get-Values $out "${phase}:dt")
            foreach ($t in $ExpectedTables.Keys | Sort-Object) {
                $row = @($dts | Where-Object { ($_ -split '\|')[0] -eq $t })
                $ok = $row.Count -eq 1 -and ($row[0] -split '\|')[1] -eq '1' -and ($row[0] -split '\|')[2] -eq $ExpectedTables[$t]
                Write-Step "${phase}: data table $t has 1 row and its columns" $ok $(if ($row.Count) { "rows=$(($row[0] -split '\|')[1]) columns=$(($row[0] -split '\|')[2])" } else { 'not restored' })
            }
        }
    }
}
catch {
    Write-Step 'n8n restore drill aborted' $false $_.Exception.Message
}
finally {
    $null = & "$PSScriptRoot\wsl-sh.ps1" -Script 'docker rm -f n8n-drill-entities n8n-drill-json >/dev/null 2>&1 || true'
}

Write-Output ("{0} failed" -f $script:failed)
if ($script:failed -gt 0) { exit 1 }
exit 0
