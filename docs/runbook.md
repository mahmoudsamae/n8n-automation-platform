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

It checks containers (including `gotenberg`), migrations 005 and 006, the `errorWorkflow` settings of all 7 workflows, that each `.sdk.ts` file matches its live workflow (`scripts\check-sdk-drift.ps1`; the first run installs the pinned SDK with `npm ci`), that CLAUDE.md is within its line limit and no README or docs link is broken (`scripts\check-docs.ps1`), a fresh Postgres dump, that the backup container can log in over TCP and is not failing, the env vars
(`TELEGRAM_SEND_PDF` must be exactly `true` or `false`), then pushes one real demo payment (`scripts\demo-payment.ps1`) through the whole pipeline: invoice row, exactly 1 email with exactly 1 real PDF, the Telegram document, a resend, a Processor re-run, and ends with a stale-timestamp check.
It creates one `e2e=true` event and deletes no real data (its only deletes are its own two `evt_test_e2e_stale_*` rows). For a read-only look: `scripts\check-error-workflows.ps1`.

## 3. What each alert means

| Alert | Meaning | What to do |
|---|---|---|
| `DEAD` | Event is `failed` with 5 attempts. The Processor will never retry it. | Read `last_error`. Fix the cause (Mailpit/Telegram down, bad payload). Then replay (section 5). |
| `STALE PENDING` | `pending` for 10+ min. The Processor is not picking events up. | Is the Processor workflow published and active? Check its executions in n8n. Check `docker ps`. |
| `STUCK FAILED` | `failed`, attempts < 5, retry overdue 10+ min. Same cause as above. | Same as stale pending. |
| `STUCK PROCESSING` | `processing` for 20+ min. A run died mid-event. | The Processor releases rows at 10 min by itself; if it did not, the Processor is not running. |
| `DEAD` with `last_error` `Render PDF (Gotenberg): ...` | The PDF could not be produced for 5 attempts (the owner got ONE text saying "PDF fehlt"). | Section 10: is `gotenberg` running? Then replay (section 5): only the missing email and document are sent. |
| `DEAD` with `last_error` `TELEGRAM_SEND_PDF must be set to true or false ...` | The variable is missing or wrong in the n8n container. | Section 10: set it in `~/n8n/.env` and in the compose `environment:` of n8n, `docker compose up -d --no-deps n8n`, replay. |
| `DEAD` with `last_error` `... No such checkout.session ...` or another Stripe message | The one Stripe lookup for the invoice failed (a 4xx is not retried). | Check the `Stripe read-only` credential and the session id in the payload; nothing was sent and no invoice exists. |
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

Needed if the `n8n_data` volume is lost. The seven workflows are in the repo: `stripe-intake.sdk.ts`, `stripe-processor.sdk.ts`, `stripe-error-handler.sdk.ts`, `stripe-monitor.sdk.ts`,
`stripe-send-alert.sdk.ts`, `stripe-render-invoice.sdk.ts`, `stripe-send-telegram.sdk.ts`.

1. Start the stack, create the n8n owner account.
2. Re-create four credentials by hand (they are never exported): `Postgres automation` (host `postgres`, DB and user `automation`),
   `Mailpit SMTP` (host `mailpit`, port 1025, no auth), `Telegram alerts` (bot token), `Stripe read-only` (type Stripe API, a restricted test-mode key with read access to Checkout Sessions, PaymentIntents and Charges, restricted to `api.stripe.com`).
3. Create the workflows from the files (n8n MCP `create_workflow_from_code`) in this order: Send Alert, Error Handler, **Render Invoice, Send Telegram**, then Monitor, Intake and the Processor last.
4. **New workflow ids.** The Monitor calls Send Alert by id, the Processor calls Render Invoice and Send Telegram by id, and `errorWorkflow` points at the Error Handler by id. Update: the ids in
   `stripe-monitor.sdk.ts` (Send Alert) and `stripe-processor.sdk.ts` (Render Invoice, Send Telegram), the ids in `scripts\check-error-workflows.ps1`, `scripts\hooks\n8n-drift-reminder.mjs`, and the table in `CLAUDE.md`.
5. Set `settings.errorWorkflow` (= Error Handler id) on Intake, Processor and Monitor with `update_workflow`; the `.sdk.ts` files cannot carry it.
   Leave it empty on the Error Handler, Send Alert, Render Invoice and Send Telegram (the first so a failing alert can never trigger another alert, the other two because they return their problems to the Processor).
6. Publish all seven, then `scripts\check-sdk-drift.ps1`, `scripts\check-error-workflows.ps1` and `scripts\e2e.ps1` must pass.

