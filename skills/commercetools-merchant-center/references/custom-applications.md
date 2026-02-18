# Custom Applications

Custom Applications are standalone React applications that integrate into the Merchant Center as full-page experiences with their own navigation entry. They appear in the MC main menu and have their own URL space under `/:projectKey/:entryPointUriPath`.

## When to Use a Custom Application

- You need a **dedicated page** in the Merchant Center (list view, detail view, create/edit forms)
- The functionality does **not** relate to a single existing built-in page
- You need **complex multi-page navigation** (tabs, nested routes, modal pages)
- You are building a **tool** for business users (e.g., email template manager, custom object editor, cart assistant)

**Real-world examples from Aries Labs:**
- **Shop Assist** -- full cart search and management UI with list and detail views
- **Emailer** -- email template CRUD with a drag-and-drop editor
- **Custom Objects Editor** -- schema definition and object management with dynamic forms

## Project Setup

### Scaffolding

```bash
# TypeScript starter (recommended)
npx @commercetools-frontend/create-mc-app@latest my-custom-app \
  --template starter-typescript

# JavaScript starter
npx @commercetools-frontend/create-mc-app@latest my-custom-app \
  --template starter
```

This creates a ready-to-run project with:
- `custom-application-config.mjs` -- application configuration
- `src/` -- React component source code
- `package.json` with `mc-scripts` commands
- Development server configuration

### Project Structure

```
my-custom-app/
├── custom-application-config.mjs    # MC configuration
├── package.json
├── src/
│   ├── components/
│   │   ├── entry-point/
│   │   │   └── entry-point.tsx      # Main entry, defines routes
│   │   ├── my-resource/
│   │   │   ├── my-resource-list.tsx  # List page
│   │   │   └── my-resource-detail.tsx # Detail page
│   │   └── ...
│   ├── hooks/
│   │   └── use-my-resource-connector/
│   │       ├── index.ts
│   │       └── fetch-my-resources.ctp.graphql
│   ├── constants.ts                  # Permission keys, paths
│   └── routes.tsx                    # Route definitions
├── jest.test.config.js
└── public/
```

## Configuration

The configuration file is the single most important file. A misconfigured application will not load.

**File format:** Supports `.json`, `.js`, `.cjs`, `.mjs`, or `.ts`. The `.mjs` format is recommended because it allows importing constants from your source code. All three Aries Labs projects use `.mjs`.

**TypeScript type:** `ConfigOptionsForCustomApplication` from `@commercetools-frontend/application-config` (use `ConfigOptions` for the older generic type).

### Cloud Identifiers

| Identifier | Region |
|------------|--------|
| `gcp-eu` | Europe (GCP, Belgium) |
| `gcp-us` | North America (GCP, Iowa) |
| `aws-eu` | Europe (AWS, Frankfurt) |
| `aws-us` | North America (AWS, Ohio) |
| `gcp-au` | Australia (GCP, Sydney) |

### Available Application Icons

30 built-in SVG icons: `bag`, `bell`, `box`, `chat`, `code`, `export`, `files`, `folder`, `gift`, `globe`, `graph`, `headphones`, `import`, `location`, `network`, `percentage`, `pricetag`, `rocket`, `screen`, `search`, `settings`, `special`, `stack`, `stamp`, `star`, `stats`, `trolley`, `truck`, `users`, `wrench`.

Reference with: `${path:@commercetools-frontend/assets/application-icons/<name>.svg}`

### Correct Configuration

