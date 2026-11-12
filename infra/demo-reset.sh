#!/bin/bash
# Nightly demo reset (M7c-2, docs/tasks/m7c-demo.md): deletes the demo data older than 5 minutes, clears Mailpit, then pings Healthchecks.
# Run by demo-reset.timer (02:30 Berlin, before the 03:00 offsite backup, so each backup holds at most ~30 minutes of visitor data).
# By hand, for a proof: sudo systemctl start demo-reset.service, then journalctl -u demo-reset.service. Never through wsl-sh.ps1 or
# server-sh.ps1: the destructive guards refuse the statements in infra/demo-reset.sql there, by design, and get no exception for it.
# Exit 0 = deleted, Mailpit cleared, pinged. Non-zero = see the journal; no ping, so Healthchecks alerts after its grace time.
# The ping URL is a secret: it goes to curl through stdin (--config -), never on a command line, and is never printed.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

heartbeat_url="$(grep -m1 '^DEMO_RESET_HEARTBEAT_URL=' "$repo/.env" | cut -d= -f2-)" || true
[ -n "$heartbeat_url" ] || { echo "[FAIL] DEMO_RESET_HEARTBEAT_URL is empty or missing in .env" >&2; exit 1; }

# As demo_reset: SELECT and DELETE on six tables, nothing else (migration 008). -X ignores any psqlrc. The SQL rolls back on any error.
docker exec -i postgres psql -X -U demo_reset -d automation -v ON_ERROR_STOP=1 < "$repo/infra/demo-reset.sql"

# Mailpit has no published port and its busybox wget cannot send DELETE, so the request goes from the n8n container's node over the
# compose network. DELETE /api/v1/messages without IDs deletes every message. A message from the last 5 minutes goes too (accepted:
# at 02:30 that visitor loses only the email preview). Fails on a non-200 answer or if messages remain counted afterwards.
docker exec n8n node -e '
const base = "http://mailpit:8025/api/v1/messages";
(async () => {
  const del = await fetch(base, { method: "DELETE", signal: AbortSignal.timeout(10000) });
  if (del.status !== 200) throw new Error("Mailpit DELETE answered " + del.status);
  const left = await (await fetch(base + "?limit=1", { signal: AbortSignal.timeout(10000) })).json();
  console.log("mailpit messages after reset: " + left.total);
})().catch(e => { console.error("[FAIL] " + e.message); process.exit(1); });'

printf 'url = "%s"\n' "$heartbeat_url" | curl --config - --silent --show-error --fail --retry 3 --connect-timeout 15 --max-time 30 --output /dev/null
echo "[PASS] demo reset finished, heartbeat pinged"
