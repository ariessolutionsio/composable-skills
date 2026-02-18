# Bulk Catalog Operations: Auditing & Batch Updates

Patterns for querying, auditing catalog completeness, batch updating products, and generating missing slugs in commercetools.

**Impact: MEDIUM -- Patterns for auditing, enriching, and bulk-updating product catalogs at scale.**

This reference covers practical patterns for catalog maintenance tasks: finding products with missing data (slugs, descriptions, images), batch-updating products, and using AI to enrich product content. These operations use the commercetools HTTP API (not the Import API) because they target existing products with surgical updates rather than full resource replacement.

## When to Use These Patterns

- **Catalog audit:** "Do all products have slugs for all required locales?"
- **Data completeness:** "Which products are missing descriptions?"
- **Bulk enrichment:** "Generate SEO-friendly descriptions for products that lack them"
- **Data cleanup:** "Normalize attribute values across the catalog"
- **Locale expansion:** "Add French translations to all product names and descriptions"

## API Client Setup

All patterns use the commercetools Platform SDK v3:

```typescript
import { createApiBuilderFromCtpClient } from '@commercetools/platform-sdk';
import { ClientBuilder } from '@commercetools/ts-client';

const projectKey = process.env.CTP_PROJECT_KEY!;

const client = new ClientBuilder()
  .withProjectKey(projectKey)
  .withClientCredentialsFlow({
    host: 'https://auth.europe-west1.gcp.commercetools.com',
    projectKey,
    credentials: {
      clientId: process.env.CTP_CLIENT_ID!,
      clientSecret: process.env.CTP_CLIENT_SECRET!,
    },
    httpClient: fetch,
  })
  .withHttpMiddleware({
    host: 'https://api.europe-west1.gcp.commercetools.com',
    httpClient: fetch,
  })
  .build();

const apiRoot = createApiBuilderFromCtpClient(client)
  .withProjectKey({ projectKey });
```

## Pattern 1: Paginated Product Query

All bulk operations start with querying the catalog. The API returns max 500 results per request with a max offset of 10,000. For larger catalogs, use `sort` + `where` with the last ID for cursor-based pagination.

```typescript
import { Product, ProductProjection } from '@commercetools/platform-sdk';

/**
 * Iterate over ALL products in the catalog using cursor-based pagination.
 * Uses Product Projections (staged=true) to include unpublished changes.
 */
async function* iterateAllProducts(
  options: {
    where?: string[];
    expand?: string[];
    staged?: boolean;
    limit?: number;
  } = {}
): AsyncGenerator<ProductProjection> {
  const { where = [], expand = [], staged = true, limit = 500 } = options;
  let lastId: string | undefined;

  while (true) {
    const wherePredicates = [...where];
    if (lastId) {
      wherePredicates.push(`id > "${lastId}"`);
    }

    const response = await apiRoot
      .productProjections()
      .get({
        queryArgs: {
          where: wherePredicates.length > 0 ? wherePredicates : undefined,
          expand: expand.length > 0 ? expand : undefined,
          staged,
          limit,
          sort: ['id asc'],
          withTotal: false,
        },
      })
      .execute();

    for (const product of response.body.results) {
      yield product;
    }

    if (response.body.results.length < limit) break;
    lastId = response.body.results[response.body.results.length - 1].id;
  }
}
```

## Pattern 2: Find Products Missing Slugs

Product slugs are required at creation, but they may be missing for specific locales. This finds products where a target locale's slug is absent.

```typescript
/**
 * Find products missing a slug for a specific locale.
 */
async function findProductsMissingSlugs(
  locale: string
): Promise<ProductProjection[]> {
  const missing: ProductProjection[] = [];

  for await (const product of iterateAllProducts({ staged: true })) {
    if (!product.slug[locale]) {
      missing.push(product);
    }
  }

  console.log(`Found ${missing.length} products missing slug for locale "${locale}"`);
  return missing;
}

// Usage
const missingSlugs = await findProductsMissingSlugs('en');
const missingFrenchSlugs = await findProductsMissingSlugs('fr');
```

