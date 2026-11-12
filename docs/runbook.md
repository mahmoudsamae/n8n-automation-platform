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

It checks containers (including `gotenberg`), migrations 005 and 006, the `errorWorkflow` settings of all 7 workflows, that each `.sdk.ts` file matches its live workflow (`scripts\check-sdk-drift.ps1`; the first run installs the pinned SDK with `npm ci`), that CLAUDE.md is within its line limit and no README or docs link is broken (`scripts\check-docs.ps1`), a fresh Postgres dump, that the backup container can log in over TCP and is not failing, that workflows cannot read the environment and their config is complete
(`scripts\check-n8n-env.ps1`: data tables `stripe_config` and `stripe_heartbeat`, `telegram_send_pdf` exactly `true` or `false`), then pushes one real demo payment (`scripts\demo-payment.ps1`) through the whole pipeline: invoice row, exactly 1 email with exactly 1 real PDF, the Telegram document, a resend, a Processor re-run, and ends with a stale-timestamp check.
It creates one `e2e=true` event and deletes no real data (its only deletes are its own two `evt_test_e2e_stale_*` rows). For a read-only look: `scripts\check-error-workflows.ps1`.

## 3. What each alert means

| Alert | Meaning | What to do |
|---|---|---|
| `DEAD` | Event is `failed` with 5 attempts. The Processor will never retry it. | Read `last_error`. Fix the cause (Mailpit/Telegram down, bad payload). Then replay (section 5). |
| `STALE PENDING` | `pending` for 10+ min. The Processor is not picking events up. | Is the Processor workflow published and active? Check its executions in n8n. Check `docker ps`. |
| `STUCK FAILED` | `failed`, attempts < 5, retry overdue 10+ min. Same cause as above. | Same as stale pending. |
| `STUCK PROCESSING` | `processing` for 20+ min. A run died mid-event. | The Processor releases rows at 10 min by itself; if it did not, the Processor is not running. |
| `DEAD` with `last_error` `Render PDF (Gotenberg): ...` | The PDF could not be produced for 5 attempts (the owner got ONE text saying "PDF fehlt"). | Section 10: is `gotenberg` running? Then replay (section 5): only the missing email and document are sent. |
| `DEAD` with `last_error` `data table stripe_config ...` or `telegram_send_pdf in data table stripe_config must be true or false` | The config row is missing, doubled or has an empty or wrong value. | n8n > Overview > Data tables > `stripe_config`: exactly one row, every cell filled (section 10). `scripts\check-n8n-env.ps1` names the problem. Then replay. |
| `DEAD` with `last_error` `... No such checkout.session ...` or another Stripe message | The one Stripe lookup for the invoice failed (a 4xx is not retried). | Check the `Stripe read-only` credential and the session id in the payload; nothing was sent and no invoice exists. |
| `Workflow error: <workflow> / <node>` | A workflow crashed. One alert per (workflow, node) per 15 min, later ones say "N similar errors suppressed". | Open the execution id from the alert. Postgres down is the common cause: `docker ps`, `docker start postgres`. |
| Healthchecks.io "stripe-pipeline is down" | No ping for about 15 min. n8n, WSL, the PC or the network is down. | Section 4. |

Alerts go to Telegram and to email (`stripe_config.alert_email_to`). One channel failing is absorbed. If both fail, the Monitor retries on its next run.

## 4. Heartbeat is down

Work from the outside in:

1. Is the PC on and online? Was it a planned shutdown without Pause? Then just start the stack (section 1).
2. `wsl -l -v`: is Ubuntu `Running`? If not, run any `wsl` command to start it, then section 1.
3. `wsl -d Ubuntu docker ps`: are `n8n`, `postgres`, `mailpit`, `postgres-backup` all `Up`? Missing one: `docker compose up -d`.
4. `http://localhost:5678/healthz` should return 200. If n8n is up but the heartbeat is still down: open the Monitor's executions, look at `Heartbeat Ping`. The ping URL must be the one row of data table `stripe_heartbeat` (no row means no ping). `scripts\check-n8n-env.ps1` checks that without printing it; never open that row through the n8n MCP or in a screenshot.
   **The Monitor also skips the ping on purpose** when the alert settings in `stripe_config` (`telegram_chat_id`, `alert_email_to`, `alert_email_from`) are incomplete or the table cannot be read: then no n8n alert could reach anyone, so Healthchecks' own email is the alarm. Look at the node `Alert Config` in the latest Monitor execution: its `config_problem` names the cause (it shows no values). Fix the row, the next run pings again.
   Note: the ping URL is stored in every Monitor execution (output of `Load Heartbeat URL`), in n8n's SQLite and in the editor's execution view. Treat execution data like the table itself: never read that node through the MCP or show it in a screenshot.
