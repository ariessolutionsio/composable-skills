# Localization Patterns

**Impact: HIGH -- Over-localizing bloats payloads. Missing fallbacks break storefronts.**

commercetools has strong built-in support for multi-locale and multi-currency commerce through `LocalizedString` fields and scoped pricing. However, misusing these features is one of the most common causes of bloated API responses and broken storefront experiences.

## Table of Contents
- [LocalizedString: When to Use and When Not To](#localizedstring-when-to-use-and-when-not-to)
- [Locale Decision Matrix](#locale-decision-matrix)
- [Pattern 1: Locale Fallback Strategy](#pattern-1-locale-fallback-strategy)
- [Pattern 2: Multi-Currency Pricing](#pattern-2-multi-currency-pricing)
  - [Price Selection Logic](#price-selection-logic)
- [Pattern 3: Stores for Multi-Market Localization](#pattern-3-stores-for-multi-market-localization)
- [Pattern 4: GraphQL Locale Differences](#pattern-4-graphql-locale-differences)
- [Pattern 5: Using localeProjection for Performance](#pattern-5-using-localeprojection-for-performance)
- [Design Checklist](#design-checklist)
- [Reference](#reference)

## LocalizedString: When to Use and When Not To

A `LocalizedString` is a map of locale codes to string values. It is the correct choice for genuinely translatable content. It is the **wrong** choice for universal data.

**Anti-Pattern (over-localizing universal data):**

```typescript
import { ProductDraft } from '@commercetools/platform-sdk';

// WRONG: Using LocalizedString for data that is the same in every locale
const overLocalizedProduct: ProductDraft = {
  key: 'laptop-x1',
  name: { en: 'ThinkPad X1 Carbon', de: 'ThinkPad X1 Carbon', fr: 'ThinkPad X1 Carbon' },
  slug: { en: 'thinkpad-x1-carbon', de: 'thinkpad-x1-carbon', fr: 'thinkpad-x1-carbon' },
  productType: { typeId: 'product-type', key: 'electronics' },
  masterVariant: {
    sku: 'TPX1C-2025',
    attributes: [
      // These are the same in every language -- should NOT be localized
      { name: 'ean', value: { en: '1234567890123', de: '1234567890123', fr: '1234567890123' } },
      { name: 'manufacturerPartNumber', value: { en: 'X1C-G12', de: 'X1C-G12', fr: 'X1C-G12' } },
      { name: 'cpuModel', value: { en: 'Intel i7-1365U', de: 'Intel i7-1365U', fr: 'Intel i7-1365U' } },
      { name: 'ramSize', value: { en: '16GB', de: '16GB', fr: '16GB' } },
    ],
    prices: [],
  },
};
// Result: 3x the storage, 3x the payload size, for zero benefit.
// Every new locale requires duplicating identical data.
```

**Recommended (localize only what varies by locale):**

```typescript
import { ProductTypeDraft, ProductDraft } from '@commercetools/platform-sdk';

// Product Type with correctly typed attributes
const electronicsType: ProductTypeDraft = {
  name: 'Electronics',
  key: 'electronics',
  description: 'Laptops, tablets, and electronic devices',
  attributes: [
    // Universal identifiers: plain text (NOT localized)
    {
      name: 'ean',
      label: { en: 'EAN' },
      type: { name: 'text' },  // Same in every language
      isRequired: false,
      attributeConstraint: 'Unique',
      isSearchable: false,
      inputHint: 'SingleLine',
    },
    {
      name: 'manufacturerPartNumber',
      label: { en: 'MPN' },
      type: { name: 'text' },  // Same in every language
      isRequired: false,
      attributeConstraint: 'SameForAll',
      isSearchable: false,
      inputHint: 'SingleLine',
    },
    // Technical specs: plain text or number (NOT localized)
    {
      name: 'cpuModel',
      label: { en: 'CPU Model' },
      type: { name: 'text' },
      isRequired: false,
      attributeConstraint: 'SameForAll',
      isSearchable: true,
      inputHint: 'SingleLine',
    },
    {
      name: 'ramSizeGB',
      label: { en: 'RAM (GB)' },
      type: { name: 'number' },  // Numeric, sortable
      isRequired: false,
      attributeConstraint: 'SameForAll',
      isSearchable: true,
      inputHint: 'SingleLine',
    },
    // Marketing copy: localized (DOES vary by language)
    {
      name: 'shortDescription',
      label: { en: 'Short Description' },
      type: { name: 'ltext' },  // Localized text -- genuinely translated
      isRequired: false,
      attributeConstraint: 'SameForAll',
      isSearchable: true,
      inputHint: 'MultiLine',
    },
    // Filterable categories: localized enum (label varies, key does not)
    {
      name: 'productLine',
      label: { en: 'Product Line' },
      type: {
        name: 'lenum',
        values: [
          { key: 'business', label: { en: 'Business', de: 'Business', fr: 'Professionnel' } },
          { key: 'consumer', label: { en: 'Consumer', de: 'Verbraucher', fr: 'Grand Public' } },
        ],
      },
      isRequired: true,
      attributeConstraint: 'SameForAll',
      isSearchable: true,
      inputHint: 'SingleLine',
    },
  ],
};

// Product with correct localization approach
const correctProduct: ProductDraft = {
  key: 'laptop-x1',
  name: { en: 'ThinkPad X1 Carbon Gen 12', de: 'ThinkPad X1 Carbon Gen 12' },
  slug: { en: 'thinkpad-x1-carbon-gen12', de: 'thinkpad-x1-carbon-gen12' },
  description: {
    en: 'Ultra-lightweight business laptop with all-day battery life.',
    de: 'Ultraleichtes Business-Laptop mit ganztaegiger Akkulaufzeit.',
  },
  productType: { typeId: 'product-type', key: 'electronics' },
  masterVariant: {
    sku: 'TPX1C-G12-16GB',
    attributes: [
      { name: 'ean', value: '1234567890123' },          // Plain text
      { name: 'manufacturerPartNumber', value: 'X1C-G12' }, // Plain text
      { name: 'cpuModel', value: 'Intel i7-1365U' },    // Plain text
      { name: 'ramSizeGB', value: 16 },                  // Number
      { name: 'shortDescription', value: {               // Localized
        en: 'Powerful business ultrabook',
        de: 'Leistungsstarkes Business-Ultrabook',
      } },
      { name: 'productLine', value: 'business' },       // Enum key (not localized)
    ],
    prices: [],
  },
};
```

**Why This Matters:** Every locale entry in a `LocalizedString` is stored and transferred in every API response. If you have 10 locales and 20 attributes that should be plain text but are `ltext`, that is 200 string values per variant instead of 20. This directly impacts API response size, search indexing time, and storage costs.

## Locale Decision Matrix

| Data Type | Localized? | Attribute Type | Examples |
|-----------|-----------|---------------|----------|
| Product names | Yes | `name` field (built-in LocalizedString) | "Running Shoe" / "Laufschuh" |
| Descriptions | Yes | `description` field (built-in) or `ltext` attribute | Marketing copy |
| Filterable options | Label only | `lenum` (key is universal, label is localized) | Color: "Red" / "Rot" |
| Technical specs | No | `text` or `number` | "Intel i7", 16 (GB), "1920x1080" |
| Identifiers | No | `text` with Unique constraint | EAN, UPC, MPN, SKU |
| Boolean flags | No | `boolean` | isWaterproof, isOrganic |
| Measurements | No | `number` | Weight, dimensions |
| Prices | No (use currency-specific pricing) | Embedded or Standalone Prices | Price per currency/country |

## Pattern 1: Locale Fallback Strategy

commercetools does not have a built-in locale fallback chain. Your application must implement it.

**Anti-Pattern (no fallback, broken storefront):**

```typescript
// Reading a localized field without fallback
function getProductName(product: ProductProjection, locale: string): string {
  return product.name[locale]; // Returns undefined if locale is missing!
}

// On the storefront: product name renders as "undefined" or blank
```

**Recommended (fallback chain implementation):**

```typescript
/**
 * Resolve a LocalizedString value with a configurable fallback chain.
 * Returns the first available locale value, or a default.
 */
function resolveLocalized(
  localizedString: Record<string, string> | undefined,
  locale: string,
  fallbackChain: string[] = ['en'],
  defaultValue: string = ''
): string {
  if (!localizedString) return defaultValue;

  // Try the requested locale
  if (localizedString[locale]) return localizedString[locale];

  // Try language without region (e.g., "de" for "de-DE")
  const langOnly = locale.split('-')[0];
  if (langOnly !== locale && localizedString[langOnly]) {
    return localizedString[langOnly];
  }

  // Try the fallback chain
  for (const fallback of fallbackChain) {
    if (localizedString[fallback]) return localizedString[fallback];
  }

  // Return the first available value, or default
  const firstValue = Object.values(localizedString)[0];
  return firstValue ?? defaultValue;
}

// Usage
const productName = resolveLocalized(
  product.name,
  'fr-CA',                        // Requested locale
  ['fr', 'en', 'de'],             // Fallback chain: French, then English, then German
  'Unnamed Product'                // Last resort default
);

// Configure fallback chains per market
const LOCALE_FALLBACKS: Record<string, string[]> = {
  'de-DE': ['de', 'en'],
  'de-AT': ['de-DE', 'de', 'en'],
  'fr-FR': ['fr', 'en'],
  'fr-CA': ['fr-FR', 'fr', 'en'],
  'en-US': ['en'],
  'en-GB': ['en-US', 'en'],
};

function getLocalizedValue(
  localizedString: Record<string, string> | undefined,
  requestedLocale: string
): string {
  const fallbackChain = LOCALE_FALLBACKS[requestedLocale] ?? ['en'];
  return resolveLocalized(localizedString, requestedLocale, fallbackChain);
}
```

## Pattern 2: Multi-Currency Pricing

Prices are not localized strings -- they are separate price entries scoped by currency, country, customer group, and channel.

```typescript
import { ProductDraft } from '@commercetools/platform-sdk';

const multiCurrencyProduct: ProductDraft = {
  key: 'premium-bag',
  name: { en: 'Premium Leather Bag', de: 'Premium Ledertasche' },
  slug: { en: 'premium-leather-bag', de: 'premium-ledertasche' },
  productType: { typeId: 'product-type', key: 'accessories' },
  masterVariant: {
    sku: 'BAG-PREM-001',
    prices: [
      // EUR price for Germany (tax-inclusive)
      {
        value: { type: 'centPrecision', currencyCode: 'EUR', centAmount: 29900, fractionDigits: 2 },
        country: 'DE',
      },
      // EUR price for France (different due to local tax or pricing strategy)
      {
        value: { type: 'centPrecision', currencyCode: 'EUR', centAmount: 31900, fractionDigits: 2 },
        country: 'FR',
      },
      // USD price for US (tax-exclusive)
      {
        value: { type: 'centPrecision', currencyCode: 'USD', centAmount: 34900, fractionDigits: 2 },
        country: 'US',
      },
      // GBP price for UK
      {
        value: { type: 'centPrecision', currencyCode: 'GBP', centAmount: 27900, fractionDigits: 2 },
        country: 'GB',
      },
      // Channel-specific pricing (e.g., outlet channel with lower prices)
      {
        value: { type: 'centPrecision', currencyCode: 'EUR', centAmount: 19900, fractionDigits: 2 },
        country: 'DE',
        channel: { typeId: 'channel', key: 'outlet-channel' },
      },
      // Customer group pricing (e.g., wholesale)
      {
        value: { type: 'centPrecision', currencyCode: 'EUR', centAmount: 22000, fractionDigits: 2 },
        country: 'DE',
        customerGroup: { typeId: 'customer-group', key: 'wholesale' },
      },
      // Time-scoped pricing (valid dates)
      {
        value: { type: 'centPrecision', currencyCode: 'EUR', centAmount: 24900, fractionDigits: 2 },
        country: 'DE',
        validFrom: '2025-11-25T00:00:00.000Z',
        validUntil: '2025-12-01T00:00:00.000Z',
      },
    ],
    attributes: [],
  },
};
```

### Price Selection Logic

commercetools uses a specific fallback order when selecting the best price for a cart:

1. Country + Currency + Customer Group + Channel + Valid Date range (most specific)
2. Country + Currency + Customer Group + Channel
3. Country + Currency + Customer Group
4. Country + Currency + Channel
5. Country + Currency
6. Currency only (least specific)

Design your pricing strategy around this selection chain. More specific prices always win.

## Pattern 3: Stores for Multi-Market Localization

Use Stores to model different markets, not separate Projects.

**Anti-Pattern (separate projects per country):**

```
Project: acme-germany    (DE locale, EUR currency)
Project: acme-france     (FR locale, EUR currency)
Project: acme-usa        (EN locale, USD currency)
// Result: 3x catalog management, 3x sync effort, no shared customers
```

**Recommended (single project with stores):**

```typescript
// Create stores for each market within a single project
const germanStore = await apiRoot.stores().post({
  body: {
    key: 'de-webshop',
    name: { en: 'Germany Web Shop', de: 'Deutschland Webshop' },
    languages: ['de', 'en'],  // German primary, English fallback
    countries: [{ code: 'DE' }, { code: 'AT' }],
    distributionChannels: [{ typeId: 'channel', key: 'eu-distribution' }],
    supplyChannels: [{ typeId: 'channel', key: 'de-warehouse' }],
    productSelections: [{
      productSelection: { typeId: 'product-selection', key: 'de-assortment' },
      active: true,
    }],
  },
}).execute();

const usStore = await apiRoot.stores().post({
  body: {
    key: 'us-webshop',
    name: { en: 'US Web Shop' },
    languages: ['en'],
    countries: [{ code: 'US' }],
    distributionChannels: [{ typeId: 'channel', key: 'us-distribution' }],
    supplyChannels: [{ typeId: 'channel', key: 'us-warehouse' }],
    productSelections: [{
      productSelection: { typeId: 'product-selection', key: 'us-assortment' },
      active: true,
    }],
  },
}).execute();

// Benefits:
// - Shared product catalog, shared customer base
// - Price selection via country/currency/channel
// - Store-specific assortments via Product Selections
// - Product Tailoring for store-specific name/description overrides
// - Scoped API access: manage_orders:acme:de-webshop
```

## Pattern 4: GraphQL Locale Differences

The REST and GraphQL APIs represent `LocalizedString` differently.

```typescript
// REST API: LocalizedString is a map
const restResponse = {
  name: {
    en: 'Classic T-Shirt',
    de: 'Klassisches T-Shirt',
    fr: 'T-Shirt Classique',
  },
};

// GraphQL API: LocalizedString is a list (nameAllLocales)
// or a single value (name with locale parameter)
const graphqlQuery = `
  query {
    product(id: "product-id") {
      masterData {
        current {
          # Single locale (returns string or null)
          name(locale: "en")

          # All locales (returns list)
          nameAllLocales {
            locale
            value
          }
        }
      }
    }
  }
`;

// GraphQL response structure
const graphqlResponse = {
  product: {
    masterData: {
      current: {
        name: 'Classic T-Shirt',
        nameAllLocales: [
          { locale: 'en', value: 'Classic T-Shirt' },
          { locale: 'de', value: 'Klassisches T-Shirt' },
          { locale: 'fr', value: 'T-Shirt Classique' },
        ],
      },
    },
  },
};

// Helper to convert GraphQL locale list to REST-style map
function localesToMap(
  locales: Array<{ locale: string; value: string }>
): Record<string, string> {
  return Object.fromEntries(locales.map(({ locale, value }) => [locale, value]));
}
```

## Pattern 5: Using localeProjection for Performance

When querying via REST, use `localeProjection` to limit which locales are returned.

```typescript
// Without localeProjection: returns ALL locales in every LocalizedString field
const bloatedResponse = await apiRoot.productProjections().get({
  queryArgs: {
    limit: 20,
    staged: false,
  },
}).execute();
// response.body.results[0].name = { en: '...', de: '...', fr: '...', ja: '...', ... }

// With localeProjection: returns only the requested locales
const leanResponse = await apiRoot.productProjections().get({
  queryArgs: {
    limit: 20,
    staged: false,
    localeProjection: ['de', 'en'],  // Only German and English
  },
}).execute();
// response.body.results[0].name = { de: '...', en: '...' }
// Significantly smaller response payload for multi-locale projects
```

## Design Checklist

- [ ] Only `LocalizedString` (`ltext`) is used for genuinely translatable content
- [ ] Technical specs, identifiers, and universal data use plain `text` or `number`
- [ ] Filterable options use `enum` (universal) or `lenum` (needs translated labels)
- [ ] A locale fallback chain is implemented in application code
- [ ] `localeProjection` is used in REST queries to reduce payload size
- [ ] Prices are structured per currency/country/channel, not "localized"
- [ ] Stores model different markets within a single project
- [ ] GraphQL locale handling accounts for the list representation (`nameAllLocales`)
- [ ] Default locale (usually `en`) is always populated as the ultimate fallback
- [ ] Product Tailoring is considered for store-specific name/description overrides

## Reference

- [Localization](https://docs.commercetools.com/api/general-concepts#localization)
- [Store Modeling Guide](https://docs.commercetools.com/foundry/best-practice-guides/modeling-stores)
- [Product Tailoring](https://docs.commercetools.com/api/projects/product-tailoring)
- [Prices](https://docs.commercetools.com/api/projects/products#price)
