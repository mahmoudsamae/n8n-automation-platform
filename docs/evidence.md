# Evidence

What was actually run, with the output. Stripe stays in sandbox; nothing here touches live mode.
Times are UTC unless stated. The Stripe CLI prints Berlin time (UTC+1), and n8n, Postgres and Mailpit use UTC.
No secrets or customer addresses appear below. Event ids are Stripe sandbox ids.

## How to read this

Every row in the README's failure table carries one of three labels:

| Label | Meaning |
|---|---|
| **checked on every e2e run** | [`scripts/e2e.ps1`](../scripts/e2e.ps1) asserts it. It is run by hand after each change; there is no CI. |
| **provoked once, recorded** | I broke the system on purpose and kept the output. It is not re-run automatically. |
| **unproven** | The behaviour is designed and in the code, but I never provoked it. |

## Intake

### Fake signature: 400

Checked on every e2e run, section 7. A request with an all-zero signature:

```
[PASS] fake signature rejected with 400 - got 400
[PASS] fake event was not stored - found 0
```

### Stale timestamp: 400

Checked on every e2e run since M6a, by [`scripts/check-stale-timestamp.ps1`](../scripts/check-stale-timestamp.ps1).
A request that is correctly signed but dated 400 s ago must be refused. A control, signed the same way with a fresh timestamp, must be accepted. Without the control, a broken signing helper would also give 400 and the check would pass for the wrong reason.

```
[PASS] validly signed request 400 s old is rejected with 400 - got 400
[PASS] the stale event was not stored - found 0
[PASS] control: the same signing with a fresh timestamp is accepted with 200 - got 200
[PASS] control: the fresh event was stored exactly once - found 1
```

The check was made to fail on purpose, once per path:

| Provoked with | Result |
|---|---|
| `-AgeSeconds 0` (the "stale" request is really fresh) | `[FAIL] ... rejected with 400 - got 200` and `[FAIL] the stale event was not stored - found 1`, exit 1 |
| `-CorruptSignature` (control signed wrongly) | `[FAIL] control: ... accepted with 200 - got 400` and `[FAIL] ... stored exactly once - found 0`, exit 1 |
| `-AgeSeconds 310` | rejected with 400, as expected |

The first version of this check failed on its first run with "got 200" instead of 400. The cause was in the test, not in Intake: `Get-Date -UFormat %s` in Windows PowerShell 5.1 returns the **local** epoch, 3600 s ahead in Berlin, so the "stale" timestamp was an hour in the future. Measured: `UFormat %s` 1793361056, true UTC 1793357456, difference 3600 s. The fix is `[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()`. The same bug sat in e2e's fake-signature step; it was harmless there and is fixed too.

### Future timestamp: accepted (a limit)

Found by that same bug and then measured on purpose with `-AgeSeconds -3600`: a validly signed request dated **one hour in the future** gets 200 and is stored.

```
[FAIL] validly signed request -3600 s old is rejected with 400 - got 200
[FAIL] the stale event was not stored - found 1
```

Intake only tests `age > 300` ([`stripe-intake.sdk.ts`](../stripe-intake.sdk.ts), node `Verify Signature and Classify`), so the replay window is one-sided. Stripe's own libraries reject both directions. Exploiting this needs the signing secret, because a captured request cannot be re-dated without invalidating its signature, so I rate the impact low. It is listed under known limits and was not changed in M6a.

### Duplicate event: 200 duplicate, 1 row

Checked on every e2e run, section 6. `stripe events resend` of a stored event:

```
[PASS] resend was forwarded to intake
[PASS] resend: still exactly 1 stripe_events row - found 1
[PASS] after resend: exactly 1 invoice - found 1
[PASS] after resend: exactly 1 email side_effect - found 1
[PASS] after resend: exactly 1 telegram side_effect - found 1
[PASS] after resend: exactly 1 Mailpit message for INV-2026-000033 - found 1
```

### Database down: 500, then the resend stores 1 row

