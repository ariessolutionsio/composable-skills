# Composable Stack Integration

Marketplacer slots in as the **marketplace platform** — one box in a larger composable architecture. The other boxes (commerce platform, search engine, PIM, OMS, ERP, storefront) vary by client. This file covers the integration *shape* by category, vendor-neutral. Pick a specific vendor in each lane (commercetools, Kibo, Scayle, Algolia, Constructor, Akeneo, etc.) and the same patterns apply with that vendor's API shape.

## Table of Contents
- [Reference Topology](#reference-topology)
- [Who Owns What (Source-of-Truth Map)](#who-owns-what-source-of-truth-map)
- [Commerce Platform Integration](#commerce-platform-integration)
- [PIM Integration](#pim-integration)
- [Search Engine Integration](#search-engine-integration)
- [OMS Integration](#oms-integration)
- [ERP Integration](#erp-integration)
- [Storefront Integration](#storefront-integration)
- [Foreign-Key Strategy](#foreign-key-strategy)
- [Order of Operations at Runtime](#order-of-operations-at-runtime)
- [Multi-Instance Considerations](#multi-instance-considerations)
- [Checklist](#checklist)

## Reference Topology

```
                ┌──────────────┐
                │   Customer   │
                └──────┬───────┘
                       │
                ┌──────▼───────────┐         ┌──────────────────┐
                │   Storefront     │◀────────│  Search Engine   │
                │  (Next.js etc.)  │  reads  │  (Algolia /      │
                └──────┬───────────┘         │   Constructor)   │
                       │                     └──────────▲───────┘
                       │ checkout                       │ indexes
                       ▼                                │
                ┌────────────────┐                      │
                │  Commerce      │                      │
                │  Platform      │                      │
                │ (ct/Kibo/etc.) │                      │
                └──┬─────────┬───┘                      │
                   │         │                          │
            order  │         │ refunds, status          │
                   ▼         ▲                          │
              ┌────────────────────┐    webhooks        │
              │   Marketplacer     │────────────────────┘
              └─┬────────────▲─────┘   (Advert/Variant events)
                │            │
   commission   │            │ catalog write
   payout       │            │
                ▼            │
        ┌──────────────┐  ┌──┴────────┐    PIM master
        │     ERP      │  │   PIM     │◀───────────────
        └──────────────┘  └───────────┘  (Akeneo / contentful / Salsify / etc.)

                ▲
                │ fulfillment status
        ┌───────┴──────┐
        │     OMS      │
        └──────────────┘
```

Read this as: Marketplacer is in the center as the marketplace platform; surrounding systems each own a specific slice; webhooks and APIs glue them together.

## Who Owns What (Source-of-Truth Map)

| Concept | Source of truth | Marketplacer's role |
|---------|-----------------|---------------------|
| Customer identity, authentication | Commerce platform | None |
| Cart | Commerce platform | None |
| Customer-facing order (the whole purchase) | Commerce platform / OMS | Mirrored as Order; per-seller slices owned here |
| Product master attributes, images, taxonomy | PIM | Mirrored as Golden Product |
| Seller-specific product data (price, stock) | Marketplacer (seller-owned) | Source of truth |
| Listing visibility / publish state | Marketplacer | Source of truth |
| Search/discovery index | Search engine | Subscribes to Marketplacer webhooks |
| Per-seller fulfillment status | Marketplacer (Invoice + Shipment) | Source of truth; flows to OMS |
| Customer money movement (capture/refund) | Operator's PSP | Out of scope |
| Marketplace commission / payouts | Marketplacer (MPay) | Source of truth |
| Tax calculation | Tax engine (Avalara / TaxJar / etc.) | Stores the result, doesn't compute |
| Promotion rule logic | Commerce platform | Records resulting Adjustment, not the rule |
| AR / AP ledger | ERP | Receives RemittanceAdvice for AP |

Disagreement on any row above causes integration churn. Lock the map down in the architecture-design phase.

## Commerce Platform Integration

The commerce platform owns the customer experience: cart, checkout orchestration, customer accounts, payment. Marketplacer sits behind it as the marketplace platform.

**Data flow:**

| Direction | What | When |
|-----------|------|------|
| Commerce → Marketplacer | `orderCreate` | After PSP authorize, before PSP capture (see `payments-payouts.md`) |
| Commerce → Marketplacer | `refundRequestCreate` and progression | When the customer-facing system initiates a refund/cancellation |
| Marketplacer → Commerce | Invoice / Shipment / RefundRequest webhooks | On every per-seller state change |
| Marketplacer → Commerce | Catalog read (rare) | One-off admin queries only — never serve catalog reads from Marketplacer at storefront request rate |

**Critical pattern: order of operations at checkout** (see [Order of Operations at Runtime](#order-of-operations-at-runtime)).

**Why not read catalog through Marketplacer for storefront pages:** the GraphQL Operator API is not optimized for high-rate read traffic. Storefront listing/PDP reads should come from the search engine (or an edge-cached read replica), with Marketplacer as the write-side source of truth. See [Search Engine Integration](#search-engine-integration).

**Commerce-platform-specific notes:**
- If the commerce platform has its own product/catalog concept (most do), the relationship to Marketplacer Adverts must be explicit. Common pattern: commerce platform products represent the Golden Product (catalog item); Marketplacer Adverts represent per-seller listings; the storefront resolves "this product, from which seller" at the variant level.
- The commerce platform's cart line items typically carry the **Marketplacer Variant ID** plus the seller reference, so `orderCreate` has the data it needs.
- Promotions/discounts computed by the commerce platform's promotion engine pass through to Marketplacer as `Adjustment[]` on the relevant line items at `orderCreate` time.

## PIM Integration

The PIM is the source of truth for product master data: attributes, images, taxonomy, brand, GTIN/barcode. Marketplacer's Golden Product layer is the mirror.

**Recommended pattern (PIM → Golden Products):**

1. PIM emits product-changed events (its own webhook or polling).
2. Operator-side middleware transforms PIM records into Marketplacer Golden Product / Golden Variant input shape.
3. Middleware calls `goldenProductUpsert` (or the equivalent — see `catalog-management.md`) for each PIM record.
4. Sellers' linked Adverts backfill on Marketplacer's batch cycle (~1 hour), or immediately via `variantUpsertFromBarcode` when a seller adds a known barcode.

**Foreign-key strategy:** PIM ID → `goldenProduct.externalIds[{ key: "pim_id", value: ... }]`. Always queryable; never lost.

**Attribute mapping:**
- PIM attributes → Marketplacer OptionTypes (per the Taxon's Prototype).
- PIM attribute level (per-variant vs per-product) must match the Prototype's variant-vs-advert level.
- Mismatches are the most common cause of PIM sync failures. Validate during the transform step, not at Marketplacer's GraphQL layer.

**What stays out of the PIM:** seller-specific data — price, inventory, seller SKU. The PIM owns the catalog, not the commerce reality.

**Alternative when there is no PIM:** the operator-portal seller spreadsheet upload becomes the catalog source of truth. This is a lighter integration but loses centralized attribute governance; suitable for smaller marketplaces.

## Search Engine Integration

The storefront's listing pages, PDP search-related sections, faceted navigation, and autocomplete all read from a search engine — not from Marketplacer or the commerce platform. The search engine is the only system that can serve catalog reads at storefront request rates.

**Recommended pattern:**

1. Marketplacer emits Advert / Variant / Seller / GoldenProduct webhooks (see `webhooks-events.md`).
2. The webhook receiver pushes updated documents into the search index.
3. The document schema combines: Marketplacer Advert/Variant fields, Golden Product enrichment, and any commerce-platform-side metadata (promotions, pricing rules) that needs to be searchable.
4. The storefront reads from the search index for all browse/search interactions.

**Document granularity choice:**
- **Per-Variant documents** — fine-grained, supports color/size faceting natively. Larger index.
- **Per-Advert documents with variant array** — coarser; PDP shows variants from a single Advert document. Smaller index, simpler.
- **Per-GoldenProduct documents with linked Adverts array** — supports "shown across N sellers" buy-box UX. Larger document, smaller doc count.

The right granularity depends on the storefront's IA. Decide early; changing later is a full reindex.

**Multi-seller faceting:** include `seller.id`, `seller.businessName`, and `seller.externalIds` in the search document so the storefront can filter by seller, show seller name on results, and link out to seller pages.

**Inventory in the index:**
- For a marketplace with infrequent stock changes, include `countOnHand` and filter out zero-stock results.
- For high-velocity inventory (e.g., second-hand, limited stock), `countOnHand` in the index will be stale. Filter inventory at the read-time layer (commerce platform's inventory service) instead of trusting the index.

## OMS Integration

The OMS is the operator's order-management system. In a marketplace context, **the OMS owns the customer order; Marketplacer owns per-seller fulfillment**.

**Data flow:**

| Direction | What | When |
|-----------|------|------|
| Commerce → OMS | Customer order created | After successful checkout (commerce platform's existing flow) |
| Commerce → Marketplacer | `orderCreate` | Same checkout flow, parallel to OMS create |
| Marketplacer → OMS | Invoice / Shipment / RefundRequest webhooks | On every per-seller state change |
| OMS → Customer | Order status, tracking, etc. | Aggregated from Marketplacer per-seller events |

**Mapping pattern:**
- OMS Customer Order → Marketplacer Order (1:1) via `paymentReferences[].paymentReference` (the PSP tx IDs) and `Order.externalIds`.
- OMS Fulfillment record → Marketplacer Invoice (1:N — one OMS fulfillment per Invoice) via `Invoice.externalIds`.

**Aggregation in the OMS:**
- Customer sees one order; OMS sees N fulfillments (one per Invoice).
- Order-level status is derived: "Partially Shipped" if some Invoices have Shipments and others don't; "Fully Shipped" when all do; etc.
- Refunds at order level are aggregated from RefundRequests across Invoices.

**Anti-pattern:** building the OMS as if Marketplacer's Order entity were the order of record. Marketplacer's Order is a record of the marketplace transaction; the customer-facing order belongs to the OMS / commerce platform.

## ERP Integration

The ERP handles the operator's books: AR (revenue from customers via PSP), AP (payouts to sellers via Marketplacer/MPay), commission revenue, refund reversals.

**Data flow:**

| Source | ERP impact |
|--------|------------|
| PSP capture events | AR posted; revenue recognized per the operator's accounting policy |
| Marketplacer Invoice creation | Liability accrued: amount owed to seller (sale price − commission) |
| Marketplacer RemittanceAdvice webhook | AP entry created: bill payable to seller for that payout |
| Marketplacer commission (calculated per Invoice) | Commission revenue line |
| RefundRequest reaching `Refunded` | Commission revenue reversed; seller liability reversed |
| PSP refund | AR reversed for the customer-side refund |

**Recommended pattern:**
- Treat **RemittanceAdvice as the primary AP feed** — one bill per remittance, with the seller as the vendor.
- Reconcile RemittanceAdvice totals against the actual MPay/Airwallex bank movement (the deposit-and-reconcile loop covered in `payments-payouts.md`).
- Period-end reconciliation matches PSP totals (AR) against Marketplacer Invoice totals + operator-retained fees + commission revenue.

**ERP-side data model:** keep Marketplacer Invoice IDs in the ERP's AP records via the same `externalIds` pattern so audit and dispute resolution can trace back.

## Storefront Integration

The storefront is the customer-facing UI. Most reads come from the search engine (above); a few patterns are marketplace-specific.

**Multi-seller PDP:** when a Golden Product is offered by multiple sellers, the PDP must choose between:
- **Buy-box UX** — one default seller is featured, others shown as "other sellers" with a selector. Mimics marketplace standards.
- **Seller-page UX** — the listing page is treated as one seller's listing; other sellers' listings appear as separate results. Simpler UX, less marketplace-y.

The choice affects the search-index granularity (above) and the cart line-item model. Decide early.

**Multi-seller cart UX:** the cart spans sellers and the customer should know this — shipping costs per seller, possibly different ETAs, separate fulfillment. UI typically groups line items by seller.

**Per-seller pages:** sellers usually have their own page on the storefront. The page reads seller details (Marketplacer Seller via the API or cached) and lists Adverts (search index filtered by seller).

**HTML sanitization:** the storefront is the last line of defense against XSS in Advert descriptions. See `catalog-management.md`.

**Image transformations:** images are served via Imgix (signed URLs). Use Marketplacer's exposed URL transformations rather than constructing Imgix URLs by hand (manual edits return `sig_invalid`).

## Foreign-Key Strategy

The integration only stays sane if every cross-system entity reference is **bidirectional, durable, and queryable**.

| Marketplacer entity | Foreign keys it should carry (`externalIds`) |
|---------------------|---------------------------------------------|
| Seller | Commerce-platform supplier ID, ERP vendor ID |
| Advert | PIM product ID (if seller-Advert is linked to a PIM record), commerce-platform product ID (if applicable) |
| Variant | PIM variant ID, search-index document ID |
| GoldenProduct | PIM product ID (primary key on this side) |
| GoldenVariant | PIM variant ID |
| Order | Commerce-platform order ID, OMS customer-order ID |
| Invoice | OMS fulfillment ID, ERP AP record ID (once paid) |
| RefundRequest | Commerce-platform refund ID, PSP refund ID |

**Rules:**
- Use `externalIds` (queryable), not `metadata`.
- Key naming: `<system>_<entity>_id` — e.g., `commercetools_product_id`, `akeneo_product_id`, `oms_fulfillment_id`. Avoid generic `external_id`.
- One `externalIds` write per system per entity. If a system changes IDs (e.g., during migration), update — don't append.
- The **inverse mapping** (Marketplacer ID stored on the other side) should also exist. The Marketplacer ID + the foreign-system ID together form the canonical link, queryable from either side.

## Order of Operations at Runtime

The single most important sequence to get right is **checkout**:

```
1. Customer clicks "Place Order" on the storefront.
2. Commerce platform validates the cart (price, stock, address, etc.).
3. Commerce platform authorizes the PSP (NOT capture).
4. Commerce platform calls Marketplacer orderCreate(paymentReferences: [{paymentReference: <PSP auth ID>, amount: <gross cents>}, …]).
   ├─ Success → continue
   └─ Failure (e.g., stock depleted, advert pulled): cancel the PSP authorize → fail checkout
5. Commerce platform captures the PSP authorization.
6. Commerce platform creates its own customer-order record (or has already done so).
7. OMS receives the customer-order create event from the commerce platform.
8. Marketplacer asynchronously emits Invoice.create webhooks.
9. OMS receives Invoice.create webhooks and links Invoices to its customer order.
```

**Why authorize-then-orderCreate-then-capture:** if Marketplacer rejects the order (stock issue, validation, etc.) **after** capture, you have to refund — which costs gateway fees, leaves audit-trail noise, and confuses customers. Authorize-first lets you cancel the auth cleanly when Marketplacer rejects.

**Don't try to make this atomic.** Distributed transactions across the PSP, Marketplacer, and the OMS are not achievable in practice. Idempotency is achievable: use deterministic order references (`paymentReferences[].paymentReference`, `externalIds`) so retries don't double-create.

## Multi-Instance Considerations

When the operator runs multiple Marketplacer instances (multi-region), the foreign-key strategy must include the instance.

**Recommended pattern:** prefix `externalIds` keys with the instance, or carry the instance as a separate column on the other side.

```typescript
// Marketplacer side, AU instance:
externalIds: [
  { key: 'au_commercetools_order_id', value: 'ord-au-123' },
  // ...
]

// Commerce-platform side (single global commercetools project):
custom: {
  fields: {
    marketplacer_instance: 'au',
    marketplacer_order_id: 'T3JkZXItMTIz...',
  }
}
```

Pick one convention per implementation and document it. The choice is mostly arbitrary; what matters is consistency.

**Other multi-instance touches:**
- Sellers in different regions are distinct records — `seller@AU` and `seller@UK` are separate.
- PIM Golden Product sync runs per-instance.
- The OMS / commerce platform / ERP carry the instance dimension on every cross-system record.

## Checklist

Before the integration is "done":

- [ ] Source-of-truth map (which system owns which data) is documented and agreed.
- [ ] Foreign-key strategy uses `externalIds` and is bidirectional.
- [ ] Checkout sequence is authorize → orderCreate → capture; not capture → orderCreate.
- [ ] Storefront reads catalog from the search index, not Marketplacer GraphQL.
- [ ] PIM → Golden Products → seller Advert backfill is automated and monitored.
- [ ] Webhook receiver subscribes to Invoice / Shipment / RefundRequest (not Order).
- [ ] OMS aggregates Invoices into customer-facing order status.
- [ ] ERP receives RemittanceAdvice as AP feed.
- [ ] Multi-seller cart UX surfaces per-seller shipping and ETA.
- [ ] HTML sanitization is in place on the storefront.
- [ ] Multi-instance (if applicable): instance is part of every cross-system foreign key.
