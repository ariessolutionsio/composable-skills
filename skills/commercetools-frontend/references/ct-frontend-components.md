# commercetools Frontend: Components & Rendering

Components (Tastics), renderer pipeline, SDK configuration, Studio best practices, and development checklist for commercetools Frontend.

## Table of Contents
- [Components (Tastics)](#components-tastics)
  - [Pattern 8: TasticProps and the Tastic Wrapper](#pattern-8-tasticprops-and-the-tastic-wrapper)
  - [Pattern 8b: The DataSource Wrapper Type](#pattern-8b-the-datasource-wrapper-type)
  - [Pattern 9: Registering Components (Real Tastic Registry)](#pattern-9-registering-components-real-tastic-registry)
  - [Pattern 10: Component with Data Source](#pattern-10-component-with-data-source)
- [Renderer Pipeline](#renderer-pipeline)
  - [Pattern 11: Page -> Section -> Grid -> Cell -> Tastic](#pattern-11-page---section---grid---cell---tastic)
- [Frontend SDK v2 Configuration](#frontend-sdk-v2-configuration)
  - [Pattern 12: Setting Up the Frontend SDK](#pattern-12-setting-up-the-frontend-sdk)
- [Studio Best Practices for Developers](#studio-best-practices-for-developers)
  - [Pattern 13: Schema Design for Business Users](#pattern-13-schema-design-for-business-users)
  - [Pattern 14: Preview Payload for Studio](#pattern-14-preview-payload-for-studio)
- [commercetools Frontend Checklist](#commercetools-frontend-checklist)
  - [Extensions](#extensions)
  - [Components (Tastics)](#components-tastics-1)
  - [Renderer & Page Structure](#renderer--page-structure)
  - [Dynamic Page Handlers](#dynamic-page-handlers)
  - [Studio](#studio)
  - [SDK](#sdk)
- [Reference](#reference)

## Components (Tastics)

### Pattern 8: TasticProps and the Tastic Wrapper

Every tastic receives a standardized set of props. The real `TasticProps` type from the scaffold:

```typescript
export interface TasticProps<T = object> {
  data: T & TasticConfiguration;
  params: Params;
  searchParams: SearchParams;
  categories: Category[];
  flattenedCategories: Category[];
  [key: string]: unknown;
}
```

The `TasticWrapper` component is responsible for looking up the tastic from the registry, injecting resolved data sources into the configuration, and rendering it:

```typescript
// frontastic/renderer/components/tastic-wrapper/index.tsx
const TasticWrapper = ({ data, dataSources, params, searchParams, categories, ... }: TasticWrapperProps) => {
  const Tastic = tastics[data.tasticType]; // Look up from registry

  // Resolve data source references in the tastic configuration to actual data
  const resolvedTasticData = dataSources
    ? injectDataSources(data.configuration, dataSources)
    : data.configuration;

  return (
    <div id={data?.tasticId}>
      {Tastic ? (
        <Tastic
          data={resolvedTasticData}
          params={params}
          searchParams={searchParams}
          categories={categories}
        />
      ) : (
        <MissingTastic data={data} />
      )}
    </div>
  );
};
```

The `injectDataSources` function walks the tastic configuration recursively. When it finds a `dataSourceId` key, it injects the resolved data as a sibling `dataSource` property. This creates the nested access pattern used by all tastics.

### Pattern 8b: The DataSource Wrapper Type

Tastics that consume data sources declare their props using the `DataSource<T>` wrapper type. This wrapping means data is **not** accessed directly on `data` -- it lives at `data.data?.dataSource`:

```typescript
// types/datasource.ts
export interface DataSource<T = unknown> {
  data?: {
    dataSource?: T;
  };
}
```

**INCORRECT -- accessing data directly:**
```typescript
// WRONG: data.items does not exist
const ProductListTastic = ({ data }: TasticProps<{ items: Product[] }>) => {
  return <ProductList products={data.items} />;  // undefined!
};
```

**CORRECT -- using the DataSource wrapper:**
```typescript
// frontastic/tastics/products/details/index.tsx
const ProductDetailsTastic = ({ data, categories }: TasticProps<DataSource<{ product: Product }>>) => {
  if (!data?.data?.dataSource?.product) return null;  // Guard against missing data

  return <ProductDetails product={mapProduct(data.data.dataSource.product)} />;
};

// frontastic/tastics/products/product-list/index.tsx
interface DataSourceProps {
  items: Product[];
  facets: Facet[];
  previousCursor?: string;
  nextCursor?: string;
  total: number;
  totalItems: number;
}

const ProductListTastic = ({
  data,
  categories,
  ...props
}: TasticProps<DataSource<DataSourceProps> & Props>) => {
  if (!data?.data?.dataSource) return <></>;

  const products = data.data.dataSource.items ?? [];
  const facets = data.data.dataSource.facets ?? [];
  const nextCursor = data.data.dataSource.nextCursor;
  // ...
};
```

The consistent access pattern across all scaffold tastics is:
```
data.data?.dataSource?.<property>
```

Where:
- First `data` = the tastic's `data` prop (from `TasticProps`)
- `.data` = the optional field from the `DataSource` interface containing the injected configuration
- `.dataSource` = the resolved data source content (injected by `injectDataSources`)
- `.<property>` = domain-specific fields (`items`, `product`, `facets`, `total`, etc.)

### Pattern 9: Registering Components (Real Tastic Registry)

Components must be registered in the tastic map so the Frontend framework knows how to render them. The scaffold uses `next/dynamic` for lazy loading:

```typescript
// frontastic/tastics/index.tsx
import dynamic from 'next/dynamic';

// Lazy-load tastics for code splitting
const Checkout = dynamic(() => import('./checkout'));
const Cart = dynamic(() => import('./cart'));
const ProductDetails = dynamic(() => import('./products/details'));
const ProductList = dynamic(() => import('./products/product-list'));
const AccountLogin = dynamic(() => import('./account/login'));
// ... additional tastics (header, footer, thank-you, account, etc.)

export const tastics = {
  'commercetools/ui/checkout': Checkout,
  'commercetools/ui/cart': Cart,
  'commercetools/ui/products/details': ProductDetails,
  'commercetools/ui/products/product-list': ProductList,
  'commercetools/ui/account/login': AccountLogin,
  // ... additional tastics
} as TasticRegistry;
```

Note the naming convention: tastic types use `commercetools/ui/` as a prefix, not a project-specific prefix. When adding custom tastics, use your own namespace (e.g., `myproject/ui/custom-banner`).

### Pattern 10: Component with Data Source

A tastic is a React component that receives its data via the `TasticProps` interface. Data source fields configured in the schema are resolved by the TasticWrapper before the component renders:

```json
{
  "tasticType": "commercetools/ui/products/product-list",
  "name": "Product List",
  "category": "Products",
  "icon": "grid_view",
  "description": "Displays a list of products from a data source",
  "schema": [
    {
      "name": "Data",
      "fields": [
        {
          "label": "Products",
          "field": "items",
          "type": "dataSource",
          "dataSourceType": "frontastic/product-list",
          "required": true
        }
      ]
    },
    {
      "name": "Layout",
      "fields": [
        {
          "label": "Show facets",
          "field": "showFacets",
          "type": "boolean",
          "default": true
        },
        {
          "label": "Show sorting",
          "field": "showSorting",
          "type": "boolean",
          "default": true
        }
      ]
    }
  ]
}
```

```typescript
// frontastic/tastics/products/product-list/index.tsx
import { TasticProps } from '../types';

interface ProductListData {
  items: {
    items: Product[];
    total: number;
    facets: Facet[];
  };
  showFacets?: boolean;
  showSorting?: boolean;
}

const ProductListTastic = ({ data, categories }: TasticProps<ProductListData>) => {
  // data.items is already resolved from the frontastic/product-list data source
  // data.showFacets and data.showSorting come from schema configuration
  return (
    <ProductList
      products={data.items}
      categories={categories}
      showFacets={data.showFacets}
      showSorting={data.showSorting}
    />
  );
};

export default ProductListTastic;
```

## Renderer Pipeline

### Pattern 11: Page -> Section -> Grid -> Cell -> Tastic

The Renderer is the core of the frontend rendering system. It takes the page data returned by the API Hub and renders it through a hierarchy: Page contains Sections (head, main, footer), each Section contains layout elements rendered in a Grid, each Cell contains one or more Tastics:

```typescript
// frontastic/renderer/index.tsx
'use client';

const Renderer = ({
  data: pageData,
  params,
  searchParams,
  categories,
  flattenedCategories,
}) => {
  const { page, data } = pageData;

  const sections = [
    page.sections.head,
    page.sections.main,
    page.sections.footer,
  ];

  return (
    <div className="flex min-h-screen flex-col">
      {sections.filter(Boolean).map((section) => (
        <Grid key={section?.sectionId}>
          {section?.layoutElements?.map((layoutElement) => (
            <Cell
              key={layoutElement.layoutElementId}
              configuration={layoutElement.configuration}
            >
              {layoutElement.tastics.map((tastic) => (
                <TasticWrapper
                  key={tastic.tasticId}
                  data={tastic}
                  dataSources={data.dataSources}
                  params={params}
                  searchParams={searchParams}
                  categories={categories}
                  flattenedCategories={flattenedCategories}
                />
              ))}
            </Cell>
          ))}
        </Grid>
      ))}
    </div>
  );
};
```

This means:
- **Page structure is defined in Studio** (which sections exist, what layout elements they contain, which tastics are placed in each cell)
- **Developers define tastics** (React components + schemas) and **extensions** (data sources, actions)
- **Business users compose pages** by dragging tastics into cells and configuring them

## Frontend SDK v2 Configuration

### Pattern 12: Setting Up the Frontend SDK

The scaffold uses a singleton SDK pattern with per-locale configuration:

```typescript
// sdk/CommercetoolsSDK.ts
import { SDK } from '@commercetools/frontend-sdk';
import {
  ComposableCommerce,
  type ComposableCommerceEvents,
} from './composable-commerce'; // Local integration, not an npm package

class CommercetoolsSDK extends SDK<ComposableCommerceEvents> {
  composableCommerce!: ComposableCommerce;

  constructor() {
    super();
    this.composableCommerce = new ComposableCommerce(this);
  }
}

// Singleton instance
const sdk = new CommercetoolsSDK();

// Configure per locale -- called on each request/navigation
// The scaffold uses defaultConfigure() which sets locale, currency, etc.
sdk.defaultConfigure(locale);

export { sdk };
```

```typescript
// Using the built-in Composable Commerce integration
import { sdk } from 'sdk';

// Product operations (via pre-built extension)
const products = await sdk.composableCommerce.product.query({
  category: categoryId,
  limit: 12,
});

// Cart operations
const cart = await sdk.composableCommerce.cart.addItem({
  variant: { sku: 'TEE-BLK-M', count: 1 },
});

// Account operations
const loginResult = await sdk.composableCommerce.account.login({
  email: 'user@example.com',
  password: 'password',
});
```

## Studio Best Practices for Developers

### Pattern 13: Schema Design for Business Users

**INCORRECT -- overly technical schema:**

```json
{
  "fields": [
    {
      "label": "categoryId (UUID format)",
      "field": "categoryId",
      "type": "string",
      "required": true
    },
    {
      "label": "queryFilter",
      "field": "queryFilter",
      "type": "string"
    }
  ]
}
```

**CORRECT -- business-friendly schema:**

```json
{
  "fields": [
    {
      "label": "Select a category",
      "field": "categoryId",
      "type": "reference",
      "referenceType": "category",
      "required": true
    },
    {
      "label": "Sort products by",
      "field": "sortBy",
      "type": "enum",
      "values": [
        { "value": "price-asc", "name": "Price: Low to High" },
        { "value": "price-desc", "name": "Price: High to Low" },
        { "value": "newest", "name": "Newest First" },
        { "value": "bestselling", "name": "Best Selling" }
      ],
      "default": "newest"
    },
    {
      "label": "Maximum products to display",
      "field": "limit",
      "type": "integer",
      "default": 12,
      "min": 4,
      "max": 48
    }
  ]
}
```

### Pattern 14: Preview Payload for Studio

When developing data source extensions, always include a `previewPayload` so business users see meaningful previews in Studio without needing live data.

```typescript
'data-sources': {
  'frontastic/product-list': async (config, context): Promise<DataSourceResult> => {
    const products = await fetchProducts(config.configuration);

    return {
      dataSourcePayload: {
        products: products.results,
        total: products.total,
      },
      // Studio uses this for visual preview in the page builder
      previewPayload: products.results.slice(0, 4).map((p) => ({
        title: p.name[context.request.sessionData?.locale || 'en-US'] || p.name['en-US'],
        image: p.masterVariant.images?.[0]?.url || '',
      })),
    };
  },
},
```

## commercetools Frontend Checklist

### Extensions
- [ ] All extensions compile to a single file via the webpack build
- [ ] External API calls have proper error handling (try/catch, not unhandled promises)
- [ ] External API calls complete within the 8-second timeout limit
- [ ] Data source extensions return `previewPayload` for Studio previews
- [ ] Action extensions validate request body before processing
- [ ] Action extensions return appropriate HTTP status codes (400 for bad input, 401 for auth)
- [ ] Action extensions return `sessionData` to maintain cart/customer state across requests
- [ ] Session data is used for locale, currency, and user context -- not hardcoded
- [ ] Extension version header is correctly configured for each environment
- [ ] Extension registry uses the merge pattern (each integration in its own directory)

### Components (Tastics)
- [ ] Every tastic has both `index.tsx` and `schema.json`
- [ ] Schema field labels are business-friendly, not technical IDs
- [ ] Schema uses `reference` type for categories/products, not raw string IDs
- [ ] Schema provides sensible `default` values for optional fields
- [ ] Data source fields use the correct `dataSourceType` matching the extension (e.g., `frontastic/product-list`)
- [ ] Data source tastics use the `DataSource<T>` wrapper type and access data via `data.data?.dataSource?.<field>`
- [ ] Components handle missing/error data gracefully (empty data source, API failure)
- [ ] Components are registered in the tastic registry (`frontastic/tastics/index.tsx`) with lazy loading via `next/dynamic`
- [ ] Tastic types use a consistent namespace prefix (e.g., `commercetools/ui/` for scaffold tastics)

### Renderer & Page Structure
- [ ] Renderer pipeline follows Page -> Section -> Grid -> Cell -> TasticWrapper hierarchy
- [ ] TasticWrapper resolves data sources via `injectDataSources` before passing to tastic
- [ ] MissingTastic fallback renders for unregistered tastic types
- [ ] Catch-all route (`app/[locale]/[[...slug]]/page.tsx`) is properly configured

### Dynamic Page Handlers
- [ ] Dynamic page handler resolves products, categories, and search URLs
- [ ] `dynamicPageType` values match page types configured in Studio
- [ ] `pageMatchingPayload` is provided where Studio needs to distinguish page variants (e.g., per product type)
- [ ] Router classes (ProductRouter, CategoryRouter, SearchRouter) are used for URL identification

### Studio
- [ ] Page folders have correct URL patterns for static pages
- [ ] Components are organized into logical categories (Products, Content, Navigation)
- [ ] Schema `icon` values use valid Material Icons names
- [ ] Preview works correctly in Studio for all components

### SDK
- [ ] Frontend SDK v2 is configured as a singleton
- [ ] `defaultConfigure(locale)` is called per-locale to set currency and language
- [ ] `callAction` responses check `isError` before accessing `data`
- [ ] Event handlers are properly cleaned up on component unmount

## Reference

- [commercetools Frontend Development](https://docs.commercetools.com/frontend-development)
- [Extensions Overview](https://docs.commercetools.com/frontend-development/extensions)
- [Frontend SDK v2](https://docs.commercetools.com/frontend-development/frontend-sdk)
- [Studio Guide](https://docs.commercetools.com/frontend-getting-started/studio-guide)
- [Creating Components with Data Sources](https://docs.commercetools.com/frontend-development/creating-frontend-component-with-a-data-source)
- [Developing Data Source Extensions](https://docs.commercetools.com/frontend-development/developing-a-data-source-extension)
- [scaffold-b2c Repository](https://github.com/FrontasticGmbH/scaffold-b2c)
- [scaffold-b2b Repository](https://github.com/FrontasticGmbH/scaffold-b2b)