Provoked once, recorded 2026-10-30, with the real Stripe CLI (`stripe listen` plus `stripe trigger checkout.session.completed`). Postgres was stopped for about 20 s.
The CLI lines show Berlin time (11:53 = 10:53 UTC).

```
[10:53:47 UTC] docker stop postgres
[10:53:49 UTC] stripe trigger checkout.session.completed (Postgres is down)
      2026-10-30 11:53:52  <--  [500] POST http://localhost:5678/webhook/stripe-intake [evt_1UWDRRFugmPRKro8qcYB3LXG]
      2026-10-30 11:53:52  <--  [500] POST http://localhost:5678/webhook/stripe-intake [evt_1UWDRTFugmPRKro8McEbzfr0]
      2026-10-30 11:53:54  <--  [500] POST http://localhost:5678/webhook/stripe-intake [evt_3UWDRVFugmPRKro80fG8XEo9]
      2026-10-30 11:53:55  <--  [500] POST http://localhost:5678/webhook/stripe-intake [evt_3UWDRVFugmPRKro80625OLyf]
      2026-10-30 11:53:55  <--  [500] POST http://localhost:5678/webhook/stripe-intake [evt_1UWDRWFugmPRKro8FNUvrCGZ]
      2026-10-30 11:53:55  <--  [500] POST http://localhost:5678/webhook/stripe-intake [evt_3UWDRVFugmPRKro80cgzUB4L]
      2026-10-30 11:53:57  <--  [500] POST http://localhost:5678/webhook/stripe-intake [evt_3UWDRVFugmPRKro80oaeTcZL]
[10:54:06 UTC] docker start postgres
[10:54:08 UTC] postgres accepting connections: True
[10:54:08 UTC] rows stored for evt_1UWDRWFugmPRKro8FNUvrCGZ before the resend: 0   (expected 0: a 500 stored nothing)
[10:54:09 UTC] stripe events resend evt_1UWDRWFugmPRKro8FNUvrCGZ
[10:54:11 UTC] rows stored for evt_1UWDRWFugmPRKro8FNUvrCGZ after the resend: 1   (expected 1)
      2026-10-30 11:54:10  <--  [200] POST http://localhost:5678/webhook/stripe-intake [evt_1UWDRWFugmPRKro8FNUvrCGZ]
[10:54:40 UTC] final: done attempts=1 last_error=NULL
      invoices=1 email_side_effects=1 telegram_side_effects=1 stripe_events_rows=1
      Mailpit messages with subject containing INV-2026-000026: 1
```

All seven forwarded events got 500 and never a 200, so none was acknowledged without being stored. Only the resent event is of the kind the Processor handles. The other six are `ignored` types and were not resent.
In real life Stripe would retry all seven on its own schedule; the CLI does not.

## Processor

### Re-run on the same event: no second invoice or message

Checked on every e2e run, section 6b. The row is put back to `pending`; the Processor really runs again (attempts 1 to 2) and nothing is duplicated:

```
[PASS] attempts increased (proves a real re-run) - 1 -> 2
[PASS] after Processor re-run: exactly 1 invoice - found 1
[PASS] after Processor re-run: exactly 1 email side_effect - found 1
[PASS] after Processor re-run: exactly 1 telegram side_effect - found 1
[PASS] after Processor re-run: exactly 1 Mailpit message for INV-2026-000033 - found 1
```

### Two claims at once: no double claim

Provoked once, recorded 2026-10-30. This proves the claim statement under real contention. It does **not** prove two whole workflow runs racing, see the note below.

Session A runs the Processor's claim statement, copied verbatim from `stripe-processor.sdk.ts` (node `Claim Events`), and holds its transaction open for 10 s. Session B starts 3 s later.
Both end in `ROLLBACK`; 3 freshly seeded `pending` test rows were the only candidates.

