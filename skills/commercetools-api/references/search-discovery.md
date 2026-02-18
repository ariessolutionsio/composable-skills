# Search & Discovery

commercetools provides three ways to retrieve products: the Query API (real-time, not optimized for search), the Product Projection Search (legacy search), and the Product Search API (recommended). Using the wrong API for your use case causes 10-100x performance degradation on large catalogs.

## When to Use Which API

| API | Use Case | Performance | Real-Time |
|-----|----------|-------------|-----------|
| **Product Search API** | Storefront search, PLP, faceted navigation | Optimized (search infrastructure) | Eventually consistent |
| **Product Projection Search** | Legacy search, still supported | Optimized (search infrastructure) | Eventually consistent |
| **Product Projections Query** | Back-office, single product fetch by ID/key | Real-time | Yes |
| **Products Query** | Admin operations, import/export | Real-time (but large payloads) | Yes |

**Anti-Pattern (using Query API for storefront search):**
```typescript
// WRONG: Using the Query API for product listing pages
// Queries on attributes are not indexed and become extremely slow
const products = await apiRoot.productProjections().get({
  queryArgs: {
    where: 'variants.attributes.color.en = "Blue"',
    sort: ['name.en asc'],
    limit: 20,
  },
}).execute();
// This scans the entire product catalog — seconds instead of milliseconds
```

**Anti-Pattern (using /products instead of /product-projections):**
```typescript
// WRONG: /products returns both staged and current data
// Response payloads are approximately double the size
const products = await apiRoot.products().get({
  queryArgs: { limit: 20 },
}).execute();
// Each product contains masterData.staged AND masterData.current
```

**Recommended (Product Search API for discovery):**
```typescript
// Product Search API is backed by search-optimized infrastructure
const searchResponse = await apiRoot.productSearch().post({
  body: {
    query: {
      fullText: { field: 'name', language: 'en', value: 'cotton shirt' },
    },
    limit: 20,
  },
}).execute();
```

## Product Search API (Recommended)

### Full-Text Search with Filters and Facets

```typescript
import { ProductSearchRequest } from '@commercetools/platform-sdk';

const searchRequest: ProductSearchRequest = {
  query: {
    and: [
      {
        fullText: {
          field: 'name',
          language: 'en',
          value: 'cotton shirt',
        },
      },
      {
        filter: [
          {
            exact: {
              field: 'variants.attributes.color',
              fieldType: 'ltext',
              language: 'en',
              value: 'Blue',
            },
          },
        ],
      },
    ],
  },
  sort: [
    { field: 'name', language: 'en', order: 'asc' },
  ],
  facets: [
    {
      distinct: {
        name: 'categories',
        field: 'categories.id',
      },
    },
    {
      distinct: {
        name: 'sizes',
        field: 'variants.attributes.size',
        fieldType: 'enum',
      },
    },
    {
      ranges: {
        name: 'price-ranges',
        field: 'variants.prices.centAmount',
        ranges: [
          { from: 0, to: 2000 },
          { from: 2000, to: 5000 },
          { from: 5000 },
        ],
      },
    },
  ],
  markMatchingVariants: true,
  limit: 20,
  offset: 0,
};

const searchResponse = await apiRoot
  .productSearch()
  .post({ body: searchRequest })
  .execute();

const { results, total, facets } = searchResponse.body;
console.log(`Found ${total} products`);

results.forEach((result) => {
  console.log('Product ID:', result.productProjection?.id);
  if (result.matchingVariants) {
    result.matchingVariants.matchedVariants.forEach((mv) => {
      console.log(`  Matched variant SKU: ${mv.sku}`);
    });
  }
});
```

### Fetching Full Product Data After Search

The Product Search API returns product IDs and basic data. For full product details with prices, fetch separately.

```typescript
const productIds = searchResponse.body.results.map(
  (r) => `"${r.productProjection?.id}"`
);

if (productIds.length > 0) {
  const fullProducts = await apiRoot.productProjections().get({
    queryArgs: {
      where: `id in (${productIds.join(',')})`,
      staged: false,
      priceCurrency: 'EUR',
      priceCountry: 'DE',
      limit: productIds.length,
    },
  }).execute();
}
```

## Product Projection Search (Legacy)

Still widely used. Uses query parameters instead of a POST body.

