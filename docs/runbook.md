# Runbook

Pipeline: Stripe -> Intake -> `stripe_events` -> Processor -> Mailpit + Telegram. Monitor, Error Handler and Send Alert watch it.
Everything runs in WSL Ubuntu under docker compose in `~/n8n`. Secrets live only in `~/n8n/.env`; this file contains none.

## 1. Start, stop, Pause

Start (also after every PC boot, containers have `restart: unless-stopped` but Docker must be running):

```powershell
wsl -d Ubuntu bash -c "cd ~/n8n && docker compose up -d"
```

`docker compose up -d` is the only command that re-reads `~/n8n/.env`. `docker restart` and `docker compose restart` do not.

**Before a planned shutdown, click Pause on the `stripe-pipeline` check in Healthchecks.io.** No pings arrive while the PC is off, so
without Pause you get one "down" email about 15 minutes later. The next ping after boot un-pauses the check by itself, no Resume needed.
A forgotten Pause only costs one false down email and one up email.

Stop: `wsl -d Ubuntu bash -c "cd ~/n8n && docker compose stop"`. Never `docker compose down -v` (deletes the data volumes).

## 2. Is it healthy? (one command)

```powershell
powershell -File scripts\e2e.ps1
```

It checks containers, migration 005, the `errorWorkflow` settings, a fresh Postgres dump, the three env vars, then pushes one real test
event through the whole pipeline. It creates one `e2e=true` event and deletes nothing. For a read-only look: `scripts\check-error-workflows.ps1`.

## 3. What each alert means

| Alert | Meaning | What to do |
|---|---|---|
| `DEAD` | Event is `failed` with 5 attempts. The Processor will never retry it. | Read `last_error`. Fix the cause (Mailpit/Telegram down, bad payload). Then replay (section 5). |
| `STALE PENDING` | `pending` for 10+ min. The Processor is not picking events up. | Is the Processor workflow published and active? Check its executions in n8n. Check `docker ps`. |
| `STUCK FAILED` | `failed`, attempts < 5, retry overdue 10+ min. Same cause as above. | Same as stale pending. |
| `STUCK PROCESSING` | `processing` for 20+ min. A run died mid-event. | The Processor releases rows at 10 min by itself; if it did not, the Processor is not running. |
| `Workflow error: <workflow> / <node>` | A workflow crashed. One alert per (workflow, node) per 15 min, later ones say "N similar errors suppressed". | Open the execution id from the alert. Postgres down is the common cause: `docker ps`, `docker start postgres`. |
| Healthchecks.io "stripe-pipeline is down" | No ping for about 15 min. n8n, WSL, the PC or the network is down. | Section 4. |

Alerts go to Telegram and to email (`ALERT_EMAIL_TO`). One channel failing is absorbed. If both fail, the Monitor retries on its next run.

## 4. Heartbeat is down

Work from the outside in:

1. Is the PC on and online? Was it a planned shutdown without Pause? Then just start the stack (section 1).
2. `wsl -l -v`: is Ubuntu `Running`? If not, run any `wsl` command to start it, then section 1.
3. `wsl -d Ubuntu docker ps`: are `n8n`, `postgres`, `mailpit`, `postgres-backup` all `Up`? Missing one: `docker compose up -d`.
4. `http://localhost:5678/healthz` should return 200. If n8n is up but the heartbeat is still down: open the Monitor's executions, look at `Heartbeat Ping`. The ping URL must be set (`docker exec n8n printenv HEARTBEAT_URL` prints a secret, so only check that it is non-empty; `scripts\e2e.ps1` does this).
5. The Monitor itself must be published and active (`scripts\check-error-workflows.ps1` lists it).

A green heartbeat only proves n8n's scheduler and network work. It does not prove Postgres or the Processor; those are covered by the alerts in section 3.

## 5. Replay a dead event

```powershell
powershell -File scripts\replay.ps1 -EventId evt_... -Reason "why" -DryRun
powershell -File scripts\replay.ps1 -EventId evt_... -Reason "why"
```

Only `failed` events are replayed. It never touches `side_effects` or `invoices`, which is what stops a second email or a second invoice.

## 6. Backup and restore

`postgres-backup` runs `pg_dump -Fc` at container start and every 24 h into `~/n8n/backups/automation-<UTC>.dump` (mode 600, root-owned).
It writes a temp file and renames it on success. After a failure it retries in 5 min. It keeps 14 days and prunes only its own
`automation-*.dump` files after a good dump. The folder is outside git because dumps contain customer emails.

Prove a restore works (never touches the live database; uses a throwaway container with no network):

```powershell
powershell -File scripts\restore-check.ps1 -Fresh
```

`-Fresh` takes a new dump first so the counts can match live. Without it, events that arrived after the newest dump make the check FAIL on purpose.

Real restore into the live Postgres (disaster only, stops the pipeline). The dump is root-only and visible only inside `postgres-backup`, so it is streamed from there.
Run these in a WSL shell (`wsl -d Ubuntu`), replacing `<file>`:

