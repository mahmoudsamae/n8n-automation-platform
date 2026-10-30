# n8n Automation Platform

Stripe payments -> Intake workflow -> `stripe_events` table -> Processor workflow -> Mailpit email + Telegram message.
Intake only verifies, classifies and stores (fast). All slow work belongs to the Processor.

## Workflows (n8n id -> source file)
- Stripe Intake `3j0pWVoxvDY2sdO5` -> `stripe-intake.sdk.ts` (live, published)
- Stripe Processor `ylR2t9B0ZAH1cLfq` -> `stripe-processor.sdk.ts` (live, published; schedule every 1 min)
- Stripe Error Handler `c2NT8k3JGpuS3r6I` -> `stripe-error-handler.sdk.ts` (errorWorkflow of Intake, Processor, Monitor)
- Stripe Monitor `yeSlEcPp87vCJT7D` -> `stripe-monitor.sdk.ts` (schedule every 5 min)
- Stripe Send Alert `WO2ebvkZGK5NxzVo` -> `stripe-send-alert.sdk.ts` (sub-workflow, Telegram + email; called by Handler and Monitor)

## Infra
- n8n, postgres, mailpit run via docker compose in WSL Ubuntu: `~/n8n/docker-compose.yml`.
  Start: `wsl -d Ubuntu bash -c "cd ~/n8n && docker compose up -d"`.
- Containers: `n8n` (:5678), `postgres` (127.0.0.1:5432), `mailpit` (UI :8025).
- Container `postgres-backup` (M5): `pg_dump -Fc` at start and every 24 h into `~/n8n/backups/automation-<UTC timestamp>.dump` (mode 600, root-owned, never in git: it holds customer emails).
  Temp file + rename; after a failed dump it retries in 5 min; keeps 14 days (prunes only its own `automation-*.dump` after a good dump). Postgres only: n8n's workflows live in SQLite in the `n8n_data` volume.
  `scripts\restore-check.ps1 [-Fresh]` restores the newest dump into a throwaway container with no network and compares row counts with live.
  `scripts\check-error-workflows.ps1` checks each workflow's `errorWorkflow` on live n8n; e2e runs both checks.
- n8n credential: `Postgres automation` (id `XVNN7sIThniqsuOf`). DB and user are both `automation`.
- Env var NAMES (the compose file only holds `${VAR}` references; real values live in `~/n8n/.env` in WSL, never copy them here):
  `STRIPE_WEBHOOK_SECRET`, `TELEGRAM_CHAT_ID`, `ALERT_EMAIL_TO`, `ALERT_EMAIL_FROM`, `HEARTBEAT_URL` (Healthchecks.io ping URL: the UUID is its only credential, treat it as a secret), `NODE_FUNCTION_ALLOW_BUILTIN`, `N8N_BLOCK_ENV_ACCESS_IN_NODE`,
  `GENERIC_TIMEZONE`, `TZ`, `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`.
- n8n credential: `Mailpit SMTP` (id `nxXABuEVvevioUzb`; host `mailpit`, port 1025, no auth). Mailpit keeps no history across restarts.
- n8n credential: `Telegram alerts` (id `kNsPsjXulOh7i4RQ`, Telegram bot). Chat ID is available in workflows as `$env.TELEGRAM_CHAT_ID`.
- `STRIPE_WEBHOOK_SECRET` must equal the `whsec_...` that `stripe listen` prints, or every event gets 400.
  `stripe listen` prints it on STDERR.

## Table `stripe_events`
`event_id TEXT PK`, `event_type TEXT NOT NULL`, `status TEXT NOT NULL DEFAULT 'pending'`,
`attempts INT NOT NULL DEFAULT 0`, `last_error TEXT`, `payload JSONB NOT NULL`,
`received_at TIMESTAMPTZ NOT NULL DEFAULT now()`, `processed_at TIMESTAMPTZ`, `claimed_at TIMESTAMPTZ` (set by the Processor when it claims a row; migration 003).
Migration 005 adds `alerted_at TIMESTAMPTZ` (Monitor sets it after alerting; Processor claim and replay clear it) and
`pending_since TIMESTAMPTZ NOT NULL DEFAULT now()` (when the row last became pending; stuck-row release and replay reset it).

