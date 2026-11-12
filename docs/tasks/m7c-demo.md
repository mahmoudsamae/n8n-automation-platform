# M7c: visitor demo (spec)

Status: plan approved by the owner on 2026-11-12. Built PR by PR; each PR updates this status line. M7c-1 (this spec, README portfolio link) merged (PR #24). M7c-2 (migration 008, nightly reset, `check-db-role.ps1` for both roles) built, PR open. Design background: `docs/tasks/m7-server.md`; M7b: `docs/tasks/m7b-stack-tunnel.md`. Every claim marked **[VERIFY]** is checked in the M7c-3 spike and the result recorded here before code relies on it.

## Goal

A recruiter opens `https://invoice.mahmud-alhussen.de`, pays with Stripe's test card `4242 4242 4242 4242`, and within about 30 seconds sees **their own** result page: a timeline of the pipeline steps, the invoice PDF, a preview of the email (caught by Mailpit, never sent to a real address) and a preview of the owner's Telegram text. The demo stays closed to the public until the owner has filled the Impressum and Datenschutz pages.

## Owner decisions (2026-11-12)

1. **Telegram per visitor:** the owner gets the real text for each payment, with the name **masked** ("E. M.") by `Stripe Render Invoice` when the new `stripe_config` column `telegram_mask_name` is `true` (exactly `true`/`false`, no default, like `telegram_send_pdf`). Config, not a payment flag, because the renderer works from the invoice row alone and `metadata` is not on that row. Server: `telegram_mask_name = true`, `telegram_send_pdf = false` (no PDF to the owner per visitor).
2. **Limits:** 50 demo payments per Berlin day, 3 per IP per hour.
3. **Speed:** Intake starts the Processor right away for a new `pending` row; the 1-minute schedule stays as the safety net.
4. **Pages:** a small Caddy container `demo-web` serves the static pages from git.

## Architecture

```
visitor -> Cloudflare (WAF + rate limit) -> cloudflared
             POST /webhook/stripe-intake                       -> n8n (unchanged)
             / , /r , /impressum , /datenschutz , /assets/*     -> demo-web (Caddy, static files from demo/site/)
             POST /api/demo/(checkout|status|pdf|email)         -> demo-web -> n8n /webhook/demo-*
```

- **`demo-web`** (Caddy, pinned, arm64, `mem_limit 48m`, no `ports:`, fixed IP `172.30.0.12`). Why: `/` cannot be an n8n webhook (n8n's paths start with `/webhook/`), and static pages in git are reviewable and cost nothing. Caddy is the third allowlist layer (it proxies exactly four API paths) and sets the headers: a CSP without inline script, `X-Robots-Tag: noindex` on the legal pages, `Referrer-Policy: no-referrer`, frame-deny. An SSH tunnel to Caddy gives e2e the same origin a visitor gets, even while the demo is closed.
- **Outbound calls from the demo workflows:** Mailpit API 5 s timeout, 2 tries; the Render Invoice call (text only) has no retry (it reads the row and calls nothing outside); a failure returns a generic 502 to the page, which retries on its next poll.
- **Dynamic work stays in n8n:** new workflows `Demo Checkout` and `Demo Result` (status, PDF, email: three webhooks), each with the Error Handler as `errorWorkflow`, added to `scripts\lib\workflows.ps1`, the drift check and `check-error-workflows.ps1`.
- **Token:** 32 random bytes, base64url (43 characters), made in a Code node. Only `sha256(token)` is stored. It travels in the URL **fragment**: Stripe's `success_url` is `https://invoice.mahmud-alhussen.de/r#<token>`, so it never appears in a request line, a Cloudflare log or a Referer; the page sends it to the API in a POST body. [VERIFY Stripe accepts a fragment in `success_url`; fallback `/r/<token>`.]
- **About 30 seconds:** with the Processor on a 1-minute schedule the average wait alone is 30 s. Intake gets one node after its 200 response that starts the Processor without waiting (Execute Workflow, `waitForSubWorkflow: false`; the Processor gets an Execute Workflow Trigger next to its schedule). Intake stays fast, and the Processor's `FOR UPDATE SKIP LOCKED` claim already makes overlapping runs safe. Rejected: a 10 s schedule (8,640 executions a day; pruning would keep only hours of history).
- **No new copies of the data:** status = `demo_sessions` joined to `stripe_events` (checkout session id in the payload), `invoices` and `side_effects`. Email preview and PDF come from **Mailpit** (the message actually sent and its attachment: no Gotenberg render per click), found by the invoice number in the subject AND the recipient from the stored event payload (not `demo_email`, in case Checkout lets the visitor edit the address). The Telegram preview is `telegram_text` from `Stripe Render Invoice` (`include_pdf = false`), so the page and the real message cannot drift. The email HTML is shown in `<iframe sandbox srcdoc>` (no scripts, no same origin).

## Data and Stripe

- **Migration 008** (the owner runs it; `lint-migrations.ps1` enforces the grants):
  - `demo_sessions(token_hash bytea UNIQUE, checkout_session_id text UNIQUE NULL, demo_email text, ip_hash bytea, is_test bool, created_at)`; `n8n_app`: SELECT, INSERT, UPDATE (`checkout_session_id` only). Order in `Demo Checkout`: the limit check and the row reservation are ONE statement (so a refused request never calls Stripe), then the Stripe create, then the session id is written. A reserved row whose Stripe call failed keeps a NULL session id and counts against the limits (fail-safe direction).
  - `demo_limit_alerts(day date PRIMARY KEY)`: one owner alert per day when the cap is reached (`INSERT ... ON CONFLICT DO NOTHING RETURNING`); `n8n_app`: SELECT, INSERT.
  - Role `demo_reset`: LOGIN, no superuser, no DDL; `SELECT, DELETE` on `event_replays`, `side_effects`, `invoices`, `stripe_events`, `demo_sessions`, `demo_limit_alerts`; nothing else, no `TRUNCATE`, sequences untouched.
- **Checkout session**, created server-side in "New business sandbox": `mode=payment`, inline `price_data` 30,00 EUR "Demo-Rechnung", `customer_email = demo-<8 random hex>@demo.mahmud-alhussen.de` (no MX; mail only ever reaches Mailpit), `adaptive_pricing[enabled]=false` (the flaky `checkout_amount_mismatch`), `expires_at` +30 min, `metadata[demo]=true`, `billing_address_collection=auto`, no phone. The create call has a 10 s timeout, 2 tries on 429/5xx/network with 1 s backoff and `Idempotency-Key = hex(token_hash)`, so a retry cannot make a second session; any other 4xx is not retried and the page gets a generic 502. [VERIFY: `customer_email` locks the field; the `adaptive_pricing` parameter; the Processor's lookup works for `price_data` products with the read-only key.]
- **Credential `Stripe demo checkout`:** a restricted sandbox key with Checkout Sessions write only (the owner creates it). The read-only key stays the Processor's.
- **Name:** Checkout asks for the cardholder name. The landing page says "beliebiger Name, z. B. Erika Mustermann". It is the one visitor input that can be real; it lives until the nightly reset.

## Abuse limits

| Layer | Rule | When it is hit |
|---|---|---|
| Cloudflare rate limiting (free plan: 1 rule, 10 s period, 10 s block) [VERIFY] | more than 30 requests to `/api/demo/*` in 10 s per IP (status polling every 2 s plus PDF and email clicks in two tabs stay below it; the tight limits are the app's) | 429 from Cloudflare; the page says "kurz warten" |
| App, per IP | 3 checkout sessions per hour per `HMAC(CF-Connecting-IP, salt)` (salt in the crypto credential `Demo IP salt`; no raw IP stored) | 429 `{"reason":"ip_limit"}` |
| App, per day | 50 sessions per Berlin day, checked and inserted in ONE statement under `pg_advisory_xact_lock` (no race) | No Stripe call; 429 `{"reason":"daily_limit"}`; the landing page says "Tageslimit erreicht, ab 0 Uhr wieder" with links to the repo; the owner gets ONE Telegram alert that day |
| App, input | no `CF-Connecting-IP` header: 400. A `192.0.2.0/24` value (TEST-NET-1) marks e2e: limited per IP, not counted in the daily cap. Only the tailnet can send one, because Cloudflare overwrites the header [VERIFY; if it does not, the exemption is dropped and e2e counts against the cap] | |
| Kill switch | the WAF rule `m7-demo-closed` | demo off in one click |

So at most 50 Stripe sessions, 50 PDFs and 50 Telegram texts per day.

## Nightly reset (server, systemd)

- `infra/demo-reset.sh`, `infra/demo-reset.sql`, `demo-reset.service` and `.timer` (02:30 Berlin, `Persistent=true`, `TimeoutStartSec=5min`), installed by `infra/bootstrap.sh` like the backup timer. Runs `docker exec -i postgres psql -U demo_reset -v ON_ERROR_STOP=1` with the SQL file on stdin.
- One transaction. The `event_id`s are chosen once (`received_at` older than 5 minutes and status `done`, `failed` or `ignored`) and every table is deleted by that set, in FK order `event_replays`, `side_effects`, `invoices`, `stripe_events`; then `demo_sessions` and `demo_limit_alerts` older than 5 minutes. Choosing per table by its own timestamp would hit RESTRICT (an old event with a newer invoice) and roll back every night. Guards in the SQL: abort, nothing deleted, if any payload has `livemode = true` or any row is `pending` or `processing` (the next night retries; the missing success ping and the Monitor alert a human). Counts before and after go to the journal. Then Mailpit is cleared (`DELETE /api/v1/messages` from a throwaway `curl` container on the compose network). `invoice_number_seq` is kept.
- Pings its own Healthchecks check `m7-demo-reset` only after success (the owner creates it; the URL sits in a root-only file and is never printed).
- **The guards are not touched:** the SQL is in a file that only systemd runs. Nothing goes through `wsl-sh.ps1` or `server-sh.ps1`, so the guards never see its `DELETE FROM` and get no exception. A manual run for proofs is `sudo systemctl start demo-reset.service` (no destructive text). Honest limit: local connections inside the postgres container are trusted, so the role limits privileges (a script bug cannot drop or touch other tables); it is not authentication.
- 02:30 is before the 03:00 offsite backup, so each encrypted backup holds at most about 30 minutes of visitor data.

## Tunnel, WAF and the go-live switch

- `infra/cloudflared.yml` adds `^/(|r|impressum|datenschutz)$`, `^/assets/[a-z0-9.-]+\.(css|js|svg|woff2)$` and `^/api/demo/(checkout|status|pdf|email)$`, all to `http://demo-web:80`. The Intake rule and the catch-all 404 stay.
- The WAF rule `m7-invoice-allowlist` is edited by the owner to allow `POST /webhook/stripe-intake`, `GET` on the page paths and assets, and `POST /api/demo/*`; everything else stays 403.
- **New WAF rule `m7-demo-closed`, first in the list: 403 for every demo path. The go-live switch is toggling `m7-demo-closed` Off;** On again is the kill switch.
- `check-tunnel-allowlist.ps1` gains `-Demo Closed|Open`. Closed: every demo path gets the WAF 403. Open: pages 200, `/api/demo/*` reach Caddy. Both: the editor, `/rest`, `/api/v1`, `/webhook/demo-*` called directly, other methods, traversal and encoded aliases of the new paths are 403. Seen failing: `-Demo Open` while closed, and `-Demo Closed` with the rule off.
- Go-live, only on the owner's word: the owner's Impressum and Datenschutz PR merged, `check-legal-pages.ps1` passes on the public URL, `-AllowMarkers` removed from e2e, `m7-demo-closed` toggled Off, `check-tunnel-allowlist.ps1 -ExpectWaf -Demo Open` passes, one real visitor run from the owner's phone.

## GDPR (not legal advice; the owner has the texts checked, e.g. with a generator such as e-recht24 or a lawyer)

- **Data minimisation:** a prefilled fake email, the test card only, no cookies, no localStorage, no analytics, self-hosted fonts, the token only in the fragment, the IP only as a salted HMAC, the name masked in Telegram, no PDF to Telegram.
- **Retention:** database rows and Mailpit until the nightly reset (02:30). n8n execution data: on the server every workflow that sees visitor data (Intake, Processor, Render Invoice, Send Telegram, the demo workflows) saves no successful executions, and `EXECUTIONS_DATA_MAX_AGE` goes from 168 to 48 h, so error executions keep data for at most 48 h of triage. Encrypted backups 14 days, each holding only the window before 03:00. Cloudflare under its own policy. **Stripe keeps the test payment (with the typed name) in the owner's sandbox; the reset cannot delete Stripe objects.** The Datenschutz page says so.
- **The Datenschutz page must cover:** the controller (name, address, email); purpose (portfolio demo) and legal basis (Art. 6(1)(f) GDPR); data categories (IP at Cloudflare and in n8n error logs, the typed name, the generated demo email, Stripe test payment data); recipients: Cloudflare (WAF and tunnel, US, Data Privacy Framework), Stripe (Checkout in test mode, its own cookies on its own domain, keeps the test payment in the sandbox), Oracle Cloud (hosting, Frankfurt), Telegram (owner notification with the masked name); retention as above; no cookies, so § 25 TDDDG consent is not needed; rights under Art. 15-21 and 77 GDPR with the supervisory authority of the owner's state; links to GitHub and the portfolio are external.
- **Impressum (§ 5 DDG):** name, registered address, email, a second fast contact channel. Both pages `noindex` (meta tag and header) and linked in every footer. Claude writes them with `[[AUSFÜLLEN: ...]]` markers; `scripts\check-legal-pages.ps1` fails while any marker remains. That check is the gate before go-live.

## Pages

- `/`: German first, English second; three sentences on what the system does, the pipeline diagram, the button "Demo-Zahlung starten", the test card with "beliebiges Datum in der Zukunft, beliebige CVC", links to the GitHub repo and `https://mahmud-alhussen.de`, footer with Impressum and Datenschutz.
- `/r#<token>`: timeline (Checkout erstellt, Zahlung bei Stripe, Webhook geprüft und gespeichert, Verarbeitung, Rechnung INV-..., E-Mail (Mailpit), Telegram, fertig), polling every 2 s for at most 3 minutes, then "dauert länger" with the current status. PDF download, email preview, Telegram preview. A `failed` event shows a fixed German message, never `last_error`. After the reset: "Demo-Daten wurden zurückgesetzt".

## PRs (each: automation-review first, PR open, the owner merges)

| PR | Content | Owner actions |
|---|---|---|
| M7c-1 | README portfolio link `https://mahmud-alhussen.de`; this spec; PLAN.md row | Repo homepage (About) |
| M7c-2 | Migration 008 and lint; reset script, SQL, units, bootstrap; reset proofs with seeded rows | Run 008; create Healthchecks `m7-demo-reset` |
| M7c-3 | Spike for every [VERIFY]; `Demo Checkout`, `Demo Result`, Intake start of the Processor, Processor trigger, name mask in Render Invoice; `.sdk.ts` exported; drift and errorWorkflow checks extended | Restricted key and credentials `Stripe demo checkout`, `Demo IP salt`; `stripe_config` gets `demo_daily_limit`, `demo_ip_hourly_limit`, `telegram_mask_name`; server `telegram_send_pdf = false`, `telegram_mask_name = true` |
| M7c-4 | `demo-web`, pages, legal pages with markers; cloudflared paths; `check-tunnel-allowlist.ps1 -Demo`; `check-legal-pages.ps1` | WAF rule `m7-demo-closed` (On), the edited allowlist rule, the rate limiting rule |
| M7c-5 | Visitor e2e (Playwright), limit and token checks, memory measurement, evidence, runbook, CLAUDE.md (stays at most 100 lines) | none |
| M7c-6 | Go-live, after the owner's legal-pages PR | Toggle `m7-demo-closed` Off |

## e2e (server target); each new check is seen failing once

1. `check-demo-visitor-flow` (Node and a pinned Playwright in `scripts/visitor-flow`, like `sdk-drift`): landing, button, Stripe Checkout, 4242, success redirect, result page. While closed it rewrites the public origin to the SSH tunnel to Caddy and sends a TEST-NET `CF-Connecting-IP`. Asserts: timeline done within 60 s (time printed and recorded), the PDF starts with `%PDF-` and shows the invoice number, the email subject is `Ihre Rechnung INV-...`, the Mailpit recipient ends in `@demo.mahmud-alhussen.de`, the Telegram preview has the amount and the masked name. Fail once: `-ExpectedAmountCents 3100`.
2. `check-demo-limits`: 4 requests from one TEST-NET IP give 3 sessions and then 429 `ip_limit`; no header gives 400. Daily cap: the exact SQL from the `.sdk.ts` against a throwaway Postgres without network, migrations 001-008 applied (limit 2: the third is refused; two parallel sessions cannot both take the last slot). Fail once: a wrong expected limit. The live daily-cap 429 is proven once by lowering `demo_daily_limit` (evidence, not e2e).
3. `check-demo-tokens`: a random token gets 404 with the generic body; no row holds a plaintext token; the token of a reset session gets "zurückgesetzt". Fail once: expect 200.
4. `check-tunnel-allowlist.ps1 -Demo Closed|Open` (above) and `check-legal-pages.ps1` (markers, noindex meta and header, footer links; it fails by design until the owner fills the pages, so e2e passes `-AllowMarkers` until go-live).
5. `check-demo-reset` (not in e2e, it deletes): seeded `evt_test_` rows and a demo session, `systemctl start`, rows gone, sequence kept, counts in the journal. Guard proofs: a `processing` row and a `livemode = true` payload each abort with no row deleted; the role cannot DROP, TRUNCATE or read other tables.

## Memory

`measure-n8n-memory.ps1`, `free -m` without cache and `docker stats`: idle before, idle after, and during 10 visitor flows. Pass: the memory Oracle measures stays above 22 %, every container's peak below 75 % of its `mem_limit`, 0 OOM kills (`check-prod-stack.ps1` also covers `demo-web`). Recorded in `docs/evidence.md`.

## Definition of done

Server e2e green with its summary line shown; every new check seen failing once; one reset by the timer at 02:30 seen in the journal; memory recorded; legal pages filled by the owner; go-live toggled by the owner; one visitor run from outside on the owner's phone in about 30 s.
