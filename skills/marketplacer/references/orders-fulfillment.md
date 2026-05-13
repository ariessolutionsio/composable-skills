# Orders & Fulfillment

Marketplacer's order model has one quirk that determines almost every integration decision: **`orderCreate` produces one Order with N Invoices (one per Seller × deliveryType)**, and **there is no `Order` webhook event**. Status changes flow as Invoice events. Get this wrong and the integration appears to work in single-seller test scenarios then silently breaks when a real cart spans sellers.

## Table of Contents
- [`orderCreate` Mutation](#ordercreate-mutation)
- [Line Item Method vs Invoice Method](#line-item-method-vs-invoice-method)
- [Multi-Seller Order Semantics](#multi-seller-order-semantics)
- [Multi-Store Orders (Parent/Child Sellers)](#multi-store-orders-parentchild-sellers)
- [Wholesale Orders](#wholesale-orders)
- [Stock Enforcement](#stock-enforcement)
- [Delivery Types & Invoice Splits](#delivery-types--invoice-splits)
- [Promotions & Custom Fees](#promotions--custom-fees)
- [Shipments](#shipments)
  - [Partial Shipments](#partial-shipments)
- [Refunds & Cancellations](#refunds--cancellations)
- [Invoice Status Flags](#invoice-status-flags)
- [Invoice Annotations](#invoice-annotations)
- [The Missing Order Webhook](#the-missing-order-webhook)
- [PII & Order Purging](#pii--order-purging)
- [Checklist](#checklist)

## `orderCreate` Mutation

Called by the operator's checkout/order-orchestration layer **after** the PSP has captured funds. Marketplacer never sees the payment; it records the order and routes per-seller fulfillment.

```graphql
mutation OrderCreate($input: OrderCreateInput!) {
  orderCreate(input: $input) {
    order {
      id legacyId
      paymentReferences { paymentReference amount }
      invoices {
        nodes {
          id legacyId seller { id }
          deliveryType
          lineItems { nodes { id quantity cost { amount tax } } }
        }
      }
    }
    errors { path message }
  }
}
```

```typescript
const input = {
  notifications: ['EMAIL'],          // or ['EMAIL', 'SMS'] or []
  paymentReferences: [               // array, even for single-tender — see payments-payouts.md
    { paymentReference: 'pi_3RxYz...', amount: 5450 },  // PSP tx ID + gross cents
  ],
  order: {
    firstName: 'Jane', surname: 'Doe',
    phone: '+61400000000', emailAddress: 'jane@example.com',
    address: {
      line1: '123 Main St', city: 'Melbourne',
      postcode: '3000', countryCode: 'AU',
    },
  },
  lineItems: [
    {
      variantId: 'VmFyaWFudC03MTM3',
      quantity: 1,
      cost: { amount: 4500, tax: 450 },
      postage: { amount: 1000, tax: 100 },
      adjustments: [{ amount: -500, sourceId: 'UHJvbW8tMQ==' }],
      deliveryType: 'BUY_ONLINE',
    },
    {
      variantId: 'VmFyaWFudC04MjAw',
      quantity: 2,
      cost: { amount: 2000, tax: 200 },
      postage: { amount: 800, tax: 80 },
      deliveryType: 'BUY_ONLINE',
    },
  ],
  externalIds: [
    { key: 'commerce_order_id', value: 'ord-9c7e...' },
    { key: 'oms_order_id', value: 'OMS-2026-001234' },
  ],
};
```

## Line Item Method vs Invoice Method

`orderCreate` accepts **either** a flat `lineItems[]` (Marketplacer splits) **or** pre-split `invoices[]` (caller splits). They are mutually exclusive.

| Method | When to use |
|--------|-------------|
| **Line Item method** (recommended) | The caller doesn't need to control invoice grouping — let Marketplacer derive it from `seller × deliveryType` |
| **Invoice method** | The caller has a specific reason to control grouping (e.g., a custom commerce-platform splitting rule the operator wants to preserve) |

**Recommended default: Line Item method.** Marketplacer's split is correct for almost every case.

## Multi-Seller Order Semantics

When `lineItems[]` contains items from multiple sellers, Marketplacer returns **one Order with one Invoice per seller**. Same seller, same `deliveryType` → one Invoice. Same seller, different `deliveryType` → two Invoices.

**Example:** cart contains:
- Item A: Seller X, BUY_ONLINE
- Item B: Seller X, BUY_ONLINE
- Item C: Seller X, CLICK_AND_COLLECT
- Item D: Seller Y, BUY_ONLINE

Result: 1 Order, 3 Invoices:
- Invoice 1: Seller X, BUY_ONLINE — items A & B
- Invoice 2: Seller X, CLICK_AND_COLLECT — item C
- Invoice 3: Seller Y, BUY_ONLINE — item D

**Integration implication:** the OMS / commerce platform sees one customer order; the fulfillment side (per-seller picking/shipping) sees three. Map this explicitly. The Order's `externalIds` carries the OMS order ID; each Invoice's `externalIds` carries the per-seller fulfillment ID.

## Multi-Store Orders (Parent/Child Sellers)

When a Seller has a `MultiStoreMembership`, the same Variant may have inventory in multiple physical locations. The line item routes via `inventoryId`:

```typescript
{
  variantId: 'VmFyaWFudC03MTM3',
  inventoryId: 'SW52ZW50b3J5LTQy',   // which child store fulfills
  quantity: 1,
  cost: { amount: 4500, tax: 450 },
  // ...
}
```

Without `inventoryId`, the parent Seller's default inventory is used. For click-and-collect specifically, supply `inventoryId` to route to the correct store location.

## Wholesale Orders

Marketplacer documents support for **B2B / wholesale order flows** alongside the standard retail path — the operator-API examples index lists a dedicated "Wholesale Orders" how-to, and the implication is that wholesale buyers can be priced and settled differently from retail. **The specific field shape, however, varies by instance and the public how-to is not always accessible**, so this section sticks to the architectural pattern rather than asserting field names.

**What's stable across implementations:**

- **Price resolution lives in the cart, not in Marketplacer.** Whatever the commerce platform's pricing engine produces for the line item (retail or wholesale) is what gets passed as `lineItems[].cost.amount` on `orderCreate`. Marketplacer settles the Invoice against whatever cost you submit — it does not run pricing rules itself.
- **Per-Taxon commission overrides exist on `CommissionPackage`** (`customCommissionRates`, see `payments-payouts.md`). If the operator wants different commission for categories that wholesale buyers tend to purchase, that's the documented surface.
- **Tax all-or-nothing rule still applies.** B2B tax-exempt orders submit `cost.tax: 0` (and `postage.tax: 0`) on every line item — never omit the field. If the tax engine returns nulls/undefined for exempt lines, the order creation fails.

**What's instance-specific (defer to the live doc):**

- Whether `orderCreate` accepts an explicit wholesale flag or price-source input vs simply reading the `cost.amount` you submit.
- Whether Variants carry a separate wholesale price tier field, or wholesale pricing is purely a cart-layer concern.
- Whether `CommissionPackage` can be assigned at the buyer level vs only at the seller level (the documented assignment is per-Seller via `seller.commissionPackageId`; per-buyer wholesale rates may require a dedicated wholesale-only seller, or it may be a new field — verify).

**Practical pattern that works regardless of instance shape:**

1. Cart classifies the buyer (wholesale vs retail) using the commerce platform's auth/account state.
2. Cart resolves the wholesale price and passes it as `cost.amount` to `orderCreate`.
3. If commission should differ for the wholesale catalog, set up a Taxon-level override on the seller's `CommissionPackage` rather than relying on Marketplacer to detect "wholesale".
4. For tax-exempt B2B buyers, ensure the tax engine emits `0` (not missing) on every line item.

**Defer to the live doc** at [api.marketplacer.com/docs/operator-api/examples/orders/howto_wholesale_orders](https://api.marketplacer.com/docs/operator-api/examples/orders/howto_wholesale_orders) and to your instance's GraphDoc at `https://<instance>/graph-doc/` for the exact input shape on a given build.

## Stock Enforcement

Marketplacer rejects orders that would exceed `countOnHand` for any Variant where `infiniteQuantity` is false. There is **no overstocking, no backorder, no pre-order**.

**Anti-pattern:** retrying `orderCreate` after a stock error in the hope it resolves.
```typescript
catch (err) {
  if (err.message.includes('insufficient stock')) {
    await sleep(1000);
    return orderCreate(input); // stock will not magically reappear
  }
}
```

**Recommended:** treat stock errors as terminal. Surface to the customer ("This item is no longer in stock"); release the held payment (or do not capture until after Marketplacer accepts the order).

**Architectural note:** because Marketplacer rejects after the PSP has captured funds in a naive flow, the operator's checkout sequence should be **authorize → orderCreate → capture**, not capture-then-orderCreate. This makes the rare race condition (stock sold to another buyer between cart and checkout) a clean cancellation rather than a refund.

## Delivery Types & Invoice Splits

The per-line `deliveryType` enum drives Invoice splitting:

| Value | Meaning |
|-------|---------|
| `BUY_ONLINE` (default) | Standard ship-to-customer |
| `CLICK_AND_COLLECT` | Pickup from the seller's location |

If the marketplace supports additional delivery types (e.g., dropship-from-seller vs warehouse), Marketplacer treats each as a distinct split. Check the live schema for the full enum.

## Promotions & Custom Fees

| Discount/fee type | Where | Notes |
|-------------------|-------|-------|
| Per-line promotions | `lineItems[].adjustments[]` | Negative `amount`, `sourceId` references a Promotion |
| Per-invoice custom fees | (set on invoice creation in Invoice method, or via separate mutation) | Use for operator fees that aren't promotions |

**Promotion engine ownership:** the discount rule logic (e.g., "10% off when 3+ items from same seller") lives in the operator's commerce platform / cart layer. Marketplacer records the resulting Adjustment; it does not run discount rules at order creation. The Promotion entity in Marketplacer is a metadata/reporting record.

## Shipments

Sellers create Shipments per Invoice via `shipmentCreate` (Seller API). Operators can also call it via the Operator API for operator-managed fulfillment.

```graphql
mutation ShipmentCreate($input: ShipmentCreateInput!) {
  shipmentCreate(input: $input) {
    shipment { id legacyId dispatchedAt trackingNumber }
    errors { path message }
  }
}
```

```typescript
{
  invoiceId: 'SW52b2ljZS00NTY=',
  dispatchedAt: '2026-05-13T10:00:00Z',
  postageCarrierId: 'UG9zdGFnZUNhcnJpZXItMQ==',
  trackingNumber: 'AU123456789',
  shippedItems: [
    { lineItemId: 'TGluZUl0ZW0tMQ==', quantity: 1 },
    { lineItemId: 'TGluZUl0ZW0tMg==', quantity: 2 },
  ],
}
```

### Partial Shipments

Multiple Shipments per Invoice are first-class. Sum of `quantity` across all shipments per `lineItemId` must be ≤ ordered quantity. Useful for:

- Backorder fulfillment that ships in waves.
- Multi-package orders (e.g., a sofa shipping in three boxes).
- Multi-warehouse fulfillment where items dispatch on different days.

**Anti-pattern:** modeling the OMS-side fulfillment with a hard "one shipment per invoice" constraint. Build for partial shipments from day one even if launch only uses one-shipment-per-invoice.

## Refunds & Cancellations

Both are handled by the **RefundRequest** workflow.

```
Created → Returned → Processed → Refunded
```

Each transition is a separate webhook event (see `webhooks-events.md`). The state machine:

| State | Mutation | What happens |
|-------|----------|--------------|
| `Created` | `refundRequestCreate` | The request is logged; goods are not yet returned |
| `Returned` | `refundRequestReturn` | Goods are physically received back |
| `Processed` | `refundRequestProcess` | Operator/seller has approved; ready to refund |
| `Refunded` | `refundRequestRefund` | Funds returned to customer; commission reversed in MPay |
| (approval; may issue additional charge) | `refundRequestApprove` | Approves a refund and optionally creates an additional charge (return shipping, restocking) when `Advanced Amendments` is enabled |

**`paymentReferences` on refund mutations:** refund mutations accept the same `paymentReferences: [{ paymentReference, amount }]` array as `orderCreate`, so MPay can match the reversal to the original tender. Use **positive** values on `refundRequestRefund` / `refundRequestApprove`; use **negative** values only on the lower-level `invoiceAmendmentUpdate`. See `payments-payouts.md` for the sign-convention table — wrong sign drifts the deposit reconciliation in the opposite direction.

**Cancellation (pre-shipment):** use the same RefundRequest flow with appropriate state — there is no separate "cancel" entity. The operator's commerce platform / OMS calls `refundRequestCreate` immediately upon cancellation; the goods state is essentially Returned (since they never shipped); Processed and Refunded follow as usual.

**Partial refunds:** RefundRequest carries `RefundRequestLineItem` children. Refund a subset of the Invoice's line items by including only those in the request.

**Additional charges on approval:** when approving a refund, the operator can attach a charge for return shipping or restocking. This issues a **separate, linked** invoice (e.g., `12345-1-CH`) — not an amendment to the original — for tax-compliance reasons in some jurisdictions. See `payments-payouts.md` for details. The charge is remitted to the seller, not the operator.

**Operator's PSP integration:** the actual money movement back to the customer happens in the operator's PSP (Stripe refund, Adyen refund, etc.). Marketplacer's `Refunded` state signals that MPay has reconciled the marketplace ledger; the PSP refund call is separate.

## Invoice Status Flags

Invoices carry a multi-flag `statusFlags` field rather than a single status enum. The flag set is documented in the operator-API how-tos; common flags include:

| Flag | Meaning |
|------|---------|
| `Ready` | Invoice is ready for fulfillment |
| `Awaiting Collection` | Click-and-collect order, not yet picked up |
| `Collected` | Click-and-collect order picked up |
| `Cancelled` | Invoice cancelled (via refund flow) |
| `Refunded` | All line items refunded |
| `Partially Refunded` | Some line items refunded |

For the canonical current list, consult the live docs at [api.marketplacer.com/docs/operator-api/examples/orders/](https://api.marketplacer.com/docs/operator-api/examples/orders/) — the flag set evolves.

Some flag transitions (notably `Ready` and `Mark Collected`) are documented as remaining **REST-only** on the legacy Seller API feature matrix. Operators that need to programmatically transition these flags may need to call the Legacy REST endpoint for those specific transitions; everything else stays on GraphQL.

## Invoice Annotations

Invoices support **annotations** — free-text operator notes that persist on the Invoice for audit and customer-service context. Examples: "customer rang to update address — confirmed with carrier", "expedited dispatch approved", "fraud review escalation #1234".

| Surface | Detail |
|---------|--------|
| Mutation | `invoiceAnnotationCreate` (verify against live schema) |
| Visibility | Operator-facing; not exposed on the storefront |
| Use case | Audit trail for human decisions that don't fit a status flag |

Annotations are not a substitute for `statusFlags` (machine-driven state) or `metadata` (display fields). They're for human prose. The OMS may want to mirror annotations from CS tickets onto the relevant Invoice for traceability.

## The Missing Order Webhook

**There is no `Order` event in the webhook event matrix.** No `OrderCreate`, `OrderUpdate`, `OrderDestroy`. Order-level changes propagate as:

- Order creation → an `Invoice` Create event per Invoice
- Order status change → `Invoice` Update event(s) and/or `Shipment` / `RefundRequest` events

**Anti-pattern:**
```graphql
# This subscription topic does not exist
webhook { events: ["order.create"] }
```

**Recommended:**
```graphql
# Subscribe to Invoice, Shipment, RefundRequest
webhook { events: [
  "invoice.create",
  "invoice.update",
  "shipment.create",
  "shipment.update",
  "refundrequest.create",
  "refundrequest.update",
  "refundrequest.refunded"
] }
```

In the receiver, treat the Invoice as the unit of work. Aggregate up to the Order in the consuming system if the UI needs an order-level view. Use the `Invoice.order.id` traversal in the webhook payload query to keep the Order ID available for the receiver.

## PII & Order Purging

GDPR / data-subject deletion requests are handled via a documented order-purge / PII-redaction flow. The mutation strips identifying fields from the Order while preserving the financial/audit record (Invoice totals, commission, payout history). The Order ID remains valid; the buyer details become anonymized placeholders.

**Defer to live docs** at the operator-API examples for the exact mutation name and field set — it's the kind of thing that should always be verified against current schema rather than implemented from memory.

## Checklist

Before shipping order/fulfillment code:

- [ ] Checkout flow is authorize → `orderCreate` → capture (not capture-then-create).
- [ ] `paymentReferences` is the array form with one `{paymentReference, amount}` entry per PSP tender (not a singular string).
- [ ] Line items use `BUY_ONLINE` / `CLICK_AND_COLLECT` correctly; the integration handles multiple Invoices per Order.
- [ ] Order's `externalIds` carries the commerce-platform order ID; each Invoice's `externalIds` carries the per-seller fulfillment ID.
- [ ] Code paths handle multi-seller orders (test with a 2+ seller cart, not just a 1-seller cart).
- [ ] Multi-store sellers route via `inventoryId`.
- [ ] Wholesale orders (if supported) classify the buyer and pick wholesale pricing at the cart layer; commission/tax model adjusted accordingly.
- [ ] Stock errors are terminal — no blind retries.
- [ ] Partial shipments are supported in the OMS-side model.
- [ ] Cancellation goes through RefundRequest, not a fictional cancel endpoint.
- [ ] Refund flow handles partial refunds via RefundRequestLineItem.
- [ ] Refund mutation sign conventions are correct (positive on `refundRequestRefund` / `refundRequestApprove`, negative on `invoiceAmendmentUpdate`).
- [ ] Webhook subscriptions cover Invoice, Shipment, RefundRequest — **not** Order.
- [ ] OMS aggregates Invoices into a customer-facing order view; Marketplacer is the source of truth for per-seller fulfillment, not for the customer order.
