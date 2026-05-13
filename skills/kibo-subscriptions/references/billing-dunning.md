# Billing Cycles & Dunning

Kibo runs continuity-order generation on an internal scheduler and runs **Payment Recycling** (its name for dunning) as a configurable retry policy that fires only on `Errored` subscriptions. The PSP is the same one the eCommerce storefront uses — there is no subscription-specific gateway. This file makes the timing, the retry math, and the PSP fit-check explicit.

## Table of Contents
- [Big Idea: Two Independent Pipelines](#big-idea-two-independent-pipelines)
- [The Scheduler](#the-scheduler)
- [`nextOrderDate` Math](#nextorderdate-math)
- [Trial Periods and First-Charge Timing](#trial-periods-and-first-charge-timing)
- [Payment Recycling — Configuration](#payment-recycling--configuration)
- [Recycling Math: Max Retries](#recycling-math-max-retries)
- [Status Flow on Payment Failure](#status-flow-on-payment-failure)
- [Shared PSP, Off-Session Captures, SCA / 3DS](#shared-psp-off-session-captures-sca--3ds)
- [Customer Notifications](#customer-notifications)
- [Installments Are Not Subscriptions](#installments-are-not-subscriptions)
- [Anti-Pattern / Recommended-Pattern Pairs](#anti-pattern--recommended-pattern-pairs)
- [Checklist](#checklist)

## Big Idea: Two Independent Pipelines

Two engines run on different cadences against different entities:

| Pipeline | Cadence | Runs on | What it does |
|----------|---------|---------|--------------|
| **Continuity-order scheduler** | ~30 min | `Active` Subscriptions where `nextOrderDate <= now` | Cuts a new Order |
| **Payment Recycling (dunning)** | Per the configured time-slot schedule | `Errored` Subscriptions whose cycle Order failed with a matching gateway code | Re-attempts the cycle Order's capture |

These are decoupled. The scheduler does not retry. Recycling does not generate new cycle Orders.

When a continuity Order is cut and its capture fails, the Subscription moves to `Errored` and the cycle Order sits there awaiting recycling retries. Recycling either succeeds (Subscription -> `Active`, the cycle Order captures normally) or exhausts its retry budget (Subscription -> `Failed`, manual intervention required).

The dunning side runs on **Subscription status** (`Errored`). The capture itself runs against the **cycle Order**. Reports that join the two must respect this: dunning state lives on the Subscription; the individual capture attempts live on the Order's payment interactions.

## The Scheduler

An internal scheduler runs every ~30 minutes, scanning every `Active` subscription. For each subscription where `nextOrderDate <= now`, it generates a continuity Order.

Three operator-configured settings affect timing:

| Setting | Effect |
|---------|--------|
| `Create Continuity Order X Days Before Next Order Date` | Lead time so fulfillment has prep time |
| `Order Now Resets Next Order Date` | Whether a customer-initiated "Order Now" shifts the recurring schedule |
| `Update Next Order Date Up to X Days` | Cap on how far a customer can push the next order out |

**Test-environment implication.** Creating a Subscription in a sandbox does **not** immediately produce a continuity Order. The scheduler runs at most every 30 minutes. End-to-end tests need to either wait, use `POST /commerce/subscriptions/{id}/orderNow` to force a cycle, or check the Subscription's `nextOrderDate` rather than expecting an Order to exist.

**Lead-time implication.** With `Create Continuity Order X Days Before Next Order Date` set to e.g. 2, the cycle Order is created at `nextOrderDate - 2 days` and capture happens at that time. A failed capture two days before the ship date still has the recycling window to recover before the ship date — design CSR alerts to fire on `subscription.errored` so the operator has the same window.

## `nextOrderDate` Math

`nextOrderDate` advances by the Subscription's current `frequency` from the previous order date — not from the Subscription's creation date.

This matters for paused/resumed Subscriptions. The documented behavior: a paused-then-resumed Subscription does **not** "catch up" missed cycles. The next-order-date is preserved as calculated from the original order date and frequency cadence.

**Concrete:**

- Subscription created Jan 1, frequency `1 Month`. `nextOrderDate` = Feb 1.
- Subscription paused Jan 20.
- Subscription resumed Mar 15.
- `nextOrderDate` after resume: **unknown — verify against a live tenant.** The docs say "preserved as calculated by the original order date and frequency" but do not pin down whether that means:
  - (a) The pre-pause `nextOrderDate` is preserved verbatim (Feb 1 — already past, so a cycle cuts at the next scheduler tick), or
  - (b) The next `nextOrderDate` on or after `now` derived from the original cadence (Apr 1, three months from Jan 1), or
  - (c) `now` + `frequency` (Apr 15).

If your design depends on the exact behavior, test it in a sandbox before shipping. The safest pattern is to surface the post-resume `nextOrderDate` to the customer in the storefront so they see what they're getting, regardless of which interpretation the platform applies.

`Skip Next Order` resumes the Subscription at the **order-after-next** — the skip is a single-cycle skip, not an indefinite pause.

## Trial Periods and First-Charge Timing

Trials are configured by two product-type attributes plus the cart-item `SubscriptionInfo`:

| Field | Effect |
|-------|--------|
| `trial.enabled` (cart) | Turns the trial on for this purchase |
| `trial.duration` (cart) | Days the trial runs |
| `trial.substituteProductCode` | The product shipped during the trial (often a sample-size SKU at $0 or a low price) |

**First-charge timing:**

- Initial Order at checkout: charges whatever the trial product's price is (commonly $0; can be a paid trial).
- First full-price continuity Order: cut `trial.duration` days after the initial Order, going through the normal scheduler -> capture flow.

The "free trial" pattern is `substituteProductCode` set to a $0 SKU and `duration` set to the trial length. The "paid trial" pattern is a non-zero substitute. Whether the substitute price is configurable independently of the regular product price is **unknown** — verify against the product configuration UI.

**Off-by-one trap.** `duration: 30` does **not** automatically mean "first charge on day 31." The first continuity Order is generated by the scheduler when `nextOrderDate <= now`, and `nextOrderDate` is set by the trial expiration. Combined with the `Create Continuity Order X Days Before Next Order Date` lead time, the first charge can land before day 30. Trace through the timing for your specific lead-time setting before promising customers a charge date.

## Payment Recycling — Configuration

Configured at **System -> Settings -> Recycling Rules**. Each rule is a (decline-code, retry-schedule) pair.

| Field | Meaning |
|-------|---------|
| `Recycling Reason Code` | **Exact** match against `payments.interactions.gatewayResponseCode` from the PSP |
| `Recycling Reason Description` | Free text for audit |
| `Payment Types` | Comma-separated card brands (VISA, Discover, etc.) |
| `Auth Time of Day` | UTC slots from `{2:30, 5:30, 8:30, 11:30, 14:30, 17:30, 20:30}` — comma-separated |
| `Auth No of Days` | Window length (total days the retry policy runs) |
| `Auth Repeat Interval Days` | Days between attempts (1 = daily) |
| `Bump Expiry Year` | Optional — adds 3 years to the card's expiry before each retry. Useful for "card expired" declines where the cardholder has a newer expiry on file but hasn't updated it |

**Exact match, no wildcards.** `Recycling Reason Code` is compared byte-for-byte against the gateway's response code. Wildcards aren't documented. If the PSP returns `05` for one decline and `0500` for another and your rule says `05`, the longer code is **not** matched.

This is the most common silent failure in Kibo dunning. Configure a rule, ship the dunning policy, then watch declines pile up in `Errored` with no retries because the codes don't quite match. Audit the actual gateway codes that come through against the configured rules before going live.

**Per-brand rules.** Different card brands return different decline codes for the same logical reason. A single "soft decline" recycling policy typically needs multiple rules — one per brand, each with the brand-specific decline codes.

## Recycling Math: Max Retries

```
max_retries = (Auth No of Days / Auth Repeat Interval Days) * (count of Auth Times)
```

**Example.** `Auth No of Days = 10`, `Auth Repeat Interval Days = 2`, `Auth Time of Day = 5:30, 17:30` (2 slots).

`(10 / 2) * 2 = 10 retries.`

The retry window runs from the time the Subscription enters `Errored` for `Auth No of Days`. Each retry attempts the failed cycle Order's capture against the same stored payment method.

**Tuning notes:**

- More time slots per day -> more retries per window, but more PSP calls per failed Subscription.
- Wider window (`Auth No of Days`) -> more total retries, but longer time before `Failed` and CSR intervention.
- `Bump Expiry Year` is the cheapest fix for the "expired card, customer never updated" failure mode — try it before more elaborate retry schedules.

**Recycling preconditions:**

- Subscription must be `Errored`. Active subscriptions are not retried (recycling is reactive, not preemptive).
- The decline code must match a configured rule's `Recycling Reason Code` exactly.
- Works alongside installment plans (installment captures retry the same way).

## Status Flow on Payment Failure

```
Active --charge fails--> Errored --recycling exhausted--> Failed
                            |
                            +--charge succeeds on retry--> Active
```

`Failed` is the manual-intervention bucket. No automatic escalation past it. The CSR or the customer must:

1. Update the payment method on the customer account.
2. Reactivate the Subscription (move it back to `Active`).
3. The scheduler then resumes normal cycle generation.

The original failed cycle Order may need separate handling depending on operator policy — manual capture against the new payment method, or cancellation and re-shipment on the next cycle.

## Shared PSP, Off-Session Captures, SCA / 3DS

The PSP integration is **the same one configured for Kibo eCommerce / OMS.** There is no subscription-specific PSP layer. Whatever gateway the storefront uses for one-time orders is the gateway used for recurring captures.

**Fit-check at platform selection.** The PSP must support:

- **Tokenization** — the Subscription stores a reference to a tokenized Card on the customer account, not a PAN.
- **Off-session merchant-initiated transactions (MIT)** — the scheduler captures continuity orders without the cardholder present. The PSP / network must accept MIT-flagged charges.

If the PSP is configured only for on-session, SCA-every-time captures, the entire continuity flow will fail. Cards will get declined for missing SCA challenge response, the Subscription will move to `Errored`, recycling will retry, recycling will exhaust, the Subscription will move to `Failed`. Configuration must include the MIT intent at the gateway level.

### Stored payment methods

Subscriptions reference a tokenized Card on the customer's `CustomerAccount`. The Subscription's `payment` block points to that stored credential. The PAN never lives on the Subscription record. Updating the Subscription's `payment` block points it at a different stored card — the card itself is managed on the customer account, not on the Subscription.

**Anti-pattern:** trying to store card data directly on the Subscription. The shape doesn't support it; even if you reverse-engineered a path, you'd be expanding PCI scope to the Subscription resource.

### SCA / 3DS — initial vs continuity

Standard pattern:

1. **Initial Order at checkout** runs the full 3DS challenge. The cardholder is present. The gateway returns a 3DS-authenticated transaction.
2. **The token from that 3DS-authenticated transaction is stored** with the off-session / MIT intent flag set at the gateway.
3. **Continuity Orders** capture using that token, with the off-session / MIT intent. No challenge required.

If the issuer requires SCA on the recurring charge despite the MIT flag (some EU issuers do, particularly for high-value or unusual transactions), the capture fails and the Subscription lands in `Errored`. Recycling will retry on the same schedule. There is no documented mechanism in Kibo to escalate this to a re-authentication flow with the customer — the PSP / gateway controls that, and Kibo's view of it is just "capture failed."

Per-gateway nuance is **not enumerated in Kibo's docs.** Verify the specific gateway's MIT support, network token capability, and SCA exemption behavior before launch.

## Customer Notifications

Two distinct notification surfaces:

| Surface | Recipient | Configured at |
|---------|-----------|---------------|
| **Customer emails** | Shopper | System -> Settings -> General (email options); templates in site theme |
| **Event notifications** | External systems | Subscribed JSON endpoints |

### Customer emails — billing-relevant events

| Trigger | Email |
|---------|-------|
| Cycle Order successfully captured | Standard order confirmation |
| Cycle Order capture failed | Payment failure notification + recovery instructions |
| Recycling retry attempted (some configurations) | Optional retry notification |
| Recycling exhausted -> `Failed` | "Action required" notification |
| Payment method updated | Confirmation of change |
| Subscription paused / resumed / cancelled | Status notification |
| Continuity order reminder | Pre-cycle reminder ("Your next order ships in N days") |
| Pause-limit reached | Auto-reactivation notification |

Templates live in the site theme. Localization, branding, and the exact copy are operator-configurable.

### Event notifications — billing-relevant topics

| Topic | Fires when |
|-------|-----------|
| `subscription.errored` | Capture failed; entered recycling |
| `subscription.statuschanged` | Includes `Errored -> Active` (recycling success) and `Errored -> Failed` |
| `subscription.paymentupdated` | Payment method changed on the Subscription |

Order-level capture events fire on the Order topics (e.g., `order.paymentcaptured`) as well. Subscribe to both surfaces for end-to-end visibility: subscription-level for lifecycle, order-level for the per-cycle financial event.

## Installments Are Not Subscriptions

Installment plans share part of the Subscription Commerce surface but are a **different shape** from recurring subscriptions. Conflating them produces wrong AR projections and broken refund handling.

Configured at **System -> Settings -> Installment Plans** (must be enabled by Kibo Support first).

| Field | Notes |
|-------|-------|
| `Installment Plan Code` | Assigned to the subscription via `installmentPlanCode` |
| `Number of Installments` | Total payments including the initial |
| `First Installment Amount` | Optional — blank = auto-split |
| `Prorate Shipping Amount` | Toggle — split shipping or load into first payment |
| `Installment Frequency` | Days between payments |

**Order metadata when installments are active:**

```json
{
  "isInstallmentOrder": true,
  "installmentNumber": 2,
  "orderType": "initialSubscription"
}
```

**Key differences from continuity orders:**

- Installment captures all happen against **one Order**. The Order sits in `Fulfilled` until **all** installments collect; only then does it move to `Completed`.
- Installments are **per-Order**, not per-Subscription. They do not roll forward onto continuity orders.
- A Subscription with an `installmentPlanCode` can have both an installment plan on the initial Order **and** an ongoing continuity cadence. The two billing pipelines are independent.

**Anti-pattern:** modeling installments as subscriptions that recur N times then cancel. They aren't subscriptions — they are an installment surface on a single Order. AR projection code that treats them as forward-rolling subscriptions overstates future revenue.

## Anti-Pattern / Recommended-Pattern Pairs

### Custom retry loop on capture failure

```typescript
// Wrong — bypasses Recycling Rules, ignores configured time slots, double-charges customers
async function captureWithRetry(orderId: string) {
  for (let attempt = 0; attempt < 5; attempt++) {
    const result = await capturePayment(orderId);
    if (result.success) return result;
    await sleep(60_000 * (attempt + 1));
  }
  throw new Error('exhausted retries');
}
```

```typescript
// Recommended — let Kibo's Payment Recycling handle it
// On capture failure, the Subscription moves to Errored automatically.
// Subscribe to subscription.errored and surface to CSR tooling;
// recycling re-attempts on the configured schedule.
```

### Wildcards in Recycling Reason Code

```
# Wrong — Kibo does not document wildcard matching
Recycling Reason Code: 05*
```

```
# Recommended — one rule per exact decline code, per brand
Recycling Reason Code: 05
Recycling Reason Code: 0500
Recycling Reason Code: 51
# ... audit actual gateway codes returned and configure each
```

### Treating `Failed` as recoverable automatically

```typescript
// Wrong — recycling has already given up
if (subscription.status === 'Failed') {
  await retryCapture(subscription.id);
}
```

```typescript
// Recommended — Failed is the manual-intervention bucket
if (subscription.status === 'Failed') {
  await notifyCSR(subscription.id);
  await sendCustomerActionRequiredEmail(subscription.email, subscription.id);
}
```

### One-time PSP flow for off-session captures

```typescript
// Wrong — on-session 3DS challenge for a continuity capture has no cardholder present
await psp.charge({
  paymentMethod: token,
  amount: order.total,
  threeDS: { challenge: 'required' },
});
```

```typescript
// Recommended — capture with off-session / MIT intent
await psp.charge({
  paymentMethod: token,
  amount: order.total,
  offSession: true,
  merchantInitiated: true,
  recurringIndicator: true,
});
```

(Configured at the PSP integration level — verify the specific gateway's flag names.)

### Storing PAN on the Subscription

```typescript
// Wrong — expands PCI scope and the shape doesn't support it
await updateSubscription(id, {
  payment: { cardNumber: '4111111111111111' },
});
```

```typescript
// Recommended — Subscription references a tokenized Card on the customer account
await addCardToCustomer(customerId, /* PSP-tokenized payment method */);
await updateSubscription(id, {
  payment: { paymentMethodId: tokenizedCardId },
});
```

### Modeling installments as subscriptions

```typescript
// Wrong — installments do not roll forward
const projectedRevenue = subscription.installmentPlanCode
  ? subscription.frequency.value * 12
  : 0;
```

```typescript
// Recommended — installments are per-Order; continuity is separate
const installmentAR = await getInstallmentOrders({ status: 'Fulfilled' })
  .then(orders => orders.reduce((sum, o) => sum + o.remainingInstallmentTotal, 0));

const continuityProjection = await getActiveSubscriptions()
  .then(subs => subs.reduce((sum, s) => sum + projectMRRForSubscription(s), 0));
```

## Checklist

Before going live with subscription billing:

- [ ] PSP supports tokenization, off-session captures, and merchant-initiated transactions (MIT).
- [ ] PSP integration flags continuity captures as off-session / MIT / recurring.
- [ ] Initial Order checkout runs 3DS / SCA on-session, stores a token suitable for off-session reuse.
- [ ] Payment Recycling Rules are configured for the actual decline codes the PSP returns (audit real codes, not assumed codes).
- [ ] Per-brand decline-code rules exist where brands return different codes for the same logical reason.
- [ ] `Bump Expiry Year` is enabled for the "expired card" decline if appropriate.
- [ ] CSR tooling has a "Failed" bucket separate from "Errored" — Errored is auto-recovering, Failed needs human action.
- [ ] Customer notification templates (capture failure, recovery, action-required) are localized and branded.
- [ ] No code retries capture in an application-level loop; recycling is the only retry path.
- [ ] Installments are modeled as per-Order, not per-Subscription; AR projection separates the two.
- [ ] `nextOrderDate` post-pause-resume behavior is verified in a sandbox before customer-facing UX promises a specific date.
- [ ] Trial first-charge timing is traced end-to-end through scheduler + lead-time + recycling for the specific configured values.
- [ ] Test environments use `POST /commerce/subscriptions/{id}/orderNow` to force cycles rather than waiting for the ~30 min scheduler tick.
- [ ] `subscription.errored` and `subscription.statuschanged` event handlers are wired to CSR alerting.
