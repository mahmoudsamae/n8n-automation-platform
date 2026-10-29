-- 003_claimed_at.sql
-- Records when the Processor claimed an event (status -> 'processing'), so a row stuck in
-- 'processing' for more than 10 minutes can be detected and returned to the queue.
-- NOT applied yet. Review, then run it yourself:
--   wsl -d Ubuntu docker exec -i postgres psql -U automation -d automation -v ON_ERROR_STOP=1 < migrations/003_claimed_at.sql
-- Nullable on purpose: existing rows were never claimed, and only the Processor writes it.
-- Rollback: ALTER TABLE stripe_events DROP COLUMN claimed_at;

BEGIN;

ALTER TABLE stripe_events ADD COLUMN IF NOT EXISTS claimed_at TIMESTAMPTZ;

COMMIT;
