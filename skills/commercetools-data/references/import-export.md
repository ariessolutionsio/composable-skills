# Import & Export Patterns

**Impact: HIGH -- 20-resource batch limit. Async processing with 48-hour retry window. Wrong import order causes unresolved references.**

The commercetools Import API is a separate, purpose-built API for bulk data loading. It operates asynchronously, uses upsert semantics, and has strict batching constraints. Understanding its behavior is essential for initial data loads, ongoing sync, and migrations.

## Import API Architecture

```
Your Application
     |
     v
Import API (https://import.{region}.commercetools.com)
     |
     v
Import Containers (logical grouping)
     |
     v
Import Requests (max 20 resources each)
     |
     v
Import Operations (one per resource, tracked for 48 hours)
     |
     v
commercetools HTTP API (actual resource creation/update)
```

### Import API Host URLs

| Region | Import API Host |
|--------|----------------|
| Europe (GCP, Belgium) | `https://import.europe-west1.gcp.commercetools.com` |
| North America (GCP, Iowa) | `https://import.us-central1.gcp.commercetools.com` |
| Europe (AWS, Frankfurt) | `https://import.eu-central-1.aws.commercetools.com` |
| North America (AWS, Ohio) | `https://import.us-east-2.aws.commercetools.com` |
| Australia (GCP, Sydney) | `https://import.australia-southeast1.gcp.commercetools.com` |

### Supported Resource Types

The Import API supports: Categories, Customers, DiscountCodes, InventoryEntry, Orders, Products (including embedded variants/prices), ProductSelections, ProductTypes, StandalonePrices, Types, and BusinessUnits. Separate endpoints exist for Products, Variants, Patches, and Prices to optimize different update scenarios.

Key characteristics:
- **Asynchronous:** Responses acknowledge receipt, not completion
- **Upsert:** Updates if `key` exists, creates if it does not
- **Eventually consistent:** Resources may import in a different order than submitted
- **48-hour window:** Unresolved references retry up to 5 times within 48 hours
- **No uniqueness validation:** Only the HTTP API enforces uniqueness constraints

## Import Client Setup

```typescript
// The Import API uses a DIFFERENT base URL and SDK package
import { ClientBuilder } from '@commercetools/ts-client';
import { createApiBuilderFromCtpClient } from '@commercetools/importapi-sdk';

const projectKey = process.env.CTP_PROJECT_KEY!;

const importAuthOptions = {
  host: 'https://auth.europe-west1.gcp.commercetools.com',
  projectKey,
  credentials: {
    clientId: process.env.CTP_CLIENT_ID!,
    clientSecret: process.env.CTP_CLIENT_SECRET!,
  },
  scopes: [`manage_import_containers:${projectKey}`],
  httpClient: fetch,
};

// IMPORTANT: Different host than the main API
const importHttpOptions = {
  host: 'https://import.europe-west1.gcp.commercetools.com',
  httpClient: fetch,
};

const importClient = new ClientBuilder()
  .withProjectKey(projectKey)
  .withClientCredentialsFlow(importAuthOptions)
  .withHttpMiddleware(importHttpOptions)
  .build();

// Note: importapi-sdk uses withProjectKeyValue (not withProjectKey)
const importApiRoot = createApiBuilderFromCtpClient(importClient)
  .withProjectKeyValue({ projectKey });
```

## Import Containers

Import Containers are logical grouping units. Keep fewer than 200,000 Import Operations per container for optimal performance.

```typescript
// Create import containers -- one per resource type is a good starting pattern
const productTypeContainer = await importApiRoot
  .importContainers()
  .post({ body: { key: 'product-type-import' } })
  .execute();

const categoryContainer = await importApiRoot
  .importContainers()
  .post({ body: { key: 'category-import' } })
  .execute();

const productContainer = await importApiRoot
  .importContainers()
  .post({ body: { key: 'product-import' } })
  .execute();

// For large imports, create time-stamped containers
const batchContainer = await importApiRoot
  .importContainers()
  .post({ body: { key: `product-import-${Date.now()}` } })
  .execute();
```

**Limit:** Maximum 1,000 Import Containers per project.

## The 20-Resource Batch Limit

Every Import Request can contain a maximum of 20 resources. For bulk imports, you must batch your data.

**Anti-Pattern (sending too many resources):**

