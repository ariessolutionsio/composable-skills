# Product Detail Pages (PDP) & Search

Product detail page patterns including variant selection, image gallery, search results, product cards, Algolia integration, and checklist for commercetools storefronts.

## Product Detail Page (PDP) Patterns

### Pattern 4: Fetching Product Data Efficiently

**INCORRECT -- fetching the full product resource:**

```typescript
// WRONG: Fetches all attributes, all variants, all prices, all images
// Even fields you never display
const product = await apiRoot
  .products()  // Use productProjections, not products
  .withKey({ key: productKey })
  .get({ queryArgs: { expand: ['productType', 'categories[*]', 'taxCategory'] } })
  .execute();
// .products() returns both current and staged data -- 2x payload
```

**CORRECT -- fetching a product projection with selective expansion:**

```typescript
// lib/commercetools/products.ts
export async function getProductBySlug(
  slug: string,
  locale: string,
  priceCurrency: string,
  priceCountry: string
) {
  const response = await apiRoot
    .productProjections()
    .search()
    .get({
      queryArgs: {
        filter: [`slug.${locale}:"${slug}"`],
        priceCurrency,
        priceCountry,
        limit: 1,
        markMatchingVariants: true,
      },
    })
    .execute();

  return response.body.results[0] ?? null;
}
```

### Pattern 5: Variant Selection UI

Variant selection is one of the most complex frontend patterns. The key is mapping variant attributes to selectable options and tracking which combinations are available.

```typescript
// lib/commercetools/variants.ts
import type { ProductVariant, Attribute } from '@commercetools/platform-sdk';

interface VariantOption {
  name: string;
  values: Array<{
    value: string;
    label: string;
    available: boolean;
  }>;
}

/**
 * Build selectable variant options from product variants.
 * Handles availability: disables options that have no matching variant.
 */
export function buildVariantOptions(
  variants: ProductVariant[],
  variantAttributes: string[], // e.g., ['color', 'size']
  currentSelection: Record<string, string>
): VariantOption[] {
  return variantAttributes.map((attrName) => {
    // Collect all unique values for this attribute
    const allValues = new Map<string, string>();
    for (const variant of variants) {
      const attr = variant.attributes?.find((a) => a.name === attrName);
      if (attr) {
        const key = typeof attr.value === 'object' ? attr.value.key : String(attr.value);
        const label = typeof attr.value === 'object'
          ? attr.value.label?.['en'] || attr.value.label || key
          : String(attr.value);
        allValues.set(key, label);
      }
    }

    // Determine availability: can this value combine with current selections?
    const values = Array.from(allValues.entries()).map(([key, label]) => {
      const testSelection = { ...currentSelection, [attrName]: key };
      const matchingVariant = findVariant(variants, testSelection, variantAttributes);
      return {
        value: key,
        label,
        available: matchingVariant !== undefined && (matchingVariant.availability?.isOnStock ?? true),
      };
    });

    return { name: attrName, values };
  });
}

/** Find a variant matching the given attribute selection */
export function findVariant(
  variants: ProductVariant[],
  selection: Record<string, string>,
  variantAttributes: string[]
): ProductVariant | undefined {
  return variants.find((variant) =>
    variantAttributes.every((attrName) => {
      if (!selection[attrName]) return true; // Not yet selected
      const attr = variant.attributes?.find((a) => a.name === attrName);
      if (!attr) return false;
      const key = typeof attr.value === 'object' ? attr.value.key : String(attr.value);
      return key === selection[attrName];
    })
  );
}
```

```typescript
// components/product/VariantSelector.tsx
'use client';

import { useState, useMemo } from 'react';
import type { ProductProjection } from '@commercetools/platform-sdk';
import { buildVariantOptions, findVariant } from '@/lib/commercetools/variants';

const VARIANT_ATTRIBUTES = ['color', 'size'];

interface Props {
  product: ProductProjection;
  onVariantChange: (variantId: number, sku: string) => void;
}

export function VariantSelector({ product, onVariantChange }: Props) {
  const allVariants = [product.masterVariant, ...product.variants];
  const [selection, setSelection] = useState<Record<string, string>>({});

  const options = useMemo(
    () => buildVariantOptions(allVariants, VARIANT_ATTRIBUTES, selection),
    [allVariants, selection]
  );

  const selectedVariant = useMemo(
    () => findVariant(allVariants, selection, VARIANT_ATTRIBUTES),
    [allVariants, selection]
  );

  const handleSelect = (attrName: string, value: string) => {
    const updated = { ...selection, [attrName]: value };
    setSelection(updated);

    const variant = findVariant(allVariants, updated, VARIANT_ATTRIBUTES);
    if (variant?.sku) {
      onVariantChange(variant.id, variant.sku);
    }
  };

  return (
    <div className="space-y-4">
      {options.map((option) => (
        <div key={option.name}>
          <label className="block font-medium capitalize mb-2">
            {option.name}
          </label>
          <div className="flex gap-2 flex-wrap">
            {option.values.map((val) => (
              <button
                key={val.value}
                onClick={() => handleSelect(option.name, val.value)}
                disabled={!val.available}
                className={`px-4 py-2 border rounded ${
                  selection[option.name] === val.value
                    ? 'border-black bg-black text-white'
                    : val.available
                      ? 'border-gray-300 hover:border-gray-500'
                      : 'border-gray-200 text-gray-300 cursor-not-allowed'
                }`}
              >
                {val.label}
              </button>
            ))}
          </div>
        </div>
      ))}

      {selectedVariant && !selectedVariant.availability?.isOnStock && (
        <p className="text-red-600 text-sm">This variant is currently out of stock.</p>
      )}
    </div>
  );
}
```

