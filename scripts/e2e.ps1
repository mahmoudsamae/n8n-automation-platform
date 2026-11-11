# End-to-end check for the Stripe -> n8n pipeline. Run: powershell -File scripts\e2e.ps1
# Non-destructive: stops no services and deletes no real data (its only deletes are its own evt_test_e2e_stale_* rows, via clean-test-event.ps1).
# Never prints stripe listen output (it holds the signing secret).
$ErrorActionPreference = 'Stop'

$IntakeUrl = 'http://localhost:5678/webhook/stripe-intake'
$MailpitUrl = 'http://localhost:8025'

$script:Passed = 0
$script:Failed = 0

function Write-Step([string]$Name, [bool]$Ok, [string]$Detail = '') {
    $tag = if ($Ok) { 'PASS' } else { 'FAIL' }
    $color = if ($Ok) { 'Green' } else { 'Red' }
    if ($Ok) { $script:Passed++ } else { $script:Failed++ }
    Write-Host ("[{0}] {1}" -f $tag, $Name) -ForegroundColor $color -NoNewline
    if ($Detail) { Write-Host (" - {0}" -f $Detail) } else { Write-Host '' }
}

# SQL goes in on stdin so PowerShell/wsl quoting never touches it.
function Invoke-Sql([string]$Sql) {
    $out = $Sql | wsl -d Ubuntu docker exec -i postgres psql -U automation -d automation -tA -v ON_ERROR_STOP=1
    if ($LASTEXITCODE -ne 0) { throw "psql failed (exit $LASTEXITCODE)" }
    return (@($out) | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) -join "`n"
}

function Assert-EventId([string]$Id) {
    if ($Id -notmatch '^evt_[A-Za-z0-9]+$') { throw "unexpected event id format" }
}

function Wait-Until([scriptblock]$Condition, [int]$TimeoutSec, [int]$PollSec = 2) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (& $Condition) { return $true }
        Start-Sleep -Seconds $PollSec
    }
    return [bool](& $Condition)
}

