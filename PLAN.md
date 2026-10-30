# Plan

Pipeline: Stripe -> Intake -> `stripe_events` -> Processor -> Mailpit + Telegram.

| # | Milestone | Status |
|---|-----------|--------|
| M1 | Infra and storage: docker compose (n8n, postgres, mailpit), `stripe_events` table, `Postgres automation` credential | DONE |
| M2 | Stripe Intake workflow: signature check, classify, idempotent insert, 200/400/500 contract. Proven with stripe CLI, including DB-down 500 | DONE |
| M3 | Stripe Processor workflow (below) | DONE. `scripts/e2e.ps1` guards it. Known gap: real Telegram 429/5xx never provoked, backoff is unproven (needed for M6 failure table) |
| M4 | Failure visibility (below): error workflow, alert when an event ends `failed`, safe way to replay a failed event | DONE, merged (PR #1). Proofs run (see the M4 section); `scripts/e2e.ps1` 35/35. Known gaps (carry into the M6 failure table): see "Known gaps" in the M4 section |
| M5 | Hardening: secret rotation procedure, Postgres backup, live-mode checklist, runbook, external dead man's switch (Monitor pings an outside heartbeat service; silence triggers the alert, covering n8n/WSL down), e2e check that each workflow's `errorWorkflow` setting is correct (it lives only in n8n, not in the `.sdk.ts` files, so a workflow recreated from its file would silently lose alerting): Intake, Processor and Monitor must point at the Error Handler id, and the Error Handler and Send Alert must have none; replace the placeholder alert addresses (`ops@example.test` recipient, `stripe-alerts@example.test` sender in `Stripe Send Alert`) with real ones | DONE on branch `m5-hardening` (pushed, not merged). All proofs recorded, `scripts/e2e.ps1` 40/40; proof 1b down 10:28:28 / up 10:33:28 Berlin time, proof 6 Postgres rotation (see "Results" in the M5 section). Known gaps listed there carry into M6 |
| M6 | Portfolio packaging: README with architecture diagram, failure scenarios with proof, 2-minute demo script | TODO |

## M3: Stripe Processor

A separate workflow, `Stripe Processor`, saved as `stripe-processor.sdk.ts`. It does all slow work so Intake stays fast.
For each stored `pending` event it sends one Mailpit email and one Telegram message, then marks the event `done`.

### Acceptance criteria
1. **Trigger:** Schedule trigger, every 1 minute. No webhook, no calls into Intake.
2. **Atomic claim:** one SQL statement selects `pending` rows (oldest first, batch of at most 10) with
   `FOR UPDATE SKIP LOCKED` and sets `status='processing'`, `attempts=attempts+1`. Two overlapping runs never process the same event.
3. **Only eligible rows:** `ignored` and `done` rows are never selected. `failed` rows are retried only while `attempts < 5`.
4. **Idempotent side effects:** after any retry or replay, each event has exactly one email and one Telegram message.
   Uses table `side_effects(event_id, kind, done_at)` with `PRIMARY KEY (event_id, kind)`, kind is `email` or `telegram`
   (SQL in `migrations/002_side_effects.sql`, run by the user, not by Claude). Per kind: skip if a row exists, otherwise send,
   then `INSERT ... ON CONFLICT DO NOTHING`. If the run dies between send and insert, a retry can send that one message twice
   (at-least-once). Document this limit in the workflow's sticky note. The workflow must not start before the user confirms the migration ran.
5. **Email:** sent via the Mailpit SMTP credential. Subject and body contain `event_id` and the amount/currency from `payload`.
   Payload fields are read defensively (missing fields do not crash the run).
6. **Telegram:** one message per event via a Telegram credential. 429 and 5xx responses are retried with exponential backoff
   (at least 3 tries) before the event is marked failed.
7. **Success:** row ends `status='done'`, `processed_at` set, `last_error` NULL.
8. **Failure:** row ends `status='failed'`, `last_error` holds a short message with no secrets, `attempts` reflects the tries.
   One failing event must not stop the rest of the batch.
9. **Stuck rows:** a row left in `processing` for more than 10 minutes is returned to `pending`.
10. **LLM output:** if any LLM step is added, its output is validated against a schema before use. Not required for M3.
11. **No secrets in logs or messages;** Telegram and email bodies never include the signing secret or full payload.
12. **Source of truth:** `stripe-processor.sdk.ts` matches the live published workflow (diff shown), and CLAUDE.md lists its id.

### Proof required (commands and output shown)
- `stripe trigger checkout.session.completed`: within 2 minutes the `pending` row becomes `done`, Mailpit shows 1 email, Telegram shows 1 message.
- `stripe events resend <id>` on a `done` event: still 1 email, 1 message, 1 row.
- Stop mailpit, trigger an event: row goes `failed` with `last_error` set; start mailpit and re-queue it: it ends `done` with exactly 1 email.
- Two Processor runs started together on 3 pending rows: 3 emails, not 6.
- The 6 `ignored` events from the stripe trigger are untouched.

## M4: Failure visibility

Three parts: an n8n error workflow for crashed executions, a `Stripe Monitor` workflow that alerts on dead or stuck events,
and a replay script that safely sends a failed event back to the Processor.

### Acceptance criteria
1. **Error workflow:** new workflow `Stripe Error Handler` (`stripe-error-handler.sdk.ts`) with an Error Trigger, set as the
   `errorWorkflow` of Intake and Processor. Each alert names the workflow, node, execution id and a short error message.
2. **Alert throttle:** at most one error alert per (workflow, node) per 15 minutes; the next alert says "N similar errors suppressed".
   State lives in workflow static data, not Postgres, so it works when the DB is the thing that is down.
3. **Dead-event alert:** `Stripe Monitor` (`stripe-monitor.sdk.ts`), schedule every 5 minutes, alerts once per event with
   `status='failed' AND attempts >= 5` (the Processor will not retry it). Failures still being retried do not alert.
4. **Stale-pending alert:** the Monitor alerts when any `pending` row has `pending_since` older than 10 minutes (Processor not running).
   It lives in the Monitor, not the Processor, because a dead Processor cannot report itself.
5. **No false stale alerts:** staleness is measured from `pending_since` (when the row last became `pending`), never `received_at`.
   New column `stripe_events.pending_since` (migration 005, default `now()`). The Processor's stuck-row release and `replay.ps1`
   both set `pending_since = now()`, so a row just released or replayed is not stale even if it was received long ago.
6. **Alert idempotency:** new column `stripe_events.alerted_at` (migration 005) is set after the dead-event alert is sent; rows with
   `alerted_at` set are skipped. A crash between send and update can duplicate one alert (at-least-once, as in M3). Sticky note documents it.
7. **Channels:** every alert goes to Telegram and to a Mailpit email, so one channel being down does not hide it.
   Telegram uses the M3 retry rules (429/5xx/network only, 3 tries, backoff).
8. **Alert content:** `event_id`, `event_type`, `attempts`, `last_error` (cut to 200 chars) and a ready-to-run replay command.
   Never the payload, customer email, secrets or tokens.
9. **Replay script:** `scripts/replay.ps1 -EventId <id> -Reason "<text>" [-DryRun]`.
   - Rejects ids not matching `^evt_[A-Za-z0-9_]+$`; passes the id to psql as a `-v` variable, never by string-building SQL.
   - Only a `failed` event is replayed. `done`, `ignored`, `pending`, `processing` are refused with a clear message.
   - One transaction: `status='pending'`, `attempts=0`, `alerted_at=NULL`, `pending_since=now()`, and one row in
     `event_replays(replay_id, event_id, reason, replayed_at)` (migration 005, FK `ON DELETE RESTRICT`).
   - Never deletes `side_effects` or `invoices`; they are what make a replay safe from double sends and double invoices.
   - Prints the row before and after. `-DryRun` changes nothing.
10. **Migration gate:** `migrations/005_m4_alerting.sql` is reviewed and run by the user. The Monitor is not published, the Processor
    is not changed and the replay script is not used until the user confirms it ran.
11. **Source of truth:** every new or changed workflow is exported to its `.sdk.ts` and diffed. CLAUDE.md lists the new workflow ids,
    the new columns/table and the replay command. `scripts/e2e.ps1` also checks that replay refuses a `done` event.
12. **Stuck-failed alert:** the Monitor also alerts on a `failed` event with `attempts < 5` whose `COALESCE(claimed_at, pending_since)`
    is older than 10 minutes. The Processor retries such rows every minute, so an old `claimed_at` means it is not running.
    Without this rule a failed-but-retryable event is neither pending nor dead and nothing would ever report it.
13. **Alert re-arming:** the Processor's claim sets `alerted_at = NULL`, so an event that was alerted as stale or stuck and then
    picked up again can alert again in a later episode. Dead events are never claimed again, so their alert stays once-only until a replay.
14. **Shared alert sender:** Telegram + email delivery lives in one sub-workflow, `Stripe Send Alert` (`stripe-send-alert.sdk.ts`),
    called by both the Error Handler and the Monitor. One channel failing is absorbed; both failing makes the sub-workflow fail, so
    the Monitor does not set `alerted_at` and retries on its next run. The Monitor also gets the Error Handler as its `errorWorkflow`.
15. **Stuck-processing alert:** the Monitor also alerts on `status='processing'` with `claimed_at` older than 20 minutes, twice the
    Processor's own 10-minute release threshold, so a healthy Processor always releases the row first and the Monitor never races it.

### Proof required (commands and output shown)
- Stop postgres for 3 minutes: the Processor fails each run, the Error Handler sends exactly 1 alert (Telegram + email);
  after restart the next alert shows the suppressed count.
- Stop mailpit until an event reaches `attempts=5`: exactly 1 dead-event alert; later Monitor runs send none.
- Start mailpit, run `replay.ps1`: the event ends `done` with exactly 1 email, 1 invoice and 1 `event_replays` row.
- `replay.ps1` on a `done` and on an `ignored` event: both refused, rows unchanged.
- `replay.ps1 -EventId "x'; drop table--"`: rejected before psql is called.
- Stuck-row release: insert `evt_test_stuck` as `processing` with `claimed_at` 15 min ago and `received_at` 30 min ago; after the next
  Processor run, its `pending_since` equals the release time (not `received_at`).
- No false stale alert: Processor unpublished (operational action, not a workflow edit), insert `evt_test_released` as `pending` with
  `received_at` 30 min ago and `pending_since = now()` (the state right after a release). Run the Monitor: no stale alert.
  After 11 minutes: exactly 1 stale alert. Republish the Processor.
- Stuck-failed alert: with the Processor unpublished, insert `evt_test_stuckfail` as `failed`, `attempts=2`, `claimed_at` 15 min ago.
  Monitor run: exactly 1 alert naming it as stuck-failed. A second Monitor run: none (`alerted_at` set). Control: the same row with
  `claimed_at = now()` gives no alert. Republish the Processor: it claims the row and `alerted_at` is cleared again.
- Channel independence: with Mailpit stopped, a dead-event alert still reaches Telegram, the sub-workflow succeeds and `alerted_at` is set.
  The "both channels fail, so `alerted_at` stays NULL" path is not provoked (it needs a broken Telegram token); it is stated as unproven.
- Stuck-processing alert: with the Processor unpublished, `evt_test_stuckproc` (`processing`, `claimed_at` 25 min ago) gets exactly 1 alert;
  the control `evt_test_stuckproc_ctl` (`claimed_at` 12 min ago) gets none. Republish the Processor: both rows end `done`, `alerted_at` cleared.
- `scripts/e2e.ps1` passes, summary shown.

### Known gaps (carry into the M6 failure table)
- **Undeliverable alert burns the throttle window:** the Error Handler records the 15-minute window before sending. If both channels fail,
  that alert is lost and repeats of the same (workflow, node) stay suppressed until the window ends. The Monitor does not have this gap
  (it sets `alerted_at` only after delivery and retries on the next run).
- **Both channels failing at once is unproven:** it needs a broken Telegram token while Mailpit is down; only each single-channel failure was provoked.
- **Monitoring is inside n8n:** nothing alerts if n8n or WSL is down (M5 dead man's switch).

### Out of scope
- Real Telegram 429/5xx backoff proof (M3 gap, needed for M6).
- Bulk replay and any replay UI.
- Monitoring of the platform itself: all alerting lives inside n8n, so if n8n or WSL is down nothing alerts.
  Covered by the M5 external dead man's switch.

## M5: Hardening

Stripe stays in sandbox forever; the live-mode checklist is documentation for a hypothetical client deployment. No schema change, no migration.
Split if time runs out: criteria 1-6 first, 7-9 as M5b. Build order: 3, 4 (code only until the user confirms the `.env` lines), 5, 6, then 1-2, 7-9.

### Findings that shaped the design
- A ping at the end of the Monitor chain never fires on a quiet run (the chain stops at `Find Alertable Events` with 0 rows), so the ping is a second branch off the trigger.
- The stack is not always on (PC off at night), so a fixed-time backup job would be missed and every shutdown looks like an outage to a heartbeat service.
- `n8n export:workflow` returns `settings.errorWorkflow` without an API key. n8n uses SQLite in the `n8n_data` volume, so a Postgres backup does not cover workflows or credentials.
- A third placeholder address exists: `stripe-processor@example.test` in `stripe-processor.sdk.ts`.

### Who does what
- **User:** Healthchecks.io free account; check `stripe-pipeline` (period 5 min, grace 10 min, email integration on); three `.env` lines in WSL
  (`HEARTBEAT_URL`, `ALERT_EMAIL_TO`, `ALERT_EMAIL_FROM`); the Postgres password rotation rehearsal; reporting the down/up email times; Pause the check before shutting the PC down.
- **Claude:** workflow and compose changes, scripts, e2e checks, docs, exports and diffs, CLAUDE.md / PLAN.md updates.

### Acceptance criteria
1. **Dead man's switch:** `Stripe Monitor` gets an HTTP node `Heartbeat Ping` on a second branch from the schedule trigger, GET `$env.HEARTBEAT_URL`, 10 s timeout,
   3 tries 5 s apart, then the error is absorbed (`continueRegularOutput`) so a ping failure never crashes the Monitor. Deliberate exception to exponential backoff:
   n8n's retry wait is fixed, the ping is harmless to repeat, and the 10 min grace tolerates misses. About 15 min of silence makes Healthchecks.io email the user.
   A green heartbeat proves n8n's scheduler and network only, not Postgres or the Processor. A shutdown without Pause costs one down email and one up email.
2. **Ping URL handling:** the UUID is the only credential. It lives only in `~/n8n/.env`; compose and the `.sdk.ts` hold only a reference. Never in git, alerts or chat. No fallback URL.
3. **`errorWorkflow` guard:** `scripts/check-error-workflows.ps1`, called from e2e, reads the 5 workflows via `n8n export:workflow`. Intake, Processor, Monitor must equal the Error Handler id;
   Error Handler and Send Alert must have none. Missing setting, wrong id or no JSON = FAIL. Prints names and ids only. A parameter overrides the expected id to prove the failure path.
4. **Alert addresses:** `Stripe Send Alert` reads `$env.ALERT_EMAIL_TO` / `$env.ALERT_EMAIL_FROM` (keeps personal addresses out of git; a client deployment changes config only).
   e2e fails if either variable or `HEARTBEAT_URL` is empty in the n8n container (presence only, never values). The Processor sender stays and goes on the live-mode checklist.
5. **Postgres backup:** compose service `postgres-backup` (`postgres:17-alpine`) runs `pg_dump -Fc` at start and every 24 h into `~/n8n/backups/`, via temp file + rename.
   Keeps 14 days; pruning runs only after a successful dump and only matches its own filename pattern (approved by the user). Backups stay out of the repo (customer emails).
   e2e fails if the newest dump is empty or older than 25 h.
6. **Restore proven:** `scripts/restore-check.ps1` restores the newest dump into a throwaway container with no network, compares row counts of `stripe_events`, `side_effects`,
   `invoices`, `event_replays` and `invoice_number_seq` against live, then removes the container. Run while no events are flowing.
7. **Secret rotation:** runbook steps for `STRIPE_WEBHOOK_SECRET`, `POSTGRES_PASSWORD`, the Telegram bot token and `HEARTBEAT_URL`, with the traps: `POSTGRES_PASSWORD` in `.env` only applies on first
   volume creation (needs `ALTER USER`), and the database, the n8n credential and the backup container must change together. Only the Postgres rotation is rehearsed (by the user).
8. **Runbook and live-mode checklist:** `docs/runbook.md` (start/stop and Pause, each alert kind, heartbeat-down triage, replay, backup/restore, rotation, rebuilding n8n from `.sdk.ts`)
   and `docs/live-mode-checklist.md` ("hypothetical client deployment, never executed"; each item has a how-to-verify line).
9. **Source of truth:** `stripe-monitor.sdk.ts` and `stripe-send-alert.sdk.ts` exported and diffed; Monitor sticky note updated; compose synced with `C:\dev\claude-config\sync.ps1`;
   CLAUDE.md gets the new env var names and scripts, and "test mode only until M5" becomes "sandbox permanently"; this M5 row marked done.

### Proof required (commands and output shown)
1. Heartbeat: (a) 2 Monitor runs show `OK`, check green; (b) `wsl --shutdown`, user reports the down email time (~15 min) and the up email after restart;
   (c) `docker stop postgres` 6 min: pings continue, one throttled Error Handler alert; (d) unresolvable `HEARTBEAT_URL`: Monitor run still `success`, no Error Handler alert, then restore it.
2. Guard passes on live; with a wrong expected id it prints FAIL.
3. A dead `evt_test_` row produces a Mailpit alert using the env-var From/To; no `example.test` left in `stripe-send-alert.sdk.ts`; test row deleted.
4. Backup: dump appears at container start; a failed dump (postgres stopped) leaves no new file.
5. `restore-check.ps1` output shows matching counts.
6. After the user's rotation: a real `stripe trigger` event ends `done`, a new dump succeeds, the old password is rejected.
7. Repo grep for `hc-ping.com/<uuid>` and `whsec_` finds nothing.
8. `scripts/e2e.ps1` summary shown, with the new checks.

### Results (2026-10-30)
- **Proof 1a** done: Monitor executions 385 and 391 both show `Heartbeat Ping` -> `{"data":"OK"}`; `Heartbeat Ping` has executionIndex 1, before `Find Alertable Events` (2), because n8n orders branches by canvas position. **Confirmed by the user** from Healthchecks.io's own event log (Europe/Berlin time = UTC+1): pings at 09:38, 09:43, 09:53, 09:58 and 10:03, i.e. the 08:38 and 08:43 UTC runs above, and again after the restart. Claude cannot see that side; this is the user's report.
- **Proof 1b** done (user report, Europe/Berlin time, UTC+1). Last ping about 10:13; Healthchecks.io changed the check to **down at 10:28:28** (= last ping + period 5 + grace 10 min) and sent the down email. The laptop then rebooted on its own (not planned), the stack was back at about 10:31 and all four containers were already running before `docker compose up -d` was typed (restart policies work). Healthchecks.io changed the check back to **up at 10:33:28** (user report; this is the status-change time, the up email follows it). n8n's side agrees: the Monitor's last run before the outage was 10:13:26 and the next one 10:33:26 (executions 456 and 462; none in between), so recovery took 2 s from the first ping. Caveat: the outage ended in an unplanned reboot, so this exercised "no pings for 15 min" (the case that matters), not the `wsl --shutdown` command by itself.
- **Proof 1c** done: Postgres stopped 08:52:30-08:58:51 UTC. Both Monitor runs (414, 427) ended `error` with the heartbeat OK. The Error Handler ran 9 times (7 Processor, 2 Monitor) and sent 2 emails: one per (workflow, node), not one in total as the criterion text said. **Confirmed from outside by the user:** Healthchecks.io logged the 09:53 and 09:58 (Berlin) pings, which arrived while Postgres was down.
- **Proof 1d** done: `HEARTBEAT_URL` overridden from the shell (`.env` untouched) with an unresolvable host. Monitor execution 406 ended `success`, the DNS error is in its data, no Error Handler execution and no crash email. Real URL restored and verified. **Confirmed from outside by the user:** the 09:48 (Berlin) ping is missing from the Healthchecks.io event log, matching this test (the 3 tries failed on DNS and the error was absorbed).
- **Proof 2** done: guard passes on live (5/5) and prints FAIL for the three protected workflows with a wrong id (exit 1).
- **Proof 3** done: seeded dead `evt_test_alert_addr`; the alert arrived 12 s later with From/To from the env vars, none `example.test`. `stripe-send-alert.sdk.ts` has no `example.test` left. The Processor's `stripe-processor@example.test` remains (live-mode checklist item). Test row deleted in FK order.
- **Proof 4** done: first dump at container start; with Postgres stopped, `backup FAILED` and no new file; the 5-minute retry was then observed (failed ~08:31:11, new dump 08:36:11, no manual action).
- **Proof 5** done: `restore-check.ps1 -Fresh` restored into a throwaway container with no network, all five counts match live. The mismatch path was also proven: a row seeded after the dump gave `[FAIL] stripe_events live=94 restored=93`, exit 1 (row deleted after).
- **Proof 6** done (rotation performed by the user, verification by Claude, no secret printed). User procedure: fresh backup, new password into a temp file, `ALTER USER` via a psql variable, `.env` updated with `sed`, n8n credential updated via `clip.exe` and tested, `postgres-backup` recreated (this also recreated `postgres`), temp file shredded. Window: 3 failed executions (Processor 09:43:37 and 09:44:37, Monitor 09:43:26 UTC), every Processor run from 09:46 succeeded. Verified: `.env`, the `postgres` container and the `postgres-backup` container hold the same value; the new password is accepted over TCP from another container and a wrong one gets `password authentication failed`; `scripts/e2e.ps1` 40/40 with a real `stripe trigger` event ending `done` through the new n8n credential; `restore-check.ps1 -Fresh` dumped over TCP with the new password and restored with matching counts (114/46/23/1, sequence 23). The first automatic dump after the recreate failed ("database system is starting up") and the 5-minute retry design covers it. **Not proven:** the OLD password cannot be tested (it no longer exists); its rejection rests on `ALTER USER` semantics.
- **Correction found while verifying proof 6:** the runbook's TCP check (`docker exec postgres ... psql -h 127.0.0.1`) could never fail, because pg_hba trusts loopback inside the postgres container (a wrong password was accepted there). Runbook section 7 now tests from another container. Runbook section 7 also gained the two-login-role pattern as the recommendation for a real client (not built).
- **Proof 7** done: no ping URL, `whsec_` or bot token in either repo's files or in git history. The old ping URL was printed once into the Claude session by a shell-quoting mistake, so it was rotated following runbook section 7: new check created, `.env` updated, n8n recreated (`HEARTBEAT_URL` verified set without printing it), **the user confirmed the new check is green and the old one is deleted**. This also exercised the `HEARTBEAT_URL` rotation steps once; the Telegram token and `STRIPE_WEBHOOK_SECRET` steps remain unrehearsed.
- **Proof 8** done: `scripts/e2e.ps1` 40/40.
- Side finding fixed: `seed-test-event.ps1` failed without `-ClaimedMinutesAgo` (`''::int` is evaluated while planning); now NULL-safe.

### Known gaps after M5 (carry into the M6 failure table)
- A green heartbeat does not prove Postgres or the Processor work.
- Backups sit on the same disk as the database: protects against bad data and a lost volume, not a lost machine.
- `n8n_data` is not backed up until the M6 export (item 8); credentials are never exported.
- A forgotten Pause means one false down email.
- Both alert channels failing at once (M4) and real Telegram 429/5xx backoff (M3) stay unproven.

### Out of scope
Off-site backups, automating Healthchecks.io through its API, the Mailpit volume (M6.7), real Stripe live mode.

## M6: Portfolio packaging

Starts after M3 (M4 and M5 can finish first). Only claims backed by evidence from real runs go in.

### Acceptance criteria
1. **README.md:** one-paragraph pitch, architecture diagram (Stripe -> Intake -> `stripe_events` -> Processor -> Mailpit + Telegram,
   with the 200/400/500 branches), setup steps that work from a clean clone, and the tech list.
2. **Failure scenarios table:** one row per scenario with expected behavior and a link or pasted command output as proof. Minimum:
   fake signature (400), stale timestamp (400), duplicate event (200 duplicate, 1 row), database down (500, then resend stores 1 row),
   Mailpit down (event `failed`, later `done` with 1 email), Telegram 429/5xx (backoff then success), two Processor runs at once (no double send),
   `ignored` events untouched, Postgres down (one throttled crash alert), dead event (one alert, replay ends `done` with 1 email),
   stuck rows (alerts for stale pending, stuck failed, stuck processing). Also list the M4 known gaps.
3. **DEMO.md:** a 2-minute video script with timestamps, the exact commands to type, and what should be on screen at each step.
4. **No secrets:** screenshots, logs and commands are redacted (no `whsec_`, bot tokens, passwords).
5. **Fresh-clone check:** the README setup is followed once on a clean folder and the result is noted in the README.
6. **Demo-reset script:** one script (for example `scripts/demo-reset.sql` plus a PowerShell wrapper) that deletes all test data in FK order:
   `side_effects` first, then `invoices`, then `stripe_events` (all three FKs are `ON DELETE RESTRICT`, so the order is required).
   It must not touch the schema, and the user runs it themselves. Decide at build time whether it wipes everything or only `evt_test_%` rows
   plus stripe-CLI test events, and print row counts before and after.
   It must also delete events tagged with Stripe metadata `e2e=true` (`payload->'data'->'object'->'metadata'->>'e2e' = 'true'`):
   `scripts/e2e.ps1` creates them with real `evt_...` ids, so the `evt_test_%` filter does not match them.
7. **Mailpit volume:** add a named volume for Mailpit in `~/n8n/docker-compose.yml` (with `MP_DATABASE` pointing into it) so the inbox
   survives `docker restart`/`compose down`. Today a restart wipes it, which hid emails during the M3 Mailpit-down proof.
   Keep the compose copy in `C:\dev\claude-config\n8n\` in sync by running `C:\dev\claude-config\sync.ps1` (it refuses literal secrets).
8. **Daily n8n export:** the Postgres backup (M5) does not cover n8n, which keeps workflows in SQLite in the `n8n_data` volume. Add a daily export of all workflows,
   including their settings (`errorWorkflow` etc.), into `~/n8n/backups/` next to the Postgres dumps, with the same temp-file-then-rename and 14-day pruning of its own filename pattern.
   Credentials are NOT exported (no `--decrypted`, no secrets on disk); the runbook lists the three credentials to re-create by hand. Prove it by restoring the export into a throwaway n8n
   container and showing the 5 workflows and their `errorWorkflow` values; `scripts/check-error-workflows.ps1` can run against the export.