## 9. Known limits

- A green heartbeat does not prove Postgres or the Processor work.
- Backups are on the same disk as the database, and n8n's own data is not backed up yet.
- An undeliverable crash alert still uses up its 15 min throttle window.
- Both alert channels failing at once, and real Telegram 429/5xx backoff, were never provoked. The same holds for a failing `sendDocument` call; the retry loop itself was proven in the engine with a stub.
- The Telegram sends have no timeout: n8n's Telegram node has no timeout option (checked in the n8n 2.45.6 container). A hung call holds one Processor run until the 10 min stuck-row release, and the `stuck processing` alert fires after 20 min; no event is lost. The fix is to replace `Send Message` and `Send Document` in `Stripe Send Telegram` with HTTP Request nodes that set `options.timeout` (30 s), then re-prove the retry loop, one live payment and e2e. Not built.
- If the PDF cannot be produced AND the owner text send also fails, `last_error` names the Telegram failure and the PDF problem resurfaces on the next run.
- Stripe is test mode only. See `docs/live-mode-checklist.md`.

## 10. Invoices: Gotenberg, the PDF and Telegram

**Flow.** Per paid event the Processor looks up the product and the payment method once from Stripe (only when no invoice exists yet) and stores them on the invoice row. `Stripe Render Invoice` then builds the German email (HTML + text), the Telegram text and the PDF
from that row alone, so a retry or a replay produces the same document and never calls Stripe again. The email carries exactly one PDF. The Telegram owner text and, if enabled, the PDF as a document go through `Stripe Send Telegram`.

**Gotenberg** (`gotenberg/gotenberg:8.39.0-chromium`, internal only, no published port): `docker compose ps gotenberg`; restart with `docker compose up -d gotenberg`. It is capped at 512 MB (memory and swap). Chromium stays resident, so it idles at about 360-410 MB.
If it is down the Processor keeps retrying every minute: no email is sent, the owner gets ONE text saying "PDF fehlt", and `last_error` says `Render PDF (Gotenberg): ...`. When it is back the next run sends the email and the document, and not a second text.

**Sending the PDF to Telegram is a data-protection decision.** The invoice PDF contains the customer's name and email address (and what they bought). Sending it to Telegram passes that personal data to a third party, a messaging provider whose servers are outside this deployment.
Under the GDPR a real deployment must decide this on purpose: it needs a legal basis, a processor agreement or other transfer safeguard where required, a retention and deletion answer (the messages stay in the chat), and a mention in the privacy notice. Until then run with `TELEGRAM_SEND_PDF=false`:
the owner text still goes out (it also names the customer) and the PDF stays on the email only. In this portfolio project everything is sandbox data and the value is `true` for the demo. This is documentation for a hypothetical client, not legal advice.

**`TELEGRAM_SEND_PDF`.** Exactly `true` or `false`, no default: unset or anything else fails every event with `TELEGRAM_SEND_PDF must be set to true or false in the n8n environment`. Two lines have to agree:
`~/n8n/.env` gets `TELEGRAM_SEND_PDF=true` (or `false`), and the `n8n` service in `~/n8n/docker-compose.yml` lists `      - TELEGRAM_SEND_PDF=${TELEGRAM_SEND_PDF}` under `environment:`. Apply with `docker compose up -d --no-deps n8n` (this drops the n8n MCP for a moment).
With `false` no document is sent and `telegram_document` is not required for `done`. To try the other value once without touching `.env`: `TELEGRAM_SEND_PDF=false docker compose up -d --no-deps n8n`, then a plain `docker compose up -d --no-deps n8n` to go back.

**Rotate the `Stripe read-only` key.** In the Stripe Dashboard (test mode) create a replacement restricted key with the same three read permissions, put it into the n8n credential `Stripe read-only`, run `scripts\demo-payment.ps1` with a listener (or `scripts\e2e.ps1`) and check that the event ends `done`, then delete the old key. The key is not in `.env` and never in git.

## 11. Server

The M7 server: OCI Always Free, `VM.Standard.A1.Flex`, 1 OCPU, 4 GB, Ubuntu 24.04, region `eu-frankfurt-1`. No public traffic and no workflows yet (M7b). Design: `docs/tasks/m7-server.md`. The server has its own secrets; nothing from the laptop's `.env`. Never click Upgrade or Pay As You Go in OCI.

