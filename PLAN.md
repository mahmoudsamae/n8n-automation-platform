# Plan

Pipeline: Stripe -> Intake -> `stripe_events` -> Processor -> Mailpit + Telegram.

| # | Milestone | Status |
|---|-----------|--------|
| M1 | Infra and storage: docker compose (n8n, postgres, mailpit), `stripe_events` table, `Postgres automation` credential | DONE |
| M2 | Stripe Intake workflow: signature check, classify, idempotent insert, 200/400/500 contract. Proven with stripe CLI, including DB-down 500 | DONE |
| M3 | Stripe Processor workflow (below) | BUILT and proven, awaiting review (real Telegram 429/5xx not provoked; see session notes) |
| M4 | Failure visibility: error workflow, alert when an event ends `failed`, safe way to replay a failed event | TODO |
| M5 | Hardening: secret rotation procedure, Postgres backup, live-mode checklist, runbook | TODO |
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
