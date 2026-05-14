---
name: kibo-ecommerce
description: Build, debug, and integrate Kibo Commerce eCommerce features — implement checkout/cart/catalog flows, troubleshoot cart and promotion issues, develop B2B portals, write API Extensions (Arc.js), configure Event Subscriptions, or connect to external PIMs/OMS/search. Covers OAuth, `x-vol-tenant`/`x-vol-site`/`x-vol-master-catalog` headers, tenant/site/catalog hierarchy, `@kibocommerce/rest-sdk`, REST vs GraphQL selection. Triggers on Kibo, Kibo Commerce, KiboCommerce, KiboSoftware, x-vol-tenant, x-vol-site, MasterCatalog, Kibo cart/checkout/catalog/storefront/B2B/promotions, API Extensions, Arc.js, Event Subscription, @kibocommerce/rest-sdk. Use whenever working with Kibo's commerce platform — implementing new features, debugging existing code, or integrating external systems.
---

# Kibo Commerce — eCommerce

**Progressive loading — only load what you need:**

- Setting up auth, the SDK, the GraphQL client, or the tenant/site headers? Load [references/api-setup.md](references/api-setup.md)
- Modeling products, variants, attributes, categories, master vs site catalogs? Load [references/catalog.md](references/catalog.md)
- Building cart, checkout, payment, or promotions flows? Load [references/cart-checkout.md](references/cart-checkout.md)
- Implementing B2B features (accounts, quoting, approvals, price lists, punchout)? Load [references/b2b.md](references/b2b.md)
- Building a storefront or using the built-in CMS / page builder? Load [references/cms-storefront.md](references/cms-storefront.md)
- Writing API Extensions (server-side JS in the platform), subscribing to events, or designing a webhook receiver? Load [references/extensions-events.md](references/extensions-events.md)
- Reviewing or debugging existing code? Load [references/anti-patterns.md](references/anti-patterns.md)

**Load the relevant reference file before writing Kibo integration code.** The unified API hides a tenant/site/catalog hierarchy that's easy to get wrong — most "this works in dev but breaks in prod" issues trace back to the wrong `x-vol-site` header or a master-catalog vs site-catalog confusion. The skill is the judgment layer; for live schema and field-level reference, defer to the apidocs portal and the TypeScript SDK source.

## CRITICAL Priority

| Pattern | File | Impact |
|---------|------|--------|
| The tenant / master-catalog / catalog / site hierarchy and the `x-vol-*` headers | [references/api-setup.md](references/api-setup.md) | Wrong header = wrong scope = silently empty results in dev, wrong data in prod. The #1 footgun. |
| OAuth 2.0 with App Key + Shared Secret; tokens expire and must be refreshed | [references/api-setup.md](references/api-setup.md) | Token expiry causes intermittent 401s that look like flaky network |
| REST is admin/back-office; GraphQL is storefront — pick deliberately | [references/api-setup.md](references/api-setup.md) | Storefront pages reading from REST will hit rate limits; admin tools using GraphQL miss back-office mutations |
| Built-in CMS is for marketing pages, not product master data | [references/cms-storefront.md](references/cms-storefront.md) | Treating Kibo CMS as a PIM produces unmaintainable content that should have lived in product attributes |
| Event Subscription payload is thin — hydrate via API callback, do not trust the payload | [references/extensions-events.md](references/extensions-events.md) | Receivers built around a "fat" payload assumption miss data and ship buggy projections |

## HIGH Priority

| Pattern | File | Impact |
|---------|------|--------|
| Master catalog vs site catalog: where price/availability overrides live | [references/catalog.md](references/catalog.md) | Overriding at the wrong level breaks multi-site consistency |
| Cart lifecycle: anonymous → authenticated merge semantics | [references/cart-checkout.md](references/cart-checkout.md) | Naive merge loses promotions, custom attributes, or duplicates items |
| Checkout is a multi-stage state machine, not a single mutation | [references/cart-checkout.md](references/cart-checkout.md) | Skipping a stage produces "valid-looking" orders that fail downstream |
| B2B account / customer / contact hierarchy is distinct from B2C | [references/b2b.md](references/b2b.md) | Modeling B2B as "customers with extra fields" misses approval workflows and price lists |
| API Extensions run in-platform; external webhooks run out-of-platform — pick by latency | [references/extensions-events.md](references/extensions-events.md) | External webhooks for sub-100ms checkout customization add latency you can't recover |
| Storefront catalog reads should use GraphQL, not REST | [references/cms-storefront.md](references/cms-storefront.md) | REST is unoptimized for storefront request rates |
| Pagination, IDs, currency / money representation | [references/api-setup.md](references/api-setup.md) | Each is a common silent-failure source |

