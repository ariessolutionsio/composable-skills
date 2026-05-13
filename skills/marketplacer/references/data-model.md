# Marketplacer Data Model

The Operator API exposes a model with several decisions that quietly trip up integrators coming from single-tenant commerce platforms. The most load-bearing of these: **Adverts are per-seller**, **Orders split into per-seller Invoices**, **`ExternalIds` (not `metadata`) is the only queryable foreign-key surface**, and **Golden Products are the marketplace-level master record**, not Adverts.

## Table of Contents
- [Entity Map](#entity-map)
- [Seller](#seller)
- [Advert (Per-Seller Product Record)](#advert-per-seller-product-record)
- [Variant](#variant)
- [GoldenProduct & GoldenVariant](#goldenproduct--goldenvariant)
- [Order, Invoice, LineItem](#order-invoice-lineitem)
- [Shipment](#shipment)
- [RefundRequest](#refundrequest)
- [Remittance & RemittanceAdvice](#remittance--remittanceadvice)
- [CommissionPackage](#commissionpackage)
- [Prototype, Taxon, OptionType, OptionValue](#prototype-taxon-optiontype-optionvalue)
- [Brand](#brand)
- [Adjustment & Promotion](#adjustment--promotion)
- [MultiStoreMembership](#multistoremembership)
- [PaymentReferences](#paymentreferences)
- [ExternalIds vs CustomFields vs Metadata](#externalids-vs-customfields-vs-metadata)
- [Contextual History](#contextual-history)
- [Modeling Decisions Worth Flagging](#modeling-decisions-worth-flagging)

## Entity Map

```
                              GoldenProduct
                                   │ (1..N) GoldenVariants
                                   │
                                   │  linked via barcode or explicit link
                                   ▼
   Seller ──< Advert ──< Variant ──┴───< (used by) LineItem
     │           │                           │
     │           └─< images, advertOptionValues
     │
     └─< MultiStoreMembership (parent/child)

  Order ──< Invoice (one per Seller × deliveryType)
              │
              ├─< LineItem ──< Adjustment ──> Promotion
              │
              ├─< Shipment ──< shippedItems[lineItem]
              │
              └─< RefundRequest ──< RefundRequestLineItem

  Seller ──< CommissionPackage (assigned)
  Seller ──< RemittanceAdvice (per-payout summary)
```

## Seller

A vendor on the marketplace. Operator-created via `sellerCreate`.

Key fields:

| Field | Type | Notes |
|-------|------|-------|
| `accountType` | enum | `PROSPECTIVE` (cannot list yet) or `RETAILER` (fully operational) |
| `businessName` | string | Display name |
| `legalBusinessName` | string | Legal entity name (used on tax/payout docs) |
| `apiEnabled` | bool | Whether the seller may use the Seller API |
| `advertVettingRequired` | bool | If true, operator must approve every Advert before publish |
| `customRemittanceDelay` | int (days) | Holdback period before payout |
| `commissionPackageId` | ID | Which CommissionPackage applies |
| `marketplaceShippingRulesEnabled` | bool | Use platform shipping rules vs seller-defined |
| `metadata` | map | Free-form key/value — **not queryable** |
| `externalIds` | `[ExternalId]` | Foreign-system keys — **queryable** |
| `address` | object | Default address |
| `user` | object | Primary contact user |

Sellers flip from PROSPECTIVE to RETAILER via `sellerUpdate` once onboarding is complete. The actual KYC and contracting workflow is not surfaced in the public GraphQL API — assume it's handled in the operator portal UI or out-of-band, and the API call is only the final flag flip.

## Advert (Per-Seller Product Record)

The most important modeling decision in Marketplacer: **an Advert belongs to exactly one Seller**. Two sellers offering "the same product" each have their own Advert with distinct IDs.

This is the inverse of the commerce-platform mental model where one Product record represents the catalog item and inventory belongs to the location/seller.

Key fields:

| Field | Notes |
|-------|-------|
| `seller` | The owning seller; immutable after creation |
| `title`, `description` | Free-text (HTML not sanitized — see `api-setup.md`) |
| `price` | Per-Advert listed price in lowest denomination integer |
| `taxonId` | Category assignment; determines the applicable Prototype |
| `brandId` | Brand reference |
| `advertOptionValues` (sometimes surfaced historically as `featureOptionValueIds` — verify on your instance) | Advert-level (not variant-level) option values, per Prototype |
| `productDetails` / `productFeatures` | Structured attribute fields driven by the Prototype |
| `images` | Ordered array; serving via Imgix CDN |
| `published` / `state` | Online / Offline / Draft (publish gated by validation + vetting) |
| `goldenVariant` | Optional link to the marketplace-level master record |
| `externalIds` | PIM ID, ERP ID, etc. |

Operators cannot create seller-owned Adverts directly via the Operator API. New Adverts originate from the seller side (Seller API or seller portal upload) or from Golden Product backfill (see below). The operator-side `advertUpsert` flow exists but is **explicitly labelled legacy in the docs** — the current path is seller-driven.

## Variant

A buyable SKU under an Advert.

Key fields:

| Field | Notes |
|-------|-------|
| `advert` | The owning Advert (so transitively, one Seller) |
| `sku` | Seller's SKU; not globally unique on the marketplace |
| `barcode` | Used for Golden Product auto-link |
| `countOnHand` | Integer stock; nullable when `infiniteQuantity` is true |
| `infiniteQuantity` | If true, no stock enforcement |
| `optionValueIds` | The variant axes (color, size, etc.) per Prototype |
| `goldenVariant` | Optional link to marketplace-level GoldenVariant |

**Stock is enforced at order creation** — see `orders-fulfillment.md`. No overstocking or pre-order is possible through the API.

## GoldenProduct & GoldenVariant

The **marketplace-level master record**. Not buyable directly; exists to:

1. Enforce consistent product attributes across sellers offering the same product.
2. Backfill seller Adverts when a seller adds a known barcode.
3. Group identical products across sellers for buy-box / "other sellers" UX.

Two creation pathways:

| Mutation | Timing | When to use |
|----------|--------|-------------|
| `variantUpsertFromBarcode` | Immediate backfill | The seller has just added a known barcode and the storefront expects the Advert to be searchable now |
| `advertUpsert` (golden flow) | Batch, ~1 hour | Operator-driven Golden Product creation/update; seller Adverts backfill on next batch cycle |

**Anti-pattern:** building a UI that expects immediate cross-seller Advert backfill after Golden Product update. The default cycle is ~1 hour. Use barcode-driven upsert when latency matters.

The PIM integration story almost always targets the Golden Product layer (see `composable-integration.md`): PIM is the source of truth for attributes; Marketplacer maps Golden Products to seller Adverts.

## Order, Invoice, LineItem

The single most important shape to internalize:

```
Order  (the customer's purchase — 1 per checkout)
  └─< Invoice  (the per-Seller × per-DeliveryType slice — N per Order)
        └─< LineItem  (a Variant × quantity × cost)
              └─< Adjustment  (discount/promo)
```

**One `orderCreate` mutation returns one Order with N Invoices** — one Invoice per Seller, with an additional split when `deliveryType` varies for the same seller (e.g., one Invoice for BUY_ONLINE and one for CLICK_AND_COLLECT from the same seller).

### Order

Customer-facing entity. Holds buyer details:

| Field | Notes |
|-------|-------|
| `firstName`, `surname` | Buyer name |
| `phone`, `emailAddress` | Buyer contact |
| `address` | Shipping / billing |
| `notifications` | `[EMAIL, SMS]` — which notifications Marketplacer sends |
| `paymentReferences` | Array of `{ paymentReference, amount }` — one per PSP tender; supports split tender (see `payments-payouts.md`) |
| `externalIds` | Map to commerce-platform / OMS order IDs |
| `metadata` | Non-queryable free-form |

### Invoice

The per-seller sub-order. **This is where fulfillment lives.** All shipment, refund, status, and payout activity is scoped to Invoice, not Order.

| Field | Notes |
|-------|-------|
| `seller` | The owning Seller |
| `order` | Back-reference |
| `lineItems` | LineItems belonging to this seller's slice |
| `statusFlags` | Multi-flag invoice state (Ready, Collected, Cancelled, etc.) |
| `deliveryType` | One value per Invoice — drives the split |
| `commissionAmount` | Calculated per Invoice from the seller's CommissionPackage |
| `externalIds` | Map to OMS-side fulfillment IDs |

### LineItem

| Field | Notes |
|-------|-------|
| `variant` | The Variant being purchased |
| `inventoryId` | Multi-store routing (parent/child sellers) |
| `quantity` | Integer |
| `cost` | `{ amount, tax }` in lowest-denomination integer |
| `postage` | `{ amount, tax }` |
| `adjustments` | `[Adjustment]` — promotions, negative amounts |

## Shipment

Created against an Invoice (not an Order). Sellers create their own shipments via `shipmentCreate` in the Seller API.

| Field | Notes |
|-------|-------|
| `invoice` | The Invoice being fulfilled |
| `dispatchedAt` | Timestamp |
| `postageCarrierId` | Carrier reference |
| `trackingNumber` | Free-text |
| `shippedItems` | `[{ lineItemId, quantity }]` — partial shipments supported, summed ≤ ordered |

Multiple Shipments per Invoice are first-class. See `orders-fulfillment.md` for the partial-fulfillment pattern.

## RefundRequest

Has its **own state machine** distinct from Invoice. The lifecycle:

```
Created → Returned → Processed → Refunded
```

Each transition emits its own webhook event (see `webhooks-events.md`). The states map to:

| State | Meaning |
|-------|---------|
| `Created` | Customer or seller requested a refund; awaiting return |
| `Returned` | Goods received back |
| `Processed` | Operator/seller has reviewed and approved the refund |
| `Refunded` | Funds returned to the customer; commission reversed |

Cancellations (pre-shipment) use the same RefundRequest flow with appropriate state transitions; there is no separate "cancel order" entity.

## Remittance & RemittanceAdvice

Two distinct entities — conflating them produces incorrect AP feeds.

| Entity | Granularity | When created |
|--------|-------------|--------------|
| **Remittance** | One per Invoice (or Invoice amendment) | When the invoice has at least one dispatched line item **and** no outstanding line items |
| **RemittanceAdvice** | One per payout cycle, per Seller | Generated nightly, grouping all releasable Remittances for that Seller |

A Remittance is a debt owed to a seller for one specific Invoice. A RemittanceAdvice is a payout document grouping many Remittances into a single bank movement. Fields use a `…Cents` suffix to make denomination explicit (`amountCents`, `commissionAmountCents`, `totalCents`, `totalPaidCents`, `shippingCostCents`).

Webhook events: RemittanceAdvice emits **Create** and **Update** only — no Destroy, since financial records are immutable. See `payments-payouts.md` for the release flow, payout-system backends (Airwallex / Hyperwallet / Xero), and ERP integration patterns.

## CommissionPackage

How the operator charges sellers. Assigned per-seller.

| Field | Notes |
|-------|-------|
| `defaultRate` | Flat commission percentage |
| `customCommissionRates` | Per-Taxon overrides |
| `thresholdPrice` + `overThresholdRate` | Tiered: rate changes above a threshold price |
| `appliesToPostage` | Whether commission is taken on shipping cost too |

**Commission is reversed on refund** — see `payments-payouts.md`.

## Prototype, Taxon, OptionType, OptionValue

The attribute model.

- **Taxon** = a category node. References a Prototype.
- **Prototype** = the attribute schema for products in that Taxon. Says which OptionTypes are advert-level vs variant-level.
- **OptionType** = an attribute (e.g., "Color", "Size", "Material") with one of three input types: `SINGLE_SELECT`, `MULTI_SELECT`, `FREE_TEXT`.
- **OptionValue** = a possible value for an OptionType (e.g., "Red", "Large").

**The Prototype determines whether an attribute differentiates variants or describes the whole Advert.** Color is typically variant-level (different SKU per color). Brand-country-of-origin is typically advert-level.

**Anti-pattern:** writing variants without consulting the Prototype. If the Prototype expects Color at variant-level and Material at advert-level, but you submit Color as an advert-level option value (`advertOptionValues` on most current builds), the call fails with a validation error. Query the Prototype before constructing the upsert, and check your instance's GraphDoc for the exact field name — older builds may still surface `featureOptionValueIds`.

## Brand

Referenced by Adverts via `brandId`. Brands are created/managed at the marketplace level by the operator. There is also a `brandMappings` input on `advertUpsert` for fuzzy/name-based linking when the ID is unknown — useful for PIM-driven import where the PIM may use brand names rather than Marketplacer brand IDs.

## Adjustment & Promotion

- **Adjustment** sits on a LineItem. Represents a discount as a negative `amount` plus a `sourceId` pointing to the Promotion that caused it.
- **Promotion** is a top-level entity with its own Create/Update/Destroy webhook events. The discount engine that produces Adjustments lives on the operator side; Marketplacer records the result, not the rule logic.

For storefront-driven promotions (e.g., commerce-platform cart promotions), the typical pattern is: the commerce platform computes the discount → the resulting Adjustment is passed in the `orderCreate` call.

## MultiStoreMembership

Models parent/child seller relationships. A parent retailer aggregates inventory across multiple child stores; the same Variant has different inventory locations.

Used in two places:

1. **Variant inventory** — the parent's Variant may carry multiple inventories, one per child store.
2. **Order line items** — supply `inventoryId` to route fulfillment to a specific child store.

This is the only multi-location pattern Marketplacer documents. It is **not** the same as "multi-region marketplace" — that requires multiple Marketplacer instances.

## PaymentReferences

A field on Order. **Plural array**, not singular — `paymentReferences: [{ paymentReference, amount }]`. Supports split tender (gift card + card, store credit + card, etc.) at order creation; even single-tender orders pass an array of one. Used by MPay to reconcile deposits against orders/refunds. See `payments-payouts.md` for the full flow.

## ExternalIds vs CustomFields vs Metadata

Three extension surfaces with different semantics. Choosing the wrong one shows up as either "I can't query by this" or "this leaks into the wrong UI."

| Surface | Queryable? | Schema | Use for |
|---------|-----------|--------|---------|
| `externalIds` | **Yes (key + value filter)** | Untyped key/value pairs | Foreign-system identifiers (PIM ID, ERP ID, commerce-platform Order ID, OMS Fulfillment ID) — anywhere you need lookup by content |
| `customFields` | **Yes (per-field, typed)** | Per-instance configured, typed schema | First-class extension columns: domain-specific data you want in the admin UI and on webhook queries with the type system intact (e.g., `wholesaleTier`, `eligibleForSubscription`) |
| `metadata` | No | Untyped key/value pairs | Display annotations, integration audit info — anything you never need to query by |

**Three-way decision rule:**

- If you need to look up a record by this value → `externalIds` (foreign keys) or `customFields` (typed business data).
- If you want admin-UI editability and a type → `customFields`. Coordinate with the operator to add the field to the instance config first.
- If it's just for display or audit alongside the record, never the lookup key → `metadata`.

**Anti-pattern:**
```graphql
# Will scan everything — metadata is not queryable
{ allAdverts(metadata: { key: "akeneo_id", value: "ABC123" }) { ... } }
```

**Recommended:**
```graphql
mutation { advertExternalIdUpsert(input: {
  advertId: $id, externalIds: [{ key: "akeneo_id", value: "ABC123" }]
}) { ... } }

# Later:
{ allAdverts(externalIds: [{ key: "akeneo_id", value: "ABC123" }]) {
    nodes { id legacyId title }
} }
```

Put every foreign-system identifier you might ever query by into `externalIds`. Use `customFields` for typed, queryable business extensions. Reserve `metadata` for display fields and audit columns that are looked up by the entity ID, not by content.

## Contextual History

Marketplacer records a **contextual history** of changes for several entity types (Adverts, Variants, Invoices, Sellers, etc.) — who changed what, when, and from which actor. Surfaced as a queryable GraphQL field rather than a separate event stream.

| Use case | Example |
|----------|---------|
| Audit / compliance | "Why did this Advert's price change at 03:14 UTC?" |
| Customer-service tooling | Show CS reps the last 10 changes on this Order/Invoice |
| Reconciliation | Match Marketplacer-side changes to upstream system events when something looks wrong |

It's not a replacement for webhooks (which fire near-real-time on every change) — contextual history is the after-the-fact record you query when you need provenance. Defer to the live doc for the exact field name and entity coverage; it expands over time.

## Modeling Decisions Worth Flagging

When mapping Marketplacer into another system's mental model, surface these explicitly in design docs:

1. **Adverts are per-seller, not per-product.** The "shared product master" lives in Golden Products, not Adverts. If the commerce platform's product catalog is the source of truth, the mapping target is Golden Product, not Advert.
2. **Orders split into Invoices.** Code that expects one order → one fulfillment record is wrong. Build for one Order → N Invoices from day one, even if launch goes live with single-seller carts.
3. **There is no `Order` webhook event.** Subscribe to Invoice for order-state-equivalent signals.
4. **RefundRequest is its own state machine.** Don't try to model refund as an Invoice status — it's a separate entity.
5. **One instance = one currency = one hostname.** Multi-region is achieved with multiple instances. Plan the foreign-key strategy with instance ID baked in.
6. **`ExternalIds` is the foreign-key surface.** `metadata` is for display. The choice between them determines whether you can recover sync drift.
7. **The operator's PSP captures funds.** Marketplacer is not a split-payment processor. See `payments-payouts.md`.
