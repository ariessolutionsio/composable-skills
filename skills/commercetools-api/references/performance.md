# Performance Optimization

commercetools is a cloud-native platform with built-in rate limiting, payload limits, and query complexity constraints. Understanding these limits and optimizing your API usage prevents cascading latency, rate limiting, and timeout failures in production.

## N+1 Query Pattern

The most common performance problem in commercetools integrations.

**Anti-Pattern (fetching related resources one by one):**
```typescript
// Product listing page: fetch 20 products, then fetch category data for each
const products = await apiRoot.productProjections().get({
  queryArgs: { limit: 20 },
}).execute();

// 20 additional API calls — one per product
for (const product of products.body.results) {
  for (const cat of product.categories) {
    const category = await apiRoot.categories().withId({ ID: cat.id }).get().execute();
    // N+1: 20 products * avg 2 categories = 40 extra API calls
  }
}
```

**Recommended (Reference Expansion):**
```typescript
// Include related resources in a single response
const products = await apiRoot.productProjections().get({
  queryArgs: {
    limit: 20,
    expand: [
      'categories[*]',
      'productType',
    ],
  },
}).execute();
// All category and product type data included — 1 API call total
```

**Recommended (batch fetch with predicates):**
```typescript
// If expansion is not available, batch-fetch with a single query
const categoryIds = products.body.results
  .flatMap((p) => p.categories.map((c) => `"${c.id}"`));

const categories = await apiRoot.categories().get({
  queryArgs: {
    where: `id in (${[...new Set(categoryIds)].join(',')})`,
    limit: 100,
  },
}).execute();
// 1 API call instead of 40
```

**Why This Matters:** Each API call adds 50-200ms of network latency. A product listing page with 20 products and N+1 queries takes 1-4 seconds instead of 100-200ms.

## Reference Expansion

### Only Expand What You Need

**Anti-Pattern (expanding everything):**
```typescript
// Expanding all references inflates response size dramatically
const order = await apiRoot.orders().withId({ ID: orderId }).get({
  queryArgs: {
    expand: [
      'lineItems[*].variant',
      'lineItems[*].variant.prices[*].customerGroup',
      'lineItems[*].variant.prices[*].channel',
      'lineItems[*].productType',
      'lineItems[*].supplyChannel',
      'lineItems[*].distributionChannel',
      'paymentInfo.payments[*]',
      'paymentInfo.payments[*].customer',
      'customer',
      'store',
      'state',
      // Response could be 500KB+ instead of 5KB
    ],
  },
}).execute();
```

**Recommended (expand only what the consumer uses):**
```typescript
// For an order confirmation page, expand only what's displayed
const order = await apiRoot.orders().withId({ ID: orderId }).get({
  queryArgs: {
    expand: [
      'paymentInfo.payments[*]', // payment details for receipt
      'lineItems[*].variant',    // product images for the confirmation
    ],
  },
}).execute();
```

### GraphQL for Selective Field Fetching

```typescript
// GraphQL returns only requested fields — no over-fetching
const query = `
  query GetOrder($id: String!) {
    order(id: $id) {
      orderNumber
      totalPrice { centAmount currencyCode }
      lineItems {
        name(locale: "en")
        quantity
        variant { sku images { url } }
      }
      shippingAddress { firstName lastName city country }
    }
  }
`;
```

## Pagination

### Omit Total Count When Not Needed

**Anti-Pattern (always requesting total):**
```typescript
// The `total` field adds computation overhead to every paginated query
const orders = await apiRoot.orders().get({
  queryArgs: {
    limit: 20,
    offset: 0,
    // total is included by default — adds overhead
  },
}).execute();
// orders.body.total — computed even if not displayed in the UI
```

**Recommended (omit total for scrolling/infinite scroll):**
```typescript
// For infinite scroll or "load more" patterns, total is unnecessary
const orders = await apiRoot.orders().get({
  queryArgs: {
    limit: 20,
    offset: 0,
    withTotal: false, // skip total count computation
  },
}).execute();
// Use `results.length < limit` to detect the last page
```

### Cursor-Based Pagination for Large Datasets

Offset-based pagination degrades as offset increases. Use ID-based cursoring for large datasets.

**Anti-Pattern (high offset pagination):**
```typescript
// Offset 10000 means the API must skip 10000 records before returning results
const page500 = await apiRoot.orders().get({
  queryArgs: {
    limit: 20,
    offset: 10000, // Slow: API scans 10000 records to skip them
    sort: ['createdAt desc'],
  },
}).execute();
```

**Recommended (cursor-based pagination):**
```typescript
// Use the last ID from the previous page as a cursor
let lastId: string | undefined;

async function getNextPage(limit: number = 20) {
  const queryArgs: any = {
    limit,
    sort: ['id asc'],
    withTotal: false,
  };

  if (lastId) {
    queryArgs.where = `id > "${lastId}"`;
  }

  const response = await apiRoot.orders().get({ queryArgs }).execute();
  const results = response.body.results;

  if (results.length > 0) {
    lastId = results[results.length - 1].id;
  }

  return results;
}
```

## Rate Limiting and Concurrency

### SDK Queue Middleware

```typescript
// Throttle concurrent requests to avoid overwhelming the API
const client = new ClientBuilder()
  .withClientCredentialsFlow(authMiddlewareOptions)
  .withQueueMiddleware({ concurrency: 20 }) // default is 20
  .withHttpMiddleware(httpMiddlewareOptions)
  .build();
```

### Bulk Import Throttling

For import operations, target approximately 300 API calls per second per project.

