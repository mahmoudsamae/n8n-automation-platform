# Plan

Pipeline: Stripe -> Intake -> `stripe_events` -> Processor -> Mailpit + Telegram.

| # | Milestone | Status |
|---|-----------|--------|
| M1 | Infra and storage: docker compose (n8n, postgres, mailpit), `stripe_events` table, `Postgres automation` credential | DONE |
| M2 | Stripe Intake workflow: signature check, classify, idempotent insert, 200/400/500 contract. Proven with stripe CLI, including DB-down 500 | DONE |
| M3 | Stripe Processor workflow (below) | DONE. `scripts/e2e.ps1` guards it. Known gap: real Telegram 429/5xx never provoked, backoff is unproven (needed for M6 failure table) |
| M4 | Failure visibility (below): error workflow, alert when an event ends `failed`, safe way to replay a failed event | DONE. Proofs run (see the M4 section); `scripts/e2e.ps1` 35/35. Known gaps (carry into the M6 failure table): see "Known gaps" in the M4 section |
| M5 | Hardening: secret rotation procedure, Postgres backup, live-mode checklist, runbook, external dead man's switch (Monitor pings an outside heartbeat service; silence triggers the alert, covering n8n/WSL down) | TODO |
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

## M6: Portfolio packaging

Starts after M3 (M4 and M5 can finish first). Only claims backed by evidence from real runs go in.

### Acceptance criteria
1. **README.md:** one-paragraph pitch, architecture diagram (Stripe -> Intake -> `stripe_events` -> Processor -> Mailpit + Telegram,
   with the 200/400/500 branches), setup steps that work from a clean clone, and the tech list.
2. **Failure scenarios table:** one row per scenario with expected behavior and a link or pasted command output as proof. Minimum:
   fake signature (400), stale timestamp (400), duplicate event (200 duplicate, 1 row), database down (500, then resend stores 1 row),
   Mailpit down (event `failed`, later `done` with 1 email), Telegram 429/5xx (backoff then success), two Processor runs at once (no double send),
   `ignored` events untouched.
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
