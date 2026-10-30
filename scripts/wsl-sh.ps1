# Run a bash script inside WSL Ubuntu without any quoting trouble. This is the SAFE way to run anything that needs $VARs, $(...) or quotes.
#   & scripts\wsl-sh.ps1 -Script 'x=$(date -u +%T); echo "now $x"'      (in-process; from another script: $out = & "$PSScriptRoot\wsl-sh.ps1" -Script $sh)
#   & scripts\wsl-sh.ps1 -File path\to\script.sh
#   $script | & scripts\wsl-sh.ps1                                       (pipeline input, in-process)
#   Get-Content script.sh | powershell -File scripts\wsl-sh.ps1          (stdin, from a child process)
# Avoid `powershell -File scripts\wsl-sh.ps1 -Script '...'`: the child powershell re-parses double quotes in the argument. Use -File or stdin there.
# Why: `wsl <cmd>` runs through an outer shell that expands $VAR and $(...) before bash sees them (this once printed a secret in an error message),
# and PowerShell 5.1 prepends a BOM when piping text to wsl. The script travels as base64 and is decoded and run inside WSL, so none of that can touch it.
# Output goes to the pipeline; the exit code of the script is this script's exit code. Never put a secret VALUE in the script text: read it from
# ~/n8n/.env inside the script, keep it in a shell variable and print only yes/no.
param(
    [Parameter(ValueFromPipeline = $true)][string[]]$InputObject,
    [string]$Script,
    [string]$File
)
begin { $piped = New-Object System.Collections.Generic.List[string] }
process { foreach ($l in $InputObject) { $piped.Add($l) } }
end {
    $ErrorActionPreference = 'Stop'
    $text = $null
    $given = 0
    if ($Script) { $given++ }
    if ($File) { $given++ }
    if ($piped.Count -gt 0) { $given++ }
    if ($given -gt 1) { throw 'give exactly one of: -Script, -File, or piped text' }
    if ($Script) { $text = $Script }
    elseif ($File) { $text = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $File)) }
    elseif ($piped.Count -gt 0) { $text = $piped -join "`n" }
    elseif ([Console]::IsInputRedirected) { $text = [Console]::In.ReadToEnd() }
    if (-not $text -or -not $text.Trim()) { throw 'no script given: use -Script, -File, pipeline input or stdin' }
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($text -replace "`r", '')))
    if ($b64.Length -gt 24000) { throw 'script too large for one wsl call (24000 base64 chars); split it' }
    wsl -d Ubuntu bash -c "echo $b64 | base64 -d | bash"
    exit $LASTEXITCODE
}
