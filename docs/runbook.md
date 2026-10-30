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

It checks containers, migration 005, the `errorWorkflow` settings, a fresh Postgres dump, that the backup container can log in over TCP and is not failing, the three env vars, then pushes one real test
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

**`POSTGRES_PASSWORD`** (the trap: this variable only sets the password when the data volume is created, so changing `.env` alone changes nothing in the database).
Rehearsed on 2026-10-30; steps 1-7 are what was done. The new value never appears on screen, in chat, on a command line or in shell history.
1. **Fresh backup first**, so you can go back: `docker restart postgres-backup`, wait for `backup ok` in `docker logs postgres-backup`.
2. **Generate the new password into a temp file** in WSL that only you can read (mode 600).
3. **`ALTER USER automation PASSWORD :'pw';`** through a psql *variable* (`-v pw=...` filled from the temp file, the SQL sent on stdin; `-c` does not expand variables). The password is then neither in the SQL text nor in history.
   From this moment n8n's old credential is wrong: the downtime window starts.
4. **Update `POSTGRES_PASSWORD` in `~/n8n/.env`** with `sed`, editing the line in place (never `echo` it).
5. **Update the n8n credential `Postgres automation`**: copy the value from the temp file to the clipboard with `clip.exe`, paste it into the credential, press Test (it must succeed), Save. The window ends here;
   in the rehearsal 3 executions failed (Processor 2, Monitor 1) in about 2 minutes, the Error Handler alerted once per (workflow, node), and every run since succeeded.
6. **`docker compose up -d postgres-backup`.** This also recreates `postgres`, because `POSTGRES_PASSWORD` is in its environment too. The data stays in the volume and the `ALTER USER` password persists.
   Postgres and the backup container start together, so the first dump can fail with "the database system is starting up"; the backup container retries by itself after 5 minutes (it did).
7. **Delete the temp file** with `shred -u`.
8. **Verify, without printing a secret** (all done in the rehearsal):
   - `scripts\e2e.ps1` passes. It pushes a real `stripe trigger` event through n8n's credential to `done`.
   - `scripts\restore-check.ps1 -Fresh` passes: `postgres-backup` dumped over TCP with the new password and the dump restored with matching counts.
   - `.env`, the `postgres` container and the `postgres-backup` container hold the same value. Compare inside one WSL script and print only yes/no.
   - Over TCP **from another container** the new password is accepted and a wrong one is refused. Export the password from `.env` inside the script, never type it:
     `docker exec -e PGPASSWORD postgres-backup psql -h postgres -U automation -d automation -tAc "select 1"` (accepted), and the same with `PGPASSWORD=wrong` gives `FATAL: password authentication failed`.
   - **Do not test over loopback inside the `postgres` container.** pg_hba has `trust` for `local`, `127.0.0.1` and `::1` (lines 117-121), so any password is accepted there; measured: a wrong password was accepted.
     Only connections from other containers (and the published port) go through `scram-sha-256`.
   - The OLD password cannot be tested: it no longer exists anywhere. Its rejection follows from step 3 (`ALTER USER` replaces the password) and was not tested with the old value.
The password lives in three places that must change together: the database, `.env` (read by `postgres-backup`), and the n8n credential. The scripts that run `docker exec postgres psql` use the local socket (trust),
so their calls cannot see a wrong password. `scripts\check-backup-health.ps1` (run by e2e) closes that gap: it authenticates over TCP from `postgres-backup` with the `.env` password,
checks that the container was created with that same password (catches a forgotten recreate), and fails if the container's last log line is `backup FAILED`
(after a Postgres restart that clears itself on the 5-minute retry, or run `docker restart postgres-backup`). It prints yes/no only.
Prove it can fail: `$env:PGPASSWORD = 'wrong'` then run it, expect `[FAIL] TCP auth` and exit 1 (the override is for tests only).

**Recommendation for a real client: two login roles, no downtime window.** The procedure above has a window (steps 3-5) in which a consumer holds a rejected password. A client should not accept that. Not built or rehearsed here.
- Keep `automation` as the admin role: migrations and the `docker exec ... psql` scripts, never used by n8n over TCP.
- Create a NOLOGIN group role `automation_app` with only what the pipeline needs (SELECT, INSERT, UPDATE on the tables, USAGE on the sequences; no DELETE, in line with `ON DELETE RESTRICT`),
  and two LOGIN roles `automation_a` and `automation_b`, both members of it.
- n8n and `postgres-backup` use the active role, say A. To rotate: set a new password on the idle role B, switch `.env` and the n8n credential to B, recreate the backup container, verify as in step 8.
  A's old password stays valid the whole time, so nothing is rejected at any moment, nothing has to be done in a hurry, and rollback is pointing back at A.
- Only after everything runs on B, give A a new random password. The next rotation flips back to A.
- Bonus: n8n no longer connects as a superuser.

**Telegram bot token**: revoke and re-issue it with BotFather, then update the n8n credential `Telegram alerts` (it is not in `.env`).
Verify with a seeded dead test event (`scripts\seed-test-event.ps1 -Id evt_test_x -Status failed -Attempts 5`), then delete that row.

**`HEARTBEAT_URL`**: the URL is the only credential. Create a replacement check in Healthchecks.io with the same period and grace,
put its URL into `.env`, `docker compose up -d n8n`, confirm the new check turns green, then delete the old check.

Rehearsed in this project: the Postgres password and `HEARTBEAT_URL`. The Telegram token and `STRIPE_WEBHOOK_SECRET` steps are written from how the system is wired and not rehearsed.

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
