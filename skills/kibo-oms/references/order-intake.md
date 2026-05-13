# Order Intake

Kibo OMS is most commonly sold standalone, sitting behind a non-Kibo storefront (Shopify, SFCC, BigCommerce, Adobe Commerce, custom). In that pattern, orders arrive via API push with `isImport=true` — the source platform owns cart, checkout, and payment capture; Kibo owns routing, inventory, fulfillment, and returns.

## Table of Contents
- [Two Intake Modes](#two-intake-modes)
- [The `POST /commerce/orders` Endpoint](#the-post-commerceorders-endpoint)
- [The Total-Reconciliation Gotcha](#the-total-reconciliation-gotcha)
- [Idempotency via `externalId`](#idempotency-via-externalid)
- [Channel Codes and Source-System Mapping](#channel-codes-and-source-system-mapping)
- [Order Data Model on Intake](#order-data-model-on-intake)
- [Bundled Mode: When Orders Originate in Kibo eCommerce](#bundled-mode-when-orders-originate-in-kibo-ecommerce)
- [The Three-Way Sync](#the-three-way-sync)
- [Order Push: Source → Kibo](#order-push-source--kibo)
- [Inventory Sync: Kibo → Source](#inventory-sync-kibo--source)
- [Status & Tracking Back: Kibo → Source](#status--tracking-back-kibo--source)
- [Catalog Sync: Source → Kibo](#catalog-sync-source--kibo)
- [Connectors](#connectors)
- [Anti-Patterns](#anti-patterns)
- [Checklist](#checklist)

## Two Intake Modes

| Mode | When | Behaviour |
|------|------|-----------|
| **Native** | Bundled Kibo eCommerce + OMS | Carts → orders flow internally; payment captured by Kibo; same APIs but `isImport` is omitted/false |
| **Import** (OMS-only) | Shopify / SFCC / custom storefront fronting Kibo OMS | `POST /commerce/orders` with `isImport=true`; payment already captured externally |

**The standalone-OMS pattern is dominant.** Kibo's strongest standalone product is the OMS, and most net-new engagements are built around fronting it with Shopify, SFCC, or a custom storefront. Code that assumes orders originate in Kibo eCommerce breaks the first time it meets one of those deals.

In Import mode, Kibo:
- Skips cart/checkout validation flow (no inventory hold at cart, no fraud-at-submit).
- Trusts pre-calculated pricing, tax, shipping, and discount totals.
- Trusts the gateway authorization (gateway transaction ID, auth code, tokenized card).
- Marks the order as `type=Offline` and surfaces a "historical import — cannot be edited" badge in the Admin UI.
- Enters the standard fulfillment workflow on accept.

Source: <https://docs.kibocommerce.com/help/orders-api-overview>

## The `POST /commerce/orders` Endpoint

Auth: OAuth 2.0 client credentials with required headers `x-vol-tenant: <tenantId>` and `x-vol-site: <siteId>`. SDK config (Kibo Java/Node SDKs) takes `tenantId`, `siteId`, `clientId`, `sharedSecret`, `authHost` and exchanges for a bearer token automatically.

Three flags carry the entire load-bearing semantics of an import order:

| Field | Required value | Why it matters |
|-------|----------------|----------------|
| `isImport` | `true` | Skips Kibo's checkout validation; trusts the external platform |
| `type` | `"Offline"` | Marks the order as historical; locks editing in Admin UI |
| `externalId` | source-platform order ID (Shopify order ID, SFCC order number, ERP order number) | Canonical foreign key; idempotency anchor; reconciliation key |

Minimal import shape:

```json
{
  "customerAccountId": 100,
  "email": "jane@example.com",
  "type": "Offline",
  "isImport": true,
  "externalId": "shopify_5678901234",
  "channelCode": "Web",
  "currencyCode": "USD",
  "tenantId": 12345,
  "siteId": 67890,
  "items": [
    {
      "product": {
        "productCode": "SKU-001",
        "name": "Standard Tee",
        "price": { "price": 25.00, "salePrice": 20.00 }
      },
      "quantity": 2,
      "subtotal": 40.00,
      "itemTaxTotal": 3.20,
      "shippingTotal": 5.00,
      "shippingTaxTotal": 0.40,
      "discountTotal": 10.00,
      "fulfillmentLocationCode": "DC01",
      "fulfillmentMethod": "Ship"
    }
  ],
  "fulfillmentInfo": {
    "fulfillmentContact": { "...": "shipping name/address/phone" },
    "shippingMethodCode": "fedex_2_DAY",
    "shippingMethodName": "FedEx 2-Day"
  },
  "billingInfo": {
    "paymentType": "CreditCard",
    "billingContact": { "...": "billing name/address" },
    "card": { "isTokenized": true, "paymentServiceCardId": "tok_..." }
  },
  "payments": [
    {
      "paymentType": "CreditCard",
      "status": "Authorized",
      "amountRequested": 48.60,
      "amountCollected": 48.60,
      "interactions": [
        {
          "interactionType": "Authorization",
          "gatewayTransactionId": "ch_3RxYz...",
          "gatewayResponseCode": "Approved",
          "amount": 48.60
        }
      ]
    }
  ]
}
```

Imported orders typically land at `Validated` or `Accepted` directly, skipping `Pending`/`Submitted` because the source platform already did checkout. Kibo doesn't expose a knob to land them in a non-default status — you control this by how completely the import payload satisfies validation.

## The Total-Reconciliation Gotcha

**The most common cause of 422 on import.** Kibo expects:

```
sum(items[].subtotal)
  + sum(items[].itemTaxTotal)
  + sum(items[].shippingTotal)
  + sum(items[].shippingTaxTotal)
  - sum(items[].discountTotal)
  == order total
```

The sum must reconcile to the penny. Compute every component in the source platform's currency precision; never round mid-pipeline.

**Anti-pattern:**

```typescript
// Source rounds to integer cents; integration converts to dollars with toFixed(2)
// and the floating-point cast loses sub-cent precision on multi-quantity lines.
const subtotal = Number((stripeLine.amount * stripeLine.quantity / 100).toFixed(2));
// 100 units at $0.999 each = expected 99.90, but rounds to 99.91 here.
```

**Recommended:**

```typescript
// Stay in integer cents until the absolute last conversion; mirror the source's
// own line-level totals rather than recomputing.
const subtotalCents = shopifyLine.discounted_total_set.shop_money.amount_in_cents;
const subtotal = subtotalCents / 100;
```

If the source platform's API exposes pre-computed line totals (Shopify's `current_subtotal_price_set`, SFCC's `merchandize_total_price`), use those rather than recomputing — the source has already reconciled internally.

## Idempotency via `externalId`

`externalId` is Kibo's canonical foreign-key strategy for round-tripping orders back to the source. It's the only stable mechanism Kibo offers for this.

| Concern | Strategy |
|---------|----------|
| **Duplicate-create from retries** | Query `GET /commerce/orders?filter=externalId eq <id>` before posting; if present, skip |
| **Status-update reconciliation** | Webhook receiver looks up the source-platform order by `externalId` |
| **Cancellation / refund routing** | Source platform sends events keyed on its own order ID; integration resolves to Kibo via `externalId` |

**Anti-pattern: stuffing other data into `externalId`.**

```typescript
// Wrong — tracking number is per-package, not the order foreign key.
externalId: `${shopifyOrderId}|${trackingNumber}`;

// Wrong — encoding the channel destroys the lookup key.
externalId: `shopify:${shopifyOrderId}`;
```

**Recommended:**

```typescript
externalId: shopifyOrderId,
channelCode: 'Web',                       // operational channel
attributes: [
  { fullyQualifiedName: 'tenant~commerceSource', value: 'shopify' },
  { fullyQualifiedName: 'tenant~sourceCartId', value: shopifyCartId },
],
```

Custom order attributes carry the auxiliary identifiers. `externalId` stays the one stable string that maps Kibo Order ↔ Source Order.

## Channel Codes and Source-System Mapping

`channelCode` is the operational channel — `Web`, `Mobile`, `POS`, `Marketplace`, `CallCenter`. It is **not** the source-system identifier. There is no schema-typed "source system" enum; convention is:

- `channelCode` for the operational channel (used in reporting).
- A custom attribute (`commerceSource: "shopify" | "sfcc" | "custom"`) for the integration identifier.
- `originalCartId` for the source cart ID when analytics joins back to abandoned-cart funnels are required.

## Order Data Model on Intake

| Field | Notes |
|-------|-------|
| `items[]` | Each line. `fulfillmentMethod` is required per line; routing cannot dispatch without it. |
| `items[].fulfillmentMethod` | `"Ship"`, `"Pickup"`, `"DirectShip"`, `"Digital"`, `"Delivery"` |
| `items[].fulfillmentLocationCode` | Optional pre-routed location. If omitted, the Order Routing engine picks. |
| `items[].product.productCode` | Must match a Kibo product (or variant). For variants, use the variant's productCode — not the parent SKU. |
| `fulfillmentInfo.fulfillmentContact` | Ship-to address; required for Ship/Delivery lines |
| `billingInfo.billingContact` | Required for the payment record even when payment is captured externally |
| `payments[]` | Array. Even single-tender orders pass one entry. Use `status: "Authorized"` or `"Captured"` to mirror the source PSP's state. |
| `payments[].interactions[]` | Audit trail of gateway calls; `gatewayTransactionId` is what enables PSP reconciliation later |
| `attributes[]` | Custom order attributes (per the tenant's extended-attribute schema) |
| `externalId` | Source-platform order ID (load-bearing) |
| `channelCode` | Operational channel |
| `currencyCode` | ISO 4217 |

Each line item's `fulfillmentMethod` drives which BPMN shipment workflow runs. See `fulfillment.md` for the workflow catalog.

## Bundled Mode: When Orders Originate in Kibo eCommerce

When Kibo eCommerce is also in the picture, the storefront submits the order through Kibo's own cart → checkout → order path, and the order arrives in OMS automatically. Different mental model:

| Concern | Standalone (Import) | Bundled (Native) |
|---------|---------------------|------------------|
| Order creation | External API push, `isImport=true` | Internal cart-submit, no `isImport` |
| Payment | Captured externally | Kibo's payment service |
| Inventory hold | None at cart (source owns) | Kibo cart reservation (`POST /commerce/reservation`) |
| Catalog source of truth | External (Shopify, PIM) | Kibo catalog |
| `externalId` usage | Required — source order ID | Optional — for ERP / downstream systems |

Code paths that handle order intake should branch on `isImport` rather than on the integration target, because the same instance can have both modes active (e.g., POS orders imported alongside web orders from Kibo eCommerce).

## The Three-Way Sync

Standalone OMS with an external commerce platform is a three-way sync:

```
   ┌──────────────┐   orders, customers   ┌────────────┐
   │ Source       │ ──────────────────────►│ Kibo OMS   │
   │ (Shopify /   │                        │            │
   │ SFCC / etc.) │ ◄─── inventory ────────│            │
   │              │   tracking, status     │            │
   └──────────────┘ ◄────────────────────  └────────────┘
         ▲                                       │
         │ catalog                               │ fulfillment
         │ (PIM →                                ▼
         │  source)                        ┌────────────┐
         │                                 │ Locations  │
                                           │ (DCs/stores│
                                           │  /dropship)│
                                           └────────────┘
```

| Concern | Owner |
|---------|-------|
| Catalog, cart, checkout, payment capture, customer account | Source platform |
| Order routing, inventory at locations, fulfillment workflows, returns | Kibo OMS |
| Bidirectional sync of orders, inventory, status, refunds | Both |

The OMS aggregates Invoices/Shipments into per-location fulfillment work; the source platform aggregates Kibo's status updates into the customer-facing order record. Each side has its own source-of-truth role.

## Order Push: Source → Kibo

Direction: source → Kibo, real-time per order.

```
Shopify order_paid webhook
   └─► integration listener
        ├─► transform (Shopify schema → Kibo schema)
        ├─► resolve productCode mapping (Shopify variant.sku → Kibo productCode)
        ├─► resolve location/channel codes
        └─► POST /commerce/orders {isImport: true, externalId: <shopify_id>, ...}
```

Critical mapping:
- Shopify `variant.sku` → Kibo `productCode` (when catalog synced via the documented Shopify→Kibo path).
- Shopify `payment_gateway_names` + transaction IDs → Kibo `payments[].interactions[].gatewayTransactionId`.
- Shopify `shipping_lines[].code` → Kibo `shippingMethodCode`.
- Shopify `order_id` → Kibo `externalId`.

## Inventory Sync: Kibo → Source

Direction: Kibo → source, real-time per inventory change. **Eventual, not synchronous.**

```
Kibo inventory.changed event (per UPC × Location)
   └─► integration listener
        ├─► aggregate to network-wide ATP per UPC
        └─► PUT Shopify InventoryLevel / SFCC Inventory
```

The source platform usually has one inventory bucket per SKU (or per location if it supports multi-location, but most external platforms don't model locations with the depth Kibo does). Translation strategies:

| Strategy | Pros | Cons |
|----------|------|------|
| **Aggregate sum** — total Available across all Kibo locations → one number | Simple | Loses BOPIS-eligibility nuance |
| **Buffer** — subtract a safety percentage from the published number | Handles PSP-timing race vs Kibo allocation | Tunes against shrinkage rather than fixes it |
| **Source-side multi-location** — mirror Kibo locations 1:1 (Shopify Locations, SFCC inventory lists) | Closer fidelity to OMS truth | Requires real-time per-location updates and stable location naming on both sides |

**Critical: this sync is eventual.** A storefront UI that reads source-platform inventory and expects it to reflect the latest OMS Allocated state will see stale numbers during traffic bursts. For accurate PDP inventory under load, query Kibo's Real-Time Inventory Service directly rather than going through the source platform's mirror.

Use Kibo's `inventory.cartitemallocated` and `inventory.cartpendingitemcreated` events for cart-level holds when those signals exist.

## Status & Tracking Back: Kibo → Source

Direction: Kibo → source, per shipment update.

```
Kibo shipment.statuschanged / shipment.workflowstatechanged
   └─► integration listener
        ├─► extract: orderExternalId, trackingNumber, carrier, status
        └─► POST source-platform-fulfillment-update
            (Shopify Fulfillment API, SFCC ShipOrder, etc.)
```

Key fields on the source side typically include: `tracking_number`, `tracking_company`, `tracking_url`, `status` (`fulfilled`, `partially_fulfilled`).

**Subscribe to `shipment.*`, not `order.*`.** Orders don't ship — shipments do, and an Order with N shipments fires N updates. See `fulfillment.md` for the full reasoning.

## Catalog Sync: Source → Kibo

Direction: source → Kibo, scheduled (hourly delta sync recommended).

Kibo OMS needs a thin product record per SKU — enough to validate orders, enough for routing rules, enough for inventory tracking. The recommended Shopify path (per Kibo's own blog):

1. Extract via Shopify `GET /products.json` (or delta via `updated_at_min`).
2. Transform to three CSVs: `products.csv`, `productcatalog.csv`, `productimages.csv`.
3. ZIP + upload via Kibo Import/Export API.
4. Each Shopify variant with a SKU → one Kibo product.
5. `ProductCode = variant.sku`.

For SFCC and other platforms, the equivalent pattern: scheduled product feed → transform → Kibo bulk import. Real-time per-product sync is possible via the Product Admin API but rarely justified at OMS-only scope.

URL: <https://kibocommerce.com/blog/how-to-sync-a-shopify-catalog-into-kibo-order-management/>

## Connectors

| Source | Connector status |
|--------|------------------|
| **Shopify** | **First-party** — Kibo OMS Connector in the Shopify App Store (Mar 2024 launch). Bidirectional sync of orders + products + inventory. Free to install; OMS subscription separate. Real-time + scheduled modes. Heavy customization requires moving off the connector to a custom integration. |
| **SFCC** | Partner-led — first-party cartridge status unknown; verify against your instance and current partner catalog. Most engagements appear to be partner-led integrations rather than a Kibo-supplied cartridge. |
| **BigCommerce, Adobe Commerce** | Per-partner integrations; Kibo Connect Hub lists pre-built connectors |
| **Custom** | Direct API integration following the order-push / inventory-sync / status-back patterns above |

URLs: <https://apps.shopify.com/kibo-oms-connector>, <https://kibocommerce.com/platform/connect-hub/>

## Anti-Patterns

### Importing Orders with `isImport=false` from an External Source

Kibo tries to re-validate the order through its checkout pipeline — re-runs inventory allocation, re-attempts payment capture against an already-captured gateway transaction, double-decrements inventory. Always `isImport=true` for non-Kibo carts.

### Pricing-Total Drift on Import

`subtotal + tax + shipping − discount ≠ order total` → 422. Compute totals in the source platform's currency precision; mirror the source's own pre-computed line totals rather than recomputing. See [The Total-Reconciliation Gotcha](#the-total-reconciliation-gotcha).

### Treating Source-Platform Inventory as Real-Time Truth

The inventory sync from Kibo to the source is eventual. Under load, the storefront's inventory mirror lags. PDPs that need accurate availability should query Kibo's Real-Time Inventory Service directly, not the source platform's mirror.

### Stuffing Tracking or Other Data Into `externalId`

`externalId` is the source-platform order foreign key. Tracking belongs on the package (`shipments[].packages[].trackingNumber`); auxiliary identifiers belong in custom order attributes. Conflation breaks reconciliation and idempotency lookup.

### Generic `external_id` Naming on Custom Attributes

When custom attributes carry foreign keys, name them after the source system and entity (`shopify_order_id`, `sfcc_order_number`). Generic `external_id` collides across integrations and obscures intent.

### No Pre-Post Idempotency Check

Without a `GET /commerce/orders?filter=externalId eq <id>` check before posting, upstream retries (Shopify's `order_paid` webhook can fire multiple times) duplicate orders. Always pre-check or use a deterministic ID strategy that lets Kibo reject the duplicate cleanly.

### Modeling Both Modes the Same Way

Bundled mode (orders originate in Kibo eCommerce) and standalone mode (imported from Shopify/SFCC) have different ownership boundaries. Code that assumes everything is bundled breaks on standalone deals; code that assumes everything is standalone misses Kibo's cart events. Branch on `isImport`.

### Forgetting `fulfillmentMethod` on Each Line Item

Routing cannot dispatch a line without a `fulfillmentMethod`. The line item gets stuck pre-Accept and surfaces in the `Customer Care` rollup. Always set `Ship`, `Pickup`, `DirectShip`, `Digital`, or `Delivery`.

### Using Parent SKU as `productCode` When Variants Exist

Kibo expects one productCode per variant. Submitting the parent SKU for a variant-level Shopify product fails the productCode lookup, or worse, attaches inventory to a phantom record. Map Shopify `variant.sku` (not the parent SKU) → Kibo `productCode`.

### Capture-Then-Import at Checkout

If Kibo rejects the import after the PSP has captured funds, the integration has to refund — gateway fees, audit-trail noise, customer confusion. Prefer `authorize → import → capture` where the source platform allows it. Imports that fail then become clean auth cancellations.

## Checklist

Before shipping order intake code:

- [ ] `isImport: true`, `type: "Offline"`, and a populated `externalId` on every import order.
- [ ] `externalId` is the source-platform's primary order ID — not encoded, not concatenated.
- [ ] Pre-post lookup by `externalId` to prevent duplicate creation on upstream retries.
- [ ] Custom attributes carry source-system identifiers (`commerceSource`, `sourceCartId`), not `externalId`.
- [ ] Line-item totals reconcile to the order total to the penny (use source-side pre-computed totals).
- [ ] Every line item has `fulfillmentMethod` set.
- [ ] `productCode` resolves to a variant when variants exist (not the parent SKU).
- [ ] Payment record carries `gatewayTransactionId` so PSP-side reconciliation works for refunds.
- [ ] Checkout sequence is authorize → import → capture where the source platform allows it.
- [ ] Inventory sync from Kibo → source treated as eventual; PDPs needing real-time read from Kibo's RIS directly.
- [ ] Status / tracking listener subscribes to `shipment.*` events, not `order.*`.
- [ ] Branch logic between bundled (`isImport` absent/false) and standalone (`isImport: true`) intake modes.
- [ ] SFCC connector availability verified against current partner catalog rather than assumed.
