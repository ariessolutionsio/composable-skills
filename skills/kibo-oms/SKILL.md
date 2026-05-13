---
name: kibo-oms
description: Use for Kibo Order Management (OMS) implementation — design order routing strategies (DC-to-store fallback, location-based), implement fulfillment workflows (BOPIS, curbside pickup, ship-from-store), build RMA and returns processing, integrate inventory APIs with WMS (Refresh vs Adjust semantics), set up standalone-OMS behind Shopify / SFCC / custom storefronts, or import orders from external platforms. Triggers on Kibo OMS, Kibo Order Management, Kibo fulfillment, order routing, BOPIS, ship-from-store, fulfiller, fulfillment task, RMA, Kibo returns, Kibo inventory location, Kibo dropship, Kibo carrier, agentic order routing, standalone OMS. Covers routing rules, allocation logic, carrier integration, location capabilities, and the OMS-behind-non-Kibo-storefront pattern.
---

# Kibo Commerce — Order Management

**Progressive loading — only load what you need:**

- Setting up auth, the SDK, the tenant model, or designing for Kibo's unified API surface? Load [references/api-setup.md](references/api-setup.md)
- Pushing orders into Kibo OMS from an external commerce platform (Shopify, SFCC, custom)? Load [references/order-intake.md](references/order-intake.md)
- Implementing fulfillment workflows, BOPIS, ship-from-store, partial shipments? Load [references/fulfillment.md](references/fulfillment.md)
- Designing order routing rules (inventory-based, distance, cost, agentic)? Load [references/order-routing.md](references/order-routing.md)
- Modeling inventory at locations, allocations, safety stock, real-time sync? Load [references/inventory.md](references/inventory.md)
- Building return / RMA workflows and refund mechanics? Load [references/returns.md](references/returns.md)
- Integrating carriers, rate shopping, label printing, tracking? Load [references/shipping.md](references/shipping.md)
- Reviewing or debugging existing code? Load [references/anti-patterns.md](references/anti-patterns.md)

**Load the relevant reference file before writing Kibo OMS integration code.** Kibo's OMS is often sold standalone — many implementations have it sitting behind a different storefront (Shopify, SFCC, or a custom build), with orders pushed in via API. The standalone-OMS shape is a different mental model from the bundled "Kibo all the way" pattern, and getting the order-intake direction wrong is the most common architectural mistake.

## CRITICAL Priority

| Pattern | File | Impact |
|---------|------|--------|
| Tenant / site model and `x-vol-*` headers (shared with all Kibo products) | [references/api-setup.md](references/api-setup.md) | Wrong header → wrong scope → wrong inventory or wrong orders |
| OMS-standalone vs OMS-with-Kibo-eCommerce are different architectures | [references/order-intake.md](references/order-intake.md) | Code that assumes orders originate in Kibo eCommerce breaks for Shopify-fronted OMS deals |
| Inventory is location-scoped; aggregate inventory is a derived view | [references/inventory.md](references/inventory.md) | Treating aggregate inventory as authoritative produces oversells |
| Order routing decides which location fulfills — get the rules right at config time | [references/order-routing.md](references/order-routing.md) | Wrong routing produces split orders that should have been single, or vice versa |
| Returns / RMA is its own workflow distinct from cancellation | [references/returns.md](references/returns.md) | Modeling returns as an order edit produces stuck states and miscounted inventory |

## HIGH Priority

| Pattern | File | Impact |
|---------|------|--------|
| Order intake: idempotency keys and external-order-ID strategy | [references/order-intake.md](references/order-intake.md) | Without these, retries from the upstream commerce platform duplicate orders |
| Partial shipments are first-class; sum quantities must equal ordered | [references/fulfillment.md](references/fulfillment.md) | Code that creates one shipment per order can't handle BOPIS + ship-from-warehouse mixed orders |
| BOPIS / curbside have their own state transitions (Awaiting, Ready, Collected) | [references/fulfillment.md](references/fulfillment.md) | Treating BOPIS as "shipped immediately" breaks the pickup notification flow |
| Inventory adjustments (decrement, allocate, reserve, release) are distinct operations | [references/inventory.md](references/inventory.md) | Mixing them up causes phantom stock |
| Carrier integration is per-tenant; rate shopping happens at checkout, not in OMS | [references/shipping.md](references/shipping.md) | Rates re-shopped in OMS can differ from the customer-shown rate |
| Inventory sync to external storefront (Shopify, SFCC) is eventual, not synchronous | [references/order-intake.md](references/order-intake.md) | UI expecting real-time inventory shows stale numbers |

