# M7 — Public demo server (design spec)

Status: design, not built. Owner decisions marked **[OWNER]**. Every claim marked **[VERIFY]** must be checked against the live system or the official doc before it is relied on, and the result recorded in `docs/evidence.md`.

## Goal

A recruiter opens one link, pays with a Stripe test card, and sees their own invoice (email preview, PDF, Telegram preview) within about 30 seconds. The server costs 0 EUR, can be destroyed and rebuilt from this repository in a measured time, and exposes **zero inbound ports** on its public IP.

## Phases (each its own PR, each ends with `automation-review`)

- **M7a — Foundation (this spec, build first):** VM, cloud-init, private admin access, Docker, hardening, offsite encrypted backups, rebuild drill. No public traffic yet.
- **M7b — Stack and tunnel:** move the existing stack, Cloudflare Tunnel with a path allowlist, a separate Stripe sandbox webhook, e2e on the server.
- **M7c — Demo experience:** landing page, checkout, per-visitor result page behind an unguessable token, rate limits, nightly reset, Impressum/Datenschutz.

## Core design decisions

### 1. Zero inbound ports

- The OCI Security List has **no TCP or UDP ingress rules** for the public internet (delete the default SSH 22 rule after bootstrap). The default ICMP rules stay: they carry path-MTU signals and open no port. Optional: UDP 41641 for direct Tailscale connections; without it Tailscale still works through relays.
- Admin access (SSH, n8n editor, Mailpit UI) only over **Tailscale**. Public traffic only through **cloudflared**, which dials out. Nothing listens on the public IP.
- Why: removes the two classic Oracle blockers (Security List and the Ubuntu image's own iptables rules) instead of fighting them, and removes the whole SSH brute-force surface.
- Docker publishes ports past UFW (Docker docs: packets are routed before the firewall rules apply). Therefore: **no `ports:` on any service** in the production compose file. cloudflared reaches n8n over the Docker network. Admin UIs are reached with an SSH tunnel over Tailscale to a fixed container IP (`ssh -L 5678:172.30.0.10:5678`). A bind to the Tailscale IP was rejected: it contradicts "no `ports:`" and fails at boot if Tailscale is not up yet.
- **No UFW.** Oracle: using UFW on an Ubuntu image "might cause an instance not to boot". Host rules go in `/etc/iptables/rules.v4`; the 169.254 rules are never touched.
- Proof required: `nmap -Pn` against the public IP from outside (e.g. from the laptop off-tailnet) shows every port closed or filtered. A check that runs on the server itself does not count.
- Oracle's testing rules (owner read them, 2026-10-31): file the Oracle Cloud Security Testing Request Form by email to `security_test_notification_grp@oracle.com`; testing may start 5 business days after submission; non-aggressive; each service at most once per calendar year, at most 10 consecutive days. Section E is limited to resources in the owner's tenancy. No nmap against the public IP outside that window.
- The form lists target IPs, and a rebuilt VM gets a new one. So: **file after the rebuild drill, with the surviving VM's IP**, and run both scans in that window. Failing case first: a temporary listener on a test port, reachable only from the listed source IP, reported open. Then remove it and run the final all-port scan. Port 22 is never reopened for a test: it closes minutes after the VM joins the tailnet.

### 2. Right-size the VM against idle reclamation

- Oracle may reclaim an Always Free VM when, over 7 days, CPU p95 < 20% **and** network < 20% **and** (A1 only) memory < 20%. All three must be true.
- The stack uses about 2 GB. On a 12 GB VM that is under 20% memory; on a **1 OCPU / 6 GB** VM it is about a third. So: shape `VM.Standard.A1.Flex`, **1 OCPU, 6 GB**. This also leaves half of the free allowance for a second VM later.
- **[VERIFY, needs the server]** how Oracle measures memory utilization (with or without page cache). Oracle's doc says only "Measured by pages... percentage of used pages". Enable the Oracle Cloud Agent monitoring plugin, compare `MemoryUtilization` with `free -m`, and record the metric after 7 days.
- No artificial CPU or network load. If reclamation still happens, the rebuild drill (below) is the answer, and Hetzner CX23 is the fallback.

### 3. Rebuild from the repository

- `infra/cloud-init.yaml`: user, SSH key, packages, Docker Engine from Docker's apt repo, Tailscale, unattended-upgrades, swap file, journald and Docker log limits, timezone Europe/Berlin.
- `infra/bootstrap.sh`: idempotent, safe to run twice. Runs from a clone the owner made with a per-VM read-only deploy key (the repo is private, and a script cannot clone the repo it lives in): checks the `.env` exists with mode 600, `git pull --ff-only`, `docker compose up -d`, installs the backup timer, reports whether the database is empty. It does not restore: the server cannot decrypt the backups (section 5), so the laptop decrypts and streams over SSH with `scripts/server-restore.ps1`.
- `docker-compose.prod.yml`: standalone, not an override. The dev file is not in the repository, and merged `ports` append, so each would need `!reset`. No published ports, cloudflared service added later in M7b, `mem_limit` on every service.
- `infra/env.example` lists every variable name with no values. (Not `.env.example`: the owner's permission rules deny Claude any `.env.*` file, which is the right default, so the template gets a name outside that pattern.)
- **Rebuild drill:** **stop** the old VM (a terminate followed by "out of host capacity" would leave no VM), create a new one from cloud-init, restore, terminate the old one only after green. The clock starts at Stop. M7a records the minutes to "stack healthy, restored counts match" in `docs/evidence.md`. e2e needs workflows and a Stripe webhook, so M7b re-runs the drill to "e2e green" and **that** number goes in the README.
- Terraform for the VM and network is a later follow-up, not part of M7a.

### 4. Secrets

- No secret in the repository, in cloud-init, or on a command line.
- One exception, deliberate: the Tailscale auth key in cloud-init. Cloud-init user-data is readable by any process on the VM through the instance metadata service, so the key must be **one-off, non-reusable, with the shortest expiry the console allows: 1 day** (Tailscale's range is 1 to 90 days). It is revoked on first use, so after first boot it is worthless; confirm that on the Keys page.
- `.env` is written on the server over Tailscale by the owner, mode 600.
- `N8N_ENCRYPTION_KEY` is set explicitly in `.env` and stored in Bitwarden. Without it n8n generates one inside its data volume. **The key alone does not save credentials on a rebuild:** they live in the `n8n_data` volume, which is not backed up. No loss in M7a (no workflows); M7b must back up the n8n export too.
- Separate secrets per environment: the server gets its own Stripe webhook endpoint and signing secret (M7b), its own Healthchecks check, its own Telegram chat if wanted. Laptop secrets are never copied to the server.

### 5. Backups that survive the server

- Nightly `pg_dump` piped straight into **age** using a public key on the server, so plaintext never touches the disk (no `postgres-backup` service on the server). The private key lives only on the owner's laptop and in Bitwarden, so a compromised server cannot read old backups.
- Upload to OCI Object Storage with a write-only pre-authenticated URL: no CLI and no OCI credential on the server, only `curl`. Free limits checked 2026-10-31: 20 GB combined after the trial, 50,000 API requests per month. Weakness: a closed Oracle account loses the backups too. Acceptable for demo data; move backups to R2 before real data (PLAN.md).
- Retention: 14 daily. Restore drill into a throwaway container, row counts compared, recorded in evidence. Same rule as before: a backup that was never restored does not count.

### 6. Observability

- Existing Healthchecks heartbeat, a second check for the server.
- An outside uptime check on the public demo URL (M7b).
- The OCI budget alert (already active, 1 EUR, 1%).
- `docker stats` snapshot and `free -m` in the evidence after the stack runs, so the memory sizing is proven, not guessed.

## Architecture compatibility (ARM64)

- Checked with `docker manifest inspect` on 2026-10-31, all have arm64: `n8nio/n8n:2.45.6`, `postgres:17.11-alpine`, `axllent/mailpit:v1.32.0`, `cloudflare/cloudflared:2026.10.7`, `gotenberg/gotenberg:8.39.0-chromium`. Pin every image to a version, never `latest`.

## n8n settings for the server (M7b)

- `WEBHOOK_URL` = the public demo hostname, `N8N_PROXY_HOPS=1`, `N8N_EDITOR_BASE_URL` = the Tailscale address.
- `N8N_PUBLIC_API_DISABLED=true`.
- The tunnel forwards only an allowlist of paths: the Stripe webhook path and the demo pages. Everything else returns 404 at Cloudflare, so the editor is not reachable from the internet even by URL.

## Owner actions (Claude never does these)

- **[OWNER]** Create the VM in the OCI console with the cloud-init file, after the plan is approved.
- **[OWNER]** Create a free Tailscale account and the single-use auth key.
- **[OWNER]** Write the server's own `.env` on the server, from Bitwarden. Nothing from the laptop's `.env`.
- **[OWNER]** Remove the SSH ingress rule after Tailscale access works.
- **[OWNER]** Domain for M7b: an existing domain moved to Cloudflare DNS, or a new one. Without a domain, Tailscale Funnel gives a free `ts.net` HTTPS URL as a fallback.
- **[OWNER]** Never click Upgrade or Pay As You Go in OCI. Every created resource must show "Always Free-eligible"; trial-credit resources are reclaimed after 30 days.

## Known risks

- "Out of host capacity" for A1 in Frankfurt: try each availability domain, then retry off-peak. No scripts that hammer the API.
- Oracle can close Always Free accounts or reclaim instances; the rebuild drill and the Hetzner fallback cover it.
- A public demo in Germany may need an Impressum and a privacy notice, because visitors type an email into Stripe Checkout. To be checked in M7c (not legal advice). Nightly reset deletes visitor data.

## Definition of done for M7a

- VM running, created from `infra/cloud-init.yaml`.
- Public IP: zero open ports, proven by `nmap` from outside.
- SSH only over Tailscale; the Security List SSH rule removed.
- Stack running from `docker-compose.prod.yml` with no published ports; memory measured.
- Encrypted backup uploaded off the VM and restored once.
- Rebuild drill done, time recorded.
- `docs/runbook.md` has a "Server" section; `automation-review` says SHIP.

## Sources

- Oracle, Always Free Resources: https://docs.oracle.com/en-us/iaas/Content/FreeTier/resourceref.htm
- Oracle, Free Tier: https://docs.oracle.com/iaas/Content/FreeTier/freetier.htm
- Tailscale on Oracle Cloud: https://tailscale.com/kb/1149/cloud-oracle/
- Docker and UFW: https://findstack.com/resources/ufw-not-blocking-docker-ports
- n8n deployment environment variables: https://docs.n8n.io/hosting/configuration/environment-variables/deployment
- n8n webhooks separated from the editor: https://itnext.io/separate-and-protect-n8n-webhooks-and-mcp-endpoints-from-the-login-ui-f0a6e29ca86f
- Gotenberg installation: https://gotenberg.dev/docs/getting-started/installation
