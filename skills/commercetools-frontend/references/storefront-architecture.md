# Headless Storefront Architecture with Next.js

**Impact: CRITICAL -- Wrong architecture choices cause stale data, slow pages, API quota exhaustion, and credential leaks**

> **Note:** Many patterns in this reference are derived from the official **commercetools Frontend scaffold-b2c** repository. Where a pattern comes from the scaffold, it is marked with **(scaffold)**. Generic Next.js + commercetools patterns that apply to any headless build are unmarked.

This reference covers building headless commerce storefronts with Next.js (App Router) and React against the commercetools APIs. If you are using commercetools Frontend (the hosted product with Studio), see `ct-frontend.md` instead -- though many rendering and i18n patterns here apply to both approaches.

## Table of Contents
- [Architecture Overview](#architecture-overview)
- [Pattern 1: SDK Client Setup for Next.js](#pattern-1-sdk-client-setup-for-nextjs)
- [Pattern 2: Data Fetching Strategies](#pattern-2-data-fetching-strategies)
- [Pattern 2b: Catch-All Routing with Parallel Data Fetching (scaffold)](#pattern-2b-catch-all-routing-with-parallel-data-fetching-scaffold)
  - [Request Deduplication with React cache() (scaffold)](#request-deduplication-with-react-cache-scaffold)
- [Pattern 3: Server Components vs Client Components](#pattern-3-server-components-vs-client-components)
- [Pattern 3b: SSR + SWR Hydration (scaffold)](#pattern-3b-ssr--swr-hydration-scaffold)
- [Pattern 4: GraphQL vs REST for Frontend](#pattern-4-graphql-vs-rest-for-frontend)
- [Pattern 5: Internationalization (i18n) with Locale Routing](#pattern-5-internationalization-i18n-with-locale-routing)
  - [Locale Routing with next-intl (scaffold)](#locale-routing-with-next-intl-scaffold)
  - [Locale-Currency Mapping (scaffold)](#locale-currency-mapping-scaffold)
  - [Middleware for Locale Detection (scaffold)](#middleware-for-locale-detection-scaffold)
  - [Message Loading with Fallback (scaffold)](#message-loading-with-fallback-scaffold)
  - [Layout with Locale Segment](#layout-with-locale-segment)
  - [Localized String Helpers](#localized-string-helpers)
  - [CurrencyHelpers (scaffold)](#currencyhelpers-scaffold)
- [Pattern 6: Error Boundaries for Commerce Data](#pattern-6-error-boundaries-for-commerce-data)
- [Pattern 7: Route Handlers for Mutations](#pattern-7-route-handlers-for-mutations)
- [Pattern 8: Customer Authentication](#pattern-8-customer-authentication)
- [Architecture Checklist](#architecture-checklist)
- [Reference](#reference)

## Architecture Overview

A headless commercetools storefront consists of three layers:

1. **Rendering layer** -- Next.js App Router with Server Components and Client Components
2. **Data layer** -- commercetools TypeScript SDK or GraphQL calls, wrapped in a service layer
3. **State layer** -- React context or state management for client-side cart, auth, and UI state

```
Browser
  |
  v
Next.js App Router (Vercel / Netlify)
  |-- Server Components: product data, category data, static content
  |-- Client Components: cart, search autocomplete, variant selectors
  |-- Route Handlers: cart mutations, auth, checkout session
  |
  v
commercetools APIs (HTTP REST or GraphQL)
  |-- Product Projections / Product Search
  |-- Carts, Orders, Customers
  |-- Checkout (hosted checkout product)
```

## Pattern 1: SDK Client Setup for Next.js

Create a singleton client for server-side usage. Never expose API credentials to the browser.

**INCORRECT:** Creating a new `ClientBuilder` inside a component or page function. This causes a new client per render (memory leak, token exhaustion). Always use a singleton.

**CORRECT -- singleton client in a dedicated module:**

```typescript
// lib/commercetools/client.ts
import { createApiBuilderFromCtpClient } from '@commercetools/platform-sdk';
import { ClientBuilder } from '@commercetools/ts-client';

const projectKey = process.env.CTP_PROJECT_KEY!;

const client = new ClientBuilder()
  .withClientCredentialsFlow({
    host: process.env.CTP_AUTH_URL!,
    projectKey,
    credentials: {
      clientId: process.env.CTP_CLIENT_ID!,
      clientSecret: process.env.CTP_CLIENT_SECRET!,
    },
  })
  .withHttpMiddleware({
    host: process.env.CTP_API_URL!,
  })
  .build();

export const apiRoot = createApiBuilderFromCtpClient(client)
  .withProjectKey({ projectKey });
```

```typescript
// lib/commercetools/products.ts
import { apiRoot } from './client';

export async function getProductBySlug(slug: string, locale: string) {
  const response = await apiRoot
    .productProjections()
    .search()
    .get({
      queryArgs: {
        filter: [`slug.${locale}:"${slug}"`],
        limit: 1,
      },
    })
    .execute();

  return response.body.results[0] ?? null;
}
```

## Pattern 2: Data Fetching Strategies

Choose the right rendering strategy for each page type.

| Page Type | Strategy | Why |
|-----------|----------|-----|
| Product Detail Page (PDP) | **ISR** (revalidate 60-300s) | Products change infrequently; ISR gives fast TTFB with eventual consistency |
| Product Listing Page (PLP) | **ISR** (revalidate 60-300s) | Same rationale; search results are not real-time |
| Category Page | **ISR** (revalidate 300-3600s) | Categories change rarely |
| Cart Page | **Client-side** + Server Component shell | Cart is per-user, changes frequently; server renders the shell |
| Checkout | **Client-side** with Route Handlers | Highly interactive, per-session state |
| Homepage | **ISR** (revalidate 60-300s) | Mostly static content with promotional slots |
| Search Results | **Server Component** with `searchParams` | URL-driven, needs fresh results, good for SEO |

**INCORRECT:** Setting `export const dynamic = 'force-dynamic'` on catalog pages. This forces a server hit on every page view, eliminating caching benefits. Use ISR instead.

**CORRECT -- ISR with revalidation:**

```typescript
// app/products/[slug]/page.tsx
import { getProductBySlug } from '@/lib/commercetools/products';
import { ProductDetail } from '@/components/product/ProductDetail';
import { notFound } from 'next/navigation';

// Revalidate every 60 seconds -- balances freshness with performance
export const revalidate = 60;

export default async function ProductPage({
  params,
}: {
  params: { slug: string };
}) {
  const product = await getProductBySlug(params.slug, 'en');

  if (!product) {
    notFound();
  }

  return <ProductDetail product={product} />;
}

// Generate static paths for high-traffic products at build time
export async function generateStaticParams() {
  const topProducts = await getTopProducts(100);
  return topProducts.map((p) => ({ slug: p.slug['en'] }));
}
```

## Pattern 2b: Catch-All Routing with Parallel Data Fetching (scaffold)

The official scaffold uses a **single catch-all route** to render every page. The CMS (Studio) determines what content appears for each URL. This avoids duplicating page files for products, categories, content pages, etc.

```typescript
// app/[locale]/[[...slug]]/page.tsx
export const revalidate = 120; // 2-minute ISR

export default async function Page(props: PageProps) {
  const { locale } = await props.params;
  sdk.defaultConfigure(locale);

  // Parallel data fetching with Promise.all -- all independent requests fire at once
  const [page, accountResult, projectSettings, categoriesResult, flattenedCategoriesResult] = await Promise.all([
    fetchPageData(params, searchParams),
    fetchAccount(),
    fetchProjectSettings(),
    fetchCategories({ format: 'tree' }),
    fetchCategories({ format: 'flat' }),
  ]);

  if (page.isError) return redirect('/404');
  if (isRedirectResponse(page.data)) redirect((page.data as RedirectResponse).target);

  return (
    <Providers accountResult={accountResult} projectSettings={projectSettings} page={page}>
      <Renderer data={page.data} params={params} searchParams={searchParams} categories={categories} />
    </Providers>
  );
}
```

`Promise.all` eliminates request waterfalls -- total latency equals the slowest single call. The `<Renderer>` inspects page data to determine which component tree to render (PDP, PLP, cart, content page, etc.).

### Request Deduplication with React `cache()` (scaffold)

The scaffold wraps page-data fetches in `React.cache()` so multiple Server Components within a single request share the result:

```typescript
// helpers/server/fetch-page-data.ts
import 'server-only';
import { cache } from 'react';

const memoizedFetchPageData = cache(async (slug: string, qs: string) => {
  return sdk.page.getPage({
    path: slug,
    query: Object.fromEntries(new URLSearchParams(qs).entries()),
    ...(await getServerOptions()),
  });
});
```

`'server-only'` prevents accidental client-bundle inclusion. `cache()` deduplicates within a single render pass -- it does **not** persist across requests (use `revalidate` for that).

## Pattern 3: Server Components vs Client Components

**Rule of thumb:** Fetch commerce data in Server Components (the default in App Router). Make it interactive in Client Components marked with `'use client'`. Server Components keep API credentials off the browser and render product data as static HTML. Client Components handle mutations (add-to-cart, variant selectors, search autocomplete). Pattern 2 above demonstrates this split -- the page function is a Server Component; interactive cart/checkout pieces are Client Components.

## Pattern 3b: SSR + SWR Hydration (scaffold)

The scaffold pre-loads server-fetched data into SWR via `fallback`, so Client Components get instant access to data that was already fetched on the server -- no extra network request, no loading spinner.

```typescript
// providers/index.tsx
<SWRProvider value={{
  fallback: {
    '/action/account/getAccount': accountResult,
    '/action/project/getProjectSettings': projectSettings,
  },
}}>
```

SWR is configured to avoid unnecessary revalidation for data that was just fetched on the server:

```typescript
<SWRConfig value={{
  revalidateIfStale: false,    // Don't refetch data we just got from the server
  revalidateOnFocus: false,    // Don't refetch when the tab regains focus
  revalidateOnReconnect: true, // Do refetch when network reconnects (stale data likely)
}}>
```

**How it fits together:** The catch-all route (Pattern 2b) fetches data on the server and passes it to `<Providers>`, which wraps the tree in `SWRConfig` with `fallback`. Any Client Component calling `useSWR('/action/account/getAccount')` gets the server result immediately. Mutations use SWR's `mutate()` to update the cache client-side.

## Pattern 4: GraphQL vs REST for Frontend

| Factor | GraphQL | REST (TypeScript SDK) |
|--------|---------|----------------------|
| Payload size | Fetch exactly what you need | Full resource returned (use `expand` selectively) |
| Type safety | Requires codegen (e.g., graphql-codegen) | Built-in with `@commercetools/platform-sdk` |
| Complexity | Higher setup, query management | Simpler, method-chain API |
| Best for | PDPs with complex variant/price structures | Most CRUD operations, cart mutations |

For GraphQL, create a thin wrapper around `fetch` that targets `${CTP_API_URL}/${CTP_PROJECT_KEY}/graphql`, passes a Bearer token, and uses `next: { revalidate: 60 }` for ISR caching. Query only the fields you need (e.g., `name`, `slug`, `masterVariant.sku`, `prices`, `images`) to minimize payload size. Use `graphql-codegen` for type-safe query results.

```graphql
# queries/product.graphql
query GetProduct($slug: String!, $locale: Locale!) {
  productProjectionSearch(
    filters: [{ model: { value: { path: "slug.$locale", values: [$slug] } } }]
    limit: 1
    locale: $locale
  ) {
    results {
      id
      name(locale: $locale)
      slug(locale: $locale)
      description(locale: $locale)
      masterVariant {
        sku
        images { url label }
        prices { value { centAmount currencyCode } country }
        attributesRaw { name value }
      }
      variants {
        sku
        images { url label }
        prices { value { centAmount currencyCode } country }
        attributesRaw { name value }
      }
    }
  }
}
```

## Pattern 5: Internationalization (i18n) with Locale Routing

Use Next.js dynamic segments for locale routing. commercetools stores all text fields as `LocalizedString` objects keyed by locale.

### Locale Routing with next-intl (scaffold)

The scaffold uses `next-intl` for navigation helpers and message translation, with `defineRouting` to configure supported locales:

```typescript
// i18n/routing.ts
import { createNavigation } from 'next-intl/navigation';
import { defineRouting } from 'next-intl/routing';

export const routing = defineRouting({
  locales: i18nConfig.locales,       // e.g. ['en', 'de']
  defaultLocale: i18nConfig.defaultLocale, // e.g. 'en'
});

// These replace next/navigation -- they add locale-aware behavior automatically
export const { Link, redirect, usePathname, useRouter, getPathname } = createNavigation(routing);
```

Use the exported `Link` and `redirect` from this module instead of the Next.js originals so locale prefixes are handled automatically.

### Locale-Currency Mapping (scaffold)

The scaffold maps short locale codes to full BCP 47 locales, currencies, and country codes:

```typescript
// project.config.ts
const localizationMapper = {
  en: { locale: 'en-US', currency: 'USD', currencyCode: '$', countryCode: 'US' },
  de: { locale: 'de-DE', currency: 'EUR', currencyCode: '€', countryCode: 'DE' },
} as Record<string, LocalizationMapping>;
```

This allows the URL to use short codes (`/en/products/...`) while the SDK receives full locale strings for API calls.

### Middleware for Locale Detection (scaffold)

The scaffold middleware detects the user's preferred locale from cookies, then the `Accept-Language` header, then the default:

```typescript
// middleware.ts
export function middleware(request: NextRequest) {
  const storedLocale = request.cookies.get('locale')?.value;
  const preferredLocale = new Negotiator({ headers }).language(i18nConfig.locales);

  // Priority: cookie > Accept-Language header > default
  locale = [storedLocale, preferredLocale, i18nConfig.defaultLocale]
    .filter(Boolean)
    .filter((l) => i18nConfig.locales.includes(l))[0];

  response = NextResponse.redirect(new URL(`/${locale}${path}`, request.url));
  // Persist locale for ~100 years so returning users get the same language
  response.cookies.set('locale', locale, { maxAge: 60 * 60 * 24 * 7 * 4 * 12 * 100 });
}
```

### Message Loading with Fallback (scaffold)

Translation messages are loaded per-locale with a fallback to the base language (e.g., `de` if `de-DE` is missing):

```typescript
// i18n/request.ts
const loadMessageBundleWithFallback = async (locale: string) => {
  const data = await import(`../messages/${locale}.json`)
    .then((m) => m.default)
    .catch(async () => {
      // If "de-DE" fails, try "de"
      if (locale.indexOf('-') >= 0) {
        const [language] = locale.split('-');
        return await import(`../messages/${language}.json`).then((m) => m.default).catch(() => {});
      }
    });
  return data || {};
};
```

### Layout with Locale Segment

Use a `[locale]` dynamic segment in your `app/` directory (e.g., `app/[locale]/layout.tsx`). Validate the locale param against your supported list and call `notFound()` for unsupported values. Set `<html lang={params.locale}>` for correct language attribution.

### Localized String Helpers

```typescript
// lib/commercetools/localization.ts

/** Extract a localized value with fallback chain */
export function localize(
  localizedString: Record<string, string> | undefined,
  locale: string,
  fallbackLocale = 'en-US'
): string {
  if (!localizedString) return '';
  return localizedString[locale] ?? localizedString[fallbackLocale] ?? Object.values(localizedString)[0] ?? '';
}
```

### CurrencyHelpers (scaffold)

The scaffold provides a `CurrencyHelpers` class for `Money` objects (centAmount + currencyCode). Safer than ad-hoc arithmetic because it preserves `fractionDigits` and currency metadata.

```typescript
// helpers/currencyHelpers/index.ts
export class CurrencyHelpers {
  static formatMoneyCurrency(price: Money, locale?: string) {
    return Intl.NumberFormat(locale, {
      style: 'currency',
      currency: price?.currencyCode ?? 'USD',
      maximumFractionDigits: price?.fractionDigits ?? 2,
    }).format((price?.centAmount ?? 0) / 100);
  }

  static addCurrency(value1?: Money, value2?: Money): Money { ... }
  static subtractCurrency(value1: Money, value2: Money): Money { ... }
  static multiplyCurrency(value: Money, numberOfItems: number): Money { ... }
}
```

Use `CurrencyHelpers.formatMoneyCurrency(price, locale)` instead of manual formatting calls.

**INCORRECT:** `product.name['en']` (breaks non-English markets) or `` `$${(centAmount / 100).toFixed(2)}` `` (wrong currency symbol for EUR). Always use locale-aware helpers.

## Pattern 6: Error Boundaries for Commerce Data

Wrap commerce-dependent sections in `<ErrorBoundary>` + `<Suspense>` pairs so a failed API call does not crash the entire page. **Critical sections** (product detail) should show an error message. **Non-critical sections** (recommendations, recently viewed) should use `fallback={null}` so they fail silently without disrupting the core shopping experience.

## Pattern 7: Route Handlers for Mutations

Use Next.js Route Handlers (not Server Actions with exposed credentials) for cart and auth mutations. Key points:

- Read `cartId` from an HttpOnly cookie; create a cart if none exists
- Always fetch the cart first to get the current `version` (optimistic concurrency)
- Store the cart ID back in an HttpOnly, Secure, SameSite cookie

```typescript
// app/api/cart/add/route.ts
import { NextRequest, NextResponse } from 'next/server';
import { apiRoot } from '@/lib/commercetools/client';
import { cookies } from 'next/headers';

export async function POST(request: NextRequest) {
  const { productId, variantId, quantity } = await request.json();
  const cartId = cookies().get('cartId')?.value;

  try {
    const cart = cartId
      ? await updateExistingCart(cartId, productId, variantId, quantity)
      : await createCartWithItem(productId, variantId, quantity);

    if (!cartId) {
      cookies().set('cartId', cart.body.id, {
        httpOnly: true, secure: true, sameSite: 'lax', maxAge: 60 * 60 * 24 * 30,
      });
    }
    return NextResponse.json(cart.body);
  } catch (error) {
    return NextResponse.json({ error: 'Failed to add item to cart' }, { status: 500 });
  }
}
```

## Pattern 8: Customer Authentication

Use HTTP-only cookies for session tokens. Never store commercetools auth tokens in localStorage. Key points:

- Call `apiRoot.login().post()` with the customer's email and password
- Pass `anonymousCart` with `anonymousCartSignInMode: 'MergeWithExistingCustomerCart'` to merge the anonymous cart into the customer's cart on login
- Store `customerId` in an HttpOnly, Secure cookie (max-age 7 days)
- Update the `cartId` cookie if the login response includes a merged cart
- Return only non-sensitive fields (`id`, `email`) to the client -- never the full customer object

## Architecture Checklist

- [ ] SDK client is a singleton, not recreated per request
- [ ] API credentials are ONLY in environment variables, NEVER in client bundles
- [ ] Catalog pages (PDP, PLP, category) use ISR with appropriate `revalidate` values
- [ ] Cart, checkout, and auth flows use client-side rendering with Route Handlers
- [ ] `LocalizedString` values use a helper with fallback chain, not direct key access
- [ ] Prices are formatted with `CurrencyHelpers` or `Intl.NumberFormat`, not string concatenation
- [ ] Error boundaries wrap commerce data sections so failures are isolated
- [ ] `Suspense` boundaries provide loading states for async Server Components
- [ ] Cart ID and customer session are stored in HttpOnly, Secure cookies
- [ ] No customer PII or tokens are stored in localStorage
- [ ] Multi-locale support uses URL segments (`/en/products/...`), not cookies or headers alone
- [ ] GraphQL queries request only needed fields (no `select *` equivalents)
- [ ] Independent data fetches use `Promise.all` to avoid request waterfalls (Pattern 2b)
- [ ] Server-fetched data is passed to SWR via `fallback` so Client Components skip redundant requests (Pattern 3b)
- [ ] Shared server-side fetches use `React.cache()` for per-request deduplication
- [ ] Locale middleware resolves language from cookie, then `Accept-Language`, then default
- [ ] Translation messages load with a language-code fallback (`de-DE` -> `de`)

## Reference

- [Next.js App Router](https://nextjs.org/docs/app)
- [commercetools TypeScript SDK](https://docs.commercetools.com/sdk/typescript-sdk)
- [commercetools GraphQL API](https://docs.commercetools.com/api/graphql)
- [Product Projections](https://docs.commercetools.com/api/projects/productProjections)
