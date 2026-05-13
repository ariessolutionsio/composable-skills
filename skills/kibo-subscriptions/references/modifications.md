# Modifications to Active Subscriptions

Skip, swap, change-frequency, change-payment, and change-address are different mutations with different scopes, different propagation semantics, and different proration consequences. Conflating them produces wrong reprice math and the wrong customer-facing copy. This file maps each modification to the API call, the timing, and the gotchas.

## Table of Contents
- [Big Idea: These Are Different Mutations](#big-idea-these-are-different-mutations)
- [Read-Modify-Write on PUT](#read-modify-write-on-put)
- [Action Endpoints vs Resource PUT](#action-endpoints-vs-resource-put)
- [Skip Next Order](#skip-next-order)
- [Swap SKU (Modify Items)](#swap-sku-modify-items)
- [Change Frequency](#change-frequency)
- [Change Payment Method](#change-payment-method)
- [Change Shipping Address](#change-shipping-address)
- [Order Immediately](#order-immediately)
- [Edit Next Order Only](#edit-next-order-only)
- [Apply Coupons and Adjust Pricing](#apply-coupons-and-adjust-pricing)
- [Mid-Cycle vs End-of-Cycle: When Changes Take Effect](#mid-cycle-vs-end-of-cycle-when-changes-take-effect)
- [Customer-Portal vs Operator-Portal Auth](#customer-portal-vs-operator-portal-auth)
- [Anti-Pattern / Recommended-Pattern Pairs](#anti-pattern--recommended-pattern-pairs)
- [Checklist](#checklist)

## Big Idea: These Are Different Mutations

Coming from Stripe Billing or Recharge, the temptation is to treat "modify a subscription" as one operation that takes a payload describing the new state. Kibo splits it across several discrete actions, each with its own semantics:

| Modification | What changes | When it takes effect | Reprices? |
|--------------|--------------|----------------------|-----------|
| Skip | Defers the next cycle by one interval | The cycle that would have been next is skipped | No reprice — the existing scheduled Order is just not cut |
| Swap SKU | Line items change | Next cycle | Yes — next continuity Order reprices |
| Change frequency | `frequency.unit` / `frequency.value` change | `nextOrderDate` recomputed; next cycle | No item reprice; cadence changes |
| Change payment method | Stored payment ref change | Next cycle onward; affects in-flight `Errored` retries (see below) | No |
| Change shipping address | `fulfillmentInfo` change | **Next cycle, not the current one** | No |

Mixing these up — for example, treating a "swap to the larger box" as a frequency change, or treating an address update as something that flows through to a cycle Order already in flight — produces wrong copy in customer notifications and wrong totals in reprice.

**Kibo has no proration engine.** No documented operation produces a mid-cycle credit or debit. Reprice happens at the next continuity Order, against the new line items / new payment / new address. If your business logic requires "credit the unused portion of this cycle," that's an Order-side adjustment you build yourself.

## Read-Modify-Write on PUT

Before any of the individual modifications below, internalize this:

`PUT /commerce/subscriptions/{id}` **replaces the resource**. Omitted fields null out. This is the single most common source of subscription bugs in Kibo — code that builds a partial PUT body wipes whatever it didn't include.

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
async function changeSubscriptionFrequency(id: string, frequency: Frequency) {
  const current = await getSubscription(id);
  const updated = {
    ...current,
    frequency,
  };
  await fetch(`/commerce/subscriptions/${id}`, {
    method: 'PUT',
    body: JSON.stringify(updated),
  });
}
```

The failure mode is silent. The API accepts the partial body. The Subscription comes back from the next GET with most of its fields blank. Compare to commercetools, where a version mismatch produces an explicit 409 — Kibo gives no such safety net.

This same rule applies to all the modifications below that go through the resource PUT path. Where an explicit action endpoint exists, prefer it — see the next section.

## Action Endpoints vs Resource PUT

Two patterns coexist on the Subscription resource:

| Pattern | Method | Path |
|---------|--------|------|
| Resource read-modify-write | PUT | `/commerce/subscriptions/{id}` |
| Dedicated action sub-paths | POST | `/commerce/subscriptions/{id}/orderNow` (and similar) |
| Status change | (status endpoint) | sets `Active` / `Paused` / `Cancelled` |

**Documented action endpoint paths:**

| Action | Path | Source |
|--------|------|--------|
| Order now (cut a cycle immediately) | `POST /commerce/subscriptions/{id}/orderNow` | Concept guide |
| List cancellation reasons | `GET /commerce/subscriptions/reasons` | Concept guide |

**Unknown — verify against your live OpenAPI / Kibo support:** the exact REST paths for the action endpoints for `pause`, `skip`, and `reactivate`. The SDK exposes them as named methods (`updateSubscriptionStatus`, `skipSubscription`, etc.); the underlying paths are not consistently published outside the OpenAPI viewer.

The two reliable approaches:

1. **Use the SDK's named methods** (e.g. `@kibocommerce/rest-sdk`) and treat the REST path as an implementation detail.
2. **PUT the full resource with a modified status field**, accepting the read-modify-write trade-off. Slower (extra GET round-trip) but path-agnostic.

When in doubt, prefer the SDK or confirm the path in the OpenAPI viewer for the tenant you are targeting. Hard-coding an action path you guessed from another tenant is the kind of thing that works in dev and breaks at launch.

## Skip Next Order

Skips the next scheduled cycle. The subscription resumes at the **order-after-next**. This is a single-cycle skip, not an indefinite pause.

**Effect on `nextOrderDate`:** advances by one interval.

**Who can initiate:**

- **Customer**, through the storefront self-service surface (if exposed).
- **Operator / CSR**, through the admin UI on the Customer Details -> Subscriptions tab.

**API:** SDK method `skipSubscription` (REST path **unknown — verify against your live OpenAPI**). The fallback is read-modify-write on the resource PUT, advancing `nextOrderDate` by `frequency`.

**Reprice:** none. Skip does not generate an Order. The cycle that would have been next is simply not cut.

**Notifications:** "next order skipped" email fires to the shopper. The post-skip `nextOrderDate` appears in the body.

**Anti-pattern:** building "skip" as "pause then resume after one cycle." Pause does not advance `nextOrderDate` on resume in the same way skip does, and the email copy is different. Use skip for "skip the next one" and pause for "pause until further notice." See `retention.md` for pause.

## Swap SKU (Modify Items)

There is **no first-class "swap SKU" mutation**. The pattern is:

1. Remove the existing line item.
2. Add the replacement line item.
3. Accept the reprice on the next continuity Order.

The "Modify Items" operator action covers add, remove, and quantity change. Any item change triggers a reprice of the next continuity Order — there is no proration on the current in-flight cycle.

**API:** read-modify-write on the resource PUT.

```typescript
async function swapSku(subscriptionId: string, oldSku: string, newSku: string) {
  const current = await getSubscription(subscriptionId);
  const updated = {
    ...current,
    items: current.items
      .filter(item => item.product.productCode !== oldSku)
      .concat([
        {
          product: { productCode: newSku },
          quantity: 1,
          fulfillmentMethod: 'Ship', // copy from the removed item if appropriate
        },
      ]),
  };
  await putSubscription(subscriptionId, updated);
}
```

**Reprice rules.** Kibo prices continuity Orders fresh per cycle — either "refresh to latest" or "apply best price" depending on the price-locking setting. The swapped SKU's price applies at the next cycle. The current cycle Order, if already in flight, is unaffected.

**Constraints:**

- New SKU must have `Subscription Mode` set to `SubscriptionOnly` or `Both`.
- New SKU's `Subscription Frequency` allowed list must include the Subscription's current `frequency`. Otherwise the change is rejected at PUT time.
- For bundle Subscriptions, the new SKU must support the Subscription's current frequency or the change is rejected.

**Anti-pattern:** assuming Kibo will compute a mid-cycle proration credit when swapping to a cheaper SKU (or a charge when swapping to a more expensive one). It won't. The current cycle keeps its Order as-is; the new SKU's price kicks in at the next cycle. If your business requires mid-cycle credit, build it yourself as an Order-side adjustment.

## Change Frequency

Changes the cadence at which continuity Orders are cut. `nextOrderDate` is recomputed from the change moment.

**API:** Kibo publishes a dedicated `PUT /commerce/subscriptions/{subscriptionId}/frequency` endpoint that takes just the new frequency body — narrower than a full resource PUT and therefore safer than the read-modify-write pattern (no risk of nulling other fields). A full read-modify-write resource PUT also works as a fallback. There is no `POST /actions/updateFrequency` action — that pattern doesn't exist on the Subscriptions API; prefer the dedicated frequency endpoint.

```typescript
async function changeFrequency(subscriptionId: string, frequency: Frequency) {
  // Preferred: dedicated frequency endpoint (no risk of nulling other fields)
  await fetch(`/commerce/subscriptions/${subscriptionId}/frequency`, {
    method: 'PUT',
    body: JSON.stringify(frequency),
  });

  // Fallback: full read-modify-write on the resource
  // const current = await getSubscription(subscriptionId);
  // await putSubscription(subscriptionId, { ...current, frequency });
}
```

The same narrow-endpoint pattern exists for next order date: `PUT /commerce/subscriptions/{id}/nextorderdate`. Verify exact endpoint shapes against <https://apidocs.kibocommerce.com/?spec=commerce-subscription>.

**Effect on `nextOrderDate`.** The platform recomputes it. The **exact behavior across pause/resume + frequency-change combinations is unknown — verify against your live tenant.** Specifically: if a Subscription is paused, then its frequency is changed, then it is resumed, the resulting `nextOrderDate` could be:

- The pre-pause `nextOrderDate` (preserved verbatim, ignoring the frequency change for the immediate next cycle).
- `now` + new `frequency` (treating the resume as a reset).
- Some calendar-aligned value derived from the original creation date and the new cadence.

The documented behavior is "preserved as calculated by the original order date and frequency cadence," which does not pin down which cadence wins when the frequency changes during a pause. Surface the computed `nextOrderDate` to the customer in the storefront after the change so they can see what they're getting.

**Constraints:**

- Bundle Subscriptions: the new frequency must be in the allowed list for **every** line item. A frequency that one line item disallows is rejected.
- Single-item Subscriptions: the new frequency must be in the product's `Subscription Frequency` allowed list.

**Reprice:** the per-cycle price does not change just because the cadence changed. Customers swapping from monthly to quarterly do not automatically pay 3x — they continue to pay the line-item totals, just less often. If your pricing model is "monthly box is $30, quarterly box is $80," that's a SKU swap, not a frequency change.

## Change Payment Method

Updates the Subscription's `payment` block to point at a different stored card on the customer account.

**API:** read-modify-write resource PUT.

```typescript
async function changePaymentMethod(subscriptionId: string, paymentMethodId: string) {
  const current = await getSubscription(subscriptionId);
  const updated = {
    ...current,
    payment: { paymentMethodId }, // exact field shape — verify against live OAS
  };
  await putSubscription(subscriptionId, updated);
}
```

**Effect timing:**

- For **`Active`** Subscriptions: applies to the next continuity capture.
- For **`Errored`** Subscriptions in mid-recycling: the change applies to subsequent retry attempts. The recycling schedule is not reset — the retry budget continues counting down from when the Subscription first entered `Errored`. A payment-method change in `Errored` is the operator's last best chance before recycling exhausts and the Subscription moves to `Failed`.

**`subscription.paymentupdated` event** fires on this change. Wire any downstream systems (CRM, AR, fraud) to this topic rather than polling.

**Tokenization.** The Subscription stores a reference to a tokenized Card on the customer's `CustomerAccount`, not a PAN. To switch payment methods, the new card must already exist on the customer account (added through the normal Add Card flow). Changing the payment method on the Subscription does not create the card — it just re-points the reference.

See `billing-dunning.md` for the full PSP / off-session story.

## Change Shipping Address

Updates the Subscription's `fulfillmentInfo` block (shipping contact + `shippingMethodCode`).

**Policy:** **applies next cycle, not the current one.**

This is a policy decision worth being explicit about in customer-facing copy. A customer who changes their shipping address mid-cycle, after the current cycle's Order has already been cut and routed through OMS, will see the new address only on the cycle after that. The current cycle ships to the old address.

If the operator wants the current cycle to ship to the new address, the cycle Order itself must be updated through the Order resource (the Subscription change does not retroactively modify an already-cut Order). This is OMS-side editing, not Subscription-side.

**API:** read-modify-write resource PUT.

```typescript
async function changeShippingAddress(
  subscriptionId: string,
  shippingAddress: ShippingAddress,
) {
  const current = await getSubscription(subscriptionId);
  const updated = {
    ...current,
    fulfillmentInfo: {
      ...current.fulfillmentInfo,
      fulfillmentContact: {
        ...current.fulfillmentInfo.fulfillmentContact,
        address: shippingAddress,
      },
    },
  };
  await putSubscription(subscriptionId, updated);
}
```

**Customer-facing copy** must say "applies to your next shipment" rather than "your address has been updated" without qualification. The latter implies the current cycle will ship to the new address, which is wrong.

**Shipping method.** Changing the address can invalidate the configured `shippingMethodCode` (a shipping method only available in one region, for instance). The platform's behavior when the configured method no longer serves the new address is **unknown — verify in a sandbox**. The safest pattern is to re-validate the shipping method against the new address on the storefront and update `shippingMethodCode` in the same PUT.

## Order Immediately

Cuts a continuity Order now, outside the scheduler's normal cadence. Useful for customer-initiated "ship me my next box now" or operator-initiated emergency shipment.

**API:** `POST /commerce/subscriptions/{id}/orderNow`

**Effect on `nextOrderDate`.** Governed by the `Order Now Resets Next Order Date` system setting:

- **Reset on:** `nextOrderDate` advances to `now + frequency`. The recurring schedule shifts.
- **Reset off:** `nextOrderDate` remains where it was. The customer effectively gets an extra cycle this period; the next scheduled cycle still cuts at the original date.

Pick the setting deliberately based on the business model. Box-of-the-month subscriptions usually want reset-on (the customer gets one box per cadence and `Order Now` shifts the cadence). Replenishment subscriptions (toothbrush heads, dog food) usually want reset-off (the customer is just getting an early refill; the next refill still ships on schedule).

**Reprice:** the Order generated by `Order Now` uses the Subscription's current line items and the current pricing rules — same as a scheduled continuity Order.

## Edit Next Order Only

Draft-mode change that applies to **one** continuity Order, not the recurring template.

**Use cases:**

- "Just for this month, add a free sample to the box."
- "Just for this month, ship to my parents' house for the holidays."
- "Just for this month, skip the conditioner."

**API:** operator action in the admin UI. The corresponding REST shape is **unknown — verify against your live OpenAPI**. The pattern is likely a separate "next Order draft" resource, or a flag on the next-cut Order pre-capture.

**Effect:** the template Subscription is unchanged. The next continuity Order picks up the override. Cycle N+2 reverts to the template.

**Anti-pattern:** building "edit next order" as a Subscription mutation that you then have to mutate back after the cycle. The state-management is a mess and easy to drift. Use the dedicated "edit next order" path if available; otherwise model the change as an Order-side edit after the cycle is cut.

## Apply Coupons and Adjust Pricing

| Action | Scope |
|--------|-------|
| Apply Coupons | Promotion codes attached to all future continuity Orders |
| Adjust Pricing | Item / shipping / handling / duty adjustments with an appeasement reason |

Coupons attach to the Subscription and roll forward onto every subsequent continuity Order until removed. Useful for "give this customer 10% off forever as goodwill."

Pricing adjustments are one-time appeasements (operator records a reason). Whether they apply only to one Order or roll forward is configuration-dependent — verify in your admin.

Both go through the resource PUT (read-modify-write) or dedicated admin actions. SDK method names vary.

## Mid-Cycle vs End-of-Cycle: When Changes Take Effect

A quick reference for "when does this change actually show up to the customer":

| Change | Applies to current in-flight cycle Order? | Applies to next cycle? |
|--------|-------------------------------------------|------------------------|
| Skip | N/A (skips the cycle entirely) | The cycle after the skip |
| Swap SKU | No — current cycle's Order is untouched | Yes, reprices at next cycle |
| Change frequency | No | Yes, `nextOrderDate` recomputed |
| Change payment | No — current Order has its own payment | Yes; affects in-flight `Errored` retries |
| Change address | **No** (policy: next cycle only) | Yes |
| Apply coupon | No (current cycle's Order already priced) | Yes |
| Edit Next Order Only | N/A (operates on the next-cut Order draft, not the template) | One-time, for the next Order |

**Operator-initiated mid-cycle change.** Say the operator updates a Subscription's shipping address while the current cycle's Order is mid-fulfillment in OMS. The Subscription PUT updates the template. The in-flight Order keeps its own address (Order-side edit required to change it). The next cycle ships to the new address.

This is the right mental model: **the Subscription is the template. Edits to the template affect cycles cut after the edit.** In-flight cycle Orders are separate entities, edited via the Order resource.

## Customer-Portal vs Operator-Portal Auth

Different auth scopes, different action surfaces.

| Surface | Auth | Available actions |
|---------|------|-------------------|
| Customer storefront self-service | Customer-scoped OAuth token (shopper's account session) | Pause, skip, resume, change frequency, change shipping/payment, on-demand order, cancel |
| Operator admin (Customer Details -> Subscriptions) | Operator-scoped OAuth token | Everything above plus modify items, apply coupons, adjust pricing, edit next order only, edit attributes, force activation |

**Same underlying API, different scopes.** The research did not surface separate "buyer" API endpoints with narrower auth — whether the customer-facing surface is exposed as separate endpoints or as the operator API with a customer-scoped token is **unknown — verify against your live tenant**. The two reliable assumptions:

1. The action surface available to customer-scoped tokens is a subset of the operator action surface.
2. Operator-only actions (modify items mid-flight, override price, force activation of a `Failed` Subscription) require an operator-scoped token. A customer-scoped token attempting them gets a 403.

**Audit trail.** Operator actions log the operator's user ID; customer self-service actions log the customer's account ID. Reporting that distinguishes "customer cancelled" from "operator cancelled" reads this log.

## Anti-Pattern / Recommended-Pattern Pairs

### Treating skip, swap, and change-frequency as the same mutation

```typescript
// Wrong — one giant "modify" function that conflates everything
async function modifySubscription(id: string, changes: any) {
  if (changes.skip) await put(id, { ...await get(id), nextOrderDate: advance() });
  if (changes.sku) await put(id, { ...await get(id), items: changes.sku });
  if (changes.frequency) await put(id, { ...await get(id), frequency: changes.frequency });
  // Each PUT races the others; net effect is whichever PUT lands last
}
```

```typescript
// Recommended — distinct functions, distinct semantics, distinct notifications
async function skipNextCycle(id: string) { /* SDK skip or explicit nextOrderDate advance */ }
async function swapSku(id: string, oldSku: string, newSku: string) { /* read-modify-write items */ }
async function changeFrequency(id: string, frequency: Frequency) { /* read-modify-write frequency */ }
async function changePaymentMethod(id: string, paymentMethodId: string) { /* read-modify-write payment */ }
async function changeShippingAddress(id: string, address: Address) { /* read-modify-write fulfillmentInfo */ }
```

### Partial PUT updates

```typescript
// Wrong — nulls every field except the one you sent
await fetch(`/commerce/subscriptions/${id}`, {
  method: 'PUT',
  body: JSON.stringify({ frequency: { unit: 'Month', value: 2 } }),
});
```

```typescript
// Recommended — GET, mutate, PUT the full payload
const current = await getSubscription(id);
await putSubscription(id, { ...current, frequency: { unit: 'Month', value: 2 } });
```

### Assuming proration on swap

```typescript
// Wrong — Kibo does not compute mid-cycle proration
const credit = computeProrationCredit(oldSku, newSku, daysIntoCycle);
await applyCredit(customerId, credit);
```

```typescript
// Recommended — accept the next-cycle reprice; if business requires mid-cycle credit, build it as an Order adjustment
await swapSku(subscriptionId, oldSku, newSku);
// Next continuity Order will reprice at the new SKU's price. Current cycle keeps its Order as-is.
```

### Customer-facing copy that promises immediate address change

```text
// Wrong — implies the in-flight Order will ship to the new address
"Your shipping address has been updated."
```

```text
// Recommended — explicit about which cycle the change affects
"Your shipping address has been updated. This applies to your next order, shipping on {nextOrderDate}.
 Your current order, already in fulfillment, ships to the previous address."
```

### Guessing action endpoint paths

```typescript
// Wrong — guessed path may not exist; "works in dev" until it doesn't
await fetch(`/commerce/subscriptions/${id}/skip`, { method: 'POST' });
```

```typescript
// Recommended — use the SDK method, which abstracts the path
import { SubscriptionApi } from '@kibocommerce/rest-sdk';
const api = new SubscriptionApi(config);
await api.skipSubscription(id);
// Or, fall back to read-modify-write resource PUT if the SDK doesn't expose the action.
```

### Operator-scoped action from a customer-scoped token

```typescript
// Wrong — customer-scoped token, operator-only action; returns 403 at runtime
await fetch(`/commerce/subscriptions/${id}/adjustPricing`, {
  method: 'POST',
  headers: { Authorization: `Bearer ${customerToken}` },
  body: JSON.stringify({ adjustment: -10, reason: 'GOODWILL' }),
});
```

```typescript
// Recommended — gate operator actions on the operator scope at the storefront layer
if (!isOperator(currentUser)) {
  throw new ForbiddenError('Pricing adjustments require operator scope');
}
await fetch(`/commerce/subscriptions/${id}/adjustPricing`, {
  method: 'POST',
  headers: { Authorization: `Bearer ${operatorToken}` },
  body: JSON.stringify({ adjustment: -10, reason: 'GOODWILL' }),
});
```

## Checklist

Before going live with subscription modification flows:

- [ ] All `PUT /commerce/subscriptions/{id}` calls do GET -> mutate -> PUT, not partial bodies.
- [ ] Skip, swap, change-frequency, change-payment, change-address are separate functions with distinct customer-facing copy.
- [ ] Customer notifications for address change say "applies to your next order," not "your address has been updated."
- [ ] No code assumes Kibo computes proration on SKU swap or frequency change.
- [ ] Bundle frequency changes validate against every line item's allowed-frequency list before PUT.
- [ ] `Order Now Resets Next Order Date` setting is set deliberately based on the business model (replenishment vs box-of-the-month).
- [ ] `Order Now` is used to force a cycle in test environments, not waiting for the ~30 min scheduler tick.
- [ ] Customer-portal actions and operator-portal actions are gated on the correct OAuth scope.
- [ ] In-flight cycle Orders that need editing are edited via the Order resource, not the Subscription resource.
- [ ] Action endpoint paths are sourced from the live OpenAPI (or SDK methods), not guessed.
- [ ] `subscription.paymentupdated` event is wired for downstream systems instead of polling.
- [ ] Operator audit trail distinguishes customer-initiated from operator-initiated changes.
- [ ] Coupons applied to a Subscription are understood to roll forward onto every future continuity Order until removed.
- [ ] Edit Next Order Only is used for one-time overrides, not as a "mutate Subscription then mutate back" pattern.
