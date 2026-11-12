# Send ONE failed Stripe event back to the Processor queue, with an audit row in event_replays.
#   powershell -File scripts\replay.ps1 -EventId evt_123 -Reason "Mailpit was down" [-DryRun]
# Exit codes: 0 replayed (or dry run OK), 1 refused (not found / not 'failed' / state changed), 2 bad arguments.
# Safe by design:
#   - the id must match ^evt_[A-Za-z0-9_]+$ and travels as a psql variable, never inside SQL text;
#   - the free-text reason travels base64-encoded and is decoded inside Postgres, so no quoting can break out of it;
#   - side_effects and invoices are never touched, so a replay cannot double-send an email/Telegram or double-invoice.
param(
    [Parameter(Mandatory = $true)][string]$EventId,
    [Parameter(Mandatory = $true)][string]$Reason,
    [switch]$DryRun,
    [ValidateSet('Laptop', 'Server')][string]$Target = 'Laptop'
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\target.ps1"
$T = Get-Target $Target

if ($EventId -cnotmatch '^evt_[A-Za-z0-9_]+\z') {
    Write-Host 'REFUSED: -EventId must match ^evt_[A-Za-z0-9_]+$' -ForegroundColor Red
    exit 2
}
$reasonText = $Reason.Trim()
if (-not $reasonText) {
    Write-Host 'REFUSED: -Reason must not be empty' -ForegroundColor Red
    exit 2
}
if ($reasonText.Length -gt 500) {
    Write-Host 'REFUSED: -Reason is longer than 500 characters' -ForegroundColor Red
    exit 2
}
$reasonB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($reasonText))

# SQL goes in on stdin; the only command-line values are the validated id and the base64 reason (both shell-safe characters).
function Invoke-Psql([string]$Sql, [string[]]$Flags = @('-tA', '-q')) {
    if ($Target -eq 'Laptop') {
        $out = $Sql | wsl -d Ubuntu docker exec -i postgres psql -U automation -d automation -v ON_ERROR_STOP=1 @Flags -v "eid=$EventId" -v "reason_b64=$reasonB64"
    } else {
        # Same values, inside single quotes in bash (both are validated above to shell-safe characters), SQL in a quoted heredoc.
        if ($Sql -match '(?m)^REPLAY_SQL$') { throw 'SQL contains the heredoc delimiter' }
        $sh = "docker exec -i postgres psql -U automation -d automation -v ON_ERROR_STOP=1 $($Flags -join ' ') -v 'eid=$EventId' -v 'reason_b64=$reasonB64' <<'REPLAY_SQL'`n$Sql`nREPLAY_SQL"
        $out = Invoke-TargetSh $T $sh
    }
    if ($LASTEXITCODE -ne 0) { throw "psql failed (exit $LASTEXITCODE)" }
    return (@($out) | ForEach-Object { "$_".TrimEnd() } | Where-Object { $_ }) -join "`n"
}

$showRow = @'
SELECT event_id, event_type, status, attempts, left(coalesce(last_error, ''), 120) AS last_error, pending_since, alerted_at
FROM stripe_events WHERE event_id = :'eid';
'@

$status = Invoke-Psql "SELECT status FROM stripe_events WHERE event_id = :'eid';"
if (-not $status) {
    Write-Host "REFUSED: $EventId does not exist in stripe_events" -ForegroundColor Red
    exit 1
}
if ($status -ne 'failed') {
    Write-Host "REFUSED: $EventId has status '$status'. Only 'failed' events can be replayed." -ForegroundColor Red
    exit 1
}

Write-Host 'Before:'
Write-Host (Invoke-Psql $showRow @())

if ($DryRun) {
    Write-Host "`nDRY RUN: nothing changed. Would set status=pending, attempts=0, alerted_at=NULL, pending_since=now() and add one event_replays row." -ForegroundColor Yellow
    exit 0
}

# One transaction; the status = 'failed' guard makes it a no-op if the Processor changed the row since the check above.
$replaySql = @'
BEGIN;
WITH upd AS (
    UPDATE stripe_events
    SET status = 'pending', attempts = 0, alerted_at = NULL, pending_since = now()
    WHERE event_id = :'eid' AND status = 'failed'
    RETURNING event_id
)
INSERT INTO event_replays (event_id, reason)
SELECT event_id, convert_from(decode(:'reason_b64', 'base64'), 'UTF8') FROM upd
RETURNING replay_id;
COMMIT;
'@
$replayId = Invoke-Psql $replaySql
if (-not $replayId) {
    Write-Host 'REFUSED: the row changed state between the check and the update; nothing was replayed. Re-check and retry.' -ForegroundColor Red
    exit 1
}

Write-Host "`nAfter:"
Write-Host (Invoke-Psql $showRow @())
Write-Host "`nReplayed: event_replays.replay_id = $replayId. The Processor picks it up within a minute." -ForegroundColor Green
exit 0