## Pattern 3: Find Products Missing Descriptions

```typescript
/**
 * Find products missing a description for any of the specified locales.
 */
async function findProductsMissingDescriptions(
  locales: string[]
): Promise<{ product: ProductProjection; missingLocales: string[] }[]> {
  const results: { product: ProductProjection; missingLocales: string[] }[] = [];

  for await (const product of iterateAllProducts({ staged: true })) {
    const missingLocales = locales.filter(
      locale => !product.description?.[locale]
    );
    if (missingLocales.length > 0) {
      results.push({ product, missingLocales });
    }
  }

  console.log(`Found ${results.length} products missing descriptions`);
  return results;
}

// Usage
const missing = await findProductsMissingDescriptions(['en', 'de', 'fr']);
```

## Pattern 4: General Catalog Audit

```typescript
interface AuditResult {
  productId: string;
  productKey?: string;
  name: string;
  issues: string[];
}

/**
 * Audit the catalog for common data quality issues.
 */
async function auditCatalog(
  requiredLocales: string[]
): Promise<AuditResult[]> {
  const issues: AuditResult[] = [];

  for await (const product of iterateAllProducts({ staged: true })) {
    const productIssues: string[] = [];
    const name = product.name['en'] || Object.values(product.name)[0] || 'UNNAMED';

    // Check slugs
    for (const locale of requiredLocales) {
      if (!product.slug[locale]) {
        productIssues.push(`Missing slug for locale "${locale}"`);
      }
    }

    // Check descriptions
    for (const locale of requiredLocales) {
      if (!product.description?.[locale]) {
        productIssues.push(`Missing description for locale "${locale}"`);
      }
    }

    // Check meta title and description (SEO)
    for (const locale of requiredLocales) {
      if (!product.metaTitle?.[locale]) {
        productIssues.push(`Missing metaTitle for locale "${locale}"`);
      }
      if (!product.metaDescription?.[locale]) {
        productIssues.push(`Missing metaDescription for locale "${locale}"`);
      }
    }

    // Check master variant has images
    if (!product.masterVariant.images || product.masterVariant.images.length === 0) {
      productIssues.push('Master variant has no images');
    }

    // Check master variant has prices
    if (!product.masterVariant.prices || product.masterVariant.prices.length === 0) {
      productIssues.push('Master variant has no prices');
    }

    // Check all variants have SKUs
    const allVariants = [product.masterVariant, ...(product.variants || [])];
    for (const variant of allVariants) {
      if (!variant.sku) {
        productIssues.push(`Variant ${variant.id} missing SKU`);
      }
    }

    // Check product has a key (needed for Import API)
    if (!product.key) {
      productIssues.push('Product missing key (required for Import API)');
    }

    if (productIssues.length > 0) {
      issues.push({
        productId: product.id,
        productKey: product.key,
        name,
        issues: productIssues,
      });
    }
  }

  // Summary
  const issueCounts: Record<string, number> = {};
  for (const result of issues) {
    for (const issue of result.issues) {
      const category = issue.replace(/ for locale ".*"/, ' for locale');
      issueCounts[category] = (issueCounts[category] || 0) + 1;
    }
  }

  console.log('\n=== Catalog Audit Summary ===');
  console.log(`Total products with issues: ${issues.length}`);
  for (const [issue, count] of Object.entries(issueCounts).sort((a, b) => b[1] - a[1])) {
    console.log(`  ${issue}: ${count}`);
  }

  return issues;
}

// Usage
const auditResults = await auditCatalog(['en', 'de']);
```

## Pattern 5: Batch Update Products