```typescript
// Rate-limited batch processor
async function importInBatches<T>(
  items: T[],
  processor: (batch: T[]) => Promise<void>,
  batchSize: number = 20,
  delayMs: number = 100
): Promise<void> {
  for (let i = 0; i < items.length; i += batchSize) {
    const batch = items.slice(i, i + batchSize);
    await processor(batch);

    // Delay between batches to stay under rate limits
    if (i + batchSize < items.length) {
      await new Promise((resolve) => setTimeout(resolve, delayMs));
    }
  }
}
```

### Retry with Exponential Backoff

```typescript
async function withRetry<T>(
  fn: () => Promise<T>,
  maxRetries: number = 3,
  baseDelay: number = 200
): Promise<T> {
  for (let attempt = 0; attempt <= maxRetries; attempt++) {
    try {
      return await fn();
    } catch (error: any) {
      const isRetryable = [429, 502, 503, 504].includes(error.statusCode);

      if (!isRetryable || attempt === maxRetries) {
        throw error;
      }

      const delay = baseDelay * Math.pow(2, attempt);
      const jitter = Math.random() * delay * 0.1;
      await new Promise((resolve) => setTimeout(resolve, delay + jitter));
    }
  }
  throw new Error('Unreachable');
}
```

## Document Size

### Keep Resources Under Size Limits

| Metric | Limit |
|--------|-------|
| Maximum JSON document size | 16 MB |
| Recommended average | Under 100 KB |
| Recommended maximum | Under 2 MB |

**Anti-Pattern (massive custom objects):**
```typescript
// WRONG: Storing a 5MB configuration blob in a single Custom Object
const customObject = await apiRoot.customObjects().post({
  body: {
    container: 'app-config',
    key: 'mega-config',
    value: hugeConfigObject, // 5MB of JSON
  },
}).execute();
// Slow reads, slow writes, risk of timeout
```

**Recommended (split across multiple objects):**
```typescript
// Split large data across multiple Custom Objects
await apiRoot.customObjects().post({
  body: {
    container: 'app-config',
    key: 'navigation',
    value: navigationConfig, // ~10KB
  },
}).execute();

await apiRoot.customObjects().post({
  body: {
    container: 'app-config',
    key: 'feature-flags',
    value: featureFlags, // ~2KB
  },
}).execute();
```

## Caching Strategies

### Cache Slow-Changing Data

```typescript
// Category trees change infrequently — cache aggressively
class CategoryCache {
  private cache: Map<string, { data: any; expiry: number }> = new Map();
  private ttlMs: number = 5 * 60 * 1000; // 5 minutes

  async getCategoryTree(): Promise<Category[]> {
    const cached = this.cache.get('tree');
    if (cached && cached.expiry > Date.now()) {
      return cached.data;
    }

    const response = await apiRoot.categories().get({
      queryArgs: { limit: 500, sort: ['orderHint asc'] },
    }).execute();

    this.cache.set('tree', {
      data: response.body.results,
      expiry: Date.now() + this.ttlMs,
    });

    return response.body.results;
  }

  invalidate(): void {
    this.cache.delete('tree');
  }
}
```

### Use Subscriptions for Cache Invalidation

```typescript
// Subscribe to category changes instead of polling
const categorySub = await apiRoot.subscriptions().post({
  body: {
    key: 'category-cache-invalidation',
    destination: { type: 'SQS', queueUrl: '...', region: '...' },
    changes: [{ resourceTypeId: 'category' }],
  },
}).execute();

// In your message handler:
async function handleCategoryChange(message: any) {
  categoryCache.invalidate();
}
```

## Locale Projection

In multi-language projects, reduce response size by requesting only the needed locale.

```typescript
// Without locale projection: all locales returned
// { name: { en: "Shirt", de: "Hemd", fr: "Chemise", es: "Camisa" } }

// With locale projection: only requested locale
const product = await apiRoot.productProjections()
  .withKey({ key: 'product-key' })
  .get({
    queryArgs: {
      localeProjection: ['en'], // only English content
    },
  })
  .execute();
// { name: { en: "Shirt" } } — smaller payload
```

## Parallel API Calls

**Anti-Pattern (sequential calls):**
```typescript
// Sequential: total time = sum of all API calls
const cart = await apiRoot.carts().withId({ ID: cartId }).get().execute();
const customer = await apiRoot.customers().withId({ ID: customerId }).get().execute();
const shippingMethods = await apiRoot.shippingMethods().get().execute();
// Total: ~600ms (200ms + 200ms + 200ms)
```

**Recommended (parallel where possible):**
```typescript
// Parallel: total time = slowest API call
const [cart, customer, shippingMethods] = await Promise.all([
  apiRoot.carts().withId({ ID: cartId }).get().execute(),
  apiRoot.customers().withId({ ID: customerId }).get().execute(),
  apiRoot.shippingMethods().get().execute(),
]);
// Total: ~200ms (all three run simultaneously)
```

## Performance Checklist

- [ ] Storefront product discovery uses the Product Search API or Product Projection Search
- [ ] Product listing pages use `/product-projections`, not `/products`
- [ ] Reference expansion is limited to fields the consumer actually uses
- [ ] GraphQL is used for listing pages to request only needed fields
- [ ] `withTotal: false` is set on paginated queries where total is not displayed
- [ ] Cursor-based pagination is used for large datasets (offset > 1000)
- [ ] SDK queue middleware is configured (default concurrency: 20)
- [ ] Retry logic uses exponential backoff starting at 200ms
- [ ] Category trees and other slow-changing data are cached
- [ ] Cache invalidation uses Subscriptions, not polling
- [ ] JSON documents stay under 100KB average (2MB max)
- [ ] `localeProjection` is used in multi-language projects
- [ ] Independent API calls are parallelized with `Promise.all`
- [ ] Update actions are batched into single requests
- [ ] Bulk imports are rate-limited to ~300 calls/second per project
