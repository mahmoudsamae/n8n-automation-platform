-- Nightly demo reset (M7c-2, docs/tasks/m7c-demo.md). Run ONLY by infra/demo-reset.sh as the role demo_reset (migration 008),
-- which can SELECT and DELETE on these six tables and nothing else. Never run through wsl-sh.ps1 or server-sh.ps1: the destructive
-- guards refuse it there, by design.
-- One transaction. Any guard or error rolls everything back: nothing is deleted, psql exits non-zero, no heartbeat ping.
\set ON_ERROR_STOP on
\pset footer off

BEGIN;
-- Wait at most 30 s for a running Processor or Intake transaction; then fail (the next night retries).
SET LOCAL lock_timeout = '30s';
-- Blocks inserts and updates (Intake, Processor) for the few milliseconds of the reset, so the chosen set cannot change underneath.
LOCK TABLE stripe_events, invoices, side_effects, event_replays, demo_sessions, demo_limit_alerts IN SHARE ROW EXCLUSIVE MODE;

-- Guards. livemode anywhere means something is badly wrong: never delete. An old pending or processing row is work in flight or a
-- stuck Processor (the Monitor alerts it): never delete it, and since its invoice and side effects may be half written, stop entirely.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM stripe_events WHERE payload->>'livemode' = 'true') THEN
    RAISE EXCEPTION 'guard: a livemode event exists, nothing deleted';
  END IF;
  IF EXISTS (SELECT 1 FROM stripe_events WHERE status IN ('pending', 'processing') AND received_at < now() - interval '5 minutes') THEN
    RAISE EXCEPTION 'guard: a pending or processing event older than 5 minutes exists, nothing deleted';
  END IF;
END
$$;

SELECT 'before' AS phase,
       (SELECT count(*) FROM stripe_events) AS stripe_events, (SELECT count(*) FROM invoices) AS invoices,
       (SELECT count(*) FROM side_effects) AS side_effects, (SELECT count(*) FROM event_replays) AS event_replays,
       (SELECT count(*) FROM demo_sessions) AS demo_sessions, (SELECT count(*) FROM demo_limit_alerts) AS demo_limit_alerts;

-- The event set is chosen ONCE, by the event's own age (now() is fixed for the whole transaction, and the tables are locked).
-- Choosing per table by its own timestamp would hit ON DELETE RESTRICT (an old event with a newer invoice) and roll back every night.
-- FK order: event_replays, side_effects, invoices, stripe_events.
DELETE FROM event_replays WHERE event_id IN
  (SELECT event_id FROM stripe_events WHERE received_at < now() - interval '5 minutes' AND status IN ('done', 'failed', 'ignored'));
DELETE FROM side_effects WHERE event_id IN
  (SELECT event_id FROM stripe_events WHERE received_at < now() - interval '5 minutes' AND status IN ('done', 'failed', 'ignored'));
DELETE FROM invoices WHERE event_id IN
  (SELECT event_id FROM stripe_events WHERE received_at < now() - interval '5 minutes' AND status IN ('done', 'failed', 'ignored'));
DELETE FROM stripe_events WHERE received_at < now() - interval '5 minutes' AND status IN ('done', 'failed', 'ignored');
DELETE FROM demo_sessions WHERE created_at < now() - interval '5 minutes';
-- Today's cap alert (Berlin day) stays, so a cap reached between midnight and the reset does not alert twice.
DELETE FROM demo_limit_alerts WHERE day < (now() AT TIME ZONE 'Europe/Berlin')::date;

SELECT 'after' AS phase,
       (SELECT count(*) FROM stripe_events) AS stripe_events, (SELECT count(*) FROM invoices) AS invoices,
       (SELECT count(*) FROM side_effects) AS side_effects, (SELECT count(*) FROM event_replays) AS event_replays,
       (SELECT count(*) FROM demo_sessions) AS demo_sessions, (SELECT count(*) FROM demo_limit_alerts) AS demo_limit_alerts;

COMMIT;
