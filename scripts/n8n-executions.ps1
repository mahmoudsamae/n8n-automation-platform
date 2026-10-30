# List n8n workflow executions straight from n8n's SQLite file, read-only. For when the n8n MCP is down (it drops whenever n8n is recreated,
# sometimes for a long time). Runs `node` with the built-in `node:sqlite` inside the n8n container; nothing is written anywhere.
#   powershell -File scripts\n8n-executions.ps1 [-Workflow 'Stripe Monitor' | <workflow id>] [-SinceUtc '2026-10-30 08:44'] [-Status error] [-Limit 20]
# Prints the newest -Limit executions, oldest first: id | workflow | status | duration | start time as Berlin time with UTC in parentheses.
# -SinceUtc is a UTC time (n8n stores UTC): 'YYYY-MM-DD' or 'YYYY-MM-DD HH:MM[:SS]'. Exit 0 = ran (even with 0 rows), 1 = failed, 2 = bad argument.
# This shows THAT and WHEN a run happened and how it ended, not node-level data (use the MCP get_workflow_execution for that when it is up).
param(
    [string]$Workflow = '',
    [string]$SinceUtc = '',
    [ValidateSet('', 'success', 'error', 'crashed', 'running', 'waiting', 'canceled', 'new')][string]$Status = '',
    [ValidateRange(1, 200)][int]$Limit = 20
)
$ErrorActionPreference = 'Stop'

if ($Workflow -and $Workflow -notmatch '^[A-Za-z0-9][A-Za-z0-9 _-]{0,63}$') { Write-Host 'REFUSED: -Workflow must be a workflow name or id (letters, digits, space, _ -)' -ForegroundColor Red; exit 2 }
if ($SinceUtc -and $SinceUtc -notmatch '^\d{4}-\d{2}-\d{2}([ T]\d{2}:\d{2}(:\d{2})?)?$') { Write-Host "REFUSED: -SinceUtc must look like '2026-10-30' or '2026-10-30 08:44[:00]'" -ForegroundColor Red; exit 2 }
$since = $SinceUtc -replace 'T', ' '

# Values are validated above, so placing them in single quotes is safe. The JS reaches node on stdin (node - args).
$sh = @'
set +x
docker exec -i n8n node - '__SINCE__' '__WORKFLOW__' '__STATUS__' '__LIMIT__' <<'JS'
const { DatabaseSync } = require('node:sqlite');
const db = new DatabaseSync('/home/node/.n8n/database.sqlite', { readOnly: true });
const [since, wf, status, limit] = process.argv.slice(2);
let sql = 'select e.id, w.name as wname, e.status, e.startedAt, e.stoppedAt from execution_entity e left join workflow_entity w on w.id = e.workflowId where 1 = 1';
const args = [];
if (since) { sql += ' and e.startedAt >= ?'; args.push(since); }
if (wf) { sql += ' and (w.name = ? or w.id = ?)'; args.push(wf, wf); }
if (status) { sql += ' and e.status = ?'; args.push(status); }
sql += ' order by e.id desc limit ?'; args.push(Number(limit));
const rows = db.prepare(sql).all(...args).reverse();
const utc = (s) => new Date(String(s).replace(' ', 'T') + 'Z');
const berlin = (d) => d.toLocaleString('sv-SE', { timeZone: 'Europe/Berlin' });
for (const r of rows) {
  const a = utc(r.startedAt);
  const ms = r.stoppedAt ? utc(r.stoppedAt) - a : null;
  console.log([String(r.id).padStart(5), (r.wname ?? '(deleted workflow)').padEnd(20), String(r.status).padEnd(8), (ms === null ? '   -' : String(ms).padStart(5) + ' ms'), berlin(a) + ' (' + a.toISOString().slice(11, 19) + ' UTC)'].join(' | '));
}
console.log('rows: ' + rows.length);
JS
'@
$sh = $sh.Replace('__SINCE__', $since).Replace('__WORKFLOW__', $Workflow).Replace('__STATUS__', $Status).Replace('__LIMIT__', [string]$Limit)
try {
    $out = @(& "$PSScriptRoot\wsl-sh.ps1" -Script $sh)
    if ($LASTEXITCODE -ne 0) { throw "node exited with $LASTEXITCODE" }
    $out
    exit 0
}
catch {
    Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
