# Custom Views

Custom Views are embedded UI panels that render inside the built-in Merchant Center applications. Unlike Custom Applications, they do not have their own menu entry or full-page layout. Instead, they appear as slide-out panels on top of existing MC pages, providing contextual functionality without requiring the user to leave their current workflow.

## When to Use a Custom View

- You need to **add functionality to an existing MC page** (e.g., order tracking on the Order detail page)
- The feature is **contextual** -- it relates to a specific resource the user is viewing
- The feature requires **minimal navigation** (one or two views, not a complex multi-page flow)
- You want to **avoid context switching** for business users

**Custom View vs Custom Application:**

| Aspect | Custom View | Custom Application |
|--------|-------------|-------------------|
| Appears in | Panel on top of a built-in MC page | Own page with main menu entry |
| Navigation | None or minimal (within panel) | Full routing (list, detail, create, tabs) |
| URL space | `/custom-views/:customViewId/projects/:projectKey` | `/:projectKey/:entryPointUriPath` |
| Isolation | Rendered in sandboxed iframe | Rendered directly in MC shell |
| Use case | Contextual enhancement | Standalone tool or workflow |
| Panel types | SMALL (narrow) or LARGE (extended) | N/A (full page) |

## Project Setup

### Scaffolding

```bash
npx @commercetools-frontend/create-mc-app@latest my-custom-view \
  --application-type custom-view \
  --template starter
```

### Project Structure

```
my-custom-view/
├── custom-view-config.mjs       # Custom View configuration
├── package.json
├── src/
│   ├── components/
│   │   ├── entry-point/
│   │   │   └── entry-point.tsx   # CustomViewShell wrapper
│   │   ├── my-view/
│   │   │   └── my-view.tsx       # Main view content
│   │   └── ...
│   ├── hooks/
│   │   └── use-my-data-connector/
│   │       └── index.ts
│   └── constants.ts              # Permission keys
└── public/
```

## Configuration

### Correct Configuration

```javascript
// custom-view-config.mjs
const config = {
  name: 'Order Tracking View',
  cloudIdentifier: '${env:CLOUD_IDENTIFIER}',
  env: {
    development: {
      initialProjectKey: '${env:CTP_PROJECT_KEY}',
      hostUriPath: '/my-project/orders',  // Simulates rendering inside the Orders page locally
    },
    production: {
      customViewId: '${env:CUSTOM_VIEW_ID}',
      url: '${env:APPLICATION_URL}',
    },
  },
  type: 'CustomPanel',
  typeSettings: {
    size: 'LARGE',
  },
  locators: ['orders.order_details.general'],
  oAuthScopes: {
    view: ['view_orders'],
    manage: [],
  },
};

export default config;
```

**Key differences from Custom Application config:**

| Property | Custom Application | Custom View |
|----------|-------------------|-------------|
| Route identifier | `entryPointUriPath` | N/A (uses `locators`) |
| Production ID | `env.production.applicationId` | `env.production.customViewId` |
| Type | N/A | `type: 'CustomPanel'` (only supported value) |
| Size | N/A | `typeSettings.size` (`SMALL` or `LARGE`) |
| Menu | `mainMenuLink`, `submenuLinks` | N/A |
| Icon | `icon` | N/A |
| Dev host path | N/A | `env.development.hostUriPath` |
| Context hook | `useApplicationContext` | `useCustomViewContext` |

### Incorrect Configuration -- Common Mistakes

```javascript
// WRONG: Missing or invalid type
const config = {
  type: 'CustomPage',  // Only 'CustomPanel' is supported
};

// WRONG: No locators defined
const config = {
  type: 'CustomPanel',
  locators: [],  // Custom View will never appear anywhere
};

// WRONG: Mismatched panel size and content complexity
const config = {
  type: 'CustomPanel',
  typeSettings: {
    size: 'SMALL',  // Narrow panel cannot fit tables or complex forms
  },
  // But the view renders a large data table -- use LARGE instead
};
```

## Panel Types and Design Guidelines

### LARGE (Extended) Panel

Best for substantial content requiring significant interaction:
- Large tables and data grids
- Charts and visualizations
- Complex forms with multiple fields
- Multi-step workflows within the panel
- Content requiring two-column layouts

**Supported content layouts:** Full, Wide (single column), Wide (two columns 1:1), Wide (two columns 2:1)

### SMALL (Narrow) Panel

Best for simple, focused content:
- Displaying a small amount of contextual information
- Simple forms with minimal fields (e.g., quick status update)
- Additional context for a specific resource (e.g., tracking number, loyalty points)

**Supported content layout:** Narrow only

### Design Rules

| Feature | LARGE Panel | SMALL Panel |
|---------|-------------|-------------|
| Tables | Yes | No |
| Multi-column layouts | Yes | No |
| Modal dialogs | Yes (use `size=scale`) | Avoid |
| Modal pages | Yes | No |
| Complex forms | Yes | No |
| Simple forms (1-3 fields) | Yes | Yes |
| Info display | Yes | Yes |

