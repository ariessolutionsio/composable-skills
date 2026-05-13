---
name: marketplacer
description: Operator-side patterns for integrating Marketplacer into a composable commerce stack — GraphQL Operator API, per-seller order splits via Invoices, caller-shaped webhooks with HMAC, MPay deposit-and-reconcile payouts, Golden Product PIM sync, wholesale orders, additional charges, and Catalog Rules. Use when implementing or maintaining a Marketplacer marketplace behind any commerce platform (commercetools, Kibo, Scayle, etc.), any search engine, any PIM, OMS, or ERP. Triggers on Marketplacer, marketplace, multi-vendor, multi-seller, Advert, Seller, Invoice, Golden Product, MPay, Airwallex, Hyperwallet, Xero, RefundRequest, RemittanceAdvice, Remittance, Taxon, Prototype, Catalog Rule, marketplace commission, marketplace fees, marketplace operator, marketplace webhooks, paymentReferences. Consult this skill before writing code that talks to a Marketplacer instance, defines a Marketplacer webhook, or maps Marketplacer data into another system.
---

# Marketplacer Operator Integration

**Progressive loading — only load what you need:**

- Setting up auth, the GraphQL client, pagination, or IDs? Load [references/api-setup.md](references/api-setup.md)
- Modeling Sellers, Adverts, Variants, Orders, Invoices, or Golden Products? Load [references/data-model.md](references/data-model.md)
- Syncing catalog from a PIM, creating/updating listings, taxons, images? Load [references/catalog-management.md](references/catalog-management.md)
- Creating orders, splitting across sellers, shipments, refunds? Load [references/orders-fulfillment.md](references/orders-fulfillment.md)
- Implementing payments, payouts, commission, or MPay reconciliation? Load [references/payments-payouts.md](references/payments-payouts.md)
- Configuring webhooks, designing payload queries, handling retries/HMAC? Load [references/webhooks-events.md](references/webhooks-events.md)
- Integrating Marketplacer with the commerce platform, search, PIM, OMS, ERP, or storefront? Load [references/composable-integration.md](references/composable-integration.md)
- Reviewing or debugging existing code? Load [references/anti-patterns.md](references/anti-patterns.md)

**Load the relevant reference file before writing Marketplacer integration code.** The Operator API has several non-obvious modeling decisions — per-seller Adverts, Order → Invoice splits, no `Order` webhook, deposit-and-reconcile payouts, `paymentReferences` as an array — that quietly break integrations written from intuition. Live schema and changelog stay authoritative for field-level details; this skill is the judgment layer that tells you which mutation to reach for and why.

## CRITICAL Priority

| Pattern | File | Impact |
|---------|------|--------|
| Use the GraphQL Operator API — never the Legacy REST API | [references/api-setup.md](references/api-setup.md) | Legacy REST is deprecated; new builds on it accrue rework, missing features, and an unsupported migration path |
| Adverts are per-seller; Golden Products are marketplace-level | [references/data-model.md](references/data-model.md) | Treating Adverts as canonical product records duplicates data per seller and breaks PIM sync |
| Orders split into per-seller Invoices — there is no `Order` webhook | [references/orders-fulfillment.md](references/orders-fulfillment.md) | Subscribing at the Order level produces zero events; status updates ship as Invoice events |
| `paymentReferences` is a plural array of `{paymentReference, amount}` — never a string | [references/payments-payouts.md](references/payments-payouts.md) | Wrong shape causes order creation to fail and rules out split tender (gift card + card) entirely |
| MPay is deposit-and-reconcile, not Stripe Connect | [references/payments-payouts.md](references/payments-payouts.md) | Designing for split payment at capture leads to a fundamentally wrong checkout — Marketplacer never touches the shopper's funds |
| Webhook 4xx auto-disables the subscription | [references/webhooks-events.md](references/webhooks-events.md) | One bad deploy can silently kill production event flow until manually re-enabled |
| HMAC-verify webhook bodies before trusting them | [references/webhooks-events.md](references/webhooks-events.md) | The endpoint is public; unsigned acceptance allows order/inventory tampering |
| One Marketplacer instance = one hostname = one currency | [references/api-setup.md](references/api-setup.md) | Multi-region storefronts need multiple instances; building "currency as a field" assumes a model that doesn't exist |