```typescript
// custom-application-config.mjs
import { PERMISSIONS, entryPointUriPath } from './src/constants';

const config = {
  name: 'My Custom App',
  entryPointUriPath: '${env:ENTRY_POINT_URI_PATH}',
  cloudIdentifier: '${env:CLOUD_IDENTIFIER}',
  env: {
    development: {
      initialProjectKey: '${env:CTP_PROJECT_KEY}',
    },
    production: {
      applicationId: '${env:CUSTOM_APPLICATION_ID}',
      url: '${env:APPLICATION_URL}',
    },
  },
  oAuthScopes: {
    view: ['view_products'],
    manage: ['manage_products'],
  },
  icon: '${path:@commercetools-frontend/assets/application-icons/rocket.svg}',
  mainMenuLink: {
    defaultLabel: 'My Custom App',
    labelAllLocales: [],
    permissions: [PERMISSIONS.View],
  },
  submenuLinks: [
    {
      uriPath: 'new',
      defaultLabel: 'Create New',
      labelAllLocales: [],
      permissions: [PERMISSIONS.Manage],
    },
  ],
};

export default config;
```

### additionalEnv for Custom Variables

Inject custom values into the runtime via `window.app`:

```javascript
// custom-application-config.mjs
const config = {
  // ... other config
  additionalEnv: {
    externalApiUrl: '${env:EXTERNAL_API_URL}',
    featureEnabled: '${env:FEATURE_ENABLED}',
  },
};

// Access at runtime:
import { useApplicationContext } from '@commercetools-frontend/application-shell-connectors';
const externalApiUrl = useApplicationContext(
  (context) => context.environment.externalApiUrl
);
```

All three Aries Labs projects use `additionalEnv` for custom configuration (Cloudinary settings, API URLs, feature flags).

### Variable Placeholders

| Syntax | Purpose | Example |
|--------|---------|---------|
| `${env:VAR_NAME}` | Environment variable | `${env:CLOUD_IDENTIFIER}` |
| `${intl:LOCALE:KEY}` | Intl message reference | `${intl:en:Menu.label}` |
| `${path:PATH}` | File path resolution | `${path:@commercetools-frontend/assets/application-icons/rocket.svg}` |

### Incorrect Configuration -- Common Mistakes

```typescript
// WRONG: Using a reserved entryPointUriPath
const config = {
  entryPointUriPath: 'products',  // RESERVED -- will conflict with built-in Products app
  // ...
};

// WRONG: Hardcoding production values in config
const config = {
  env: {
    production: {
      applicationId: 'abc123-real-id',  // Should use ${env:CUSTOM_APPLICATION_ID}
      url: 'https://my-app.vercel.app', // Should use ${env:APPLICATION_URL}
    },
  },
};

// WRONG: Missing oAuthScopes
const config = {
  name: 'My App',
  entryPointUriPath: 'my-app',
  // No oAuthScopes -- all API calls will fail with 403
};
```

### entryPointUriPath Rules

- 2-64 characters, lowercase alphanumeric and hyphens only
- Cannot start or end with a hyphen
- No consecutive hyphens
- This value determines the URL: `/:projectKey/:entryPointUriPath`
- It also determines default permission names: `View<EntryPointUriPath>` / `Manage<EntryPointUriPath>`

**Reserved values** (will silently fail or conflict with built-in MC applications):

```
account, audit-log, categories, change-history, customers, dashboard,
disabled, discounts, exports, impex, imports, imports-exports, operations,
orders, products, settings, standalone-prices, welcome
```

## Application Shell

The `ApplicationShell` component is the root wrapper for every Custom Application. It provides authentication, routing, permissions, Apollo Client, and the MC chrome (header, sidebar).

### Entry Point Pattern

```tsx
// src/components/entry-point/entry-point.tsx
import { lazy } from 'react';
import {
  ApplicationShell,
  setupGlobalErrorListener,
} from '@commercetools-frontend/application-shell';
import loadMessages from '../../load-messages';

const AsyncRoutes = lazy(
  () => import('../../routes' /* webpackChunkName: "routes" */)
);

// Setup global error listener for Sentry integration
setupGlobalErrorListener();

const EntryPoint = () => (
  <ApplicationShell
    environment={window.app}
    applicationMessages={loadMessages}
  >
    <AsyncRoutes />
  </ApplicationShell>
);

export default EntryPoint;
```

**What ApplicationShell provides automatically:**
- User authentication and session management
- Apollo Client pre-configured for MC API
- React Router with base route `/:projectKey/:entryPointUriPath`
- Permissions context
- Internationalization (react-intl)
- MC chrome (navigation header, project selector)
- Sentry error reporting integration

