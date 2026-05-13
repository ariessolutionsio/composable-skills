---
name: kibo-subscriptions
description: Patterns for integrating Kibo's Subscription Commerce product — subscription lifecycle, plan configuration, billing cycles, dunning / retry on failed charges, modifications to active subscriptions (skip, swap, change frequency), cancellation and retention flows, and the relationship between a Subscription and the underlying Order. Use when implementing or maintaining subscription commerce on Kibo. Triggers on Kibo subscription, Kibo Subscription Commerce, subscriptionUpdate, subscriptionCreate, subscription cycle, subscription pause, subscription skip, subscription swap, subscription dunning, subscription retry, subscription churn, recurring billing Kibo, evergreen subscription, fixed-term subscription, subscribe and save. Consult this skill before writing code that creates or modifies subscriptions, handles dunning, or projects subscription state into reporting/ERP systems.
---

# Kibo Commerce — Subscriptions

**Progressive loading — only load what you need:**

- Setting up auth, the SDK, the tenant model (shared with all Kibo products)? Load [references/api-setup.md](references/api-setup.md)
- Modeling Subscriptions, plans, the entity lifecycle, the relationship to Orders? Load [references/subscription-model.md](references/subscription-model.md)
- Configuring plans, frequencies, trials, fixed-term vs evergreen? Load [references/plans.md](references/plans.md)
- Implementing billing cycles, dunning, retry, notifications? Load [references/billing-dunning.md](references/billing-dunning.md)
- Handling modifications (skip, swap, change frequency, change address)? Load [references/modifications.md](references/modifications.md)
- Designing cancellation, pause, and retention flows? Load [references/retention.md](references/retention.md)
- Reviewing or debugging existing code? Load [references/anti-patterns.md](references/anti-patterns.md)

**Load the relevant reference file before writing Kibo Subscriptions integration code.** Subscriptions look like "orders that repeat" until you have to handle a paused subscription with a swapped SKU and a deferred charge — at which point the differences matter. The Subscription entity has its own lifecycle, its own state transitions, and its own relationship to Orders (each cycle typically creates a new Order rather than amending one).

## CRITICAL Priority

| Pattern | File | Impact |
|---------|------|--------|
| Tenant / site model and `x-vol-*` headers (shared with all Kibo products) | [references/api-setup.md](references/api-setup.md) | Wrong header → wrong scope |
| A Subscription is not an Order — each cycle creates a new Order | [references/subscription-model.md](references/subscription-model.md) | Code that mutates the original Order across cycles breaks reporting and refunds |
| Subscription lifecycle (Active, Paused, Cancelled, Failed) is distinct from Order lifecycle | [references/subscription-model.md](references/subscription-model.md) | Treating "subscription failed" the same as "order failed" produces stuck states and wrong dunning |
| Dunning is a configurable retry schedule, not a retry-on-failure loop | [references/billing-dunning.md](references/billing-dunning.md) | Ad-hoc retry loops bypass dunning rules and over-charge or under-collect |

## HIGH Priority

| Pattern | File | Impact |
|---------|------|--------|
| Stored payment methods + off-session SCA / 3DS for recurring charges | [references/billing-dunning.md](references/billing-dunning.md) | Off-session charges that don't handle SCA fail silently in EU markets |
| Modifications: skip vs swap vs change-frequency are different mutations | [references/modifications.md](references/modifications.md) | Conflating them produces wrong proration |
| Pause is a retention tool, not a cancel — has different reactivation semantics | [references/retention.md](references/retention.md) | Cancelling instead of pausing loses customer LTV signal |
| Cancellation: immediate vs end-of-period are policy decisions, not enums | [references/retention.md](references/retention.md) | Wrong policy implementation surprises customers and triggers chargebacks |
| Plan attribute changes vs subscription attribute changes apply at different scopes | [references/plans.md](references/plans.md) | Editing the plan affects all subscribers; editing the subscription affects one |

## MEDIUM Priority

| Pattern | File | Impact |
|---------|------|--------|
| Trial periods affect first charge timing | [references/billing-dunning.md](references/billing-dunning.md) | Off-by-one trial computation creates wrong charge dates |
| Frequency expressed as interval + unit (weekly, monthly, every-N) | [references/plans.md](references/plans.md) | Custom cadences need the interval form, not predefined enums |
| Bundle subscriptions (multiple SKUs in one cycle) have their own line semantics | [references/subscription-model.md](references/subscription-model.md) | Treating a bundle as a single SKU loses per-line fulfillment status |
| Address change on active subscription: applies next cycle, not the current one | [references/modifications.md](references/modifications.md) | Mid-cycle address changes are ambiguous; document the policy |

## Common Anti-Patterns (Quick Reference)

| Anti-Pattern | File | Consequence |
|--------------|------|-------------|
| Building dunning as a custom retry loop | [references/anti-patterns.md](references/anti-patterns.md) | Bypasses platform-configured retry rules; produces wrong customer notifications |
| Treating each cycle's Order as an amendment to the prior Order | [references/anti-patterns.md](references/anti-patterns.md) | Each cycle is its own Order with its own state |
| Hardcoded next-charge-date computation | [references/anti-patterns.md](references/anti-patterns.md) | Leap years, paused cycles, swapped plans break the math |
| Off-session charges without SCA / 3DS handling | [references/anti-patterns.md](references/anti-patterns.md) | Silent failures in EU markets |
| Cancellation = immediate by default | [references/anti-patterns.md](references/anti-patterns.md) | Customer expects access through end of period; chargebacks follow |
| Pause modelled as a temporary cancel | [references/anti-patterns.md](references/anti-patterns.md) | Loses retention signal and forces full re-onboarding |

## Live Documentation as Source of Truth

| Need | Source |
|------|--------|
| Subscription product page | [kibocommerce.com/platform/subscription](https://kibocommerce.com/platform/subscription/) |
| Concept and developer guides | [docs.kibocommerce.com](https://docs.kibocommerce.com/) |
| Interactive API reference | [apidocs.kibocommerce.com](https://apidocs.kibocommerce.com/) |
| Hosted MCP server for runtime API access | [docs.kibocommerce.com/pages/kibo-mcp-server](https://docs.kibocommerce.com/pages/kibo-mcp-server) |

**Workflow:** Use this skill to understand the right pattern → use apidocs.kibocommerce.com to look up exact field names → use Kibo's hosted MCP server to test the call against a real tenant.

## Related Skills

- [kibo-ecommerce](../kibo-ecommerce/SKILL.md) — when products are subscribable and the catalog/cart layer is also Kibo
- [kibo-oms](../kibo-oms/SKILL.md) — subscription cycle orders flow through OMS for fulfillment like regular orders
- [commercetools-api](../commercetools-api/SKILL.md) — for clients running Kibo Subscriptions behind commercetools as the storefront/checkout
