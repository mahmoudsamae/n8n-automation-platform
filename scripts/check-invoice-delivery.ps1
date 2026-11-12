# Checks what one processed demo payment delivered: the invoice row, exactly ONE email (German subject, text and HTML parts, exactly the expected number of
# PDF attachments, a real PDF) and the Telegram document side effect. Used by scripts\e2e.ps1; the parameters below are also how each check is made to fail.
#   powershell -File scripts\check-invoice-delivery.ps1 -EventId evt_... -InvoiceNumber INV-2026-000001 [-ExpectTelegramDocument:$false]
# Exit 0 = all checks pass, 1 = a check failed. Prints event and invoice ids only, never an address or a customer name.
# To prove it can fail: -ExpectedAttachments 2, -SubjectPrefix 'Rechnung ', -ExpectedAmountCents 3100, -ExpectTelegramDocument:$false (when one was sent).
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^evt_[A-Za-z0-9]+$')][string]$EventId,
    [Parameter(Mandatory = $true)][ValidatePattern('^INV-\d{4}-\d{6}$')][string]$InvoiceNumber,
    [int]$ExpectedAmountCents = 3000,
    [string]$ExpectedCurrency = 'eur',
    [string]$ExpectedProduct = 'Workshop: Automatisierung mit n8n',
    [int]$ExpectedAttachments = 1,
    [string]$SubjectPrefix = 'Ihre Rechnung ',
    [bool]$ExpectTelegramDocument = $true,
    # Server: Mailpit through e2e's SSH tunnel (local 28025), so run it from e2e -Target Server, or pass -MailpitUrl for your own tunnel.
    [ValidateSet('Laptop', 'Server')][string]$Target = 'Laptop',
    [string]$MailpitUrl = ''
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\target.ps1"
$T = Get-Target $Target
if (-not $MailpitUrl) { $MailpitUrl = $T.MailpitUrl }
$failed = 0
function Write-Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if (-not $Ok) { $script:failed++ }
    Write-Host ("[{0}] {1}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name) -ForegroundColor $(if ($Ok) { 'Green' } else { 'Red' }) -NoNewline
    if ($Detail) { Write-Host (" - {0}" -f $Detail) } else { Write-Host '' }
}
function Invoke-Psql([string]$Sql) {
    $script = 'docker exec postgres psql -U automation -d automation -tAc "' + $Sql + '"'
    return (@(@(Invoke-TargetSh $T $script) | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) -join '|')
}
function Read-Utf8Json([string]$Url) {
    # Invoke-RestMethod in Windows PowerShell 5.1 can mis-decode UTF-8 JSON, so decode the bytes explicitly.
    return [Text.Encoding]::UTF8.GetString((Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 15).RawContentStream.ToArray()) | ConvertFrom-Json
}

try {
    # the invoice row holds what the documents are rendered from
    $row = Invoke-Psql "select amount_cents || '|' || currency || '|' || (customer_name is not null) || '|' || (payment_method is not null) || '|' || coalesce(line_items->0->>'description', '') || '|' || coalesce(jsonb_array_length(line_items)::text, '0') from invoices where event_id = '$EventId' and invoice_number = '$InvoiceNumber'"
    $p = @($row -split '\|')
    $shown = if ($p.Count -ge 2) { "$($p[0]) $($p[1])" } else { 'no invoice row' }
    Write-Check "invoice $InvoiceNumber belongs to $EventId and is $ExpectedAmountCents $ExpectedCurrency" ($p.Count -ge 6 -and [int]$p[0] -eq $ExpectedAmountCents -and $p[1] -eq $ExpectedCurrency) $shown
    Write-Check 'invoice row stores the customer name, the payment method and one line item with the product' ($p.Count -ge 6 -and $p[2] -eq 'true' -and $p[3] -eq 'true' -and $p[4] -eq $ExpectedProduct -and $p[5] -eq '1')

    # exactly one email for this invoice
    $q = [uri]::EscapeDataString("subject:`"$InvoiceNumber`"")
    $found = @((Read-Utf8Json "$MailpitUrl/api/v1/search?query=$q").messages | Where-Object { $_.Subject -like "*$InvoiceNumber*" })
    Write-Check "exactly 1 email in Mailpit for $InvoiceNumber" ($found.Count -eq 1) "found $($found.Count)"
    if ($found.Count -ge 1) {
        $m = Read-Utf8Json "$MailpitUrl/api/v1/message/$($found[0].ID)"
        Write-Check "subject is exactly '$SubjectPrefix$InvoiceNumber'" ($m.Subject -ceq ($SubjectPrefix + $InvoiceNumber)) $m.Subject
        Write-Check 'sender is a real configured address (not the example.test placeholder)' ($m.From.Address -match '^[^@\s]+@[^@\s]+$' -and $m.From.Address -notmatch 'example\.test$')
        Write-Check 'email has a plain-text part and an HTML part, both with the invoice number' ([string]$m.Text -like "*$InvoiceNumber*" -and [string]$m.HTML -like "*$InvoiceNumber*")
        Write-Check 'the plain text shows the total' ([string]$m.Text -match 'Gesamtbetrag')
        $atts = @($m.Attachments)
        Write-Check "exactly $ExpectedAttachments PDF attachment(s) on the email" ($atts.Count -eq $ExpectedAttachments) "found $($atts.Count)"
        if ($atts.Count -ge 1) {
            $a = $atts[0]
            Write-Check "attachment is application/pdf named Rechnung-$InvoiceNumber.pdf" ($a.ContentType -eq 'application/pdf' -and $a.FileName -ceq "Rechnung-$InvoiceNumber.pdf") "$($a.ContentType) $($a.FileName)"
            $bytes = (Invoke-WebRequest -Uri "$MailpitUrl/api/v1/message/$($found[0].ID)/part/$($a.PartID)" -UseBasicParsing -TimeoutSec 15).RawContentStream.ToArray()
            $head = if ($bytes.Length -ge 5) { [Text.Encoding]::ASCII.GetString($bytes[0..4]) } else { '' }
            Write-Check 'the attachment is a real PDF (starts with %PDF-, more than 1 KB)' ($head -ceq '%PDF-' -and $bytes.Length -gt 1000) "$($bytes.Length) bytes"
        }
    }

    # the Telegram document is a side effect of its own; it exists only when TELEGRAM_SEND_PDF=true
    $doc = [int](Invoke-Psql "select count(*) from side_effects where event_id = '$EventId' and kind = 'telegram_document'")
    $want = if ($ExpectTelegramDocument) { 1 } else { 0 }
    Write-Check "telegram_document side effect: exactly $want" ($doc -eq $want) "found $doc"
}
catch {
    Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
    $failed++
}
if ($failed -gt 0) { exit 1 }
exit 0
