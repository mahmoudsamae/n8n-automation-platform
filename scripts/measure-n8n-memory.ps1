# Measures the server's n8n container memory in the phases that load it (M7b-7). The 24.04 kernel cannot reset cgroup memory.peak, so a
# sampler on the server reads memory.current once a second during each phase; the result is that phase's peak against the container limit,
# plus the cgroup's oom_kill count before and after. Why: n8n was OOM-killed on the laptop on 9 Nov at 1.38 GB, cause unproven.
#   idle      nothing but the schedules (Processor every minute, Monitor every 5 min), -IdleMinutes long
#   payments  -Payments real sandbox payments (demo-payment.ps1 -Target Server -Tag e2e), each rendered to a PDF by Gotenberg, until all are done
#   exports   the checks that start extra n8n processes in the container (check-error-workflows, check-sdk-drift) and one real backup run
#   overlap   one payment while the export check runs over and over, so an export coincides with the Processor's render
# Run: powershell -File scripts\measure-n8n-memory.ps1 [-Phases idle,payments,exports,overlap] [-IdleMinutes 30] [-Payments 10]
# Exit 0 = every peak at most -MaxPercent (75) of the limit and no new oom_kill; 1 = above it (raise the limit and/or cap V8, measure again).
# Prove it can fail: -MaxPercent 10. Prints sizes and counts only.
param(
    [ValidateSet('idle', 'payments', 'exports', 'overlap')][string[]]$Phases = @('idle', 'payments', 'exports', 'overlap'),
    [ValidateRange(1, 180)][int]$IdleMinutes = 30,
    [ValidateRange(1, 20)][int]$Payments = 10,
    [ValidateRange(1, 100)][int]$MaxPercent = 75
)
$ErrorActionPreference = 'Stop'
$failed = 0
function Write-Step([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { Write-Host "[PASS] $Name" -ForegroundColor Green -NoNewline } else { Write-Host "[FAIL] $Name" -ForegroundColor Red -NoNewline; $script:failed++ }
    if ($Detail) { Write-Host " - $Detail" } else { Write-Host '' }
}
function Invoke-Server([string]$Sh) {
    $out = @(& "$PSScriptRoot\server-sh.ps1" -Script $Sh)
    if ($LASTEXITCODE -ne 0) { throw "server command failed (exit $LASTEXITCODE)" }
    $v = @{}; foreach ($l in $out) { $i = "$l".IndexOf('='); if ($i -gt 0) { $v["$l".Substring(0, $i)] = "$l".Substring($i + 1).Trim() } }
    return $v
}

$cgSh = 'cg="/sys/fs/cgroup/system.slice/docker-$(docker inspect -f "{{.Id}}" n8n).scope"; [ -r "$cg/memory.current" ] || { echo "nocg=1"; exit 1; }'
$startSh = $cgSh + @'

# A sampler left by a run that died (seen 2026-11-12: the laptop side was killed) ends itself after 2 h; its stale pidfile is cleared here.
if [ -e /dev/shm/n8n-mem.pid ]; then
  if kill -0 "$(cat /dev/shm/n8n-mem.pid)" 2>/dev/null; then echo "busy=1"; exit 1; fi
  rm -f /dev/shm/n8n-mem.pid /dev/shm/n8n-mem.samples
fi
echo "limit=$(cat $cg/memory.max)"
echo "oom=$(awk '$1=="oom_kill"{print $2}' $cg/memory.events)"
nohup timeout 7200 sh -c "while :; do cat $cg/memory.current; sleep 1; done" > /dev/shm/n8n-mem.samples 2>/dev/null &
echo $! > /dev/shm/n8n-mem.pid
'@
$stopSh = $cgSh + @'

kill "$(cat /dev/shm/n8n-mem.pid)" 2>/dev/null
echo "oom=$(awk '$1=="oom_kill"{print $2}' $cg/memory.events)"
echo "samples=$(wc -l < /dev/shm/n8n-mem.samples)"
echo "peak=$(sort -n /dev/shm/n8n-mem.samples | tail -1)"
echo "first=$(head -1 /dev/shm/n8n-mem.samples)"
rm -f /dev/shm/n8n-mem.pid /dev/shm/n8n-mem.samples
'@
$countSh = 'echo "invoices=$(docker exec postgres psql -U automation -d automation -tAc "select count(*) from invoices")"; echo "open=$(docker exec postgres psql -U automation -d automation -tAc "select count(*) from stripe_events where status in (''pending'',''processing'')")"'

function Wait-Invoices([int]$Before, [int]$Expected, [int]$TimeoutMinutes = 10) {
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    do {
        Start-Sleep -Seconds 15
        $c = Invoke-Server $countSh
        if ([int]$c.invoices -ge $Before + $Expected -and [int]$c.open -eq 0) { return [int]$c.invoices - $Before }
    } while ((Get-Date) -lt $deadline)
    return [int]$c.invoices - $Before
}

$results = @()
foreach ($phase in $Phases) {
    Write-Host "--- phase $phase, started $([DateTimeOffset]::UtcNow.ToString('HH:mm:ss')) UTC"
    $s = Invoke-Server $startSh
    $note = ''
    try {
        switch ($phase) {
            'idle' { Start-Sleep -Seconds ($IdleMinutes * 60); $note = "$IdleMinutes min" }
            'payments' {
                $before = [int](Invoke-Server $countSh).invoices
                $fired = 0
                for ($i = 1; $i -le $Payments; $i++) { & "$PSScriptRoot\demo-payment.ps1" -Target Server -Tag e2e *> $null; if ($LASTEXITCODE -eq 0) { $fired++ } }
                $done = Wait-Invoices $before $fired
                Write-Step "payments: $fired fired, all invoiced" ($fired -eq $Payments -and $done -eq $fired) "$done new invoices"
                $note = "$fired payments"
            }
            'exports' {
                & "$PSScriptRoot\check-error-workflows.ps1" -Target Server *> $null; $a = $LASTEXITCODE
                & "$PSScriptRoot\check-sdk-drift.ps1" -Target Server *> $null; $b = $LASTEXITCODE
                $null = & "$PSScriptRoot\server-sh.ps1" -Script 'sudo systemctl start backup-offsite.service'; $c = $LASTEXITCODE
                Write-Step 'exports: check-error-workflows, check-sdk-drift, backup run all ran' ($a -eq 0 -and $b -eq 0 -and $c -eq 0) "exit $a / $b / $c"
                $note = 'error-workflows + sdk-drift + backup'
            }
            'overlap' {
                $before = [int](Invoke-Server $countSh).invoices
                & "$PSScriptRoot\demo-payment.ps1" -Target Server -Tag e2e *> $null
                $fired = [int]($LASTEXITCODE -eq 0)
                # The Processor claims within a minute: keep an export running across the next 2 minutes so one coincides with the render.
                $end = (Get-Date).AddSeconds(120); $runs = 0
                while ((Get-Date) -lt $end) { & "$PSScriptRoot\check-error-workflows.ps1" -Target Server *> $null; $runs++ }
                $done = Wait-Invoices $before $fired
                Write-Step 'overlap: payment invoiced while exports ran' ($fired -eq 1 -and $done -eq 1) "$runs export checks, $done invoice"
                $note = "1 payment, $runs export checks"
            }
        }
    }
    finally {
        $e = Invoke-Server $stopSh
    }
    $limitMb = [math]::Round([double]$s.limit / 1MB)
    $peakMb = [math]::Round([double]$e.peak / 1MB)
    $pct = [math]::Round(100 * [double]$e.peak / [double]$s.limit, 1)
    $results += [pscustomobject]@{ Phase = $phase; Note = $note; Samples = $e.samples; StartMB = [math]::Round([double]$e.first / 1MB); PeakMB = $peakMb; LimitMB = $limitMb; Percent = $pct; OomKills = [int]$e.oom - [int]$s.oom }
    Write-Step "${phase}: peak at most $MaxPercent% of the limit" ($pct -le $MaxPercent) "peak $peakMb MB of $limitMb MB ($pct%), $($e.samples) samples"
    Write-Step "${phase}: no oom_kill" (([int]$e.oom - [int]$s.oom) -eq 0) "oom_kill $($s.oom) -> $($e.oom)"
}
$results | Format-Table -AutoSize | Out-String | Write-Host
Write-Output ("{0} failed" -f $failed)
if ($failed -gt 0) { exit 1 }
exit 0
