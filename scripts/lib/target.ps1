# Where a check runs: the laptop stack in WSL, or the M7 server over Tailscale. Dot-source it: . "$PSScriptRoot\lib\target.ps1"
# Everything that differs between the two lives here, so e2e and the checks only ask "run this bash / this SQL on the target".
# Both runners send the text as base64 (wsl-sh.ps1, server-sh.ps1), so the destructive-command guard checks it before it leaves.
# The container names are the same on both (n8n, postgres, mailpit, gotenberg), so the bash that runs there is the same too.

function Get-Target([ValidateSet('Laptop', 'Server')][string]$Name = 'Laptop') {
    $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    if ($Name -eq 'Laptop') {
        return [pscustomobject]@{
            Name = 'Laptop'
            Runner = Join-Path $root 'scripts\wsl-sh.ps1'
            N8nUrl = 'http://localhost:5678'
            MailpitUrl = 'http://localhost:8025'
            IntakeUrl = 'http://localhost:5678/webhook/stripe-intake'
            ComposeDir = '~/n8n'
            ComposeArgs = ''
            EnvFile = '~/n8n/.env'
            # The Stripe CLI profile whose sandbox delivers to this target, and that sandbox's display name (checked before every payment).
            StripeProject = 'default'
            StripeAccountName = 'Automation sandbox'
            IdMap = $null
            Tunnel = $null
        }
    }
    return [pscustomobject]@{
        Name = 'Server'
        Runner = Join-Path $root 'scripts\server-sh.ps1'
        # Through the SSH tunnel that Open-TargetTunnel starts. Not 5678/8025 (the laptop stack) and not 15678/18025 (the admin tunnel in
        # runbook section 11, often open in another window): e2e found its port taken by exactly that tunnel in M7b-4.
        N8nUrl = 'http://127.0.0.1:25678'
        MailpitUrl = 'http://127.0.0.1:28025'
        IntakeUrl = 'https://invoice.mahmud-alhussen.de/webhook/stripe-intake'
        ComposeDir = '~/n8n-workflows'
        ComposeArgs = '-f docker-compose.prod.yml'
        EnvFile = '~/n8n-workflows/.env'
        StripeProject = 'm7-server'
        StripeAccountName = 'New business sandbox'
        # Credential and data table ids differ per n8n instance; the .sdk.ts files carry the laptop's. Ids are not secret.
        IdMap = Join-Path $root 'infra\n8n-ids.server.json'
        Tunnel = [pscustomobject]@{ Host = 'ubuntu@m7-server'; KeyFile = (Join-Path $HOME '.ssh\oci_m7'); N8nPort = 25678; MailpitPort = 28025; N8n = '25678:172.30.0.10:5678'; Mailpit = '28025:172.30.0.11:8025' }
    }
}

# Runs bash on the target. Returns the output lines; $LASTEXITCODE is the script's exit code.
function Invoke-TargetSh($Target, [string]$Script) {
    return @(& $Target.Runner -Script $Script)
}

# Runs SQL as the owner role over the local socket inside the postgres container. Same contract as e2e's old Invoke-Sql:
# trimmed, non-empty lines joined with newlines; throws on any psql error.
function Invoke-TargetSql($Target, [string]$Sql) {
    if ($Target.Name -eq 'Laptop') {
        # SQL on stdin, so neither PowerShell nor wsl quoting touches it.
        $out = $Sql | wsl -d Ubuntu docker exec -i postgres psql -U automation -d automation -tA -v ON_ERROR_STOP=1
    } else {
        # A quoted heredoc: bash expands nothing inside it.
        if ($Sql -match '(?m)^E2E_SQL$') { throw 'SQL contains the heredoc delimiter' }
        $out = Invoke-TargetSh $Target ("docker exec -i postgres psql -U automation -d automation -tA -v ON_ERROR_STOP=1 <<'E2E_SQL'`n" + $Sql + "`nE2E_SQL")
    }
    if ($LASTEXITCODE -ne 0) { throw "psql failed on $($Target.Name) (exit $LASTEXITCODE)" }
    return (@($out) | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) -join "`n"
}

function Test-LocalPort([int]$Port) {
    $c = New-Object Net.Sockets.TcpClient
    try { $c.Connect('127.0.0.1', $Port); return $true } catch { return $false } finally { $c.Dispose() }
}

# Server only: forwards the n8n and Mailpit ports over Tailscale (Windows OpenSSH; Git Bash's ssh is refused on this setup).
# ExitOnForwardFailure makes ssh quit when a local port is taken, so a stale tunnel or another program cannot answer in its place.
# Returns the ssh process (close it with Close-TargetTunnel), $null for the laptop. Throws if n8n's /healthz does not answer within 20 s.
function Open-TargetTunnel($Target) {
    if (-not $Target.Tunnel) { return $null }
    $t = $Target.Tunnel
    foreach ($p in $t.N8nPort, $t.MailpitPort) { if (Test-LocalPort $p) { throw "local port $p is already in use (an old e2e tunnel?): close it first" } }
    $ssh = Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
    $proc = Start-Process -FilePath $ssh -WindowStyle Hidden -PassThru -ArgumentList @(
        '-N', '-i', "`"$($t.KeyFile)`"", '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15', '-o', 'ExitOnForwardFailure=yes',
        '-o', 'ServerAliveInterval=15', '-L', $t.N8n, '-L', $t.Mailpit, $t.Host)
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline -and -not $proc.HasExited) {
        try {
            $r = Invoke-WebRequest -Uri "$($Target.N8nUrl)/healthz" -UseBasicParsing -TimeoutSec 3
            if ($r.StatusCode -eq 200) { return $proc }
        } catch { }
        Start-Sleep -Milliseconds 500
    }
    Close-TargetTunnel $proc
    throw "SSH tunnel to $($t.Host) did not come up (n8n /healthz on $($Target.N8nUrl) never answered 200)"
}

function Close-TargetTunnel($Proc) {
    if ($Proc -and -not $Proc.HasExited) { Stop-Process -Id $Proc.Id -Force -ErrorAction SilentlyContinue }
}

# The Stripe CLI keeps a CURRENT profile in its config, and `stripe login --project-name X` switches it to X (seen in M7b-4: a laptop
# trigger would have gone to the server's sandbox). So every stripe call names its profile, and this proves where that profile points.
# Returns the profile's account display name ('' if the CLI could not answer).
function Get-StripeAccountName([string]$Project) {
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $raw = (@(& stripe get /v1/account --project-name $Project 2>$null) -join "`n") } finally { $ErrorActionPreference = $old }
    try { return [string](($raw | ConvertFrom-Json).settings.dashboard.display_name) } catch { return '' }
}
