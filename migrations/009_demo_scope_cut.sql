-- 009_demo_scope_cut.sql
-- M7c scope cut (owner, 2026-11-13, docs/tasks/m7c-demo.md): the per-IP limit and the e2e exemption from the daily cap are dropped.
-- ip_hash (a salted hash of the visitor's IP) would then be stored with no purpose (GDPR data minimisation), and is_test existed only for
-- the e2e exemption. The table holds only seeded test rows today (the nightly reset removes them). The index demo_sessions_ip_created_idx
-- and the partial index demo_sessions_created_idx (WHERE NOT is_test) go with their columns; a plain index on created_at replaces the
-- second, for the daily cap count.
--
-- NOT applied yet. Review, then run it yourself on the server:
--   docker exec -i postgres psql -U automation -d automation -v ON_ERROR_STOP=1 < ~/n8n-workflows/migrations/009_demo_scope_cut.sql
-- Grants are unchanged: no new table, and the column grant on checkout_session_id stays.
-- Rollback: re-add both columns as nullable (the old NOT NULL needs values) and their indexes.

BEGIN;

ALTER TABLE demo_sessions DROP COLUMN IF EXISTS ip_hash;
ALTER TABLE demo_sessions DROP COLUMN IF EXISTS is_test;
CREATE INDEX IF NOT EXISTS demo_sessions_created_at_idx ON demo_sessions (created_at);

COMMIT;
