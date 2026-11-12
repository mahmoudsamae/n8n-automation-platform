-- 008_demo.sql
-- M7c-2: tables for the visitor demo and the narrow role of the nightly demo reset (docs/tasks/m7c-demo.md).
--
-- NOT applied yet. Review, then run it yourself on the server:
--   docker exec -i postgres psql -U automation -d automation -v ON_ERROR_STOP=1 < ~/n8n-workflows/migrations/008_demo.sql
-- The role demo_reset gets no password: infra/demo-reset.sh connects through the postgres container's local socket, and over TCP
-- (scram) a role without a password cannot log in at all. So the role limits WHAT the reset can do; it is not authentication.
--
-- demo_sessions: one row per Stripe Checkout session the demo created. Only sha256(token) is stored, never the token itself.
--   The row is reserved BEFORE the Stripe call (the limit check and the insert are one statement), so checkout_session_id is
--   filled in afterwards: that is the only column n8n_app may UPDATE. CHECKs make a test-mode session id and the demo address
--   format the only accepted values, so a live-mode session can never be recorded here.
-- demo_limit_alerts: one row per Berlin day on which the daily cap was reached; INSERT ... ON CONFLICT DO NOTHING RETURNING
--   decides whether the owner alert is sent (once per day).
-- No foreign keys: a session row exists before its Stripe event, and the reset deletes both sides by age.
--
-- demo_reset: SELECT and DELETE on the four pipeline tables and the two demo tables, nothing else. No TRUNCATE, no sequence
--   (invoice_number_seq is kept on purpose), no TEMPORARY, owns nothing, so DROP and ALTER are refused. LOCK TABLE ... IN SHARE ROW
--   EXCLUSIVE MODE needs DELETE, which it has. scripts\check-db-role.ps1 proves the exact privileges of both roles.
--
-- Rollback (owner): REVOKE ALL ON ALL TABLES IN SCHEMA public FROM demo_reset; REVOKE ALL ON SCHEMA public FROM demo_reset;
--   REVOKE ALL ON DATABASE automation FROM demo_reset; DROP ROLE demo_reset; then drop the two tables.

BEGIN;

CREATE TABLE IF NOT EXISTS demo_sessions (
    token_hash          BYTEA       PRIMARY KEY CHECK (length(token_hash) = 32),
    checkout_session_id TEXT        UNIQUE CHECK (checkout_session_id ~ '^cs_test_[A-Za-z0-9]+$'),
    demo_email          TEXT        NOT NULL UNIQUE CHECK (demo_email ~ '^demo-[0-9a-f]{8}@demo\.mahmud-alhussen\.de$'),
    ip_hash             BYTEA       NOT NULL CHECK (length(ip_hash) = 32),
    is_test             BOOLEAN     NOT NULL,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);
-- The two limit counts: per IP in the last hour, and per Berlin day without the e2e rows.
CREATE INDEX IF NOT EXISTS demo_sessions_ip_created_idx ON demo_sessions (ip_hash, created_at);
CREATE INDEX IF NOT EXISTS demo_sessions_created_idx ON demo_sessions (created_at) WHERE NOT is_test;

CREATE TABLE IF NOT EXISTS demo_limit_alerts (
    day        DATE        PRIMARY KEY,
    alerted_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

GRANT SELECT, INSERT ON demo_sessions TO n8n_app;
GRANT UPDATE (checkout_session_id) ON demo_sessions TO n8n_app;
GRANT SELECT, INSERT ON demo_limit_alerts TO n8n_app;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'demo_reset') THEN
    CREATE ROLE demo_reset LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 2;
  END IF;
END
$$;

GRANT CONNECT ON DATABASE automation TO demo_reset;
GRANT USAGE ON SCHEMA public TO demo_reset;
GRANT SELECT, DELETE ON event_replays, side_effects, invoices, stripe_events, demo_sessions, demo_limit_alerts TO demo_reset;

COMMIT;
