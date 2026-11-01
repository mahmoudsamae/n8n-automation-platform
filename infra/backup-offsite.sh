#!/bin/bash
# Nightly offsite backup: pg_dump piped straight into age, so plaintext never touches this disk, then upload with the write-only bucket URL.
# The private key is not on this server, so a compromised server cannot read old backups. Retention is the bucket's lifecycle rule (14 days).
# Run by backup-offsite.timer, or by hand: bash infra/backup-offsite.sh   Exit 0 = uploaded and pinged, non-zero = see the journal.
# Any failure means no ping, so Healthchecks alerts after the grace time.
# The URLs are secrets: they go to curl through stdin (--config -), never on a command line, and are never printed.
set -euo pipefail
umask 077

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

env_value() {
  local value
  value="$(grep -m1 "^$1=" "$repo/.env" | cut -d= -f2-)" || true
  [ -n "$value" ] || { echo "[FAIL] $1 is empty or missing in .env" >&2; exit 1; }
  printf '%s' "$value"
}

par_url="$(env_value BACKUP_PAR_URL)"
heartbeat_url="$(env_value BACKUP_HEARTBEAT_URL)"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

name="automation-$(date -u +%Y%m%dT%H%M%SZ).dump.age"
docker exec postgres pg_dump -U automation -d automation -Fc | age -R "$repo/infra/backup-recipient.pub" -o "$tmp/$name"
[ -s "$tmp/$name" ] || { echo "[FAIL] encrypted dump is empty" >&2; exit 1; }

# --retry covers 429, 5xx and network errors, with exponential backoff.
printf 'url = "%s%s"\n' "$par_url" "$name" | curl --config - --silent --show-error --fail --retry 5 --connect-timeout 15 --max-time 900 --upload-file "$tmp/$name" --output /dev/null
echo "uploaded $name ($(stat -c %s "$tmp/$name") bytes)"

printf 'url = "%s"\n' "$heartbeat_url" | curl --config - --silent --show-error --fail --retry 3 --connect-timeout 15 --max-time 30 --output /dev/null
echo "[PASS] backup finished, heartbeat pinged"
