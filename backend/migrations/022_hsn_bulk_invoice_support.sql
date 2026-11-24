ALTER TABLE products
  ADD COLUMN IF NOT EXISTS hsn_code VARCHAR(20) NOT NULL DEFAULT '';

ALTER TABLE invoice_items
  ADD COLUMN IF NOT EXISTS hsn_code_snapshot VARCHAR(20) NOT NULL DEFAULT '';

ALTER TABLE products
  DROP CONSTRAINT IF EXISTS products_unit_check;

ALTER TABLE products
  ADD CONSTRAINT products_unit_check
  CHECK (unit IN ('kg', 'g', 'litre', 'ml', 'piece', 'packet', 'boxes', 'box', 'bottle', 'pai', 'Can', 'Bundle', 'saram', 'Bag'));

ALTER TABLE stock_batches
  DROP CONSTRAINT IF EXISTS stock_batches_purchase_unit_check;

ALTER TABLE stock_batches
  ADD CONSTRAINT stock_batches_purchase_unit_check
  CHECK (purchase_unit IN ('kg', 'g', 'litre', 'ml', 'piece', 'packet', 'boxes', 'box', 'bottle', 'pai', 'Can', 'Bundle', 'saram', 'Bag'));

ALTER TABLE invoices
  ADD COLUMN IF NOT EXISTS invoice_type VARCHAR(16) NOT NULL DEFAULT 'retail',
  ADD COLUMN IF NOT EXISTS customer_name_snapshot VARCHAR(160) NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS customer_address_snapshot TEXT NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS customer_gstin_snapshot VARCHAR(15) NOT NULL DEFAULT '',
  ADD COLUMN IF NOT EXISTS place_of_supply_snapshot VARCHAR(160) NOT NULL DEFAULT '';

ALTER TABLE invoices
  DROP CONSTRAINT IF EXISTS invoices_invoice_type_check;

ALTER TABLE invoices
  ADD CONSTRAINT invoices_invoice_type_check
  CHECK (invoice_type IN ('retail', 'bulk'));
