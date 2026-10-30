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

