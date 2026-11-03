# Run a bash script on the M7 server over Tailscale without any quoting trouble. Same idea as wsl-sh.ps1.
#   & scripts\server-sh.ps1 -Script 'free -m'
#   & scripts\server-sh.ps1 -File path\to\script.sh
# The script travels as base64 and runs on the server, so no local shell can expand anything in it. Output goes to the pipeline; its exit code is this script's exit code.
# Never put a secret VALUE in the script text: read it from .env on the server, keep it in a shell variable and print only yes/no.
param(
    [string]$Script,
    [string]$File,
    [string]$Target = 'ubuntu@m7-server',
    [string]$KeyFile = (Join-Path $HOME '.ssh\oci_m7')
)
$ErrorActionPreference = 'Stop'
if (($Script -and $File) -or (-not $Script -and -not $File)) { throw 'give exactly one of: -Script, -File' }
$text = if ($Script) { $Script } else { [IO.File]::ReadAllText((Resolve-Path -LiteralPath $File)) }
# Destructive text (DROP, down -v, ...) is refused here, on the final text, before it becomes base64 that nothing else can read.
. "$PSScriptRoot\lib\destructive-guard.ps1"
Assert-NotDestructive $text
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($text -replace "`r", '')))
# BatchMode: fail instead of hanging on a prompt. accept-new: a rebuilt VM has a new host key under the same name, see the runbook.
& ssh -i $KeyFile -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new $Target "echo $b64 | base64 -d | bash"
exit $LASTEXITCODE
