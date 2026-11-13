# Proves the nightly demo reset on the M7 server (M7c-2): both guards abort with nothing deleted, then a real run deletes the old rows in
# FK order, keeps the new ones, keeps invoice_number_seq and clears Mailpit. NOT part of e2e: it deletes every server row older than 5 minutes.
# Run (owner approves first): powershell -File scripts\check-demo-reset.ps1 [-SkipBackup]   Exit 0 = ok, 1 = problem.
# It never sends a deleting statement itself: it seeds with INSERT, flips states with UPDATE, and every deletion is done by the real
# demo-reset.service (systemctl start), the only path the reset may take. The destructive guards are never asked for an exception.
# Before the real run it takes a fresh offsite backup (backup-offsite.service), unless -SkipBackup.
# Seeded rows use ids evt_test_reset_<run>_*, so nothing real is touched by the seeding. Rows seeded as "new" are left for the next reset.
param([switch]$SkipBackup)
$ErrorActionPreference = 'Stop'
$failed = 0
function Write-Step([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { Write-Host "[PASS] $Name" -ForegroundColor Green -NoNewline } else { Write-Host "[FAIL] $Name" -ForegroundColor Red -NoNewline; $script:failed++ }
    if ($Detail) { Write-Host " - $Detail" } else { Write-Host '' }
}
function Invoke-Server([string]$Script) {
    $out = @(& "$PSScriptRoot\server-sh.ps1" -Script $Script)
    return @{ Out = $out; Code = $LASTEXITCODE }
}
function Get-Value($Out, [string]$Key) { $l = @($Out | Where-Object { "$_" -like "$Key=*" }); if ($l.Count) { "$($l[0])".Substring($Key.Length + 1).Trim() } else { '' } }

$run = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$p = "evt_test_reset_${run}"
# Runs the service and returns its result and journal lines (counts and guard messages; no secret is ever printed by the script).
function Start-Reset {
    $r = Invoke-Server @'
ts="$(date +%s)"
if sudo systemctl start demo-reset.service; then echo "rc=0"; else echo "rc=1"; fi
journalctl -u demo-reset.service --since "@$ts" -o cat --no-pager | grep -Ev '^\s*$' | tail -20
'@
    return $r.Out
}
# Counts this run's seeded rows: old ones must go, new ones must stay. psql variables keep the run id out of the SQL text.
function Get-Seeded {
    $r = Invoke-Server @"
docker exec -i postgres psql -U automation -d automation -tA -v ON_ERROR_STOP=1 -v p='$p' <<'SQL'
select 'old_events=' || count(*) from stripe_events where event_id = :'p' || '_old';
select 'old_children=' || (select count(*) from invoices where event_id = :'p' || '_old') + (select count(*) from side_effects where event_id = :'p' || '_old')
       + (select count(*) from event_replays where event_id = :'p' || '_old');
select 'new_events=' || count(*) from stripe_events where event_id = :'p' || '_new';
select 'new_children=' || (select count(*) from invoices where event_id = :'p' || '_new') + (select count(*) from side_effects where event_id = :'p' || '_new');
select 'old_sessions=' || count(*) from demo_sessions where token_hash = sha256(convert_to(:'p' || '_old', 'UTF8'));
select 'new_sessions=' || count(*) from demo_sessions where token_hash = sha256(convert_to(:'p' || '_new', 'UTF8'));
select 'old_alerts=' || count(*) from demo_limit_alerts where day = date '2000-01-01';
select 'total_events=' || count(*) from stripe_events;
select 'seq=' || last_value from invoice_number_seq;
SQL
"@
    if ($r.Code -ne 0) { throw "count query failed (exit $($r.Code))" }
    return $r.Out
}

# 0. Preconditions: the role, the timer, the ping URL (presence only), the new tables.
$r = Invoke-Server @'
echo "role=$(docker exec postgres psql -U automation -d automation -tAc "select count(*) from pg_roles where rolname = 'demo_reset'")"
echo "tables=$(docker exec postgres psql -U automation -d automation -tAc "select count(*) from pg_tables where tablename in ('demo_sessions','demo_limit_alerts')")"
echo "timer=$(systemctl is-active demo-reset.timer)"
if grep -Eq '^DEMO_RESET_HEARTBEAT_URL=.+' ~/n8n-workflows/.env; then echo "pingurl=set"; else echo "pingurl=EMPTY"; fi
echo "unit_current=$(cmp -s ~/n8n-workflows/infra/demo-reset.service /etc/systemd/system/demo-reset.service && echo yes || echo no)"
'@
Write-Step 'role demo_reset exists (migration 008)' ((Get-Value $r.Out 'role') -eq '1') (Get-Value $r.Out 'role')
Write-Step 'tables demo_sessions and demo_limit_alerts exist' ((Get-Value $r.Out 'tables') -eq '2') (Get-Value $r.Out 'tables')
Write-Step 'demo-reset.timer is active' ((Get-Value $r.Out 'timer') -eq 'active') (Get-Value $r.Out 'timer')
Write-Step 'DEMO_RESET_HEARTBEAT_URL is set in the server .env' ((Get-Value $r.Out 'pingurl') -eq 'set') (Get-Value $r.Out 'pingurl')
Write-Step 'installed demo-reset.service matches the repo' ((Get-Value $r.Out 'unit_current') -eq 'yes') (Get-Value $r.Out 'unit_current')
if ($failed -gt 0) { Write-Output ("{0} failed" -f $failed); exit 1 }

# 1. Seed. Old rows: 10 minutes old, with an invoice, a side effect and a replay (the FK chain). New rows: now (must survive).
# A minimal payload: the Processor never touches done rows. The invoice number is explicit, so invoice_number_seq is not consumed.
$r = Invoke-Server @"
docker exec -i postgres psql -U automation -d automation -tA -v ON_ERROR_STOP=1 -v p='$p' <<'SQL'
begin;
insert into stripe_events (event_id, event_type, status, attempts, payload, received_at, pending_since, processed_at)
  values (:'p' || '_old', 'checkout.session.completed', 'done', 1, '{"livemode": false, "object": "event"}', now() - interval '10 minutes', now() - interval '10 minutes', now() - interval '9 minutes'),
         (:'p' || '_new', 'checkout.session.completed', 'done', 1, '{"livemode": false, "object": "event"}', now(), now(), now());
insert into invoices (invoice_number, event_id, customer_email, amount_cents, currency)
  values ('INV-TEST-' || :'p' || '-OLD', :'p' || '_old', 'demo-00000000@demo.mahmud-alhussen.de', 3000, 'eur'),
         ('INV-TEST-' || :'p' || '-NEW', :'p' || '_new', 'demo-00000000@demo.mahmud-alhussen.de', 3000, 'eur');
insert into side_effects (event_id, kind) values (:'p' || '_old', 'email'), (:'p' || '_new', 'email');
insert into event_replays (event_id, reason) values (:'p' || '_old', 'check-demo-reset seed');
insert into demo_sessions (token_hash, demo_email, created_at)
  values (sha256(convert_to(:'p' || '_old', 'UTF8')), 'demo-' || left(md5(:'p' || 'old'), 8) || '@demo.mahmud-alhussen.de', now() - interval '10 minutes'),
         (sha256(convert_to(:'p' || '_new', 'UTF8')), 'demo-' || left(md5(:'p' || 'new'), 8) || '@demo.mahmud-alhussen.de', now());
insert into demo_limit_alerts (day) values (date '2000-01-01') on conflict do nothing;
-- The guard row: processing, received 10 minutes ago, claimed now (so the Processor's 10-minute release leaves it alone).
insert into stripe_events (event_id, event_type, status, attempts, payload, received_at, pending_since, claimed_at)
  values (:'p' || '_guard', 'checkout.session.completed', 'processing', 1, '{"livemode": false, "object": "event"}', now() - interval '10 minutes', now() - interval '10 minutes', now());
commit;
SQL
"@
Write-Step 'seeded old and new rows (event, invoice, side effect, replay, demo session, limit alert) and a processing guard row' ($r.Code -eq 0) "exit $($r.Code)"
if ($r.Code -ne 0) { Write-Output ("{0} failed" -f $failed); exit 1 }
$before = Get-Seeded

# The guard row must never stay behind as processing or livemode: it would block every nightly reset (fail-safe, but alerting).
$restoreGuard = @"
docker exec -i postgres psql -U automation -d automation -tA -v ON_ERROR_STOP=1 -v p='$p' <<'SQL'
update stripe_events set status = 'done', claimed_at = null, processed_at = now(), payload = jsonb_set(payload, '{livemode}', 'false') where event_id = :'p' || '_guard';
SQL
"@
try {
    # 2. Guard: an old processing row aborts the whole reset.
    $j = Start-Reset
    $after = Get-Seeded
    Write-Step 'guard 1: an old processing row makes the service fail' ((Get-Value $j 'rc') -eq '1') (Get-Value $j 'rc')
    Write-Step 'guard 1: the journal names the guard' (@($j | Where-Object { "$_" -match 'guard: a pending or processing event' }).Count -eq 1)
    Write-Step 'guard 1: nothing deleted (all event counts unchanged)' ((Get-Value $after 'total_events') -eq (Get-Value $before 'total_events') -and (Get-Value $after 'old_children') -eq (Get-Value $before 'old_children')) "events $(Get-Value $before 'total_events') -> $(Get-Value $after 'total_events')"

    # 3. Guard: a livemode payload anywhere aborts the whole reset (the processing row is now done, so only this guard can fire).
    $r = Invoke-Server @"
docker exec -i postgres psql -U automation -d automation -tA -v ON_ERROR_STOP=1 -v p='$p' <<'SQL'
update stripe_events set status = 'done', claimed_at = null, processed_at = now(), received_at = now(), payload = jsonb_set(payload, '{livemode}', 'true') where event_id = :'p' || '_guard';
SQL
"@
    if ($r.Code -ne 0) { throw "could not flip the guard row to livemode (exit $($r.Code))" }
    $j = Start-Reset
    $after = Get-Seeded
    Write-Step 'guard 2: a livemode payload makes the service fail' ((Get-Value $j 'rc') -eq '1') (Get-Value $j 'rc')
    Write-Step 'guard 2: the journal names the guard' (@($j | Where-Object { "$_" -match 'guard: a livemode event exists' }).Count -eq 1)
    Write-Step 'guard 2: nothing deleted (all event counts unchanged)' ((Get-Value $after 'total_events') -eq (Get-Value $before 'total_events')) "events $(Get-Value $before 'total_events') -> $(Get-Value $after 'total_events')"
} finally {
    $r = Invoke-Server $restoreGuard
    Write-Step 'guard row restored (done, livemode false)' ($r.Code -eq 0) "exit $($r.Code)"
}

# 4. demo_reset can do nothing beyond SELECT and DELETE (privileges in full: scripts\check-db-role.ps1). Each attempt must be refused.
$r = Invoke-Server @'
try() { if docker exec postgres psql -X -U demo_reset -d automation -tAc "$2" >/dev/null 2>&1; then echo "$1=allowed"; else echo "$1=refused"; fi; }
try update "update stripe_events set attempts = attempts where false"
try insert "insert into demo_limit_alerts (day) values (date '1999-01-01')"
try seq "select last_value from invoice_number_seq"
try temp "create temp table t (x int)"
'@
foreach ($k in 'update', 'insert', 'seq', 'temp') { Write-Step "demo_reset is refused: $k" ((Get-Value $r.Out $k) -eq 'refused') (Get-Value $r.Out $k) }

# 5. A fresh offsite backup first: the real run deletes every server row older than 5 minutes.
if (-not $SkipBackup) {
    $r = Invoke-Server 'if sudo systemctl start backup-offsite.service; then echo "backup=ok"; else echo "backup=failed"; fi'
    Write-Step 'fresh offsite backup before the real run' ((Get-Value $r.Out 'backup') -eq 'ok') (Get-Value $r.Out 'backup')
    if ((Get-Value $r.Out 'backup') -ne 'ok') { Write-Output ("{0} failed" -f $failed); exit 1 }
}

# 6. The real run.
$before = Get-Seeded
$j = Start-Reset
$after = Get-Seeded
Write-Host ($j -join "`n")
Write-Step 'real run: the service succeeds' ((Get-Value $j 'rc') -eq '0') (Get-Value $j 'rc')
Write-Step 'real run: the journal shows counts before and after' (@($j | Where-Object { "$_" -match '^\s*(before|after)\s*\|' }).Count -eq 2)
Write-Step 'real run: the old event and its invoice, side effect and replay are gone' ((Get-Value $after 'old_events') -eq '0' -and (Get-Value $after 'old_children') -eq '0') "old_events=$(Get-Value $after 'old_events') old_children=$(Get-Value $after 'old_children')"
Write-Step 'real run: the new event and its children stay' ((Get-Value $after 'new_events') -eq '1' -and (Get-Value $after 'new_children') -eq '2') "new_events=$(Get-Value $after 'new_events') new_children=$(Get-Value $after 'new_children')"
Write-Step 'real run: old demo session gone, new one stays' ((Get-Value $after 'old_sessions') -eq '0' -and (Get-Value $after 'new_sessions') -eq '1') "old=$(Get-Value $after 'old_sessions') new=$(Get-Value $after 'new_sessions')"
Write-Step 'real run: a past day in demo_limit_alerts is gone' ((Get-Value $after 'old_alerts') -eq '0') (Get-Value $after 'old_alerts')
Write-Step 'real run: invoice_number_seq unchanged' ((Get-Value $after 'seq') -eq (Get-Value $before 'seq')) "$(Get-Value $before 'seq') -> $(Get-Value $after 'seq')"
Write-Step 'real run: Mailpit is empty' (@($j | Where-Object { "$_" -match '^mailpit messages after reset: 0$' }).Count -eq 1)
Write-Step 'real run: the heartbeat was pinged (the owner confirms the ping time in Healthchecks)' (@($j | Where-Object { "$_" -match 'demo reset finished, heartbeat pinged' }).Count -eq 1)

Write-Output ("{0} failed" -f $failed)
if ($failed -gt 0) { exit 1 }
exit 0