```typescript
const projectionSearch = await apiRoot.productProjections().search().get({
  queryArgs: {
    'text.en': 'shirt',
    'filter': ['variants.attributes.size:"M"'],
    'filter.facets': ['categories.id'],
    'facet': [
      'variants.attributes.color.en',
      'variants.attributes.size',
      'variants.price.centAmount:range(0 to 2000),(2000 to 5000),(5000 to *)',
    ],
    sort: ['name.en asc'],
    limit: 20,
    offset: 0,
    staged: false,
    priceCurrency: 'EUR',
    priceCountry: 'DE',
  },
}).execute();
```

### filter vs filter.query vs filter.facets

| Parameter | Filters results | Affects facet counts |
|-----------|----------------|---------------------|
| `filter` | Yes | Yes (post-filter) |
| `filter.query` | Yes | No (pre-filter) |
| `filter.facets` | No | Yes (counts only) |

**Recommended:** Use `filter.query` for the primary category/collection filter. Use `filter` for user-selected refinements (so facet counts update to reflect the refinement).

## Search Performance Optimization

### Reduce Faceting Attributes

**Anti-Pattern (faceting on everything):**
```typescript
// Every additional facet increases response time
const search = await apiRoot.productProjections().search().get({
  queryArgs: {
    facet: [
      'variants.attributes.color.en',
      'variants.attributes.size',
      'variants.attributes.material.en',
      'variants.attributes.brand.en',
      'variants.attributes.season',
      'variants.attributes.gender',
      'variants.attributes.style',
      'variants.attributes.pattern',
      // 15 more facets...
    ],
  },
}).execute();
// Each facet computes a full aggregation across all matching products
```

**Recommended (limit to useful facets):**
```typescript
// Only request facets that are displayed in the UI
const search = await apiRoot.productProjections().search().get({
  queryArgs: {
    facet: [
      'variants.attributes.color.en',
      'variants.attributes.size',
      'variants.price.centAmount:range(0 to 5000),(5000 to 10000),(10000 to *)',
    ],
  },
}).execute();
```

### Category Navigation

**Anti-Pattern (assuming parent category includes children):**
```typescript
// WRONG: Querying parent category does NOT include subcategory products
const products = await apiRoot.productProjections().search().get({
  queryArgs: {
    filter: ['categories.id:"parent-category-id"'],
  },
}).execute();
// Products assigned only to child categories are NOT returned
```

**Recommended (use subtree filter):**
```typescript
// Use subtree to include all descendant categories
const products = await apiRoot.productProjections().search().get({
  queryArgs: {
    filter: ['categories.id: subtree("parent-category-id")'],
  },
}).execute();
// Returns products in the parent AND all child/grandchild categories
```

## GraphQL for Precise Data Fetching

For storefront product listing pages where you need minimal data per product, GraphQL significantly reduces payload size.

```typescript
const productListQuery = `
  query SearchProducts($text: String!, $locale: Locale!) {
    productProjectionSearch(text: $text, locale: $locale, limit: 20) {
      results {
        id
        name(locale: $locale)
        slug(locale: $locale)
        masterVariant {
          sku
          images { url }
          scopedPrice {
            value { centAmount currencyCode }
            discounted { value { centAmount currencyCode } }
          }
        }
      }
      total
    }
  }
`;

const result = await apiRoot.graphql().post({
  body: {
    query: productListQuery,
    variables: { text: 'shirt', locale: 'en' },
  },
}).execute();
```

## Product Projections Query (for Back-Office)

Use the Query API only for real-time operations where search indexing delay is unacceptable.

```typescript
// Get a single product by key (real-time)
const product = await apiRoot.productProjections()
  .withKey({ key: 'product-key' })
  .get({
    queryArgs: {
      staged: false,
      priceCurrency: 'EUR',
      priceCountry: 'DE',
    },
  })
  .execute();

// Query with predicates (suitable for small result sets)
const productList = await apiRoot.productProjections().get({
  queryArgs: {
    where: ['productType(id="product-type-id")'],
    sort: ['name.en asc'],
    expand: ['productType'],
    limit: 20,
    staged: false,
  },
}).execute();
```

## Checklist

- [ ] Storefront search uses the Product Search API, not the Query API
- [ ] Product listing pages use `/product-projections`, not `/products`
- [ ] Category navigation uses `subtree` filter for parent-child inclusion
- [ ] Faceting is limited to attributes actually displayed in the UI
- [ ] `filter.query` is used for primary filters, `filter` for user refinements
- [ ] GraphQL is used for listing pages to minimize payload size
- [ ] Search results are fetched with price scope (currency, country, customer group)
- [ ] Query API is reserved for back-office operations requiring real-time data
- [ ] `markMatchingVariants` is used to identify which variants matched the search
- [ ] Pagination uses reasonable limits (20-50 per page, not 500)
