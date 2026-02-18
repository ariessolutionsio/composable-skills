# Aries Composable Commerce Skills

Comprehensive commercetools and composable commerce guidance from Aries Solutions Engineering.

## Skill Routing

When a task matches the keywords below, load the corresponding skill's SKILL.md for detailed patterns and reference files.

### commercetools-api
**Load for:** commercetools SDK, ts-client, platform-sdk, apiRoot, carts, orders, customers, payments, extensions, subscriptions, discounts, business units, approval rules, quotes, GraphQL, query predicates, update actions, optimistic concurrency, version conflicts, cart lifecycle, checkout flow, payment integration, order state machine, returns, refunds, B2B commerce, promotions, discount stacking, Connect apps.
→ [skills/commercetools-api/SKILL.md](skills/commercetools-api/SKILL.md)

### commercetools-data
**Load for:** product types, attributes, variants, custom fields, custom types, custom objects, categories, category hierarchies, Import API, data migration, product selections, stores, channels, state machines, localization, LocalizedString, product type design, data modeling, import/export, bulk operations, catalog management.
→ [skills/commercetools-data/SKILL.md](skills/commercetools-data/SKILL.md)

### commercetools-merchant-center
**Load for:** Merchant Center, custom application, custom view, MC extension, MC SDK, ui-kit, Application Shell, entryPointUriPath, CustomViewShell, ApplicationShell, mc-scripts, create-mc-app, FormModalPage, useMcQuery, useMcMutation, GRAPHQL_TARGETS, merchant-center-application-kit, MC deployment, MC permissions, OAuth scopes.
→ [skills/commercetools-merchant-center/SKILL.md](skills/commercetools-merchant-center/SKILL.md)

### commercetools-frontend
**Load for:** storefront, frontend, Next.js, React, SSR, SSG, ISR, Server Components, App Router, commercetools Frontend, Studio, tastics, extensions, data sources, actions, PDP, PLP, category pages, cart UI, checkout UI, headless commerce, GraphQL frontend, product search UI, SEO, Core Web Vitals, performance, image optimization, i18n, locale routing, structured data, sitemap, B2B storefront.
→ [skills/commercetools-frontend/SKILL.md](skills/commercetools-frontend/SKILL.md)

### akeneo (coming soon)
**Load for:** Akeneo, PIM, product information management, families, attributes, channels, locales, product enrichment, Akeneo API, product sync.
→ [skills/akeneo/SKILL.md](skills/akeneo/SKILL.md)

### algolia (coming soon)
**Load for:** Algolia, InstantSearch, search index, facets, ranking, relevance, product search UI, autocomplete, search analytics, synonyms, query rules.
→ [skills/algolia/SKILL.md](skills/algolia/SKILL.md)

## Cross-Skill Combinations

Some tasks benefit from loading multiple skills:

| Task | Load These Skills |
|------|-------------------|
| Building a storefront with API integration | commercetools-api + commercetools-frontend |
| Designing data models and importing data | commercetools-data + commercetools-api |
| Building MC app that manages custom data | commercetools-merchant-center + commercetools-data |
| Building storefront with custom MC tooling | commercetools-frontend + commercetools-merchant-center |
| Full-stack commerce feature | commercetools-api + commercetools-data + commercetools-frontend |
| PIM-to-commerce pipeline | akeneo + commercetools-data + commercetools-api |
| Search-powered storefront | algolia + commercetools-frontend + commercetools-data |

## MCP Complement

These skills provide **judgment, patterns, and anti-patterns**. For API access and schema reference, use the commercetools MCP servers:

- [Developer MCP](https://docs.commercetools.com/sdk/mcp/developer-mcp) — Documentation search, GraphQL/OAS schema fetching (free, 100 req/15 min)
- [Commerce MCP](https://docs.commercetools.com/sdk/mcp/commerce-mcp) — CRUD operations on commercetools resources (95+ tools, requires auth)

**Workflow:** Use skills to understand the _right pattern_, then use the MCP to look up exact field names and API shapes, then write the code.
