---
name: commercetools-api
description: >
  Backend development patterns for the commercetools HTTP and GraphQL APIs from
  Aries Solutions Engineering. Use when building cart/checkout flows, order
  management, customer auth, payment integration, API extensions, subscriptions,
  B2B commerce (business units, approvals, quotes), promotions/discounts, or
  product search. Triggers on tasks involving commercetools SDK, ts-client,
  platform-sdk, apiRoot, carts, orders, customers, payments, extensions,
  subscriptions, discounts, business units, approval rules, quotes, GraphQL,
  query predicates, update actions, optimistic concurrency, version conflicts,
  cart lifecycle, checkout flow, payment integration, order state machine,
  returns, refunds, B2B commerce, promotions, discount stacking, Connect apps.
  MUST be consulted before writing commercetools API integration code.
  Do NOT use for data modeling, Merchant Center UI, or storefront pages.
license: MIT
metadata:
  author: ariessolutionsio
  version: "1.0.0"
---

# commercetools API Development

Production-tested patterns for the commercetools HTTP and GraphQL APIs, built from hundreds of real-world implementations by Aries Solutions Engineering.

> **Aries Solutions** is a commercetools Platinum partner with the most live
> commercetools implementations in North America. These patterns reflect
> real-world lessons, not theoretical best practices.

## How to Use This Skill

1. Read the priority tables below to find relevant patterns for your task
2. **MUST load the relevant reference file** before writing any commercetools API code
3. For SDK client setup, **always start with** `references/sdk-setup.md`
4. Reference files contain correct/incorrect code pairs, checklists, and pitfall warnings
5. When in doubt, check `references/anti-patterns.md` for the most common mistakes

**Progressive loading — only load what you need:**

- Setting up the SDK or client? Load `references/sdk-setup.md`
- Building cart or checkout? Load `references/cart-checkout.md`
- Working with orders? Load `references/order-management.md`
- Managing customers? Load `references/customer-management.md`
- Setting up extensions or subscriptions? Load `references/extensions-subscriptions.md`
- Implementing discounts? Load `references/promotions-pricing.md`
- Building B2B features? Load `references/b2b-patterns.md`
- Implementing search? Load `references/search-discovery.md`
- Optimizing performance? Load `references/performance.md`
- Code review or debugging? Load `references/anti-patterns.md`

## CRITICAL Priority

| Pattern | File | Impact |
|---------|------|--------|
| Optimistic concurrency & version handling | [references/sdk-setup.md](references/sdk-setup.md) | Every update/delete fails without correct version tracking |
| Cart lifecycle & freeze before payment | [references/cart-checkout.md](references/cart-checkout.md) | Price changes during checkout cause order failures |
| Payment flow — never reuse/delete Payments | [references/cart-checkout.md](references/cart-checkout.md) | Lost audit trail, double charges, PSP inconsistencies |
| Extension timeout constraints (2s / 10s) | [references/extensions-subscriptions.md](references/extensions-subscriptions.md) | Entire API call fails on timeout — affects all clients |
| Discount stacking & sort order | [references/promotions-pricing.md](references/promotions-pricing.md) | Unexpected pricing, revenue loss, customer complaints |
| Direct Discounts block Discount Codes | [references/promotions-pricing.md](references/promotions-pricing.md) | Codes silently stop working when Direct Discounts exist |

## HIGH Priority

| Pattern | File | Impact |
|---------|------|--------|
| Client setup & auth flows | [references/sdk-setup.md](references/sdk-setup.md) | Wrong setup causes auth failures and token leaks |
| Order state machines & returns | [references/order-management.md](references/order-management.md) | Invalid state transitions, incomplete fulfillment |
| Customer auth & email verification | [references/customer-management.md](references/customer-management.md) | Broken sign-up/login, unverified accounts |
| Subscription idempotency & ordering | [references/extensions-subscriptions.md](references/extensions-subscriptions.md) | Duplicate side effects, stale data overwrites |
| Business unit hierarchies & permissions | [references/b2b-patterns.md](references/b2b-patterns.md) | Security gaps, broken approval workflows |
| Product Search API vs Query API | [references/search-discovery.md](references/search-discovery.md) | 10-100x slower queries on large catalogs |
| N+1 queries & reference expansion | [references/performance.md](references/performance.md) | Cascading latency on listing pages |

## MEDIUM Priority

| Pattern | File | Impact |
|---------|------|--------|
| Tax mode configuration | [references/cart-checkout.md](references/cart-checkout.md) | Failed order creation from incomplete tax data |
| Approval rules & quote lifecycle | [references/b2b-patterns.md](references/b2b-patterns.md) | Blocked B2B purchasing workflows |
| Connect application patterns | [references/extensions-subscriptions.md](references/extensions-subscriptions.md) | Deployment failures, resource constraint issues |
| Pagination & query optimization | [references/performance.md](references/performance.md) | Slow page loads, unnecessary API load |
| Customer groups & address management | [references/customer-management.md](references/customer-management.md) | Wrong pricing tiers, address data issues |
| Faceting & search performance | [references/search-discovery.md](references/search-discovery.md) | Slow search responses, poor relevance |

## Common Anti-Patterns (Quick Reference)

| Anti-Pattern | File | Consequence |
|-------------|------|-------------|
| Creating a client per request | [references/anti-patterns.md](references/anti-patterns.md) | Memory leaks, token exhaustion |
| Not batching update actions | [references/anti-patterns.md](references/anti-patterns.md) | Version conflicts under load |
| Using /products instead of /product-projections | [references/anti-patterns.md](references/anti-patterns.md) | 2x response payload size |
| Polling instead of Subscriptions | [references/anti-patterns.md](references/anti-patterns.md) | Wasted API quota, delayed detection |
| Ignoring ConcurrentModification errors | [references/anti-patterns.md](references/anti-patterns.md) | Silent data loss, corrupt state |
| Expanding all references "just in case" | [references/anti-patterns.md](references/anti-patterns.md) | Bloated responses, slow queries |
| Creating empty carts for every visitor | [references/anti-patterns.md](references/anti-patterns.md) | Millions of unused cart resources |
| Not monitoring Subscription health | [references/anti-patterns.md](references/anti-patterns.md) | Silent notification failures for 7 days |

## Complements the commercetools MCP

This skill provides **judgment and patterns** — when to use which approach, what
goes wrong in production, and how to structure code correctly. For API access and
schema reference, use the commercetools MCP servers:

| Need | Use |
|------|-----|
| Search documentation, fetch GraphQL/OAS schemas | [Developer MCP](https://docs.commercetools.com/sdk/mcp/developer-mcp) (free, 100 req/15 min) |
| CRUD operations on products, carts, orders, customers | [Commerce MCP](https://docs.commercetools.com/sdk/mcp/commerce-mcp) (95+ tools, requires auth) |
| Best practices, anti-patterns, correct code structure | **This skill** |

**Workflow**: Use this skill to understand the _right pattern_, then use the MCP
to look up exact field names, types, and schemas, then write the code.

## Related Skills

- [commercetools-data](../commercetools-data/SKILL.md) -- Product type design, custom types/objects, category hierarchies, import/export, data migration
- [commercetools-merchant-center](../commercetools-merchant-center/SKILL.md) -- Building custom MC applications and views, UI Kit patterns, deployment
- [commercetools-frontend](../commercetools-frontend/SKILL.md) -- Storefront architecture, SSR/SSG, product pages, cart UI, performance/SEO