```bash
cd ~/n8n && docker compose stop n8n postgres-backup
docker exec postgres createdb -U automation automation_restore
docker exec postgres-backup cat /backups/<file>.dump | docker exec -i postgres pg_restore -U automation -d automation_restore --no-owner --exit-on-error
# check the restored database before swapping (row counts of stripe_events, side_effects, invoices, event_replays)
docker exec postgres psql -U automation -d postgres -c "ALTER DATABASE automation RENAME TO automation_broken" -c "ALTER DATABASE automation_restore RENAME TO automation"
docker compose up -d n8n postgres-backup
```

Then `scripts\e2e.ps1` must pass. Keep `automation_broken` until you are sure, then drop it by hand.
The dump restore itself is drilled by `scripts\restore-check.ps1`; the rename-and-swap above is not rehearsed. Ask before doing it on real data.

**Not covered:** n8n's own data (workflows, credentials) is in SQLite in the `n8n_data` volume, not in Postgres, so these dumps do not include it.
Rebuild it with section 8. Backups sit on the same disk as the database: they protect against bad data and a lost volume, not a lost machine.

## 7. Rotate secrets

Never paste a secret into chat, a ticket or a commit. Edit `~/n8n/.env` in WSL, and apply with `docker compose up -d` (not `restart`).

**`STRIPE_WEBHOOK_SECRET`** (`whsec_...`)
1. Local CLI: restart `stripe listen --all-snapshot --forward-to localhost:5678/webhook/stripe-intake`. It prints the new `whsec_` on STDERR.
2. Put it into `.env`, then `wsl -d Ubuntu bash -c "cd ~/n8n && docker compose up -d n8n"`.
3. Verify: `stripe trigger checkout.session.completed` is stored; a request with a fake signature gets 400 (`scripts\e2e.ps1` checks both).
Until step 2 finishes, every event gets 400. Stripe retries those later.

**`POSTGRES_PASSWORD`** (the trap: this variable only sets the password when the data volume is created, so changing `.env` alone changes nothing in the database)
1. Change it in the database first: `ALTER USER automation PASSWORD '<new>';` (psql inside the container, typed interactively so it stays out of shell history).
2. Put the same value into `~/n8n/.env`.
3. Update the n8n credential `Postgres automation` in the n8n UI (Credentials -> Postgres automation -> password -> Save).
4. `docker compose up -d`: this recreates `postgres` (its environment changed) and `postgres-backup`. Expect a few seconds of downtime and possibly one throttled crash alert.
5. Verify: a new `stripe trigger` event ends `done`; `docker restart postgres-backup` writes a new dump; the OLD password is refused over TCP:
   `docker exec postgres sh -c "PGPASSWORD=<old> psql -h 127.0.0.1 -U automation -d automation -c 'select 1'"` must fail.
The password lives in three places that must change together: the database, `.env` (read by `postgres-backup`), and the n8n credential.
Scripts that use `docker exec postgres psql` connect over the local socket and are unaffected.

**Telegram bot token**: revoke and re-issue it with BotFather, then update the n8n credential `Telegram alerts` (it is not in `.env`).
Verify with a seeded dead test event (`scripts\seed-test-event.ps1 -Id evt_test_x -Status failed -Attempts 5`), then delete that row.

**`HEARTBEAT_URL`**: the URL is the only credential. Create a replacement check in Healthchecks.io with the same period and grace,
put its URL into `.env`, `docker compose up -d n8n`, confirm the new check turns green, then delete the old check.

Only the Postgres rotation is rehearsed in this project; the other three are written from how the system is wired and not rehearsed.

## 8. Rebuild n8n from the `.sdk.ts` files

Needed if the `n8n_data` volume is lost. The five workflows are in the repo: `stripe-intake.sdk.ts`, `stripe-processor.sdk.ts`,
`stripe-error-handler.sdk.ts`, `stripe-monitor.sdk.ts`, `stripe-send-alert.sdk.ts`.

1. Start the stack, create the n8n owner account.
2. Re-create three credentials by hand (they are never exported): `Postgres automation` (host `postgres`, DB and user `automation`),
   `Mailpit SMTP` (host `mailpit`, port 1025, no auth), `Telegram alerts` (bot token).
3. Create the workflows from the files (n8n MCP `create_workflow_from_code`), Send Alert and Error Handler first.
4. **New workflow ids.** The Monitor calls Send Alert by id, and `errorWorkflow` points at the Error Handler by id. Update: the id in
   `stripe-monitor.sdk.ts` (Send Alert), the id in `scripts\check-error-workflows.ps1`, and the table in `CLAUDE.md`.
5. Set `settings.errorWorkflow` (= Error Handler id) on Intake, Processor and Monitor with `update_workflow`; the `.sdk.ts` files cannot carry it.
   Leave it empty on the Error Handler and Send Alert, so a failing alert can never trigger another alert.
6. Publish all five, then `scripts\check-error-workflows.ps1` and `scripts\e2e.ps1` must pass.

## 9. Known limits

- A green heartbeat does not prove Postgres or the Processor work.
- Backups are on the same disk as the database, and n8n's own data is not backed up yet.
- An undeliverable crash alert still uses up its 15 min throttle window.
- Both alert channels failing at once, and real Telegram 429/5xx backoff, were never provoked.
- Stripe is test mode only. See `docs/live-mode-checklist.md`.