## Available Locators

Locators determine where a Custom View appears in the built-in MC applications. Each locator maps to a specific page. The complete list (60+ locators):

### Products

| Locator | Page |
|---------|------|
| `products.product_details.general` | Product detail -- General tab |
| `products.product_details.variants` | Product detail -- Variants tab |
| `products.product_details.search` | Product detail -- Search tab |
| `products.product_details.selections` | Product detail -- Selections tab |
| `products.product_variant_details.general` | Variant detail -- General tab |
| `products.product_variant_details.images` | Variant detail -- Images tab |
| `products.product_variant_details.prices` | Variant detail -- Prices tab |
| `products.product_variant_details.prices.edit_price` | Variant -- Edit price modal |
| `products.product_variant_details.inventory` | Variant detail -- Inventory tab |
| `products.product_variant_details.inventory.details` | Variant -- Inventory details |
| `products.product_variant_details.inventory.details.add_inventory` | Variant -- Add inventory modal |
| `products.product_variant_images.add_image` | Variant -- Add image modal |
| `products.product_variant_prices.add_price` | Variant -- Add price modal |

### Categories

| Locator | Page |
|---------|------|
| `categories.category_details.general` | Category detail |
| `categories.category_details.products` | Category products |
| `categories.category_details.external_search` | Category external search |
| `categories.category_products.manage_storefront_order` | Category -- Manage storefront order |

### Customers

| Locator | Page |
|---------|------|
| `customers.customer_details.general` | Customer detail |
| `customers.customer_details.addresses` | Customer addresses |
| `customers.customer_details.orders` | Customer orders |
| `customers.customer_details.business_units` | Customer business units |
| `customers.customer_addresses.new_address` | Customer -- New address modal |
| `customers.customer_addresses.edit_address` | Customer -- Edit address modal |
| `customers.customer_orders.order_detail` | Customer -- Order detail |
| `customers.business_unit_details.general` | Business unit detail |
| `customers.business_unit_details.associates` | Business unit associates |
| `customers.business_unit_details.addresses` | Business unit addresses |
| `customers.business_unit_details.orders` | Business unit orders |
| `customers.business_unit_associates.new_associate` | BU -- New associate modal |
| `customers.business_unit_associates.edit_associate` | BU -- Edit associate modal |
| `customers.business_unit_addresses.new_address` | BU -- New address modal |
| `customers.business_unit_addresses.edit_address` | BU -- Edit address modal |
| `customers.add_business_unit.business_unit_details` | Add business unit modal |

### Orders

| Locator | Page |
|---------|------|
| `orders.order_details.general` | Order detail -- General |
| `orders.order_details.shipping_and_delivery` | Order shipping and delivery |
| `orders.order_details.returns` | Order returns |
| `orders.order_details.payments` | Order payments |
| `orders.order_shipping_and_delivery.create_delivery` | Order -- Create delivery modal |
| `orders.order_shipping_and_delivery.edit_delivery` | Order -- Edit delivery modal |
| `orders.order_shipping_and_delivery.add_parcel` | Order -- Add parcel modal |
| `orders.order_returns.create_return` | Order -- Create return modal |
| `orders.order_returns.edit_return` | Order -- Edit return modal |

### Standalone Prices

| Locator | Page |
|---------|------|
| `standalone_prices.add_standalone_price` | Add standalone price |
| `standalone_prices.standalone_price_details` | Standalone price detail |

### Discounts

| Locator | Page |
|---------|------|
| `discounts.product_discount_details.general` | Product discount detail |
| `discounts.cart_discount_details.general` | Cart discount detail |
| `discounts.cart_discount_details.custom_fields` | Cart discount -- Custom fields |
| `discounts.discount_code_details.general` | Discount code detail |
| `discounts.discount_code_details.custom_fields` | Discount code -- Custom fields |
| `discounts.generate_discount_codes` | Generate discount codes |

### Operations

| Locator | Page |
|---------|------|
| `operations.import_log_details` | Import log detail |

### Project Settings

| Locator | Page |
|---------|------|
| `settings.project.store_details` | Store settings |
| `settings.project.channel_details` | Channel settings |

## CustomViewShell

The `CustomViewShell` is the root wrapper for Custom Views, analogous to `ApplicationShell` for Custom Applications.

### Entry Point Pattern

```tsx
// src/components/entry-point/entry-point.tsx
import { lazy } from 'react';
import {
  CustomViewShell,
  setupGlobalErrorListener,
} from '@commercetools-frontend/application-shell';
import loadMessages from '../../load-messages';

const MyView = lazy(
  () => import('../my-view/my-view' /* webpackChunkName: "my-view" */)
);

setupGlobalErrorListener();

const EntryPoint = () => (
  <CustomViewShell
    environment={window.app}
    applicationMessages={loadMessages}
  >
    <MyView />
  </CustomViewShell>
);

export default EntryPoint;
```

