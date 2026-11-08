# n8n Automation Platform

Stripe payments -> Intake workflow -> `stripe_events` table -> Processor workflow -> Mailpit email + Telegram message.
Intake only verifies, classifies and stores (fast). All slow work belongs to the Processor.

## Workflows (n8n id -> source file)
- Stripe Intake `3j0pWVoxvDY2sdO5` -> `stripe-intake.sdk.ts` (live, published)
- Stripe Processor `ylR2t9B0ZAH1cLfq` -> `stripe-processor.sdk.ts` (live, published; schedule every 1 min)
- Stripe Error Handler `c2NT8k3JGpuS3r6I` -> `stripe-error-handler.sdk.ts` (errorWorkflow of Intake, Processor, Monitor); Stripe Monitor `yeSlEcPp87vCJT7D` -> `stripe-monitor.sdk.ts` (every 5 min)
- Stripe Send Alert `WO2ebvkZGK5NxzVo` -> `stripe-send-alert.sdk.ts` (sub-workflow, Telegram + email; called by Handler and Monitor)
- Stripe Render Invoice `3dvdSRSD6ObBVsxy` -> `stripe-render-invoice.sdk.ts` (sub-workflow, called by the Processor; the ONLY place that builds the invoice subject, HTML, text, Telegram text and the PDF, from the invoice row alone; callable again for any existing invoice, M7 will reuse it)
- Stripe Send Telegram `Yel7C2ufq8wR5s3W` -> `stripe-send-telegram.sdk.ts` (sub-workflow, called by the Processor for the owner text and the PDF document; ONE retry loop: 3 tries, 2 s then 4 s backoff on 429/5xx/network)
- The two invoice sub-workflows have no `errorWorkflow` (they return `problem`, the Processor reports it); `scripts\check-error-workflows.ps1` checks all 7. The Processor calls both BY ID: if one is recreated, update the id in `stripe-processor.sdk.ts`.

## Infra
- n8n, postgres, mailpit, postgres-backup, gotenberg run via docker compose in WSL Ubuntu: `~/n8n/docker-compose.yml`.
  Start: `wsl -d Ubuntu bash -c "cd ~/n8n && docker compose up -d"`. Ports: n8n :5678, postgres 127.0.0.1:5432, Mailpit UI :8025. WSL powers off ~15 s after the last `wsl` client exits (Docker with it): keep a WSL terminal open; after each boot `postgres-backup` logs `backup FAILED` until its 5 min retry.
- `gotenberg` (`gotenberg/gotenberg:8.39.0-chromium`) renders the invoice PDF: no published port (`http://gotenberg:3000`), 512m mem and swap limit, JS and webhooks off. Idle about 360-410 MB (resident Chromium, mostly reclaimable cache). Memory gate: `docs/evidence.md`.
- `postgres-backup`: `pg_dump -Fc` at start + every 24 h into `~/n8n/backups/` (mode 600, never in git: customer emails), 5 min retry, 14-day prune. Postgres only: n8n workflows (SQLite in `n8n_data`) are NOT backed up. Drill: `scripts/restore-check.ps1 [-Fresh]`.
- e2e also runs `scripts/check-sdk-drift.ps1` (each `.sdk.ts` vs the live export; first run does `npm ci` in `scripts/sdk-drift`), `scripts/check-docs.ps1` (this file <= 100 lines, no broken links, no public IP in tracked files), `scripts/check-error-workflows.ps1` (each workflow's `errorWorkflow` on live n8n) and `scripts/check-backup-health.ps1` (TCP password auth from `postgres-backup`; e2e's own psql uses the trusted socket and cannot see a wrong password).
- Env var NAMES (the compose file only holds `${VAR}` references; real values live in `~/n8n/.env` in WSL, never copy them here):
  `STRIPE_WEBHOOK_SECRET`, `TELEGRAM_CHAT_ID`, `ALERT_EMAIL_TO`, `ALERT_EMAIL_FROM`, `HEARTBEAT_URL` (Healthchecks.io ping URL: the UUID is its only credential, treat it as a secret),
  `INVOICE_EMAIL_FROM` (sender of the invoice email, e.g. `Musterwerk <rechnung@musterwerk.example>`; if unset the send fails),
  `TELEGRAM_SEND_PDF` (exactly `true` or `false`, NO default: it decides whether the invoice PDF, which holds customer data, is sent to Telegram, a third party; unset or any other value fails every event with a clear `last_error`),
  `NODE_FUNCTION_ALLOW_BUILTIN`, `N8N_BLOCK_ENV_ACCESS_IN_NODE`, `GENERIC_TIMEZONE`, `TZ`, `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`.