```typescript
// THIS WILL FAIL -- Import API rejects requests with more than 20 resources
await importApiRoot
  .productDrafts()
  .importContainers()
  .withImportContainerKeyValue({ importContainerKey: 'product-import' })
  .post({
    body: {
      type: 'product-draft',
      resources: allProducts, // 500 products -- ERROR: max 20
    },
  })
  .execute();
```

**Recommended (batched import with rate control):**

```typescript
interface ImportableResource {
  key: string;
  [key: string]: any;
}

/**
 * Batch import resources with rate limiting.
 * Handles the 20-resource-per-request limit and prevents overwhelming the API.
 */
async function batchImport<T extends ImportableResource>(
  resources: T[],
  containerKey: string,
  importFn: (batch: T[], containerKey: string) => Promise<void>,
  options: {
    batchSize?: number;
    delayBetweenBatchesMs?: number;
    onBatchComplete?: (batchIndex: number, totalBatches: number) => void;
  } = {}
): Promise<void> {
  const {
    batchSize = 20,
    delayBetweenBatchesMs = 200,
    onBatchComplete,
  } = options;

  const batches: T[][] = [];
  for (let i = 0; i < resources.length; i += batchSize) {
    batches.push(resources.slice(i, i + batchSize));
  }

  for (const [index, batch] of batches.entries()) {
    await importFn(batch, containerKey);

    onBatchComplete?.(index + 1, batches.length);

    // Rate limiting: avoid overwhelming the Import API
    if (index < batches.length - 1) {
      await new Promise(resolve => setTimeout(resolve, delayBetweenBatchesMs));
    }
  }
}

// Usage: Import products in batches of 20
await batchImport(
  allProducts,
  'product-import',
  async (batch, containerKey) => {
    await importApiRoot
      .productDrafts()
      .importContainers()
      .withImportContainerKeyValue({ importContainerKey: containerKey })
      .post({
        body: {
          type: 'product-draft',
          resources: batch,
        },
      })
      .execute();
  },
  {
    batchSize: 20,
    delayBetweenBatchesMs: 200,
    onBatchComplete: (current, total) => {
      console.log(`Imported batch ${current}/${total}`);
    },
  }
);
```

## Import Order: Dependencies Matter

The Import API resolves references asynchronously, but importing in the wrong order wastes retry cycles and can cause failures if references are not resolved within 48 hours.

**Recommended import order:**

```
1. Product Types (no dependencies)
2. Tax Categories (no dependencies)
3. Categories (may reference parent categories -- import top-down)
4. Custom Types / Type Definitions (no dependencies)
5. Channels (no dependencies)
6. Customer Groups (no dependencies)
7. Customers (may reference customer groups)
8. Products (reference product types, categories, tax categories)
9. Product Variants (reference products)
10. Inventory Entries (reference product variants via SKU, channels)
11. Prices / Standalone Prices (reference products, channels, customer groups)
12. Product Selections (reference products)
13. Orders (reference products, customers -- typically via Order Import)
```

```typescript
// Full import sequence example
async function runFullImport() {
  console.log('Step 1: Importing Product Types...');
  await importProductTypes('product-type-import');

  console.log('Step 2: Importing Categories (top-down)...');
  await importCategories('category-import');

  console.log('Step 3: Importing Products...');
  await importProducts('product-import');

  console.log('Step 4: Checking import status...');
  await waitForImportCompletion('product-import');

  console.log('Step 5: Importing Inventory...');
  await importInventory('inventory-import');

  console.log('Import complete.');
}
```

## Monitoring Import Operations

Import Operations track the status of each imported resource and persist for 48 hours.

