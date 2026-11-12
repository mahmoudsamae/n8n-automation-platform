#!/bin/bash
# Nightly offsite backup: pg_dump piped straight into age, so plaintext never touches this disk, then upload with the write-only bucket URL.
# Then the same for n8n (M7b-6): workflows, credentials and data tables, which live in n8n's SQLite, not in Postgres.
# The private key is not on this server, so a compromised server cannot read old backups. Retention is the bucket's lifecycle rule (14 days).
# Run by backup-offsite.timer, or by hand: bash infra/backup-offsite.sh   Exit 0 = both uploaded and pinged, non-zero = see the journal.
# Any failure means no ping, so Healthchecks alerts after the grace time. The ping comes only after BOTH uploads.
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

# $tmp (disk) only ever holds encrypted files. $ram (host tmpfs) and $cdir (the n8n container's /dev/shm, also tmpfs) hold the n8n export
# in plaintext for a few seconds: its data tables contain the heartbeat URL and the alert addresses. All three are removed on any exit.
tmp="$(mktemp -d)"
ram="$(mktemp -d -p /dev/shm)"
cdir=/dev/shm/n8n-backup
trap 'rm -rf "$tmp" "$ram"; docker exec n8n rm -rf "$cdir" >/dev/null 2>&1 || true' EXIT

upload() {
  # --retry covers 429, 5xx and network errors, with exponential backoff.
  printf 'url = "%s%s"\n' "$par_url" "$1" | curl --config - --silent --show-error --fail --retry 5 --connect-timeout 15 --max-time 900 --upload-file "$tmp/$1" --output /dev/null
  echo "uploaded $1 ($(stat -c %s "$tmp/$1") bytes)"
}

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
name="automation-$stamp.dump.age"
docker exec postgres pg_dump -U automation -d automation -Fc | age -R "$repo/infra/backup-recipient.pub" -o "$tmp/$name"
[ -s "$tmp/$name" ] || { echo "[FAIL] encrypted dump is empty" >&2; exit 1; }
upload "$name"

# n8n. credentials.json keeps n8n's own encryption (N8N_ENCRYPTION_KEY): never --decrypted, so the backup is useless without that key.
# export:entities is the only CLI export that includes data table rows (stripe_config, stripe_heartbeat); it encrypts the credential and
# data table files inside entities.zip with the same key. workflows.json and credentials.json are the simple restore path
# (import:workflow, import:credentials), entities.zip the complete one. Each command starts a second n8n process in the container.
n8n_name="n8n-$stamp.tar.age"
docker exec n8n sh -c "rm -rf $cdir && mkdir -m 700 $cdir $cdir/entities \
  && n8n export:workflow --all --output=$cdir/workflows.json \
  && n8n export:credentials --all --output=$cdir/credentials.json \
  && n8n export:entities --outputDir=$cdir/entities" >/dev/null
for f in workflows.json credentials.json entities/entities.zip; do
  docker exec n8n cat "$cdir/$f" > "$ram/$(basename "$f")"
done
python3 - "$ram" <<'PY'
import json, sys, zipfile
d = sys.argv[1]
for f in ('workflows.json', 'credentials.json'):
    items = json.load(open(f'{d}/{f}'))
    if not isinstance(items, list) or not items: sys.exit(f'[FAIL] {f} holds no items')
if not any(n.startswith('data_table_user_') for n in zipfile.ZipFile(f'{d}/entities.zip').namelist()):
    sys.exit('[FAIL] entities.zip holds no data table rows')
PY
tar -C "$ram" -cf - workflows.json credentials.json entities.zip | age -R "$repo/infra/backup-recipient.pub" -o "$tmp/$n8n_name"
[ -s "$tmp/$n8n_name" ] || { echo "[FAIL] encrypted n8n export is empty" >&2; exit 1; }
upload "$n8n_name"

printf 'url = "%s"\n' "$heartbeat_url" | curl --config - --silent --show-error --fail --retry 3 --connect-timeout 15 --max-time 30 --output /dev/null
echo "[PASS] backup finished, heartbeat pinged"
