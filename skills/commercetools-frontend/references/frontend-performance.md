# Frontend Performance Optimization

Core Web Vitals optimization including image handling, font loading, code splitting, prefetching, CLS prevention, and caching strategies for commercetools storefronts.

**Impact: HIGH -- Poor Core Web Vitals drop search rankings. Slow pages lose 7% conversion per second of load time.**

## Table of Contents
- [Core Web Vitals Optimization](#core-web-vitals-optimization)
  - [Pattern 1: Image Optimization for Product Images](#pattern-1-image-optimization-for-product-images)
  - [Pattern 2: Font Loading Strategy](#pattern-2-font-loading-strategy)
  - [Pattern 3: Code Splitting for Commerce Components](#pattern-3-code-splitting-for-commerce-components)
  - [Pattern 4: Prefetching Critical Navigation](#pattern-4-prefetching-critical-navigation)
  - [Pattern 5: Avoiding Layout Shift (CLS) on Product Pages](#pattern-5-avoiding-layout-shift-cls-on-product-pages)
- [Caching Strategies](#caching-strategies)
  - [Pattern 6: Next.js Fetch Cache for commercetools Data](#pattern-6-nextjs-fetch-cache-for-commercetools-data)
- [Reference](#reference)

## Core Web Vitals Optimization

### Pattern 1: Image Optimization for Product Images

Product images are typically the Largest Contentful Paint (LCP) element. Optimizing them is the single highest-impact performance improvement for any commerce storefront.

**INCORRECT -- unoptimized product images:**

```typescript
// WRONG: Raw image tag with no optimization
function ProductImage({ url, name }: { url: string; name: string }) {
  return (
    // No lazy loading, no responsive sizing, no format optimization
    // Browser loads the full 4000x4000 image even on mobile
    <img src={url} alt={name} />
  );
}
```

**CORRECT -- optimized with Next.js Image:**

```typescript
// components/product/OptimizedProductImage.tsx
import Image from 'next/image';

interface Props {
  url: string;
  alt: string;
  isLCP?: boolean; // true for the main PDP image or first PLP image
  sizes?: string;
}

export function OptimizedProductImage({
  url,
  alt,
  isLCP = false,
  sizes = '(max-width: 768px) 100vw, 50vw',
}: Props) {
  return (
    <div className="relative aspect-square">
      <Image
        src={url}
        alt={alt}
        fill
        sizes={sizes}
        priority={isLCP} // Preloads the LCP image, skips lazy loading
        quality={80}     // 80% quality is visually identical, 40% smaller file
        className="object-contain"
        // Next.js automatically converts to WebP/AVIF and resizes
      />
    </div>
  );
}
```

**Image `sizes` cheat sheet for common commerce layouts:**

| Context | Sizes Value |
|---------|-------------|
| PDP main image | `(max-width: 768px) 100vw, 50vw` |
| PLP grid (4 columns) | `(max-width: 640px) 50vw, (max-width: 1024px) 33vw, 25vw` |
| PLP grid (3 columns) | `(max-width: 640px) 50vw, 33vw` |
| Cart thumbnail | `80px` |
| Product carousel | `(max-width: 768px) 80vw, 33vw` |
| Hero banner | `100vw` |

**Official Scaffold Image Component Pattern:** The `scaffold-b2c` uses a unified `Image` component that handles Cloudinary-hosted images, standard Next.js images, and fallbacks in a single component:

```typescript
// components/commercetools-ui/atoms/image/index.tsx (scaffold-b2c)
const Image = ({ media, ratio, gravity, suffix, src = '', ...props }) => {
  // Cloudinary images (managed via commercetools Frontend media manager)
  if (media?.mediaId) {
    return <CldImage src={media.mediaId} alt={alt} crop={cropConfig} gravity={gravity?.mode || 'auto'} aspectRatio={ratio} />;
  }
  // Standard Next.js images with custom loader
  try {
    const processedSrc = defaultLoader({ src, suffix });
    if (processedSrc) return <NextImage src={processedSrc} alt={alt} {...dimensions} {...props} />;
  } catch (error) {}
  // Fallback placeholder
  return <NextImage src={PLACEHOLDER_IMAGE} alt={alt} {...dimensions} {...props} />;
};
```

This pattern is important because commercetools Frontend projects often have images from multiple sources (Cloudinary for CMS-managed media, direct URLs for product images from the commercetools API). The scaffold's approach ensures every image path gets optimized -- Cloudinary images use `CldImage` for on-the-fly transforms (crop, gravity, format), while other images go through the Next.js image pipeline.

**Scaffold `useImageSizes` hook:** Instead of manually writing `sizes` strings, the scaffold provides a hook that generates responsive sizes from fractional viewport widths per breakpoint:

```typescript
// helpers/hooks/useImageSizes/index.ts (scaffold-b2c)
import * as screensizes from 'helpers/utils/screensizes';
// screensizes: { mobile: 480, tablet: 744, desktop: 1024, ... }

interface UseImageSizesParams {
  sm?: number;   // fraction of viewport at mobile (<=480px)
  md?: number;   // fraction of viewport at tablet (<=744px)
  lg?: number;   // fraction of viewport at desktop (<=1024px)
  defaultSize?: number;  // fraction above desktop
}

const useImageSizes = ({ sm, md, lg, defaultSize = 1 }: UseImageSizesParams) => {
  const calculateSizes = useCallback(() => {
    let imageSizes = `${defaultSize * 100}vw`;
    // Stack from largest to smallest breakpoint
    imageSizes = `(max-width: ${screensizes.desktop}px) ${(lg ?? defaultSize) * 100}vw, ` + imageSizes;
    imageSizes = `(max-width: ${screensizes.tablet}px) ${(md ?? lg ?? defaultSize) * 100}vw, ` + imageSizes;
    imageSizes = `(max-width: ${screensizes.mobile}px) ${(sm ?? md ?? lg ?? defaultSize) * 100}vw, ` + imageSizes;
    return imageSizes;
  }, [sm, md, lg, defaultSize]);
  return calculateSizes();
};
```

Usage examples:
```typescript
// Logo: full width on mobile, 15% on desktop
const logoSizes = useImageSizes({ sm: 1, md: 0.5, lg: 0.15, defaultSize: 0.15 });
// → "(max-width: 480px) 100vw, (max-width: 744px) 50vw, (max-width: 1024px) 15vw, 15vw"

// Category tiles: 50% on mobile, 25% on desktop (4-column grid)
const tileSizes = useImageSizes({ md: 0.5, lg: 0.25, defaultSize: 0.25 });
// → "(max-width: 480px) 50vw, (max-width: 744px) 50vw, (max-width: 1024px) 25vw, 25vw"

// Uniform size: 25% everywhere
const sliderSizes = useImageSizes({ defaultSize: 0.25 });
// → "(max-width: 480px) 25vw, (max-width: 744px) 25vw, (max-width: 1024px) 25vw, 25vw"
```

This is preferable to hand-writing `sizes` strings because the breakpoints match the scaffold's CSS breakpoints exactly, and the fallback cascade (`sm ?? md ?? lg ?? defaultSize`) handles missing values gracefully.

### Pattern 2: Font Loading Strategy

Custom fonts cause layout shift (CLS) if loaded incorrectly.

```typescript
// app/layout.tsx
import { Inter } from 'next/font/google';

// Next.js automatically self-hosts Google fonts -- no external requests
const inter = Inter({
  subsets: ['latin'],
  display: 'swap', // Prevents FOIT (Flash of Invisible Text)
  // 'swap' shows fallback font immediately, swaps when loaded
});

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className={inter.className}>
      <body>{children}</body>
    </html>
  );
}
```

### Pattern 3: Code Splitting for Commerce Components

Heavy components (rich text editors, image zoom, 3D viewers) should be dynamically imported.

```typescript
// components/product/ProductPage.tsx
import dynamic from 'next/dynamic';

// Heavy components loaded on demand
const ProductZoom = dynamic(() => import('./ProductZoom'), {
  loading: () => <div className="aspect-square bg-gray-100 animate-pulse" />,
  ssr: false, // Image zoom only needed client-side
});

const ProductReviews = dynamic(() => import('./ProductReviews'), {
  loading: () => <div className="h-48 bg-gray-50 animate-pulse" />,
});

const RecentlyViewed = dynamic(() => import('./RecentlyViewed'), {
  ssr: false, // Depends on localStorage
});
```

### Pattern 4: Prefetching Critical Navigation

```typescript
// components/navigation/CategoryNav.tsx
import Link from 'next/link';

// Next.js App Router prefetches <Link> components automatically when they
// enter the viewport. This is free performance for category navigation.

export function CategoryNav({ categories, locale }: { categories: Category[]; locale: string }) {
  return (
    <nav>
      {categories.map((cat) => (
        <Link
          key={cat.id}
          href={`/${locale}/category/${cat.slug[locale]}`}
          // prefetch={true} is the default in App Router
          // prefetch={false} for low-traffic links to save bandwidth
        >
          {cat.name[locale]}
        </Link>
      ))}
    </nav>
  );
}
```

### Pattern 5: Avoiding Layout Shift (CLS) on Product Pages

```typescript
// components/product/ProductPrice.tsx
// Reserve space for price display to prevent CLS when data loads

interface Props {
  price?: { centAmount: number; currencyCode: string };
  discountedPrice?: { centAmount: number; currencyCode: string };
  locale: string;
  loading?: boolean;
}

export function ProductPrice({ price, discountedPrice, locale, loading }: Props) {
  if (loading) {
    // Skeleton with fixed dimensions prevents layout shift
    return <div className="h-8 w-24 bg-gray-200 rounded animate-pulse" />;
  }

  if (!price) return null;

  return (
    <div className="h-8 flex items-center gap-2">
      {discountedPrice ? (
        <>
          <span className="text-xl font-bold text-red-600">
            {formatPrice(discountedPrice.centAmount, discountedPrice.currencyCode, locale)}
          </span>
          <span className="text-sm text-gray-400 line-through">
            {formatPrice(price.centAmount, price.currencyCode, locale)}
          </span>
        </>
      ) : (
        <span className="text-xl font-bold">
          {formatPrice(price.centAmount, price.currencyCode, locale)}
        </span>
      )}
    </div>
  );
}
```

## Caching Strategies

### Pattern 6: Next.js Fetch Cache for commercetools Data

```typescript
// lib/commercetools/products.ts

// Product data: cache for 60 seconds, revalidate in background
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

// Category tree: cache for 1 hour (changes very rarely)
export async function getCategoryTree() {
  // Using fetch with Next.js cache directives
  const token = await getAccessToken();
  const res = await fetch(
    `${process.env.CTP_API_URL}/${process.env.CTP_PROJECT_KEY}/categories?limit=500&sort=orderHint asc`,
    {
      headers: { Authorization: `Bearer ${token}` },
      next: { revalidate: 3600 }, // 1 hour
    }
  );
  return res.json();
}
```

**Caching guidelines by data type:**

| Data | `revalidate` | Rationale |
|------|-------------|-----------|
| Product catalog | 60-300s | Balance freshness vs API quota |
| Category tree | 3600s | Changes very rarely |
| Cart data | 0 (no cache) | Per-user, real-time |
| Inventory/stock | 30-60s | Near-real-time needed |
| Customer data | 0 (no cache) | Per-user, sensitive |
| CMS/promotional content | 300-3600s | Controlled publish cycle |
| Search results | 0-60s | Depends on catalog velocity |

## Reference

- [Next.js Image Optimization](https://nextjs.org/docs/app/building-your-application/optimizing/images)
- [Web Vitals](https://web.dev/vitals/)
- [commercetools Product Projections](https://docs.commercetools.com/api/projects/productProjections)