## HIGH Priority

| Pattern | File | Impact |
|---------|------|--------|
| API keys are scoped and one-time-reveal — missing scopes surface as `extensions.code: "MISSING_SCOPE"` | [references/api-setup.md](references/api-setup.md) | Wrong scope = silent permission failures masquerading as schema errors; lost keys must be regenerated, breaking dependents |
| Pagination is forward-only (`first` + `after`); cap page size at 500 | [references/api-setup.md](references/api-setup.md) | UIs designed around backward paging or large pages will silently break |
| IDs are opaque base64; use `legacyId` only for display | [references/api-setup.md](references/api-setup.md) | Decoded IDs can change shape; code that depends on the format breaks on schema evolution |
| Honour the `Retry-After` header on 429/503 (default 60 s when absent) | [references/api-setup.md](references/api-setup.md) | Generic exponential backoff misses the documented signal; thundering-herd retries can sustain the rate limit |
| `ExternalIds`, `CustomFields`, and `Metadata` are three different extension surfaces | [references/data-model.md](references/data-model.md) | Picking the wrong one means you either can't query later (`metadata`) or can't display it cleanly (`externalIds`) |
| Refund mutations: positive amounts on `refundRequestRefund` / `refundRequestApprove`, negative only on `invoiceAmendmentUpdate` | [references/payments-payouts.md](references/payments-payouts.md) | Wrong sign drifts the deposit reconciliation in the opposite direction |
| Remittance (per-Invoice) and RemittanceAdvice (per-Seller payout group) are distinct entities | [references/payments-payouts.md](references/payments-payouts.md) | ERP AP feeds that conflate them post duplicate or missing bills |
| Golden Product backfill via barcode is batch (~1 hr) | [references/catalog-management.md](references/catalog-management.md) | UI flows that expect immediate seller-Advert backfill will appear broken |
| Subscribe to Invoice + Shipment for fulfillment status | [references/orders-fulfillment.md](references/orders-fulfillment.md) | Polling burns rate-limit budget; the event matrix already covers every state transition |
| Webhook payloads are caller-shaped GraphQL queries | [references/webhooks-events.md](references/webhooks-events.md) | Default payloads are minimal — without a registered query the receiver gets just `{ id }` |
| Deduplication respects payload equality, not just event type | [references/webhooks-events.md](references/webhooks-events.md) | Including `updatedAt` in the query disables dedup; omitting it can hide real changes |
| Commission flips on refund | [references/payments-payouts.md](references/payments-payouts.md) | Reporting that doesn't model the reversal will over-state operator revenue |
| Map Marketplacer entities into the wider stack via `ExternalIds` | [references/composable-integration.md](references/composable-integration.md) | Without a consistent foreign-key strategy, sync drift becomes unrecoverable |

## MEDIUM Priority

| Pattern | File | Impact |
|---------|------|--------|
| Prototype-driven attributes (advert-level vs variant-level) | [references/catalog-management.md](references/catalog-management.md) | Wrong option-type level causes "missing required attribute" failures on publish |
| Image source URLs must resolve in <5 s | [references/catalog-management.md](references/catalog-management.md) | Slow CDNs silently drop images; surface validation early |
| Catalog Rules can mutate an Advert after the upsert returns | [references/catalog-management.md](references/catalog-management.md) | Code that trusts the submitted Taxon/state drifts from reality — read post-rule state from the webhook |
| Partial shipments are first-class; sum quantities ≤ ordered | [references/orders-fulfillment.md](references/orders-fulfillment.md) | Code that creates one shipment per invoice can't handle split-pack reality |
| RefundRequest has its own state machine separate from Invoice | [references/orders-fulfillment.md](references/orders-fulfillment.md) | Treating refund as an Invoice mutation produces stuck states |
| Additional Charges (return shipping, restocking) flow to the seller, not the operator | [references/payments-payouts.md](references/payments-payouts.md) | Operator-side accounting that captures these as operator revenue is wrong by design |
| Wholesale orders: cart owns price resolution; Marketplacer settles whatever `cost.amount` you submit | [references/orders-fulfillment.md](references/orders-fulfillment.md) | Code expecting Marketplacer to detect "wholesale" and adjust pricing/commission itself will be wrong on most instances |
| Pricing is whole-cent integer in lowest denomination | [references/api-setup.md](references/api-setup.md) | Floats and fractional cents round silently and break ledger reconciliation |
| High-volume mode purges delivered events | [references/webhooks-events.md](references/webhooks-events.md) | Cannot rely on Marketplacer as the replay source past 50k undelivered |
| Use search engine for catalog reads, not Operator API | [references/composable-integration.md](references/composable-integration.md) | GraphQL is for writes and admin reads; storefront listing pages should query the search index |
| Operator order webhook = Invoice; OMS owns the customer order | [references/composable-integration.md](references/composable-integration.md) | Avoids dual-source-of-truth conflicts on order state |

