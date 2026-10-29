# Insert ONE test event into stripe_events, in the state you ask for, to prove alert/recovery paths.
#   powershell -File scripts\seed-test-event.ps1 -Id evt_test_stuckproc -Status processing -ClaimedMinutesAgo 25 -ReceivedMinutesAgo 30
# The payload is copied from the newest REAL 'done' event, so the Processor can finish the row once it is let loose.
# Exit codes: 0 inserted, 1 refused (id exists / no real done event to copy), 2 bad arguments.
# Safe by design: the id must start with evt_test_ (so cleanup can never touch real events), only INSERT runs (no delete, no schema change),
# and every value travels as a psql variable, never inside the SQL text.
# Cleanup (order matters, all FKs are RESTRICT): event_replays, side_effects, invoices, stripe_events -> see CLAUDE.md.
param(
    [Parameter(Mandatory = $true)][string]$Id,
    [ValidateSet('pending', 'processing', 'failed')][string]$Status = 'pending',
    [ValidateRange(0, 100)][int]$Attempts = 0,
    [ValidateRange(0, 100000)][int]$ReceivedMinutesAgo = 0,
    [ValidateRange(0, 100000)][int]$PendingSinceMinutesAgo = 0,
    [ValidateRange(-1, 100000)][int]$ClaimedMinutesAgo = -1   # -1 = not claimed (NULL); a 'processing' row defaults to 0 (claimed now)
)
$ErrorActionPreference = 'Stop'

if ($Id -cnotmatch '^evt_test_[A-Za-z0-9_]+\z') {
    Write-Host 'REFUSED: -Id must match ^evt_test_[A-Za-z0-9_]+$ (only test ids can be seeded)' -ForegroundColor Red
    exit 2
}
if ($Status -eq 'processing' -and $ClaimedMinutesAgo -lt 0) { $ClaimedMinutesAgo = 0 }
$claimed = if ($ClaimedMinutesAgo -ge 0) { "$ClaimedMinutesAgo" } else { '' }

function Invoke-Psql([string]$Sql, [string[]]$Flags = @('-tA', '-q')) {
    $out = $Sql | wsl -d Ubuntu docker exec -i postgres psql -U automation -d automation -v ON_ERROR_STOP=1 @Flags `
        -v "eid=$Id" -v "st=$Status" -v "att=$Attempts" -v "recv=$ReceivedMinutesAgo" -v "pend=$PendingSinceMinutesAgo" -v "claimed=$claimed"
    if ($LASTEXITCODE -ne 0) { throw "psql failed (exit $LASTEXITCODE)" }
    return (@($out) | ForEach-Object { "$_".TrimEnd() } | Where-Object { $_ }) -join "`n"
}

if (Invoke-Psql "SELECT 1 FROM stripe_events WHERE event_id = :'eid';") {
    Write-Host "REFUSED: $Id already exists. Delete it first (order: event_replays, side_effects, invoices, stripe_events) or pick another id." -ForegroundColor Red
    exit 1
}

$insert = @'
INSERT INTO stripe_events (event_id, event_type, status, attempts, payload, received_at, claimed_at, pending_since)
SELECT :'eid', event_type, :'st', :'att'::int, payload,
       now() - make_interval(mins => :'recv'::int),
       CASE WHEN :'claimed' = '' THEN NULL ELSE now() - make_interval(mins => :'claimed'::int) END,
       now() - make_interval(mins => :'pend'::int)
FROM stripe_events
WHERE status = 'done' AND event_id NOT LIKE 'evt\_test\_%'
ORDER BY received_at DESC
LIMIT 1
RETURNING event_id;
'@
if (-not (Invoke-Psql $insert)) {
    Write-Host 'REFUSED: no real (non-test) done event exists to copy the payload from. Run scripts\e2e.ps1 first.' -ForegroundColor Red
    exit 1
}

Write-Host (Invoke-Psql "SELECT event_id, status, attempts, received_at, claimed_at, pending_since, now() AS db_now FROM stripe_events WHERE event_id = :'eid';" @())
Write-Host "Seeded $Id. If the Processor is published it will pick up pending/failed(attempts<5) rows within a minute." -ForegroundColor Green
exit 0