```
--- 1. the Processor's exact statement (FOR UPDATE SKIP LOCKED) in session B
    A started 10:57:47 UTC, holds its claim open for 10 s, then rolls back; A claimed 3 row(s)
    B started 10:57:50 UTC (3 s later), took 0.5 s, claimed 0 row(s)
--- 2. control: session B without SKIP LOCKED (must wait for A, proving A really held the rows)
    A started 10:57:57 UTC, holds its claim open for 10 s, then rolls back; A claimed 3 row(s)
    B started 10:58:00 UTC (3 s later), took 7.4 s, claimed 3 row(s)
```

With `SKIP LOCKED`, B returned at once with nothing. Without it, B waited 7.4 s for A and then took all three. So A really held the rows, and the real statement skips them instead of waiting or taking them twice.

After the rollback the scheduled Processor processed the rows normally. Together with 3 rows from the first attempt, 6 test events ended like this:

```
6 invoices, 6 distinct invoiced events, 6 email side_effects, 6 telegram side_effects
Mailpit: INV-2026-000027 ... INV-2026-000032: 1 message each
```

**Note on the first attempt.** I first tried two production executions through the n8n API at the same moment (executions 618 and 619). They did not contend: the scheduled run 617 had already claimed one of the 3 rows at 10:55:38, execution 618 then claimed the other two in one statement, and 619 started a second later and found nothing (59 ms).
No duplicates resulted, but that run proves nothing about contention, so it is not what the claim above rests on.
The M3 section of [PLAN.md](../PLAN.md#m3-stripe-processor) lists "two runs started together" as a required proof without recording output; this is the recorded replacement for the claim statement. Two whole workflow runs racing was not reproduced.

### Ignored events untouched

Provoked once (a query), recorded 2026-10-30. 102 `ignored` rows existed (`stripe trigger` fires about 6 of them per run). Count of `ignored` rows that were ever claimed, processed, invoiced or given a side effect:

```
attempts > 0: 0   claimed or processed: 0   side_effects: 0   invoices: 0
```

### Mailpit down: failed, then done with 1 email

Provoked once, recorded in [PR #1](https://github.com/mahmoudsamae/n8n-automation-platform/pull/1) (M4 proofs 2 and 3), not re-run in M6a.
`evt_test_replayok` failed once a minute with `connect EHOSTUNREACH` while Mailpit was stopped and reached `failed` with attempts 5 after about 5 minutes.
After Mailpit restarted, `replay.ps1` moved it `failed` to `pending` to `done` with `last_error` NULL: exactly 1 invoice, 1 email side effect, 1 Telegram side effect, 1 `event_replays` row and 1 Mailpit message.

## Alerts and replay

All of this is from [PR #1](https://github.com/mahmoudsamae/n8n-automation-platform/pull/1) (M4), recorded when it was built and not re-run in M6a. The criteria are in [PLAN.md, M4](../PLAN.md#m4-failure-visibility).

### Postgres down: one throttled crash alert

Postgres stopped for about 3.5 min: 3 Processor crashes (executions 257, 260, 262) produced 1 alert.
The Monitor's own crash produced one separate alert, because the throttle key is (workflow, node).
A single crash after the 15-minute window produced an alert saying "2 similar errors suppressed since the last alert for this workflow and node".
The M5 heartbeat run saw the same shape: 9 Error Handler runs (7 Processor, 2 Monitor) gave 2 emails, one per (workflow, node) ([PLAN.md, M5 results](../PLAN.md#results-2026-10-30), proof 1c).

### Dead event: one alert, replay ends done

`evt_test_replayok`, with Mailpit down, reached attempts 5 and caused exactly one dead-event alert (execution 247: `{"telegram":"ok","email":"failed"}`, `alerted_at` set); later Monitor runs sent none.
Replay then ended `done` with 1 invoice and 1 `event_replays` row (see the Mailpit section above).
Replay refusals: `done`, `ignored` and unknown ids exit 1 with rows unchanged; a malformed id such as `x'; drop table stripe_events;--` and an empty reason exit 2; counts stayed at 59 events and 0 replays.
A reason string containing `x'); DROP TABLE event_replays;-- "quoted" $(whoami)` was stored verbatim, the table survived and no file was created.
The e2e run checks the refusal of a `done` event and the malformed id on every run (section 6c).

### Stuck rows: stale pending, stuck failed, stuck processing

Seeded test rows, with the Processor unpublished where needed:

| Alert | Setup | Result |
|---|---|---|
| Stale pending | `pending`, `received_at` 30 min old, `pending_since = now()` | no alert at 7.5 min; exactly one at the first tick after 10 min |
| Stuck failed | `failed`, attempts 2, `claimed_at` 15 min old; control claimed just now | one alert, for that row only; the next tick sent none |
| Stuck processing | `processing`, `claimed_at` 25 min old; control 12 min old | one alert, for that row only |
| Re-arming | Processor republished | all rows ended `done`, `alerted_at` cleared |
| Release resets the clock | `processing` row received 30 min ago, claimed 15 min ago | after the next Processor run `pending_since` = the release time (15:35:42), not `received_at` (15:05) |

### One alert channel down

With Mailpit stopped, a dead-event alert still reached Telegram and `alerted_at` was set.
The reverse (Telegram broken) and **both channels down at once** were not provoked.

## Hardening

Recorded in [PLAN.md, M5 results](../PLAN.md#results-2026-10-30) with Berlin and UTC times. Short version:

### Heartbeat

The Monitor pings an outside service every 5 min. I confirmed from Healthchecks.io's own event log that pings arrived while Postgres was down, and that the ping is missing when `HEARTBEAT_URL` cannot be resolved.
After about 15 min of silence (last ping about 10:13 Berlin) the check turned **down at 10:28:28 Berlin (09:28:28 UTC)** and emailed me, and **up at 10:33:28** after the stack came back.
Caveat: that outage ended in an unplanned reboot, so it exercised "no pings for 15 min", not `wsl --shutdown` by itself.
A green heartbeat proves n8n's scheduler and network only, not Postgres or the Processor.

### Backup and restore

`postgres-backup` dumps at start and every 24 h. With Postgres stopped it logged `backup FAILED` and left no new file; the 5-minute retry then produced a good dump without help.
`scripts/restore-check.ps1 -Fresh` restored the newest dump into a throwaway container with no network, and all five counts matched live. A row seeded after the dump gave `[FAIL] stripe_events live=94 restored=93`, exit 1.
`scripts/check-backup-health.ps1` came out of my own M5 review: e2e's psql calls use the trusted local socket and could not see a wrong `POSTGRES_PASSWORD`, so every backup could have failed while e2e passed. It is now part of e2e, and it was made to fail four ways.

### Secret rotation

The Postgres password was rotated by me following [`docs/runbook.md`](runbook.md#7-rotate-secrets); 3 executions failed in the window, every run after succeeded, and e2e passed through the new credential. `HEARTBEAT_URL` was rotated once too (the old URL was printed into a session by a quoting mistake).
Not rehearsed: the Telegram token and `STRIPE_WEBHOOK_SECRET` steps. The old Postgres password cannot be tested any more, so its rejection rests on `ALTER USER` semantics.

## The e2e run

Run from the M6a branch on 2026-10-30 after all changes (output trimmed to the summary):

```
== Summary ==
42/42 checks passed, 0 failed
```

42 = the 41 checks from M5 plus the stale-timestamp check.

## Not proven

- Telegram 429/5xx backoff against a real error. The retry code is in the Processor and Send Alert, but no real 429 or 5xx was ever provoked.
- Both alert channels failing at once.
- Two whole Processor runs racing (only the claim statement was).
- Whether the OLD Postgres password is rejected after rotation.
- A crash between a send and its `side_effects` insert, which can duplicate one message (at-least-once by design).
- Rotation of the Telegram token and `STRIPE_WEBHOOK_SECRET`.