5. The Monitor itself must be published and active (`scripts\check-error-workflows.ps1` lists it).
6. A gap in ALL executions (Monitor and Processor) while WSL stayed up: look for an out-of-memory kill, `journalctl --since "<start of the gap>" | grep -i "out of memory"` in WSL. On 9 Nov the kernel killed n8n (1.38 GB, WSL capped at 2 GB), Docker restarted it, and Healthchecks emailed the down 15 min after the last ping (`docs/evidence.md`).

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

**The Stripe signing secret** (`whsec_...`). It lives in two places that must agree: the n8n credential `Stripe webhook secret` (type crypto, field Hmac Secret), which the Intake's HMAC node uses, and `STRIPE_WEBHOOK_SECRET` in `.env`, which only the host-side test scripts use to sign test requests. n8n never gets it as a variable.
1. Get the new value: `stripe listen --print-secret` (or the server endpoint's signing secret in the Stripe Dashboard).
2. n8n > Overview > Credentials > `Stripe webhook secret` > Hmac Secret: `Ctrl+A`, paste, **Save**. The field shows a masked placeholder: text typed onto it is ignored, so select all first.
   Confirm the save reached the database: the credential's `updatedAt` in n8n's SQLite must change (in M7b-3 two edits that looked saved were not).
3. Put the same value into `.env` as `STRIPE_WEBHOOK_SECRET` (no restart needed: n8n does not read it).
4. Verify: `scripts\check-stale-timestamp.ps1` (a fresh correctly signed request is stored, a stale one gets 400) and `scripts\e2e.ps1`.
Rehearsed in M7b-3 as a fail test: a wrong Hmac Secret made a correctly signed request get 400 and not be stored; restoring it made it pass again.

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

**Never take a screenshot of a Healthchecks page.** The checks list shows every check's ping URL (Ping URL column) and a check page shows it under "How To Ping"; a list screenshot exposed two URLs in M7b-3. Read out the status and the last-ping time instead. Any URL that was on screen in a shared image is rotated.

**The heartbeat ping URL**: the URL is the only credential. Create a replacement check in Healthchecks.io with the same period and grace,
paste its URL into n8n > Data tables > `stripe_heartbeat` > `heartbeat_url` (no restart), update Bitwarden, confirm the new check gets the next Monitor ping (every 5 min), then delete the old check.

Rehearsed in this project: the Postgres password, the heartbeat URL (M5 through `.env`, M7b-3 through the data table) and the signing secret (M7b-3, see above). The Telegram token steps are written from how the system is wired and not rehearsed.

## 8. Rebuild n8n from the `.sdk.ts` files

Needed if the `n8n_data` volume is lost. The seven workflows are in the repo: `stripe-intake.sdk.ts`, `stripe-processor.sdk.ts`, `stripe-error-handler.sdk.ts`, `stripe-monitor.sdk.ts`,
`stripe-send-alert.sdk.ts`, `stripe-render-invoice.sdk.ts`, `stripe-send-telegram.sdk.ts`.

1. Start the stack, create the n8n owner account.
2. Re-create five credentials by hand (they are never exported): `Postgres automation` (host `postgres`, DB and user `automation`),
   `Mailpit SMTP` (host `mailpit`, port 1025, no auth), `Telegram alerts` (bot token), `Stripe read-only` (type Stripe API, a restricted test-mode key with read access to Checkout Sessions, PaymentIntents and Charges, restricted to `api.stripe.com`),
   `Stripe webhook secret` (type Crypto, only Hmac Secret = the `whsec_`).
   Re-create the two data tables (Overview > Data tables), each with exactly one row. The workflows reference them by id, so put the new ids into the `dataTableId` values of the `.sdk.ts` files (5 references) like the credential ids: `stripe_config` (string columns `telegram_chat_id`, `alert_email_to`, `alert_email_from`, `invoice_email_from`, `telegram_send_pdf`) and `stripe_heartbeat` (`heartbeat_url`). `scripts\check-n8n-env.ps1` must pass.
3. Create the workflows from the files (n8n MCP `create_workflow_from_code`) in this order: Send Alert, Error Handler, **Render Invoice, Send Telegram**, then Monitor, Intake and the Processor last.
4. **New workflow ids.** The Monitor calls Send Alert by id, the Processor calls Render Invoice and Send Telegram by id, and `errorWorkflow` points at the Error Handler by id. Update: the ids in
   `stripe-monitor.sdk.ts` (Send Alert) and `stripe-processor.sdk.ts` (Render Invoice, Send Telegram), the ids in `scripts\check-error-workflows.ps1`, `scripts\hooks\n8n-drift-reminder.mjs`, and the table in `CLAUDE.md`.
5. Set `settings.errorWorkflow` (= Error Handler id) on Intake, Processor and Monitor with `update_workflow`; the `.sdk.ts` files cannot carry it.
   Leave it empty on the Error Handler, Send Alert, Render Invoice and Send Telegram (the first so a failing alert can never trigger another alert, the other two because they return their problems to the Processor).
6. Publish all seven (an unpublished draft is not what the trigger runs; the drift check fails on one), then `scripts\check-sdk-drift.ps1`, `scripts\check-error-workflows.ps1` and `scripts\e2e.ps1` must pass.

## 9. Known limits

- A green heartbeat does not prove Postgres or the Processor work.
- Backups are on the same disk as the database, and n8n's own data is not backed up yet.
- An undeliverable crash alert still uses up its 15 min throttle window.
- Both alert channels failing at once, and real Telegram 429/5xx backoff, were never provoked. The same holds for a failing `sendDocument` call; the retry loop itself was proven in the engine with a stub.
- The Telegram sends have no timeout: n8n's Telegram node has no timeout option (checked in the n8n 2.45.6 container). A hung call holds one Processor run until the 10 min stuck-row release, and the `stuck processing` alert fires after 20 min; no event is lost. The fix is to replace `Send Message` and `Send Document` in `Stripe Send Telegram` with HTTP Request nodes that set `options.timeout` (30 s), then re-prove the retry loop, one live payment and e2e. Not built.
- A wrong Hmac Secret in `Stripe webhook secret` rejects every real event with 400, and nothing in this stack alerts: no row is stored, so the Monitor sees nothing, and the heartbeat stays green. Stripe retries for up to 3 days and emails the account owner about a failing endpoint; `stripe events resend` recovers the events. So after every rotation run `scripts\check-stale-timestamp.ps1` and e2e (section 7).
- The laptop's WSL is capped at 2 GB (`.wslconfig`). On 2026-11-09 the kernel OOM-killed n8n there (1.38 GB); the restart policy recovered it and pings resumed after 25 min. The cause of the growth is not proven; it is measured in M7b-7 on the server, where n8n is capped at 1536m.
- If the PDF cannot be produced AND the owner text send also fails, `last_error` names the Telegram failure and the PDF problem resurfaces on the next run.
- Stripe is test mode only. See `docs/live-mode-checklist.md`.

## 10. Invoices: Gotenberg, the PDF and Telegram

**Flow.** Per paid event the Processor looks up the product and the payment method once from Stripe (only when no invoice exists yet) and stores them on the invoice row. `Stripe Render Invoice` then builds the German email (HTML + text), the Telegram text and the PDF
from that row alone, so a retry or a replay produces the same document and never calls Stripe again. The email carries exactly one PDF. The Telegram owner text and, if enabled, the PDF as a document go through `Stripe Send Telegram`.

**Gotenberg** (`gotenberg/gotenberg:8.39.0-chromium`, internal only, no published port): `docker compose ps gotenberg`; restart with `docker compose up -d gotenberg`. It is capped at 512 MB (memory and swap). Chromium stays resident, so it idles at about 360-410 MB.
If it is down the Processor keeps retrying every minute: no email is sent, the owner gets ONE text saying "PDF fehlt", and `last_error` says `Render PDF (Gotenberg): ...`. When it is back the next run sends the email and the document, and not a second text.

**Sending the PDF to Telegram is a data-protection decision.** The invoice PDF contains the customer's name and email address (and what they bought). Sending it to Telegram passes that personal data to a third party, a messaging provider whose servers are outside this deployment.
Under the GDPR a real deployment must decide this on purpose: it needs a legal basis, a processor agreement or other transfer safeguard where required, a retention and deletion answer (the messages stay in the chat), and a mention in the privacy notice. Until then run with `telegram_send_pdf` set to `false`:
the owner text still goes out (it also names the customer) and the PDF stays on the email only. In this portfolio project everything is sandbox data and the value is `true` for the demo. This is documentation for a hypothetical client, not legal advice.

**`telegram_send_pdf`** (data table `stripe_config`). Exactly `true` or `false`, no default: empty or anything else fails every event with a clear `last_error` (`telegram_send_pdf in data table stripe_config must be true or false`, or `... is empty`).
Change it in n8n > Overview > Data tables > `stripe_config`; it applies on the next Processor run, no restart. Workflows cannot read the environment (`N8N_BLOCK_ENV_ACCESS_IN_NODE=true`), so a `.env` line has no effect.
With `false` no document is sent and `telegram_document` is not required for `done`.

**Rotate the `Stripe read-only` key.** In the Stripe Dashboard (test mode) create a replacement restricted key with the same three read permissions, put it into the n8n credential `Stripe read-only`, run `scripts\demo-payment.ps1` with a listener (or `scripts\e2e.ps1`) and check that the event ends `done`, then delete the old key. The key is not in `.env` and never in git.

## 11. Server

The M7 server: OCI Always Free, `VM.Standard.A1.Flex`, 1 OCPU, 4 GB, Ubuntu 24.04, region `eu-frankfurt-1`. Runs the 7 workflows; public only at `https://invoice.mahmud-alhussen.de/webhook/stripe-intake` since M7b-5b (see "Public hostname" below). Design: `docs/tasks/m7-server.md`. The server has its own secrets; nothing from the laptop's `.env`. Never click Upgrade or Pay As You Go in OCI.

**Access, only over Tailscale.** `ssh -i "$HOME\.ssh\oci_m7" ubuntu@m7-server`. Nothing publishes a port, so admin UIs go through an SSH tunnel to fixed container IPs:
`ssh -i "$HOME\.ssh\oci_m7" -L 5678:172.30.0.10:5678 -L 8025:172.30.0.11:8025 ubuntu@m7-server`, then http://localhost:5678 (n8n) and http://localhost:8025 (Mailpit). From scripts: `scripts\server-sh.ps1 -Script '...'` (base64, so no quoting problems).

**Is it healthy?**
```powershell
powershell -File scripts\check-server-base.ps1                              # VM matches cloud-init, 4 GB, port 22 only on tailscale0, password login off
powershell -File scripts\check-prod-stack.ps1                               # stack up, no published ports, nothing on public addresses, memory
powershell -File scripts\check-public-ports.ps1 -Mode Tailnet -Ip <public-ip>   # Tailscale SSH works, public SSH does not answer (no nmap)
powershell -File scripts\check-imds-blocked.ps1                             # containers cannot reach the metadata service; DNS, HTTPS and the host still work
powershell -File scripts\check-db-role.ps1                                  # n8n_app holds exactly migration 007's privileges and logs in over TCP
powershell -File scripts\check-tunnel-allowlist.ps1 -ExpectWaf              # from outside: only POST /webhook/stripe-intake gets through, the WAF 403s the rest
powershell -File scripts\check-probe-quiet.ps1                              # probe-style POSTs: 400, successful Intake runs, no row, no Error Handler, no alert
powershell -File scripts\measure-n8n-memory.ps1                             # n8n memory peaks: idle, payments, exports, overlap (about 45 min, 11 sandbox payments)
```
`check-prod-stack.ps1` also fails on a container that was OOM-killed or restarted by its restart policy, on an `oom_kill` in any container's cgroup, on memory used below 22% (Oracle reclaims an idle Always Free A1 VM below 20%; "used" is MemTotal - MemAvailable, like Oracle's metric) and on a `mem_limit` sum above 75% of RAM (2,816 MB = 72.3% today: a new service needs room taken elsewhere). Docker keeps `OOMKilled` and `RestartCount` for a container's lifetime, so after triage (logs, `memory.events`) the check stays red until that container is recreated: `docker compose -f docker-compose.prod.yml up -d --force-recreate <service>`.

