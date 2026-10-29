-- 005_m4_alerting.sql
-- M4 failure visibility: dead-event alert tracking, stale-pending detection, replay audit trail.
-- NOT applied yet. Review, then run it yourself:
--   wsl -d Ubuntu docker exec -i postgres psql -U automation -d automation -v ON_ERROR_STOP=1 < migrations/005_m4_alerting.sql
--
-- stripe_events.alerted_at: set by the Monitor after it sends the dead-event alert (failed, attempts >= 5),
--   so each dead event alerts once. Nullable: NULL means "not alerted". replay.ps1 resets it to NULL.
-- stripe_events.pending_since: when the row last became 'pending'. The stale-pending alert uses this, not
--   received_at, so a row just released by stuck-row recovery or just replayed is not reported as stale.
--   Intake inserts get the default now(). The Processor's release and replay.ps1 set it to now() explicitly.
--   Existing rows are backfilled with received_at (the moment they first became pending or ignored).
-- event_replays: one row per manual replay, with a required reason. Audit trail for a manual action on
--   financial records, so the FK is ON DELETE RESTRICT. For test cleanup, delete event_replays rows together
--   with side_effects and invoices, before stripe_events.
-- Rollback: DROP TABLE event_replays;
--           ALTER TABLE stripe_events DROP COLUMN pending_since, DROP COLUMN alerted_at;

BEGIN;

ALTER TABLE stripe_events ADD COLUMN IF NOT EXISTS alerted_at TIMESTAMPTZ;

ALTER TABLE stripe_events ADD COLUMN IF NOT EXISTS pending_since TIMESTAMPTZ;
UPDATE stripe_events SET pending_since = received_at WHERE pending_since IS NULL;
ALTER TABLE stripe_events ALTER COLUMN pending_since SET DEFAULT now();
ALTER TABLE stripe_events ALTER COLUMN pending_since SET NOT NULL;

CREATE TABLE IF NOT EXISTS event_replays (
    replay_id   BIGINT      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_id    TEXT        NOT NULL REFERENCES stripe_events (event_id) ON DELETE RESTRICT,
    reason      TEXT        NOT NULL CHECK (length(btrim(reason)) > 0),
    replayed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS event_replays_event_id_idx ON event_replays (event_id);

COMMIT;
