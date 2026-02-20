# Deployment & Testing

Merchant Center customizations are Single-Page Applications that you build, host, and manage yourself. commercetools provides the build tooling (`mc-scripts`) and a registration system in the Merchant Center, but you choose the hosting platform.

## Table of Contents
- [mc-scripts CLI Reference](#mc-scripts-cli-reference)
  - [mc-scripts login Options](#mc-scripts-login-options)
  - [mc-scripts config:sync:ci Options](#mc-scripts-configsyncci-options)
  - [Dotenv File Loading Order](#dotenv-file-loading-order)
- [Deployment Workflow Overview](#deployment-workflow-overview)
- [Application Registration & States](#application-registration--states)
  - [Application States](#application-states)
  - [Installation](#installation)
- [Deploying to Static Hosting (Vercel, Netlify)](#deploying-to-static-hosting-vercel-netlify)
  - [Platform Comparison](#platform-comparison)
  - [Static Hosting Common Steps](#static-hosting-common-steps)
  - [Netlify SPA Redirect Requirement](#netlify-spa-redirect-requirement)
  - [Static Hosting Incorrect Patterns](#static-hosting-incorrect-patterns)
- [Deploying to commercetools Connect](#deploying-to-commercetools-connect)
  - [connect.yaml Structure](#connectyaml-structure)
  - [Connect-Specific Rules](#connect-specific-rules)
  - [Connect Incorrect Patterns](#connect-incorrect-patterns)
- [Deploying to AWS (S3 + CloudFront)](#deploying-to-aws-s3--cloudfront)
  - [High-Level Steps](#high-level-steps)
  - [CloudFront Error Page Configuration](#cloudfront-error-page-configuration)
- [Other Hosting Platforms](#other-hosting-platforms)
- [Content Security Policy (CSP)](#content-security-policy-csp)
- [Testing Custom Applications](#testing-custom-applications)
  - [Test Setup](#test-setup)
  - [Testing with renderApp](#testing-with-renderapp)
  - [Testing Permission Mappings](#testing-permission-mappings)
  - [Testing GraphQL Queries](#testing-graphql-queries)
  - [Cypress Integration Testing](#cypress-integration-testing)
- [Deployment Previews](#deployment-previews)
  - [Setup](#setup)
- [Checklist: Deployment](#checklist-deployment)
- [Checklist: Testing](#checklist-testing)
- [Reference](#reference)

## mc-scripts CLI Reference

The `@commercetools-frontend/mc-scripts` package provides all build and deployment tooling.

| Command | Description |
|---------|-------------|
| `mc-scripts start` (alias: `dev`) | Launch Webpack dev server at `http://localhost:3001` |
| `mc-scripts build` | Production bundle into `public/` directory |
| `mc-scripts build --build-only` | Bundle without compiling `index.html` (for custom HTML processing) |
| `mc-scripts compile-html` | Compile `index.html` with runtime config and security headers |
| `mc-scripts serve` | Serve built app locally for production testing |
| `mc-scripts login` | Authenticate and get a 36-hour API token |
| `mc-scripts config:sync` | Sync local config with Merchant Center (interactive) |
| `mc-scripts config:sync:ci` | Non-interactive config sync for CI/CD pipelines |

### mc-scripts login Options

```bash
# Interactive login (opens browser)
npx mc-scripts login

# With explicit MC API URL
npx mc-scripts login --mc-api-url=https://mc-api.europe-west1.gcp.commercetools.com

# With project key and scopes (for API token)
npx mc-scripts login --mc-api-url=... --project-key=my-project --oauth-scope=view_products

# Headless mode for CI (uses Puppeteer)
IDENTITY_EMAIL="user@example.com" IDENTITY_PASSWORD="pass" \
  npx mc-scripts login --headless
```

Token stored at `~/.commercetools/mc-credentials.json`.

### mc-scripts config:sync:ci Options

```bash
# Preview changes without applying
mc-scripts config:sync:ci --dry-run

# Full sync in CI/CD
MC_ACCESS_TOKEN=$TOKEN CT_ORGANIZATION_NAME="My Org" mc-scripts config:sync:ci
```

### Dotenv File Loading Order

Files loaded in priority order (first match wins per variable):

1. `.env.{development|test|production}.local`
2. `.env.{development|test|production}`
3. `.env.local` (all environments except test)
4. `.env`

Custom dotenv files: `mc-scripts --env=.env.local --env=.env.defaults start`

## Deployment Workflow Overview

```
1. Develop locally (yarn start, http://localhost:3001)
2. Register customization in Merchant Center (gets Application ID or Custom View ID)
3. Configure production environment variables
4. Build the application (mc-scripts build)
5. Deploy to hosting platform
6. Update registration with production URL
7. Move state from Draft to Ready
8. Install in target Projects
```

## Application Registration & States

Before deploying, you must register your customization in the Merchant Center:

**For Custom Applications:**
1. Go to **Organization Settings > Custom Applications**
2. Create a new Custom Application entry
3. Copy the generated **Application ID** -- this goes into `env.production.applicationId`

**For Custom Views:**
1. Go to **Organization Settings > Custom Views**
2. Create a new Custom View entry
3. Copy the generated **Custom View ID** -- this goes into `env.production.customViewId`

### Application States

| State | Meaning | Can Install? |
|-------|---------|-------------|
| **Draft** | Still in development, configuration can change | No |
| **Ready** | Production-ready, can be installed in Projects | Yes |

**Common mistake:** Forgetting to change the state from Draft to Ready. The application will appear registered but cannot be installed in any Project.

### Installation

After moving to Ready state:
1. Navigate to the Project where you want the customization
2. Go to **Project Settings > Custom Applications** (or Custom Views)
3. Install the customization
4. Assign permissions to Teams

## Deploying to Static Hosting (Vercel, Netlify)

Both Vercel and Netlify work well for MC customizations. The setup is nearly identical.

### Platform Comparison

| Setting | Vercel | Netlify |
|---------|--------|---------|
| Framework Preset | Create React App | (none needed) |
| Build Command | `yarn build` | `yarn build` |
| Output Directory | `public` | `public` |
| Node.js Version | 18+ (20 recommended) | 18+ |
| SPA Routing | Automatic with CRA preset | **Manual** -- requires `_redirects` file (see below) |
| Auto-deploy on push | Yes | Yes |

### Static Hosting Common Steps

1. **Connect your repository** via the platform's GitHub integration
2. **Configure build settings** per the table above (build command: `yarn build`, output: `public`)
3. **Set environment variables** in platform settings:

```
CUSTOM_APPLICATION_ID=<your-application-id>     # or CUSTOM_VIEW_ID for views
APPLICATION_URL=https://<project>.vercel.app     # or your custom domain
ENTRY_POINT_URI_PATH=my-custom-app
CLOUD_IDENTIFIER=gcp-eu                          # or your region
CTP_PROJECT_KEY=my-project
```

4. **Update your config** to use environment variable placeholders (see the `custom-application-config.mjs` example in [custom-applications.md](./custom-applications.md#configuration-file))
5. **Deploy** and **update MC registration** with the production URL; move state to Ready

### Netlify SPA Redirect Requirement

Netlify does **not** automatically route unknown paths to `index.html`. Without this, direct navigation to `/:projectKey/:entryPointUriPath/some-id` returns a 404.

```
# public/_redirects  (REQUIRED for Netlify)
/*    /index.html   200
```

Or equivalently in `netlify.toml`:

```toml
[[redirects]]
  from = "/*"
  to = "/index.html"
  status = 200
```

### Static Hosting Incorrect Patterns

```javascript
// WRONG: Output directory set to 'build'
// MC applications output to 'public', not 'build'

// WRONG: Hardcoding values instead of using env vars
const config = {
  env: {
    production: {
      applicationId: 'abc123',              // Exposed in version control
      url: 'https://my-app.vercel.app',     // Not configurable per environment
    },
  },
};
```

## Deploying to commercetools Connect

Connect is commercetools' own hosting platform. It handles deployment infrastructure and provides the application URL automatically.

### connect.yaml Structure

The YAML structure is the same for both Custom Applications and Custom Views. Adjust `name`, `applicationType`, and the ID key as noted below.

```yaml
deployAs:
  - name: my-custom-application            # or my-custom-view
    applicationType: merchant-center-custom-application
    # For Custom Views use: merchant-center-custom-view
    configuration:
      standardConfiguration:
        - key: CUSTOM_APPLICATION_ID       # For Custom Views use: CUSTOM_VIEW_ID
          description: The Application/View ID
          required: true
        - key: CLOUD_IDENTIFIER
          description: The cloud identifier (e.g., gcp-eu)
          default: 'gcp-eu'
        - key: ENTRY_POINT_URI_PATH        # Only needed for Custom Applications
          description: The application entry point URI path
          required: true
```

### Connect-Specific Rules

- **APPLICATION_URL is auto-provided** -- do NOT define it in `connect.yaml`. commercetools Connect generates the URL.
- Releases must have **Git tags** for Connect to detect deployable versions
- Private repositories require granting access to the `connect-mu` machine user
- After deployment, retrieve the generated URL from the Deployment object and update your MC registration

### Connect Incorrect Patterns

```yaml
# WRONG: Defining APPLICATION_URL in connect.yaml
configuration:
  standardConfiguration:
    - key: APPLICATION_URL            # Auto-provided by Connect -- do NOT define
      description: The application URL
      required: true

# WRONG: Using wrong applicationType
deployAs:
  - name: my-view
    applicationType: merchant-center-custom-application  # Should be merchant-center-custom-view for Custom Views
```

## Deploying to AWS (S3 + CloudFront)

### High-Level Steps

1. **Build** the application: `yarn build`
2. **Upload** the `public/` directory contents to an S3 bucket
3. **Configure CloudFront** distribution pointing to the S3 bucket
4. **Set up error page handling** -- route all 404s to `/index.html` with a 200 status (SPA requirement)
5. **Set environment variables** during the build step (CI/CD pipeline)
6. **Update MC registration** with the CloudFront domain URL

### CloudFront Error Page Configuration

```json
{
  "CustomErrorResponses": [
    {
      "ErrorCode": 404,
      "ResponseCode": 200,
      "ResponsePagePath": "/index.html",
      "ErrorCachingMinTTL": 0
    },
    {
      "ErrorCode": 403,
      "ResponseCode": 200,
      "ResponsePagePath": "/index.html",
      "ErrorCachingMinTTL": 0
    }
  ]
}
```

## Other Hosting Platforms

The following platforms are also supported. The key requirements for any platform are:

1. **SPA routing** -- All paths must serve `index.html` (client-side routing)
2. **Static file hosting** -- The built output is static HTML/JS/CSS
3. **Environment variables** -- Available at build time for `mc-scripts build`
4. **HTTPS** -- Required for MC integration

| Platform | Notes |
|----------|-------|
| Azure Static Web Apps | Configure fallback route to `index.html` |
| Azure Blob Storage | Use Azure CDN with custom error rules |
| Google Cloud | Cloud Storage + Cloud CDN with error page config |
| Cloudflare Pages | Built-in SPA support, configure build command |
| Render | Static site type, redirect/rewrite rules for SPA |
| Surge | Simple deployment with `surge public/` |

## Content Security Policy (CSP)

If your customization loads external resources (fonts, scripts, images), configure CSP headers in the config:

```javascript
// custom-application-config.mjs
const config = {
  headers: {
    csp: {
      'connect-src': ['https://my-api.example.com'],
      'font-src': ['https://fonts.gstatic.com'],
      'img-src': ['https://images.example.com'],
      'style-src': ['https://fonts.googleapis.com'],
      'script-src': ['https://analytics.example.com'],
    },
  },
};
```

**Common mistake:** Forgetting to add CSP directives for external APIs. The browser silently blocks requests, and the only symptom is failed API calls with no clear error in the application.

## Testing Custom Applications

### Test Setup

MC provides test utilities that mock the ApplicationShell context:

```tsx
// jest.test.config.js
module.exports = {
  preset: '@commercetools-frontend/jest-preset-mc-app',
};
```

### Testing with renderApp

```tsx
import { renderApp } from '@commercetools-frontend/application-shell/test-utils';
import { entryPointUriPath } from '../constants';
import MyComponent from './my-component';

it('renders with view permissions', () => {
  const rendered = renderApp(<MyComponent />, {
    route: `/${entryPointUriPath}`,
    permissions: { canView: true, canManage: false },
    environment: { entryPointUriPath },
  });
  expect(rendered.getByText('My Resource List')).toBeInTheDocument();
});
```

For Custom Views, use `renderCustomView` instead of `renderApp`. It accepts the same options plus a `hostUrl` property (e.g., `hostUrl: '/my-project/orders/order-123'`).

### Testing Permission Mappings

```tsx
import {
  mapResourceAccessToAppliedPermissions,
  denormalizePermissions,
} from '@commercetools-frontend/application-shell/test-utils';

const permissions = mapResourceAccessToAppliedPermissions(
  [PERMISSIONS.View, PERMISSIONS.Manage],
  ['view', 'manage']
);
```

`denormalizePermissions` is available for more complex permission setups (e.g., `{ ViewMyCustomApp: true, ManageMyCustomApp: true }`).

### Testing GraphQL Queries

Pass `mocks` to `renderApp` to supply Apollo MockedProvider responses:

```tsx
renderApp(<ChannelList />, {
  mocks: [
    {
      request: { query: FetchChannelsQuery, variables: { limit: 20, offset: 0 } },
      result: { data: { channels: { results: [{ id: '1', key: 'ch-1' }], total: 1 } } },
    },
  ],
});
await waitFor(() => expect(screen.getByText('ch-1')).toBeInTheDocument());
```

### Cypress Integration Testing

The MC SDK provides a Cypress preset: `@commercetools-frontend/cypress` (add to `devDependencies`).

## Deployment Previews

Custom Applications support deployment previews for testing branches before merging to production.

### Setup

1. Deploy your branch to a preview URL (Vercel/Netlify auto-generate these for PRs)
2. Register the preview URL using the CLI:

```bash
mc-scripts deployment-previews:set
```

3. The preview deployment is accessible alongside the production version
4. Preview URLs are temporary and tied to the pull request lifecycle

This is useful for QA review of MC customization changes before merging.

## Checklist: Deployment

- [ ] Application registered in MC Organization settings
- [ ] Application ID (or Custom View ID) copied to config
- [ ] Production URL configured (or auto-provided by Connect)
- [ ] Environment variables set on hosting platform (not hardcoded in config)
- [ ] Build command is `yarn build` (which runs `mc-scripts build`)
- [ ] Output directory is `public` (not `build` or `dist`)
- [ ] SPA routing configured (all paths serve `index.html`)
- [ ] HTTPS enabled on hosting platform
- [ ] CSP headers configured for any external resource domains
- [ ] Application state moved from Draft to Ready
- [ ] Application installed in target Project(s)
- [ ] Team permissions assigned (View and/or Manage)
- [ ] Smoke test: verify the application loads and API calls succeed
- [ ] Test with a non-admin user to verify permission enforcement

## Checklist: Testing

- [ ] Jest configured with `@commercetools-frontend/jest-preset-mc-app`
- [ ] Components tested with `renderApp` (Custom Applications) or `renderCustomView` (Custom Views)
- [ ] Permission scenarios tested (view-only user, manage user, unauthorized)
- [ ] GraphQL queries mocked with Apollo test utilities
- [ ] Data conversion functions (`docToFormValues`, `formValuesToDoc`) have unit tests
- [ ] Form validation logic has unit tests
- [ ] Error states tested (API failures, loading states)

## Reference

- [Deployment overview](https://docs.commercetools.com/merchant-center-customizations/deployment/overview)
- [Deploy to Vercel](https://docs.commercetools.com/merchant-center-customizations/deployment/vercel)
- [Deploy to Netlify](https://docs.commercetools.com/merchant-center-customizations/deployment/netlify)
- [Deploy to Connect](https://docs.commercetools.com/merchant-center-customizations/deployment/commercetools-connect)
- [Managing Custom Applications](https://docs.commercetools.com/merchant-center/managing-custom-applications)
- [Application Shell test utilities](https://docs.commercetools.com/merchant-center-customizations/tooling-and-configuration/commercetools-frontend-application-shell)
