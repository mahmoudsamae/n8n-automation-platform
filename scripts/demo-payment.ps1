# Fires ONE Stripe sandbox demo payment: 30,00 EUR for "Workshop: Automatisierung mit n8n", quantity 1. Needs `stripe listen` running to reach Intake
# (scripts\e2e.ps1 starts its own). The customer is the CLI fixture's ("Jenny Rosen", paying by Visa).
#   powershell -File scripts\demo-payment.ps1 [-Tag e2e]        -Tag adds the Stripe metadata <tag>=true to the checkout session
# Exit codes: 0 fired, 1 failed (the reason is printed).
#
# The overrides (stripe CLI 1.55, fixture checkout.session.completed; found by trying, the CLI help does not list them):
#   price:currency=eur                          the fixture's price is usd
#   price:unit_amount=3000                      the fixture's 1500
#   product:name=Workshop: Automatisierung mit n8n   the fixture's "myproduct"
#   checkout_session:line_items[0][quantity]=1  the fixture's 2; 1 x 3000 = 3000 matches the fixture's fixed expected_amount of 3000
#
# Why the retry: this sandbox account has Adaptive Pricing enabled, and Stripe then sometimes answers checkout_amount_mismatch to the fixture's
# fixed expected_amount at the confirm step ("Your order has been updated"). The identical command succeeded on the next try (seen on 2026-10-30).
# Only that error is retried; anything else fails at once.
param(
    [ValidatePattern('^[a-z0-9_]{1,40}$')][string]$Tag = '',
    [ValidateRange(1, 5)][int]$Tries = 3
)
$ErrorActionPreference = 'Stop'

$overrides = @(
    '--override', 'price:currency=eur',
    '--override', 'price:unit_amount=3000',
    '--override', 'product:name=Workshop: Automatisierung mit n8n',
    '--override', 'checkout_session:line_items[0][quantity]=1'
)
if ($Tag) { $overrides += @('--add', "checkout_session:metadata[$Tag]=true") }

$stripe = (Get-Command stripe -ErrorAction Stop).Source
for ($try = 1; $try -le $Tries; $try++) {
    # The CLI writes a hint line to stderr; Windows PowerShell 5.1 would turn that into an error under 'Stop'.
    $ErrorActionPreference = 'Continue'
    $out = & $stripe trigger checkout.session.completed @overrides 2>&1 | ForEach-Object { "$_" } | Where-Object { $_ -notmatch 'claude-code-hint' }
    $exit = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($exit -eq 0) { Write-Host "demo payment fired (try $try of $Tries)"; exit 0 }
    $text = ($out -join ' ') -replace '\s+', ' '
    if ($text -match 'checkout_amount_mismatch' -and $try -lt $Tries) {
        Write-Host "try $try of ${Tries}: checkout_amount_mismatch (Adaptive Pricing), retrying" -ForegroundColor Yellow
        Start-Sleep -Seconds 3
        continue
    }
    Write-Host "demo payment FAILED (try $try of $Tries): $($text.Substring(0, [Math]::Min(300, $text.Length)))" -ForegroundColor Red
    exit 1
}
exit 1
