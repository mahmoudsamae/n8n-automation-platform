-- 007_n8n_app_role.sql
-- M7b-2: n8n gets its own login role without DDL rights. `automation` stays the owner of every table: migrations and the
-- docker exec scripts (replay, seed, clean, backups) keep using it, and n8n no longer connects as a superuser.
-- Why a role: text guards can be bypassed and never see an n8n Postgres node. The database cannot be talked out of a missing privilege.
--
-- NOT applied yet. Review, then run it yourself on the server (the role gets no password here, so it cannot log in yet):
--   docker exec -i postgres psql -U automation -d automation -v ON_ERROR_STOP=1 < ~/n8n-workflows/migrations/007_n8n_app_role.sql
-- Then set the password interactively (it is never in a file, a command line or shell history):
--   docker exec -it postgres psql -U automation -d automation -c '\password n8n_app'
--
-- Privileges are exactly what the workflows' SQL needs (grepped from the .sdk.ts files on 2026-11-08):
--   stripe_events  SELECT, INSERT, UPDATE  Intake inserts; Processor claims (FOR UPDATE needs UPDATE) and marks; Monitor sets alerted_at
--   side_effects   SELECT, INSERT          INSERT ... ON CONFLICT DO NOTHING, EXISTS checks
--   invoices       SELECT, INSERT          insert-or-read of the invoice row; the renderer reads it
--   event_replays  nothing                 only scripts\replay.ps1 writes it, as `automation`
--   sequences      USAGE                   invoice_number_seq and invoices_invoice_id_seq (column defaults call nextval)
-- No DELETE (ON DELETE RESTRICT tables, nothing in n8n deletes), no TRUNCATE, no REFERENCES, no TRIGGER, no CREATE anywhere.
-- Not the owner of anything, so ALTER and DROP are refused. Every later migration that adds a table must grant to n8n_app
-- explicitly (scripts\lint-migrations.ps1 enforces it), because there are no default privileges.
--
-- Rollback: REVOKE ALL ON ALL TABLES IN SCHEMA public FROM n8n_app; REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM n8n_app;
--           REVOKE ALL ON SCHEMA public FROM n8n_app; REVOKE ALL ON DATABASE automation FROM n8n_app; DROP ROLE n8n_app;
--           and GRANT CONNECT, TEMPORARY ON DATABASE automation TO PUBLIC to restore the default.

BEGIN;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'n8n_app') THEN
    CREATE ROLE n8n_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 20;
  END IF;
END
$$;

-- PUBLIC gets CONNECT and TEMPORARY on a new database by default. Only named roles may connect now (automation is a superuser).
REVOKE ALL ON DATABASE automation FROM PUBLIC;
GRANT CONNECT ON DATABASE automation TO n8n_app;
GRANT USAGE ON SCHEMA public TO n8n_app;

GRANT SELECT, INSERT, UPDATE ON stripe_events TO n8n_app;
GRANT SELECT, INSERT ON side_effects TO n8n_app;
GRANT SELECT, INSERT ON invoices TO n8n_app;
GRANT USAGE ON SEQUENCE invoice_number_seq, invoices_invoice_id_seq TO n8n_app;

COMMIT;
