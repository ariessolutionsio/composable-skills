# Plans, Frequencies, and Trials

Kibo Subscription Commerce does not have a Plan entity. Configuration lives on product type attributes, optional product-level overrides, and the per-cart-item `SubscriptionInfo` block applied at checkout. Anyone arriving from Stripe Billing, Recharge, or Chargebee will look for `/plans` and waste hours; this file is here to short-circuit that.

## Table of Contents
- [There Is No Plan Entity](#there-is-no-plan-entity)
- [The Three Configuration Layers](#the-three-configuration-layers)
- [Product Type Attributes](#product-type-attributes)
- [Frequencies: Standard, Custom, and the Calendar Trap](#frequencies-standard-custom-and-the-calendar-trap)
- [Trial Periods and First-Charge Timing](#trial-periods-and-first-charge-timing)
- [Fixed-Term vs Evergreen](#fixed-term-vs-evergreen)
- [Bundle Subscriptions](#bundle-subscriptions)
- [Plan-Level vs Subscription-Level Changes](#plan-level-vs-subscription-level-changes)
- [Cart-Side `SubscriptionInfo`](#cart-side-subscriptioninfo)
- [Anti-Pattern / Recommended-Pattern Pairs](#anti-pattern--recommended-pattern-pairs)
- [Checklist](#checklist)

## There Is No Plan Entity

There is no `Plan` resource. There is no `POST /plans` endpoint. There is no "plan ID" attached to a Subscription. If you go searching for one you will not find one.

Configuration that other platforms put on a Plan resource — allowed frequencies, trial duration, substitute SKU, mode (subscribable / one-time / both) — lives on the **product type** and is overridable at the **product** level. The shopper's runtime choice (frequency, trial enabled) lives on the cart item's `SubscriptionInfo` block. The Subscription itself, once materialized, carries a snapshot of those choices (`frequency`, items, etc.) but no link back to a Plan record because there isn't one.

This has practical consequences:

- "Change the price for all subscribers on the Monthly Box plan" is a product-level price change, not a plan mutation. Effects propagate through the next continuity-Order reprice (Kibo recomputes prices per cycle).
- "List all subscribers on the Monthly Box plan" is a query against Subscriptions filtered by the product's SKU and `frequency`, not by plan ID.
- "Create a new plan" means adding a new product (or new product type) with the appropriate subscription attributes. There is no "create plan" operation distinct from product creation.

See `subscription-model.md` for the cart-side shape; this file covers the configuration that drives what shows up on the cart.

## The Three Configuration Layers

```
+-----------------------------------+
| 1. Product Type (schema-level)    |  Attribute defaults across all products of this type
|    System -> Schema -> Product    |
|    Types                          |
+-----------------------------------+
              |
              v
+-----------------------------------+
| 2. Product (catalog item)         |  Overrides for a specific product
|    Main -> Catalog -> Products    |
|    -> Properties                  |
+-----------------------------------+
              |
              v
+-----------------------------------+
| 3. Cart item SubscriptionInfo     |  Shopper's actual choice at checkout
|    PUT .../subscriptionInfo       |
+-----------------------------------+
              |
              v
        Materialized Subscription
        (snapshot of the choice at order placement)
```

Layer 1 sets defaults. Layer 2 overrides per product. Layer 3 is the shopper's choice for this purchase, constrained to what layers 1 and 2 allow.

Editing layer 1 or layer 2 affects **all future subscribers** to that product. It does **not** retroactively edit existing Subscriptions — those are already materialized and carry their own snapshot. To change an existing Subscription, mutate the Subscription resource directly (see `modifications.md`).

## Product Type Attributes

Configured at **System -> Schema -> Product Attributes** and assigned to product types at **System -> Schema -> Product Types**.

| Attribute | Purpose |
|-----------|---------|
| `Subscription Mode` | `SubscriptionOnly` (subscription-only purchase) or `Both` (subscription + one-time purchase allowed) |
| `Subscription Frequency` | Multi-select of allowed frequencies for products of this type |
| `Trial Days` | Trial duration (1-365) |
| `Trial Product Code` | Substitute product offered during trial |
| `Trial Product Variation Code` | Substitute variation; requires `Trial Product Code` |
| `Split Extras in Shipments` | For configurable bundles — splits bundle pricing at shipment |
| `Split Extras in Subscriptions` | Flattens a bundle into separate Subscription line items |

Each attribute is either set on the product type (applies to all products of that type) or overridden on the product (applies to that one product). The product-level value, when present, wins.

**Validation surfaces at add-to-cart, not at attribute edit.** Out-of-range values configured on the Product Attributes admin page do not raise validation errors there. The error appears when a shopper tries to add the product to the cart with the offending configuration. Audit attribute values against the unit ranges below before shipping a new product.

Source: https://docs.kibocommerce.com/help/configure-subscriptions

## Frequencies: Standard, Custom, and the Calendar Trap

Standard frequencies enabled per product (via `Subscription Frequency` multi-select): weekly, bi-weekly, monthly, quarterly, semi-annual, annual.

Custom frequencies use an integer + unit:

| Unit | Valid range | Semantics |
|------|-------------|-----------|
| `Day` | 1-365 | Exact day count |
| `Week` | 1-52 | 7 * value days |
| `Month` | (calendar-preserving) | Preserves day-of-month across boundaries |
| `Year` | (calendar-preserving) | Preserves month + day across boundaries |

Frequency is expressed on the cart as `{ unit, value }`:

```json
{ "unit": "Month", "value": 1 }
{ "unit": "Week", "value": 2 }
{ "unit": "Month", "value": 3 }
{ "unit": "Day", "value": 45 }
```

**Calendar trap.** `{ unit: "Month", value: 1 }` is **not** the same as `{ unit: "Day", value: 30 }`.

- `1 Month` preserves day-of-month: a subscription created on the 15th renews on the 15th of each subsequent month. February rolls to the 28th/29th and then back to the 15th in March.
- `30 Days` is exactly 30 days: a subscription created on Jan 15 renews on Feb 14, then Mar 16, drifting forward through the calendar.

Pick the one that matches what the customer expects. "Monthly" almost always means `Month`, not `30 Days`. Subscription boxes that advertise "every 30 days" should use `Day` with `value: 30` so the marketing copy and the cadence agree.

Custom cadences require the interval form. There are no predefined enums for "every 3 weeks" or "every 45 days" — use `{ unit: "Week", value: 3 }` or `{ unit: "Day", value: 45 }`. The standard frequencies are conveniences on the admin UI side, not separate types.

## Trial Periods and First-Charge Timing

Trials are configured by two product-type attributes plus the cart-item `SubscriptionInfo.trial` block:

| Field | Source | Effect |
|-------|--------|--------|
| `Trial Days` | Product type | Trial duration (1-365) |
| `Trial Product Code` | Product type | Substitute product shipped during trial |
| `Trial Product Variation Code` | Product type | Substitute variation; requires `Trial Product Code` |
| `trial.enabled` | Cart | Turns the trial on for this purchase |
| `trial.duration` | Cart | Override of `Trial Days` for this purchase (within the allowed range) |
| `trial.substituteProductCode` | Cart | Override of `Trial Product Code` for this purchase |

Cart-side body example:

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

**First-charge timing.** The initial Order at checkout captures whatever the trial product's price is (`$0` for a free trial, non-zero for a paid trial). The first **full-price** continuity Order is cut by the scheduler `trial.duration` days after the initial Order.

Important: combined with the `Create Continuity Order X Days Before Next Order Date` lead-time setting, the first full-price charge can land before day `trial.duration`. With a 30-day trial and 2-day lead time, the first full-price capture happens around day 28. Trace the timing through scheduler + lead-time for your specific configuration before promising customers a charge date.

See `billing-dunning.md` for the full first-charge trace.

## Fixed-Term vs Evergreen

Kibo Subscriptions are **evergreen by default**. The research did not surface a first-class "fixed-term" or "ends after N cycles" field on the Subscription resource. Whether such a field exists as an instance-specific extension is **unknown — verify against your live OpenAPI / Kibo support**.

The two documented approximations:

1. **Installment Plans** (`installmentPlanCode`). A fixed payment count against a single Order. Installments are per-Order, not per-Subscription, and they do not roll forward onto continuity Orders. Use installments for "pay this Order off over N payments," not for "this Subscription expires after N cycles." See `billing-dunning.md`.

2. **Operator-side automation.** Cancel the Subscription after N continuity Orders. Implementation: a job that queries Subscriptions, counts continuity Orders per Subscription, and cancels when the count hits the target. Note that **cancellation is terminal and immediate** (see `retention.md`) — there is no `cancelAtPeriodEnd` flag. The pattern is "skip the rest then cancel after the last ships" or "pause until the term ends then cancel."

If your product genuinely requires a fixed-term subscription where the customer pays N times and the Subscription stops, build the cancellation automation explicitly. Do not rely on a platform field that does not exist.

## Bundle Subscriptions

A single Subscription can carry multiple SKUs as line items. Two product-type attributes control bundle behavior:

| Attribute | Effect |
|-----------|--------|
| `Split Extras in Shipments` | At shipment time, splits bundle pricing across the constituent shipments |
| `Split Extras in Subscriptions` | Flattens a configurable bundle into separate Subscription line items |

**Multi-SKU cart -> Subscription materialization** (recap from `subscription-model.md`):

| Cart shape | Resulting Subscriptions |
|------------|-------------------------|
| Two items, same frequency, same shipping address | One Subscription with two line items |
| Two items, same frequency, different shipping addresses | Two Subscriptions |
| Two items, different frequencies | Two Subscriptions |

**Per-line fulfillment.** Each line item on a bundle Subscription carries its own `fulfillmentMethod`. A bundle with a shippable item and a digital item routes through OMS as a mixed-fulfillment Order each cycle. Do not flatten "this Subscription has a shippable line" to "this Subscription is shippable" — the per-line method is what OMS reads.

**Frequency change on a bundle.** Constrained to frequencies supported by **every** item on the Subscription. If one item allows monthly and quarterly while another allows only monthly, the bundle Subscription can only be set to monthly. See `modifications.md` for the change-frequency mutation.

**Pricing.** Adding or removing a line item on a bundle Subscription triggers a reprice of the **next** continuity Order. The in-flight cycle Order (if any) is unaffected. Kibo has no proration engine; mid-cycle changes do not credit or debit the current cycle.

## Plan-Level vs Subscription-Level Changes

Different scope, different propagation. Confusing the two is the most common source of "my plan change didn't apply" tickets.

| Change | Where it lives | Scope | Affects existing Subscriptions? |
|--------|----------------|-------|-------------------------------|
| Edit `Subscription Frequency` attribute on product type | Schema | All products of that type | No — only future shoppers |
| Edit `Subscription Frequency` attribute on a product | Catalog | That product | No — only future shoppers |
| Edit `Trial Days` on product type / product | Schema / Catalog | All future shoppers | No |
| Edit `frequency` on a Subscription | Subscription | That one Subscription | Yes, that one only |
| Edit `items` on a Subscription | Subscription | That one Subscription | Yes, that one only |
| Edit a product's catalog price | Catalog | All future continuity Orders | Yes — next cycle reprices |

**Existing Subscriptions hold their own snapshot.** When the Subscription is materialized at order placement, it copies `frequency`, the chosen line items, and the relevant attributes. Subsequent edits to the product type or product do not reach back and rewrite that snapshot.

The exception is **price**: continuity Orders reprice per cycle (governed by the price-locking setting — "refresh to latest" or "apply best price"). A catalog price change does flow through to the next continuity Order's totals, even though it doesn't edit the Subscription record.

**To change a single subscriber's frequency or items**: mutate the Subscription resource directly. See `modifications.md` for the read-modify-write pattern.

**To change all future subscribers' allowed frequencies**: edit the product type or product attribute. Existing subscribers keep what they had at materialization time; new shoppers see the new allowed list.

## Cart-Side `SubscriptionInfo`

The bridge from "regular cart item" to "subscribed cart item":

```
PUT /commerce/checkouts/{checkoutId}/items/{itemId}/subscriptionInfo
```

Body shape (see `subscription-model.md` for the full discussion):

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

`required: true` flips the line item from one-time to subscribed. The frequency must be one allowed by the product's `Subscription Frequency` attribute (the multi-select on the product type or product). Calling this with a disallowed frequency surfaces the validation error at this point, not at attribute edit time.

Source: https://docs.kibocommerce.com/api-reference/checkout/update-item-subscription-info.md

## Anti-Pattern / Recommended-Pattern Pairs

### Hunting for a Plan API

```typescript
// Wrong — there is no Plan resource
const plan = await fetch('/commerce/subscriptions/plans/MONTHLY_BOX');
const allFrequencies = plan.allowedFrequencies;
```

```typescript
// Recommended — read frequencies off the product
const product = await getProduct('MONTHLY_BOX');
const allowedFrequencies = product.properties.find(
  p => p.attributeFQN === 'tenant~subscription-frequency',
)?.values;
```

### Editing a product type to "change a customer's plan"

```typescript
// Wrong — assumes product-type edits propagate to existing subscribers
await updateProductType('subscription-box', {
  attributes: { 'subscription-frequency': ['weekly'] },
});
// Existing customers on monthly do NOT switch to weekly.
```

```typescript
// Recommended — mutate the Subscription directly for that customer
const current = await getSubscription(subscriptionId);
const updated = {
  ...current,
  frequency: { unit: 'Week', value: 1 },
};
await putSubscription(subscriptionId, updated);
// And separately, if you want to constrain new shoppers:
await updateProductType('subscription-box', {
  attributes: { 'subscription-frequency': ['weekly'] },
});
```

### Using `30 Days` when the customer expects "monthly"

```json
// Wrong — drifts forward through the calendar; renews on a different day each month
{ "unit": "Day", "value": 30 }
```

```json
// Recommended — preserves day-of-month
{ "unit": "Month", "value": 1 }
```

### Assuming "fixed term" is a flag

```typescript
// Wrong — no such field exists
await createSubscription({
  customerAccountId,
  items,
  frequency,
  termCycles: 12,         // not real
  endsAfter: { cycles: 12 }, // not real
  cancelAtPeriodEnd: true,   // not real
});
```

```typescript
// Recommended — automate the cancellation explicitly, or use an installment plan
async function cancelAfterCycles(subscriptionId: string, targetCycles: number) {
  // Orders carry subscriptionIds[] back-references; query Orders where
  // subscriptionIds contains this subscription's id
  const orders = await getContinuityOrders({ subscriptionId });
  if (orders.length >= targetCycles) {
    await cancelSubscription(subscriptionId, { reasonCode: 'TERM_COMPLETE' });
  }
}

// Or, for a fixed payment count on a single Order (different shape — see billing-dunning.md):
await createSubscription({
  customerAccountId,
  items,
  frequency,
  installmentPlanCode: 'TWELVE_MONTH_PLAN',
});
```

### Flattening a mixed-fulfillment bundle

```typescript
// Wrong — picks one fulfillment method for the whole subscription
const fulfillmentMethod = subscription.items[0].fulfillmentMethod;
routeToOms({ subscriptionId, fulfillmentMethod });
```

```typescript
// Recommended — OMS reads per-line method on each continuity Order
// Do not flatten on the Subscription side; let OMS route per line item per cycle.
```

## Checklist

Before going live with subscription plan configuration:

- [ ] No code references a `/plans` endpoint or a Plan resource.
- [ ] `Subscription Frequency` attribute is set on the product type and overridden per product where needed.
- [ ] `Subscription Mode` is set to `SubscriptionOnly` or `Both` deliberately, per product.
- [ ] Frequency choice (`Month` vs `Day`) matches customer-facing copy — `1 Month` and `30 Days` are not the same.
- [ ] Custom cadences (every-N-weeks, every-N-days) use `{ unit, value }`, not a string-typed enum.
- [ ] Trial duration + lead-time setting have been traced end-to-end to confirm the first full-price charge date.
- [ ] Trial substitute SKU is configured if the trial is free or a paid sample-size shipment.
- [ ] Bundle subscriptions have `Split Extras in Subscriptions` set deliberately — flattened or kept-as-one.
- [ ] Bundle frequency changes are constrained to frequencies supported by every line item.
- [ ] Catalog price changes are understood to flow through to the next continuity Order, not the current one.
- [ ] Existing Subscriptions are mutated directly, not by editing the product or product type.
- [ ] Fixed-term Subscriptions, if required, are implemented via operator-side cancellation automation or installment plans, not a non-existent `cancelAtPeriodEnd` flag.
- [ ] Out-of-range frequency values are validated before reaching add-to-cart (the admin UI does not catch them).