## MEDIUM Priority

| Pattern | File | Impact |
|---------|------|--------|
| Location capabilities (ship-eligible, BOPIS-enabled, dropship) are per-location flags | [references/order-routing.md](references/order-routing.md) | Routing rules that ignore capabilities try to fulfill from disabled locations |
| Refund mechanics: OMS records, PSP captures | [references/returns.md](references/returns.md) | Treating Kibo's "refunded" state as customer-side authoritative is wrong |
| Backorder vs out-of-stock vs preorder are different states | [references/inventory.md](references/inventory.md) | Conflating produces wrong promise dates |
| Calendar / hours / capacity per location | [references/order-routing.md](references/order-routing.md) | Routing to a closed store creates customer-service tickets |

## Common Anti-Patterns (Quick Reference)

| Anti-Pattern | File | Consequence |
|--------------|------|-------------|
| Treating Kibo OMS as Kibo eCommerce | [references/anti-patterns.md](references/anti-patterns.md) | Standalone-OMS deals have orders coming in via API from a different storefront |
| Pushing orders without idempotency keys | [references/anti-patterns.md](references/anti-patterns.md) | Upstream retries duplicate orders |
| Reading aggregate inventory and treating it as authoritative | [references/anti-patterns.md](references/anti-patterns.md) | Oversells at high-velocity SKUs |
| Modeling returns as an order edit | [references/anti-patterns.md](references/anti-patterns.md) | RMA has its own state machine |
| Hardcoding shipment count assumptions per order | [references/anti-patterns.md](references/anti-patterns.md) | BOPIS + ship-from-warehouse split orders don't fit one-shipment-per-order |
| Re-shopping carrier rates in OMS | [references/anti-patterns.md](references/anti-patterns.md) | Rates can differ from the customer-shown rate |
| Treating Kibo OMS "refunded" state as customer-side authoritative | [references/anti-patterns.md](references/anti-patterns.md) | Customer-side refund is the operator's PSP |

## Live Documentation as Source of Truth

| Need | Source |
|------|--------|
| Interactive API reference (REST) | [apidocs.kibocommerce.com](https://apidocs.kibocommerce.com/) |
| Developer guides, fulfillment & OMS concept docs | [docs.kibocommerce.com](https://docs.kibocommerce.com/) |
| Fulfillment workflow engine (Java, reference impl) | [github.com/KiboSoftware/kibo-fulfillment-workflows](https://github.com/KiboSoftware/kibo-fulfillment-workflows) |
| Hosted MCP server for runtime API access | [docs.kibocommerce.com/pages/kibo-mcp-server](https://docs.kibocommerce.com/pages/kibo-mcp-server) |

**Workflow:** Use this skill to understand the right pattern → use apidocs.kibocommerce.com to look up exact field names → use Kibo's hosted MCP server to test the call against a real tenant.

## Related Skills

- [kibo-ecommerce](../kibo-ecommerce/SKILL.md) — when the storefront is also Kibo, the order originates there and lands in OMS via the bundled integration
- [kibo-subscriptions](../kibo-subscriptions/SKILL.md) — subscription orders flow through OMS for fulfillment like regular orders, with cycle-specific metadata
- [commercetools-api](../commercetools-api/SKILL.md) — for clients running Kibo OMS behind commercetools as the storefront/checkout
- [marketplacer](../marketplacer/SKILL.md) — when a Marketplacer marketplace uses Kibo OMS for operator-side fulfillment of dropship sellers
