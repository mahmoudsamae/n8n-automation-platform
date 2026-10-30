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
- n8n, postgres, mailpit, postgres-backup run via docker compose in WSL Ubuntu: `~/n8n/docker-compose.yml`.
  Start: `wsl -d Ubuntu bash -c "cd ~/n8n && docker compose up -d"`. Ports: n8n :5678, postgres 127.0.0.1:5432, Mailpit UI :8025.
- `postgres-backup`: `pg_dump -Fc` at start + every 24 h into `~/n8n/backups/` (mode 600, never in git: customer emails), retry 5 min after a failure, 14-day prune.
  Postgres only: n8n's workflows (SQLite in the `n8n_data` volume) are NOT backed up. Restore drill: `scripts\restore-check.ps1 [-Fresh]`.
- e2e also runs `scripts\check-error-workflows.ps1` (each workflow's `errorWorkflow` on live n8n) and `scripts\check-backup-health.ps1` (TCP auth from `postgres-backup` with the `.env`
  password, same password inside the container, last log line is not `backup FAILED`); e2e's own psql calls use the trusted socket and cannot see a wrong password.
- n8n credential: `Postgres automation` (id `XVNN7sIThniqsuOf`). DB and user are both `automation`.
- Env var NAMES (the compose file only holds `${VAR}` references; real values live in `~/n8n/.env` in WSL, never copy them here):
  `STRIPE_WEBHOOK_SECRET`, `TELEGRAM_CHAT_ID`, `ALERT_EMAIL_TO`, `ALERT_EMAIL_FROM`, `HEARTBEAT_URL` (Healthchecks.io ping URL: the UUID is its only credential, treat it as a secret),
  `NODE_FUNCTION_ALLOW_BUILTIN`, `N8N_BLOCK_ENV_ACCESS_IN_NODE`, `GENERIC_TIMEZONE`, `TZ`, `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`.
- n8n credential: `Mailpit SMTP` (id `nxXABuEVvevioUzb`; host `mailpit`, port 1025, no auth). Mailpit keeps no history across restarts.
- n8n credential: `Telegram alerts` (id `kNsPsjXulOh7i4RQ`, Telegram bot). Chat ID is available in workflows as `$env.TELEGRAM_CHAT_ID`.
- `STRIPE_WEBHOOK_SECRET` must equal the `whsec_...` that `stripe listen` prints (on STDERR), or every event gets 400.

## Table `stripe_events`
Columns are in `migrations/` (001-005). Non-obvious: `claimed_at` is set when the Processor claims a row; `pending_since` (when the row last became pending; stuck-row release and
replay reset it) drives stale-pending alerts, never `received_at`; `alerted_at` is set by the Monitor after alerting and cleared by the Processor claim and by replay.

Applied by the user (002-005; the user runs migrations, Claude never does, and checks a table exists before relying on it): `event_replays`, `side_effects` (PK `(event_id, kind)`,
kind `email` or `telegram`), `invoices` (event_id UNIQUE), all FK ON DELETE RESTRICT. `invoice_number` = `INV-<year>-<6 digits>` from `invoice_number_seq` (no yearly reset; gaps possible).
`amount_cents` is Stripe's smallest unit as-is (JPY 1500 = 1500).

## Processor behaviour (M3, built)
- Every minute it releases rows stuck in `processing` > 10 min, then claims up to 10 (`pending`, or `failed` with attempts < 5) via `FOR UPDATE SKIP LOCKED`.
- Recipient is `customer_details.email` from the event. Missing/invalid email, amount or currency => event `failed` with a clear `last_error`. No fallback address.
- Telegram: up to 3 tries, 2 s then 4 s backoff, only for 429/5xx/network-looking errors. Other errors fail fast; the next run retries (max 5 attempts).
- Delivery is at-least-once: a crash between a send and its `side_effects` insert can duplicate that one message.

## Failure visibility (M4 + M5, built)
- Monitor sends ONE alert listing up to 10 events, then sets `alerted_at` (after delivery, so at-least-once). Kinds: `dead`, `stale pending`, `stuck failed`, `stuck processing`
  (rules: `docs/runbook.md` section 3). `stuck processing` waits 20 min, twice the Processor's 10 min release, so it never races a healthy Processor.
- Workflow crashes go through the Error Handler: one alert per (workflow | node) per 15 min, state in static data so it works with Postgres down. An undeliverable alert still uses up its window.
- Replay a dead event: `powershell -File scripts\replay.ps1 -EventId evt_... -Reason "..." [-DryRun]`. Only `failed` events; never touches `side_effects` or `invoices`.
- Dead man's switch: the Monitor's `Heartbeat Ping` (own branch, above the chain) GETs `$env.HEARTBEAT_URL`; Healthchecks.io (period 5, grace 10) emails after ~15 min of silence.
  It does NOT prove Postgres or the Processor work. Pause the check before a planned shutdown.
- Alert From/To come from `ALERT_EMAIL_FROM` / `ALERT_EMAIL_TO`; the Processor's sender is still the placeholder `stripe-processor@example.test` (live-mode checklist item).
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

## Gotchas learned
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
