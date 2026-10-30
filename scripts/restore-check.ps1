# Proves the newest Postgres dump really restores, without touching the live database.
# Restores into a throwaway container with NO network, then compares row counts (and the invoice sequence) with live.
# Run: powershell -File scripts\restore-check.ps1 [-Fresh]   Exit 0 = restore works and matches live, 1 = problem.
# -Fresh restarts postgres-backup first (it dumps on start), so the dump is seconds old and counts can match live.
# Without -Fresh, events that arrived after the dump make the counts differ: that is a FAIL here, rerun with -Fresh.
param([switch]$Fresh)
$ErrorActionPreference = 'Stop'

$Name = 'pg-restore-check'
$Db = 'restorecheck'
# One line, same shape for live and restored: "events,side_effects,invoices,replays,sequence".
$CountsSql = "select (select count(*) from stripe_events) || ',' || (select count(*) from side_effects) || ',' || (select count(*) from invoices) || ',' || (select count(*) from event_replays) || ',' || (select last_value || '/' || is_called from invoice_number_seq);"
$Labels = 'stripe_events', 'side_effects', 'invoices', 'event_replays', 'invoice_number_seq'

function Write-Step([string]$Name, [bool]$Ok, [string]$Detail = '') {
    $tag = if ($Ok) { 'PASS' } else { 'FAIL' }
    $color = if ($Ok) { 'Green' } else { 'Red' }
    Write-Host ("[{0}] {1}" -f $tag, $Name) -ForegroundColor $color -NoNewline
    if ($Detail) { Write-Host (" - {0}" -f $Detail) } else { Write-Host '' }
}

# Scripts travel as base64 and are decoded inside WSL: no PowerShell/wsl quoting and no stdin BOM (PS 5.1 adds one) can touch them.
# $Command must be plain words (no spaces or shell characters inside a word).
function Invoke-Piped([string]$Text, [string[]]$Command) {
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Text -replace "`r", '')))
    $out = wsl -d Ubuntu bash -c ("echo $b64 | base64 -d | " + ($Command -join ' '))
    if ($LASTEXITCODE -ne 0) { throw "$($Command -join ' ') failed (exit $LASTEXITCODE)" }
    return (@($out) | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) -join "`n"
}

# "path|age in seconds" of the newest dump, read inside the backup container.
function Get-NewestDump {
    $sh = 'f=$(ls -1t /backups/automation-*.dump 2>/dev/null | head -1); [ -n "$f" ] || exit 3; echo "$f|$(( $(date +%s) - $(stat -c %Y "$f") ))"'
    return Invoke-Piped $sh @('docker', 'exec', '-i', 'postgres-backup', 'sh')
}

function Remove-Throwaway {
    $stale = @(wsl -d Ubuntu docker ps -aq --filter "name=$Name") | Where-Object { $_ }
    if ($stale) { $null = wsl -d Ubuntu docker rm -f $Name }
}

$failed = $false
try {
    if ($Fresh) {
        $before = (Get-NewestDump) -split '\|' | Select-Object -First 1
        $null = wsl -d Ubuntu docker restart postgres-backup
        $deadline = (Get-Date).AddSeconds(60)
        $now = $before
        while ($now -eq $before -and (Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 2
            $now = (Get-NewestDump) -split '\|' | Select-Object -First 1
        }
        Write-Step 'fresh dump written by postgres-backup' ($now -ne $before) $now
        if ($now -eq $before) { throw 'no new dump within 60 s (is postgres running?)' }
    }

    $dumpPath, $age = (Get-NewestDump) -split '\|'
    if ($dumpPath -notmatch '^/backups/automation-\d{8}T\d{6}Z\.dump$') { throw "unexpected dump name: $dumpPath" }
    Write-Step 'newest dump found' $true ("{0}, {1} min old" -f ($dumpPath -replace '^/backups/', ''), [math]::Round([int]$age / 60, 1))

    Remove-Throwaway
    # trust auth is safe here: the container has no network, so nothing outside it can connect.
    # Only the backups folder is mounted (read-only). $HOME is expanded by bash inside WSL.
    $null = wsl -d Ubuntu bash -c ('docker run -d --rm --name ' + $Name + ' --network none -v $HOME/n8n/backups:/backups:ro -e POSTGRES_HOST_AUTH_METHOD=trust postgres:17-alpine')
    if ($LASTEXITCODE -ne 0) { throw 'could not start the throwaway container' }

    $ready = $false
    for ($i = 0; $i -lt 30 -and -not $ready; $i++) {
        $running = @(wsl -d Ubuntu docker ps -q --filter "name=$Name") | Where-Object { $_ }
        if (-not $running) { throw 'throwaway container exited during startup' }
        $null = wsl -d Ubuntu docker exec $Name pg_isready -q -h localhost -U postgres   # -q: silent, exit 0 when ready
        $ready = ($LASTEXITCODE -eq 0)
        if (-not $ready) { Start-Sleep -Seconds 2 }
    }
    Write-Step 'throwaway postgres (no network) is up' $ready
    if (-not $ready) { throw 'throwaway postgres did not become ready' }

    $null = wsl -d Ubuntu docker exec $Name createdb -h localhost -U postgres $Db
    if ($LASTEXITCODE -ne 0) { throw 'createdb failed' }
    $null = wsl -d Ubuntu docker exec $Name pg_restore -h localhost -U postgres -d $Db --no-owner --exit-on-error $dumpPath
    Write-Step 'pg_restore finished without errors' ($LASTEXITCODE -eq 0) "exit $LASTEXITCODE"
    if ($LASTEXITCODE -ne 0) { throw 'pg_restore failed' }

    $live = (Invoke-Piped $CountsSql @('docker', 'exec', '-i', 'postgres', 'psql', '-U', 'automation', '-d', 'automation', '-tA')) -split ','
    $restored = (Invoke-Piped $CountsSql @('docker', 'exec', '-i', $Name, 'psql', '-h', 'localhost', '-U', 'postgres', '-d', $Db, '-tA')) -split ','
    for ($i = 0; $i -lt $Labels.Count; $i++) {
        $same = ($live[$i] -eq $restored[$i])
        Write-Step ("{0}: restored matches live" -f $Labels[$i]) $same ("live={0} restored={1}" -f $live[$i], $restored[$i])
        if (-not $same) { $failed = $true }
    }
    if ($failed) { Write-Host 'Counts differ. If events arrived after the dump, rerun with -Fresh.' -ForegroundColor Yellow }
}
catch {
    Write-Step 'restore check aborted' $false $_.Exception.Message
    $failed = $true
}
finally {
    Remove-Throwaway
}

if ($failed) { exit 1 }
exit 0
