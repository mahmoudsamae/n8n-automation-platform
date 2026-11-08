# M7b: stack and tunnel (spec)

Status: plan approved by the owner on 2026-11-08. Built PR by PR; each PR updates this file's status line. M7b-1 merged (PR #16). M7b-2 built and proven 2026-11-08 (PR open). Design background: `docs/tasks/m7-server.md`.

## Goal

The invoice pipeline runs on the M7a server (`m7-server`) and receives Stripe sandbox webhooks at `https://invoice.mahmud-alhussen.de`. The laptop stack is no longer needed.

## Order, and why

Public traffic comes last. The tunnel opens only when three things are in place: containers cannot reach the metadata service, n8n uses a database role without DDL rights, and workflows cannot read the environment. The env-access redesign is built and proven on the laptop first, where the n8n MCP, e2e and `stripe listen` already work. The `.sdk.ts` files are shared, so the server then imports workflows that are already proven.

No rebuild drill before the Oracle scans are done (window 17-26 Nov 2026): a rebuilt VM gets a new IP that the filed form does not list.

## Owner decisions (2026-11-08)

- Config that workflows read today through `$env` moves into an **n8n Data Table** (`stripe_config`). It is n8n-internal, so the heartbeat still works while Postgres is down.
- **Locally-managed tunnel**, with its ingress rules in git (`infra/cloudflared.yml`).
- **Cloudflare WAF custom rule is required** as a second layer, with its own fail-once proof.

## PRs and acceptance criteria

Every new check is seen failing once and then passing, and the runner's summary line is required, not only its exit code. No secret is printed. The public IP is written as `<public-ip>`.

### M7b-1: metadata service blocked (built, proofs in `docs/evidence.md`)
- `infra/imds-block.sh`, run by `infra/docker-imds-block.service` after Docker:
  - Its own chain `M7-IMDS`, hooked first into `DOCKER-USER`: DNS (53) to `169.254.169.254` is allowed, everything else to `169.254.0.0/16` is rejected.
  - Idempotent; restarted with Docker (`PartOf`). It never touches `rules.v4` or the host's own 169.254 rules, and never runs `iptables-restore`.
  - Installed by `infra/bootstrap.sh`.
- `scripts/check-imds-blocked.ps1`:
  - Metadata v1 and v2 blocked from the n8n container, from a throwaway container on `m7_default` and from one on the default bridge.
  - Controls: the host still reaches the metadata service; DNS works; HTTPS out works.
  - Hook present, unit enabled.
- Fail once: unhook the chain. The check FAILs; `systemctl restart docker-imds-block` makes it PASS. The rule must also survive a Docker restart and a VM reboot.
- Known window: on boot, containers with a restart policy start with Docker, a few seconds before this unit runs.

### M7b-2: Postgres role `n8n_app` (built, proofs in `docs/evidence.md`)
- `migrations/007_n8n_app_role.sql`, run by the owner:
  - LOGIN, no superuser, no createdb, no createrole, no password in the file.
  - As built, from the workflows' SQL: `stripe_events` SELECT/INSERT/UPDATE, `side_effects` and `invoices` SELECT/INSERT, USAGE on the two column-default sequences, nothing on `event_replays`. No DELETE, no TRUNCATE.
  - `automation` keeps ownership, so `n8n_app` cannot ALTER or DROP anything.
- `scripts/check-db-role.ps1`: catalog checks plus a TCP login test.
- Fail once: the owner grants TRUNCATE on one table and the check FAILs; revoke, then PASS. The owner also attempts the negative DDL by hand as `n8n_app`, which must show `permission denied`.
- `lint-migrations.ps1` fails when a new table gets no grant to `n8n_app`.

### M7b-3: env access blocked (laptop first)
- Intake verifies the signature with the Crypto node (HMAC SHA256), using credential `Stripe webhook secret` of type `crypto`, plus a `timingSafeEqual` compare. The 200/400/500 contract is unchanged.
- Data Table `stripe_config` holds `HEARTBEAT_URL`, `TELEGRAM_CHAT_ID`, `ALERT_EMAIL_TO`, `ALERT_EMAIL_FROM`, `INVOICE_EMAIL_FROM` and `TELEGRAM_SEND_PDF`.
  - A missing or invalid value still makes the event `failed` with a clear `last_error`; no defaults.
- Compose:
  - `N8N_BLOCK_ENV_ACCESS_IN_NODE=true`.
  - n8n's environment no longer holds the secrets or the config.
  - On the server, `N8N_ENCRYPTION_KEY` arrives through `N8N_ENCRYPTION_KEY_FILE` (a compose secret).
  - `.env` keeps `STRIPE_WEBHOOK_SECRET` for the host-side test scripts only.
- Proof:
  - A throwaway workflow tries `$env`, `process.env`, `require('fs')` and `require('child_process')`, and all are denied.
  - `scripts/check-n8n-env.ps1`, names only.
- Fail once: the block flag set to false; one Data Table value removed (the event ends `failed`); a wrong HMAC secret (the event gets 400). e2e green on the laptop.

### M7b-4: `-Target Laptop|Server` for e2e and the scripts
- `scripts/lib/target.ps1`.
- In server mode, e2e opens its own SSH tunnel on ports 15678 (n8n) and 18025 (Mailpit).
- No `stripe listen` there. The bad-signature and stale-timestamp tests go to the public URL.
- The backup checks read the `backup-offsite` journal.
- The laptop mode stays the default and stays green.

### M7b-5: stack, tunnel, Stripe (goes public)
- `cloudflared` (`2026.10.7`, 128m). Ingress allows only path `^/webhook/stripe-intake$` on the host; everything else gets 404.
- n8n settings: `WEBHOOK_URL`, `N8N_PROXY_HOPS=1`, `N8N_PUBLIC_API_DISABLED=true`, `N8N_EDITOR_BASE_URL`.
- Workflows imported with their ids kept. Credentials are new on the server; laptop secrets are never copied.
- `scripts/check-tunnel-allowlist.ps1`, run from outside:
  - Editor, REST, MCP, `webhook-test`, other webhooks, Mailpit and traversal variants are refused.
  - A bad-signature POST gets 400.
- Two layers, told apart by status code:
  - cloudflared answers 404. Fail once with a catch-all config.
  - The WAF rule `m7-invoice-allowlist` answers 403. Fail once by disabling the rule; `-ExpectWaf` FAILs while the cloudflared check still passes.
- A separate Stripe sandbox endpoint and signing secret, subscribed to two event types only.
- Healthchecks check `m7-server-n8n` (period 5, grace 10). Fail once: stop n8n for about 16 min.
- Done when e2e `-Target Server` is green with a real event arriving through Cloudflare.

### M7b-6: n8n data in the offsite backup
- The nightly backup adds `export:workflow`, `export:credentials` (encrypted) and the Data Table, sent through `age` and uploaded. The ping fires only after both uploads.
- Restore drill into a throwaway n8n on the laptop.
- Fail once: a wrong encryption key; a tampered `errorWorkflow`; a failing export step (no ping).

### M7b-7: memory, cutover, review
- Measure idle and during PDF renders. Oracle P95 after 7 days.
- `check-prod-stack.ps1 -MinUsedPercent 22` (Oracle reclaims below 20%) and the sum of `mem_limit` at most 75% of RAM.
- e2e defaults to the server; CLAUDE.md updated; the laptop stack is stopped by the owner.
- `automation-review` SHIP.
- After 26 Nov: the rebuild drill to "e2e green", whose number goes in the README.
