# Product Listing Pages (PLP)

Search API integration, server components, faceted filter UI, and ProductListProvider patterns for product listing pages in commercetools storefronts.

**Impact: HIGH -- Over-fetching, N+1 queries, and missing variant logic directly impact conversion rates and page speed**

## Table of Contents
- [Product Listing Page (PLP) Patterns](#product-listing-page-plp-patterns)
  - [Pattern 1: Using Product Search API (Not Product Projections Query)](#pattern-1-using-product-search-api-not-product-projections-query)
  - [Pattern 2: PLP Server Component](#pattern-2-plp-server-component)
  - [Pattern 3: Faceted Filter UI (Client Component)](#pattern-3-faceted-filter-ui-client-component)
  - [Pattern 3b: ProductListProvider Context (scaffold)](#pattern-3b-productlistprovider-context-scaffold)

## Product Listing Page (PLP) Patterns

### Pattern 1: Using Product Search API (Not Product Projections Query)

For listing pages, always use the Product Search API. It provides full-text search, faceting, and sorting in a single request. The older Product Projections query endpoint works but lacks search relevance and efficient faceting.

**INCORRECT -- using product projections query for search:**

```typescript
// WRONG: Product Projections query does not support full-text relevance or efficient facets
const response = await apiRoot
  .productProjections()
  .get({
    queryArgs: {
      where: `categories(id="${categoryId}")`,
      limit: 20,
      offset: page * 20,
      // No faceting, no relevance scoring, no typo tolerance
    },
  })
  .execute();
```

**CORRECT -- using Product Search API:**

```typescript
// lib/commercetools/product-search.ts
import { apiRoot } from './client';
import type { ProductProjection } from '@commercetools/platform-sdk';

interface PLPParams {
  categoryId?: string;
  searchQuery?: string;
  filters?: Record<string, string[]>;
  sort?: string;
  page?: number;
  pageSize?: number;
  locale: string;
  currency: string;
  country: string;
}

interface PLPResult {
  products: ProductProjection[];
  total: number;
  facets: Record<string, FacetResult>;
}

interface FacetResult {
  terms: Array<{ term: string; count: number }>;
}

export async function getProductListing(params: PLPParams): Promise<PLPResult> {
  const {
    categoryId,
    searchQuery,
    filters = {},
    sort = 'score desc',
    page = 0,
    pageSize = 24,
    locale,
    currency,
    country,
  } = params;

  const filterQueries: string[] = [];

  // Category filter
  if (categoryId) {
    filterQueries.push(`categories.id:subtree("${categoryId}")`);
  }

  // Dynamic attribute filters (from URL query params)
  for (const [key, values] of Object.entries(filters)) {
    if (values.length > 0) {
      const quoted = values.map((v) => `"${v}"`).join(',');
      filterQueries.push(`variants.attributes.${key}.key:${quoted}`);
    }
  }

  // Price filter -- filter for products with prices in this currency/country
  filterQueries.push(`variants.prices.value.currencyCode:"${currency}"`);

  const response = await apiRoot
    .productProjections()
    .search()
    .get({
      queryArgs: {
        [`text.${locale}`]: searchQuery || undefined,
        'filter.query': filterQueries,
        facet: [
          'variants.attributes.color.key',
          'variants.attributes.size.key',
          'variants.attributes.brand.key',
          `variants.scopedPrice.value.centAmount:range(0 to *)`,
        ],
        sort: [sort],
        limit: pageSize,
        offset: page * pageSize,
        priceCurrency: currency,
        priceCountry: country,
        markMatchingVariants: true,
      },
    })
    .execute();

  return {
    products: response.body.results,
    total: response.body.total ?? 0,
    facets: response.body.facets as unknown as Record<string, FacetResult>,
  };
}
```

### Pattern 2: PLP Server Component

```typescript
// app/[locale]/category/[slug]/page.tsx
import { getProductListing } from '@/lib/commercetools/product-search';
import { getCategoryBySlug } from '@/lib/commercetools/categories';
import { ProductGrid } from '@/components/product/ProductGrid';
import { FacetSidebar } from '@/components/product/FacetSidebar';
import { Pagination } from '@/components/ui/Pagination';
import { notFound } from 'next/navigation';

export const revalidate = 120; // ISR: 2 minutes

interface Props {
  params: { locale: string; slug: string };
  searchParams: { page?: string; sort?: string; [key: string]: string | undefined };
}

export default async function CategoryPage({ params, searchParams }: Props) {
  const category = await getCategoryBySlug(params.slug, params.locale);
  if (!category) notFound();

  // Parse filter params from URL: ?color=red,blue&size=M
  const filters: Record<string, string[]> = {};
  for (const [key, value] of Object.entries(searchParams)) {
    if (key !== 'page' && key !== 'sort' && value) {
      filters[key] = value.split(',');
    }
  }

  const { products, total, facets } = await getProductListing({
    categoryId: category.id,
    filters,
    sort: searchParams.sort || 'score desc',
    page: parseInt(searchParams.page || '0', 10),
    pageSize: 24,
    locale: params.locale,
    currency: 'USD',
    country: 'US',
  });

  return (
    <div>
      <FacetSidebar facets={facets} activeFilters={filters} />
      <div>
        <h1>{category.name[params.locale]}</h1>
        <p>{total} products</p>
        <ProductGrid products={products} locale={params.locale} />
        <Pagination total={total} pageSize={24} />
      </div>
    </div>
  );
}
```

### Pattern 3: Faceted Filter UI (Client Component)

```typescript
// components/product/FacetSidebar.tsx
'use client';

import { useRouter, usePathname, useSearchParams } from 'next/navigation';
import { useCallback } from 'react';

interface FacetResult {
  terms: Array<{ term: string; count: number }>;
}

interface Props {
  facets: Record<string, FacetResult>;
  activeFilters: Record<string, string[]>;
}

export function FacetSidebar({ facets, activeFilters }: Props) {
  const router = useRouter();
  const pathname = usePathname();
  const searchParams = useSearchParams();

  const toggleFilter = useCallback(
    (facetKey: string, value: string) => {
      const params = new URLSearchParams(searchParams.toString());
      const current = params.get(facetKey)?.split(',') || [];

      if (current.includes(value)) {
        const updated = current.filter((v) => v !== value);
        if (updated.length === 0) {
          params.delete(facetKey);
        } else {
          params.set(facetKey, updated.join(','));
        }
      } else {
        params.set(facetKey, [...current, value].join(','));
      }

      // Reset to page 0 when filters change
      params.delete('page');

      router.push(`${pathname}?${params.toString()}`, { scroll: false });
    },
    [router, pathname, searchParams]
  );

  return (
    <aside>
      {Object.entries(facets).map(([key, facet]) => {
        // Extract attribute name from facet key
        const attrName = key.replace('variants.attributes.', '').replace('.key', '');
        const activeFacet = activeFilters[attrName] || [];

        return (
          <div key={key}>
            <h3>{attrName}</h3>
            <ul>
              {facet.terms.map((term) => (
                <li key={term.term}>
                  <label>
                    <input
                      type="checkbox"
                      checked={activeFacet.includes(term.term)}
                      onChange={() => toggleFilter(attrName, term.term)}
                    />
                    <span>{term.term}</span>
                    <span>({term.count})</span>
                  </label>
                </li>
              ))}
            </ul>
          </div>
        );
      })}
    </aside>
  );
}
```

### Pattern 3b: ProductListProvider Context (scaffold)

> From the official `scaffold-b2c` repo: The scaffold uses a dedicated React Context to manage the full filter/sort/pagination state, with URL-driven refinements applied via `router.push`.

```typescript
// components/commercetools-ui/organisms/product/product-list/context/index.tsx (scaffold-b2c)
export const ProductListContext = createContext<ProductListContextShape>({
  categories: [], pricesConfiguration: {}, facetsConfiguration: {},
  totalItems: 0, activeRefinements: [],
  refine() {}, refineRange() {}, replaceSort() {}, removeAllRefinements() {}, loadMore() {},
});

const ProductListProvider = ({ children, uiState, facetsConfiguration, ... }) => {
  const router = useRouter();
  const searchParams = useSearchParams();

  const applyRefinements = useCallback((facetsConfiguration, sort?, limit?) => {
    const params = new URLSearchParams();
    Object.values(facetsConfiguration).forEach((config) => {
      if (!config.selected) return;
      if (config.type === 'range') {
        params.set(`facets[${config.key}][min]`, config.minSelected.toString());
        params.set(`facets[${config.key}][max]`, config.maxSelected.toString());
      } else if (config.type === 'term') {
        config.terms.filter((t) => t.selected)
          .forEach((term, i) => params.set(`facets[${config.key}][terms][${i}]`, term.key));
      }
    });
    if (sort?.attribute) params.set(`sortAttributes[0][${sort.attribute}]`, sort.value);
    router.push(`${pathWithoutQuery}?${params.toString()}`);
  }, [router, pathWithoutQuery]);
  // ... refine, refineRange, replaceSort, removeAllRefinements, loadMore
};
export const useProductList = () => useContext(ProductListContext);
```

Key insight: Filters are serialized to URL params and applied via `router.push`, making the filter state shareable and SEO-friendly. The scaffold uses structured param keys like `facets[color][terms][0]` rather than comma-separated values, which avoids encoding issues and supports range facets natively.