Applied by the user (migrations 002-005):
- `event_replays` (one row per manual replay), `side_effects` (PK `(event_id, kind)`, kind `email` or `telegram`), `invoices` (event_id UNIQUE): all FK ON DELETE RESTRICT.
  `invoice_number` = `INV-<year>-<6 digits>` from `invoice_number_seq` (no yearly reset; gaps possible). `amount_cents` is Stripe's smallest unit as-is (JPY 1500 = 1500).
The user reviews and runs migrations themselves; Claude never runs them. Check the table exists before relying on it.

## Processor behaviour (M3, built)
- Every minute: release rows stuck in `processing` > 10 min (to `pending` if attempts < 5, else `failed`), then claim up to 10
  (`pending`, or `failed` with attempts < 5) via `FOR UPDATE SKIP LOCKED`.
- Recipient is `customer_details.email` from the event. Missing/invalid email, amount or currency => event `failed` with a clear `last_error`. No fallback address.
- Telegram: up to 3 tries, 2 s then 4 s backoff, only for 429/5xx/network-looking errors. Other errors fail fast; the next run retries (max 5 attempts).
- Delivery is at-least-once: a crash between a send and its `side_effects` insert can duplicate that one message.

## Failure visibility (M4, built)
- Monitor sends ONE alert listing up to 10 events, then sets `alerted_at` (after delivery, so at-least-once). Kinds: `dead` (failed, attempts >= 5),
  `stale pending` (pending 10+ min counted from `pending_since`, never `received_at`), `stuck failed` (failed, attempts < 5, `COALESCE(claimed_at, pending_since)` 10+ min old),
  `stuck processing` (`claimed_at` 20+ min old: twice the Processor's 10 min release, so it never races a healthy Processor).
- Workflow crashes go through the Error Handler: one alert per (workflow | node) per 15 min, state in static data so it works with Postgres down.
- Replay a dead event: `powershell -File scripts\replay.ps1 -EventId evt_... -Reason "..." [-DryRun]`. Only `failed` events; never touches `side_effects` or `invoices`.
- Dead man's switch (M5): the Monitor's `Heartbeat Ping` node (own branch, placed above the chain so it runs first) GETs `$env.HEARTBEAT_URL` every 5 min; Healthchecks.io (period 5, grace 10) emails the owner after ~15 min of silence,
  which covers n8n or WSL being down. 3 tries 5 s apart, then the error is absorbed. A green heartbeat does NOT prove Postgres or the Processor work. Pause the check before a planned shutdown.
- Alert sender and recipient come from `ALERT_EMAIL_FROM` / `ALERT_EMAIL_TO`. The Processor's own sender is still the literal placeholder `stripe-processor@example.test` (live-mode checklist item).
- Runbook: `docs/runbook.md` (alerts, heartbeat triage, backup/restore, secret rotation, rebuilding n8n). Live-mode steps: `docs/live-mode-checklist.md` (documentation only, never executed).
- Not covered: an undeliverable error alert still uses up its 15 min throttle window (see PLAN.md known gaps).

## Decided status rules
- Intake sets `pending` if type is `checkout.session.completed` AND `payment_status = 'paid'`,
  or type is `checkout.session.async_payment_succeeded`. Everything else is `ignored`.
- Only the Processor moves `pending/failed -> processing -> done|failed`. `ignored` is never touched.
- Intake responses: 200 `{"received":true}` (new), 200 `{"received":true,"duplicate":true}`,
  400 bad signature or timestamp older than 5 min, 500 if the insert failed (so Stripe retries).
  Never 200 for an event that was not stored.

## Testing (PowerShell)
```
stripe listen --all-snapshot --forward-to localhost:5678/webhook/stripe-intake
stripe trigger checkout.session.completed
stripe events resend <event_id>
wsl -d Ubuntu docker exec postgres psql -U automation -d automation -c "select event_id, event_type, status, attempts from stripe_events order by received_at"
```
- `--all-snapshot` is required on CLI 1.55+ (plain `listen` errors out).
- `stripe trigger` fires ~7 events; only the `checkout.session.completed` one is `pending`.
- Prove the 500 path by `wsl -d Ubuntu docker stop postgres`, trigger, then `docker start postgres` and resend.
  Do not edit the workflow to simulate failure.
- Seed a test row in a chosen state (stuck, stale, dead) with `scripts\seed-test-event.ps1`; it copies a real done payload and accepts only `evt_test_` ids.
- Test rows use `event_id LIKE 'evt_test_%'`; delete only those. `scripts/e2e.ps1` events have real `evt_...` ids and are tagged by
  Stripe metadata `e2e=true`, so that filter misses them. Delete order (all FKs RESTRICT): `event_replays`, `side_effects`, `invoices`, `stripe_events`.

## Gotchas learned
- NEVER set `alwaysOutputData: true` on the Insert Event node. When the DB is down it emits an empty item
  on the success output as well as the error output, so "200 Duplicate" races "500" and wins.
- n8n MCP: `validate_workflow` / `create_workflow_from_code` take the code inline (not a file path).
  Small edits to a live workflow: `update_workflow` operations, then `publish_workflow`.
- Postgres nodes that write per item need `options.queryBatching: 'independently'`. Default batching merges items into one output,
  which breaks `$('Prepare Event').item` ("Multiple matches found").
- A zero-row `ON CONFLICT DO NOTHING` or `UPDATE ... RETURNING` emits `{"success":true}` (a phantom item): Intake's duplicate branch relies on it; the Processor guards with `Claimed Event?`, keep it.
- The n8n Telegram node's error output is `{error: "<string>"}` (no httpCode). Its default parse mode choked on `_` in `evt_...`; parse_mode is set to HTML.
- SDK `.onError()`: write `node.onError(handlerChain).to(next)`. `node.to(next).onError(h)` attaches the handler to `next`, and
  statement-level `.onTrue()` chains on already-used nodes are silently dropped. After building, check connections with `get_workflow_details`.
- The SDK files cannot carry workflow settings. `errorWorkflow` (= Error Handler id) is set with `update_workflow` on Intake, Processor and Monitor; each file's header says so.
- n8n MCP cannot execute a workflow with an Execute Workflow Trigger (Send Alert); prove sub-workflows through a caller. Postgres, n8n and Mailpit timestamps are UTC; the Windows clock is currently UTC+1.

- PowerShell 5.1 prepends a UTF-8 BOM when piping text to `wsl`. psql tolerates it, `sh`/`bash` do not. Send scripts as base64 and decode in WSL
  (`wsl -d Ubuntu bash -c "echo <b64> | base64 -d | bash"`); see `scripts\restore-check.ps1`. Also, `wsl <cmd>` runs through an outer shell, so `$VAR` and quotes in the command are expanded/split before bash sees them.
- `docker compose up -d` re-reads `~/n8n/.env`; `restart` does not. Recreating n8n drops the n8n MCP connection for a few seconds.
- Postgres auth tests: the official image's pg_hba TRUSTS `local`, `127.0.0.1` and `::1` inside the `postgres` container, so any password is accepted there (and by every `docker exec postgres psql`).
  Test password auth from another container: `docker exec -e PGPASSWORD postgres-backup psql -h postgres -U automation -d automation -tAc "select 1"` (export the value from `.env` inside a script, never type it).
- `seed-test-event.ps1`: a seeded row has no `claimed_at` unless you pass `-ClaimedMinutesAgo`; a `processing` row defaults to claimed now.

## Rules
- Only ONE agent at a time may run `scripts/e2e.ps1` or touch the live stack (containers, n8n workflows, Postgres rows, Mailpit, the Stripe CLI). Parallel agents, e.g. in worktrees, work on files only.
  Why: e2e starts `stripe listen`, creates events and counts side effects, and a container recreate or `docker stop` mid-run fails the other agent's checks (this happened on 2026-10-30 during M5).
  Before taking the stack, check nobody else holds it (`Get-Process stripe`, recent `stripe_events` rows).
- Missing or invalid required data => mark the event `failed` with a clear `last_error`. Never substitute a default or fallback value.
- Any table holding financial or legal records uses `ON DELETE RESTRICT`, never CASCADE.
- Task specs live in `docs/tasks/` (long pasted prompts get truncated). Point to the file instead of pasting.
- Every change to a live workflow must be exported to its `.sdk.ts` file in the same session, then diffed.
- Never print or log secrets (signing secrets, tokens, DB passwords). Redact `whsec_` before showing any output.
- Ask before deleting files, rewriting git history, or running DB migrations (schema changes need approval).
- Before declaring any workflow change done, run `scripts/e2e.ps1` and show the summary.
- Stripe stays in sandbox permanently (portfolio project). Nothing goes live; the live-mode checklist is documentation for a hypothetical client.
