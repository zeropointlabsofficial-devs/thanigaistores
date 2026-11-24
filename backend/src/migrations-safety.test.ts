import { readdir, readFile } from 'node:fs/promises';
import path from 'node:path';
import { deepStrictEqual, equal, match, ok } from 'node:assert/strict';
import { it } from 'node:test';

it('keeps shipped schema migrations versioned and non-destructive', async () => {
  const directory = path.resolve(__dirname, '../migrations');
  const files = (await readdir(directory))
    .filter((file) => /^\d+_[a-z0-9_-]+\.sql$/i.test(file))
    .sort();

  ok(files.length > 0);
  const versions = files.map((file) => Number(file.split('_', 1)[0]));
  deepStrictEqual(
    versions,
    Array.from({ length: files.length }, (_, index) => index + 1),
  );

  for (const file of files) {
    const sql = await readFile(path.join(directory, file), 'utf8');
    equal(
      /(?:^|;)\s*(?:DROP\s+(?:TABLE|SCHEMA|DATABASE|COLUMN)\b|TRUNCATE\b|DELETE\s+FROM\b)/im.test(sql),
      false,
      file,
    );
    match(file, /^\d+_[a-z0-9_-]+\.sql$/i);
  }
});

it('removes the legacy product unit constraint while allowing all supported units', async () => {
  const migration = await readFile(
    path.resolve(
      __dirname,
      '../migrations/019_fix_legacy_product_unit_constraint.sql',
    ),
    'utf8',
  );

  match(migration, /DROP CONSTRAINT IF EXISTS products_stock_unit_check/i);
  match(migration, /unit IN \([^)]*'boxes'[^)]*'saram'[^)]*\)/i);
  match(
    migration,
    /purchase_unit IN \([^)]*'boxes'[^)]*'saram'[^)]*\)/i,
  );
});

it('allows Bag for product and stock batch units without changing existing rows', async () => {
  const migration = await readFile(
    path.resolve(__dirname, '../migrations/020_add_bag_product_unit.sql'),
    'utf8',
  );

  match(migration, /unit IN \([^)]*'Bag'\)/i);
  match(migration, /purchase_unit IN \([^)]*'Bag'\)/i);
});

it('allows bottle, box, and pai product and stock batch units', async () => {
  const migration = await readFile(
    path.resolve(__dirname, '../migrations/021_add_product_units.sql'),
    'utf8',
  );

  for (const unit of ['bottle', 'box', 'pai']) {
    match(migration, new RegExp(`unit IN \\([^)]*'${unit}'[^)]*\\)`, 'i'));
    match(
      migration,
      new RegExp(`purchase_unit IN \\([^)]*'${unit}'[^)]*\\)`, 'i'),
    );
  }
});

it('adds HSN and bulk invoice snapshots without changing existing records', async () => {
  const migration = await readFile(
    path.resolve(__dirname, '../migrations/022_hsn_bulk_invoice_support.sql'),
    'utf8',
  );

  match(migration, /ADD COLUMN IF NOT EXISTS hsn_code/i);
  match(migration, /ADD COLUMN IF NOT EXISTS hsn_code_snapshot/i);
  match(migration, /ADD COLUMN IF NOT EXISTS invoice_type/i);
  match(migration, /CHECK \(invoice_type IN \('retail', 'bulk'\)\)/i);
});