```typescript
// Check the status of import operations in a container
async function checkImportStatus(containerKey: string): Promise<{
  total: number;
  imported: number;
  rejected: number;
  unresolved: number;
  processing: number;
}> {
  const stats = { total: 0, imported: 0, rejected: 0, unresolved: 0, processing: 0 };
  let offset = 0;
  const limit = 500;

  while (true) {
    const response = await importApiRoot
      .importContainers()
      .withImportContainerKeyValue({ importContainerKey: containerKey })
      .importOperations()
      .get({ queryArgs: { limit, offset } })
      .execute();

    for (const op of response.body.results) {
      stats.total++;
      switch (op.state) {
        case 'imported': stats.imported++; break;
        case 'rejected': stats.rejected++; break;
        case 'unresolved': stats.unresolved++; break;
        case 'validationFailed': stats.rejected++; break;
        default: stats.processing++; break;
      }
    }

    if (response.body.results.length < limit) break;
    offset += limit;
  }

  return stats;
}

// Log detailed errors for failed imports
async function logImportErrors(containerKey: string): Promise<void> {
  const response = await importApiRoot
    .importContainers()
    .withImportContainerKeyValue({ importContainerKey: containerKey })
    .importOperations()
    .get({
      queryArgs: {
        limit: 500,
        // Filter to only failed operations
        states: ['rejected', 'validationFailed'],
      },
    })
    .execute();

  for (const op of response.body.results) {
    console.error(`FAILED: ${op.resourceKey} (state: ${op.state})`);
    if (op.errors) {
      for (const err of op.errors) {
        console.error(`  Error: ${err.message}`);
      }
    }
    if (op.unresolvedReferences) {
      for (const ref of op.unresolvedReferences) {
        console.error(`  Unresolved: ${ref.typeId} with key "${ref.key}"`);
      }
    }
  }
}

// Poll until import is complete
async function waitForImportCompletion(
  containerKey: string,
  intervalMs: number = 5000,
  timeoutMs: number = 300000
): Promise<void> {
  const start = Date.now();

  while (Date.now() - start < timeoutMs) {
    const status = await checkImportStatus(containerKey);
    console.log(`Status: ${JSON.stringify(status)}`);

    if (status.processing === 0 && status.unresolved === 0) {
      if (status.rejected > 0) {
        console.warn(`Import completed with ${status.rejected} failures.`);
        await logImportErrors(containerKey);
      } else {
        console.log('Import completed successfully.');
      }
      return;
    }

    await new Promise(resolve => setTimeout(resolve, intervalMs));
  }

  throw new Error(`Import did not complete within ${timeoutMs}ms`);
}
```

## Import Operation States

| State | Meaning | Action |
|-------|---------|--------|
| `processing` | Currently being processed | Wait |
| `validationFailed` | Request payload is invalid | Fix data and re-import |
| `unresolved` | Referenced resources not found yet | Wait (retries up to 5x in 48h) or import the missing dependencies |
| `waitForMasterVariant` | Product variant waiting for its product | Import the product first |
| `imported` | Successfully imported | Done |
| `rejected` | Failed after all retries | Check errors, fix, re-import |
| `canceled` | Manually canceled | Re-import if needed |

## Upsert Behavior

The Import API uses the `key` field to determine whether to create or update.

```typescript
// First import: creates the product (key does not exist)
await importApiRoot
  .productDrafts()
  .importContainers()
  .withImportContainerKeyValue({ importContainerKey: 'product-import' })
  .post({
    body: {
      type: 'product-draft',
      resources: [{
        key: 'classic-tee',  // Key used for matching
        name: { en: 'Classic T-Shirt' },
        productType: { typeId: 'product-type', key: 'apparel' },
        slug: { en: 'classic-tee' },
      }],
    },
  })
  .execute();

// Second import with same key: UPDATES the existing product
await importApiRoot
  .productDrafts()
  .importContainers()
  .withImportContainerKeyValue({ importContainerKey: 'product-import' })
  .post({
    body: {
      type: 'product-draft',
      resources: [{
        key: 'classic-tee',  // Same key -- this is an UPDATE
        name: { en: 'Classic T-Shirt (Updated)' },
        productType: { typeId: 'product-type', key: 'apparel' },
        slug: { en: 'classic-tee' },
      }],
    },
  })
  .execute();

// IMPORTANT: Keys are MANDATORY for the Import API
// Products without keys cannot be imported or updated via Import API

// WARNING: Product import is a FULL REPLACE, not a merge.
// Omitting fields in a product import REMOVES existing values.
// Always include all fields you wish to retain.
```

## Category Import (Top-Down)

Categories must be imported from root to leaf so parent references resolve.