## MEDIUM Priority

| Pattern | File | Impact |
|---------|------|--------|
| Promotion stacking rules and exclusivity | [references/cart-checkout.md](references/cart-checkout.md) | Wrong assumption about stacking produces over- or under-discounted carts |
| Category hierarchy: slug-based vs ID-based URLs | [references/catalog.md](references/catalog.md) | URL strategy affects SEO and ISR cache shape |
| Variant attribute vs product attribute placement | [references/catalog.md](references/catalog.md) | Attributes on the wrong entity break faceted search |
| Punchout / cXML — scope verification before scoping | [references/b2b.md](references/b2b.md) | First-party support is unconfirmed in the indexed concept guides — verify with Kibo before quoting scope; b2b.md captures what is and isn't documented |

## Common Anti-Patterns (Quick Reference)

| Anti-Pattern | File | Consequence |
|--------------|------|-------------|
| Hardcoding tenant ID / hostname in source | [references/anti-patterns.md](references/anti-patterns.md) | Breaks every multi-environment promotion |
| Missing `x-vol-site` / `x-vol-catalog` / `x-vol-master-catalog` for the call's scope | [references/anti-patterns.md](references/anti-patterns.md) | Silently returns the wrong scope's data — site calls without `x-vol-site` return master-catalog data; admin calls without `x-vol-master-catalog` return tenant-default scope |
| Trusting Event Subscription payloads without hydrating | [references/anti-patterns.md](references/anti-patterns.md) | Receiver builds stale projections |
| Re-stringifying parsed JSON before HMAC verification (if HMAC used) | [references/anti-patterns.md](references/anti-patterns.md) | Signature mismatch |
| Modeling B2B customers as B2C customers + custom fields | [references/anti-patterns.md](references/anti-patterns.md) | Loses approval workflow and price-list semantics |
| Serving storefront catalog reads from REST | [references/anti-patterns.md](references/anti-patterns.md) | Hits rate limits under traffic |
| Treating Kibo CMS as the product master | [references/anti-patterns.md](references/anti-patterns.md) | Should live in product attributes or an external PIM |
| Building API Extensions for things webhooks should handle | [references/anti-patterns.md](references/anti-patterns.md) | In-platform code is harder to test/version |

## Live Documentation as Source of Truth

This skill encodes the **patterns and judgment** for working with Kibo eCommerce. For live schema and field-level details, defer to:

| Need | Source |
|------|--------|
| Interactive API reference (REST) | [apidocs.kibocommerce.com](https://apidocs.kibocommerce.com/) |
| Developer guides, concept docs, GraphQL pages | [docs.kibocommerce.com](https://docs.kibocommerce.com/) |
| LLM-friendly doc index | [docs.kibocommerce.com/llms.txt](https://docs.kibocommerce.com/llms.txt) |
| Official SDKs and storefront starters | [github.com/KiboSoftware](https://github.com/KiboSoftware) |
| TypeScript REST SDK source | [github.com/KiboSoftware/typescript-rest-sdk](https://github.com/KiboSoftware/typescript-rest-sdk) |
| Hosted MCP server for runtime API access | [docs.kibocommerce.com/pages/kibo-mcp-server](https://docs.kibocommerce.com/pages/kibo-mcp-server) |

**Workflow:** Use this skill to understand the right pattern → use the apidocs portal or the TypeScript SDK to look up exact field names → use Kibo's hosted MCP server to actually run CRUD operations against a tenant.

## Related Skills

- [kibo-oms](../kibo-oms/SKILL.md) — when fulfillment, inventory, order routing, or returns are in scope; Kibo OMS often layers on top of (or replaces) the eCommerce order workflow
- [kibo-subscriptions](../kibo-subscriptions/SKILL.md) — when subscription commerce features are in scope
- [commercetools-api](../commercetools-api/SKILL.md), [commercetools-data](../commercetools-data/SKILL.md) — for clients evaluating Kibo against commercetools, or running both
- [marketplacer](../marketplacer/SKILL.md) — when Kibo eCommerce is the commerce platform fronting a Marketplacer marketplace
- [akeneo](../akeneo/SKILL.md) — when Akeneo is the PIM feeding Kibo's product catalog
- [algolia](../algolia/SKILL.md) — when Algolia is the search engine indexing Kibo products
