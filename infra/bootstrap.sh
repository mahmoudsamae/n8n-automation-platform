#!/bin/bash
# Brings the M7 server to its running state from a clone of this repository. Safe to run twice: the second run changes nothing.
# Run: bash infra/bootstrap.sh   Exit 0 = stack up and backup timer active, 1 = stopped with a reason (nothing started).
# It never restores and never runs migrations: the server has no key to decrypt backups, and migrations are the owner's.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"
compose=(docker compose -f docker-compose.prod.yml)

fail() { echo "[FAIL] $1" >&2; exit 1; }

[ -f .env ] || fail ".env is missing: cp infra/env.example .env, chmod 600 .env, fill it in"
mode="$(stat -c %a .env)"
[ "$mode" = "600" ] || fail ".env has mode $mode, must be 600"
# Names only in the output, never a value.
for name in POSTGRES_PASSWORD N8N_ENCRYPTION_KEY BACKUP_PAR_URL BACKUP_HEARTBEAT_URL; do
  grep -Eq "^$name=.+" .env || fail "$name is empty or missing in .env"
done
[ -s infra/backup-recipient.pub ] || fail "infra/backup-recipient.pub is missing"

git pull --ff-only
"${compose[@]}" up -d

# Only touch systemd when a unit file really changed.
changed=0
for unit in backup-offsite.service backup-offsite.timer; do
  if ! cmp -s "infra/$unit" "/etc/systemd/system/$unit"; then
    sudo install -m 0644 "infra/$unit" "/etc/systemd/system/$unit"
    changed=1
  fi
done
if [ "$changed" = 1 ]; then sudo systemctl daemon-reload; fi
sudo systemctl enable --now backup-offsite.timer >/dev/null 2>&1
systemctl is-active --quiet backup-offsite.timer || fail "backup-offsite.timer is not active"

ready=0
for _ in $(seq 1 30); do
  if docker exec postgres pg_isready -q -U automation -d automation; then ready=1; break; fi
  sleep 2
done
[ "$ready" = 1 ] || fail "postgres did not become ready within 60 s"

if [ "$(docker exec postgres psql -U automation -d automation -tAc "select to_regclass('public.stripe_events') is null")" = "t" ]; then
  echo "[INFO] DB EMPTY: no stripe_events table. Either the owner runs the migrations, or restore from the laptop: scripts\\server-restore.ps1"
else
  echo "[INFO] DB has a stripe_events table"
fi
echo "[PASS] bootstrap finished"
