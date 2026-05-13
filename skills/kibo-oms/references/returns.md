# Returns & Refunds

Returns are a separate entity in Kibo with their own lifecycle — **not an order edit**. Modeling them as `order.update()` produces stuck states, miscounted inventory, and refund records that don't reconcile against the original payment. On OMS-only deployments, refunds add another twist: Kibo records the credit decision but doesn't directly call the PSP.

## Table of Contents
- [Returns Are Not Order Edits](#returns-are-not-order-edits)
- [The Return State Machine](#the-return-state-machine)
- [Return Rollup Statuses](#return-rollup-statuses)
- [RMA Flow End-to-End](#rma-flow-end-to-end)
- [Returns API Surface](#returns-api-surface)
- [Refund Mechanics](#refund-mechanics)
- [Cancellation vs Return](#cancellation-vs-return)
- [Partial Returns](#partial-returns)
- [Replacement Orders](#replacement-orders)
- [Disposition and Inventory Impact](#disposition-and-inventory-impact)
- [Webhook Events](#webhook-events)
- [Anti-Patterns](#anti-patterns)
- [Checklist](#checklist)

## Returns Are Not Order Edits

A Return in Kibo is its own first-class entity with:

- Its own ID and state machine (`Created → Authorized → Closed`).
- Its own line items (subset of the original order's items, with return quantities).
- Its own payment actions (credits, store credit, check refunds).
- Its own routing for the inbound shipment (the RMA shipping label).
- Its own disposition logic (restock, scrap, refurbish).
- Its own webhook events (`return.opened`, `return.authorized`, `return.closed`).

**Modeling returns as `order.update()` is the CRITICAL anti-pattern.** The order record stays paid-and-fulfilled (because it was); the return record carries the reversal. Conflating them produces:

- Orders stuck in `Customer Care` rollup because partial-return state can't be expressed on the order alone.
- Inventory restocks tied to the wrong audit trail.
- Refund records that don't reconcile against the original `gatewayTransactionId`.
- Reporting that double-counts revenue (order says paid; return says credited; both at the order level).

```typescript
// Wrong — treating a return as an order edit
await api.put(`/commerce/orders/${orderId}`, {
  items: order.items.map(i =>
    i.lineId === returnLineId ? { ...i, quantity: 0 } : i
  ),
  status: 'Refunded',
});

// Recommended — create a Return entity referencing the original order's items
await api.post('/commerce/returns', {
  originalOrderId: orderId,
  returnItems: [
    { orderItemId: returnLineId, quantity: 1, reasonCode: 'WrongSize' },
  ],
});
```

Source: <https://docs.kibocommerce.com/concept-guides/returns-and-reverse-logistics>

## The Return State Machine

Source: <https://docs.kibocommerce.com/help/return-statuses>

Modern flow — three states:

```
            ┌──────────┐  authorize    ┌────────────┐  close   ┌────────┐
init ──────►│ Created  │ ─────────────►│ Authorized │ ────────►│ Closed │
            └──────────┘               └────────────┘          └────────┘
                  │ cancel/reject              │ cancel/reject
                  ▼                            ▼
            ┌────────────────────────┐   ┌────────────────────────┐
            │ Cancelled / Rejected   │   │ Cancelled / Rejected   │
            └────────────────────────┘   └────────────────────────┘
```

| State | Meaning |
|-------|---------|
| `Created` | RMA initiated; customer or operator has registered the return intent |
| `Authorized` | Approved — return label issued, item is in flight, or item is at the receiving location |
| `Closed` | Disposition complete, refunds settled, replacement (if any) shipped |
| `Cancelled` | Voluntary cancellation by customer or operator before disposition |
| `Rejected` | Operator-side rejection (e.g., outside return window, item ineligible) |

**Legacy intermediate states** (`Await`, `Receive`, `Restock`, `Refund`, `Ship`) still exist on tenants that have them enabled, but the modern path is direct `Authorized → Closed`. Code that loops over the legacy states explicitly breaks on modern tenants and vice versa — check the active state set on the tenant's configuration rather than hard-coding either path.

## Return Rollup Statuses

Two separate axes:

| Axis | Values |
|------|--------|
| **Return Refund Status** | `Partially Refunded`, `Fully Refunded` |
| **Order Return Status** (rollup on the parent order) | `None`, `In Progress`, `Order Partially Returned`, `Order Fully Returned` |

The Order Return Status is the rollup view from the order's perspective. An order with 3 line items and a return for 1 of them is `Order Partially Returned`. An order with full quantity returned across all lines is `Order Fully Returned`. These rollups are derived from the Return entities — never written directly on the order.

## RMA Flow End-to-End

```
┌───────────────────┐   create    ┌──────────────────┐  authorize  ┌───────────────────┐
│ Customer / CSR    │ ──────────► │ Return: Created  │ ──────────► │ Return: Authorized │
│ initiates return  │             └──────────────────┘             └───────────────────┘
└───────────────────┘                                                       │
                                                                            │ ship inbound
                                                                            ▼
                                                                   ┌───────────────────┐
                                                                   │ Item received at  │
                                                                   │ disposition loc.  │
                                                                   └───────────────────┘
                                                                            │
                                                       ┌────────────────────┼──────────────┐
                                                       │ Good               │ Bad         │ Refurb
                                                       ▼                    ▼             ▼
                                              ┌───────────────┐   ┌───────────────┐  ┌───────────────┐
                                              │ Restock       │   │ Write-off     │  │ Restock as    │
                                              │ inventory     │   │ no inventory  │  │ Refurbished   │
                                              └───────────────┘   └───────────────┘  └───────────────┘
                                                       │                    │             │
                                                       └──────────┬─────────┴─────────────┘
                                                                  ▼
                                                       ┌────────────────────┐  refund &  ┌──────────┐
                                                       │ Disposition done   │ ─────────► │ Closed   │
                                                       └────────────────────┘            └──────────┘
```

### Initiation

Customer-side (via the source platform's storefront return UI, which calls Kibo's Return API) or operator-side (CSR creates the RMA in Kibo Admin). Both paths post to `POST /commerce/returns` with the items being returned.

### Authorization

`PerformReturnActions` with `actionName=Authorize`. Who authorizes:

- **Operator-side manual approval** — CSR or returns team reviews and clicks Authorize.
- **Automated rules** — tenant can configure auto-authorize for in-window returns, specific reason codes, or specific item categories. Verify against your tenant's configuration; auto-authorize behavior is per-instance.

Authorization is when the return label is issued (if return shipping is required) and the customer is notified.

### Receipt at the Location

When the returned item physically arrives, the receiving location updates the Return entity. The location is typically the location from which the item shipped, but reverse-logistics routing can override (e.g., all returns go to a centralized reverse-logistics center).

### Disposition

The receiving operator marks each returned item with a disposition — `Good`, `Bad`, `Refurbished`, `Liquidation`. The disposition drives the inventory effect; see [Disposition and Inventory Impact](#disposition-and-inventory-impact).

### Close

`PerformReturnActions` with `actionName=Close`. Closes the return — all refunds settled, replacement (if any) created and routed, disposition recorded. **A return cannot Close until child replacement orders close** (a built-in constraint).

## Returns API Surface

Sources: <https://docs.kibocommerce.com/help/returns-api-overview>, <https://docs.kibocommerce.com/help/refund-a-return>

| Endpoint | Purpose |
|----------|---------|
| `POST /commerce/returns` (`CreateReturn`) | Initiate RMA (carries `returnItems[]` referencing original order's items) |
| `PerformReturnActions` with `actionName=Authorize` | Authorize the RMA |
| `PerformReturnActions` with `actionName=Close` | Close (after refunds & replacements settled) |
| `UpdateReturn` | Modify quantities, eligibility for restock |
| `RestockReturnItems` | Put condition-OK items back into inventory |
| `GetPayments` | Lookup the order's payments |
| `PerformPaymentActionForReturn` | **Credit an existing payment** (refund to original tender) |
| `CreatePaymentActionForReturn` | Issue **store credit** or **check** (new tender) |
| `CreateReturnShippingOrder` | Create the replacement order linked to this RMA |
| `GetRmaLabels` | Get carrier return label |
| **Disposition API** (if reverse logistics enabled) | Mark items handled per location |

## Refund Mechanics

**Kibo does NOT directly call the PSP.** It records the financial action (`Credit`, `Void`) against the stored Payment record. The actual money movement flows through whatever payment integration is configured at the site level. Two patterns:

| Pattern | Behavior |
|---------|----------|
| **Native Kibo gateway integration** (Stripe, Adyen, Cybersource, PayPal) | Kibo's payment connector translates the Credit action into a PSP refund API call. Refund-on-Kibo == refund-at-PSP. |
| **External payment captured pre-import** (OMS-only mode) | Kibo records the Credit; the source platform / external PSP integration is responsible for the actual refund. **The OMS-only integration must listen for `payment.credited` and trigger its own PSP refund.** |

### OMS-Only Refund Flow

```
┌────────────────────┐  refund click   ┌──────────────────┐
│ Kibo CSR / Admin   │ ──────────────► │ Kibo records     │
└────────────────────┘                 │ payment.credited │
                                       └──────────────────┘
                                                 │ webhook
                                                 ▼
                                       ┌──────────────────┐
                                       │ Integration      │
                                       │ listener         │
                                       └──────────────────┘
                                                 │
                                                 ▼
                                       ┌──────────────────┐  refund API  ┌─────────┐
                                       │ Shopify / SFCC   │ ───────────► │ PSP     │
                                       │ refund call      │              │ refund  │
                                       └──────────────────┘              └─────────┘
```

In OMS-only deployments fronted by Shopify, the typical pattern: Kibo CSR clicks "Refund" → Kibo records `payment.credited` event → integration listener calls Shopify's refund API (which then triggers Shopify's PSP refund). The OMS is the system of record for the **decision**; the source platform is the system of record for the **transaction**.

**Anti-pattern:**

```typescript
// Wrong — assumes Kibo's "refunded" state means money has moved
function onReturnClosed(returnId: string) {
  notifyCustomer(returnId, 'Your refund has been processed');
}

// Recommended — wait for the source platform's confirmation
function onReturnClosed(returnId: string) {
  // Kibo recorded the credit; the source-platform refund is in flight
  notifyCustomer(returnId, 'Your refund is being processed');
}
function onShopifyRefundCompleted(refundId: string) {
  // Now the money has actually moved
  notifyCustomer(refundId, 'Your refund has been processed');
}
```

### Refund Methods

| Method | API call | When |
|--------|----------|------|
| **Credit to original tender** | `PerformPaymentActionForReturn` | Default — refund goes back to the card / wallet that paid |
| **Store credit** | `CreatePaymentActionForReturn` (new tender) | Customer opted for credit instead of refund |
| **Check** | `CreatePaymentActionForReturn` (new tender) | Refund-by-check (typically B2B, expired card cases) |
| **Combination** | Multiple calls | Partial credit, partial store credit |

## Cancellation vs Return

Two distinct flows for "I don't want this anymore":

| Flow | When | Mechanism |
|------|------|-----------|
| **Cancellation** | **Pre-fulfillment** — order accepted but shipment not yet completed | `PUT /commerce/orders/{id}/canceled` or per-shipment `PUT /commerce/shipments/{id}/canceled`. Releases allocated inventory; voids payment (or credits if captured). |
| **Return** | **Post-fulfillment** — item has shipped (or pickup has been collected) | `POST /commerce/returns`. Creates an RMA entity with its own lifecycle. |

Code that uses `cancel` for a post-ship "I don't want this" creates dangling shipment records and inventory that doesn't reconcile. The decision boundary is `shipment.state == Complete` — once a shipment is complete, the path forward is Return, not Cancel.

```typescript
// Branch on the shipment state, not on the customer's wording
async function customerWantsToReturn(orderId: string, lineId: string) {
  const order = await api.get(`/commerce/orders/${orderId}`);
  const shipment = order.shipments.find(s => s.items.some(i => i.id === lineId));

  if (shipment.state === 'Complete') {
    // Post-fulfillment: Return
    return api.post('/commerce/returns', { originalOrderId: orderId, returnItems: [/* ... */] });
  } else {
    // Pre-fulfillment: Cancel
    return api.put(`/commerce/shipments/${shipment.shipmentNumber}/canceled`);
  }
}
```

## Partial Returns

A Return doesn't have to cover the whole order. The `returnItems[]` array can reference any subset of the original order's items, each with its own quantity (≤ ordered quantity).

```json
{
  "originalOrderId": "ORD-789",
  "returnItems": [
    { "orderItemId": "LINE-A", "quantity": 1, "reasonCode": "WrongSize" },
    { "orderItemId": "LINE-B", "quantity": 0 },
    { "orderItemId": "LINE-C", "quantity": 2, "reasonCode": "Defective" }
  ]
}
```

The parent order's rollup becomes `Order Partially Returned` until the remaining lines are returned (which may never happen — partial-return is a terminal state for the unreturned portion). Refund mechanics also become partial: the credit is for the dollar amount of the returned items only, with tax / shipping / discount apportioned correctly (Kibo handles the apportionment; verify against the live API response).

## Replacement Orders

`CreateReturnShippingOrder` creates a **separate child order** for the replacement, linked to the parent return:

```
Original order: ORD-789  (Customer bought a red shirt, size M)
  └─ Return: RMA-456     (Customer is returning the size M)
       └─ Replacement order: ORD-790  (Same product, size L)
```

The replacement is created in a Paid state (Kibo carries the credit from the return into the replacement), routed through standard order routing, and fulfilled normally. **The parent return cannot Close until child replacement orders close** — a built-in constraint that prevents "I sent the customer the replacement but never closed the original return" data drift.

## Disposition and Inventory Impact

When Reverse Logistics is enabled, returned items have a disposition outcome that drives where they physically go and how inventory is affected:

| Disposition | Inventory effect |
|-------------|------------------|
| **Good** | Restock at the receiving location's `On Hand` (incrementing the `(SKU × Location)` record) |
| **Bad / Damaged** | Write off — no inventory restock |
| **Refurbished** | Restock with `condition=Refurbished` — separate inventory bucket from new stock |
| **Liquidation** | Move to a liquidation location (typically a non-customer-facing inventory pool) |

The disposition is recorded via the Disposition API on the receiving location. **The inventory restock is what re-enables routing to fulfill new orders from that unit** — until disposition is set and inventory adjusted, the returned item is in limbo (received but not sellable). See `inventory.md` for the underlying `Adjust` API mechanics.

### Q1 2026 Before & After Actions for Reverse Logistics API

Q1 2026 release added customization hooks at the return-routing engine boundaries — operators inject custom code to enforce vendor-specific disposition or route returns back to the original fulfillment location without bespoke development. Surface details: **unknown — verify against your instance / Kibo support.**

URL: <https://kibocommerce.com/press-events/kibo-product-innovations-reverse-logistics-b2b-agentic-commerce/>

## Webhook Events

| Topic | Fires on |
|-------|----------|
| `return.opened` | New return created (`Created` state) |
| `return.authorized` | Return moves to `Authorized` |
| `return.updated` | Mid-lifecycle update (disposition recorded, refund applied) |
| `return.closed` | Return reaches `Closed` |
| `return.cancelled` | Return cancelled |
| `return.rejected` | Return rejected |
| `payment.credited` | Credit recorded against the original payment (refund decision) |
| `payment.refunded` | Refund settled (when the integrated PSP confirms) |

In OMS-only mode, **`payment.credited` is the trigger for the integration to call the source platform's refund API.** `payment.refunded` fires when the integration's downstream PSP confirms — and is the signal to notify the customer the refund has actually settled.

## Anti-Patterns

### Modeling Returns as Order Edits

The CRITICAL anti-pattern. Returns are separate entities with their own state machine, audit trail, and refund records. `order.update()` doesn't carry the return's lifecycle, breaks inventory restock audit, and produces orders stuck in `Customer Care` for partial-return cases.

### Using `Cancel` Post-Fulfillment

`Cancel` is for pre-fulfillment changes. Once a shipment is complete, the customer's "I don't want this" path is a Return. Branching on `shipment.state == Complete` is the correct decision boundary.

### Treating Kibo's "Refunded" State as Customer-Side Authoritative

In OMS-only mode, Kibo records the credit decision; the source-platform PSP integration moves the money. Customer notifications "Your refund has been processed" should fire on the source-platform refund confirmation, not on `return.closed`.

### Looping Over Legacy Intermediate States

Tenants on the modern flow go `Created → Authorized → Closed` directly. Code that hard-codes `Await → Receive → Restock → Refund → Ship` breaks on modern tenants. Check the tenant's active state set rather than hard-coding either path.

### Auto-Closing Returns Before Replacement Ships

Kibo prevents this (the parent return can't Close until child replacement orders close), but custom workflows that bypass the API constraint produce orphan replacement orders. Always use `PerformReturnActions actionName=Close` rather than direct state writes.

### Refund Without Reading the Original Payment

`PerformPaymentActionForReturn` requires the original `paymentId`. Skipping `GetPayments` to find it and instead creating a new payment action with `CreatePaymentActionForReturn` issues a **separate** refund tender (store credit / check) instead of crediting the original card. Customer support tickets follow.

### Conflating Partial-Return Tax and Shipping Apportionment

Kibo apportions tax / shipping / discount across return lines automatically. Hand-rolling the apportionment in the integration produces refund amounts that don't match Kibo's record, which then doesn't match the PSP's record. Use Kibo's computed refund amount.

### Skipping Disposition

A return that reaches Authorized but never gets disposition stays in limbo: received but not sellable. Inventory effect doesn't apply. Always record disposition (even `Bad` / `Write-off`) to close the loop.

### Hard-Coding Reason Codes

Tenant returns-reason codes are configurable; don't hard-code `"WrongSize"`, `"Defective"`, etc., in integration logic. Read the configured reason-code list at integration time.

## Checklist

Before shipping returns code:

- [ ] Returns are modeled as a separate entity via `POST /commerce/returns`, never as `order.update()`.
- [ ] Branching between Cancel (pre-fulfillment) and Return (post-fulfillment) keys on `shipment.state == Complete`.
- [ ] Customer notifications for refund completion fire on the source-platform refund confirmation, not on Kibo's `return.closed`.
- [ ] Integration listener subscribed to `payment.credited` and triggers the source-platform refund API.
- [ ] State-machine handling tolerates both legacy intermediate states and modern direct-to-Closed flows (or explicitly targets one based on tenant config).
- [ ] Replacement orders flow through `CreateReturnShippingOrder`, not via manual order creation.
- [ ] Disposition is set on every return that reaches Authorized (even write-offs).
- [ ] Inventory restock follows disposition — `Good` increments On Hand at the receiving location; `Refurbished` goes to a separate `condition` bucket; `Bad` writes off.
- [ ] Refund method choice (credit to original tender vs store credit vs check) is explicit in the API call.
- [ ] `PerformPaymentActionForReturn` is used for credits to original tender; `CreatePaymentActionForReturn` is reserved for new-tender refunds (store credit, check).
- [ ] Return reason codes read from tenant config, not hard-coded.
- [ ] Order rollup `Order Partially Returned` surfaced in operational reporting.
- [ ] Webhook subscription includes `return.*` and `payment.credited` / `payment.refunded`.
