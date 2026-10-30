# n8n Automation Platform

Stripe payments -> Intake workflow -> `stripe_events` table -> Processor workflow -> Mailpit email + Telegram message.
Intake only verifies, classifies and stores (fast). All slow work belongs to the Processor.

## Workflows (n8n id -> source file)
- Stripe Intake `3j0pWVoxvDY2sdO5` -> `stripe-intake.sdk.ts` (live, published)
- Stripe Processor `ylR2t9B0ZAH1cLfq` -> `stripe-processor.sdk.ts` (live, published; schedule every 1 min)
- Stripe Error Handler `c2NT8k3JGpuS3r6I` -> `stripe-error-handler.sdk.ts` (errorWorkflow of Intake, Processor, Monitor)
- Stripe Monitor `yeSlEcPp87vCJT7D` -> `stripe-monitor.sdk.ts` (schedule every 5 min)
- Stripe Send Alert `WO2ebvkZGK5NxzVo` -> `stripe-send-alert.sdk.ts` (sub-workflow, Telegram + email; called by Handler and Monitor)
- Stripe Render Invoice `3dvdSRSD6ObBVsxy` -> `stripe-render-invoice.sdk.ts` (sub-workflow, called by the Processor; the ONLY place that builds the invoice subject, HTML, text, Telegram text and the PDF, from the invoice row alone; callable again for any existing invoice, M7 will reuse it)
- Stripe Send Telegram `Yel7C2ufq8wR5s3W` -> `stripe-send-telegram.sdk.ts` (sub-workflow, called by the Processor for the owner text and the PDF document; ONE retry loop: 3 tries, 2 s then 4 s backoff on 429/5xx/network)
- The two invoice sub-workflows have no `errorWorkflow` (they return `problem`, the Processor reports it); `scripts\check-error-workflows.ps1` checks all 7. The Processor calls both BY ID: if one is recreated, update the id in `stripe-processor.sdk.ts`.

## Infra
- n8n, postgres, mailpit, postgres-backup, gotenberg run via docker compose in WSL Ubuntu: `~/n8n/docker-compose.yml`.
  Start: `wsl -d Ubuntu bash -c "cd ~/n8n && docker compose up -d"`. Ports: n8n :5678, postgres 127.0.0.1:5432, Mailpit UI :8025.
- `gotenberg` (`gotenberg/gotenberg:8.39.0-chromium`, Chromium + PDF engines only): renders the invoice HTML to PDF. No published port (n8n reaches `http://gotenberg:3000`), `mem_limit` and `memswap_limit` 512m,
  JavaScript off, webhooks off, 30 s API timeout. Idle it holds about 360-410 MB (Chromium stays resident); real working memory is about 130 MB, the rest is reclaimable file cache. Memory gate recorded in `docs/evidence.md`.
- `postgres-backup`: `pg_dump -Fc` at start + every 24 h into `~/n8n/backups/` (mode 600, never in git: customer emails), retry 5 min after a failure, 14-day prune.
  Postgres only: n8n's workflows (SQLite in the `n8n_data` volume) are NOT backed up. Restore drill: `scripts\restore-check.ps1 [-Fresh]`.
- e2e also runs `scripts\check-error-workflows.ps1` (each workflow's `errorWorkflow` on live n8n) and `scripts\check-backup-health.ps1` (TCP auth from `postgres-backup` with the `.env`
  password, same password inside the container, last log line is not `backup FAILED`); e2e's own psql calls use the trusted socket and cannot see a wrong password.
