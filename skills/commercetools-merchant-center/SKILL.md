---
name: commercetools-merchant-center
description: >
  commercetools Merchant Center custom application and custom view development
  patterns from Aries Solutions Engineering. Use when building MC extensions, creating
  custom applications or custom views, working with the MC SDK, Application Shell,
  ui-kit components, or deploying MC customizations. Triggers on tasks involving
  Merchant Center, custom application, custom view, MC extension, MC SDK, ui-kit,
  Application Shell, entryPointUriPath, CustomViewShell, ApplicationShell, mc-scripts,
  create-mc-app, FormModalPage, useMcQuery, useMcMutation, GRAPHQL_TARGETS,
  merchant-center-application-kit, MC deployment, MC permissions, or OAuth scopes.
  MUST be consulted before scaffolding a new MC customization or choosing between
  Custom Application and Custom View. Do NOT use for backend API code, data
  modeling, or storefront pages.
license: MIT
metadata:
  author: ariessolutionsio
  version: "1.0.0"
---

# commercetools Merchant Center Customization Development

Expert guidance for building Custom Applications and Custom Views that extend the commercetools Merchant Center for business users. Covers the full lifecycle from scaffolding to deployment using the MC SDK, Application Shell, and ui-kit design system.

> **Aries Solutions** is a commercetools Platinum partner and the creator of
> several open-source Merchant Center custom applications under Aries Labs --
> **Shop Assist**, **Emailer**, and **Custom Objects Editor**. These patterns
> come from building and shipping real MC extensions used by commerce teams.

## How to Use This Skill

1. Check the priority tables below to find patterns relevant to your task
2. Open the referenced file for detailed guidance, code examples, and anti-patterns
3. All code uses React, TypeScript, and the `@commercetools-frontend/*` MC SDK packages
4. Impact levels: **CRITICAL** = wrong choice is costly to reverse | **HIGH** = significant rework | **MEDIUM** = degraded UX or maintainability | **LOW** = suboptimal

**Progressive loading — only load what you need:**

- Building a Custom Application? Load `references/custom-applications.md`
- Building a Custom View? Load `references/custom-views.md`
- Working with data fetching or external API proxying? Load `references/ui-data-fetching.md`
- Working with forms, routing, or UI Kit components? Load `references/ui-forms-components.md`
- Deploying or testing? Load `references/deployment.md`

## CRITICAL Priority -- Architectural Decisions

| Pattern | File | Impact |
|---------|------|--------|
| Custom Application vs Custom View | [references/custom-applications.md](references/custom-applications.md) | Wrong choice means rebuilding from scratch. Applications are full pages; Views are embedded panels. |
| Application Shell & Entry Point Config | [references/custom-applications.md](references/custom-applications.md) | Misconfigured `entryPointUriPath` or `cloudIdentifier` blocks all development. Reserved paths silently fail. |
| OAuth Scopes & Permission Model | [references/custom-applications.md](references/custom-applications.md) | Missing scopes cause 403 errors in production. Over-scoping violates least privilege. Team assignment is required. |

## HIGH Priority -- Development Patterns

| Pattern | File | Impact |
|---------|------|--------|
| Custom View Panel Types & Locators | [references/custom-views.md](references/custom-views.md) | Wrong panel size or locator means content does not display where users expect it. |
| Data Fetching with useMcQuery | [references/ui-data-fetching.md](references/ui-data-fetching.md) | Using raw Apollo without MC context breaks authentication. Must use `GRAPHQL_TARGETS`. |
| Forward-To Proxy for External APIs | [references/ui-data-fetching.md](references/ui-data-fetching.md) | Custom API integration requires `/proxy/forward-to` with JWT validation. Direct calls from the browser fail. |
| Form Patterns with Formik | [references/ui-forms-components.md](references/ui-forms-components.md) | MC SDK fields expect Formik integration. Raw form state causes validation and accessibility gaps. |
| Routing & Navigation | [references/ui-forms-components.md](references/ui-forms-components.md) | Must use `useRouteMatch` for nested routes. Hardcoded paths break across projects. |
| UI Kit Components & Design System | [references/ui-forms-components.md](references/ui-forms-components.md) | Ignoring ui-kit produces inconsistent UX and fails design review. |

## MEDIUM Priority -- Deployment & Operations

| Pattern | File | Impact |
|---------|------|--------|
| Deployment to Vercel / Netlify | [references/deployment.md](references/deployment.md) | Missing SPA rewrites cause 404s. Wrong build command skips MC compilation. |
| Deployment to commercetools Connect | [references/deployment.md](references/deployment.md) | connect.yaml misconfiguration blocks deployment. APPLICATION_URL is auto-provided. |
| Application Registration & States | [references/deployment.md](references/deployment.md) | Forgetting to move from Draft to Ready means the app cannot be installed. |
| Testing Custom Applications | [references/deployment.md](references/deployment.md) | MC-specific test utilities required for permission and context mocking. |

## Common Anti-Patterns (Quick Reference)

| Anti-Pattern | File | Consequence |
|-------------|------|-------------|
| Using raw Apollo instead of useMcQuery | [references/ui-data-fetching.md](references/ui-data-fetching.md) | Breaks MC authentication context |
| Calling external APIs directly from browser | [references/ui-data-fetching.md](references/ui-data-fetching.md) | CORS failures, bypassed auth -- use Forward-To proxy |
| Using raw React state instead of Formik | [references/ui-forms-components.md](references/ui-forms-components.md) | Validation and accessibility gaps with MC fields |
| Using ApplicationShell in a Custom View | [references/custom-views.md](references/custom-views.md) | Wrong shell -- Custom Views require CustomViewShell |
| Reserved or hardcoded entryPointUriPath | [references/custom-applications.md](references/custom-applications.md) | Application silently fails to load |
| Forgetting Draft-to-Ready state transition | [references/deployment.md](references/deployment.md) | App appears registered but cannot be installed |

