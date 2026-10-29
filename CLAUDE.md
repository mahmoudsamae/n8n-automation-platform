# n8n Automation Platform

Stripe payments -> Intake workflow -> `stripe_events` table -> Processor workflow -> Mailpit email + Telegram message.
Intake only verifies, classifies and stores (fast). All slow work belongs to the Processor.

## Workflows (n8n id -> source file)
- Stripe Intake `3j0pWVoxvDY2sdO5` -> `stripe-intake.sdk.ts` (live, published)
- Stripe Processor -> not built yet, see PLAN.md (M3)

## Infra
- n8n, postgres, mailpit run via docker compose in WSL Ubuntu: `~/n8n/docker-compose.yml`.
  Start: `wsl -d Ubuntu bash -c "cd ~/n8n && docker compose up -d"`.
- Containers: `n8n` (:5678), `postgres` (127.0.0.1:5432), `mailpit` (UI :8025).
- n8n credential: `Postgres automation` (id `XVNN7sIThniqsuOf`). DB and user are both `automation`.
- Env var NAMES (values live only in the compose file, never copy them here):
  `STRIPE_WEBHOOK_SECRET`, `NODE_FUNCTION_ALLOW_BUILTIN`, `N8N_BLOCK_ENV_ACCESS_IN_NODE`,
  `GENERIC_TIMEZONE`, `TZ`, `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`.
- `STRIPE_WEBHOOK_SECRET` must equal the `whsec_...` that `stripe listen` prints, or every event gets 400.
  `stripe listen` prints it on STDERR.

## Table `stripe_events`
`event_id TEXT PK`, `event_type TEXT NOT NULL`, `status TEXT NOT NULL DEFAULT 'pending'`,
`attempts INT NOT NULL DEFAULT 0`, `last_error TEXT`, `payload JSONB NOT NULL`,
`received_at TIMESTAMPTZ NOT NULL DEFAULT now()`, `processed_at TIMESTAMPTZ`.
Status CHECK: `pending | processing | done | failed | ignored`.
Partial index on `(status, received_at)` where status is pending or failed.

Planned: `side_effects(event_id, kind, done_at)`, PK `(event_id, kind)`, in `migrations/002_side_effects.sql`.
The user reviews and runs migrations themselves; Claude never runs them. Check the table exists before relying on it.

## Decided status rules
- Intake sets `pending` if type is `checkout.session.completed` AND `payment_status = 'paid'`,
  or type is `checkout.session.async_payment_succeeded`. Everything else is `ignored`.
- Only the Processor moves `pending/failed -> processing -> done|failed`. `ignored` is never touched.
- Intake responses: 200 `{"received":true}` (new), 200 `{"received":true,"duplicate":true}`,
  400 bad signature or timestamp older than 5 min, 500 if the insert failed (so Stripe retries).
  Never 200 for an event that was not stored.
- Dedupe is `INSERT ... ON CONFLICT (event_id) DO NOTHING RETURNING event_id`.

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
- Test rows use `event_id LIKE 'evt_test_%'`; delete only those.

## Gotchas learned
- NEVER set `alwaysOutputData: true` on the Insert Event node. When the DB is down it emits an empty item
  on the success output as well as the error output, so "200 Duplicate" races "500" and wins.
- A zero-row `ON CONFLICT DO NOTHING` already returns `{"success":true}`; that is how the duplicate branch fires.
- Webhook has `rawBody: true`; the Code node reads bytes from binary `data` via `this.helpers.getBinaryDataBuffer`.
  Re-serialized JSON would break the HMAC.
- n8n MCP: `validate_workflow` / `create_workflow_from_code` take the code inline (not a file path).
  Small edits to a live workflow: `update_workflow` operations, then `publish_workflow`.

## Rules
- Every change to a live workflow must be exported to its `.sdk.ts` file in the same session, then diffed.
- Never print or log secrets (signing secrets, tokens, DB passwords). Redact `whsec_` before showing any output.
- Ask before deleting files, rewriting git history, or running DB migrations (schema changes need approval).
- Stripe is test mode only until M5.
