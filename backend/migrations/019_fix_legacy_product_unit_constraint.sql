ALTER TABLE products
  DROP CONSTRAINT IF EXISTS products_stock_unit_check,
  DROP CONSTRAINT IF EXISTS products_unit_check;

ALTER TABLE products
  ADD CONSTRAINT products_unit_check
  CHECK (unit IN ('kg', 'g', 'litre', 'ml', 'piece', 'packet', 'boxes', 'saram'));

ALTER TABLE stock_batches
  DROP CONSTRAINT IF EXISTS stock_batches_purchase_unit_check;

ALTER TABLE stock_batches
  ADD CONSTRAINT stock_batches_purchase_unit_check
  CHECK (purchase_unit IN ('kg', 'g', 'litre', 'ml', 'piece', 'packet', 'boxes', 'saram'));
