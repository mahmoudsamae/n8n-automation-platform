\# Task: professional invoice (HTML email + PDF)



Goal: the invoice email is the image recruiters see. Make it look like a real German invoice from a clearly fictional shop.



Shop: "Musterwerk" (fictional, no GmbH). Footer: "Portfolio-Demo aus der Stripe-Sandbox. Keine Rechnung im Sinne von § 14 UStG."

Product for demo payments: "Workshop: Automatisierung mit n8n", 30,00 EUR.



1\. Email: German HTML with a plain-text alternative. Subject "Ihre Rechnung INV-YYYY-NNNNNN". Greeting with the customer name from the event, invoice number, date (de-DE), line items, total, payment method. Event id only as a small "Referenz" in the footer. Sender from an env var, no example.test placeholder left.

2\. PDF: the same invoice as an attached PDF via a Gotenberg container. Set a memory limit in compose and measure docker stats before and after; our WSL limit is 2 GB. If it does not fit, stop and propose an alternative.

3\. The PDF is rendered only from the stored invoice row, so a retry produces the same document. Invoice and side\_effects idempotency must stay as they are.

4\. Telegram: short, for the owner: "Zahlung eingegangen", amount in EUR, customer first name, invoice number, product.

5\. Demo payments in EUR with the product name: find the right stripe trigger override and document it.

6\. Proofs: e2e passes; a resend still produces exactly 1 email with exactly 1 PDF; the PDF opens and shows the right number and amount; Gotenberg stopped means the event fails with a clear last\_error and succeeds after restart with no duplicate email.



7\. Design for M7: a later public demo page will show a visitor the same email and PDF for their own payment. Keep rendering in one place that can be called again for an existing invoice, and keep the PDF reachable by invoice number. Do not build the demo page now.



Plan first and wait for my approval.





\## Design v2 (approved by owner, 2026-10-30)



Layout follows DIN 5008 conventions, modernized:

1\. Logo: an original inline SVG monogram "M" (rounded square #1e3a5f, M stroke #5dcaa5), next to "Musterwerk" and the tagline "Workshops für Automatisierung". Inline only, no remote assets, so the CSP stays strict.

2\. Small sender line above the recipient: "Musterwerk · Musterstraße 1 · 12345 Musterstadt".

3\. Recipient left (name, email). Information block right: Rechnungs-Nr., Rechnungsdatum, Leistungsdatum, Zahlungsart.

4\. Heading "Rechnung", short greeting, then the line-item table with a dark header row (Pos., Beschreibung, Menge, Einzelpreis, Gesamt).

5\. Totals block right-aligned: Nettobetrag, "zzgl. 19 % USt.", Gesamtbetrag. Stripe's total is gross. Compute net = round(gross / 1.19) in cents and VAT = gross - net, so net + VAT always equals the total exactly. Test it for 3000 (2521 + 479) and several other amounts, including odd cents and a zero-decimal currency.

6\. A green "Bezahlt" badge in the header and a line "Der Betrag wurde am <date> per <payment method> beglichen. Es ist nichts mehr zu zahlen."

7\. Footer in three columns: address, contact, and the demo note "Portfolio-Demo, Stripe-Sandbox. Keine Rechnung i. S. d. § 14 UStG." Then the Referenz line. No IBAN, no tax number, no USt-IdNr, not even fake ones: invented official-looking numbers must not appear.

8\. The HTML email uses the same identity (logo, colors, totals), the plain-text part stays.

9\. Keep all escaping and the CSP. The hostile-name proof must still pass.



Also: keep the improved last\_error from Describe Failure, but prove that rk\_ keys are still redacted in it.



After the change, show me the new PDF and email screenshots again before the proofs.

