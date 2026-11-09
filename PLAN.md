# Plan

Pipeline: Stripe -> Intake -> `stripe_events` -> Processor -> Mailpit + Telegram.

| # | Milestone | Status |
|---|-----------|--------|
| M1 | Infra and storage: docker compose (n8n, postgres, mailpit), `stripe_events` table, `Postgres automation` credential | DONE |
| M2 | Stripe Intake workflow: signature check, classify, idempotent insert, 200/400/500 contract. Proven with stripe CLI, including DB-down 500 | DONE |
| M3 | Stripe Processor workflow (below) | DONE. `scripts/e2e.ps1` guards it. Known gap: real Telegram 429/5xx never provoked, backoff is unproven (needed for M6 failure table) |
| M4 | Failure visibility (below): error workflow, alert when an event ends `failed`, safe way to replay a failed event | DONE, merged (PR #1). Proofs run (see the M4 section); `scripts/e2e.ps1` 35/35. Known gaps (carry into the M6 failure table): see "Known gaps" in the M4 section |
| M5 | Hardening: secret rotation procedure, Postgres backup, live-mode checklist, runbook, external dead man's switch (Monitor pings an outside heartbeat service; silence triggers the alert, covering n8n/WSL down), e2e check that each workflow's `errorWorkflow` setting is correct (it lives only in n8n, not in the `.sdk.ts` files, so a workflow recreated from its file would silently lose alerting): Intake, Processor and Monitor must point at the Error Handler id, and the Error Handler and Send Alert must have none; replace the placeholder alert addresses (`ops@example.test` recipient, `stripe-alerts@example.test` sender in `Stripe Send Alert`) with real ones | DONE, merged (PR #2, review follow-up PR #3). All proofs recorded, `scripts/e2e.ps1` 41/41 (see "Results" in the M5 section). Known gaps listed there carry into M6 |
| M6a | Portfolio packaging, part 1: README reviewed and updated for M5, `docs/evidence.md`, stale-timestamp check, new proofs, case study (EN/DE) | DONE, merged (PR #5). `scripts/e2e.ps1` 42/42 (see "Results" in the M6 section). The repo went public in M6b Phase A |
| INV | Invoice design: German invoice (HTML email, plain text, PDF via Gotenberg) rendered only from the stored invoice row by the sub-workflow `Stripe Render Invoice`; one read-only Stripe lookup for product and payment method; owner Telegram text plus optional PDF document (`TELEGRAM_SEND_PDF`) through the shared sub-workflow `Stripe Send Telegram` | DONE, merged (PR #6). `scripts/e2e.ps1` 51/51, proofs in `docs/evidence.md` (section "Invoice, PDF and Telegram"). Not proven: real Stripe and Telegram 429/5xx, `sendDocument` failing |
| M6b | Portfolio packaging, part 2. **Phase A:** final history scan, README fixes, the owner flips the repo public. **Phase B:** screenshots, Mailpit volume, daily n8n export, clean-clone files and check, demo reset, `DEMO.md` | Phase A: DONE (PR #12 merged, repo public since 2026-11-05, history scan clean, logged-out check passed; see the M6b section). Phase B: TODO, own plan |
| M7a | Server foundation: free OCI VM from the repo, zero public ports, encrypted offsite backups, timed rebuild drill (`docs/tasks/m7-server.md`) | PR #7, merged by the owner with one line open. Rebuild drill about 38 min. **Pending:** nmap from outside, in Oracle's testing window, then a small evidence PR; the form was sent on 2026-11-08 (owner confirmed; an earlier note here said 3 Nov, wrong) and acknowledged by Oracle Security on 2026-11-09, window 17-26 Nov confirmed (see the M7 section). 7-day check done 2026-11-08: memory 25-26% by Oracle's metric, which ignores page cache |
| Guards | Destructive-command guards: helper guard, PreToolUse hook (see "Safety guards") | DONE, merged (PR #9, #10). The open MEDIUM (e2e guard step never seen failing) is closed: seen failing with an allow-all stub, and `destructive-guard.test.mjs --prove-failure` proves the suite catches both stubs and that a crashing suite does not count (an e2e step since PR #11, merged; automation-review: SHIP, its MEDIUM fixed; e2e 54/54). Proofs in `docs/evidence.md` |
| M7b, M7c | Stack and tunnel; demo experience (see the M7 section and the spec) | M7b: plan approved 2026-11-08, 7 PRs, spec `docs/tasks/m7b-stack-tunnel.md`. M7b-1 (metadata service blocked from containers) DONE, merged (PR #16). M7b-2 (`n8n_app` role, migration 007 run by the owner) DONE, merged (PR #17). M7b-3 (workflows cannot read the environment: signing secret in a crypto credential, config in n8n data tables, server key from a file) built, laptop e2e 50/50, PR open. M7c: TODO |

**Next steps:** (0) `m7-server-backup` ping URL rotated 2026-11-08, new check green with the 13:12 ping and old check deleted, both owner confirmed (`docs/evidence.md`, "Backup ping rotation"); (1) Oracle's form was sent on 2026-11-08 and acknowledged by Oracle Security on 2026-11-09 (owner confirmed), scan window 17-26 Nov confirmed; no rebuild drill before the scans are done, a new VM gets an IP the form does not list; (2) M6b Phase B: its own plan, criteria 1-6 and 8; criterion 8's repeated history scan reuses the Phase A scan (as `scripts/scan-history.ps1` if the owner approves it) (Phase A is done; the local branches `invoice-design` and `m4-failure-visibility` remain, their remote copies are gone); (3) in Oracle's window: both scans, then the evidence PR; (4) from 15 Nov: the M7a lifecycle follow-up (the 7-day memory follow-up is done).

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
All times are Europe/Berlin (CET, UTC+1) with UTC in parentheses. Healthchecks.io's event log is in Berlin time; n8n, Postgres and Mailpit are UTC.
- **Proof 1a** done: Monitor executions 385 and 391 both show `Heartbeat Ping` -> `{"data":"OK"}`; `Heartbeat Ping` has executionIndex 1, before `Find Alertable Events` (2), because n8n orders branches by canvas position. **Confirmed by the user** from Healthchecks.io's own event log: pings at 09:38 (08:38 UTC), 09:43 (08:43 UTC), 09:53 (08:53 UTC), 09:58 (08:58 UTC) and 10:03 (09:03 UTC). The first two match executions 385 (09:38:26 / 08:38:26 UTC) and 391 (09:43:26 / 08:43:26 UTC); 09:53 (08:53 UTC) and 09:58 (08:58 UTC) are covered under proof 1c, and 10:03 (09:03 UTC) is the first after Postgres came back. Claude cannot see that side; this is the user's report.
- **Proof 1b** done (user report). Last ping about 10:13 (09:13 UTC); Healthchecks.io changed the check to **down at 10:28:28 (09:28:28 UTC)** (= last ping + period 5 + grace 10 min) and sent the down email. The laptop then rebooted on its own (not planned), the stack was back at about 10:31 (09:31 UTC) and all four containers were already running before `docker compose up -d` was typed (restart policies work). Healthchecks.io changed the check back to **up at 10:33:28 (09:33:28 UTC)** (user report; this is the status-change time, the up email follows it). n8n's side agrees: the Monitor's last run before the outage was 10:13:26 (09:13:26 UTC) and the next one 10:33:26 (09:33:26 UTC) (executions 456 and 462; none in between), so recovery took 2 s from the first ping. Caveat: the outage ended in an unplanned reboot, so this exercised "no pings for 15 min" (the case that matters), not the `wsl --shutdown` command by itself.
- **Proof 1c** done: Postgres stopped 09:52:30-09:58:51 (08:52:30-08:58:51 UTC). Both Monitor runs (414 at 09:53:26 / 08:53:26 UTC, 427 at 09:58:26 / 08:58:26 UTC) ended `error` with the heartbeat OK. The Error Handler ran 9 times (7 Processor, 2 Monitor) and sent 2 emails: one per (workflow, node), not one in total as the criterion text said. **Confirmed from outside by the user:** Healthchecks.io logged the 09:53 (08:53 UTC) and 09:58 (08:58 UTC) pings, which arrived while Postgres was down.
- **Proof 1d** done: `HEARTBEAT_URL` overridden from the shell (`.env` untouched) with an unresolvable host. Monitor execution 406 (09:48:26 / 08:48:26 UTC) ended `success`, the DNS error is in its data, no Error Handler execution and no crash email. Real URL restored and verified. **Confirmed from outside by the user:** the 09:48 (08:48 UTC) ping is missing from the Healthchecks.io event log, matching this test (the 3 tries failed on DNS and the error was absorbed).
- **Proof 2** done: guard passes on live (5/5) and prints FAIL for the three protected workflows with a wrong id (exit 1).
- **Proof 3** done: seeded dead `evt_test_alert_addr` at 09:33:15 (08:33:15 UTC); the alert arrived 12 s later (09:33:27 / 08:33:27 UTC) with From/To from the env vars, none `example.test`. `stripe-send-alert.sdk.ts` has no `example.test` left. The Processor's `stripe-processor@example.test` remains (live-mode checklist item). Test row deleted in FK order.
- **Proof 4** done: first dump at container start; with Postgres stopped, `backup FAILED` and no new file; the 5-minute retry was then observed (failed ~09:31:11 (08:31:11 UTC), new dump 09:36:11 (08:36:11 UTC), no manual action).
- **Proof 5** done: `restore-check.ps1 -Fresh` restored into a throwaway container with no network, all five counts match live. The mismatch path was also proven: a row seeded after the dump gave `[FAIL] stripe_events live=94 restored=93`, exit 1 (row deleted after).
- **Proof 6** done (rotation performed by the user, verification by Claude, no secret printed). User procedure: fresh backup, new password into a temp file, `ALTER USER` via a psql variable, `.env` updated with `sed`, n8n credential updated via `clip.exe` and tested, `postgres-backup` recreated (this also recreated `postgres`), temp file shredded. Window: 3 failed executions (Processor 10:43:37 and 10:44:37, Monitor 10:43:26; 09:43:37, 09:44:37 and 09:43:26 UTC), every Processor run from 10:46 (09:46 UTC) succeeded. Verified: `.env`, the `postgres` container and the `postgres-backup` container hold the same value; the new password is accepted over TCP from another container and a wrong one gets `password authentication failed`; `scripts/e2e.ps1` 40/40 with a real `stripe trigger` event ending `done` through the new n8n credential; `restore-check.ps1 -Fresh` dumped over TCP with the new password and restored with matching counts (114/46/23/1, sequence 23). The first automatic dump after the recreate failed at 10:45:07 (09:45:07 UTC) ("database system is starting up") and the 5-minute retry design covers it. **Not proven:** the OLD password cannot be tested (it no longer exists); its rejection rests on `ALTER USER` semantics.
- **Correction found while verifying proof 6:** the runbook's TCP check (`docker exec postgres ... psql -h 127.0.0.1`) could never fail, because pg_hba trusts loopback inside the postgres container (a wrong password was accepted there). Runbook section 7 now tests from another container. Runbook section 7 also gained the two-login-role pattern as the recommendation for a real client (not built).
- **Proof 7** done: no ping URL, `whsec_` or bot token in either repo's files or in git history. The old ping URL was printed once into the Claude session by a shell-quoting mistake, so it was rotated following runbook section 7: new check created, `.env` updated, n8n recreated (`HEARTBEAT_URL` verified set without printing it), **the user confirmed the new check is green and the old one is deleted**. This also exercised the `HEARTBEAT_URL` rotation steps once; the Telegram token and `STRIPE_WEBHOOK_SECRET` steps remain unrehearsed.
- **Proof 8** done: `scripts/e2e.ps1` 40/40.
- Side finding fixed: `seed-test-event.ps1` failed without `-ClaimedMinutesAgo` (`''::int` is evaluated while planning); now NULL-safe.
- Review follow-up (after the M5 merge): e2e could pass while every backup failed, because its psql calls use the trusted local socket and never test the password. `scripts/check-backup-health.ps1`, run by e2e (now 41 checks), authenticates over TCP from `postgres-backup` with the `.env` password, checks the container was created with that same password, and fails if its last log line is `backup FAILED` (prints yes/no only). Proven able to fail: `PGPASSWORD=wrong` (TCP FAIL, exit 1, and e2e itself stops in preflight with exit 1), a throwaway container whose last log line is `backup FAILED`, a throwaway container created with a stale password, and a missing container.
- Compound follow-up (branch `compound-m5`): `scripts/wsl-sh.ps1` (run a bash script in WSL via base64), the PreToolUse hook `scripts/hooks/wsl-quoting-guard.mjs` (blocks `wsl ... bash -c` with `$(`, `` `$ `` or `\$`, and `wsl` reads of `.env`, secret-looking `printenv` or `docker compose config`, and names `scripts/wsl-sh.ps1` as the alternative; 15-case test, which was itself proven able to fail against stub hooks that allow or block everything), `scripts/clean-test-event.ps1` and `scripts/n8n-executions.ps1`. The global `automation-review` skill gained "provoke every check's failure path once" (three checks in M5 could never fail until they were provoked). The drift hook's workflow map now knows all five workflows.

### Known gaps after M5 (carry into the M6 failure table)
- A green heartbeat does not prove Postgres or the Processor work.
- Backups sit on the same disk as the database: protects against bad data and a lost volume, not a lost machine.
- `n8n_data` is not backed up until the M6 export (item 8); credentials are never exported.
- A forgotten Pause means one false down email.
- Both alert channels failing at once (M4) and real Telegram 429/5xx backoff (M3) stay unproven.

### Out of scope
Off-site backups, automating Healthchecks.io through its API, the Mailpit volume (M6b), real Stripe live mode.

## M6: Portfolio packaging

Split in two: M6b needs compose changes and a stopped live stack, so M6a ships first and a truthful README exists even if M6b slips. Only claims backed by evidence from real runs go in.
Goal: this repo is the main portfolio piece for German applications (automation, backend, AI-automation). A recruiter gives it 2 minutes, a technical interviewer 20.

Decisions (2026-10-30):
- Telegram 429/5xx stays labelled **unproven**; no stub test.
- The repo goes public after M6a. Before the switch: a scan of the full history (all commits, all branches, PR refs) for secrets, the Telegram chat ID and `hc-ping.com` URLs, result shown to the owner, who flips the visibility.
- `hello-webhook-strict.ts` (an early stray file, referenced nowhere) is deleted.
- The README's "How it was built" lists five corrections the owner confirmed, the fifth being the `POSTGRES_PASSWORD` blind spot behind `check-backup-health.ps1` (PR #3).

### M6a: README, evidence, case study (status: built on `m6a-portfolio-readme`, PR open, not merged)

Acceptance criteria:
1. **Review first.** The draft's claims are kept, fixed or cut with evidence (table under Results).
2. **Top of the README for the recruiter:** a pitch with no milestone jargon that says "sandbox", 3-4 proven results, a small diagram with the 200/400/500 branches.
3. **Rest of the README for the interviewer:** failure table, engineering decisions, known limits, where to start reading, the detailed diagram, a German Kurzfassung.
4. **Updated for M5:** heartbeat, backups and restore drill, rotation, runbook, guard scripts, all known gaps; the check count matches the latest e2e run.
5. **Failure table:** every row of the old criterion 2 plus heartbeat, restore and rotation, each labelled `e2e`, `provoked` or `unproven`.
6. **`docs/evidence.md`** holds the recorded outputs with stable anchors (M4 from PR #1, M5 from this file, new runs). No secrets, no customer addresses.
7. **New proofs on the live stack, one agent at a time:** stale timestamp (new e2e check with a fresh-timestamp control), database down (500, then resend stores 1 row), two claims at once, `ignored` events untouched.
8. **Links are stable and checked:** no line-number links; every relative link and anchor resolved by a script.
9. **Honest wording:** no "production-ready", no "exactly once", no "every failure path"; one line says the invoices make no claim to § 14 UStG or GoBD.
10. **Case study** in `docs/case-study.md`, English and German, claiming only what this file proves.
11. **Done means:** `scripts/e2e.ps1` summary shown, secret scan clean, PLAN.md and CLAUDE.md updated, PR open for the owner to merge.

Branch and worktree: the draft branch `m6-readme-draft` (worktree `C:\dev\n8n-workflows-readme`) was rebased onto `main` (it only adds `README.md`) and renamed `m6a-portfolio-readme`. After the owner merges:
check the worktree is clean, `git worktree remove "C:\dev\n8n-workflows-readme"` (never `--force`), `git worktree prune`, `git branch -d m6a-portfolio-readme` (a squash merge makes `-d` refuse: ask before `-D`), delete the remote branch, show `git worktree list`.

#### Results (2026-10-30)
- **Review of the draft** (131 lines, 2 unpushed commits on `38dea66`, 9 commits behind `main`):
  - Overclaims removed: "every failure path is tested", "runs on every change" (there is no CI; e2e is run by hand), "one throttled crash alert" (M5 proof 1c showed one per (workflow, node)).
  - Stale for M5 and rewritten: the 35/35 count (now 42/42), the "M5 still open" limits, the setup status, the stack table.
  - Citations: line-number links had drifted and were dropped; links to the "Proof required" lists pointed at requirements, not results, so they now point at `docs/evidence.md`.
  - Kept: the known-limits section, the engineering decisions, and marking Telegram and both-channels-down as unproven. The "How it was built" corrections were not provable from this file; the owner confirmed them.
- **Stale timestamp:** new `scripts/check-stale-timestamp.ps1`, run by e2e (a validly signed request 400 s old gets 400 and is not stored; a fresh-timestamp control is accepted and stored once). Made to fail both ways: `-AgeSeconds 0` and `-CorruptSignature`.
- **Test bug found on the way:** `Get-Date -UFormat %s` in Windows PowerShell 5.1 is the LOCAL epoch (3600 s ahead in Berlin). The first version of the check put its "stale" timestamp an hour into the future and got 200. Fixed with `[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()`, also in e2e's fake-signature step.
- **Finding: one-sided replay window.** Intake accepts a validly signed request dated one hour in the future (it only tests `age > 300`). Impact is low, it needs the signing secret. Not changed in M6a: listed under known limits and open for a decision.
- **Database down:** 7 forwarded events all got 500 while Postgres was stopped; the resend stored exactly 1 row and it ended `done` with 1 invoice, 1 email, 1 Telegram message (output in `docs/evidence.md`).
- **Two claims at once:** the first attempt (two API-started runs, executions 618 and 619) did not contend, so it proves nothing. The recorded proof runs the Processor's exact claim statement in two sessions, A holding its transaction open: B got 0 rows in 0.5 s; the control without `SKIP LOCKED` waited 7.4 s and took all 3. Two whole workflow runs racing was not reproduced.
- **`ignored` events:** 102 rows, none ever claimed, processed, invoiced or given a side effect.
- **`scripts/e2e.ps1` 42/42** (the 41 from M5 plus the stale-timestamp check).
- Test rows `evt_test_m6a_par1..6` were created and removed with `clean-test-event.ps1`. The events from the database-down proof and the e2e run keep real `evt_...` ids and stay until the M6b reset script.

### M6b: remaining packaging

Split in two (owner decision, 2026-11-05): **Phase A** makes the repo public now; **Phase B** is criteria 1-6 and 8 below and gets its own plan.

#### Phase A: public flip (branch `m6b-public`)
Decisions (2026-11-05): git history is kept, no rewrite. The owner's gmail address stays in the metadata of the first 62 commits (no file contains it); new commits use the GitHub noreply address (local `user.email`). No LICENSE (all rights reserved). LinkedIn is dropped from the README.
- **Scan (2026-11-05), result: clean.** Scope: a `--mirror` clone (1 head, 11 `refs/pull/*`, 0 tags, 73 commits, 199 blobs, all commit messages) plus all PR bodies, comments and reviews. Patterns (whsec, Stripe keys, Telegram token, `hc-ping.com`, private keys, AGE, `tskey`, OCI PAR URL and OCID, cloud tokens, JWT, `PASSWORD=literal`): 0. Every value in `~/n8n/.env`, exact match: 0, except `INVOICE_EMAIL_FROM` (the documented `musterwerk.example` sender). The current home IP and the server's public IP, fetched and never printed, dotted and dashed: 0. Any public IPv4: one hit, a four-part version-string example in an old PLAN.md (the one `check-docs.ps1` once found), not an address. No wiki, pages, releases, issues or Actions runs.
- **README:** e2e count 51 -> 54 (pitch and Kurzfassung), Render Invoice and Send Telegram in "Where to start reading", author line with the portfolio link.
- **Portfolio link:** `https://mahmud-alhussen.de` did not resolve on 2026-11-05, so the README links `https://mahmud-portfolio-ten.vercel.app`. **TODO:** switch the README author line to `https://mahmud-alhussen.de` (and the repo homepage) once it serves the portfolio.
- **Owner steps on GitHub:** email privacy and push blocking, repo description, homepage and topics, profile display name "Mahmud Al Hussen", flip to public, then branch protection on `main` (criterion 7a), then a logged-out render check.
- **Result (2026-11-05): DONE.** PR #12 merged. Checked through the API without credentials: repo `public`, description, homepage (the Vercel URL) and 7 topics set, profile name "Mahmud Al Hussen", public profile email `null`. Ruleset `protect-main` active on the default branch: PR required (0 approvals), no force push, no deletion. The email push-blocking setting is not visible through the API; the owner set it, not verified by Claude.
  Logged-out check (`curl`, no cookies): the page has no signed-in user, the merged README (all 10 sections, 54 checks, portfolio link, no LinkedIn placeholder), the 3 images load from the public raw URLs, all 94 README links return 200 and every in-page anchor exists (the 95th, `#readme-ov-file`, is GitHub's own tab link). Both Mermaid diagrams (the small one and "The full picture") render: checked by the owner in a private window, because Playwright and headless Edge hung in that session.

Acceptance criteria (Phase B, and 7/7a for Phase A):
1. **Mailpit volume:** `mailpit_data` with `MP_DATABASE`, applied with `up -d --no-deps mailpit` (recreating n8n drops the n8n MCP). Proof: a message survives `docker restart mailpit` and a `compose down` + `up` (never `-v`). Compose copy synced with `C:\dev\claude-config\sync.ps1`.
2. **Daily n8n export:** a sidecar on the same n8n image and the `n8n_data` volume runs `export:workflow --all` at start and every 24 h into `~/n8n/backups/n8n-workflows-<UTC>.json`: temp file then rename, mode 600, 5-minute retry, 14-day pruning of its own pattern only, no credentials and no `--decrypted`. A sidecar, not cron, because the stack is not always on (M5 finding), and not n8n backing itself up, because that fails exactly when n8n does.
   e2e fails if the newest export is empty or older than 25 h (failure path provoked once). `check-error-workflows.ps1` gains `-ExportFile`. Proof: import into a throwaway n8n with no network and show 7 workflows with the right `errorWorkflow`; a tampered copy gives FAIL. The runbook lists the three credentials to re-create by hand.
3. **Clean-clone files:** `deploy/docker-compose.yml`, `.env.example` (names only), `workflows/*.json` from the export (no `staticData`, no `pinData`, grepped for secrets; `.sdk.ts` stays the source of truth), n8n image pinned to the version running now. e2e fails if the repo compose differs from `~/n8n` or the JSON from live. JSON, because `n8n import:workflow` keeps ids, so `errorWorkflow` and Send Alert references survive without the n8n MCP.
4. **Demo reset:** `scripts/demo-reset.ps1`, run by the owner. One transaction, FK order **`event_replays`, `side_effects`, `invoices`, `stripe_events`** (all RESTRICT; the old text omitted `event_replays`), schema untouched.
   It wipes all rows: `stripe trigger` fires about 6 untagged `ignored` events that neither the `evt_test_%` nor the `e2e=true` filter catches, and the data is sandbox only. Guards: refuses if any payload has `livemode=true` or any row is `processing`; `-DryRun`; typed confirmation; a fresh dump first. Prints counts before and after, clears Mailpit through its API, keeps `invoice_number_seq` (e2e counts Mailpit messages by invoice number, and a reused number would break that).
   Runs only after M6a's evidence is recorded, because it deletes the rows behind it.
5a. **Screenshots back in the README:** the owner adds `docs/img/healthchecks-down-up.png` (Healthchecks.io down then up) and `docs/img/telegram-alert.png` (owner alert in Telegram), then both entries return to the README Screenshots section. `scripts/check-docs.ps1` keeps passing: it fails on any broken image link, so add the file before the reference.
5. **Fresh-clone check:** a new folder, following only the README. The live stack is stopped with `compose down` (no `-v`) and the heartbeat paused, because `container_name` and fixed ports block running both. The owner runs the migrations. Passes when `e2e.ps1` and the guard scripts pass; date and result go in the README. A step that needs outside knowledge is a README bug. Live is then brought back and verified with e2e. Whether imported workflows re-link to hand-made credentials is untested and this check will show it.
6. **`DEMO.md`:** a 2-minute script with timestamps, exact commands, what is on screen, and a marked cut for the Processor's wait of up to 60 s; rehearsed once with a stopwatch. `stripe listen` prints `whsec_` on STDERR, so redirect it to a file; never on screen: the heartbeat URL, the Telegram chat ID, `ALERT_EMAIL_TO` in Mailpit. The owner records the video.
7. **Public repo (flipped by the owner after M6a, before M6b):** a rendered-README check while logged out, including the Mermaid diagrams, as soon as it is public (done 2026-11-05, see Phase A); when M6b lands, the README's "Setup" limit is replaced by the verified setup steps and the history scan is repeated.
7a. **Branch protection:** the owner turns it on for `main` when the repo goes public. Done 2026-11-05 (ruleset `protect-main`, see Phase A).
8. **Done means:** e2e summary shown, runbook section 8 and known limits updated, PLAN.md and CLAUDE.md updated, M6 marked done.

## Safety guards

**Why:** `scripts/wsl-sh.ps1` and `scripts/server-sh.ps1` send the script as base64, so a permission rule cannot see a `DROP` or `down -v` inside a file or a variable. The owner approved this design on 2026-11-01. These guards stop mistakes, not a determined attacker.

**Live and proven, 2026-11-01 (`~/.claude/settings.json`, not in this repo):**
- Deny, Bash and PowerShell: `*compose*down*-v*`, `*compose*down*--volumes*`, `*docker volume rm*`, `*docker volume remove*`, `*docker volume prune*`, `*docker system prune*--volumes*`. Denied with `--help` probes: direct, through `wsl`, inside `wsl ... bash -c`, through `wsl-sh.ps1 -Script`. Also denied: a multi-line here-string and uppercase `DOCKER VOLUME RM`.
- Ask, Bash and PowerShell: `*gh pr*merge*`, `*pulls/*/merge*`, `*clean-test-event*` (approved decision 1). All probed in `gh pr merge` (both shells), the API form and `clean-test-event.ps1` prompted, and the owner answered No.
- Known bypass, shown: `d=docker; $d volume rm --help` was not denied; it only stopped because Git Bash has no `docker`.

**Built 2026-11-03 (branch `safety-guards`), proofs in `docs/evidence.md` section "Safety guards":**
1. **One pattern list:** `scripts/lib/destructive-patterns.json`, 10 patterns (DROP, TRUNCATE, DELETE FROM, compose `down -v`/`--volumes`, `volume rm|remove|prune`, `dropdb`, `dropuser`, `pg_restore --clean`, `system prune --volumes`, `/var/lib/docker/volumes`), each with a harmless `echo` sample that the tests use, so no pattern goes untested.
2. **Helper guard:** `scripts/lib/destructive-guard.ps1`, dot-sourced by both helpers on the final text before encoding (`-Script`, `-File`, piped, stdin). Refusal = exit 3, nothing sent; an unreadable pattern file also refuses. No override switch. Test: `scripts/check-destructive-guard.ps1 [-Target wsl|server|both] [-ProveFailure]`.
3. **Hook:** `scripts/hooks/destructive-guard.mjs`, registered next to `wsl-quoting-guard` in `.claude/settings.json`. Acts only when an executor is a segment's command word (also after `sudo`, and a variable as the command word, which closes the 2026-11-01 bypass); scans the command, literal base64 and the helpers' `-File` targets, never `powershell -File <script>`. Test: `scripts/hooks/destructive-guard.test.mjs`, proven able to fail with stubs. Both tests run in e2e.
4. **Decision 1, approved, already live:** direct `clean-test-event.ps1` calls prompt. e2e's nested call through `check-stale-timestamp.ps1` stays an exception: a rule cannot see it, and e2e needs it to remove its own test rows. The hook lets the direct call through to that ask rule.
5. **Decision 2, approved:** ask rules on both helpers, `scripts/lib/destructive-*` and `scripts/hooks/**` in `~/.claude/settings.json`, added last. Written as `Edit(//c/dev/n8n-workflows/...)`: an `Edit(path)` rule also covers Write (a `Write(path)` rule is never matched), and `//c/...` is the absolute Windows form. Probed 2026-11-03: prompted, the owner answered No.
6. **Public-IP check:** `scripts/check-docs.ps1` fails on any public IPv4 address in tracked files (private, loopback, link-local, Tailscale and documentation ranges allowed; hits print masked). Its first run found one version-string example in this file, since reworded; `-AllowedIps` is empty.

**Follow-up (small):** e2e prints the ~60 expected refusal lines of `check-destructive-guard.ps1` on stderr (one as a PowerShell ErrorRecord), which buries real errors. Run the check as a child process with stderr discarded.

**Still open:** text built at runtime, files one level down (`psql -f`), other routes (Docker socket, Python), MCP tools and n8n workflows. The M7b Postgres role is the hard boundary for the database.

## M7: Public live demo

Spec: `docs/tasks/m7-server.md`. Proofs: `docs/evidence.md` section "M7a server". Operations: `docs/runbook.md` section 11.

### M7a follow-ups
- **Scans, the one open Definition of Done line:** the form was NOT sent on 3 Nov as noted before; the owner sent it on 2026-11-08 (owner confirmed); Oracle Security acknowledged it by email on 2026-11-09 ("you may proceed as planned", owner confirmed), window 17 Nov 09:00 to 26 Nov 23:00 Berlin, confirmed (the filled copy lives outside the repo, it holds the home IP; target and source IP unchanged since the 3 Nov draft). In the window, run both scans in one session (control port, then full; runbook section 11), then open a small evidence PR that adds the output to `docs/evidence.md` and marks the line done.
- DONE 2026-11-08, 7 days after the rebuild: Oracle's `MemoryUtilization` P95 25-26% all week, `free -m` 26.7% without cache and 78.6% with it, so Oracle ignores page cache and the VM stays about 6 points above 20%. CPU P95 2-4.5%, network far below. All 7 nightly backups in the journal, the bucket and Healthchecks (`docs/evidence.md`, "After 7 days").
- Day 15 after the first backup (from 2026-11-15): check the bucket's lifecycle rule really deleted the oldest object. Keep the first object until then, it is the test.
- Move backups to R2 before real data: a closed Oracle account loses the backups too.
- The pre-authenticated upload URL expires after one year.

### M7b requirements found in M7a
- DONE in M7b-2 (2026-11-08, `docs/evidence.md` "Database role without DDL rights"; n8n starts using it in M7b-5): give n8n its own Postgres role without DDL rights (no DROP, TRUNCATE or ALTER). The owner role stays for migrations, which the owner runs. This is the hard boundary: text guards can be bypassed, and they never see an n8n Postgres node.
- Back up the n8n export too. `N8N_ENCRYPTION_KEY` alone saves nothing: credentials live in the `n8n_data` volume, which is not backed up.
- DONE in M7b-1 (2026-11-08, `docs/evidence.md` "Metadata service blocked"): block containers from the instance metadata service, before any public traffic: the n8n container could read it (checked 2026-11-01, even with IMDSv2's header). User-data, with the spent Tailscale key, is readable through it. Also confirm "Require an authorization header" on every rebuild.
- Alert when the stack or VM is down: today only the nightly backup ping notices, after up to about 30 hours. Fine with no traffic, not with a public demo (the spec's outside uptime check).
- DONE in M7b-3 (2026-11-09, `docs/evidence.md` "Workflows cannot read the environment"): workflow code could read the n8n environment (`N8N_BLOCK_ENV_ACCESS_IN_NODE=false`, including `N8N_ENCRYPTION_KEY`). Now `true` on the laptop and the server; nothing secret is passed as a variable.
- Follow-up (owner, optional): the laptop's `~/n8n/.env` still holds six lines nothing reads any more (`TELEGRAM_CHAT_ID`, `ALERT_EMAIL_TO`, `ALERT_EMAIL_FROM`, `INVOICE_EMAIL_FROM`, `TELEGRAM_SEND_PDF`, and the deleted check's `HEARTBEAT_URL`). The laptop's n8n image is still unpinned (`docker.n8n.io/n8nio/n8n`); the server pins 2.45.6.
- Re-run the drill to "e2e green": that number goes in the README, not M7a's 38 minutes.
- The drill's new VM has a new public IP that Oracle's form does not list. A scan of it needs a new form, and if 2026's test is used up, it waits for 2027. Until then the proof is the Security List.
- Re-measure memory with workflows, `cloudflared` and real PDF renders: all `mem_limit` values add up to 2,688 MB today on a 4 GB VM.

### M7c requirement found in the Safety guards task (owner decision, 2026-11-03)
- The nightly demo reset runs real `DELETE FROM` statements. It runs on the server as a systemd service and timer (like `backup-offsite.timer`), never through `wsl-sh.ps1` or `server-sh.ps1`: the guards refuse those statements there, by design, and must not get an exception for it.
- It connects with its own narrow Postgres role: `DELETE` on the four pipeline tables (`event_replays`, `side_effects`, `invoices`, `stripe_events`) and `SELECT` for its guards only. No DDL, no `TRUNCATE`, no access to other tables. A role, because a text guard can be bypassed and the database cannot.

### Before M7a

**Constraint from the invoice work:** invoice numbers are sequential and guessable, and an invoice shows a customer name and payment details. M7 must not serve a PDF by invoice number alone: a visitor link needs an unguessable token. The renderer (`Stripe Render Invoice`, input `invoice_number`) is meant to be reused so page and email cannot drift apart; the token check belongs in front of it. Decided in M7's criteria session, not built.

Idea, not yet a plan: a public demo that runs on a free Oracle Cloud Always Free ARM instance behind a Cloudflare Tunnel. A visitor pays with Stripe's test card and watches the event, the invoice and the email appear, then resends the same payment and sees that no second invoice is created.
It needs rate limiting and a nightly reset (M6b's demo-reset is the likely starting point).

Written down so it is not forgotten; nothing is decided or built. The acceptance criteria are written in their own session, and the session also has to settle:
- Stripe stays in test mode, so "Nothing goes live" in `CLAUDE.md` and the live-mode checklist wording need a deliberate update, not a silent one.
- A public endpoint changes the threat model (abuse, cost, what the demo may store); that review comes before any build.

## Invoice design: results

- Workflows 5 -> 7 (`Stripe Render Invoice`, `Stripe Send Telegram`). Processor 37 -> 42 nodes. The Telegram retry chain exists once, in `Stripe Send Telegram`; Send Alert still has its own copy (possible follow-up: reuse Send Telegram there).
- Migration 006 (run by the owner): `customer_name`, `payment_method`, `line_items` on `invoices`, all-or-none CHECK.
- The PDF is never stored; it is re-rendered from the row. GoBD archiving of the sent PDF is not built (listed in the README and the live-mode checklist).
- `TELEGRAM_SEND_PDF` sends customer data to a third party: the GDPR decision is documented in `docs/runbook.md` section 10.
- Accepted: if PDF rendering and the Telegram text fail in the same run, `last_error` shows the text failure; the next run reports the PDF problem.
- M6b note: the demo reset and the clean-clone files must cover Gotenberg and the two new workflows (7, not 5, in the import check).
- Follow-up (automation-review, Medium 4): Send Alert still has its own Telegram retry copy; reuse `Stripe Send Telegram` there.
- Decided (automation-review, Medium 2): the Telegram send nodes have no timeout, and n8n 2.45.6's Telegram node has no timeout option at all. The gap is documented (README known limits, runbook section 9); a hung call is recovered by the 10 min stuck-row release and the 20 min `stuck processing` alert. Planned fix, not built: HTTP Request nodes with `options.timeout` for `Send Message` and `Send Document` (re-prove the retry loop, one live payment, e2e).
- New e2e checks: `scripts/check-sdk-drift.ps1` (each `.sdk.ts` compiled with the pinned SDK in `scripts/sdk-drift` and diffed against the live export) and `scripts/check-docs.ps1` (CLAUDE.md line limit, relative links and images). The README Screenshots section no longer references `healthchecks-down-up.png` and `telegram-alert.png`; they come back with M6b (see there).
