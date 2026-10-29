# End-to-end check for the Stripe -> n8n pipeline. Run: powershell -File scripts\e2e.ps1
# Non-destructive: stops no services, deletes no rows. Never prints stripe listen output (it holds the signing secret).
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

foreach ($svc in 'postgres', 'mailpit', 'n8n') {
    Write-Step "container '$svc' running" ($running -contains $svc)
}

try {
    $resp = Invoke-WebRequest -Uri 'http://localhost:5678/healthz' -UseBasicParsing -TimeoutSec 5
    Write-Step 'n8n answers on :5678' ($resp.StatusCode -eq 200) "GET /healthz -> $($resp.StatusCode)"
} catch {
    Write-Step 'n8n answers on :5678' $false $_.Exception.Message
}

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
    $null = & stripe trigger checkout.session.completed --add 'checkout_session:metadata[e2e]=true'
    Write-Step 'stripe trigger succeeded' ($LASTEXITCODE -eq 0) "exit $LASTEXITCODE"
    if ($LASTEXITCODE -ne 0) { throw 'stripe trigger failed' }

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

    # ---- 7. bad signature ----
    Write-Host "`n== 7. Fake-signed request ==" -ForegroundColor Cyan
    $ts = [int][double]::Parse((Get-Date -UFormat %s))
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