**Official Scaffold Variant Selection Pattern:** The `scaffold-b2c` handles color variants with visual swatches (colored circles) and size with text buttons, using a unified component:

```typescript
// components/commercetools-ui/organisms/product/product-details/components/product-variant.tsx (scaffold-b2c)
const ProductVariant = ({ variants, currentVariant, attribute, onClick }) => {
  const getVariantClassName = (id) => `... ${
    currentVariant?.id === id ? selectedVariantClassName :
    attribute === 'size' ? sizeVariantClassname : defaultVariantClassName
  }`;
  return (
    <div>
      <h3>{translate(`product.${attribute}`)}</h3>
      <p>{currentVariant?.attributes?.[`${attribute}label`] ?? textToColor(currentVariant?.attributes?.[attribute]).label}</p>
      <div className="mt-16 flex gap-24">
        {variants.map(({ attributes, id, sku }) => (
          <button
            key={id}
            onClick={() => onClick?.(sku)}
            className={getVariantClassName(id)}
            style={attribute !== 'size' ? { backgroundColor: textToColor(attributes?.[attribute]).code } : {}}
          >
            {attribute === 'size' && attributes?.[attribute]}
          </button>
        ))}
      </div>
    </div>
  );
};
```

Note: The scaffold distinguishes rendering by attribute name -- `size` renders as text labels, while color-type attributes render as colored circles using `textToColor()` to map attribute values like `"red"` to hex codes.

### Pattern 6: Product Image Gallery

```typescript
// components/product/ProductImageGallery.tsx
'use client';

import { useState } from 'react';
import Image from 'next/image';
import type { Image as CTImage } from '@commercetools/platform-sdk';

interface Props {
  images: CTImage[];
  productName: string;
}

export function ProductImageGallery({ images, productName }: Props) {
  const [selectedIndex, setSelectedIndex] = useState(0);

  if (images.length === 0) {
    return (
      <div className="aspect-square bg-gray-100 flex items-center justify-center">
        <span className="text-gray-400">No image available</span>
      </div>
    );
  }

  const mainImage = images[selectedIndex];

  return (
    <div className="space-y-4">
      {/* Main image -- priority loading for LCP */}
      <div className="relative aspect-square">
        <Image
          src={mainImage.url}
          alt={mainImage.label || productName}
          fill
          sizes="(max-width: 768px) 100vw, 50vw"
          className="object-contain"
          priority={selectedIndex === 0} // Priority for the first image (LCP)
        />
      </div>

      {/* Thumbnails */}
      {images.length > 1 && (
        <div className="flex gap-2 overflow-x-auto">
          {images.map((img, index) => (
            <button
              key={img.url}
              onClick={() => setSelectedIndex(index)}
              className={`relative w-16 h-16 flex-shrink-0 border-2 rounded ${
                index === selectedIndex ? 'border-black' : 'border-transparent'
              }`}
            >
              <Image
                src={img.url}
                alt={img.label || `${productName} view ${index + 1}`}
                fill
                sizes="64px"
                className="object-cover rounded"
              />
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
```

## Search Results Page

### Pattern 7: URL-Driven Search with Server Components

```typescript
// app/[locale]/search/page.tsx
import { getProductListing } from '@/lib/commercetools/product-search';
import { ProductGrid } from '@/components/product/ProductGrid';

export const revalidate = 0; // Always fresh search results

interface Props {
  params: { locale: string };
  searchParams: { q?: string; page?: string; sort?: string };
}

export default async function SearchPage({ params, searchParams }: Props) {
  const query = searchParams.q || '';

  if (!query) {
    return <p>Enter a search term to find products.</p>;
  }

  const { products, total } = await getProductListing({
    searchQuery: query,
    page: parseInt(searchParams.page || '0', 10),
    sort: searchParams.sort || 'score desc',
    locale: params.locale,
    currency: 'USD',
    country: 'US',
  });

  return (
    <div>
      <h1>
        {total} results for &quot;{query}&quot;
      </h1>
      <ProductGrid products={products} locale={params.locale} />
    </div>
  );
}
```