# Read a file another process is still writing, without printing it.
function Read-Shared([string]$Path) {
    try {
        $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        try { return (New-Object System.IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
    } catch { return '' }
}

function Get-Counts([string]$EventId) {
    $inv = [int](Invoke-Sql "select count(*) from invoices where event_id = '$EventId'")
    $mail = [int](Invoke-Sql "select count(*) from side_effects where event_id = '$EventId' and kind = 'email'")
    $tg = [int](Invoke-Sql "select count(*) from side_effects where event_id = '$EventId' and kind = 'telegram'")
    return @{ Invoice = $inv; Email = $mail; Telegram = $tg }
}

function Get-MailpitCount([string]$InvoiceNumber) {
    $q = [uri]::EscapeDataString("subject:`"$InvoiceNumber`"")
    $r = Invoke-RestMethod -Uri "$MailpitUrl/api/v1/search?query=$q" -TimeoutSec 10
    return @($r.messages | Where-Object { $_.Subject -like "*$InvoiceNumber*" }).Count
}

function Assert-Counts([string]$EventId, [string]$InvoiceNumber, [string]$Label) {
    $c = Get-Counts $EventId
    Write-Step "$Label`: exactly 1 invoice" ($c.Invoice -eq 1) "found $($c.Invoice)"
    Write-Step "$Label`: exactly 1 email side_effect" ($c.Email -eq 1) "found $($c.Email)"
    Write-Step "$Label`: exactly 1 telegram side_effect" ($c.Telegram -eq 1) "found $($c.Telegram)"
    $m = Get-MailpitCount $InvoiceNumber
    Write-Step "$Label`: exactly 1 Mailpit message for $InvoiceNumber" ($m -eq 1) "found $m"
}

# What one processed demo payment must have delivered: invoice row, exactly 1 German email with text + HTML and exactly 1 real PDF, and (when
# TELEGRAM_SEND_PDF=true) the Telegram document as a side effect of its own. The checks live in their own script so each can be made to fail.
function Test-Delivery([string]$EventId, [string]$InvoiceNumber, [string]$Label) {
    & "$PSScriptRoot\check-invoice-delivery.ps1" -EventId $EventId -InvoiceNumber $InvoiceNumber -ExpectTelegramDocument $script:sendPdf
    Write-Step "$Label`: invoice row, email (subject, text + HTML, exactly 1 PDF) and Telegram document are right" ($LASTEXITCODE -eq 0) "exit $LASTEXITCODE"
}

# ---------- 1. Preflight ----------
Write-Host '== 1. Preflight ==' -ForegroundColor Cyan

& "$PSScriptRoot\lint-migrations.ps1"
Write-Step 'migrations lint (no ON DELETE CASCADE)' ($LASTEXITCODE -eq 0) "exit $LASTEXITCODE"

$running = @()
try {
    $running = @(wsl -d Ubuntu bash -c "cd ~/n8n && docker compose ps --status running --services") |
        ForEach-Object { "$_".Trim() } | Where-Object { $_ }
} catch {
    Write-Step 'docker compose reachable' $false $_.Exception.Message
}

foreach ($svc in 'postgres', 'mailpit', 'n8n', 'gotenberg') {
    Write-Step "container '$svc' running" ($running -contains $svc)
}

try {
    $resp = Invoke-WebRequest -Uri 'http://localhost:5678/healthz' -UseBasicParsing -TimeoutSec 5
    Write-Step 'n8n answers on :5678' ($resp.StatusCode -eq 200) "GET /healthz -> $($resp.StatusCode)"
} catch {
    Write-Step 'n8n answers on :5678' $false $_.Exception.Message
}

# Migration 005 (M4) adds the columns the Processor, Monitor and replay.ps1 rely on.
try {
    $m5 = Invoke-Sql "select (select count(*) from information_schema.columns where table_name = 'stripe_events' and column_name in ('alerted_at', 'pending_since')) || '|' || coalesce(to_regclass('public.event_replays')::text, 'missing')"
    Write-Step 'migration 005 applied (alerted_at, pending_since, event_replays)' ($m5 -eq '2|event_replays') $m5
} catch {
    Write-Step 'migration 005 applied (alerted_at, pending_since, event_replays)' $false $_.Exception.Message
}

# Migration 006 (invoice design) adds what the invoice documents are rendered from: customer_name, payment_method, line_items.
try {
    $m6 = Invoke-Sql "select (select count(*) from information_schema.columns where table_name = 'invoices' and column_name in ('customer_name', 'payment_method', 'line_items')) || '|' || (select count(*) from pg_constraint where conname = 'invoices_document_all_or_none')"
    Write-Step 'migration 006 applied (invoice document columns and their CHECK)' ($m6 -eq '3|1') $m6
} catch {
    Write-Step 'migration 006 applied (invoice document columns and their CHECK)' $false $_.Exception.Message
}

# M5: errorWorkflow lives only in n8n (not in the .sdk.ts files), so check it on the live workflows.
& "$PSScriptRoot\check-error-workflows.ps1"
Write-Step 'errorWorkflow correct on all 7 workflows' ($LASTEXITCODE -eq 0) "exit $LASTEXITCODE"

# Every change to a live workflow must be exported to its .sdk.ts file: compile each file and diff it against the live export.
& "$PSScriptRoot\check-sdk-drift.ps1"
Write-Step 'all 7 .sdk.ts files match their live workflows' ($LASTEXITCODE -eq 0) "exit $LASTEXITCODE"

# Doc rot: CLAUDE.md within its line limit, every relative link and image in README and docs resolves (known-missing images warn).
& "$PSScriptRoot\check-docs.ps1"
Write-Step 'docs: CLAUDE.md within its line limit, no broken relative links, no public IP' ($LASTEXITCODE -eq 0) "exit $LASTEXITCODE"

# Safety guards: the hook blocks destructive text sent to an executor, and wsl-sh.ps1 refuses it before sending (samples only echo).
$null = & node "$PSScriptRoot\hooks\destructive-guard.test.mjs"
Write-Step 'destructive-guard hook: every pattern blocked, controls allowed' ($LASTEXITCODE -eq 0) "exit $LASTEXITCODE"
$null = & node "$PSScriptRoot\hooks\destructive-guard.test.mjs" --prove-failure
Write-Step 'destructive-guard test fails against allow-all and block-all stubs' ($LASTEXITCODE -eq 0) "exit $LASTEXITCODE"
$null = & "$PSScriptRoot\check-destructive-guard.ps1" -Target wsl 2>$null
Write-Step 'wsl-sh.ps1 refuses every destructive pattern (-Script, -File, piped)' ($LASTEXITCODE -eq 0) "exit $LASTEXITCODE"

# M5: the newest Postgres dump must exist, be non-empty and be younger than 25 h (the backup container dumps at start and every 24 h).
try {
    $dumps = @(wsl -d Ubuntu bash -c "docker exec postgres-backup find /backups -maxdepth 1 -name 'automation-*.dump' -size +0c -mmin -1500") |
        ForEach-Object { "$_".Trim() } | Where-Object { $_ }
    Write-Step 'Postgres backup: non-empty dump younger than 25 h' ($dumps.Count -ge 1) "$($dumps.Count) recent dump(s)"
} catch {
    Write-Step 'Postgres backup: non-empty dump younger than 25 h' $false $_.Exception.Message
}

# M5 follow-up: e2e's own psql calls use the trusted local socket, so a wrong POSTGRES_PASSWORD would pass everything above while
# every backup failed. This authenticates over TCP from the backup container with the .env password and reads its last log line.
& "$PSScriptRoot\check-backup-health.ps1"
Write-Step 'Postgres backup authenticates over TCP and its last log line is not backup FAILED' ($LASTEXITCODE -eq 0) "exit $LASTEXITCODE"

# M7b-3: workflows cannot read the environment (N8N_BLOCK_ENV_ACCESS_IN_NODE=true, no secret or config name in n8n's environment); the
# configuration lives in the data tables stripe_config and stripe_heartbeat and the signing secret in the crypto credential. Names only.
# telegram_send_pdf has no default on purpose (it decides whether customer data goes to Telegram): anything but true/false fails every event.
$envOut = @(& "$PSScriptRoot\check-n8n-env.ps1" | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
$envExit = $LASTEXITCODE
$envOut | Where-Object { $_ -like '`[FAIL`]*' } | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
Write-Step 'env access blocked, config in data tables, signing secret in the credential (check-n8n-env.ps1)' ($envExit -eq 0 -and ($envOut -contains '0 failed')) "exit $envExit"
$sendPdfLine = @($envOut | Where-Object { $_ -like 'telegram_send_pdf=*' })[0]
$sendPdf = ($sendPdfLine -eq 'telegram_send_pdf=true')

# Two listeners would forward every event twice and skew the duplicate checks.
$existing = Get-Process -Name stripe -ErrorAction SilentlyContinue
Write-Step 'no other stripe CLI process running' (-not $existing) $(if ($existing) { 'stop it first (it may be a stripe listen)' } else { '' })

if ($script:Failed -gt 0) {
    Write-Host "`nPreflight failed. Start the stack: wsl -d Ubuntu bash -c `"cd ~/n8n && docker compose up -d`"" -ForegroundColor Yellow
    exit 1
}

# ---------- 2..7 ----------
$listenProc = $null
$logOut = Join-Path ([IO.Path]::GetTempPath()) ("e2e-listen-{0}.out" -f [guid]::NewGuid().ToString('N'))
$logErr = Join-Path ([IO.Path]::GetTempPath()) ("e2e-listen-{0}.err" -f [guid]::NewGuid().ToString('N'))

try {
    # ---- 2. stripe listen in the background ----
    Write-Host "`n== 2. stripe listen ==" -ForegroundColor Cyan
    $stripeExe = (Get-Command stripe -ErrorAction Stop).Source
    $listenProc = Start-Process -FilePath $stripeExe `
        -ArgumentList @('listen', '--all-snapshot', '--forward-to', 'localhost:5678/webhook/stripe-intake') `
        -RedirectStandardOutput $logOut -RedirectStandardError $logErr -WindowStyle Hidden -PassThru
    $ready = Wait-Until { (Read-Shared $logErr) -match 'Ready!' -or (Read-Shared $logOut) -match 'Ready!' -or $listenProc.HasExited } 20 1
    $ready = $ready -and -not $listenProc.HasExited
    Write-Step 'stripe listen is ready' $ready
    if (-not $ready) { throw 'stripe listen did not become ready (output not shown: may contain a secret)' }

    # ---- 3. trigger ----
    Write-Host "`n== 3. Trigger checkout.session.completed ==" -ForegroundColor Cyan
    $t0 = Invoke-Sql 'select now()'
    # The documented demo payment (30,00 EUR "Workshop: Automatisierung mit n8n"), tagged e2e=true; it retries Stripe's Adaptive Pricing amount mismatch.
    & "$PSScriptRoot\demo-payment.ps1" -Tag e2e
    Write-Step 'demo payment fired (stripe trigger with the EUR overrides)' ($LASTEXITCODE -eq 0) "exit $LASTEXITCODE"
    if ($LASTEXITCODE -ne 0) { throw 'demo payment failed' }

    # ---- 4. find the event, wait for done ----
    Write-Host "`n== 4. Wait for the Processor ==" -ForegroundColor Cyan
    # Prefer the row carrying our e2e metadata tag; trigger fires ~7 events and only one is pending.
    $findSql = @"
select event_id from stripe_events
where event_type = 'checkout.session.completed' and status <> 'ignored'
  and received_at >= '$t0'::timestamptz
order by (payload->'data'->'object'->'metadata'->>'e2e' = 'true') desc, received_at desc
limit 1
"@
    $eventId = ''
    $found = Wait-Until { $script:eventId = Invoke-Sql $findSql; [bool]$script:eventId } 30 2
    Write-Step 'new checkout.session.completed event stored' $found $(if ($found) { $eventId } else { 'none arrived: STRIPE_WEBHOOK_SECRET may not match stripe listen (every event would get 400)' })
    if (-not $found) { throw 'event not found in stripe_events' }
    Assert-EventId $eventId

    $tagged = Invoke-Sql "select (payload->'data'->'object'->'metadata'->>'e2e' = 'true') from stripe_events where event_id = '$eventId'"
    Write-Host ("      metadata e2e=true on event: {0}" -f $(if ($tagged -eq 't') { 'yes' } else { 'no (matched by time window instead)' }))

    $done = Wait-Until {
        $s = Invoke-Sql "select status from stripe_events where event_id = '$eventId'"
        $s -eq 'done' -or $s -eq 'failed'
    } 120 3
    $row = Invoke-Sql "select status || '|' || attempts || '|' || coalesce(last_error, '') from stripe_events where event_id = '$eventId'"
    $status, $attempts, $lastError = $row -split '\|', 3
    Write-Step 'event reached status done' ($status -eq 'done') "status=$status attempts=$attempts$(if ($lastError) { " last_error=$lastError" })"
    if ($status -ne 'done') { throw 'event never reached done' }

    # ---- 5. assertions ----
    Write-Host "`n== 5. First-delivery assertions ==" -ForegroundColor Cyan
    $invoiceNumber = Invoke-Sql "select invoice_number from invoices where event_id = '$eventId'"
    Assert-Counts $eventId $invoiceNumber 'first delivery'
    Test-Delivery $eventId $invoiceNumber 'first delivery'

    # ---- 6. resend (intake dedupe) ----
    Write-Host "`n== 6. Resend the same event ==" -ForegroundColor Cyan
    $null = & stripe events resend $eventId
    Write-Step 'stripe events resend succeeded' ($LASTEXITCODE -eq 0) "exit $LASTEXITCODE"
    # Wait until the listener has forwarded the event a second time (matched in the log, never printed).
    $pattern = "-->.*\[$eventId\]"
    $forwarded = Wait-Until {
        $log = (Read-Shared $logOut) + (Read-Shared $logErr)
        ([regex]::Matches($log, $pattern)).Count -ge 2
    } 30 2
    Write-Step 'resend was forwarded to intake' $forwarded
    Start-Sleep -Seconds 5   # let intake finish its insert/no-op
    $rows = [int](Invoke-Sql "select count(*) from stripe_events where event_id = '$eventId'")
    Write-Step 'resend: still exactly 1 stripe_events row' ($rows -eq 1) "found $rows"
    Assert-Counts $eventId $invoiceNumber 'after resend'
    Test-Delivery $eventId $invoiceNumber 'after resend'

    # ---- 6b. Processor idempotency ----
    Write-Host "`n== 6b. Re-run the Processor on the same event ==" -ForegroundColor Cyan
    $attemptsBefore = [int](Invoke-Sql "select attempts from stripe_events where event_id = '$eventId'")
    $null = Invoke-Sql "update stripe_events set status = 'pending', claimed_at = null where event_id = '$eventId'"
    $reDone = Wait-Until {
        $s = Invoke-Sql "select status from stripe_events where event_id = '$eventId'"
        $s -eq 'done' -or $s -eq 'failed'
    } 120 3
    $row = Invoke-Sql "select status || '|' || attempts || '|' || coalesce(last_error, '') from stripe_events where event_id = '$eventId'"
    $status, $attemptsAfter, $lastError = $row -split '\|', 3
    Write-Step 'Processor picked the event up again and finished' ($reDone -and $status -eq 'done') "status=$status$(if ($lastError) { " last_error=$lastError" })"
    # Without this, unchanged counts would prove nothing: the Processor must really have re-run.
    Write-Step 'attempts increased (proves a real re-run)' ([int]$attemptsAfter -gt $attemptsBefore) "$attemptsBefore -> $attemptsAfter"
    Assert-Counts $eventId $invoiceNumber 'after Processor re-run'
    Test-Delivery $eventId $invoiceNumber 'after Processor re-run'

    # ---- 6c. replay safety ----
    Write-Host "`n== 6c. replay.ps1 refuses what it must refuse ==" -ForegroundColor Cyan
    $rowBefore = Invoke-Sql "select status || '|' || attempts || '|' || pending_since from stripe_events where event_id = '$eventId'"
    $replaysBefore = [int](Invoke-Sql "select count(*) from event_replays where event_id = '$eventId'")
    $null = & "$PSScriptRoot\replay.ps1" -EventId $eventId -Reason 'e2e: a done event must be refused'
    Write-Step 'replay.ps1 refuses a done event (exit 1)' ($LASTEXITCODE -eq 1) "exit $LASTEXITCODE"
    $rowAfter = Invoke-Sql "select status || '|' || attempts || '|' || pending_since from stripe_events where event_id = '$eventId'"
    Write-Step 'refused replay left the event row unchanged' ($rowAfter -eq $rowBefore)
    $replaysAfter = [int](Invoke-Sql "select count(*) from event_replays where event_id = '$eventId'")
    Write-Step 'refused replay wrote no event_replays row' ($replaysAfter -eq $replaysBefore) "found $replaysAfter"
    $null = & "$PSScriptRoot\replay.ps1" -EventId "x'; drop table stripe_events;--" -Reason 'e2e: malformed id'
    Write-Step 'replay.ps1 rejects a malformed event id (exit 2)' ($LASTEXITCODE -eq 2) "exit $LASTEXITCODE"
    $stillThere = [int](Invoke-Sql 'select count(*) from stripe_events')
    Write-Step 'stripe_events still exists after the malformed-id attempt' ($stillThere -gt 0) "rows $stillThere"

    # ---- 7. bad signature ----
    Write-Host "`n== 7. Fake-signed request ==" -ForegroundColor Cyan
    $ts = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()   # not Get-Date -UFormat %s: that is the LOCAL epoch in Windows PowerShell 5.1
    $code = $null
    try {
        $r = Invoke-WebRequest -Uri $IntakeUrl -Method Post -UseBasicParsing -ContentType 'application/json' `
            -Headers @{ 'Stripe-Signature' = "t=$ts,v1=$('0' * 64)" } -Body '{"id":"evt_fake_e2e","type":"checkout.session.completed"}'
        $code = [int]$r.StatusCode
    } catch {
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode } else { throw }
    }
    Write-Step 'fake signature rejected with 400' ($code -eq 400) "got $code"
    $leak = [int](Invoke-Sql "select count(*) from stripe_events where event_id = 'evt_fake_e2e'")
    Write-Step 'fake event was not stored' ($leak -eq 0) "found $leak"

    # ---- 7b. stale timestamp ----
    Write-Host "`n== 7b. Validly signed request with a stale timestamp ==" -ForegroundColor Cyan
    # Its own script so each failure path can be provoked on its own. Stores and removes two evt_test_e2e_stale_* rows.
    & "$PSScriptRoot\check-stale-timestamp.ps1"
    Write-Step 'stale timestamp rejected (400, not stored) and the fresh signed control accepted' ($LASTEXITCODE -eq 0) "exit $LASTEXITCODE"
}
catch {
    Write-Step 'script aborted' $false $_.Exception.Message
}
finally {
    if ($listenProc -and -not $listenProc.HasExited) { Stop-Process -Id $listenProc.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $logOut, $logErr -Force -ErrorAction SilentlyContinue
}

# ---------- 8. Summary ----------
Write-Host "`n== Summary ==" -ForegroundColor Cyan
$total = $script:Passed + $script:Failed
$color = if ($script:Failed -eq 0) { 'Green' } else { 'Red' }
Write-Host ("{0}/{1} checks passed, {2} failed" -f $script:Passed, $total, $script:Failed) -ForegroundColor $color
if ($script:Failed -eq 0) { exit 0 } else { exit 1 }
