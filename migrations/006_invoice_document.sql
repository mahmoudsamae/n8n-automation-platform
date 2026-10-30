-- 006_invoice_document.sql
-- Stores everything the invoice document shows, so the email and the PDF are rendered ONLY from the invoice row:
-- a retry, a replay or a later re-render produces the same document and never calls Stripe again.
-- NOT applied yet. Review, then run it yourself (the script runs it through base64, so no quoting trouble):
--   & scripts\wsl-sh.ps1 -Script 'docker exec -i postgres psql -U automation -d automation -v ON_ERROR_STOP=1 < /mnt/c/dev/n8n-workflows/migrations/006_invoice_document.sql'
-- Three nullable columns, filled together by the Processor in the same INSERT that creates the invoice:
--   customer_name  TEXT   the customer's name from the checkout session (customer-controlled text: escape it wherever it is shown)
--   payment_method TEXT   the method actually used, e.g. 'Visa' (from the charge, not the list of allowed methods)
--   line_items     JSONB  array of {"description": text, "quantity": int, "unit_amount": int, "amount_total": int};
--                         amounts are Stripe's smallest currency unit, like amount_cents. The Processor checks that the
--                         amount_total values add up to amount_cents before inserting.
-- The 27 invoices that exist today keep NULL in all three: they were sent as plain text and are never re-rendered.
-- The CHECK makes a half-filled row impossible: either all three are NULL (an old invoice) or all three are set.
-- No NOT NULL on purpose (old rows), no default (a missing value must fail the event, not become a made-up one).
-- No new table and no foreign key, so nothing here changes ON DELETE RESTRICT on financial records.
-- Safe to run twice. Rollback (destroys the stored document data, so only before real use):
--   ALTER TABLE invoices DROP CONSTRAINT IF EXISTS invoices_document_all_or_none;
--   ALTER TABLE invoices DROP COLUMN IF EXISTS customer_name, DROP COLUMN IF EXISTS payment_method, DROP COLUMN IF EXISTS line_items;

BEGIN;

ALTER TABLE invoices
    ADD COLUMN IF NOT EXISTS customer_name  TEXT,
    ADD COLUMN IF NOT EXISTS payment_method TEXT,
    ADD COLUMN IF NOT EXISTS line_items     JSONB;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'invoices_document_all_or_none') THEN
        ALTER TABLE invoices ADD CONSTRAINT invoices_document_all_or_none CHECK (
            (customer_name IS NULL AND payment_method IS NULL AND line_items IS NULL)
            OR (customer_name IS NOT NULL AND btrim(customer_name) <> ''
                AND payment_method IS NOT NULL AND btrim(payment_method) <> ''
                AND line_items IS NOT NULL AND jsonb_typeof(line_items) = 'array' AND jsonb_array_length(line_items) > 0)
        );
    END IF;
END $$;

COMMIT;
