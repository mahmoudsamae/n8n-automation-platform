# Fails if the Postgres backup cannot work. e2e's own psql calls use the trusted local socket (pg_hba trusts loopback inside the
# postgres container), so a wrong POSTGRES_PASSWORD would not fail e2e while every backup failed for up to 25 h.
#   1. TCP auth (scram) from the backup container to postgres, with the password from ~/n8n/.env
#   2. the backup container was created with that same password (a recreate was not forgotten after a rotation)
#   3. the backup container's last log line is not "backup FAILED"
# Run: powershell -File scripts\check-backup-health.ps1 [-Container postgres-backup]   Exit 0 = all pass, 1 = any fail.
# Prints yes/no only, never a password. For tests, $env:PGPASSWORD overrides the password from .env (proves the check can fail);
# the override must be a plain word, it is a throwaway test value and not a real secret.
# A FAIL on check 3 right after a Postgres restart clears itself: the container retries 5 minutes after a failed dump.
param([string]$Container = 'postgres-backup')
$ErrorActionPreference = 'Stop'

if ($Container -notmatch '^[a-z0-9][a-z0-9_-]{0,63}$') { throw "unexpected container name: $Container" }
$override = [string]$env:PGPASSWORD
if ($override -and $override -notmatch '^[A-Za-z0-9._-]{1,64}$') { throw 'PGPASSWORD override must match ^[A-Za-z0-9._-]{1,64}$' }

# Runs inside WSL as base64 so no PowerShell/wsl quoting touches it (see CLAUDE.md gotchas).
$sh = @'
set +x
c=__CONTAINER__
override='__OVERRIDE__'
envpw=$(grep -E '^POSTGRES_PASSWORD=' ~/n8n/.env | cut -d= -f2-)
if [ -n "$override" ]; then pw="$override"; echo "note:override"; else pw="$envpw"; fi
if ! docker ps --format '{{.Names}}' | grep -qx "$c"; then echo "running:no"; exit 0; fi
echo "running:yes"
export PGPASSWORD="$pw"
out=$(docker exec -e PGPASSWORD "$c" psql -h postgres -U automation -d automation -tAc 'select 1' 2>/dev/null)
unset PGPASSWORD
if [ "$out" = "1" ]; then echo "tcp:yes"; else echo "tcp:no"; fi
cpw=$(docker exec "$c" printenv PGPASSWORD 2>/dev/null)
if [ -n "$envpw" ] && [ "$cpw" = "$envpw" ]; then echo "same:yes"; else echo "same:no"; fi
last=$(docker logs --tail 1 "$c" 2>&1 | tr -d '\r' | cut -c1-100)
case "$last" in
  "") echo "log:empty";;
  "backup FAILED"*) echo "log:failed:$last";;
  *) echo "log:ok:$last";;
esac
'@
$sh = $sh.Replace('__CONTAINER__', $Container).Replace('__OVERRIDE__', $override)
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($sh -replace "`r", '')))
$lines = @(wsl -d Ubuntu bash -c "echo $b64 | base64 -d | bash") | ForEach-Object { "$_".Trim() } | Where-Object { $_ }
$r = @{}
foreach ($l in $lines) { $k, $v = $l -split ':', 2; $r[$k] = $v }

$failed = 0
function Show([string]$Name, [bool]$Ok, [string]$Detail = '') {
    $tag = if ($Ok) { 'PASS' } else { 'FAIL' }
    $color = if ($Ok) { 'Green' } else { 'Red' }
    if (-not $Ok) { $script:failed++ }
    Write-Host ("[{0}] {1}" -f $tag, $Name) -ForegroundColor $color -NoNewline
    if ($Detail) { Write-Host (" - {0}" -f $Detail) } else { Write-Host '' }
}

if ($r.ContainsKey('note')) { Write-Host 'note: PGPASSWORD override active, the password from .env is NOT used for the TCP check' -ForegroundColor Yellow }
Show "container '$Container' is running" ($r['running'] -eq 'yes')
if ($r['running'] -eq 'yes') {
    Show "TCP auth from '$Container' to postgres with the .env password" ($r['tcp'] -eq 'yes') "authenticated: $($r['tcp'])"
    Show "'$Container' was created with the current .env password" ($r['same'] -eq 'yes') "same password: $($r['same'])"
    $logOk = $r['log'] -like 'ok:*'
    $last = if ($r['log'] -match '^(ok|failed):(.*)$') { $Matches[2] } else { '(no log lines yet)' }
    Show "last log line of '$Container' is not 'backup FAILED'" $logOk "last line: $last"
}

if ($failed -gt 0) { exit 1 }
exit 0
