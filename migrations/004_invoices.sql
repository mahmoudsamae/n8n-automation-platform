-- 004_invoices.sql
-- One invoice per paid Stripe event. Creating the invoice is the Processor's first side effect;
-- the email that follows carries the invoice number.
-- NOT applied yet. Review, then run it yourself:
--   wsl -d Ubuntu docker exec -i postgres psql -U automation -d automation -v ON_ERROR_STOP=1 < migrations/004_invoices.sql
-- event_id UNIQUE makes invoice creation idempotent: the Processor inserts with
-- ON CONFLICT (event_id) DO NOTHING, so a retry or replay never makes a second invoice.
-- Deleting a stripe_events row is blocked while its invoice exists (ON DELETE RESTRICT):
-- an invoice is a financial record and must never disappear silently.
-- For test cleanup, delete from invoices and side_effects first, then from stripe_events.
-- amount_cents holds Stripe's smallest currency unit as is. For zero-decimal currencies
-- (JPY, KRW, ...) that is the whole amount, not hundredths; the Processor handles this when formatting.
-- Number format: INV-<year>-<6 digits>, e.g. INV-2026-000001. The sequence does NOT reset each year.
-- Gaps in numbering are possible (a rolled-back or conflicting insert still consumes a sequence value).
-- Rollback: DROP TABLE invoices; DROP SEQUENCE invoice_number_seq;

BEGIN;

CREATE SEQUENCE IF NOT EXISTS invoice_number_seq;

CREATE TABLE IF NOT EXISTS invoices (
    invoice_id     BIGINT      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    invoice_number TEXT        NOT NULL UNIQUE
                               DEFAULT 'INV-' || to_char(now(), 'YYYY') || '-' || lpad(nextval('invoice_number_seq')::text, 6, '0'),
    event_id       TEXT        NOT NULL UNIQUE REFERENCES stripe_events (event_id) ON DELETE RESTRICT,
    customer_email TEXT        NOT NULL,
    amount_cents   BIGINT      NOT NULL CHECK (amount_cents >= 0),
    currency       TEXT        NOT NULL CHECK (currency ~ '^[a-z]{3}$'),
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER SEQUENCE invoice_number_seq OWNED BY invoices.invoice_number;

COMMIT;
