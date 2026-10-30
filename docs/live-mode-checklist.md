# Live-mode checklist (hypothetical client deployment, never executed)

This project runs in Stripe's sandbox only and nothing here has been done against live mode. The list is what a real client
deployment would have to change, and how to check each item. Every item needs a person to tick it, not this file.

## Stripe

- [ ] **Public HTTPS endpoint for the Intake webhook** (reverse proxy or tunnel with a valid certificate; only the webhook path exposed, not the n8n editor).
  Verify: Stripe Dashboard -> send a test webhook -> HTTP 200; `https://<host>/` of the editor is not reachable from the internet.
- [ ] **Live-mode webhook endpoint with its own signing secret.** Test and live use different `whsec_` values; put the live one in `.env` as `STRIPE_WEBHOOK_SECRET`.
  Verify: a request with a forged signature gets 400, and a real live event is stored (`select event_id, status from stripe_events order by received_at desc limit 3`).
- [ ] **Stop forwarding from the Stripe CLI** (`stripe listen`) on the production host, and keep CLI keys off it.
  Verify: no `stripe` process (`Get-Process stripe`).
- [ ] **Retry window.** Intake answers 500 when the insert fails so Stripe retries; confirm Stripe's current live-mode retry window is longer than the longest outage the client accepts.
  Verify: read Stripe's webhook retry docs and write the number into the runbook.
- [ ] **Subscribe to exactly the events used** (`checkout.session.completed`, `checkout.session.async_payment_succeeded`); everything else is stored as `ignored`.
  Verify: Dashboard endpoint settings list only those events.

## Email and alerts

- [ ] **Real SMTP instead of Mailpit** (credential `Mailpit SMTP` is test-only: it catches everything and keeps no history across restarts), with SPF and DKIM set up for the sender domain.
  Verify: send a test invoice email to an address you control and read the headers for `spf=pass dkim=pass`.
- [ ] **Real sender and recipient addresses.** `ALERT_EMAIL_FROM` / `ALERT_EMAIL_TO` / `INVOICE_EMAIL_FROM` are env vars; set them to addresses the client owns (the demo uses `.example` addresses). No `example.test` placeholder is left in any workflow.
  Verify: `Select-String -Path *.sdk.ts -Pattern 'example\.test'` returns nothing, and a test invoice arrives from the client's real sender address.
- [ ] **Decide whether invoice PDFs go to Telegram (GDPR).** `TELEGRAM_SEND_PDF=true` sends each invoice PDF, which holds the customer's name and email address, to Telegram, a third party. A real deployment needs a legal basis, a processor agreement or transfer safeguard where required,
  a retention and deletion answer (the messages stay in the chat) and a privacy-notice entry; until then use `false` (the PDF stays on the email, and the owner text still names the customer, so decide that too).
  Verify: the decision and its basis are written into the client's records, and the value in `~/n8n/.env` matches it (`docs/runbook.md` section 10).
- [ ] **A real German invoice.** The demo invoice is explicitly not one: a fictional seller (Musterwerk, no tax number, no USt-IdNr, no bank details) and a fixed 19 % split of Stripe's gross total. A real one must carry what § 14 UStG requires of the issuer (full seller and buyer details, tax number or USt-IdNr,
  service date, the actual tax rate and amount per item, a continuous number) and the right rate for each product, and the footer disclaimer must go. Verify: the client's accountant approves one sample invoice.
- [ ] **A restricted LIVE Stripe key for the invoice lookup.** The `Stripe read-only` credential holds a test-mode restricted key (Checkout Sessions, PaymentIntents, Charges: read). Live mode needs its own restricted key with the same three read permissions, stored only in the n8n credential.
  Verify: a live test payment produces an invoice with the right product and payment method; the key has no write permission in the Dashboard.
- [ ] **Customer emails are real.** The Processor sends to `customer_details.email` and fails the event if it is missing; there is no fallback address on purpose.
  Verify: a live test purchase reaches the buyer's inbox, and an event without an email ends `failed` with a clear `last_error`.
- [ ] **Client-owned Telegram bot and chat** (new token in the `Telegram alerts` credential, new `TELEGRAM_CHAT_ID`), with at least two people in the alert chat.
  Verify: a seeded dead test event produces a Telegram message.
