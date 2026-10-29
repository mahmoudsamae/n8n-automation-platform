-- 001_stripe_events.sql
-- Reconstructed from the live table definition (pg_indexes, pg_constraint, information_schema).
-- The table already exists in the running database; every statement is IF NOT EXISTS,
-- so this file is a no-op there and builds the schema on a fresh database.
-- Run (fresh DB):
--   wsl -d Ubuntu docker exec -i postgres psql -U automation -d automation -v ON_ERROR_STOP=1 < migrations/001_stripe_events.sql

BEGIN;

CREATE TABLE IF NOT EXISTS stripe_events (
    event_id     TEXT        NOT NULL,
    event_type   TEXT        NOT NULL,
    status       TEXT        NOT NULL DEFAULT 'pending',
    attempts     INTEGER     NOT NULL DEFAULT 0,
    last_error   TEXT,
    payload      JSONB       NOT NULL,
    received_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    processed_at TIMESTAMPTZ,
    CONSTRAINT stripe_events_pkey PRIMARY KEY (event_id),
    CONSTRAINT stripe_events_status_check
        CHECK (status = ANY (ARRAY['pending', 'processing', 'done', 'failed', 'ignored']))
);

CREATE INDEX IF NOT EXISTS idx_stripe_events_pending
    ON stripe_events USING btree (status, received_at)
    WHERE status = ANY (ARRAY['pending', 'failed']);

COMMIT;