## Product Card Component

### Pattern 8: Reusable Product Card for Grids

```typescript
// components/product/ProductCard.tsx
import Image from 'next/image';
import Link from 'next/link';
import type { ProductProjection } from '@commercetools/platform-sdk';
import { localize, formatPrice } from '@/lib/commercetools/localization';

interface Props {
  product: ProductProjection;
  locale: string;
  currency?: string;
}

export function ProductCard({ product, locale, currency = 'USD' }: Props) {
  const name = localize(product.name, locale);
  const slug = localize(product.slug, locale);
  const image = product.masterVariant.images?.[0];
  const price = product.masterVariant.prices?.find(
    (p) => p.value.currencyCode === currency
  );
  const discountedPrice = price?.discounted?.value;

  return (
    <Link
      href={`/${locale}/products/${slug}`}
      className="group block"
    >
      <div className="relative aspect-square overflow-hidden rounded-lg bg-gray-100">
        {image ? (
          <Image
            src={image.url}
            alt={image.label || name}
            fill
            sizes="(max-width: 640px) 50vw, (max-width: 1024px) 33vw, 25vw"
            className="object-cover group-hover:scale-105 transition-transform"
          />
        ) : (
          <div className="flex items-center justify-center h-full text-gray-400">
            No image
          </div>
        )}
      </div>

      <h3 className="mt-2 text-sm font-medium">{name}</h3>

      {price && (
        <div className="mt-1">
          {discountedPrice ? (
            <>
              <span className="text-red-600 font-medium">
                {formatPrice(discountedPrice.centAmount, discountedPrice.currencyCode, locale)}
              </span>
              <span className="text-gray-400 line-through ml-2 text-sm">
                {formatPrice(price.value.centAmount, price.value.currencyCode, locale)}
              </span>
            </>
          ) : (
            <span className="font-medium">
              {formatPrice(price.value.centAmount, price.value.currencyCode, locale)}
            </span>
          )}
        </div>
      )}
    </Link>
  );
}
```

## Algolia Search Integration (Official Scaffold Pattern)

### Pattern 9: Algolia as an Alternative Search Backend

> From the official `scaffold-b2c` repo: The scaffold supports Algolia as a drop-in alternative to the commercetools Product Search API. It wraps the same `ProductListProvider` context inside Algolia's `InstantSearch`, so all filter/sort/pagination logic stays the same.

```typescript
// frontastic/tastics/products/product-list-algolia/index.tsx (scaffold-b2c)
function ProductListAlgoliaTastic({ data, categories, ...props }) {
  return (
    <InstantSearch>
      <LocalizedIndex type="products">
        <ProductListProvider ...>
          <ProductListTastic data={{ ...data }} categories={flattenedCategories} {...props} />
        </ProductListProvider>
      </LocalizedIndex>
    </InstantSearch>
  );
}
```

The key architectural insight is that the scaffold has separate tastics for `product-list` (uses commercetools search) and `product-list-algolia` (uses Algolia). Both render the same `ProductListTastic` UI component, but the Algolia version wraps it with `InstantSearch` and `LocalizedIndex` to provide Algolia-powered faceting and search. This means switching search backends requires only changing the tastic wired in the Studio, not rewriting the UI.

## Product Pages Checklist

- [ ] PLP uses Product Search API (not raw product projections query) for relevance and faceting
- [ ] Facet filters update the URL (enables sharing, back button, SEO)
- [ ] Pagination resets to page 0 when filters change
- [ ] PDP uses `productProjections().search()` or GraphQL, NOT `products().withId()`
- [ ] Variant selection disables unavailable combinations (not just hides them)
- [ ] Product images use `next/image` with appropriate `sizes` attribute
- [ ] First product image has `priority` for LCP optimization
- [ ] Price display handles both regular and discounted prices
- [ ] Price formatting uses `Intl.NumberFormat` with correct locale and currency
- [ ] Missing images have a fallback placeholder
- [ ] Search results page uses `revalidate = 0` for fresh results
- [ ] Product cards include alt text on images for accessibility
- [ ] Category pages use `subtree` filter to include subcategory products

## Reference

- [Product Search API](https://docs.commercetools.com/api/projects/product-search)
- [Product Projections Search](https://docs.commercetools.com/api/projects/productProjections#search-productprojections)
- [Product Projections](https://docs.commercetools.com/api/projects/productProjections)
- [Next.js Image Component](https://nextjs.org/docs/app/api-reference/components/image)
