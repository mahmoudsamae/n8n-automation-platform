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

Intake only tests `age > 300` ([`stripe-intake.sdk.ts`](../stripe-intake.sdk.ts), node `Verify Signature and Classify`), so the replay window is one-sided.

This matches the reference library, so it is not a deviation from Stripe's own check. Read on 2026-10-30: [`stripe-node`'s `Webhooks.ts`](https://github.com/stripe/stripe-node/blob/master/src/Webhooks.ts) computes `timestampAge = now - details.timestamp` and rejects only when `tolerance > 0 && timestampAge > tolerance`, so a future timestamp gives a negative age and passes there too. [Stripe's webhook docs](https://docs.stripe.com/webhooks) (section on preventing replay attacks) say to compare the difference between the current and the received timestamp with a tolerance, 5 minutes by default; they do not say the check must be two-sided. Library source changes, so re-read it before relying on this.

Whether Stripe's other official libraries behave the same was not checked. I rate the impact low by construction: the signature covers the timestamp, so a captured request cannot be re-dated without invalidating it, and a future-dated request needs the signing secret. It is listed under known limits and was not changed in M6a.

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

## Invoice, PDF and Telegram

All recorded 2026-10-30 (times UTC) on the live stack with the Stripe CLI, unless it says otherwise. Customer data is Stripe's sandbox fixture ("Jenny Rosen"); no real person is involved.

### Gotenberg memory gate

Before any workflow change: Gotenberg (`8.39.0-chromium`, 512 MB memory and swap cap, no published port) was added to compose and 10 sequential renders of a realistic German invoice page were measured against the 2 GB WSL.

```
10/10 renders ok: http 200, %PDF-, 25,064 bytes each; the first took 5.2 s (Chromium start), the others 0.3-0.7 s
samples=10  min_available=707 MB  swap_used 5 MB before -> 94 MB after  gotenberg_peak=491 MB (cap 512)  n8n_peak=517 MB
memory.events: oom 0, oom_kill 0   gotenberg OOMKilled=false restarts=0   n8n: same StartedAt before and after, restarts=0
```

The 491 MB peak looks tight but is mostly file cache: the cgroup split was `anon 133 MB, file 280 MB`, and the kernel reclaims cache before it kills anything (`memory.events max 0`). Chromium stays resident, so Gotenberg idles at about 360-410 MB.
Not measured: several PDFs rendered at the same moment (the Processor renders one event at a time).

### Live payment: owner text and PDF document

`scripts\demo-payment.ps1` with a listener, `TELEGRAM_SEND_PDF=true`. Event `evt_1UWMrRFugmPRKro8af5GPRqX` ended `done` in 5 s, invoice `INV-2026-000037` (3000 eur, "Workshop: Automatisierung mit n8n", "Karte (Visa)"), side effects `email, telegram, telegram_document`, exactly 1 email in Mailpit with 1 PDF attachment.
From the execution data (execution 939; the chat details in Telegram's reply were not copied):

```
Telegram Text Input   <b>Zahlung eingegangen</b> / Betrag: 30,00 EUR / Kunde: Jenny Rosen / Zahlungsart: Karte (Visa) / Rechnung: INV-2026-000037 / Produkt: Workshop: Automatisierung mit n8n
Send Telegram Text    ok=true message_id=54
Restore PDF           mode=document caption="Rechnung INV-2026-000037"   binary Rechnung-INV-2026-000037.pdf, 32,364 bytes
Send Telegram Document ok=true message_id=55 file_name=Rechnung-INV-2026-000037.pdf file_size=32364
```

The document is exactly as large as the email attachment (32,364 bytes): the PDF crossed the sub-workflow boundary intact. That the message and the document looked right in the Telegram chat itself is the owner's confirmation, not something this repository can see.

### Gotenberg down: one text, no email, then done

Gotenberg stopped, one payment (`evt_1UWMspFugmPRKro8Qzhkk6cE`, `INV-2026-000038`), three Processor runs, then Gotenberg started again:

```
20:59:47  failed attempts=1 last_error=Render PDF (Gotenberg): getaddrinfo ENOTFOUND gotenberg | side_effects=telegram | emails for INV-2026-000038: 0
21:00:51  failed attempts=2 last_error=Render PDF (Gotenberg): getaddrinfo ENOTFOUND gotenberg | side_effects=telegram | emails: 0
21:01:23  docker start gotenberg
21:01:50  done attempts=3 last_error=NULL | side_effects=email,telegram,telegram_document | emails for INV-2026-000038: 1 | invoices 1 | 3 side_effect rows
```

- **Exactly two Telegram sends** for this payment: execution 954 (the text, during attempt 1) and 959 (the document, after the restart). Attempt 2 (execution 955) entered at `Telegram Already Sent?` and sent nothing.
- **The text in attempt 1** (execution 952) was the normal owner text plus the line `PDF fehlt: konnte nicht erstellt werden. Es wird erneut versucht.`, with no internal error text in it. `Send Invoice Email` did not run.
- Attempt 1 went `Render Problem -> Describe Failure -> Mark Failed`, so the row was `failed` with the real reason; nothing was skipped silently.

### TELEGRAM_SEND_PDF=false: no document, still done

n8n recreated with `TELEGRAM_SEND_PDF=false` from the shell only (`.env` untouched, restored afterwards). One payment (`INV-2026-000039`) ended `done` with side effects `email, telegram`, exactly one Telegram send (the text, execution 974) and 1 email that still carries the PDF.

### Resend and retry: nothing duplicated, the same document

- **Resend** of `evt_1UWMrRFugmPRKro8af5GPRqX`: Intake answered 200 (duplicate); after two Processor passes still `stripe_events rows=1, invoices=1, side_effects=email,telegram,telegram_document, emails=1`, and no new Telegram execution.
- **Retry after a simulated crash** (the email and document records removed, the event re-queued): execution 979 ran `Find Invoice -> Invoice Exists? -> Render Input`, so `Fetch Session` and `Create Invoice` did not run: no second Stripe call. The email went out again (at-least-once, by design), the document again (message 59, 32,364 bytes), the text was not repeated.
  The two PDFs have identical extracted text (793 characters, 1 page each) and the same size; the bytes differ only by the PDF's creation timestamp (`20:57:41` vs `21:07:39`), so "same document" means same content, not same bytes.

### Hostile customer name: literal in email, PDF and Telegram

A test row whose customer name is `<img src=http://n8n:5678/x onerror=alert(1)> Müller, "Max" & O'Brien` (a first attempt used a mis-encoded `ü` because Windows PowerShell 5.1 read my script as cp1252; the input was rebuilt from the code point and the run repeated):

- **Email HTML:** the escaped form `&lt;img src=http://n8n:5678/x onerror=alert(1)&gt; Müller, &quot;Max&quot; &amp; O&#39;Brien`, no raw `<img`. **Plain text:** the literal name.
- **PDF** (text extracted with pypdf): the literal name, one page.
- **Telegram** (execution 987): `Kunde: &lt;img src=http://n8n:5678/x onerror=alert(1)&gt; Müller, &quot;Max&quot; &amp; O&#39;Brien`, delivered (message 62, parse mode HTML would have rejected an unescaped tag) and the document delivered (message 63).
- Gotenberg's log shows 0 requests mentioning `n8n:5678`. Because the markup is escaped, no tag reaches Chromium at all; the page's own `Content-Security-Policy` (`default-src 'none'`) is a second layer that was not separately provoked.

### Stripe lookup fails: failed with a clear reason, nothing created

A test row whose payload points at a session that does not exist:

```
evt_test_badsession : failed attempts=1 last_error=The resource you are requesting could not be found: No such checkout.session: cs_test_doesnotexist0000000000 | invoices=0 side_effects=(none)
```

A 404 is not retried (only 429, 5xx and network-looking errors are). A real Stripe 429 or 5xx on this lookup was not provoked.
The first live run of the lookup had failed for a different reason: n8n serialised two `expand[]` query parameters as an object and Stripe answered 400; the query now sits in the URL. That same run also showed that `last_error` only held "Bad request - please check your parameters", so `Describe Failure` now keeps the error's description.
The redaction of `rk_`, `sk_`, `pk_`, `whsec_` and bot tokens in that text was proven against the code taken from n8n's own export (8 cases plus a control that leaks when the redaction lines are removed).

### The retry loop, proven in the engine

`Stripe Send Telegram` has one retry loop for the text and the document. A throwaway copy of it with a send step that always fails with a retryable error ("Bad gateway") was run in n8n (execution 914, archived afterwards):

```
Send (stub): 3 runs ("Bad gateway at try 1/2/3 (pdf on item: true)")   Backoff: 2,009 ms and 4,002 ms   Retryable? asked 3 times, the third said no   Failed: ok=false, problem="Telegram: Bad gateway at try 3 ..."
```

So: exactly 3 tries, 2 s then 4 s, and the PDF was on the item at every try. What this does not prove is Telegram itself returning 429 or 5xx.

### The Processor's Telegram wiring, all 384 cases

A simulator walks the real compiled Processor graph from `Render Input` to a terminal node, running the real node code and expressions, for every combination of already-done side effects (8), `TELEGRAM_SEND_PDF` (2), render outcome ok / PDF failure / data failure (3) and failing email, text or document send (8): 384 cases.
Invariants checked for all of them: a `done` event has everything required recorded; nothing is sent twice or after it was already done; every failure ends `failed` with a reason; a render problem never ends `done`; on a PDF failure the email and document are not sent but the text is (with the "PDF fehlt" line) when it is still pending; the PDF is on the item wherever it is sent; `include_pdf` is true exactly when a PDF is needed.
All hold. Five broken wirings (silent skips among them) were each caught. One accepted behaviour it exposed: if the PDF fails and the owner text send also fails, `last_error` names the Telegram failure and the PDF problem resurfaces on the next run.

### Invoice delivery checks, made to fail

`scripts/check-invoice-delivery.ps1` passes on the right payments and fails, with the intended line, on each wrong expectation: 2 attachments, a different subject, 3100 instead of 3000, another product, a document where none is expected, no document where one is expected, an invoice of another event.
It also flagged a real case: `INV-2026-000037` has 2 emails because of the crash simulation above. Building the demo trigger and its first live runs also showed that it needs a retry: Adaptive Pricing is on in the sandbox account and Stripe sometimes answers `checkout_amount_mismatch`.

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

Run from the invoice-design branch on 2026-10-31 after all changes (output trimmed to the summary):

```
== Summary ==
51/51 checks passed, 0 failed
```

51 = 49 + the SDK drift check and the docs check (below). The first run of this version aborted once, after the demo payment was stored, on a single `psql` call through WSL that returned exit -1 (`[FAIL] script aborted - psql failed (exit -1)`, 22/23); the stack was healthy right after, and the identical re-run passed 51/51. I never found a cause, so I call it a transient WSL failure, not a fixed bug.

49 = the 41 checks from M5, the stale-timestamp check (42), and 7 from the invoice work: the `gotenberg` container, migration 006, `INVOICE_EMAIL_FROM`, `TELEGRAM_SEND_PDF` being exactly true or false, and the delivery check (invoice row, exactly 1 email with exactly 1 real PDF, the Telegram document) after the first delivery, after the resend and after the Processor re-run.
The run also shows the demo payment's retry at work (`try 1 of 3: checkout_amount_mismatch (Adaptive Pricing), retrying`, then `fired (try 2 of 3)`). With Gotenberg stopped the preflight fails at once (`[FAIL] container 'gotenberg' running`, exit 1, nothing fired).

### SDK drift and docs checks, made to fail

Both are e2e checks (`scripts/check-sdk-drift.ps1`, `scripts/check-docs.ps1`). Each was made to fail once before it was trusted. Run on 2026-10-31 against the live stack.

Drift check, real tree (all 7 files match live), then an edited copy via `-SdkDir` (the Gotenberg timeout 35000 changed to 36000 in a temp copy of the render workflow; no live workflow was touched):

```
[PASS] stripe-render-invoice.sdk.ts : no differences from live (3dvdSRSD6ObBVsxy)      (and 6 more PASS lines, exit 0)
[FAIL] stripe-render-invoice.sdk.ts : differs from live (3dvdSRSD6ObBVsxy)
        DIFF  Render PDF (Gotenberg)
                parameters.options.timeout: file=36000 live=35000
exit 1
```

Docs check: a line limit of 50 gives `[FAIL] CLAUDE.md has 99 lines, limit is 50` (exit 1); a full temp copy of the docs is clean (exit 0), and appending one image link to a file that does not exist gives `[FAIL] README.md links to docs/img/does-not-exist.png, which does not exist` (exit 1); a known-missing entry for a file that exists gives `[FAIL] docs/img/telegram-invoice.png now exists: remove it from -KnownMissing` (exit 1). The real tree gave exit 0 with a WARN for each of the two screenshots the owner had still to add; those two README references were removed afterwards (they return with M6b), so the check now runs with no known-missing files and no warnings.

One bug in the docs check was found by running it: its relative path display used the wrong offset when the temp path was an 8.3 short name, so the failure message was garbled. Fixed, and the broken-link case re-run.

## M7a server

### Memory sizing

First VM, 1 OCPU, 6 GB, idle M7a stack with no workflows, `free -m` on 2026-11-01: 1,059 MB used of 5,901 MB (about 18%), 4,401 MB cache. That is under Oracle's 20% reclamation line if its metric ignores cache, so the rebuilt VM uses 1 OCPU, 4 GB.

Rebuilt VM, 1 OCPU, 4 GB, same stack: 1,016 MB used of 3,895 MB (about 26%) after the restore, and 928 MB (about 24%) after the reboot. Oracle reclaims only if CPU and network are under 20% as well.

### After 7 days

Read 2026-11-08, 7 days 2 hours after the rebuild, against Oracle's idle-reclamation rule (CPU P95, network and memory all under 20% for 7 days). Server snapshot at 12:25:52 (11:25:52 UTC):

```
Mem:  total 3895  used 1038  free 834  buff/cache 2236  available 2857
used without cache (MemTotal - MemAvailable): 26.7%   with cache (MemTotal - MemFree): 78.6%
n8n 503.3MiB   postgres 56.17MiB   gotenberg 47.89MiB   mailpit 28.57MiB   (CPU each under 0.3%)
load average 0.05, 0.09, 0.09 on 1 core
enp0s6 since boot: 487.7 MB received, 681.2 MB sent
```

OCI console, namespace `oci_computeagent`, 1-8 Nov, statistic P95 (read by the owner):

| Metric | Oracle | Under 20%? |
|---|---|---|
| `MemoryUtilization` | flat at about 25-26% all week | **No** |
| `CpuUtilization` | 2-4.5% | Yes |
| Network bytes in / out | cumulative, about 500 MB / 700 MB by 8 Nov (same as `enp0s6`); about 1.1 KB/s on average, roughly 0.001% of A1's 1 Gbit/s | Yes |
| Memory allocation stalls | 0 all week | - |

**Oracle's `MemoryUtilization` does not count page cache:** it matches the 26.7% without cache, not the 78.6% with it. So memory keeps the 4 GB VM above the line on its own, by about 6 points. n8n grew from 382 MiB on day 0 to 503 MiB. If the stack ever shrinks under about 800 MB used, the VM falls below 20% on all three; the rebuild drill is the answer then (no artificial load).

```
NAME        MEM USAGE / LIMIT   CPU %
n8n         382.2MiB / 1.5GiB   0.51%
postgres    39.95MiB / 512MiB   0.06%
gotenberg   7.887MiB / 512MiB   0.01%
mailpit     9.086MiB / 128MiB   0.00%
```

### Backup ping rotation

2026-11-08. A screenshot of the `m7-server-backup` check page showed its ping URL to a Claude session, so the URL was rotated the same way as M5 proof 7. No value was printed at any step.
- Before: Claude stored the sha256 of the current `BACKUP_HEARTBEAT_URL` in a mode-600 file on the server.
- Owner: renamed the old check `m7-server-backup-old`, created a new `m7-server-backup` (period 1 day, grace 6 h, email on), updated the Bitwarden item "M7 Healthchecks backup ping URL" and edited the server `.env` by hand.
- Claude, yes/no only: `.env` mode 600, one `BACKUP_HEARTBEAT_URL` line, an `https://hc-ping.com/` URL with no spaces or quotes, and its hash **differs** from the old one. The hash file was then shredded.
- One manual run at 13:12:09 (12:12:09 UTC):

```
uploaded automation-20261108T121209Z.dump.age (11593 bytes)
[PASS] backup finished, heartbeat pinged
exit 0
```

- The owner confirmed the new check is green with its last ping at 13:12 (12:12 UTC), then deleted the old check.
- The failure path needed no new test: a failed backup sends no ping (see "Checks, made to fail" below: Postgres stopped, and an unresolvable upload URL). The old URL cannot be tested once its check is deleted.

### Rebuild drill

All times Berlin (CET, UTC+1), 2026-11-01. The old VM was stopped first, so the new one could not lean on it, and terminated only after green. **About 38 minutes** from Stop to "stack healthy, restored counts match", including the owner's console work. M7a has no workflows: M7b re-runs the drill to "e2e green", and that number goes in the README.

| Time (UTC) | Event |
|---|---|
| 09:46 (08:46) | Old VM stopped, to the minute. Clock starts |
| 10:02:23 (09:02:23) | New VM booted from `infra/cloud-init.yaml`; it never had public SSH |
| 10:22:56 (09:22:56) | `bootstrap.sh` run twice: container ids and start times unchanged |
| 10:23:31 (09:23:31) | `server-restore.ps1` finished, from the nightly backup taken on the old VM |
| **10:23:46 (09:23:46)** | **All counts match, stack check green. Clock stops** |
| 10:24:07 (09:24:07) | `harden-ssh.sh` done, base check and SSH check green |
| 10:24:31 (09:24:31) | One reboot. SSH rule, `rpcbind` off, timer, containers and the marker row all survived, all checks green |

Before the restore the same check failed on the empty database, as it must:
```
[PASS] marker row evt_test_m7a_restore restored - 1 row
[FAIL] stripe_events: restored matches server - server= restored=1
exit: 1
```
After the restore:
```
[PASS] file is age-encrypted - age-encryption.org/v1
[PASS] decrypted and restored into a no-network throwaway - exit 0
[PASS] marker row evt_test_m7a_restore restored - 1 row
[PASS] stripe_events: restored matches server - server=1 restored=1
[PASS] side_effects: restored matches server - server=0 restored=0
[PASS] invoices: restored matches server - server=0 restored=0
[PASS] event_replays: restored matches server - server=0 restored=0
[PASS] invoice_number_seq: restored matches server - server=1/false restored=1/false
[PASS] upload URL cannot read an object - HTTP 404
[PASS] upload URL cannot list the bucket - HTTP 404
[PASS] no age private key on the server - 0 key files, 0 files with key text
[PASS] no plaintext dump on the server disk - 0 found
[PASS] backup timer active - active
check-offsite-restore exit: 0
```

### Checks, made to fail

| Check | Provoked with | Result |
|---|---|---|
| `check-public-ports.ps1 -Mode Tailnet` | First VM, before the SSH rule was deleted | `[FAIL] SSH to the public IP does not answer`, exit 1; a login through `<public-ip>` printed `m7-server`. Passed after the rule was deleted |
| `check-public-ports.ps1 -Mode Public` | No window given, and a window that has not opened | `FAIL`, exit 1, no nmap process started |
| `check-server-base.ps1`: user-data | First VM, after `infra/cloud-init.yaml` changed | `[FAIL] VM user-data equals the repository file`. Passes on the rebuilt VM |
| `check-server-base.ps1`: memory | The first 6 GB VM against the 4 GB default | `[FAIL] memory (GB) - 6.0` |
| `check-server-base.ps1`: iptables | Before `harden-ssh.sh` | `[FAIL] iptables: port 22 only on tailscale0 - 1 rule(s), 1 public` |
| `check-prod-stack.ps1`: listeners | The image's `rpcbind`, found by this check | `[FAIL] ... 0.0.0.0:111, [::]:111`. Fixed in cloud-init |
| `check-prod-stack.ps1`: ports, limits | Throwaway container with `-p 127.0.0.1:18999:8025` | `[FAIL] no container publishes a port`, `[FAIL] every container has a memory limit`, exit 1 |
| `check-prod-stack.ps1 -StaticOnly -ComposeFile` | Copies with `ports:`, `:latest`, no `mem_limit` | `FAIL`, exit 1 (also: compose refuses a missing `N8N_ENCRYPTION_KEY`) |
| `bootstrap.sh` | `.env` at mode 644 | `[FAIL] .env has mode 644, must be 600`, exit 1 |
| `harden-ssh.sh` | Session variable removed, so not "over Tailscale" | `[FAIL] this session did not come in over Tailscale, refusing`, exit 1, iptables unchanged |
| `backup-offsite.sh` | Postgres stopped | Exit 1, stopped at the dump, no upload and no ping |
| `backup-offsite.sh` | Unresolvable upload URL, temp copy with a fake `.env` | Exit 6, no ping |
| `check-offsite-restore.ps1` | One byte flipped | `age: error: failed to decrypt and authenticate payload chunk`, exit 1 |
| `check-offsite-restore.ps1` | Wrong key | `age: error: no identity matched any of the recipients`, exit 1 |
| `check-offsite-restore.ps1` | `-AddRowToRestored`, throwaway only | `[FAIL] stripe_events: restored matches server - server=1 restored=2`, exit 1 |
| `check-offsite-restore.ps1`: key, dump, timer | Fake files planted on the server (a made-up key, an empty `.dump`), timer stopped | `[FAIL] no age private key on the server - 1 key files, 1 files with key text`, `[FAIL] no plaintext dump on the server disk - 1 found`, `[FAIL] backup timer active - inactive`, exit 1. Green again after undoing |
| `check-server-base.ps1`: shape | `-ExpectedShape x` | `[FAIL] shape - VM.Standard.A1.Flex` |
| `check-public-ports.ps1`: parser | Not a scan of the server: nmap against the reserved test address 192.0.2.1 | All-filtered output is `Ports: <tab>Ignored State: filtered (100)`, one port is `18999/filtered/tcp`; both forms are what the parser reads. 100 filtered ports took 21 s, so the full scan may take well over 11 minutes |
| `server-restore.ps1` | Second restore onto the restored database | `[FAIL] the server's database is not empty`, exit 1 |

### Findings from the live VM

- **Port 22 on the first VM** was open from 12:16 (11:16 UTC) until between 13:02 and 13:05 (12:02-12:05 UTC) on 2026-10-31. SSH log: 5 logins, all by key, 3 over Tailscale and 2 from the laptop's tests, no password attempt, 1 outside probe with an empty username. The log starts at 12:29, so 12:16-12:29 is not covered. The rebuilt VM never had the rule.
- **`rpcbind`** came with the image and listened on all addresses. Nothing uses NFS, so cloud-init turns it off. The stack check only looked at TCP until then.
- **The check itself was wrong once:** OCPU and memory compared `1.0` with `1` as text, so they failed on a correct VM. They compare numbers now.
- **Nightly backup on the rebuilt VM** (read 2026-11-03, `journalctl -u backup-offsite`): both nights uploaded and pinged. Healthchecks.io's side was not looked at here.

```
2026-11-02T03:00:31+01:00 m7-server bash[92288]: uploaded automation-20261102T020030Z.dump.age (11593 bytes)
2026-11-02T03:00:31+01:00 m7-server bash[92288]: [PASS] backup finished, heartbeat pinged
2026-11-03T03:10:31+01:00 m7-server bash[220315]: uploaded automation-20261103T021030Z.dump.age (11593 bytes)
2026-11-03T03:10:31+01:00 m7-server bash[220315]: [PASS] backup finished, heartbeat pinged
```

- **Nightly backup, first 7 nights** (read 2026-11-08): the journal shows one `uploaded` and one `[PASS] ... heartbeat pinged` line for every night from 2 to 8 Nov, each object 11,593 bytes, between 03:00 and 03:13 (02:00-02:13 UTC; the timer is Persistent with a random delay). The OCI console lists the same 7 object names in `m7-backups`, plus the 31 Oct and 1 Nov objects from the first VM (9 in all, about 102 KiB). Healthchecks.io `m7-server-backup`: up, one OK ping for each of those nights, and status "All good" for October and November. One pause on 7 Nov 23:24 (22:24 UTC): the owner clicked this check by mistake while meaning to pause `stripe-pipeline` before `wsl --shutdown`; the next ping set it back to up. A paused check never alerts, and only a ping unpauses it: had that night's backup failed, the check would have stayed paused and silent. The 31 Oct object is the lifecycle test (from 15 Nov).

```
Nov 02 03:00:31 uploaded automation-20261102T020030Z.dump.age (11593 bytes)
Nov 03 03:10:31 uploaded automation-20261103T021030Z.dump.age (11593 bytes)
Nov 04 03:07:17 uploaded automation-20261104T020717Z.dump.age (11593 bytes)
Nov 05 03:12:41 uploaded automation-20261105T021241Z.dump.age (11593 bytes)
Nov 06 03:12:17 uploaded automation-20261106T021217Z.dump.age (11593 bytes)
Nov 07 03:06:59 uploaded automation-20261107T020659Z.dump.age (11593 bytes)
Nov 08 03:13:11 uploaded automation-20261108T021310Z.dump.age (11593 bytes)
(each followed by: [PASS] backup finished, heartbeat pinged)
```

## Safety guards

Recorded 2026-11-03. One pattern list, `scripts/lib/destructive-patterns.json` (10 patterns, each with a harmless `echo` sample), read by the helper guard (`scripts/lib/destructive-guard.ps1`, in `wsl-sh.ps1` and `server-sh.ps1`) and the PreToolUse hook (`scripts/hooks/destructive-guard.mjs`).

| Check | Run | Result |
|---|---|---|
| `node scripts/hooks/destructive-guard.test.mjs` | Real hook | `41/41 cases behaved`: every pattern blocked through `wsl bash -c` and through `wsl-sh.ps1 -Script`, plus direct docker, uppercase, after `&&`, `sudo`, `$( )`, a variable as the command word (`d=docker; $d volume rm`, the bypass shown on 2026-11-01), a script held in a variable, literal base64, a helper `-File` target. Allowed: a commit message or grep mentioning the words, `clean-test-event.ps1`, `docker ps`, harmless helper calls, e2e |
| same | Stub that allows everything / blocks everything | `11/41`, exit 1 / `30/41`, exit 1 |
| `scripts/e2e.ps1` wiring | `DESTRUCTIVE_GUARD_HOOK` = allow-all stub (`process.exit(0)`), 2026-11-03 | `[FAIL] destructive-guard hook: every pattern blocked, controls allowed - exit 1`, the only FAIL of 76 preflight steps (the `wsl-sh.ps1` step stayed PASS: it does not use the hook); e2e stopped at "Preflight failed", exit 1, before any payment. Its hint "Start the stack" is misleading for this cause |
| `destructive-guard.test.mjs --prove-failure` | Runs the suite against built-in allow-all and block-all stubs | `PASS allow-all ... 12/45`, `PASS block-all ... 33/45`, exit 0 (same counts as by hand). Seen failing: a scratch copy whose allow-all stub imports the real hook gives `FAIL allow-all stub makes the suite fail -> 45/45 cases behaved, exit 0`, exit 1 |
| `scripts/e2e.ps1` step for `--prove-failure` | Real run; then e2e from a scratch worktree whose allow-all stub imports the real hook | `54/54 checks passed`. Sabotaged: `[FAIL] destructive-guard test fails against allow-all and block-all stubs - exit 1`, the only FAIL (76 PASS), e2e stopped at preflight |
| `--prove-failure` vs a crashing suite (review finding on PR #11) | Temp copy without `destructive-patterns.json`: the suite throws before any case | Before: both stubs `PASS ... -> , exit 1`, exit 0 (a crash counted as caught). After requiring the last line `N/M cases behaved` with N < M: both `FAIL ... -> , exit 1`, exit 1. Real repo still `12/45` and `33/45`, exit 0; e2e 54/54 |
| `check-destructive-guard.ps1 -Target both` | Both helpers | 55 PASS: 10 patterns x (`wsl-sh` -Script, -File, piped; `server-sh` -Script, -File), each exit 3 with 0 output lines, and the `echo ok` control passes every route |
| same, `-ProveFailure` | Control expected refused | 3 `[FAIL] ... passes the control 'echo ok'`, exit 1 |
| Hook, live in the session | `wsl -d Ubuntu echo "drop table x"`; `wsl ... "echo <base64 only> \| base64 -d \| bash"` | Both blocked (`sql-drop`, `sql-delete-from`); `& scripts\wsl-sh.ps1 -Script 'echo ok'` ran |
| Helper, direct | `wsl-sh.ps1 -Script "echo start<newline>echo 'TRUNCATE x'"` | `destructive-guard refused: sql-truncate ...`, exit 3, and `start` was not printed: nothing was sent |
| Review finding: wrappers | Before the fix: `powershell -Command "... drop table x"`, `cmd /c "... TRUNCATE x"`, `powershell -File scripts\wsl-sh.ps1 -File <file with DROP>` | All three allowed (exit 0), `42/45`, exit 1. After treating `powershell`, `pwsh`, `cmd`, `iex` as wrappers: `45/45`; stubs `12/45` and `33/45`, exit 1 |
| Fail closed | Hook copy and `wsl-sh.ps1` copy without `destructive-patterns.json` | Hook: `docker ps` blocked, exit 2. Helper: `echo ok` refused, exit 3, 0 output lines |
| `check-docs.ps1` public-IP check | `-ExtraFile` holding a non-documentation public address; then `192.0.2.5` and `1.2.3.999` | `[FAIL] public IPv4 203.x.x.x in ...:1`, exit 1; then PASS. On its first run it found the one real hit, a version-string example in PLAN.md, since reworded |
| Regression | `check-server-base`, `check-prod-stack` through the guarded `server-sh.ps1` | 16/16 and 13/13 PASS |

Not covered, by design: text built at runtime, files one level down (`psql -f`), `Get-Content x \| powershell -File wsl-sh.ps1` in the hook (the helper still refuses it), the Docker socket, Python, MCP tools and n8n Postgres nodes. The hard boundary for the database is the M7b role without DDL rights.

## Not proven

- **Zero open ports by nmap from outside: pending Oracle's testing window.** Oracle requires a filed form, 5 business days' notice, and one test per service per calendar year. Until then the proof is indirect: the Security List has no TCP or UDP ingress rule, iptables ends in `REJECT`, and public SSH does not answer. UDP stays unproven by nmap either way (it reports `open|filtered`).
- A rebuilt VM gets a new public IP that the form does not list, so a scan of the M7b drill's VM needs a new form and possibly the next calendar year.
- That the bucket's lifecycle rule really deletes after 14 days: only the rule's existence was seen, by the owner.
- Checks never seen failing: "upload URL cannot read or list" (it would need a URL with read rights), `sshd: password login off` (the image already had it off) and the simple value lines of `check-server-base.ps1` (cloud-init, Docker, Tailscale, swap, timezone, log limits, unattended-upgrades). `sshd: root login off` was added after hardening; the first VM showed `without-password` before it.
- Telegram 429/5xx backoff against a real error. The retry code is in `Stripe Send Telegram` and Send Alert, but no real 429 or 5xx was ever provoked. The retry loop's mechanics were proven with a stub; a failing `sendDocument` call and a real Stripe 429/5xx on the invoice lookup were not provoked either.
- Several PDFs rendered at the same moment (memory gate), and Gotenberg under the memory cap with a much longer invoice.
- How the email looks in mail clients other than Mailpit: some (Gmail among them) strip inline SVG, so the logo may be missing there; the layout survives without it.
- Both alert channels failing at once.
- Two whole Processor runs racing (only the claim statement was).
- Whether the OLD Postgres password is rejected after rotation.
- A crash between a send and its `side_effects` insert, which can duplicate one message (at-least-once by design).
- Rotation of the Telegram token and `STRIPE_WEBHOOK_SECRET`.