- [ ] **Client-owned Healthchecks.io account** with at least two alert recipients, period 5 min, grace 10 min; its ping URL in `HEARTBEAT_URL`.
  Verify: `wsl --shutdown` -> a down email arrives about 15 min later on both recipients.

## Data and recovery

- [ ] **Off-site copy of the Postgres dumps** (`~/n8n/backups` is on the same disk as the database), encrypted at rest, since dumps contain customer emails.
  Verify: restore a dump from the off-site copy with `scripts\restore-check.ps1`-style drill on another machine.
- [ ] **Back up n8n itself** (workflows with their settings; credentials are not exported). Set an explicit `N8N_ENCRYPTION_KEY` and keep it in the client's password manager: n8n encrypts stored credentials with it, and today it only exists inside the `n8n_data` volume.
  Verify: rebuild n8n on a clean machine following `docs/runbook.md` section 8.
- [ ] **Retention for financial records.** `invoices`, `side_effects` and `stripe_events` use `ON DELETE RESTRICT` and nothing deletes them; the 14-day pruning only affects backup files. Decide how long invoices and dumps must be kept.
  Verify: ask the client's accountant, write the period into the runbook.
- [ ] **Invoice numbering rules.** `INV-<year>-<6 digits>` comes from a sequence with no yearly reset, and gaps are possible after a rolled-back insert. Some countries require gapless numbering.
  Verify: accountant sign-off.
- [ ] **Archive the sent invoice PDF unchanged (GoBD).** The demo renders invoices on demand from the stored row, so a later template change would alter re-rendered invoices; the stored row is not the document that was sent. A real German deployment must keep the sent PDF itself, unchanged: write it to write-once storage at send time, with its hash, and link it to the invoice number. Not built here.
  Verify: change the template, re-render an old invoice, and confirm the archived copy still matches its recorded hash and still shows the original layout. Have the client's accountant confirm the retention rules and period.
- [ ] **Gotenberg stays internal and pinned.** It has no published port and a 512 MB cap; keep it that way (it renders HTML, so it must never be reachable from outside), pin the image digest, and re-run the memory check on the real host.
  Verify: `docker port gotenberg` prints nothing, `docker inspect gotenberg` shows the memory limit.
- [ ] **Adaptive Pricing and presentment currency.** If the client's Stripe account shows prices in the buyer's currency, the session currency can differ from what the invoice should show. The pipeline fails an event whose session amount or currency differs from the event (it never guesses); decide the policy for the client.
  Verify: a test payment from another country either invoices correctly or fails with the clear `last_error`.
- [ ] **n8n execution data holds customer data.** Stored executions keep invoice rows, customer names and emails, and the rendered PDF for as long as n8n keeps them, which is separate from the database retention above. Set an explicit execution retention (`EXECUTIONS_DATA_MAX_AGE`, and decide whether to save successful runs) and cover it in the privacy notice.
  Verify: the setting is in the client's `.env` and an execution older than the limit is gone.
- [ ] **Remove test data:** `evt_test_%` rows, `e2e=true` events, the Mailpit inbox.
  Verify: `select count(*) from stripe_events where event_id like 'evt\_test\_%'` is 0. Delete order: `event_replays`, `side_effects`, `invoices`, `stripe_events`.

## Platform

- [ ] **Postgres stays private** (`127.0.0.1:5432` today) and the n8n owner account has a strong unique password.
  Verify: `Test-NetConnection <host> -Port 5432` fails from another machine.
- [ ] **Always-on host** (not a PC that sleeps at night): the heartbeat treats every shutdown as an outage.
  Verify: 7 days without a heartbeat-down email.
- [ ] **Time zone.** `GENERIC_TIMEZONE`/`TZ` are `Europe/Berlin`; timestamps in Postgres, n8n and Mailpit are UTC. Confirm which zone the client expects in emails.
- [ ] **Rotate every test secret** (webhook secret, bot token, Postgres password) before first use and run section 7 of the runbook once on the new host.
  Verify: no secret from the sandbox period is still valid.
- [ ] **Re-run the proofs on the live host:** `scripts\e2e.ps1` (it uses Stripe test mode, so run it against a staging copy, never against live keys).