- n8n credential: `Postgres automation` (id `XVNN7sIThniqsuOf`). DB and user are both `automation`.
- Env var NAMES (the compose file only holds `${VAR}` references; real values live in `~/n8n/.env` in WSL, never copy them here):
  `STRIPE_WEBHOOK_SECRET`, `TELEGRAM_CHAT_ID`, `ALERT_EMAIL_TO`, `ALERT_EMAIL_FROM`, `HEARTBEAT_URL` (Healthchecks.io ping URL: the UUID is its only credential, treat it as a secret),
  `INVOICE_EMAIL_FROM` (sender of the invoice email, e.g. `Musterwerk <rechnung@musterwerk.example>`; if unset the send fails),
  `TELEGRAM_SEND_PDF` (exactly `true` or `false`, NO default: it decides whether the invoice PDF, which holds customer data, is sent to Telegram, a third party; unset or any other value fails every event with a clear `last_error`),
  `NODE_FUNCTION_ALLOW_BUILTIN`, `N8N_BLOCK_ENV_ACCESS_IN_NODE`, `GENERIC_TIMEZONE`, `TZ`, `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`.
- n8n credential: `Mailpit SMTP` (id `nxXABuEVvevioUzb`; host `mailpit`, port 1025, no auth). Mailpit keeps no history across restarts.
- n8n credential: `Telegram alerts` (id `kNsPsjXulOh7i4RQ`, Telegram bot). Chat ID is available in workflows as `$env.TELEGRAM_CHAT_ID`.
- n8n credential: `Stripe read-only` (id `qtmzPq7nRsOF9MAW`, type `stripeApi`, a restricted test-mode key: Checkout Sessions, PaymentIntents and Charges read, restricted to api.stripe.com). Used only by the Processor's one lookup per invoice. Never print it.
- `STRIPE_WEBHOOK_SECRET` must equal the `whsec_...` that `stripe listen` prints (on STDERR), or every event gets 400.

## Table `stripe_events`
Columns are in `migrations/` (001-005). Non-obvious: `claimed_at` is set when the Processor claims a row; `pending_since` (when the row last became pending; stuck-row release and
replay reset it) drives stale-pending alerts, never `received_at`; `alerted_at` is set by the Monitor after alerting and cleared by the Processor claim and by replay.

Applied by the user (002-006; the user runs migrations, Claude never does, and checks a table exists before relying on it): `event_replays`, `side_effects` (PK `(event_id, kind)`,
kind is plain TEXT with no CHECK; used: `email`, `telegram` = the owner text, `telegram_document` = the PDF), `invoices` (event_id UNIQUE), all FK ON DELETE RESTRICT. `invoice_number` = `INV-<year>-<6 digits>` from `invoice_number_seq` (no yearly reset; gaps possible).
`amount_cents` is Stripe's smallest unit as-is (JPY 1500 = 1500), and it is the GROSS total.
Migration 006 added `invoices.customer_name`, `payment_method` and `line_items` (JSONB array of `{description, quantity, unit_amount, amount_total}`): everything the documents show, so they are rendered from the row alone.
A CHECK allows all three NULL (the 27 invoices before 006, which are never re-rendered) or all three set.

## Processor behaviour (M3, built)
- Every minute it releases rows stuck in `processing` > 10 min, then claims up to 10 (`pending`, or `failed` with attempts < 5) via `FOR UPDATE SKIP LOCKED`.
- Recipient is `customer_details.email` from the event. Missing/invalid email, name, session id, amount or currency, or `TELEGRAM_SEND_PDF` not exactly true/false => event `failed` with a clear `last_error`. No fallback address, no defaults.
- Invoice data (M-invoice): if no invoice exists yet, ONE read-only Stripe lookup (`GET /v1/checkout/sessions/{id}?expand[]=line_items&expand[]=payment_intent.latest_charge`, 3 tries, 2 s then 4 s backoff on 429/5xx/network) gets the product and the payment
  method actually used; both are stored on the invoice row with the customer name. A retry, replay or re-render never calls Stripe again. Anything inconsistent (not paid, amount or currency differs, items do not add up, no card brand) fails the event.