```typescript
import { ProductUpdateAction } from '@commercetools/platform-sdk';

interface ProductUpdate {
  productId: string;
  version: number;
  actions: ProductUpdateAction[];
}

/**
 * Batch-update products with retry on ConcurrentModification.
 */
async function batchUpdateProducts(
  updates: ProductUpdate[],
  options: {
    concurrency?: number;
    retries?: number;
    delayMs?: number;
  } = {}
): Promise<{ succeeded: number; failed: number; errors: string[] }> {
  const { concurrency = 5, retries = 3, delayMs = 100 } = options;
  let succeeded = 0;
  let failed = 0;
  const errors: string[] = [];

  // Process in chunks for controlled concurrency
  for (let i = 0; i < updates.length; i += concurrency) {
    const chunk = updates.slice(i, i + concurrency);

    const results = await Promise.allSettled(
      chunk.map(async (update) => {
        let currentVersion = update.version;

        for (let attempt = 0; attempt <= retries; attempt++) {
          try {
            await apiRoot
              .products()
              .withId({ ID: update.productId })
              .post({
                body: {
                  version: currentVersion,
                  actions: update.actions,
                },
              })
              .execute();
            return; // success
          } catch (error: any) {
            if (error.statusCode === 409 && attempt < retries) {
              // ConcurrentModification -- refetch version and retry
              const fresh = await apiRoot
                .products()
                .withId({ ID: update.productId })
                .get()
                .execute();
              currentVersion = fresh.body.version;
              await new Promise(r => setTimeout(r, delayMs * (attempt + 1)));
            } else {
              throw error;
            }
          }
        }
      })
    );

    for (const result of results) {
      if (result.status === 'fulfilled') {
        succeeded++;
      } else {
        failed++;
        errors.push(result.reason?.message || 'Unknown error');
      }
    }

    // Rate limiting between chunks
    if (i + concurrency < updates.length) {
      await new Promise(r => setTimeout(r, delayMs));
    }
  }

  console.log(`Batch update complete: ${succeeded} succeeded, ${failed} failed`);
  return { succeeded, failed, errors };
}
```

## Pattern 6: Generate Missing Slugs

Slugs must match the pattern `[a-zA-Z0-9_-]{2,256}` and be unique across the project per locale.

```typescript
/**
 * Generate a URL-safe slug from a product name.
 */
function generateSlug(name: string): string {
  return name
    .toLowerCase()
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')  // Remove diacritics
    .replace(/[^a-z0-9]+/g, '-')      // Replace non-alphanumeric with hyphens
    .replace(/^-+|-+$/g, '')           // Trim leading/trailing hyphens
    .replace(/-{2,}/g, '-')            // Collapse multiple hyphens
    .slice(0, 256);                    // Max 256 chars
}

/**
 * Find products missing slugs and generate them from product names.
 */
async function generateMissingSlugs(
  locale: string,
  options: { dryRun?: boolean } = {}
): Promise<ProductUpdate[]> {
  const updates: ProductUpdate[] = [];

  for await (const product of iterateAllProducts({ staged: true })) {
    if (product.slug[locale]) continue;  // Already has slug

    const name = product.name[locale];
    if (!name) {
      console.warn(`Product ${product.id} has no name for locale "${locale}" -- skipping`);
      continue;
    }

    // Generate slug and append product key for uniqueness
    let slug = generateSlug(name);
    if (product.key) {
      slug = `${slug}-${product.key}`.slice(0, 256);
    }

    updates.push({
      productId: product.id,
      version: product.version,
      actions: [{
        action: 'changeSlug',
        slug: { ...product.slug, [locale]: slug },
        staged: true,
      }],
    });
  }

  console.log(`Generated ${updates.length} slug updates for locale "${locale}"`);

  if (!options.dryRun && updates.length > 0) {
    await batchUpdateProducts(updates);
  }

  return updates;
}

// Usage
const slugUpdates = await generateMissingSlugs('en', { dryRun: true });  // Preview first
await generateMissingSlugs('en');  // Then apply
```