- M7 server (`ubuntu@m7-server`, Tailscale only, `docker-compose.prod.yml`, `infra/`): `docs/runbook.md` section 11. The owner approves any iptables, sshd or file-delete command there; nmap only inside Oracle's filed window; write `<public-ip>`, never the address. Fetch a public IP with `curl -4` or `api.ipify.org` (`ifconfig.me` answers IPv6 here and once printed the home IPv6 past an IPv4-only mask) and print only "same/differs". SSH only with Windows OpenSSH (`scripts\server-sh.ps1`; Git Bash's `ssh` is refused); its `.env` is `~/n8n-workflows/.env`.
- n8n credentials: `Postgres automation` (`XVNN7sIThniqsuOf`, DB and user `automation`), `Mailpit SMTP` (`nxXABuEVvevioUzb`, host `mailpit`:1025, no history across restarts), `Telegram alerts` (`kNsPsjXulOh7i4RQ`; chat id = `$env.TELEGRAM_CHAT_ID`),
  `Stripe read-only` (`qtmzPq7nRsOF9MAW`, restricted test-mode key: Checkout Sessions, PaymentIntents, Charges read; only the Processor's one lookup per invoice; never print it).
- `STRIPE_WEBHOOK_SECRET` must equal the `whsec_...` that `stripe listen` prints (on STDERR), or every event gets 400.

## Table `stripe_events`
Columns are in `migrations/` (001-006). Non-obvious: `claimed_at` is set when the Processor claims a row; `pending_since` (when the row last became pending; stuck-row release and replay reset it) drives stale-pending alerts, never `received_at`; `alerted_at` is set by the Monitor after alerting and cleared by the Processor claim and by replay.
Applied by the user (002-006; the user runs migrations, Claude never does, and checks a table exists before relying on it): `event_replays`, `side_effects` (PK `(event_id, kind)`, kind plain TEXT: `email`, `telegram` = owner text, `telegram_document`), `invoices` (event_id UNIQUE), all FK ON DELETE RESTRICT.
`invoice_number` = `INV-<year>-<6 digits>` from `invoice_number_seq` (gaps possible). `amount_cents` is Stripe's smallest unit as-is and the GROSS total. 006 added `customer_name`, `payment_method`, `line_items` (JSONB): the documents render from the row alone; the 27 pre-006 invoices have all three NULL (CHECK: all or none).

## Processor behaviour (M3, built)
- Every minute it releases rows stuck in `processing` > 10 min, then claims up to 10 (`pending`, or `failed` with attempts < 5) via `FOR UPDATE SKIP LOCKED`.
- Recipient is `customer_details.email` from the event. Missing/invalid email, name, session id, amount or currency, or `TELEGRAM_SEND_PDF` not exactly true/false => event `failed` with a clear `last_error`. No fallback address, no defaults.
- Invoice data: if no invoice exists yet, ONE read-only Stripe lookup (3 tries, 2 s then 4 s backoff on 429/5xx/network) gets product and payment method; stored on the row with the customer name, so a retry, replay or re-render never calls Stripe again. Inconsistent data (unpaid, amount/currency differs, items do not add up, no card brand) fails the event.
- Rendering goes through Stripe Render Invoice (`include_pdf` only while email or document is still to send); exactly one PDF on the email. Telegram goes through Stripe Send Telegram: owner text, and if `TELEGRAM_SEND_PDF=true` the PDF as a document (side effects `telegram`, `telegram_document`).
  If the PDF cannot be produced: no email, the owner text says "PDF fehlt", the event ends `failed` with the real reason (e.g. `Render PDF (Gotenberg): ...`); the next run sends only what is missing. If that text send ALSO fails, its error wins in `last_error` (accepted).
- Delivery is at-least-once: a crash between a send and its `side_effects` insert can duplicate that one message. Max 5 attempts per event.

## Failure visibility (M4 + M5, built)
- Monitor sends ONE alert listing up to 10 events, then sets `alerted_at` (after delivery, so at-least-once). Kinds: `dead`, `stale pending`, `stuck failed`, `stuck processing` (rules: `docs/runbook.md` section 3; `stuck processing` waits 20 min, twice the 10 min release).
- Workflow crashes go through the Error Handler: one alert per (workflow | node) per 15 min, state in static data so it works with Postgres down. An undeliverable alert still uses up its window.
- Replay a dead event: `powershell -File scripts\replay.ps1 -EventId evt_... -Reason "..." [-DryRun]`. Only `failed` events; never touches `side_effects` or `invoices`.
- Dead man's switch: the Monitor's `Heartbeat Ping` (own branch, above the chain) GETs `$env.HEARTBEAT_URL`; Healthchecks.io (period 5, grace 10) emails after ~15 min of silence. It does NOT prove Postgres or the Processor work. Pause the check before a planned shutdown.
- Docs: `docs/runbook.md` (alerts, triage, backup/restore, rotation, rebuilding n8n), `docs/live-mode-checklist.md` (never executed). Alert From/To = `ALERT_EMAIL_FROM`/`ALERT_EMAIL_TO`; invoice sender = `INVOICE_EMAIL_FROM`. Known gaps: PLAN.md.

## Decided status rules
- Intake sets `pending` if type is `checkout.session.completed` AND `payment_status = 'paid'`, or `checkout.session.async_payment_succeeded`. Everything else is `ignored`.
- Only the Processor moves `pending/failed -> processing -> done|failed`. `ignored` is never touched.
- Intake responses: 200 `{"received":true}` (new), 200 plus `"duplicate":true`, 400 bad signature or timestamp older than 5 min, 500 if the insert failed (so Stripe retries). Never 200 for an event that was not stored.

## Testing (PowerShell)
- `scripts/e2e.ps1` starts its own `stripe listen` and FAILS if any stripe process already runs: never ask the owner to start one before e2e.
- `stripe listen --all-snapshot --forward-to localhost:5678/webhook/stripe-intake` (`--all-snapshot` is required on CLI 1.55+), `stripe trigger checkout.session.completed`
  (fires ~7 events; only that one is `pending`), `stripe events resend <event_id>`.
- Prove the 500 path by `wsl -d Ubuntu docker stop postgres`, trigger, `docker start postgres`, resend. Never edit the workflow to simulate failure.
- Seed a test row in a chosen state (stuck, stale, dead) with `scripts\seed-test-event.ps1`; it copies a real done payload and accepts only `evt_test_` ids.
- Test rows use `event_id LIKE 'evt_test_%'`; delete only via `scripts/clean-test-event.ps1 -Id evt_test_... [-DryRun]` (FK order, all RESTRICT: `event_replays`, `side_effects`, `invoices`, `stripe_events`). `scripts/e2e.ps1` events have real `evt_...` ids, tagged by Stripe metadata `e2e=true`: the `evt_test_` filter misses them.
- `scripts/demo-payment.ps1 [-Tag e2e]` fires ONE 30,00 EUR demo payment (needs `stripe listen` running) and retries Stripe's flaky `checkout_amount_mismatch` (Adaptive Pricing is on in the sandbox; the same command succeeds next try).
- `scripts/check-invoice-delivery.ps1 -EventId ... -InvoiceNumber ...` (e2e runs it 3 times): row, exactly 1 email with 1 real PDF, `telegram_document` side effect. Prove it can fail: `-ExpectedAttachments 2`, `-SubjectPrefix 'Rechnung '`, `-ExpectedAmountCents 3100`, `-ExpectTelegramDocument $false`. To see ONE e2e step fail, sabotage it in a scratch `git worktree add --detach` and run e2e from there; never break a tool env-wide (`NODE_OPTIONS` crashed `check-sdk-drift` first). A runner's exit 1 alone proves nothing (a crash exits 1 too): also require its summary line.
- Test rows needing a payload edit: seed `-Status failed -Attempts 5` (dead, unclaimable), edit the payload (name = invoice customer, `object.id` = looked-up session), then `status='pending', attempts=0`.
- Sub-workflows cannot be run through the n8n MCP (Execute Workflow Trigger): prove them through the Processor or a throwaway manual-trigger copy (archive it after).

## Gotchas learned
- Stripe `expand[]` must stay in the URL query string: n8n's query parameters serialise a repeated name as an object and Stripe returns 400.
- Scripts keep secrets inside WSL: compute there (HMAC, checks) and return only the result. Never expand a secret in the outer shell.
- A sub-workflow that throws shows the caller only "Error in sub-workflow": the invoice sub-workflows RETURN `problem` (empty = ok) and the Processor routes on it. Binary (the PDF) does not survive a Postgres node: see `Restore PDF` and `Reload Input`.
- PowerShell 5.1: a `.ps1` WITHOUT a BOM is read as cp1252 (a literal `ü` corrupts test input silently: use `[char]0xFC`); the `stripe` CLI's stderr hint line is an error under `$ErrorActionPreference = 'Stop'`; `Invoke-RestMethod` can mis-decode UTF-8 (decode `RawContentStream`).
- `Intl.NumberFormat('de-DE')` puts a NON-BREAKING space (U+00A0) before the currency sign in exact-text comparisons.
- NEVER set `alwaysOutputData: true` on the Insert Event node: with the DB down it emits an item on the success output too, so "200 Duplicate" races "500" and wins.
- Postgres nodes that write per item need `options.queryBatching: 'independently'`, or `$('Prepare Event').item` fails ("Multiple matches found").
- A zero-row `ON CONFLICT DO NOTHING` or `UPDATE ... RETURNING` emits `{"success":true}` (a phantom item): Intake's duplicate branch relies on it; the Processor guards with `Claimed Event?`, keep it.
- SDK `.onError()`: write `node.onError(handlerChain).to(next)` (`node.to(next).onError(h)` attaches to `next`; `.onTrue()` chains on already-used nodes are silently dropped). After building, check connections with `get_workflow_details`.
- n8n runs the branches of one trigger top-most first by canvas position, not in connection order: put a must-run-first branch above the others.
- n8n 2.45.6's Telegram node has NO timeout option (no `timeout` in any of its files in the container). A real send timeout needs an HTTP Request node (`options.timeout`); documented as a known limit, fix planned, not built. Before promising a node option, grep the node source in the n8n container.
- Postgres, n8n and Mailpit timestamps are UTC; Windows and Healthchecks.io use Europe/Berlin (currently UTC+1). In docs and PRs write Berlin time with UTC in parentheses.
- `wsl <cmd>` runs through an outer shell that expands `$VAR` and `$(...)` first (this once printed a secret in an error message), and PowerShell 5.1 prepends a BOM when piping to `wsl`.
  Run anything with `$`, quotes or secrets through `& scripts\wsl-sh.ps1 -Script '...'` (base64); the hook `scripts/hooks/wsl-quoting-guard.mjs` blocks the unsafe forms (test: `node scripts/hooks/wsl-quoting-guard.test.mjs`).
  Both helpers (exit 3) and the hook `destructive-guard.mjs` refuse DROP, TRUNCATE, DELETE FROM, `down -v` etc. from `scripts/lib/destructive-patterns.json`; no override, the owner runs those by hand (tests: `destructive-guard.test.mjs`, its `--prove-failure` (built-in allow-all and block-all stubs must both fail it), `check-destructive-guard.ps1`, all in e2e).
- PowerShell 5.1: `Get-Date -UFormat %s` is the LOCAL epoch (3600 s ahead in Berlin). Use `[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()` for anything compared with a server clock (it made a "stale timestamp" test send a future one).
  Also, a pipeline that yields ONE string is not an array: `(... | Where-Object {...})[0]` returns its first character. Wrap in `@(...)` before indexing or counting. But `@('[]' | ConvertFrom-Json).Count` is 1, not 0: read the raw JSON for "none".
- PowerShell 5.1 mangles embedded double quotes in native arguments: use `git commit -F file` (write it with the Write tool: `Set-Content -Encoding utf8` puts a BOM into the subject), `gh pr create --body-file` (a new file name per PR: a failed Write once published an old PR's body; check with `gh pr view`), and parse `gh ... --json` with ConvertFrom-Json (not `--jq` with spaces).
- `docker compose up -d` re-reads `~/n8n/.env`; `restart` does not. Recreating n8n drops the n8n MCP connection, sometimes for a long time: list executions with `scripts\n8n-executions.ps1` (reads n8n's SQLite, read-only).
- The official postgres image TRUSTS `local`, `127.0.0.1` and `::1` inside the `postgres` container: any password works there. Test password auth from another container (`docker exec -e PGPASSWORD postgres-backup psql -h postgres ...`), exporting the value from `.env` inside a script.

## Rules
- Only ONE agent at a time may run `scripts/e2e.ps1` or touch the live stack (containers, n8n workflows, Postgres rows, Mailpit, the Stripe CLI). Parallel agents, e.g. in worktrees, work on files only.
  Why: a container recreate or `docker stop` mid-run fails the other agent's checks (happened in M5). Before taking the stack, check `Get-Process stripe` and recent `stripe_events` rows.
- Missing or invalid required data => mark the event `failed` with a clear `last_error`. Never substitute a default or fallback value.
- Any table holding financial or legal records uses `ON DELETE RESTRICT`, never CASCADE.
- Task specs live in `docs/tasks/` (long pasted prompts get truncated). Point to the file instead of pasting.
- Record an owner action (form sent, check rotated, key added) as done only after the owner confirms it; until then write "planned for <date>". PLAN.md once said Oracle's form went out on 3 Nov; it never did.
- Every change to a live workflow must be exported to its `.sdk.ts` file in the same session, then diffed.
- Never print or log secrets (signing secrets, tokens, DB passwords, the heartbeat URL). Redact `whsec_` before showing any output. A Healthchecks check page shows its ping URL under "How To Ping": ask for screenshots cropped above it. The repo is PUBLIC since 2026-11-05: every commit, PR body and comment is published at once. `main` is protected (PR only); new commits use the GitHub noreply email (local `user.email`).
- Before declaring any workflow change done, run `scripts/e2e.ps1` and show the summary.
- Stripe stays in sandbox permanently (portfolio project). Nothing goes live; the live-mode checklist is documentation for a hypothetical client.