- Rendering goes through Stripe Render Invoice (include_pdf only while the email or the document is still to be sent). Email: German HTML + plain text, subject `Ihre Rechnung INV-...`, exactly one PDF attached, sender `$env.INVOICE_EMAIL_FROM`.
- Telegram goes through Stripe Send Telegram: the owner text (full name, Zahlungsart, no event id; customer text escaped) and, if `TELEGRAM_SEND_PDF=true`, the PDF as a document (plain-text caption). Two side effects, `telegram` and `telegram_document`.
  If the PDF cannot be produced the email is skipped, the owner text still goes out saying "PDF fehlt: konnte nicht erstellt werden. Es wird erneut versucht.", and the event ends `failed` with the real reason (e.g. `Render PDF (Gotenberg): ...`);
  the next run sends only what is still missing, so the text is never repeated. If that text send ALSO fails, its error wins in `last_error` and the PDF problem resurfaces on the next run (accepted).
- Delivery is at-least-once: a crash between a send and its `side_effects` insert can duplicate that one message. Max 5 attempts per event.

## Failure visibility (M4 + M5, built)
- Monitor sends ONE alert listing up to 10 events, then sets `alerted_at` (after delivery, so at-least-once). Kinds: `dead`, `stale pending`, `stuck failed`, `stuck processing`
  (rules: `docs/runbook.md` section 3). `stuck processing` waits 20 min, twice the Processor's 10 min release, so it never races a healthy Processor.
- Workflow crashes go through the Error Handler: one alert per (workflow | node) per 15 min, state in static data so it works with Postgres down. An undeliverable alert still uses up its window.
- Replay a dead event: `powershell -File scripts\replay.ps1 -EventId evt_... -Reason "..." [-DryRun]`. Only `failed` events; never touches `side_effects` or `invoices`.
- Dead man's switch: the Monitor's `Heartbeat Ping` (own branch, above the chain) GETs `$env.HEARTBEAT_URL`; Healthchecks.io (period 5, grace 10) emails after ~15 min of silence.
  It does NOT prove Postgres or the Processor work. Pause the check before a planned shutdown.
- Alert From/To come from `ALERT_EMAIL_FROM` / `ALERT_EMAIL_TO`; the invoice email's sender comes from `INVOICE_EMAIL_FROM` (the `example.test` placeholder is gone).
- Docs: `docs/runbook.md` (alerts, triage, backup/restore, rotation, rebuilding n8n), `docs/live-mode-checklist.md` (documentation only, never executed). Known gaps: PLAN.md.

## Decided status rules
- Intake sets `pending` if type is `checkout.session.completed` AND `payment_status = 'paid'`,
  or type is `checkout.session.async_payment_succeeded`. Everything else is `ignored`.
- Only the Processor moves `pending/failed -> processing -> done|failed`. `ignored` is never touched.
- Intake responses: 200 `{"received":true}` (new), 200 `{"received":true,"duplicate":true}`,
  400 bad signature or timestamp older than 5 min, 500 if the insert failed (so Stripe retries).
  Never 200 for an event that was not stored.

## Testing (PowerShell)
- `stripe listen --all-snapshot --forward-to localhost:5678/webhook/stripe-intake` (`--all-snapshot` is required on CLI 1.55+), `stripe trigger checkout.session.completed`
  (fires ~7 events; only that one is `pending`), `stripe events resend <event_id>`.
- Prove the 500 path by `wsl -d Ubuntu docker stop postgres`, trigger, then `docker start postgres` and resend.
  Do not edit the workflow to simulate failure.
- Seed a test row in a chosen state (stuck, stale, dead) with `scripts\seed-test-event.ps1`; it copies a real done payload and accepts only `evt_test_` ids.
- Test rows use `event_id LIKE 'evt_test_%'`; delete only those with `scripts\clean-test-event.ps1 -Id evt_test_... [-DryRun]` (FK order, all RESTRICT: `event_replays`, `side_effects`,
  `invoices`, `stripe_events`). `scripts/e2e.ps1` events have real `evt_...` ids and are tagged by Stripe metadata `e2e=true`, so the `evt_test_` filter misses them.