### Accessing Host Context

Custom Views can access information about the host page using `useCustomViewContext`:

```tsx
import { useCustomViewContext } from '@commercetools-frontend/application-shell-connectors';

const MyView = () => {
  const { hostUrl } = useCustomViewContext(
    (context) => ({
      hostUrl: context.hostUrl,
    })
  );

  // Extract resource ID from the host URL
  // e.g., hostUrl = "/my-project/orders/order-id-123"
  const orderId = extractOrderIdFromUrl(hostUrl);

  return <OrderTrackingPanel orderId={orderId} />;
};
```

### Routing Within Custom Views

Custom Views can optionally define routes within the panel for multiple views (e.g., a list and detail view):

```tsx
import { Switch, Route, useRouteMatch } from 'react-router-dom';

const MyView = () => {
  const match = useRouteMatch();

  return (
    <Switch>
      <Route path={`${match.path}/:itemId`}>
        <ItemDetail />
      </Route>
      <Route>
        <ItemList />
      </Route>
    </Switch>
  );
};
```

However, for most Custom Views, a single view without routing is sufficient and recommended.

## Permissions for Custom Views

### Defining Permission Constants

```typescript
// src/constants.ts
import { resolveCustomViewResourceAccesses } from '@commercetools-frontend/application-config';

export const PERMISSIONS = resolveCustomViewResourceAccesses();
```

### With Additional Permission Groups

```typescript
export const PERMISSIONS = resolveCustomViewResourceAccesses([
  'delivery',
  'promotion',
]);
// Generates:
// PERMISSIONS.View
// PERMISSIONS.Manage
// PERMISSIONS.ViewDelivery
// PERMISSIONS.ManageDelivery
// PERMISSIONS.ViewPromotion
// PERMISSIONS.ManagePromotion
```

Note: Unlike Custom Applications, Custom View default permission names do not derive from an `entryPointUriPath`. Additional group names follow the format `{View,Manage}<GroupName>`.

## Incorrect Patterns

### Using ApplicationShell Instead of CustomViewShell

```tsx
// WRONG: ApplicationShell is for Custom Applications only
import { ApplicationShell } from '@commercetools-frontend/application-shell';

const EntryPoint = () => (
  <ApplicationShell environment={window.app}>
    <MyView />
  </ApplicationShell>
);

// CORRECT: Use CustomViewShell for Custom Views
import { CustomViewShell } from '@commercetools-frontend/application-shell';

const EntryPoint = () => (
  <CustomViewShell environment={window.app}>
    <MyView />
  </CustomViewShell>
);
```

### Ignoring Panel Size Constraints

```tsx
// WRONG: Rendering a complex DataTable in a SMALL panel
// The table will be cramped and unusable
// custom-view-config.mjs: typeSettings.size = 'SMALL'

const MyView = () => (
  <DataTable
    columns={[/* 8 columns */]}
    rows={data}
  />
);

// CORRECT: Use LARGE panel for tables, or simplify content for SMALL
// Option 1: Change config to size: 'LARGE'
// Option 2: Show a simple summary list instead of a full table
```

### Not Using useCustomViewContext for Host Data

```tsx
// WRONG: Trying to read URL params directly
// Custom Views are in an iframe -- window.location points to the iframe URL
const orderId = window.location.pathname.split('/').pop();

// CORRECT: Use the hook to access the host application context
const { hostUrl } = useCustomViewContext((context) => ({
  hostUrl: context.hostUrl,
}));
```

## Checklist: Custom View Setup

- [ ] Scaffolded with `create-mc-app` using `--application-type custom-view`
- [ ] `type` is set to `CustomPanel` (the only supported value)
- [ ] `typeSettings.size` matches content complexity (LARGE for tables/forms, SMALL for simple info)
- [ ] `locators` array includes at least one valid locator for the target page
- [ ] `oAuthScopes` declares minimum required scopes
- [ ] `env.production.customViewId` uses `${env:CUSTOM_VIEW_ID}` placeholder
- [ ] Entry point uses `CustomViewShell` (not `ApplicationShell`)
- [ ] Host page context accessed via `useCustomViewContext` (not `window.location`)
- [ ] Panel content follows design guidelines for the chosen size
- [ ] Tested in local development environment with the dummy host application

## Reference

- [Custom Views overview](https://docs.commercetools.com/merchant-center-customizations/custom-views)
- [Custom View Config](https://docs.commercetools.com/merchant-center-customizations/tooling-and-configuration/custom-view-config)
- [Design Guidelines for Custom Views](https://docs.commercetools.com/merchant-center-customizations/concepts/design-guidelines/custom-views)
- [Create and Install a Custom View tutorial](https://docs.commercetools.com/tutorials/create-custom-view)
