# Subscription Data Model

Kibo Subscription Commerce has two decisions that quietly trip up integrators coming from Stripe Billing, Recharge, or Chargebee: **the Subscription is a template and each cycle creates a new Order**, and **there is no Plan entity** — configuration lives on product type attributes plus a per-cart-item `SubscriptionInfo` block. Internalize both before writing code.

## Table of Contents
- [The Two Load-Bearing Concepts](#the-two-load-bearing-concepts)
- [Entity Shape](#entity-shape)
- [Subscription vs Order](#subscription-vs-order)
- [The Six-State Lifecycle](#the-six-state-lifecycle)
- [Errored vs Failed](#errored-vs-failed)
- [Same-Frequency Consolidation, Different-Frequency Split](#same-frequency-consolidation-different-frequency-split)
- [Bundle Subscriptions](#bundle-subscriptions)
- [No Plan Entity — Where Configuration Actually Lives](#no-plan-entity--where-configuration-actually-lives)
- [Cart-Side `SubscriptionInfo`](#cart-side-subscriptioninfo)
- [API Surface](#api-surface)
- [Read-Modify-Write on PUT](#read-modify-write-on-put)
- [Event Topics](#event-topics)
- [Anti-Pattern / Recommended-Pattern Pairs](#anti-pattern--recommended-pattern-pairs)
- [Checklist](#checklist)

## The Two Load-Bearing Concepts

**1. The Subscription is a template; each cycle creates a new Order.**

Continuity orders are first-class Orders that flow through the standard Kibo OMS — inventory allocation, routing, fulfillment, payment capture, the lot. The Subscription holds the recurring relationship and the schedule. The Order holds the revenue, the line totals, the tax, the shipment.

Revenue lives on Orders. Lifecycle lives on Subscriptions. Any report that touches both must join across them. A naive `SUM(subscription.total)` is wrong by design — there is no subscription-side revenue field that aggregates across cycles.

**2. There is no Plan entity.**

People coming from Stripe Billing look for `/plans` and don't find it. Configuration lives in three places:

- **Product type attributes** (`Subscription Mode`, `Subscription Frequency`, `Trial Days`, `Trial Product Code`, etc.) — schema-level defaults.
- **Product-level overrides** — same attributes, set on the catalog item.
- **`SubscriptionInfo` on the cart item** — the per-purchase choice (frequency selected by the shopper, trial enabled, etc.).

If you go hunting for a `POST /plans` endpoint you will waste hours. There isn't one.

## Entity Shape

Documented Subscription fields (verify exact casing against the live OpenAPI):

| Field | Type | Notes |
|-------|------|-------|
| `id` | string | Subscription identifier; use for API calls |
| `subscriptionNumber` | int | Human-friendly number used in admin search |
| `customerAccountId` | int | Owning customer |
| `email` | string | Buyer email |
| `status` | enum | `Pending` \| `Active` \| `Paused` \| `Errored` \| `Failed` \| `Cancelled` |
| `currencyCode` | string | ISO 4217; set at creation, not mutable |
| `frequency` | object | `{ value: int, unit: "Day" \| "Week" \| "Month" \| "Year" }` |
| `nextOrderDate` | ISO 8601 | When the next continuity order will be cut |
| `items` | array | Line items with `product`, `quantity`, `fulfillmentMethod` |
| `fulfillmentInfo` | object | Shipping contact + `shippingMethodCode` |
| `payment` | object | Reference to a tokenized Card on the customer account |
| `attributes` | array | Custom attributes (scope: subscription-only OR order-and-subscription) |
| `installmentPlanCode` | string | Optional installment plan reference (separate concept; see `billing-dunning.md`) |

**`subscriptionNumber` vs `id`:** both surface in docs. The human-readable `subscriptionNumber` drives admin UI search; `id` drives API calls. Store both if you need bidirectional lookup; do not assume one is derivable from the other.

**`currencyCode` is set at creation.** There is no documented "switch currency" mutation. Treat it as immutable. Whether a single tenant supports multi-currency Subscriptions the same way Orders do is **unknown** — verify against the live tenant before building a multi-currency subscription flow.

## Subscription vs Order

```
                 Customer / Cart
                       |
                       v  (checkout with SubscriptionInfo.required = true)
                  Initial Order  ----> creates ---->  Subscription (Pending -> Active)
                                                            |
                                                            |  internal scheduler
                                                            |  (scans every ~30 min)
                                                            v
                                                       Continuity Order #1  ----> OMS
                                                            |
                                                            v
                                                       Continuity Order #2  ----> OMS
                                                            |
                                                            v
                                                            ...
```

The very first Order — the one placed at checkout — is the **initial subscription order**. It carries `orderType: "initialSubscription"` on the payment block. Continuity orders that follow are normal Orders linked back to the Subscription via subscription number.

**Reporting implication.** Any code that counts Subscriptions as the revenue unit is wrong. MRR is computed externally by summing continuity Orders in the period and filtering by `subscriptionNumber` (or the equivalent linkage field on the Order). Churn analysis joins Cancelled Subscriptions to the trailing N continuity Orders they generated.

**OMS implication.** Each continuity Order goes through the same fulfillment pipeline as a one-time Order. If the OMS has special handling for an order (fraud screening, manual review, fulfillment routing), continuity Orders hit it too. The Subscription does not bypass anything.

## The Six-State Lifecycle

```
Pending  ---->  Active  <---->  Paused
                  |
                  v
               Errored  ---->  Failed
                  |
                  v
              Cancelled (terminal)
```

| State | Meaning | Generates orders? |
|-------|---------|-------------------|
| `Pending` | Newly created, not yet validated/activated | No |
| `Active` | Generating continuity orders on schedule | Yes |
| `Paused` | Temporarily suspended (auto-reactivate after N cycles or manual) | No |
| `Errored` | Payment or processing problem — eligible for recycling retries | No (recycling retries the cycle Order) |
| `Failed` | Recycling exhausted; needs manual intervention | No |
| `Cancelled` | Terminal — no further orders, no reactivation | No |

The UI generally surfaces five states; `Errored` and `Failed` are distinct underneath. Treat them as distinct in code too — see the next section.

**Transitions worth noting:**

- `Pending -> Active` happens via successful initial-order checkout (or operator activation for offline-created subscriptions).
- `Active <-> Paused` is reversible; the next-order-date does not "catch up" on missed cycles when resumed.
- `Active -> Errored` happens on a failed capture for the cycle Order.
- `Errored -> Active` happens when payment recycling succeeds.
- `Errored -> Failed` happens when recycling exhausts the configured retry budget.
- `Cancelled` is terminal. There is **no documented "reactivate a Cancelled subscription" action.** Re-creation is the only path back, either via offline-order flow or storefront re-subscribe.

## Errored vs Failed

This is the single most load-bearing distinction in the lifecycle. Conflating them produces wrong dunning behavior and wrong involuntary-churn reporting.

| State | What it means | What you do |
|-------|---------------|-------------|
| `Errored` | A cycle Order's capture failed. Payment Recycling is retrying it on the configured schedule | Nothing automated — let recycling run. CSR tooling shows "retry pending" |
| `Failed` | Recycling exhausted the retry budget. No further automatic action | CSR contacts customer, updates payment method, manually reactivates |

`Errored` is recoverable without human intervention. `Failed` is not. Build CSR tooling that shows both views as separate buckets; build reports that separate involuntary churn (`Failed`) from voluntary churn (`Cancelled`).

**Anti-pattern:** treating `Failed` as a retry candidate. Recycling has already given up. Building an auto-retry on `Failed` charges the customer outside the configured policy and creates audit trail noise. See `billing-dunning.md` for the recycling configuration.

## Same-Frequency Consolidation, Different-Frequency Split

When a customer places a checkout with multiple subscribed items, Kibo materializes Subscriptions based on frequency and shipping address:

| Cart shape | Resulting Subscriptions |
|------------|-------------------------|
| Two items, same frequency, same shipping address | **One** Subscription with two line items |
| Two items, same frequency, different shipping addresses | **Two** Subscriptions |
| Two items, different frequencies | **Two** Subscriptions |

**Cart UX implication.** A shopper adding a monthly vitamin and a quarterly razor blade ends up with two Subscriptions for what they perceive as one transaction. They will see two pause buttons, two cancel buttons, two emails. The storefront should warn before checkout, or normalize frequency selections where possible.

**Reporting implication.** Cross-subscription customer reporting must aggregate by `customerAccountId`, not by `subscriptionNumber`. Counting "subscribers" as `COUNT(DISTINCT subscriptionNumber)` overcounts.

## Bundle Subscriptions

A single Subscription can carry multiple SKUs as line items. Configurable bundles use two product-type attributes to control behavior:

| Attribute | Effect |
|-----------|--------|
| `Split Extras in Shipments` | At shipment time, splits bundle pricing across the constituent shipments |
| `Split Extras in Subscriptions` | Flattens a configurable bundle into separate Subscription line items |

Bundle subscriptions have **per-line fulfillment semantics** — each line item carries its own `fulfillmentMethod`. A bundle with one shippable item and one digital item will route through OMS as a mixed-fulfillment Order each cycle.

When modifying a bundle subscription:

- Adding/removing a line item triggers a reprice of the next continuity Order (not the current one — Kibo has no proration engine).
- Frequency change is constrained to frequencies supported by **every** item on the subscription.
- A bundle whose constituent products have different `Subscription Frequency` allowed-lists will refuse a frequency change that violates any of them.

## No Plan Entity — Where Configuration Actually Lives

Three configuration layers, top-down:

**1. Product type attributes** (System -> Schema -> Product Types):

| Attribute | Purpose |
|-----------|---------|
| `Subscription Mode` | `SubscriptionOnly` or `Both` (subscription + one-time purchase allowed) |
| `Subscription Frequency` | Multi-select of allowed frequencies for products of this type |
| `Trial Days` | Trial duration (1-365) |
| `Trial Product Code` | Substitute product offered during trial |
| `Trial Product Variation Code` | Substitute variation; requires Trial Product Code |
| `Split Extras in Shipments` | Bundle-pricing-at-shipment toggle |
| `Split Extras in Subscriptions` | Bundle-flattening toggle |

**2. Product-level overrides** (Main -> Catalog -> Products -> Properties): the same attributes, set per product.

**3. Cart-item `SubscriptionInfo`** (per checkout): the shopper's actual choice — frequency selected from the allowed list, trial enabled or not.

**Frequency validation:**

| Unit | Valid range |
|------|-------------|
| `Day` | 1-365 |
| `Week` | 1-52 |
| `Month` | Calendar-preserving (1 Month preserves day-of-month) |
| `Year` | Calendar-preserving |

**Gotcha:** `1 Month` and `30 Days` are different. `1 Month` preserves day-of-month across boundaries; `30 Days` is exactly 30 days. Pick one deliberately. Out-of-range values do not surface validation errors on the Product Attributes admin page — they surface at add-to-cart time.

**Fixed-term vs evergreen.** The research did not surface a first-class "fixed-term" field on the Subscription. Kibo subscriptions are evergreen by default. "Fixed term" is approximated by either:

- An **Installment Plan** (`installmentPlanCode`) for a fixed payment count — see `billing-dunning.md`. Installments are per-order, not per-subscription, and do not roll forward.
- Operator-side automation that cancels the Subscription after N continuity Orders.

Whether a dedicated fixed-term enum exists on the Subscription resource is **unknown** — verify against the live OpenAPI if you need it.

## Cart-Side `SubscriptionInfo`

The bridge from "regular cart item" to "subscribed cart item":

```
PUT /commerce/checkouts/{checkoutId}/items/{itemId}/subscriptionInfo
```

Body:

```json
{
  "required": true,
  "frequency": { "unit": "Month", "value": 1 },
  "trial": {
    "enabled": true,
    "duration": 30,
    "substituteProductCode": "TRIAL-SKU",
    "substituteProductQuantity": 1,
    "substituteVariationProductCode": null
  }
}
```

`required: true` flips the line item from one-time to subscribed. The Subscription itself is then materialized by the order-placement flow — you do not call `POST /commerce/subscriptions` from the storefront for a normal checkout. That endpoint exists for offline / CSR / import flows.

**Trial mechanics.** When `trial.enabled` is true and `substituteProductCode` is set, the initial Order ships the substitute product. The first full-price continuity Order is cut `trial.duration` days after the initial Order. See `billing-dunning.md` for the exact first-charge timing.

## API Surface

| Operation | Method | Path |
|-----------|--------|------|
| Attach subscription info to a cart item | PUT | `/commerce/checkouts/{checkoutId}/items/{itemId}/subscriptionInfo` |
| Create (offline / import / CSR) | POST | `/commerce/subscriptions` |
| Retrieve | GET | `/commerce/subscriptions/{subscriptionId}` |
| Update (read-modify-write) | PUT | `/commerce/subscriptions/{subscriptionId}` |
| Order now (cut a continuity order immediately) | POST | `/commerce/subscriptions/{subscriptionId}/orderNow` |
| Change status | (status endpoint) | Active / Paused / Cancelled |
| List cancellation reasons | GET | `/commerce/subscriptions/reasons` |

**Unknown — verify against the live OpenAPI:** exact REST paths for the `pause`, `skip`, and `reactivate` action endpoints. The SDK surfaces them as named methods (`updateSubscriptionStatus`, `skipSubscription`, etc.); the underlying paths are not consistently published outside the OpenAPI viewer. The two reliable patterns:

1. `PUT /commerce/subscriptions/{id}` with a modified `status` field (read-modify-write).
2. Dedicated action sub-paths under `/commerce/subscriptions/{id}/...` — confirm the exact path before coding.

Auth: same OAuth 2.0 / client-credentials flow as the rest of Kibo Commerce. `tenantId`, `siteId`, `clientId`, `sharedSecret`, `authHost`. No subscription-specific scope.

## Read-Modify-Write on PUT

`PUT /commerce/subscriptions/{id}` replaces the resource. **Omitted fields null out.** This is the single most common source of subscription bugs — code that builds a partial PUT body wipes whatever it didn't include.

**Anti-pattern:**

```typescript
// Wrong — sends only the frequency; nulls everything else on the subscription
await fetch(`/commerce/subscriptions/${id}`, {
  method: 'PUT',
  body: JSON.stringify({
    frequency: { unit: 'Month', value: 2 },
  }),
});
```

**Recommended:**

```typescript
// GET -> mutate -> PUT the whole payload
const current = await getSubscription(id);
const updated = {
  ...current,
  frequency: { unit: 'Month', value: 2 },
};
await fetch(`/commerce/subscriptions/${id}`, {
  method: 'PUT',
  body: JSON.stringify(updated),
});
```

The failure mode here is silent — the API accepts the partial body and the Subscription comes back from the next GET with most of its fields blanked. Compare to commercetools, where version-mismatch produces an explicit 409. Kibo gives you no such safety net.

## Event Topics

Subscription-related event topics:

| Topic | Fires when |
|-------|-----------|
| `subscription.statuschanged` | Status moves to Active / Paused / Cancelled / Errored |
| `subscription.activated` | Subscription becomes Active |
| `subscription.cancelled` | Subscription is Cancelled |
| `subscription.errored` | Subscription enters Errored |
| `subscription.paused` | Subscription is Paused |
| `subscription.paymentupdated` | Payment method changed |

**Unknown:** whether a `subscription.created` topic exists distinct from `subscription.activated`. The Event Notifications catalog does not list it. If your design needs a "subscription was created but not yet active" signal, verify in the live tenant or treat `Pending -> Active` via `subscription.activated` as the canonical creation signal.

**Event envelope** (standard Kibo shape):

```json
{
  "eventID": "uuid",
  "topic": "subscription.statuschanged",
  "entityID": "subscription-id",
  "timestamp": "2026-01-15T10:30:00Z",
  "correlationID": "req-uuid",
  "isTest": false,
  "extendedProperties": [{ "key": "...", "value": "..." }]
}
```

The payload carries only entity IDs. Receivers fetch full state from `GET /commerce/subscriptions/{id}`. Receiver must `200 OK` within 45 seconds. Retry schedule: 5 min, then 1 hr, then 24 hrs. Events expire after 14 days.

**Anti-pattern:** polling `GET /commerce/subscriptions/{id}` on a timer to detect status changes. Subscribe to `subscription.statuschanged` and `subscription.paymentupdated`; let the receiver fetch detail on demand.

## Anti-Pattern / Recommended-Pattern Pairs

### Treating the Subscription as the revenue unit

```typescript
// Wrong — Subscription has no per-cycle revenue field
const mrr = subscriptions.reduce((sum, s) => sum + s.total, 0);
```

```typescript
// Recommended — sum continuity Orders for the period
const orders = await getOrders({
  createdAfter: periodStart,
  createdBefore: periodEnd,
  filter: 'orderType eq "Continuity"', // verify exact filter syntax against the live OAS
});
const mrr = orders.reduce((sum, o) => sum + o.total, 0);
```

### Hunting for a Plan API

```typescript
// Wrong — there is no Plan resource
const plan = await fetch('/commerce/subscriptions/plans/MONTHLY_BOX');
```

```typescript
// Recommended — configuration lives on product type attributes + cart-item SubscriptionInfo
const product = await getProduct('MONTHLY_BOX');
const allowedFrequencies = product.properties.find(p => p.attributeFQN === 'tenant~subscription-frequency');
// Then on cart:
await fetch(`/commerce/checkouts/${checkoutId}/items/${itemId}/subscriptionInfo`, {
  method: 'PUT',
  body: JSON.stringify({
    required: true,
    frequency: { unit: 'Month', value: 1 },
  }),
});
```

### Partial PUT updates

See [Read-Modify-Write on PUT](#read-modify-write-on-put).

### Conflating same-frequency / different-frequency cart items

```typescript
// Wrong — assumes one cart -> one Subscription
const subscription = await getSubscriptionForOrder(orderId);
```

```typescript
// Recommended — query by customer + order, expect N Subscriptions
const subscriptions = await fetch(
  `/commerce/subscriptions?filter=customerAccountId eq ${customerId} and parentOrderNumber eq ${orderNumber}`,
);
// Iterate.
```

### Reactivating a Cancelled subscription

```typescript
// Wrong — Cancelled is terminal
await updateSubscriptionStatus(id, 'Active');
```

```typescript
// Recommended — re-create via offline order or storefront re-subscribe
await fetch('/commerce/subscriptions', {
  method: 'POST',
  body: JSON.stringify({
    customerAccountId: oldSubscription.customerAccountId,
    items: oldSubscription.items,
    frequency: oldSubscription.frequency,
    // ... full payload
  }),
});
```

## Checklist

Before going live with a Kibo Subscriptions integration:

- [ ] Revenue reporting joins continuity Orders to Subscriptions, not the other way round.
- [ ] No code references a `/plans` endpoint or assumes a Plan entity exists.
- [ ] Cart UX warns shoppers when their cart will materialize into multiple Subscriptions (different-frequency case).
- [ ] CSR tooling separates `Errored` (retrying) from `Failed` (manual-intervention) buckets.
- [ ] Involuntary-churn reporting (`Failed`) is separate from voluntary churn (`Cancelled`).
- [ ] All `PUT /commerce/subscriptions/{id}` calls do GET -> mutate -> PUT, not partial bodies.
- [ ] No code attempts to reactivate a `Cancelled` Subscription.
- [ ] Status changes drive on `subscription.statuschanged` event, not polling.
- [ ] Event receiver `200 OK`s within 45 seconds; full state fetched lazily from the API.
- [ ] Customer aggregation queries use `customerAccountId`, not `subscriptionNumber`, as the join key.
- [ ] Bundle subscriptions' per-line fulfillment is modeled in OMS, not flattened to "one fulfillment per cycle".
- [ ] Frequency choice (`Month` vs `Day`) matches the desired calendar semantics — `1 Month` and `30 Days` are not the same.