- `scripts\check-stale-timestamp.ps1` (run by e2e) sends validly signed requests with an old and a fresh timestamp; its two `evt_test_e2e_stale_*` rows are removed before and after. The signature is computed inside WSL, only the HMAC comes back.
  Prove it can fail with `-AgeSeconds 0` and `-CorruptSignature`. Recorded outputs for the README's failure table live in `docs/evidence.md`.

- Demo payments: `scripts\demo-payment.ps1 [-Tag e2e]` fires ONE 30,00 EUR "Workshop: Automatisierung mit n8n" payment (the `stripe trigger` overrides are documented in its header). It retries Stripe's `checkout_amount_mismatch`:
  Adaptive Pricing is on in the sandbox account and Stripe sometimes rejects the fixture's fixed `expected_amount` (the identical command succeeds on the next try). `stripe trigger` needs `stripe listen` running to reach Intake.
- `scripts\check-invoice-delivery.ps1 -EventId ... -InvoiceNumber ...` (run by e2e three times) checks the invoice row, exactly 1 email (subject, text + HTML, exactly 1 real PDF) and the `telegram_document` side effect.
  Prove it can fail with `-ExpectedAttachments 2`, `-SubjectPrefix 'Rechnung '`, `-ExpectedAmountCents 3100`, `-ExpectTelegramDocument $false`.
- Test rows that need a payload edit: seed as `-Status failed -Attempts 5` (dead, so the Processor cannot claim it), edit the payload, then set `status='pending', attempts=0`. The payload name is the customer name on the invoice (hostile-name proof); `object.id` is the Stripe session looked up.
- The sub-workflows cannot be executed through the n8n MCP (Execute Workflow Trigger); prove them through the Processor, or through a throwaway copy with a manual trigger (archive it afterwards).