## Common Anti-Patterns (Quick Reference)

| Anti-Pattern | File | Consequence |
|--------------|------|-------------|
| Using the Legacy Seller REST API for new work | [references/anti-patterns.md](references/anti-patterns.md) | Building on deprecated surface; missing features and migration burden |
| Subscribing to an `Order` webhook event | [references/anti-patterns.md](references/anti-patterns.md) | Event never fires — Marketplacer emits Invoice events, not Order |
| Designing Stripe-Connect-style split payments | [references/anti-patterns.md](references/anti-patterns.md) | Architectural rewrite — Marketplacer is deposit-and-reconcile, not split-capture |
| Decoding base64 IDs to extract the integer | [references/anti-patterns.md](references/anti-patterns.md) | Format may change; use `legacyId` if you need the integer |
| Storing foreign-system keys in `metadata` | [references/anti-patterns.md](references/anti-patterns.md) | Cannot query by metadata — use `ExternalIds` for lookup |
| Returning HTTP 4xx from a webhook receiver | [references/anti-patterns.md](references/anti-patterns.md) | Auto-disables the webhook subscription |
| Treating Adverts as marketplace-wide product records | [references/anti-patterns.md](references/anti-patterns.md) | Per-seller duplication; PIM sync target should be Golden Products |
| Trusting webhook payloads without HMAC verification | [references/anti-patterns.md](references/anti-patterns.md) | Public endpoint accepts forged traffic |
| Polling for order status instead of subscribing | [references/anti-patterns.md](references/anti-patterns.md) | Burns rate-limit budget; lags real state |
| Designing UI around backward pagination | [references/anti-patterns.md](references/anti-patterns.md) | API supports forward-only cursors |
| Using fractional cents or floats for money | [references/anti-patterns.md](references/anti-patterns.md) | Silent rounding; reconciliation drift |
| Sanitizing HTML output server-side and assuming Marketplacer did it | [references/anti-patterns.md](references/anti-patterns.md) | Marketplacer does not sanitize — XSS risk on the storefront |

## Live Documentation as Source of Truth

This skill encodes the **patterns and judgment** for working with Marketplacer. It does not duplicate field-level schema documentation, which drifts. For the live schema, the live changelog, and any documented endpoint detail not covered here, defer to:

| Need | Source |
|------|--------|
| Schema introspection (queries, mutations, types) | `https://<instance>/graph-doc/` (GraphDoc / Voyager / Spectaql per instance) |
| Operator API how-tos | [api.marketplacer.com/docs/operator-api/](https://api.marketplacer.com/docs/operator-api/) |
| Webhook event matrix and lifecycle docs | [api.marketplacer.com/docs/webhooks/](https://api.marketplacer.com/docs/webhooks/webhooksoverview/) |
| API changelog (breaking changes, deprecations) | [changelog.marketplacer.com](https://changelog.marketplacer.com/en) |
| Legacy REST (only for the small feature-gap list) | [api.marketplacer.com/docs/seller-api/feature_matrix/](https://api.marketplacer.com/docs/seller-api/feature_matrix/) |

**Workflow:** Use this skill to understand the right pattern → look up exact field names in the live GraphDoc → write the code → verify against the changelog for any drift.

## Related Skills

- [commercetools-api](../commercetools-api/SKILL.md), [commercetools-data](../commercetools-data/SKILL.md) — when the commerce platform behind the marketplace is commercetools, those skills cover the cart/order/PIM-side patterns
- [akeneo](../akeneo/SKILL.md) — when the PIM feeding Golden Products is Akeneo
- [algolia](../algolia/SKILL.md) — when the search engine indexing Adverts is Algolia
