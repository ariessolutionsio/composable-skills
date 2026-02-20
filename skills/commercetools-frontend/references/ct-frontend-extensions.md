# commercetools Frontend: Architecture & Extensions

> **Source**: Patterns in this reference are extracted from the official [FrontasticGmbH/scaffold-b2c](https://github.com/FrontasticGmbH/scaffold-b2c) and [FrontasticGmbH/scaffold-b2b](https://github.com/FrontasticGmbH/scaffold-b2b) repositories -- the starter projects provided by commercetools for Frontend projects. When scaffold code is shown, it reflects the real file paths and naming conventions used in production projects.

**Impact: HIGH -- Wrong extension architecture, bad component schemas, and misconfigured data sources break both the developer workflow and the business user experience in Studio**

This reference covers development patterns specific to **commercetools Frontend** -- the hosted frontend product (formerly Frontastic) that provides the Studio visual page builder for business users. If you are building a fully custom headless storefront with Next.js, see `storefront-architecture.md` instead -- but return here for the ct Frontend extension model.

## Table of Contents
- [Architecture Overview](#architecture-overview)
- [Project Structure](#project-structure)
- [Extension Registry](#extension-registry)
  - [Pattern 1: The Extension Entry Point](#pattern-1-the-extension-entry-point)
- [Data Source Extensions](#data-source-extensions)
  - [Pattern 2: Registered Data Sources](#pattern-2-registered-data-sources)
  - [Pattern 3: Data Source Schema for Studio](#pattern-3-data-source-schema-for-studio)
- [Action Extensions](#action-extensions)
  - [Pattern 4: Action Controller Architecture](#pattern-4-action-controller-architecture)
  - [Pattern 5: Real Action Implementation](#pattern-5-real-action-implementation)
  - [Pattern 6: Calling Actions from the Frontend SDK](#pattern-6-calling-actions-from-the-frontend-sdk)
- [Dynamic Page Handlers](#dynamic-page-handlers)
  - [Pattern 7: Resolving Product, Category, and Search URLs](#pattern-7-resolving-product-category-and-search-urls)

## Architecture Overview

commercetools Frontend has four key layers:

```
Studio (Business Users)
  |-- Page Builder (drag-and-drop)
  |-- Data Source configuration
  |-- Component settings
  |-- Preview & Publishing
  |
  v
Components (Tastics) -- React components with JSON schemas
  |-- Render data from data sources
  |-- Accept configuration from Studio
  |-- Can use any React library/pattern
  |
  v
API Hub (Extensions)
  |-- Data Source Extensions: fetch data for components
  |-- Action Extensions: handle mutations (cart, auth, etc.)
  |-- Dynamic Page Handlers: resolve URLs to page types
  |
  v
External APIs
  |-- commercetools Composable Commerce
  |-- CMS (Contentful, Contentstack, etc.)
  |-- Search (Algolia, etc.)
  |-- Custom backends
```

## Project Structure

This is the real directory layout from the scaffold-b2c repository:

```
backend/
  index.ts                      # Extension entry point (merges all integrations)
  commerce-commercetools/
    index.ts                    # Data sources + dynamic page handler
    actionControllers/          # Cart, Account, Product, Wishlist, Project controllers
    apis/                       # CartApi, ProductApi, AccountApi
    utils/
      CartFetcher.ts            # Session-based cart resolution
  content-contentful/           # CMS integration (optional)
frontend/
  app/[locale]/
    [[...slug]]/page.tsx        # Catch-all route (single page renders everything)
  components/
    commercetools-ui/
      atoms/                    # Button, Image, Input
      molecules/                # ProductCard, CartItem
      organisms/                # Checkout, Cart, ProductList
  frontastic/
    tastics/
      index.tsx                 # Tastic registry
      checkout/
      cart/
      products/details/
      products/product-list/
    renderer/
      index.tsx                 # Renderer pipeline
      components/tastic-wrapper/
  sdk/
    CommercetoolsSDK.ts         # SDK singleton
    composable-commerce/        # Commerce integration types
  providers/
    index.tsx                   # Root provider (SWR, Account, etc.)
    swr/index.tsx               # SWR configuration
  i18n/
    routing.ts                  # next-intl locale routing
    request.ts                  # Message bundle loading
  helpers/
    currencyHelpers/            # CurrencyHelpers.formatForCurrency
    server/
      fetch-page-data.ts        # React cache() for SSR dedup
  project.config.ts             # Locale/currency mapping
types/
  product/Product.ts            # Shared product types
  cart/Cart.ts                  # Shared cart types
```

The catch-all route at `app/[locale]/[[...slug]]/page.tsx` is critical: every URL in the storefront resolves through this single Next.js page, which fetches page data from the API Hub and delegates rendering to the Renderer pipeline.

## Extension Registry

### Pattern 1: The Extension Entry Point

The `backend/index.ts` file is the single entry point that merges all integration extensions into one registry. The scaffold uses a merge pattern where each integration (commerce, CMS, search) exports its own data sources, actions, and dynamic page handler, and they are combined:

```typescript
// backend/index.ts
import commercetoolsExtension from '@Commerce-commercetools';
import contentfulExtensions from '@Content-contentful';

const extensionsToMerge = [commercetoolsExtension, contentfulExtensions];

export default {
  'dynamic-page-handler': mergeDynamicPageHandlers(extensionsToMerge),
  'data-sources': extensionsToMerge
    .map((ext) => ext['data-sources'] || {})
    .reduce(Object.assign, {}),
  actions: mergeActions(extensionsToMerge),
} as ExtensionRegistry;
```

This merge pattern means you never write a monolithic extension file. Each integration lives in its own directory (`commerce-commercetools/`, `content-contentful/`) and exports a standard shape. To add a new integration, add it to the `extensionsToMerge` array.

## Data Source Extensions

### Pattern 2: Registered Data Sources

The scaffold registers these data sources out of the box. Each one maps to a function in `commerce-commercetools/index.ts` that fetches data from the commercetools API:

**B2C data sources:**
| Data Source ID | Purpose |
|---|---|
| `frontastic/product-list` | PLP data (category or filtered product lists) |
| `frontastic/product` | Single product detail |
| `frontastic/similar-products` | Related products |
| `frontastic/other-products` | Random/fallback products |
| `frontastic/referenced-products` | Products referenced by an attribute |
| `frontastic/empty` | Empty data source (for static components) |

**B2B additional data sources:**
| Data Source ID | Purpose |
|---|---|
| `frontastic/approval-flow` | Single approval flow |
| `frontastic/approval-flows` | List of approval flows |
| `frontastic/approval-rule` | Single approval rule |
| `frontastic/approval-rules` | List of approval rules |
| `frontastic/quote` | Single quote |
| `frontastic/quotes` | List of quotes |
| `frontastic/quote-request` | Single quote request |
| `frontastic/quote-requests` | List of quote requests |
| `frontastic/recurring-order` | Single recurring order |
| `frontastic/recurring-orders` | List of recurring orders |

**Key constraints:**
- Extension runner has an **8-second timeout** for external calls
- All code must compile to a **single JavaScript file** (webpack bundles automatically)
- Node.js 22.x is the supported runtime

### Pattern 3: Data Source Schema for Studio

The data source schema defines what business users can configure in Studio.

```json
{
  "customDataSourceType": "frontastic/product-list",
  "name": "Product List",
  "category": "Products",
  "icon": "shopping_cart",
  "schema": [
    {
      "name": "Configuration",
      "fields": [
        {
          "label": "Select a category",
          "field": "categoryId",
          "type": "reference",
          "referenceType": "category",
          "required": false
        },
        {
          "label": "Products per page",
          "field": "limit",
          "type": "integer",
          "default": 12,
          "min": 1,
          "max": 48
        },
        {
          "label": "Sort by",
          "field": "sortBy",
          "type": "enum",
          "values": [
            { "value": "price-asc", "name": "Price: Low to High" },
            { "value": "price-desc", "name": "Price: High to Low" },
            { "value": "name-asc", "name": "Name: A to Z" },
            { "value": "newest", "name": "Newest First" }
          ],
          "default": "newest"
        }
      ]
    }
  ]
}
```

## Action Extensions

### Pattern 4: Action Controller Architecture

Actions are organized by namespace, where each namespace maps to a controller class. The scaffold uses the pattern `namespace/actionName`, and the framework routes to the correct controller method:

**B2C action controller namespaces:**
| Namespace | Controller | Key Actions |
|---|---|---|
| `account` | AccountController | `login`, `register`, `confirm`, `requestConfirmationEmail`, `logout`, `requestReset`, `reset`, `password`, `getAccount`, `update`, `addAddress`, `addShippingAddress`, `addBillingAddress`, `updateAddress`, `removeAddress`, `setDefaultBillingAddress`, `setDefaultShippingAddress`, `deleteAccount` |
| `cart` | CartController | `getCart`, `addToCart`, `updateLineItem`, `removeLineItem`, `checkout`, `redeemDiscount`, `removeDiscount`, `updateCart`, `setShippingMethod`, `getShippingMethods` |
| `product` | ProductController | `query`, `getProduct`, `queryCategories`, `productFilters`, `categoryFilters` |
| `wishlist` | WishlistController | `getWishlist`, `addToWishlist`, `removeLineItem`, `updateLineItemCount` |
| `project` | ProjectController | `getProjectSettings` |

**B2B additional namespaces:**
| Namespace | Controller | Key Actions |
|---|---|---|
| `business-unit` | BusinessUnitActions | Business unit management |
| `quote` | QuoteAction | Quote workflows |

### Pattern 5: Real Action Implementation

Action controllers follow a consistent pattern. Each action is an `ActionHook` that receives the request and action context, uses an API class to perform the operation, and returns a response with session data:

```typescript
// actionControllers/CartController.ts
export const redeemDiscount: ActionHook = async (request, actionContext) => {
  const cartApi = getCartApi(request, actionContext.frontasticContext);

  // CartFetcher resolves the cart from session data (cartId in sessionData)
  let cart = await CartFetcher.fetchCart(request, actionContext.frontasticContext);

  const body = JSON.parse(request.body);
  cart = await cartApi.redeemDiscountCode(cart, body.code);

  return {
    statusCode: 200,
    body: JSON.stringify(cart),
    sessionData: {
      ...cartApi.getSessionData(),
      cartId: cart.cartId,
    },
  };
};
```

Key details of this pattern:
- `CartFetcher.fetchCart` resolves the current cart from the session (using `cartId` stored in `sessionData`)
- API classes (`CartApi`, `ProductApi`, `AccountApi`) encapsulate all commercetools API calls
- `sessionData` is returned in every response to maintain server-side session state (cart ID, customer ID, etc.)
- The request body is always `JSON.parse`'d from `request.body`

### Pattern 6: Calling Actions from the Frontend SDK

```typescript
// Using the Frontend SDK v2 to call action extensions
import { sdk } from 'sdk';

// Add to cart
async function handleAddToCart(productId: string, variantId: number) {
  const response = await sdk.callAction<Cart>({
    actionName: 'cart/addToCart',
    payload: { productId, variantId, quantity: 1 },
  });

  if (response.isError) {
    console.error('Failed to add item:', response.error);
    return;
  }

  // response.data contains the updated cart
  setCart(response.data);
}

// Login
async function handleLogin(email: string, password: string) {
  const response = await sdk.callAction<{ customer: Customer }>({
    actionName: 'account/login',
    payload: { email, password },
  });

  if (response.isError) {
    setError('Invalid email or password');
    return;
  }

  // Session is automatically updated by the SDK
  router.push('/account');
}
```

## Dynamic Page Handlers

### Pattern 7: Resolving Product, Category, and Search URLs

The dynamic page handler maps URLs that do not have a corresponding page folder to a page type. The scaffold uses Router classes to identify and load data for each URL pattern:

```typescript
// commerce-commercetools dynamic page handler
'dynamic-page-handler': async (request, context) => {
  // Product pages -- e.g., /blue-running-shoes-p-ABC123
  if (ProductRouter.identifyFrom(request)) {
    const product = await ProductRouter.loadFor(
      request,
      context.frontasticContext
    );
    return {
      dynamicPageType: 'frontastic/product-detail-page',
      dataSourcePayload: { product },
      pageMatchingPayload: { productTypeId: product.productTypeId },
    };
  }

  // Search pages -- e.g., /search?q=shoes
  if (SearchRouter.identifyFrom(request)) {
    const result = await SearchRouter.loadFor(
      request,
      context.frontasticContext
    );
    return {
      dynamicPageType: 'frontastic/search',
      dataSourcePayload: result,
    };
  }

  // Category pages -- e.g., /mens/shoes
  if (CategoryRouter.identifyFrom(request)) {
    const category = await CategoryRouter.loadFor(
      request,
      context.frontasticContext
    );
    const result = await CategoryRouter.loadProductsFor(
      request,
      context.frontasticContext,
      category
    );
    return {
      dynamicPageType: 'frontastic/category',
      dataSourcePayload: result,
      pageMatchingPayload: { categoryRef: category.categoryRef },
    };
  }

  // No match -- return null to let the 404 page handle it
  return null;
};
```

The `dynamicPageType` values (`frontastic/product-detail-page`, `frontastic/search`, `frontastic/category`) must match page types configured in Studio. `pageMatchingPayload` allows Studio to assign different page layouts per product type or category.