```typescript
interface CategoryImportData {
  key: string;
  name: Record<string, string>;
  slug: Record<string, string>;
  parentKey?: string;
  orderHint?: string;
}

async function importCategoriesTopDown(
  categories: CategoryImportData[],
  containerKey: string
): Promise<void> {
  // Sort: roots first, then children, then grandchildren
  const roots = categories.filter(c => !c.parentKey);
  const children = categories.filter(c => c.parentKey);

  // Import roots first
  if (roots.length > 0) {
    await batchImport(
      roots,
      containerKey,
      async (batch, key) => {
        await importApiRoot
          .categories()
          .importContainers()
          .withImportContainerKeyValue({ importContainerKey: key })
          .post({
            body: {
              type: 'category',
              resources: batch.map(cat => ({
                key: cat.key,
                name: cat.name,
                slug: cat.slug,
                orderHint: cat.orderHint,
              })),
            },
          })
          .execute();
      }
    );

    // Wait for roots to be imported before importing children
    await waitForImportCompletion(containerKey);
  }

  // Import children (they reference parents by key)
  if (children.length > 0) {
    await batchImport(
      children,
      containerKey,
      async (batch, key) => {
        await importApiRoot
          .categories()
          .importContainers()
          .withImportContainerKeyValue({ importContainerKey: key })
          .post({
            body: {
              type: 'category',
              resources: batch.map(cat => ({
                key: cat.key,
                name: cat.name,
                slug: cat.slug,
                parent: cat.parentKey
                  ? { typeId: 'category', key: cat.parentKey }
                  : undefined,
                orderHint: cat.orderHint,
              })),
            },
          })
          .execute();
      }
    );
  }
}
```

## Product Import with Variants

```typescript
async function importProductsWithVariants(
  containerKey: string
): Promise<void> {
  const productDrafts = [
    {
      key: 'classic-tee',
      name: { en: 'Classic T-Shirt', de: 'Klassisches T-Shirt' },
      productType: { typeId: 'product-type' as const, key: 'apparel' },
      slug: { en: 'classic-tee', de: 'klassisches-t-shirt' },
      categories: [
        { typeId: 'category' as const, key: 'mens-t-shirts' },
      ],
      masterVariant: {
        key: 'classic-tee-black-s',
        sku: 'TEE-BLK-S',
        attributes: [
          { name: 'color', value: { key: 'black' } },
          { name: 'size', value: { key: 'S' } },
        ],
        prices: [{
          value: { type: 'centPrecision' as const, currencyCode: 'EUR', centAmount: 2999, fractionDigits: 2 },
          country: 'DE',
        }],
      },
      variants: [
        {
          key: 'classic-tee-black-m',
          sku: 'TEE-BLK-M',
          attributes: [
            { name: 'color', value: { key: 'black' } },
            { name: 'size', value: { key: 'M' } },
          ],
          prices: [{
            value: { type: 'centPrecision' as const, currencyCode: 'EUR', centAmount: 2999, fractionDigits: 2 },
            country: 'DE',
          }],
        },
      ],
    },
  ];

  await batchImport(
    productDrafts,
    containerKey,
    async (batch, key) => {
      await importApiRoot
        .productDrafts()
        .importContainers()
        .withImportContainerKeyValue({ importContainerKey: key })
        .post({
          body: {
            type: 'product-draft',
            resources: batch,
          },
        })
        .execute();
    }
  );
}
```

## Common Import Pitfalls

1. **Duplicate concurrent imports:** Sending the same import request multiple times concurrently causes `ConcurrentModification` errors. Wait for acknowledgment before retrying.

2. **No deduplication:** The Import API does not deduplicate within a batch. If you send the same key twice in one request, both are processed (last one wins or conflict occurs).

3. **CSV format changes:** If using the Merchant Center CSV import, any change to the CSV column structure requires re-importing the entire file. Prefer the API for programmatic imports.

4. **Missing keys:** Every resource imported via the Import API MUST have a `key`. Products without keys cannot be updated via subsequent imports.

5. **Inventory without SKU:** Inventory imports match by SKU, not by product key. Ensure SKUs are set on variants before importing inventory.

## Design Checklist

- [ ] Import API client uses the correct host (`import.{region}.commercetools.com`)
- [ ] API client has `manage_import_containers` scope
- [ ] All resources have `key` values (mandatory for Import API)
- [ ] Batch size does not exceed 20 resources per request
- [ ] Import order respects dependency chain (types before products, products before inventory)
- [ ] Rate limiting is implemented between batches (200ms+ delay recommended)
- [ ] Import operation status is monitored and errors are logged
- [ ] Failed imports are retried with corrected data
- [ ] Import containers have fewer than 200,000 operations each
- [ ] Categories are imported top-down (parents before children)
- [ ] SKUs are finalized before importing inventory or prices
- [ ] Deduplication logic prevents concurrent duplicate imports

## Reference

- [Import API Overview](https://docs.commercetools.com/import-export/overview)
- [Import API Best Practices](https://docs.commercetools.com/api/import-export/best-practices)
- [@commercetools/importapi-sdk](https://www.npmjs.com/package/@commercetools/importapi-sdk)