## OAuth Scopes & Permissions

### Defining Permission Constants

```typescript
// src/constants.ts
import { entryPointUriPathToPermissionKeys } from '@commercetools-frontend/application-shell/ssr';

export const entryPointUriPath = 'my-custom-app';

// Generates: { View: 'ViewMyCustomApp', Manage: 'ManageMyCustomApp' }
export const PERMISSIONS = entryPointUriPathToPermissionKeys(entryPointUriPath);
```

### With Additional Permission Groups

```typescript
// For granular permissions (v21.21.0+)
export const PERMISSIONS = entryPointUriPathToPermissionKeys(
  entryPointUriPath,
  ['delivery', 'promotion']
);
// Generates:
// PERMISSIONS.View = 'ViewMyCustomApp'
// PERMISSIONS.Manage = 'ManageMyCustomApp'
// PERMISSIONS.ViewDelivery = 'ViewMyCustomAppDelivery'
// PERMISSIONS.ManageDelivery = 'ManageMyCustomAppDelivery'
// PERMISSIONS.ViewPromotion = 'ViewMyCustomAppPromotion'
// PERMISSIONS.ManagePromotion = 'ManageMyCustomAppPromotion'
```

### Config with Additional Groups

```javascript
// custom-application-config.mjs
const config = {
  oAuthScopes: {
    view: ['view_orders'],
    manage: ['manage_orders'],
  },
  additionalOAuthScopes: [
    {
      name: 'delivery',
      view: [],
      manage: ['manage_orders'],
    },
    {
      name: 'promotion',
      view: [],
      manage: ['manage_orders', 'manage_discount_codes'],
    },
  ],
};
```

### Enforcing Permissions in Code

```tsx
import { useIsAuthorized } from '@commercetools-frontend/permissions';
import { PageUnauthorized } from '@commercetools-frontend/application-components';
import { PERMISSIONS } from '../../constants';

const MyResourceCreate = () => {
  const canManage = useIsAuthorized({
    demandedPermissions: [PERMISSIONS.Manage],
  });

  if (!canManage) {
    return <PageUnauthorized />;
  }

  return <CreateForm />;
};
```

### Disabling UI Elements Based on Permissions

```tsx
import { useIsAuthorized } from '@commercetools-frontend/permissions';
import PrimaryButton from '@commercetools-uikit/primary-button';

const MyResourceDetail = ({ onSave }) => {
  const canManage = useIsAuthorized({
    demandedPermissions: [PERMISSIONS.Manage],
  });

  return (
    <div>
      {/* Show data to everyone with View permission */}
      <DataDisplay />

      {/* Disable save button for users without Manage permission */}
      <PrimaryButton
        label="Save"
        onClick={onSave}
        isDisabled={!canManage}
      />
    </div>
  );
};
```

### How Permissions Flow

1. **Config declares scopes** -- `oAuthScopes` in `custom-application-config.mjs`
2. **Organization admin assigns permissions** -- In MC, under Team settings, assign View/Manage for each custom application
3. **Code checks permissions** -- `useIsAuthorized` reads the user's assigned permissions at runtime
4. **API enforces scopes** -- When the user makes API calls through the MC proxy, only their granted OAuth scopes are used

**Anti-pattern:** Assuming all users have Manage permissions. Always check permissions and gracefully degrade the UI for view-only users.

## Routing

### Basic Route Setup