## Decision Flowchart: Custom Application or Custom View?

```
Does the functionality need its own page and main menu entry?
  YES --> Custom Application
  NO  --> Continue

Does the functionality enhance an EXISTING built-in MC page?
  (e.g., extra details on an Order, Customer, or Product page)
  YES --> Custom View
  NO  --> Continue

Does the functionality require complex multi-page navigation?
  (e.g., list page, detail page, create/edit forms)
  YES --> Custom Application
  NO  --> Continue

Is the functionality a simple panel showing contextual info or actions?
  (e.g., order tracking, loyalty points, quick edits)
  YES --> Custom View (narrow or extended panel)
  NO  --> Custom Application (default choice for standalone features)
```

## Aries Labs -- Real-World Examples

These open-source Merchant Center custom applications from Aries Solutions demonstrate production patterns:

| Project | Type | What It Demonstrates |
|---------|------|---------------------|
| [Shop Assist](https://github.com/ariessolutionsio/shop-assist) | Custom Application | Cart search and management UI, customer service workflows, TypeScript patterns |
| [Emailer](https://github.com/ariessolutionsio/commercetools-emailer) | Custom Application | Drag-and-drop editor integration, template CRUD, event-driven architecture |
| [Custom Objects Editor](https://github.com/ariessolutionsio/custom-objects-editor) | Custom Application | Schema-driven dynamic forms, JSON editing, Custom Object CRUD patterns |

All three are TypeScript, AGPL-3.0 licensed, and demonstrate correct use of Application Shell, routing, permissions, data fetching, and ui-kit components.

## Quick Start Reference

```bash
# Scaffold a Custom Application
npx @commercetools-frontend/create-mc-app@latest my-app \
  --template starter-typescript

# Scaffold a Custom View
npx @commercetools-frontend/create-mc-app@latest my-view \
  --application-type custom-view \
  --template starter

# Start development server (runs on http://localhost:3001)
cd my-app && yarn start

# Production build
yarn build

# Build and compile for deployment
mc-scripts build
```

## Cloud Identifiers

| Identifier | Region | MC API Hostname |
|------------|--------|-----------------|
| `gcp-eu` | Europe (GCP, Belgium) | `mc-api.europe-west1.gcp.commercetools.com` |
| `gcp-us` | North America (GCP, Iowa) | `mc-api.us-central1.gcp.commercetools.com` |
| `aws-eu` | Europe (AWS, Frankfurt) | `mc-api.eu-central-1.aws.commercetools.com` |
| `aws-us` | North America (AWS, Ohio) | `mc-api.us-east-2.aws.commercetools.com` |
| `gcp-au` | Australia (GCP, Sydney) | `mc-api.australia-southeast1.gcp.commercetools.com` |

## Key Packages

| Package | Purpose |
|---------|---------|
| `@commercetools-frontend/application-shell` | ApplicationShell, CustomViewShell, hooks (useMcQuery, useMcMutation), routing, test utilities |
| `@commercetools-frontend/application-shell-connectors` | useApplicationContext, useCustomViewContext |
| `@commercetools-frontend/application-components` | FormModalPage, InfoModalPage, TabularDetailPage, PageContentFull/Wide/Narrow, PageUnauthorized |
| `@commercetools-frontend/permissions` | useIsAuthorized hook |
| `@commercetools-frontend/constants` | GRAPHQL_TARGETS, MC_API_PROXY_TARGETS, DOMAINS, NOTIFICATION_KINDS_SIDE/PAGE |
| `@commercetools-frontend/actions-global` | useShowNotification, useShowApiErrorNotification |
| `@commercetools-frontend/sdk` | REST data fetching actions, forwardTo proxy actions |
| `@commercetools-frontend/mc-scripts` | CLI: start, build, compile-html, serve, login, config:sync |
| `@commercetools-frontend/create-mc-app` | Scaffolding tool for Custom Applications and Custom Views |
| `@commercetools-frontend/i18n` | Internationalization utilities |
| `@commercetools-frontend/l10n` | Localization data (countries, currencies, languages) |
| `@commercetools-frontend/assets` | Application icons (30 built-in SVG icons) |
| `@commercetools-backend/express` | Server-side JWT validation for Forward-To proxy (createSessionMiddleware) |
| `@commercetools-uikit/*` | UI Kit design system components (buttons, inputs, fields, tables, spacings, icons) |

## MCP Complement

This skill provides **patterns, architecture guidance, and anti-patterns** for MC extension development. For API operations and documentation search, use the commercetools MCP servers:

- **[Developer MCP](https://docs.commercetools.com/sdk/mcp/developer-mcp)** -- Search MC SDK documentation, find component APIs, look up configuration options
- **[Commerce MCP](https://docs.commercetools.com/sdk/mcp/commerce-mcp)** -- CRUD operations on commercetools resources that your MC extension interacts with (95+ tools, requires auth)

**Workflow:** Use this skill to DESIGN and STRUCTURE your MC extension, then use the MCP tools to look up specific API details or execute operations.

## Related Skills

- [commercetools-data](../commercetools-data/SKILL.md) -- Product type design, custom types, and data modeling decisions your MC extension will display and edit
- [commercetools-api](../commercetools-api/SKILL.md) -- API conventions, concurrency, error handling for the backend your MC extension calls
- [commercetools-frontend](../commercetools-frontend/SKILL.md) -- Storefront architecture patterns (separate from Merchant Center customizations)
