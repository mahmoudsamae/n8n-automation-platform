# Delete ONE test event and everything that points at it, in FK order, in a single transaction:
# event_replays, side_effects, invoices, stripe_events (all FKs are ON DELETE RESTRICT, so the order is required).
#   powershell -File scripts\clean-test-event.ps1 -Id evt_test_stuckproc [-DryRun]
# Exit codes: 0 done (or nothing to delete), 1 failed (nothing changed: single transaction), 2 refused (bad id).
# Safe by design: the id must match ^evt_test_[A-Za-z0-9_]+$ (so it can never touch a real or e2e event, whose ids start evt_1...),
# it deletes exactly one event_id, the id travels as a psql variable (never inside the SQL text), and -DryRun only counts.
# Counterpart of scripts\seed-test-event.ps1.
param(
    [Parameter(Mandatory = $true)][string]$Id,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'

if ($Id -cnotmatch '^evt_test_[A-Za-z0-9_]+\z') {
    Write-Host 'REFUSED: -Id must match ^evt_test_[A-Za-z0-9_]+$ (only test events can be cleaned; real and e2e events are never touched)' -ForegroundColor Red
    exit 2
}

function Invoke-Psql([string]$Sql, [string[]]$Flags = @('-tA')) {
    $out = $Sql | wsl -d Ubuntu docker exec -i postgres psql -U automation -d automation -v ON_ERROR_STOP=1 @Flags -v "eid=$Id"
    if ($LASTEXITCODE -ne 0) { throw "psql failed (exit $LASTEXITCODE)" }
    return (@($out) | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
}

$countSql = @'
select 'stripe_events=' || (select count(*) from stripe_events where event_id = :'eid')
    || ' side_effects=' || (select count(*) from side_effects where event_id = :'eid')
    || ' invoices=' || (select count(*) from invoices where event_id = :'eid')
    || ' event_replays=' || (select count(*) from event_replays where event_id = :'eid');
'@

try {
    $before = Invoke-Psql $countSql
    Write-Host "before: $before"
    if ($before -match '^stripe_events=0 side_effects=0 invoices=0 event_replays=0$') {
        Write-Host "nothing to delete for $Id (check the id if you expected rows)"
        exit 0
    }
    if ($DryRun) {
        Write-Host "DRY RUN: would delete the rows above in this order: event_replays, side_effects, invoices, stripe_events. Nothing changed."
        exit 0
    }

    $deleteSql = @'
DELETE FROM event_replays WHERE event_id = :'eid';
DELETE FROM side_effects  WHERE event_id = :'eid';
DELETE FROM invoices      WHERE event_id = :'eid';
DELETE FROM stripe_events WHERE event_id = :'eid';
'@
    # -1 = one transaction: if any statement fails, nothing is deleted.
    $tags = Invoke-Psql $deleteSql @('-1', '-tA')
    $labels = 'event_replays', 'side_effects', 'invoices', 'stripe_events'
    for ($i = 0; $i -lt $labels.Count; $i++) { Write-Host ("deleted from {0,-13}: {1}" -f $labels[$i], ($tags[$i] -replace '^DELETE ', '')) }

    $after = Invoke-Psql $countSql
    Write-Host "after:  $after"
    if ($after -notmatch '^stripe_events=0 side_effects=0 invoices=0 event_replays=0$') { throw 'rows are still present after the delete' }
    exit 0
}
catch {
    Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