```tsx
// src/routes.tsx
import { Switch, Route, useRouteMatch } from 'react-router-dom';
import { useIsAuthorized } from '@commercetools-frontend/permissions';
import { PageUnauthorized } from '@commercetools-frontend/application-components';
import { PERMISSIONS } from './constants';
import MyResourceList from './components/my-resource/my-resource-list';
import MyResourceDetail from './components/my-resource/my-resource-detail';
import MyResourceCreate from './components/my-resource/my-resource-create';

const ApplicationRoutes = () => {
  const match = useRouteMatch();
  const canManage = useIsAuthorized({
    demandedPermissions: [PERMISSIONS.Manage],
  });

  return (
    <Switch>
      {/* Detail route -- must be before the catch-all */}
      <Route path={`${match.path}/:id`}>
        <MyResourceDetail />
      </Route>

      {/* Create route -- permission-gated */}
      <Route path={`${match.path}/new`}>
        {canManage ? <MyResourceCreate /> : <PageUnauthorized />}
      </Route>

      {/* List route (default) */}
      <Route>
        <MyResourceList />
      </Route>
    </Switch>
  );
};

export default ApplicationRoutes;
```

### Using useRoutesCreator for Type-Safe Routing

```tsx
import { useRoutesCreator } from '@commercetools-frontend/application-shell';
import { entryPointUriPath } from './constants';

const useRoutes = () => {
  const { createRoute } = useRoutesCreator();

  return {
    list: createRoute(`/:projectKey/${entryPointUriPath}`),
    detail: createRoute<'id'>(
      `/:projectKey/${entryPointUriPath}/:id`
    ),
    create: createRoute(
      `/:projectKey/${entryPointUriPath}/new`
    ),
  };
};

// Usage in a component
const MyComponent = () => {
  const routes = useRoutes();

  // Navigate programmatically
  const handleRowClick = (id: string) => {
    routes.detail.go({ id });
  };

  // Get URL for links
  const detailUrl = routes.detail.getUrl({ id: '123' });

  // With query parameters
  const filteredUrl = routes.list.getUrl(
    {},
    new URLSearchParams({ status: 'active' })
  );
};
```

### Incorrect Routing Patterns

```tsx
// WRONG: Hardcoded project key in routes
<Route path="/my-project/my-app/:id">  {/* Breaks in other projects */}

// WRONG: Not using match.path for nested routes
<Route path="/my-app/:id">  {/* Ignores project key prefix */}

// CORRECT: Always use match.path or useRoutesCreator
const match = useRouteMatch();
<Route path={`${match.path}/:id`}>
```

## Checklist: Custom Application Setup

- [ ] Scaffolded with `create-mc-app` using `--template starter-typescript`
- [ ] `entryPointUriPath` is unique and not a reserved value
- [ ] `cloudIdentifier` matches the target commercetools region
- [ ] `oAuthScopes` lists the minimum required scopes (view and manage)
- [ ] `env.production.applicationId` uses `${env:CUSTOM_APPLICATION_ID}` placeholder
- [ ] `env.production.url` uses `${env:APPLICATION_URL}` placeholder
- [ ] Permission constants defined using `entryPointUriPathToPermissionKeys`
- [ ] `useIsAuthorized` checks added to all write/create/delete operations
- [ ] Routes use `useRouteMatch` or `useRoutesCreator` (no hardcoded paths)
- [ ] `ApplicationShell` wraps all content in the entry point component
- [ ] Menu links have `permissions` arrays configured
- [ ] Local development tested with `yarn start` on `http://localhost:3001`

## Reference

- [Custom Applications overview](https://docs.commercetools.com/merchant-center-customizations/custom-applications)
- [Custom Application Config](https://docs.commercetools.com/merchant-center-customizations/tooling-and-configuration/custom-application-config)
- [Application Shell](https://docs.commercetools.com/merchant-center-customizations/tooling-and-configuration/commercetools-frontend-application-shell)
- [OAuth Scopes and Permissions](https://docs.commercetools.com/merchant-center-customizations/concepts/oauth-scopes-and-user-permissions)
- [Permissions Development Guide](https://docs.commercetools.com/merchant-center-customizations/development/permissions)
- [Aries Labs Shop Assist](https://github.com/ariessolutionsio/shop-assist)
- [Aries Labs Emailer](https://github.com/ariessolutionsio/commercetools-emailer)
- [Aries Labs Custom Objects Editor](https://github.com/ariessolutionsio/custom-objects-editor)