**n8n executions.** Pruned at 168 h or 5,000 executions, whichever comes first (`docker-compose.prod.yml`); at about 1,800 a day that is about 2.7 days of history. The Monitor saves no successful executions (`scripts/lib/workflows.ps1` `ServerSettings`, checked by `check-error-workflows.ps1`): its runs show only in n8n's event log and in Healthchecks `m7-server-n8n`; failed runs are saved as before.

**Public hostname (M7b-5b).** `cloudflared` (locally-managed tunnel `m7-invoice`, id in `infra/cloudflared.yml`) dials out, so nothing listens on the public IP. Two layers, told apart by status code:
- cloudflared's ingress (`infra/cloudflared.yml`, in git): only path `^/webhook/stripe-intake$` goes to `http://n8n:5678`, everything else gets an empty 404. It matches the DECODED path, so encoded aliases (`/webhook%2fstripe-intake`) reach n8n, and a GET there returns the editor's static shell (no data). It also cannot filter methods.
- The Cloudflare WAF custom rule `m7-invoice-allowlist` (dashboard, zone `mahmud-alhussen.de`): 403 for anything but `POST /webhook/stripe-intake`, aliases included. It is required, not optional. Bot Fight Mode stays off (it would challenge Stripe).
- Credentials: `secrets/cloudflared.json` (Bitwarden, as text), owner uid 65532 (the image's user), mode 400, set by `bootstrap.sh`. After replacing it: `docker compose -f docker-compose.prod.yml up -d --force-recreate cloudflared`.
- n8n: `N8N_WEBHOOK_URL`, `N8N_PROXY_HOPS=1`, `N8N_PUBLIC_API_DISABLED=true` and `N8N_PUBLIC_API_SWAGGERUI_DISABLED=true`. In 2.45.6 `/api/v1` stays mounted anyway (the flag only turns off API-key auth), so the two layers are what keep it off the internet.
- cloudflared logs each request with the client IP (personal data); Docker's log size limits bound how long it stays.
- **Outside probe (M7b-7).** The heartbeat pings outward and stays green while the tunnel or the WAF is broken, so GitHub Actions (`.github/workflows/outside-probe.yml`, `scripts/outside-probe.sh`) POSTs a bad signature every 15 min and expects `400 invalid signature`; it pings Healthchecks `m7-public-probe` (period 15, grace 45), or `/fail` after 3 tries, which alerts at once. Ping URL: Actions secret `HC_PUBLIC_PROBE_URL` (rotate like section 7: new check, new secret, then delete the old check). `m7-public-probe` down: Actions > outside-probe > the red run shows the status per try (530 = tunnel down, 403 = WAF, 502 = n8n down, 400 with another error = the Intake). Run it by hand: Actions > outside-probe > Run workflow. GitHub disables the schedule after 60 days without repository activity (the check then alerts after about 1 h of silence): re-enable it under Actions. Each probe is one successful Intake execution, no row, no alert (`scripts/check-probe-quiet.ps1`).
- n8n down or restarting: the URL answers 502 and Stripe retries (sandbox: a few times over some hours). `import-workflows.ps1 -Restart` has the same window.
- Stripe endpoint `m7-server-invoice` in "New business sandbox" (2 event types). A resend for the server needs `--webhook-endpoint we_...` (without it the CLI answers "No CLI endpoints found" and still exits 0); e2e looks the id up by URL.

**Backups.** `backup-offsite.timer` runs nightly at 03:00 (Persistent): `pg_dump -Fc` piped into `age` (`automation-<UTC>.dump.age`), then n8n's workflows, credentials and data tables (`n8n-<UTC>.tar.age`, M7b-6), both uploaded with a write-only pre-authenticated URL to the bucket `m7-backups`, then a ping to the Healthchecks check `m7-server-backup` (period 1 day, grace 6 h). Any failure, including a failed n8n export after the Postgres upload, means no ping. Keeps 14 days (bucket lifecycle rule). Run one by hand: `bash ~/n8n-workflows/infra/backup-offsite.sh`. Logs: `journalctl -u backup-offsite`.
The private key is only on the laptop (`~/.config/age/m7-backup.key` in WSL) and in Bitwarden (`M7 age backup private key`). Lose both and the backups are unreadable.
The n8n archive needs a SECOND key: its credentials (and, inside `entities.zip`, the workflows and data tables) are encrypted with the server's `N8N_ENCRYPTION_KEY` (Bitwarden `M7 server N8N_ENCRYPTION_KEY`, 64 characters). The export never uses `--decrypted`. The plaintext export exists only in RAM (`/dev/shm` in the n8n container and on the host) for a few seconds; it holds the heartbeat URL and the alert addresses.

**Prove a backup restores.** Download the newest `.age` from the OCI console (Storage > Buckets > `m7-backups` > Objects), keep its name. `powershell -File scripts\check-offsite-restore.ps1 -File <path>` restores into a no-network throwaway on the laptop and compares with the server; it never writes to the server.
For the n8n archive: put the server's key into WSL without showing it (`(umask 077; IFS= read -rs k && printf '%s' "$k" > ~/.config/n8n-drill/server-encryption-key; unset k)`, paste, Enter), then `powershell -File scripts\check-n8n-offsite-restore.ps1 -File <n8n-...tar.age>`. It restores twice into no-network throwaways (`import:entities`, and `import:workflow` + `import:credentials`) and checks workflows, `errorWorkflow`, credential names and decryption, and both data tables. Shred the key file afterwards (`shred -u`).
Restoring n8n for real (new VM, empty `n8n_data`; done only in the drill's throwaways so far, not on a VM): with the same key, `import:entities --inputDir=<writable dir with entities.zip> --truncateTables` (the CLI runs the migrations itself; it unpacks the zip into that directory). Without `--truncateTables` it prints "Not all tables are empty, skipping import" and **exits 0 having imported nothing**; check the workflow list afterwards, never the exit code.

**Rebuild** (last drill about 38 min: `docs/evidence.md`). Never terminate first: "out of host capacity" could leave no VM.
1. Stop the old VM, note the time. Tailscale > Machines: remove the old `m7-server`. Laptop: `ssh-keygen -R m7-server`.
2. Tailscale > Settings > Keys: new key, Reusable off, Ephemeral off, expiry 1 day.
3. Compute > Instances > Create: `m7-server`, Ubuntu 24.04, `VM.Standard.A1.Flex`, 1 OCPU, 4 GB, `m7-vcn` public subnet, public IPv4, paste `oci_m7.pub`. Advanced options > Management: paste `infra/cloud-init.yaml`, replacing `__TAILSCALE_AUTHKEY__` in that box only. "Out of host capacity": try the other availability domains, then later off-peak. No scripts that hammer the API.
4. Instance > Oracle Cloud Agent: Compute Instance Monitoring enabled. Tailscale > Machines > `m7-server`: disable key expiry. Keys: the auth key is used.
5. On the VM: `ssh-keygen -t ed25519 -f ~/.ssh/repo_deploy -N "" -C m7-server-deploy`. GitHub > Settings > Deploy keys: add the `.pub`, write access off. Clone with `git clone -c core.sshCommand="ssh -i ~/.ssh/repo_deploy -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new" git@github.com:mahmoudsamae/n8n-automation-platform.git ~/n8n-workflows`.
6. `cd ~/n8n-workflows && cp infra/env.example .env && chmod 600 .env`, fill it from the Bitwarden items `M7 server POSTGRES_PASSWORD`, `M7 server N8N_ENCRYPTION_KEY`, `M7 OCI backup write URL`, `M7 Healthchecks backup ping URL`, `M7 server n8n_app DB password`, and the tunnel credentials JSON into `secrets/cloudflared.json`. Do not generate new values. No migrations: the restore creates the tables.
7. `bash infra/bootstrap.sh`. Laptop: `powershell -File scripts\server-restore.ps1 -File <newest .age>` (refuses a database that has tables), then the restore check above.
8. Over Tailscale: `bash infra/harden-ssh.sh`. Then the three health checks.
9. Only after green: terminate the old VM, tick **Permanently delete the attached boot volume** (the free limit counts it), remove its deploy key. Update the testing form's IP with Oracle before any further scan.

**Firewall.** Security List: no TCP or UDP ingress, ICMP stays (path-MTU). Host: `/etc/iptables/rules.v4`, no UFW (Oracle: it "might cause an instance not to boot"), never `iptables-restore` (it flushes Docker's and Tailscale's chains), never touch the 169.254 rules. Port 22 is never reopened for a test.
Containers are kept away from the metadata service (`169.254.169.254`, where user-data is readable) by `docker-imds-block.service` (`infra/imds-block.sh`): its own chain `M7-IMDS`, hooked first into `DOCKER-USER`, allows DNS (53) to that address (OCI's resolver) and rejects everything else to `169.254.0.0/16`. The host is not affected. It runs after Docker and again on every Docker restart; `bootstrap.sh` installs it. If `check-imds-blocked.ps1` fails: `sudo systemctl restart docker-imds-block`.

**Oracle's scan rules.** nmap against the public IP only inside the window on the filed Oracle Cloud Security Testing Request Form (`security_test_notification_grp@oracle.com`): from 5 business days after submission, at most 10 consecutive days, once per service per calendar year, non-aggressive, only the form's target and source IPs. `check-public-ports.ps1 -Mode Public` refuses anything else. If the VM or the home IP changes first, tell Oracle before testing.

**The scan, inside the window, in one session.** The owner approves the iptables commands. Nothing in step 1 is saved to `rules.v4`, so a reboot also clears it.
1. Control port, to prove this path can see an open port: Security List > add Ingress TCP 18999 from `<source-ip>/32`. On the VM: `sudo iptables -I INPUT 1 -p tcp -s <source-ip> --dport 18999 -j ACCEPT` and `nc -lk 18999`.
2. Laptop: `tailscale down`, then `powershell -File scripts\check-public-ports.ps1 -Mode Public -Ip <public-ip> -Scope ControlPort -Port 18999 -WindowStart <start> -WindowEnd <end> -SourceIp <source-ip>`. It must report the port OPEN, exit 1.
3. `tailscale up`. Stop `nc`, `sudo iptables -D INPUT -p tcp -s <source-ip> --dport 18999 -j ACCEPT`, delete the Security List rule. `tailscale down`, run step 2 again: no open port, exit 0.
4. Same parameters with `-Scope Full` (all 65535 TCP ports at 100 packets/s, about 11 minutes or more). Exit 0, then `tailscale up`.

**n8n's environment.** Workflows cannot read it (`N8N_BLOCK_ENV_ACCESS_IN_NODE=true`), and nothing secret is passed in: config is in the data tables, the signing secret in a credential (section 7). `N8N_ENCRYPTION_KEY` stays in `.env` (written from Bitwarden), and `bootstrap.sh` copies it to `secrets/n8n_encryption_key` (owner uid 1000, mode 400, gitignored), which compose mounts as a secret (`N8N_ENCRYPTION_KEY_FILE`). So the key is in no process environment and not in `docker inspect`. A changed key file makes `bootstrap.sh` recreate n8n (a running container keeps the old file). A key that does not match the one n8n stored in its volume stops n8n with "Mismatching encryption keys" (provoked in M7b-3).

**Database roles.** `automation` owns every table and is used only for migrations (run by the owner) and the `docker exec` scripts. n8n connects as `n8n_app` (migration 007): no DDL, no DELETE, no TRUNCATE, only the privileges its SQL needs. Its password is in the n8n credential, in `.env` as `N8N_DB_PASSWORD` (read by `check-db-role.ps1`) and in Bitwarden "M7 server n8n_app DB password". A new table needs an explicit `GRANT ... TO n8n_app` in its migration (`lint-migrations.ps1` enforces it). Rotate: `\password n8n_app`, then the credential, `.env` and Bitwarden, then `check-db-role.ps1`.

**Secrets.** Rotating `POSTGRES_PASSWORD` has the same `ALTER USER` trap as section 7 (not rehearsed on the server; there is no `postgres-backup` container here). The upload URL expires after a year: create a new pre-authenticated request, update `.env` and Bitwarden, delete the old one. `BACKUP_HEARTBEAT_URL` (rehearsed 2026-11-08): store a hash of the old value in a mode-600 file on the server; rename the old check, create the new one with the same period and grace; update Bitwarden "M7 Healthchecks backup ping URL" and `.env` by hand; check that the hash differs (yes/no only); run `bash ~/n8n-workflows/infra/backup-offsite.sh` once; confirm the new check got the ping; only then delete the old check. A new Tailscale key is needed only for a new VM; it is one-off because user-data stays readable through the metadata service.