## Gotchas learned
- n8n's HTTP Request node serialises two query parameters with the same name (`expand[]`) as an object (`expand[0]={"0":...}`) and Stripe answers 400: put the repeated query in the URL itself.
- A sub-workflow that throws shows the caller only a generic "Error in sub-workflow". The invoice sub-workflows therefore RETURN `problem` (empty = ok) and the Processor routes on it; the caller's `last_error` then holds the real message.
- Binary data does not survive a Postgres node: the Processor re-takes the PDF from the render result (`Restore PDF`) before sending the document. In the Telegram sub-workflow a failed try leaves an item without the PDF, so `Reload Input` restores it before every try.
- A retry loop in an SDK file is a plain `.to(earlierNode)` (see `stripe-send-telegram.sdk.ts`); `$runIndex` counts a node's runs (0, 1, 2) and drives both "max 3 tries" and the 2 s / 4 s backoff. The loop was proven in the real engine with a throwaway copy.
- `Intl.NumberFormat('de-DE', currency)` puts a NON-BREAKING space (U+00A0) before the currency sign: compare with ` `, not a normal space.
- Windows PowerShell 5.1 reads a script WITHOUT a BOM as cp1252: a literal `ü` in a `.ps1` becomes `Ã¼` and corrupts a test input silently. Build such characters from the code point (`[char]0xFC`) or keep scripts ASCII.
- The `stripe` CLI writes a hint line to stderr; under `$ErrorActionPreference = 'Stop'` PowerShell 5.1 turns that into an error. Set `Continue` around the native call (see `demo-payment.ps1`).
- `Invoke-RestMethod` can mis-decode UTF-8 JSON in PowerShell 5.1 (Mailpit's subject and text): decode `RawContentStream` bytes explicitly.
- NEVER set `alwaysOutputData: true` on the Insert Event node. When the DB is down it emits an empty item
  on the success output as well as the error output, so "200 Duplicate" races "500" and wins.
- Postgres nodes that write per item need `options.queryBatching: 'independently'`. Default batching merges items into one output,
  which breaks `$('Prepare Event').item` ("Multiple matches found").
- A zero-row `ON CONFLICT DO NOTHING` or `UPDATE ... RETURNING` emits `{"success":true}` (a phantom item): Intake's duplicate branch relies on it; the Processor guards with `Claimed Event?`, keep it.
- SDK `.onError()`: write `node.onError(handlerChain).to(next)`. `node.to(next).onError(h)` attaches the handler to `next`, and
  statement-level `.onTrue()` chains on already-used nodes are silently dropped. After building, check connections with `get_workflow_details`.
- n8n runs the branches of one trigger top-most first by canvas position, not in connection order: put a must-run-first branch above the others.
- n8n MCP cannot execute a workflow with an Execute Workflow Trigger (Send Alert); prove sub-workflows through a caller.
- Postgres, n8n and Mailpit timestamps are UTC; Windows and Healthchecks.io use Europe/Berlin (currently UTC+1). In docs and PRs write Berlin time with UTC in parentheses.
- `wsl <cmd>` runs through an outer shell that expands `$VAR` and `$(...)` first (this once printed a secret in an error message), and PowerShell 5.1 prepends a BOM when piping to `wsl`.
  Run anything with `$`, quotes or secrets through `& scripts\wsl-sh.ps1 -Script '...'` (base64); the hook `scripts/hooks/wsl-quoting-guard.mjs` blocks the unsafe forms (test: `node scripts/hooks/wsl-quoting-guard.test.mjs`).
- PowerShell 5.1: `Get-Date -UFormat %s` is the LOCAL epoch (3600 s ahead in Berlin). Use `[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()` for anything compared with a server clock (it made a "stale timestamp" test send a future one).
  Also, a pipeline that yields ONE string is not an array: `(... | Where-Object {...})[0]` returns its first character. Wrap in `@(...)` before indexing or counting.
- Intake's replay window is one-sided: it rejects timestamps older than 5 min but accepts future ones (measured, `docs/evidence.md`). Known and listed; not changed.
- PowerShell 5.1 mangles embedded double quotes in native arguments: use `git commit -F file`, `gh pr create --body-file`, and parse `gh ... --json` with ConvertFrom-Json (not `--jq` with spaces).
- `docker compose up -d` re-reads `~/n8n/.env`; `restart` does not. Recreating n8n drops the n8n MCP connection, sometimes for a long time: list executions with `scripts\n8n-executions.ps1` (reads n8n's SQLite, read-only).
- The official postgres image's pg_hba TRUSTS `local`, `127.0.0.1` and `::1` inside the `postgres` container: any password works there (and for every `docker exec postgres psql`).
  Test password auth from another container (`docker exec -e PGPASSWORD postgres-backup psql -h postgres ...`), exporting the value from `.env` inside a script.

## Rules
- Only ONE agent at a time may run `scripts/e2e.ps1` or touch the live stack (containers, n8n workflows, Postgres rows, Mailpit, the Stripe CLI). Parallel agents, e.g. in worktrees, work on files only.
  Why: a container recreate or `docker stop` mid-run fails the other agent's checks (happened in M5). Before taking the stack, check `Get-Process stripe` and recent `stripe_events` rows.
- Missing or invalid required data => mark the event `failed` with a clear `last_error`. Never substitute a default or fallback value.
- Any table holding financial or legal records uses `ON DELETE RESTRICT`, never CASCADE.
- Task specs live in `docs/tasks/` (long pasted prompts get truncated). Point to the file instead of pasting.
- Every change to a live workflow must be exported to its `.sdk.ts` file in the same session, then diffed.
- Never print or log secrets (signing secrets, tokens, DB passwords, the heartbeat URL). Redact `whsec_` before showing any output.
- Ask before deleting files, rewriting git history, or running DB migrations (schema changes need approval).
- Before declaring any workflow change done, run `scripts/e2e.ps1` and show the summary.
- Stripe stays in sandbox permanently (portfolio project). Nothing goes live; the live-mode checklist is documentation for a hypothetical client.
