# Stripe payments to invoices with n8n and PostgreSQL

A pipeline of seven n8n workflows that turns Stripe payment events into German invoices (an HTML email with the PDF attached) plus a Telegram message to the owner. It stores every event before acknowledging it, creates one invoice per paid event, and makes failures visible: dead or stuck events raise alerts, and a failed event can be replayed with an audit trail.

What I can show, each with the output behind it in [`docs/evidence.md`](docs/evidence.md):

- **No double invoice or message.** Resending a Stripe event, or running the Processor again on the same event, leaves exactly 1 invoice, 1 email and 1 Telegram message. [Checked on every e2e run.](docs/evidence.md#duplicate-event-200-duplicate-1-row)
- **No 200 for an event that was not stored.** With Postgres stopped, Intake answered 500 to all 7 events of a Stripe CLI trigger. After the restart a resend stored exactly 1 row and it ended `done`. [Recorded output.](docs/evidence.md#database-down-500-then-the-resend-stores-1-row)
- **Failures reach a human.** Dead and stuck events raise one alert (Telegram and email) and can be replayed with a reason and an audit row; replay never touches invoices. [Recorded.](docs/evidence.md#alerts-and-replay)
- **Silence is detected.** An outside heartbeat emails me after about 15 minutes without a ping, and a Postgres backup restores into a throwaway container with matching row counts. [Recorded.](docs/evidence.md#hardening)
- **A missing PDF is never skipped silently.** With the PDF service stopped, the owner got exactly one Telegram text saying the PDF is missing, no email went out, and the event ended `failed` with `Render PDF (Gotenberg): ...`; after the restart it ended `done` with 1 email, 1 PDF document and no second text. [Recorded.](docs/evidence.md#gotenberg-down-one-text-no-email-then-done)
- **The same document on every retry.** The PDF is rendered from the stored invoice row only: a retry produced identical content and never called Stripe again. [Recorded.](docs/evidence.md#resend-and-retry-nothing-duplicated-the-same-document)
- **54 end-to-end checks** run through one script after every change (by hand; there is no CI): [`scripts/e2e.ps1`](scripts/e2e.ps1).

What I could not prove is listed just as plainly: [known limits](#known-limits) and [not proven](docs/evidence.md#not-proven).

## Screenshots

![The invoice email in the Mailpit inbox](docs/img/mailpit-invoice.png)
*The invoice email for a demo payment, with the PDF attached (Mailpit, the local inbox).*

![Page 1 of the invoice PDF](docs/img/invoice-pdf.png)
*The attached PDF: a fictional shop, 30,00 EUR split into net and 19 % VAT, marked as paid, with the demo disclaimer in the footer.*

![The owner's Telegram chat after a payment: the text, then the invoice PDF as a document](docs/img/telegram-invoice.png)
*The owner's Telegram chat after a demo payment: the message with the customer, payment method and invoice number, then the PDF as a document (`TELEGRAM_SEND_PDF=true`). The customer is Stripe's test name.*

This runs in Stripe's sandbox only, on my own machine; what a real deployment would still need is in the [live-mode checklist](docs/live-mode-checklist.md).

```mermaid
flowchart LR
    S["Stripe"] --> I["Intake: verify signature, store"]
    I -->|"bad signature or older than 5 min"| R400["400"]
    I -->|"stored, or duplicate"| R200["200"]
    I -->|"insert failed"| R500["500: Stripe retries"]
    I --> DB[("stripe_events")]
    DB --> P["Processor: every minute"]
    P --> INV[("invoice")]
    INV --> R["Render: German email and PDF from the invoice row"]
    R --> M["email with PDF via Mailpit"]
    R --> T["Telegram: text and PDF"]
```

## How it works

1. **Accept and store.** Intake checks the Stripe signature (HMAC-SHA256, constant-time compare) and rejects timestamps older than 5 minutes. It classifies the event and inserts it idempotently: a paid `checkout.session.completed` or an `async_payment_succeeded` becomes `pending`, everything else `ignored`. It answers 200, 200 duplicate, 400, or 500 if the insert failed. The response is sent only after the insert, so Stripe's own retries cover an outage.
2. **Claim atomically.** Every minute the Processor releases rows stuck in `processing` for more than 10 minutes, then claims up to 10 eligible rows (`pending`, or `failed` with fewer than 5 attempts) in one statement with `FOR UPDATE SKIP LOCKED`.
3. **Invoice first.** Each valid paid event gets one invoice before any notification: `event_id` is `UNIQUE`, and `INV-<year>-<6 digits>` comes from a PostgreSQL sequence. If no invoice exists yet, ONE read-only Stripe lookup (3 tries, 2 s then 4 s backoff) gets the product and the payment method actually used, and both are stored on the invoice row with the customer name. Amounts stay in Stripe's smallest unit (JPY 1500 is 1500) and are shown with `Intl.NumberFormat('de-DE')`.
4. **Render from the row, deliver once per kind.** A separate `Stripe Render Invoice` workflow builds the German email (HTML and plain text), the Telegram text and the PDF (Gotenberg) from the invoice row alone, so a retry gives the same document. The Processor checks `side_effects(event_id, kind)` for `email`, `telegram` (the owner text) and `telegram_document`, sends what is missing, then records it. All Telegram sends go through one sender workflow with one retry loop (3 tries, 2 s then 4 s, for 429, 5xx and network errors only). Missing or invalid customer data, a missing `TELEGRAM_SEND_PDF` setting or a PDF that cannot be produced marks the event `failed` with a clear `last_error`; there is no fallback and no default.
5. **Watch.** A Monitor workflow looks every 5 minutes for exhausted retries, stale pending, stuck failed and stuck processing events. Crashed workflows go through an Error Handler with a 15-minute throttle per (workflow, node). Both use one shared Send Alert workflow.
6. **Replay.** `scripts/replay.ps1` accepts only `failed` events, resets them in one transaction and writes an `event_replays` row with the reason.

Details and criteria: [M3](PLAN.md#m3-stripe-processor), [M4](PLAN.md#m4-failure-visibility), [M5](PLAN.md#m5-hardening). Operating it: [`docs/runbook.md`](docs/runbook.md).

<details>
<summary>The full picture, including alerting and recovery</summary>

```mermaid
flowchart TD
    Stripe[Stripe events] --> Intake["Intake: verify, classify, insert"]
    Intake -->|"bad signature or stale timestamp"| Bad["HTTP 400"]
    Intake -->|"insert failed"| Retry["HTTP 500: Stripe retries"]
    Intake -->|"new event stored"| OK["HTTP 200"]
    Intake -->|"duplicate"| Dup["HTTP 200 duplicate"]
    Intake --> DB[("PostgreSQL: stripe_events")]
    Tick["every minute"] --> Processor["Processor: claim up to 10"]
    DB --> Processor
    Processor -->|"once per invoice, read-only"| StripeApi["Stripe API: product, payment method"]
    Processor --> Invoices[("invoices: one per event")]
    Processor <--> Effects[("side_effects")]
    Processor --> Render["Render Invoice: from the invoice row only"]
    Render --> Gotenberg["Gotenberg: HTML to PDF"]
    Processor --> Email["email with PDF via Mailpit"]
    Processor --> TgSender["Send Telegram: one retry loop"]
    TgSender --> Telegram["Telegram: text, then PDF"]
    Processor -->|"done or failed"| DB
    Monitor["Monitor: every 5 min"] -->|"dead or stuck events"| DB
    Monitor --> Sender["Send Alert: Telegram and email"]
    Intake -. crash .-> Handler["Error Handler: 15 min throttle"]
    Processor -. crash .-> Handler
    Monitor -. crash .-> Handler
    Handler --> Sender
    Monitor -->|"ping every 5 min"| HC["Healthchecks.io: emails after about 15 min of silence"]
    Replay["replay.ps1: failed events only"] --> DB
    Replay --> Audit[("event_replays")]
    DB --> Backup["postgres-backup: daily pg_dump"]
```

</details>

## Engineering decisions

- **Store first, answer 500 if storage fails.** An early 200 would tell Stripe the event arrived and lose it; a 500 makes Stripe retry. [Output](docs/evidence.md#database-down-500-then-the-resend-stores-1-row).
- **Database constraints, not check-then-insert.** `UNIQUE` on the event and on the invoice's event, plus `ON CONFLICT`, hold under concurrency. See [`migrations/`](migrations/).
- **`ON DELETE RESTRICT` on financial records.** A payment event cannot be deleted while its invoice exists. An earlier plan said `CASCADE`; I changed it.
- **Two timestamps with one meaning each.** `pending_since` dates the current pending episode and `claimed_at` dates the processing claim, so a row released after 30 minutes does not look stale. [M4 criteria 4 and 5](PLAN.md#m4-failure-visibility).
- **The Monitor is a separate workflow.** A Processor that has stopped cannot report that it stopped.
- **Alerting also fails safely.** The crash throttle keeps its state in n8n's static data, so it works when Postgres is the thing that is down. The Monitor sets `alerted_at` only after delivery, so an undelivered alert is retried.
- **Every check must be able to fail.** After M5 I made each new check fail on purpose, because three of them could never have failed. Example: the stale-timestamp check has a fresh-timestamp control, and both ways of breaking it were provoked ([how](docs/evidence.md#stale-timestamp-400)).
- **Secrets stay out of the repo and out of output.** Compose holds `${VAR}` references only; scripts read secrets inside WSL and print yes/no. A hook blocks the unsafe `wsl` quoting forms that once printed a secret.

## Failure scenarios and evidence

Labels: **e2e** is asserted on every run of [`scripts/e2e.ps1`](scripts/e2e.ps1); **provoked** means I broke it on purpose and kept the output; **unproven** means designed and coded, never provoked. Full output for each row is in [`docs/evidence.md`](docs/evidence.md).

| Scenario | Behavior | Label |
|---|---|---|
| Fake signature | 400, event not stored | **e2e** ([output](docs/evidence.md#fake-signature-400)) |
| Validly signed, older than 5 min | 400, not stored; a fresh control is accepted | **e2e** ([output](docs/evidence.md#stale-timestamp-400)) |
| Validly signed, dated 1 h in the future | Accepted and stored (the window is one-sided) | **provoked**, a [known limit](#known-limits) ([output](docs/evidence.md#future-timestamp-accepted-a-limit)) |
| Duplicate event | 200 duplicate, 1 row, 1 invoice, 1 email, 1 Telegram message | **e2e** ([output](docs/evidence.md#duplicate-event-200-duplicate-1-row)) |
| Postgres down during Intake | 500 for every event; after restart a resend stores 1 row and it ends `done` | **provoked** ([output](docs/evidence.md#database-down-500-then-the-resend-stores-1-row)) |
| Processor runs again on a done event | Attempts go up, still 1 invoice and 1 message of each kind | **e2e** ([output](docs/evidence.md#re-run-on-the-same-event-no-second-invoice-or-message)) |
| Two claims at once | The second session gets 0 rows (and, without `SKIP LOCKED`, waits and takes them). Two whole workflow runs racing was not reproduced | **provoked**, claim statement only ([output](docs/evidence.md#two-claims-at-once-no-double-claim)) |
| `ignored` events | Never claimed, processed or invoiced (102 rows checked) | **provoked** ([output](docs/evidence.md#ignored-events-untouched)) |
| Mailpit down | Event `failed` with `last_error`; after recovery `done` with 1 email | **provoked** ([output](docs/evidence.md#mailpit-down-failed-then-done-with-1-email)) |
| PDF service (Gotenberg) down | The owner text goes out once saying the PDF is missing, no email, event `failed` with `Render PDF (Gotenberg): ...`; after the restart `done` with 1 email, 1 document, no second text | **provoked** ([output](docs/evidence.md#gotenberg-down-one-text-no-email-then-done)) |
| `TELEGRAM_SEND_PDF=false` | No document is sent and none is required for `done`; the email still carries the PDF | **provoked** ([output](docs/evidence.md#telegram_send_pdffalse-no-document-still-done)) |
| `TELEGRAM_SEND_PDF` missing or not true/false | Every event fails with a clear `last_error`; there is no default | **e2e** (the variable is checked) and unit-tested; not provoked live |
| Resend, or a retry after a crash between send and record | Same invoice, no second Stripe call, an identical PDF content; the email repeats only after a simulated crash (at-least-once) | **provoked** ([output](docs/evidence.md#resend-and-retry-nothing-duplicated-the-same-document)) |
| Hostile customer name (markup, quotes, `&`) | Shown literally in email, PDF and Telegram, never as markup | **provoked** ([output](docs/evidence.md#hostile-customer-name-literal-in-email-pdf-and-telegram)) |
| The invoice lookup at Stripe fails | `failed` with the Stripe message, no invoice, nothing sent (a 404 is not retried) | **provoked** ([output](docs/evidence.md#stripe-lookup-fails-failed-with-a-clear-reason-nothing-created)) |
| Every Telegram send (text and document) | One retry loop: 3 tries, 2 s then 4 s, only for 429/5xx/network errors; exactly 3 sends then `failed` | loop mechanics **provoked** with a stub ([output](docs/evidence.md#the-retry-loop-proven-in-the-engine)); a real Telegram 429/5xx or a failing `sendDocument` is **unproven** |
| Every combination of done side effects, switch value, render outcome and send failure | `done` only when everything required is recorded; nothing sent twice; every failure ends `failed` with a reason | checked on the real graph, 384 cases ([output](docs/evidence.md#the-processors-telegram-wiring-all-384-cases)) |
| Postgres down during Processor runs | One crash alert per (workflow, node) per 15 min, then a suppressed count | **provoked** ([output](docs/evidence.md#postgres-down-one-throttled-crash-alert)) |
| Event reaches 5 failed attempts | One dead-event alert, none after; replay ends `done` with 1 email, 1 invoice, 1 audit row | **provoked** ([output](docs/evidence.md#dead-event-one-alert-replay-ends-done)) |
| Replay of a `done` event or a malformed id | Refused, rows unchanged; the id never reaches psql | **e2e** for `done` and malformed ids; `ignored` and unknown ids **provoked** |
| Stale pending, stuck failed, stuck processing | One alert each, a fresh control gets none, the Processor clears the marker | **provoked** ([output](docs/evidence.md#stuck-rows-stale-pending-stuck-failed-stuck-processing)) |
| One alert channel down | The other still delivers; `alerted_at` is set | **provoked** with Mailpit down ([output](docs/evidence.md#one-alert-channel-down)) |
| Both alert channels down | Monitor should leave `alerted_at` unset and retry | **unproven** |
| n8n, WSL or the PC goes silent | Healthchecks.io emails after about 15 min | **provoked** once; that outage ended in an unplanned reboot ([output](docs/evidence.md#heartbeat)) |
| Wrong Postgres password in the backup config | e2e fails (TCP login from the backup container) | **e2e**, made to fail four ways ([output](docs/evidence.md#backup-and-restore)) |
| Backup restore | Restored into a throwaway container, row counts match live; a mismatch exits 1 | **provoked** ([output](docs/evidence.md#backup-and-restore)) |
| Postgres password rotation | 3 failed executions in the window, everything fine afterwards | **provoked** once by me ([output](docs/evidence.md#secret-rotation)) |

## Known limits

- **At-least-once, not exactly-once.** A crash between a send and its `side_effects` insert can duplicate that one message; a Monitor crash between delivery and `alerted_at` can duplicate an alert.
- **One-sided replay window.** Intake refuses old timestamps but accepts future ones. `stripe-node`'s own check behaves the same ([source and docs](docs/evidence.md#future-timestamp-accepted-a-limit)). Exploiting it needs the signing secret, so I rate it low; not changed.
- **Invoices are a technical demo.** Numbers are sequential with possible gaps and no yearly reset. Nothing here claims to meet German invoicing rules (§ 14 UStG, GoBD).
- **Nothing archives what was sent.** The invoice PDF is rendered from the stored row each time it is needed, so a later template change would alter re-rendered invoices (the content is identical for the same row and template, the bytes differ by a timestamp). A real German deployment must archive the sent PDF unchanged (GoBD); that is not built here. See the [live-mode checklist](docs/live-mode-checklist.md).
- **The invoice is a demo.** A fictional shop with no tax number or bank details, and a fixed 19 % split of Stripe's gross total; it says so in its footer. The email uses inline SVG for the logo, which some mail clients (Gmail among them) strip; the layout survives without it.
- **Sending the PDF to Telegram passes customer data to a third party.** The PDF holds the customer's name and email address; with `TELEGRAM_SEND_PDF=true` it goes to Telegram. A real deployment must decide that under the GDPR (legal basis, safeguards, retention); the setting has no default and `false` keeps the PDF on the email only. See the [runbook](docs/runbook.md#10-invoices-gotenberg-the-pdf-and-telegram).
- **Sandbox.** Email goes to Mailpit, whose inbox is lost on restart. Adaptive Pricing is on in the Stripe sandbox account, so the demo-payment script retries Stripe's occasional `checkout_amount_mismatch`. See the [live-mode checklist](docs/live-mode-checklist.md).
- **A double failure shows one reason.** If the PDF cannot be produced and the owner text send also fails, `last_error` names the Telegram failure; the PDF problem resurfaces on the next run.
- **No timeout on the Telegram sends.** n8n's Telegram node has no timeout option, so a hung Telegram call is not cut off by the workflow. It is recovered by the Processor's release of rows stuck in `processing` after 10 minutes and the `stuck processing` alert after 20; nothing is lost. The planned fix is HTTP Request nodes (which have `options.timeout`) for the two sends in `Stripe Send Telegram`; not built.
- **Alerting limits.** A green heartbeat proves n8n's scheduler and network only, not Postgres or the Processor. An alert that cannot be delivered still uses up its 15-minute throttle window in the Error Handler.
- **Backups.** Postgres dumps sit on the same disk as the database. n8n's own data is not backed up: workflows can be rebuilt from the `.sdk.ts` files ([runbook, section 8](docs/runbook.md#8-rebuild-n8n-from-the-sdkts-files)) and credentials are re-created by hand.
- **Never provoked:** real Telegram 429 or 5xx, a failing `sendDocument`, a real Stripe 429 or 5xx on the invoice lookup, both alert channels down at once, two whole Processor runs racing. See [not proven](docs/evidence.md#not-proven).
- **Setup.** This repository holds the workflows, migrations, scripts and runbook. The Docker Compose file and importable workflow files are not in it yet, so it cannot be cloned and run today, only read and reviewed. A clean-clone setup and its verification come next ([M6](PLAN.md#m6-portfolio-packaging)).

## Tech stack

| Technology | Role |
|---|---|
| n8n | Intake, scheduled Processor, Monitor, Error Handler, and the shared sub-workflows (Send Alert, Render Invoice, Send Telegram) |
| PostgreSQL | Event storage, atomic claims, invoice sequence and document data, side-effect and replay records |
| TypeScript (n8n Workflow SDK) | The seven workflows as `.sdk.ts` source files |
| Docker Compose in WSL | n8n, PostgreSQL, Mailpit, Gotenberg and a daily backup container |
| Gotenberg (Chromium) | HTML to PDF for the invoice, internal only, memory-capped |
| Mailpit | Local SMTP inbox for invoice and alert emails |
| Telegram Bot API | Owner message with the invoice PDF, and alerts |
| Healthchecks.io | Outside heartbeat that detects silence |
| Stripe and the Stripe CLI | Sandbox webhook source, trigger and resend |
| PowerShell | End-to-end checks, replay, restore drill and test-data helpers |

## How it was built

- I built it with agentic engineering, using Claude Code and Codex, and approved written acceptance criteria before each milestone.
- I reviewed and corrected the AI's plans and work. Five examples:
  1. `CASCADE` on a financial table became `RESTRICT`.
  2. A missing invoice step was added.
  3. A fallback email address was rejected; a missing email now fails the event.
  4. A false stale alert was found in review: staleness was measured from receipt time, so a row released after 30 minutes looked stale. It is now `pending_since`.
  5. In the M5 review I found that e2e could not detect a wrong `POSTGRES_PASSWORD` in `.env`, because its own database calls use the trusted local socket. That led to [`scripts/check-backup-health.ps1`](scripts/check-backup-health.ps1) ([PR #3](https://github.com/mahmoudsamae/n8n-automation-platform/pull/3)).
- I reviewed and ran every database migration myself.
- Guardrails: e2e as the definition of done, a [workflow drift hook](scripts/hooks/n8n-drift-reminder.mjs), [migration lint](scripts/lint-migrations.ps1), a [WSL quoting guard](scripts/hooks/wsl-quoting-guard.mjs), and secret scans.

## Where to start reading

[`PLAN.md`](PLAN.md) has the acceptance criteria and results per milestone. The workflows: [Intake](stripe-intake.sdk.ts), [Processor](stripe-processor.sdk.ts), [Monitor](stripe-monitor.sdk.ts), [Error Handler](stripe-error-handler.sdk.ts), [Send Alert](stripe-send-alert.sdk.ts), [Render Invoice](stripe-render-invoice.sdk.ts), [Send Telegram](stripe-send-telegram.sdk.ts). Then [`migrations/`](migrations/), [`scripts/`](scripts/) and the [runbook](docs/runbook.md). A short write-up for a CV or LinkedIn is in [`docs/case-study.md`](docs/case-study.md).

## Kurzfassung

Dieses Portfolio-Projekt verarbeitet Stripe-Zahlungsereignisse mit sieben n8n-Workflows und PostgreSQL zu deutschen Rechnungen (HTML-E-Mail mit PDF-Anhang) sowie einer Telegram-Nachricht an den Betreiber. Jedes Ereignis wird gespeichert, bevor es bestätigt wird; pro bezahltem Ereignis entsteht genau eine Rechnung mit der Nummer `INV-JJJJ-NNNNNN`, und Wiederholungen erzeugen keine zweite. Fällt die Datenbank aus, antwortet der Webhook mit 500, sodass Stripe die Zustellung wiederholt. Endgültig fehlgeschlagene oder hängende Ereignisse lösen einen Alarm aus und lassen sich mit Begründung und Protokolleintrag erneut verarbeiten. Ein externer Heartbeat meldet einen Ausfall, wenn das System etwa 15 Minuten lang kein Signal sendet. Alles läuft nur in der Stripe-Sandbox. Das PDF wird nur aus der gespeicherten Rechnungszeile erzeugt, sodass jeder Wiederholungsversuch dasselbe Dokument liefert; lässt es sich nicht erzeugen, endet das Ereignis als fehlgeschlagen und wird nie stillschweigend übersprungen. Ein Skript führt 54 End-to-End-Prüfungen aus, und jede Zeile der Fehlertabelle ist als geprüft, gezielt ausgelöst oder unbelegt gekennzeichnet. Nicht belegt sind echte Telegram-429/5xx-Fehler, ein fehlschlagender sendDocument-Aufruf, ein echtes Stripe-429/5xx bei der Rechnungsabfrage, der gleichzeitige Ausfall beider Alarmkanäle und zwei vollständig parallel laufende Processor-Läufe. Bekannte Grenzen: mögliche doppelte Benachrichtigung nach einem Absturz (at-least-once), die Weitergabe von Kundendaten an Telegram beim PDF-Versand (eine DSGVO-Entscheidung; die Einstellung hat keinen Standardwert), ein einseitiges Zeitfenster gegen Replay-Angriffe und Rechnungen, die keine Konformität mit deutschem Rechnungsrecht (§ 14 UStG, GoBD) beanspruchen. Das Repository lässt sich noch nicht frisch klonen und starten; das ist der nächste Schritt.

## Author

Mahmud Al Hussen. Portfolio: [mahmud-portfolio-ten.vercel.app](https://mahmud-portfolio-ten.vercel.app)