**Access, only over Tailscale.** `ssh -i "$HOME\.ssh\oci_m7" ubuntu@m7-server`. Nothing publishes a port, so admin UIs go through an SSH tunnel to fixed container IPs:
`ssh -i "$HOME\.ssh\oci_m7" -L 5678:172.30.0.10:5678 -L 8025:172.30.0.11:8025 ubuntu@m7-server`, then http://localhost:5678 (n8n) and http://localhost:8025 (Mailpit). From scripts: `scripts\server-sh.ps1 -Script '...'` (base64, so no quoting problems).

**Is it healthy?**
```powershell
powershell -File scripts\check-server-base.ps1                              # VM matches cloud-init, 4 GB, port 22 only on tailscale0, password login off
powershell -File scripts\check-prod-stack.ps1                               # stack up, no published ports, nothing on public addresses, memory
powershell -File scripts\check-public-ports.ps1 -Mode Tailnet -Ip <public-ip>   # Tailscale SSH works, public SSH does not answer (no nmap)
powershell -File scripts\check-imds-blocked.ps1                             # containers cannot reach the metadata service; DNS, HTTPS and the host still work
```

**Backups.** `backup-offsite.timer` runs nightly at 03:00 (Persistent): `pg_dump -Fc` piped into `age`, uploaded with a write-only pre-authenticated URL to the bucket `m7-backups`, then a ping to the Healthchecks check `m7-server-backup` (period 1 day, grace 6 h). Any failure means no ping. Keeps 14 days (bucket lifecycle rule). Postgres only: `n8n_data` is not backed up yet (M7b). Run one by hand: `bash ~/n8n-workflows/infra/backup-offsite.sh`. Logs: `journalctl -u backup-offsite`.
The private key is only on the laptop (`~/.config/age/m7-backup.key` in WSL) and in Bitwarden (`M7 age backup private key`). Lose both and the backups are unreadable.

**Prove a backup restores.** Download the newest `.age` from the OCI console (Storage > Buckets > `m7-backups` > Objects), keep its name. `powershell -File scripts\check-offsite-restore.ps1 -File <path>` restores into a no-network throwaway on the laptop and compares with the server; it never writes to the server.

**Rebuild** (last drill about 38 min: `docs/evidence.md`). Never terminate first: "out of host capacity" could leave no VM.
1. Stop the old VM, note the time. Tailscale > Machines: remove the old `m7-server`. Laptop: `ssh-keygen -R m7-server`.
2. Tailscale > Settings > Keys: new key, Reusable off, Ephemeral off, expiry 1 day.
3. Compute > Instances > Create: `m7-server`, Ubuntu 24.04, `VM.Standard.A1.Flex`, 1 OCPU, 4 GB, `m7-vcn` public subnet, public IPv4, paste `oci_m7.pub`. Advanced options > Management: paste `infra/cloud-init.yaml`, replacing `__TAILSCALE_AUTHKEY__` in that box only. "Out of host capacity": try the other availability domains, then later off-peak. No scripts that hammer the API.
4. Instance > Oracle Cloud Agent: Compute Instance Monitoring enabled. Tailscale > Machines > `m7-server`: disable key expiry. Keys: the auth key is used.
5. On the VM: `ssh-keygen -t ed25519 -f ~/.ssh/repo_deploy -N "" -C m7-server-deploy`. GitHub > Settings > Deploy keys: add the `.pub`, write access off. Clone with `git clone -c core.sshCommand="ssh -i ~/.ssh/repo_deploy -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new" git@github.com:mahmoudsamae/n8n-automation-platform.git ~/n8n-workflows`.
6. `cd ~/n8n-workflows && cp infra/env.example .env && chmod 600 .env`, fill it from the Bitwarden items `M7 server POSTGRES_PASSWORD`, `M7 server N8N_ENCRYPTION_KEY`, `M7 OCI backup write URL`, `M7 Healthchecks backup ping URL`. Do not generate new values. No migrations: the restore creates the tables.
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

**Secrets.** Rotating `POSTGRES_PASSWORD` has the same `ALTER USER` trap as section 7 (not rehearsed on the server; there is no `postgres-backup` container here). The upload URL expires after a year: create a new pre-authenticated request, update `.env` and Bitwarden, delete the old one. `BACKUP_HEARTBEAT_URL` (rehearsed 2026-11-08): store a hash of the old value in a mode-600 file on the server; rename the old check, create the new one with the same period and grace; update Bitwarden "M7 Healthchecks backup ping URL" and `.env` by hand; check that the hash differs (yes/no only); run `bash ~/n8n-workflows/infra/backup-offsite.sh` once; confirm the new check got the ping; only then delete the old check. A new Tailscale key is needed only for a new VM; it is one-off because user-data stays readable through the metadata service.
