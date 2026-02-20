# Frontend SEO Optimization

SEO patterns including structured data (JSON-LD), meta tags, dynamic XML sitemaps, canonical URLs, hreflang for multi-locale, and performance/SEO checklist for commercetools storefronts.

**Impact: HIGH -- Missing structured data means no rich results. Proper SEO implementation drives organic traffic and visibility for commerce storefronts.**

## Table of Contents
- [SEO Optimization](#seo-optimization)
  - [Pattern 7: Product Structured Data (JSON-LD)](#pattern-7-product-structured-data-json-ld)
  - [Pattern 8: Meta Tags for Product and Category Pages](#pattern-8-meta-tags-for-product-and-category-pages)
  - [Pattern 9: Dynamic XML Sitemap](#pattern-9-dynamic-xml-sitemap)
  - [Pattern 10: Canonical URLs and hreflang for Multi-Locale](#pattern-10-canonical-urls-and-hreflang-for-multi-locale)
- [Performance & SEO Checklist](#performance--seo-checklist)
  - [Performance](#performance)
  - [SEO](#seo)
- [Reference](#reference)

## SEO Optimization

### Pattern 7: Product Structured Data (JSON-LD)

Google uses Product structured data for rich results (price, availability, reviews in search results).

```typescript
// components/seo/ProductStructuredData.tsx
import type { ProductProjection } from '@commercetools/platform-sdk';
import { localize } from '@/lib/commercetools/localization';

interface Props {
  product: ProductProjection;
  locale: string;
  currency: string;
  baseUrl: string;
}

export function ProductStructuredData({ product, locale, currency, baseUrl }: Props) {
  const name = localize(product.name, locale);
  const description = localize(product.description, locale);
  const slug = localize(product.slug, locale);
  const image = product.masterVariant.images?.[0]?.url;
  const sku = product.masterVariant.sku;

  const price = product.masterVariant.prices?.find(
    (p) => p.value.currencyCode === currency
  );

  const availability = product.masterVariant.availability;
  const isInStock = availability?.isOnStock ?? true;

  const structuredData = {
    '@context': 'https://schema.org',
    '@type': 'Product',
    name,
    description,
    image: image ? [image] : undefined,
    sku,
    url: `${baseUrl}/${locale}/products/${slug}`,
    brand: product.masterVariant.attributes?.find((a) => a.name === 'brand')
      ? {
          '@type': 'Brand',
          name: product.masterVariant.attributes.find((a) => a.name === 'brand')?.value?.label ||
                product.masterVariant.attributes.find((a) => a.name === 'brand')?.value,
        }
      : undefined,
    offers: price
      ? {
          '@type': 'Offer',
          url: `${baseUrl}/${locale}/products/${slug}`,
          priceCurrency: price.value.currencyCode,
          price: (price.discounted?.value.centAmount ?? price.value.centAmount) / 100,
          availability: isInStock
            ? 'https://schema.org/InStock'
            : 'https://schema.org/OutOfStock',
          // Include high price for variant range
          ...(product.variants.length > 0
            ? {
                '@type': 'AggregateOffer',
                lowPrice: (price.discounted?.value.centAmount ?? price.value.centAmount) / 100,
                highPrice: getHighestPrice(product, currency) / 100,
                offerCount: product.variants.length + 1,
              }
            : {}),
        }
      : undefined,
  };

  return (
    <script
      type="application/ld+json"
      dangerouslySetInnerHTML={{ __html: JSON.stringify(structuredData) }}
    />
  );
}

function getHighestPrice(product: ProductProjection, currency: string): number {
  const allVariants = [product.masterVariant, ...product.variants];
  let highest = 0;
  for (const variant of allVariants) {
    const price = variant.prices?.find((p) => p.value.currencyCode === currency);
    if (price) {
      const amount = price.discounted?.value.centAmount ?? price.value.centAmount;
      if (amount > highest) highest = amount;
    }
  }
  return highest;
}
```

### Pattern 8: Meta Tags for Product and Category Pages

```typescript
// app/[locale]/products/[slug]/page.tsx
import type { Metadata } from 'next';
import { getProductBySlug } from '@/lib/commercetools/products';
import { localize } from '@/lib/commercetools/localization';

export async function generateMetadata({
  params,
}: {
  params: { locale: string; slug: string };
}): Promise<Metadata> {
  const product = await getProductBySlug(params.slug, params.locale, 'USD', 'US');

  if (!product) {
    return { title: 'Product Not Found' };
  }

  const name = localize(product.name, params.locale);
  const description = localize(product.description, params.locale) ||
    `Shop ${name} at our store.`;
  const image = product.masterVariant.images?.[0]?.url;

  return {
    title: `${name} | Your Store`,
    description: description.slice(0, 160), // Meta descriptions should be < 160 chars
    openGraph: {
      title: name,
      description,
      type: 'og:product',
      images: image ? [{ url: image, width: 1200, height: 1200 }] : undefined,
      url: `/${params.locale}/products/${params.slug}`,
    },
    alternates: {
      canonical: `/${params.locale}/products/${params.slug}`,
      languages: {
        'en-US': `/en-US/products/${params.slug}`,
        'de-DE': `/de-DE/products/${params.slug}`,
        'fr-FR': `/fr-FR/products/${params.slug}`,
      },
    },
    robots: {
      index: true,
      follow: true,
    },
  };
}
```

**Official Scaffold SEO Metadata Pattern:** The `scaffold-b2c` generates metadata dynamically from page folder types, extracting SEO fields from categories and products:

```typescript
// helpers/seo-tools/index.ts (scaffold-b2c)
export const getSeoInfoFromPageResponse = (response, categories) => {
  const pageType = response.pageFolder?.pageFolderType;
  if (pageType === 'frontastic/category') {
    const category = findCurrentCategory(response, categories);
    seoTitle = category.metaTitle ?? category.name;
    seoDescription = category.metaDescription;
  }
  if (pageType === 'frontastic/product-detail-page') {
    const product = data?.product;
    seoTitle = product.metaTitle ?? product.name;
    seoDescription = product.metaDescription ?? product.description;
  }
  return { seoTitle, seoDescription, seoKeywords };
};

// Used in generateMetadata() at the route level
export async function generateMetadata(props) {
  const [response, flatCategories] = await Promise.all([
    fetchPageData(params, searchParams),
    fetchCategories({ format: 'flat' }),
  ]);
  const { seoTitle, seoDescription, seoKeywords } = getSeoInfoFromPageResponse(response.data, categories);
  return { title: seoTitle, description: seoDescription, keywords: seoKeywords };
}
```

Key insight: The scaffold uses the `pageFolderType` from the commercetools Frontend page response to determine which SEO fields to extract. This means SEO metadata is centralized in one helper rather than duplicated across every page component. The fallback chain (`metaTitle` -> `name`) ensures pages always have a title even if the SEO fields are not filled in.

### Pattern 9: Dynamic XML Sitemap

```typescript
// app/sitemap.ts
import { MetadataRoute } from 'next';
import { apiRoot } from '@/lib/commercetools/client';

const BASE_URL = process.env.NEXT_PUBLIC_BASE_URL || 'https://www.example.com';
const LOCALES = ['en-US', 'de-DE', 'fr-FR'];

export default async function sitemap(): Promise<MetadataRoute.Sitemap> {
  const entries: MetadataRoute.Sitemap = [];

  // Static pages
  for (const locale of LOCALES) {
    entries.push({
      url: `${BASE_URL}/${locale}`,
      lastModified: new Date(),
      changeFrequency: 'daily',
      priority: 1.0,
    });
  }

  // Product pages -- paginate through all published products
  let offset = 0;
  const limit = 500;
  let hasMore = true;

  while (hasMore) {
    const response = await apiRoot
      .productProjections()
      .search()
      .get({
        queryArgs: { limit, offset, staged: false },
      })
      .execute();

    for (const product of response.body.results) {
      for (const locale of LOCALES) {
        const slug = product.slug[locale];
        if (slug) {
          entries.push({
            url: `${BASE_URL}/${locale}/products/${slug}`,
            lastModified: new Date(product.lastModifiedAt),
            changeFrequency: 'weekly',
            priority: 0.8,
          });
        }
      }
    }

    offset += limit;
    hasMore = response.body.results.length === limit;
  }

  // Category pages
  const categories = await apiRoot
    .categories()
    .get({ queryArgs: { limit: 500 } })
    .execute();

  for (const category of categories.body.results) {
    for (const locale of LOCALES) {
      const slug = category.slug[locale];
      if (slug) {
        entries.push({
          url: `${BASE_URL}/${locale}/category/${slug}`,
          lastModified: new Date(category.lastModifiedAt),
          changeFrequency: 'weekly',
          priority: 0.7,
        });
      }
    }
  }

  return entries;
}
```

**Official Scaffold Dynamic Sitemap Pattern:** The `scaffold-b2c` uses cursor-based pagination (not offset-based) for sitemap generation, with per-locale routes and proper cache headers:

```typescript
// app/[locale]/sitemap-products.xml/route.ts (scaffold-b2c)
export async function GET(request, props) {
  sdk.defaultConfigure(locale);
  let nextCursor;
  do {
    const response = await extensions.product.query({ cursor: nextCursor, limit: 500 });
    items.push(...response.data.items);
    fields.push(...items.map((product) => ({
      loc: `${siteUrl}/${locale}${product._url}`,
      lastmod: new Date().toISOString(),
      changefreq: 'daily',
    })));
    nextCursor = response.data.nextCursor;
  } while (nextCursor);
  return new Response(generateSiteMap(fields), {
    headers: {
      'Cache-Control': 'public, s-maxage=86400, stale-while-revalidate',
      'Content-Type': 'application/xml',
    },
  });
}
```

Key improvements over the generic pattern above: (1) Uses cursor-based pagination instead of offset, which is more reliable for large catalogs where products may be added/removed during pagination. (2) Sets proper `Cache-Control` headers with `s-maxage=86400` (24h CDN cache) and `stale-while-revalidate` so sitemap regeneration does not block requests. (3) Generates per-locale sitemaps at `/{locale}/sitemap-products.xml` rather than a single global sitemap.

### Pattern 10: Canonical URLs and hreflang for Multi-Locale

```typescript
// app/[locale]/layout.tsx
import type { Metadata } from 'next';

const LOCALES = ['en-US', 'de-DE', 'fr-FR'];

export async function generateMetadata({
  params,
}: {
  params: { locale: string };
}): Promise<Metadata> {
  const languages: Record<string, string> = {};
  for (const loc of LOCALES) {
    languages[loc] = `/${loc}`;
  }

  return {
    alternates: {
      canonical: `/${params.locale}`,
      languages,
    },
    other: {
      // x-default for language negotiation
      'x-default': '/en-US',
    },
  };
}
```

## Performance & SEO Checklist

### Performance
- [ ] Product images use `next/image` with correct `sizes` attribute
- [ ] LCP image (main PDP image, first PLP card) has `priority` attribute
- [ ] Image `sizes` use `useImageSizes` hook (scaffold) or match actual layout breakpoints
- [ ] Fonts use `next/font` with `display: 'swap'`
- [ ] Heavy components are dynamically imported (`next/dynamic`)
- [ ] Skeleton loaders reserve space to prevent CLS
- [ ] ISR revalidation times match data freshness requirements
- [ ] No full product objects stored in client-side state (extract needed fields only)
- [ ] Bundle analyzer confirms no unexpected large dependencies
- [ ] Third-party scripts (analytics, chat) are loaded with `strategy="lazyOnload"`

### SEO
- [ ] Every PDP has JSON-LD Product structured data
- [ ] `generateMetadata` provides unique title and description per page
- [ ] Open Graph tags include product image, title, and description
- [ ] `sitemap.ts` generates entries for all published products and categories
- [ ] Each locale variant has `hreflang` alternate links
- [ ] Canonical URLs prevent duplicate content across locale variants
- [ ] `robots.txt` allows crawling of product and category pages
- [ ] Cart, checkout, and account pages are `noindex`
- [ ] Meta descriptions are under 160 characters
- [ ] Product images have meaningful `alt` text (not just "image" or empty)
- [ ] 404 pages return proper HTTP 404 status (use `notFound()`)

## Reference

- [Next.js Metadata API](https://nextjs.org/docs/app/api-reference/functions/generate-metadata)
- [Next.js Sitemap](https://nextjs.org/docs/app/api-reference/file-conventions/metadata/sitemap)
- [Google Product Structured Data](https://developers.google.com/search/docs/appearance/structured-data/product)
- [commercetools Product Projections](https://docs.commercetools.com/api/projects/productProjections)
