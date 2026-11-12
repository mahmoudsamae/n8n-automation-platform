# Proves workflows cannot read secrets through the environment, and that the configuration they read instead is complete.
# Run: powershell -File scripts\check-n8n-env.ps1   Exit 0 = ok, 1 = problem. Prints names and set/empty only, never a value.
# Last line before the summary: telegram_send_pdf=true|false|INVALID, which e2e reads to know whether a Telegram document is expected.
# Checks: N8N_BLOCK_ENV_ACCESS_IN_NODE=true in the n8n container; none of the secret or config names in the container's environment
# (they moved to the credential "Stripe webhook secret" and the data tables stripe_config and stripe_heartbeat); each data table has
# exactly one row with every column set; telegram_send_pdf is exactly true or false; the crypto credential exists.
# Data tables and credentials are read from n8n's SQLite file, read-only, inside the container.
# Prove it can fail: N8N_BLOCK_ENV_ACCESS_IN_NODE=false docker compose up -d --no-deps n8n (then run it, expect FAIL), or empty one cell of stripe_config.
# -Target Server runs the same checks inside the server's n8n container (table ids are read there, so no id map is needed).
param([ValidateSet('Laptop', 'Server')][string]$Target = 'Laptop')
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\target.ps1"
$T = Get-Target $Target
$failed = 0
function Write-Step([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { Write-Host "[PASS] $Name" -ForegroundColor Green -NoNewline } else { Write-Host "[FAIL] $Name" -ForegroundColor Red -NoNewline; $script:failed++ }
    if ($Detail) { Write-Host " - $Detail" } else { Write-Host '' }
}

$forbidden = @('N8N_ENCRYPTION_KEY', 'STRIPE_WEBHOOK_SECRET', 'HEARTBEAT_URL', 'TELEGRAM_CHAT_ID', 'ALERT_EMAIL_TO', 'ALERT_EMAIL_FROM', 'INVOICE_EMAIL_FROM', 'TELEGRAM_SEND_PDF')

$sh = @'
echo "block=$(docker exec n8n printenv N8N_BLOCK_ENV_ACCESS_IN_NODE)"
docker exec n8n env | cut -d= -f1 | sed 's/^/envname=/'
docker exec -i n8n node - <<'JS'
const { DatabaseSync } = require('node:sqlite');
const db = new DatabaseSync('/home/node/.n8n/database.sqlite', { readOnly: true });
const tables = new Set(db.prepare("select name from sqlite_master where type = 'table'").all().map((r) => r.name));
const blank = (v) => v == null || String(v).trim() === '';
for (const name of ['stripe_config', 'stripe_heartbeat']) {
  const meta = db.prepare('select id from data_table where name = ?').all(name);
  if (meta.length !== 1) { console.log('table_' + name + '=missing'); continue; }
  const phys = 'data_table_user_' + meta[0].id;
  if (!tables.has(phys)) { console.log('table_' + name + '=missing'); continue; }
  const rows = db.prepare('select * from "' + phys + '"').all();
  console.log('table_' + name + '=rows:' + rows.length);
  const cols = db.prepare('select name from data_table_column where dataTableId = ?').all(meta[0].id).map((r) => r.name);
  for (const c of cols) console.log('col_' + name + '.' + c + '=' + (rows.length === 1 && !blank(rows[0][c]) ? 'set' : 'EMPTY'));
  if (name === 'stripe_config' && rows.length === 1) {
    const v = String(rows[0].telegram_send_pdf ?? '').trim();
    console.log('telegram_send_pdf=' + (v === 'true' || v === 'false' ? v : 'INVALID'));
  }
  if (name === 'stripe_heartbeat' && rows.length === 1) {
    console.log('heartbeat_shape=' + (/^https:\/\/hc-ping\.com\/\S+$/.test(String(rows[0].heartbeat_url ?? '').trim()) ? 'ok' : 'BAD'));
  }
}
// Every data table node in the PUBLISHED pipeline workflows must reference its table by id (name mode matches LIKE '%name%' and
// can pick another table), and that id must exist with the expected name: stripe_heartbeat for the heartbeat URL, stripe_config otherwise.
const names = new Map(db.prepare('select id, name from data_table').all().map((r) => [r.id, r.name]));
const wfs = db.prepare("select w.name as wname, h.nodes from workflow_entity w join workflow_history h on h.versionId = w.activeVersionId where w.isArchived = 0 and w.name like 'Stripe %'").all();
for (const w of wfs) {
  for (const n of JSON.parse(w.nodes).filter((x) => x.type === 'n8n-nodes-base.dataTable')) {
    const ref = n.parameters.dataTableId || {};
    const want = n.name === 'Load Heartbeat URL' ? 'stripe_heartbeat' : 'stripe_config';
    const ok = ref.mode === 'id' && names.get(ref.value) === want;
    console.log('ref=' + w.wname + ' / ' + n.name + ': ' + (ok ? 'ok' : 'BAD (mode ' + ref.mode + ', table ' + (names.get(ref.value) || 'missing') + ', expected ' + want + ')'));
  }
}
const cred = db.prepare("select count(*) as n from credentials_entity where name = 'Stripe webhook secret' and type = 'crypto'").get();
console.log('crypto_credential=' + cred.n);
JS
'@
$out = @(Invoke-TargetSh $T $sh)
if ($LASTEXITCODE -ne 0) { Write-Step 'n8n container reachable' $false "exit $LASTEXITCODE"; Write-Output '1 failed'; exit 1 }
function Get-Values([string]$Key) { @($out | Where-Object { "$_" -like "$Key=*" } | ForEach-Object { "$_".Substring($Key.Length + 1).Trim() }) }
function Get-One([string]$Key) { $v = @(Get-Values $Key); if ($v.Count) { $v[0] } else { '' } }

Write-Step 'N8N_BLOCK_ENV_ACCESS_IN_NODE=true in the n8n container' ((Get-One 'block') -eq 'true') "value: $(if (Get-One 'block') { Get-One 'block' } else { 'unset' })"
$names = @(Get-Values 'envname')
$present = @($forbidden | Where-Object { $_ -in $names })
Write-Step 'no secret or config name in the n8n container environment' ($names.Count -gt 0 -and $present.Count -eq 0) $(if ($present.Count) { 'present: ' + ($present -join ', ') } else { "$($names.Count) names checked" })

foreach ($t in 'stripe_config', 'stripe_heartbeat') {
    Write-Step "data table $t has exactly one row" ((Get-One "table_$t") -eq 'rows:1') (Get-One "table_$t")
    $cols = @($out | Where-Object { "$_" -like "col_$t.*" })
    $empty = @($cols | Where-Object { "$_" -like '*=EMPTY' } | ForEach-Object { ("$_" -split '=')[0].Substring("col_$t.".Length) })
    Write-Step "data table ${t}: every column set" ($cols.Count -gt 0 -and $empty.Count -eq 0) $(if ($empty.Count) { 'empty: ' + ($empty -join ', ') } else { "$($cols.Count) columns" })
}
$sendPdf = Get-One 'telegram_send_pdf'
Write-Step 'stripe_config.telegram_send_pdf is exactly true or false' ($sendPdf -in 'true', 'false') $(if ($sendPdf) { $sendPdf } else { 'not reported' })
Write-Step 'stripe_heartbeat.heartbeat_url is an https://hc-ping.com/ URL' ((Get-One 'heartbeat_shape') -eq 'ok') (Get-One 'heartbeat_shape')
$refs = @(Get-Values 'ref')
$badRefs = @($refs | Where-Object { $_ -notlike '*: ok' })
Write-Step 'published workflows reference the data tables by id, and each id has the expected name' ($refs.Count -ge 5 -and $badRefs.Count -eq 0) $(if ($badRefs.Count) { $badRefs -join '; ' } else { "$($refs.Count) references" })
Write-Step 'crypto credential "Stripe webhook secret" exists' ((Get-One 'crypto_credential') -eq '1') "$(Get-One 'crypto_credential') found"

# Write-Output, not Write-Host: e2e reads these two lines from the pipeline.
Write-Output ("telegram_send_pdf={0}" -f $(if ($sendPdf) { $sendPdf } else { 'INVALID' }))
Write-Output ("{0} failed" -f $failed)
if ($failed -gt 0) { exit 1 }
exit 0
