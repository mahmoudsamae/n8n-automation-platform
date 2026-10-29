-- 002_side_effects.sql
-- Records which side effects (email, telegram) were already done for an event,
-- so the Processor can retry an event without sending the same message twice.
-- NOT applied yet. Review, then run it yourself:
--   wsl -d Ubuntu docker exec -i postgres psql -U automation -d automation -v ON_ERROR_STOP=1 < migrations/002_side_effects.sql
-- Rollback: DROP TABLE side_effects;

BEGIN;

CREATE TABLE IF NOT EXISTS side_effects (
    event_id TEXT        NOT NULL REFERENCES stripe_events (event_id) ON DELETE CASCADE,
    kind     TEXT        NOT NULL,
    done_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (event_id, kind)
);

COMMIT;
