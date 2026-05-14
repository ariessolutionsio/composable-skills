# Cancellation, Pause, and Retention

Cancellation in Kibo Subscriptions is terminal and immediate. There is no `cancelAtPeriodEnd` flag. Pause is the only retention pattern that preserves customer history and supports resumption without full re-onboarding. Get the pause-vs-cancel decision right or the customer experience will silently degrade.

## Table of Contents
- [Cancellation Is Terminal and Immediate](#cancellation-is-terminal-and-immediate)
- [Pause Is the Only Retention Pattern](#pause-is-the-only-retention-pattern)
- [Pause vs Cancel — Decision Table](#pause-vs-cancel--decision-table)
- [Pause Mechanics](#pause-mechanics)
- [Resume Mechanics](#resume-mechanics)
- [Cancellation Reason Codes](#cancellation-reason-codes)
- [Win-Back and Reactivation](#win-back-and-reactivation)
- [Customer-Side Communication](#customer-side-communication)
- [Operator-Initiated vs Customer-Initiated](#operator-initiated-vs-customer-initiated)
- [In-Flight Orders Are Not Cancelled With the Subscription](#in-flight-orders-are-not-cancelled-with-the-subscription)
- [Approximating End-of-Period Cancellation](#approximating-end-of-period-cancellation)
- [Anti-Pattern / Recommended-Pattern Pairs](#anti-pattern--recommended-pattern-pairs)
- [Checklist](#checklist)

## Cancellation Is Terminal and Immediate

`Cancel` moves the Subscription to `Cancelled` immediately. No further continuity Orders are generated. **There is no documented `cancelAtPeriodEnd` flag in Kibo.** The SKILL.md draft in some earlier iterations mentioned end-of-period cancellation as a configurable enum — that is wrong. The references must get this right.

Once `Cancelled`:

- No new continuity Orders cut.
- The scheduler skips the Subscription.
- Recycling does not retry it (recycling only runs on `Errored`).
- There is **no documented "reactivate a Cancelled subscription" action.** The closest API path — `PUT /commerce/subscriptions/{id}` with `status: "Active"` — is **not documented to work on a Cancelled subscription**. Treat `Cancelled` as terminal in code.

If your business model genuinely requires end-of-period cancellation (the customer paid for the cycle; they should get the value of that cycle before access stops), see [Approximating End-of-Period Cancellation](#approximating-end-of-period-cancellation) below for the documented workarounds.

**API:**

```typescript
async function cancelSubscription(subscriptionId: string, reasonCode: string) {
  // Cancellation requires a Reason Code from the configured list.
  await updateSubscriptionStatus(subscriptionId, 'Cancelled', { reasonCode });
}
```

**Cancellation Reason Code is required.** See [Cancellation Reason Codes](#cancellation-reason-codes) below.

## Pause Is the Only Retention Pattern

Pause moves the Subscription to `Paused`. The Subscription continues to exist, the customer history is preserved, and the Subscription can be resumed without re-onboarding.

This is the load-bearing retention distinction:

| Behavior | `Paused` | `Cancelled` |
|----------|----------|-------------|
| Generates continuity Orders | No | No |
| Can be resumed | Yes (`Paused -> Active`) | **No** — terminal |
| Preserves customer history | Yes | Yes (but not addressable for resumption) |
| Auto-recovery | Yes — pause-limit auto-reactivates | None |
| Customer must re-onboard to come back | No | Yes — full re-subscribe |
| Email notifications fire | Yes (paused / reactivation reminder / pause-limit reached) | Yes (cancellation confirmation) |
| Lifecycle | Reversible | Terminal |

**The default retention play is Pause, not Cancel.** When the customer says "I want to stop," the right operator response in most cases is to offer pause first and only cancel if the customer insists. Cancellation throws away the LTV signal: the customer's payment method, history, preferences, and addressable identity all become inert. Pause keeps them addressable.

## Pause vs Cancel — Decision Table

| Customer situation | Right action |
|--------------------|--------------|
| "Going on vacation for 3 months" | Pause |
| "Have too much product, need to stretch the cadence" | Change frequency (not pause, not cancel) |
| "Want to skip just this month" | Skip Next Order (see `modifications.md`) |
| "Cash flow is tight this quarter" | Pause with reactivation reminder |
| "Don't like the product anymore" | Cancel — collect reason code for churn analysis |
| "Moved abroad / address no longer serviceable" | Cancel — operator-side |
| "Found a competitor I like better" | Cancel — collect competitive-loss reason code |
| "Account holder died / fraud" | Cancel — operator-side, no win-back |

The right question on the cancellation surface is "are you sure you want to lose your account history?" Not "are you sure you want to cancel?" The latter doesn't capture what's actually lost.

## Pause Mechanics

**Pause moves `Active -> Paused`.**

| Setting | Effect |
|---------|--------|
| Pause Subscription Duration Limits | Caps how long a pause may run before auto-reactivation |
| Auto-reactivate after N continuity-order cycles | Operator can configure a Subscription to auto-resume after a configured number of cycles |

**Pause duration: bounded or open-ended?** Both are supported.

- **Bounded:** the operator (or customer, via storefront self-service) sets a Subscription to auto-reactivate after N cycles, or the system-wide "Pause Subscription Duration Limits" setting caps the maximum pause length.
- **Open-ended:** without a duration cap, pause persists until manual resume.

The exact UI / API surface for setting a per-Subscription pause-duration limit is **unknown — verify against your live tenant**. The system-wide cap and the auto-reactivate-after-N-cycles options are documented; per-Subscription overrides are not consistently described.

**Effects of pausing different statuses:**

| Pre-pause status | Effect |
|------------------|--------|
| `Active` | Moves to `Paused`. Scheduler stops cutting cycles for this Subscription |
| `Errored` | **Unknown — verify in a sandbox.** The platform's behavior when pausing a Subscription mid-recycling is not pinned down in the research. Two possibilities: (a) pause overrides recycling and the Subscription holds at `Paused` until resumed, dropping the recycling budget; (b) pause is rejected while in `Errored`. Test before relying on either behavior. |
| `Failed` | Likely not pausable directly — `Failed` is the manual-intervention bucket; the recovery path is "update payment method + reactivate to `Active`," not "pause." Verify if your CSR tooling needs this. |
| `Cancelled` | Not applicable — terminal |

**Effect on `nextOrderDate` during pause.** The documented behavior is "preserved as calculated by the original order date and frequency." The pre-pause `nextOrderDate` is held while the Subscription is `Paused`. The scheduler does not advance it.

## Resume Mechanics

**Resume moves `Paused -> Active`.**

**Crucial:** resume does **not** generate an immediate continuity Order. The schedule is preserved. Next cycle cuts according to `nextOrderDate`.

**Effect on `nextOrderDate` on resume:** here the documentation is ambiguous and the exact behavior is **unknown — verify against a live tenant**. The three plausible interpretations:

1. **Verbatim:** the pre-pause `nextOrderDate` is restored as-is. If it is now in the past, the scheduler cuts a continuity Order at the next tick.
2. **Recomputed from cadence:** the next `nextOrderDate` on or after `now` derived from the original order date and frequency (preserving the cadence's calendar alignment).
3. **`now` + `frequency`:** a clean reset, treating resume as a new cycle start.

The docs say "preserved as calculated by the original order date and frequency cadence," which leans toward interpretation 2. But "preserved" can also mean interpretation 1. Test it in your sandbox before promising customers a charge date — and surface the post-resume `nextOrderDate` in the storefront after resume so the customer sees the actual computed value.

**Effects of resuming different statuses:**

| Pre-resume status | Effect |
|-------------------|--------|
| `Paused` | Moves to `Active`. Schedule resumes per the rules above |
| `Errored` | Resume is not the operation here — successful recycling moves it to `Active` automatically |
| `Failed` | The CSR pattern is: update payment method, then move Subscription back to `Active`. This is "manual reactivation," not "resume" — different semantic. The unrecovered failed cycle Order may need separate handling |
| `Cancelled` | **Not possible.** Terminal status. Re-create the Subscription instead |

## Cancellation Reason Codes

Cancellation requires a **Reason Code** from the configured Subscription Reasons list. Without one, the cancel call is rejected.

**Where it's configured:** System -> Settings -> General -> Subscriptions tab.

**API:** `GET /commerce/subscriptions/reasons` returns the configured list for the tenant.

**Default reason codes:** **unknown — verify against your instance.** The research did not surface an authoritative default set. The reason list is instance-configurable; common categories seen in subscription commerce broadly (your tenant's list will differ):

| Category | Example codes |
|----------|---------------|
| Voluntary, product fit | `TOO_MUCH_PRODUCT`, `NOT_USING`, `DONT_LIKE_PRODUCT` |
| Voluntary, price | `TOO_EXPENSIVE`, `BUDGET_CUT` |
| Voluntary, competitor | `SWITCHED_COMPETITOR`, `BETTER_PRICE_ELSEWHERE` |
| Voluntary, lifestyle | `MOVING`, `NO_LONGER_NEEDED` |
| Involuntary | `PAYMENT_ISSUES`, `ADDRESS_NOT_SERVICEABLE`, `FRAUD` |
| Operator | `CSR_INITIATED`, `COMPLIANCE_HOLD`, `DUPLICATE_SUBSCRIPTION` |

Reason codes drive churn-cause reporting. The wider the reason set, the more granular the churn analysis. Too granular and the data is sparse per code. The reason-code list is usually a product / customer-success decision, not a developer decision — but the developer needs to make sure the cancellation flow always sends one.

```typescript
// Fetch the list, validate before send
const reasons = await fetch('/commerce/subscriptions/reasons');
const validCodes = reasons.map(r => r.code);

async function cancelWithReason(subscriptionId: string, reasonCode: string) {
  if (!validCodes.includes(reasonCode)) {
    throw new Error(`Invalid reason code: ${reasonCode}`);
  }
  await updateSubscriptionStatus(subscriptionId, 'Cancelled', { reasonCode });
}
```

## Win-Back and Reactivation

**Cancelled subscriptions cannot be reactivated.** Re-creation is the only path back.

The recovery pattern:

1. Identify Cancelled subscriptions of interest (date range, reason code).
2. Run an external win-back campaign (email, ads, offer code).
3. When the customer responds:
   - **Storefront re-subscribe:** customer adds the product to cart, picks frequency, checks out — normal flow that creates a new Subscription.
   - **Offline / CSR-created:** operator uses the offline-order flow to create a new Subscription on the customer's behalf with the customer's existing account.

Either path produces a **new** Subscription with a new `id` and `subscriptionNumber`. The old Cancelled Subscription stays in its terminal state for reporting; the new Subscription is the live one.

**Acquiring back customer history.** The customer's CustomerAccount is unaffected by Subscription cancellation — addresses, payment methods, order history all remain. The new Subscription inherits the customer account, so the customer is not re-onboarded in the data sense (their account is intact). They are re-onboarded in the Subscription sense — the new Subscription has no history with the customer relative to the prior cadence.

**Reactivation reminder email.** Kibo emits a reactivation reminder near the end of a paused window (the docs note this exists; the exact trigger condition is **unknown — verify in your tenant**). This is the platform's built-in win-back for `Paused`. For `Cancelled`, win-back is operator-side — external CRM / marketing automation.

**Anti-pattern:** treating Cancelled and Paused as interchangeable in win-back automation. They aren't. Cancelled customers need a re-subscribe path (storefront link to PDP, offline-order flow); Paused customers need a resume path (one-click reactivation). The CTAs are different and the conversion mechanics are different.

## Customer-Side Communication

Email notifications fire on retention-relevant events. Templates live in the site theme; copy, branding, and localization are operator-configurable.

| Trigger | Email |
|---------|-------|
| Subscription paused | Confirmation of pause + pause duration / auto-resume info if applicable |
| Subscription resumed | Confirmation of resume + the post-resume `nextOrderDate` |
| Subscription cancelled | Confirmation of cancellation + win-back offer if configured |
| Reactivation reminder | Near the end of a paused window — invites the customer to resume |
| Pause-limit reached | Notification that the system-wide or per-Subscription pause limit has been reached and the Subscription is auto-reactivating |
| Recycling exhausted -> `Failed` | "Action required" — different surface than cancellation, but ends in the same place if the customer doesn't act |

**Post-resume `nextOrderDate` in the resume confirmation email** is critical for managing customer expectations given the ambiguity in resume `nextOrderDate` behavior. The customer should see the actual computed next charge date in their inbox.

**Cancellation confirmation email** should restate the cancellation reason (the reason code's human label, not the code itself), confirm there will be no further charges, and include a path to re-subscribe if the operator wants to support win-back inline.

## Operator-Initiated vs Customer-Initiated

Different auth scopes, same Subscription mutation. The distinction matters for audit and for the actions surface.

| Surface | Auth | Actions available |
|---------|------|-------------------|
| Customer storefront self-service | Customer-scoped OAuth token | Pause, resume, cancel (with reason code), skip, change frequency, change shipping / payment |
| Operator admin | Operator-scoped OAuth token | Everything above plus override pricing, force-activate a `Failed` Subscription, edit attributes, edit on behalf of the customer |

**Audit trail.** The Subscription's history log records whether a state transition was customer-initiated or operator-initiated. Reporting that wants to distinguish "voluntary cancel" from "operator cancel" (compliance, fraud) reads this log. Both still produce `subscription.cancelled` events — the event payload itself may not carry the actor identity; verify against your live tenant if you need it on the event.

**Forbidden actions on a customer-scoped token.** Adjust pricing, override reason code, force-activate a `Failed` Subscription. These are operator-only. A storefront making them with a customer-scoped token gets a 403.

## In-Flight Orders Are Not Cancelled With the Subscription

This is a load-bearing distinction that bites refund-handling code.

**When a Subscription is cancelled, any in-flight continuity Orders are not automatically cancelled.** Continuity Orders are first-class Orders that flow through Kibo OMS — once cut, they have their own lifecycle (allocation, routing, fulfillment, capture). Cancelling the parent Subscription does not retroactively cancel an Order that has already been cut and is mid-fulfillment.

The implications:

- If the operator wants to stop the in-flight Order from shipping, that's an Order-side cancel via the OMS, not a Subscription-side cancel.
- The customer's expectation is usually "I cancelled, so the order I have not received yet should also be cancelled." Without explicit operator action, the in-flight Order ships and the customer is billed.
- This is a refund / chargeback risk: cancellation copy that says "no further charges" while an in-flight Order is mid-capture will be wrong if the in-flight Order goes through.

**The right pattern:**

1. Customer clicks Cancel on the storefront.
2. The flow checks whether there is an in-flight cycle Order (cut but not yet captured / shipped).
3. If yes, prompt the customer: "Your next order, scheduled to ship on {date}, has already been prepared. Do you want to cancel that order as well, or let it ship?"
4. Based on the response: cancel the Order via the OMS surface in addition to cancelling the Subscription, or let the Order proceed.

The same pattern applies to operator-initiated cancellation. CSR tooling should expose the in-flight Order state alongside the cancel button.

## Approximating End-of-Period Cancellation

If the business model requires "the customer paid for this cycle; they get the cycle's value before access stops," Kibo gives two documented workarounds:

**Option A: Skip then cancel.**

1. Customer requests cancellation.
2. Operator (or storefront automation) sets the Subscription to skip all remaining cycles until the end of the prepaid period.
3. After the final continuity Order in the prepaid period ships, the operator cancels the Subscription.

**Option B: Pause then cancel.**

1. Customer requests cancellation.
2. Operator pauses the Subscription until the end of the prepaid period.
3. After the period ends, the operator cancels.

Both are operator-side automation. Neither is a built-in flag. Both produce a final `Cancelled` state with no resumption.

If the business model is "customer pays per cycle, no prepayment, just stop the next cycle," cancel directly. There is no in-flight cycle to honor. The cancel-is-immediate semantics match the business model already.

**The bug pattern this prevents:** designing the cancellation surface as if `cancelAtPeriodEnd: true` exists, then discovering at integration time that it doesn't, then frantically hacking together a "schedule a cancellation" cron job that doesn't survive the next platform upgrade. The skip-then-cancel and pause-then-cancel patterns above are the supported approaches; build the automation explicitly.

## Anti-Pattern / Recommended-Pattern Pairs

### Designing for `cancelAtPeriodEnd`

```typescript
// Wrong — no such flag exists
await fetch(`/commerce/subscriptions/${id}`, {
  method: 'PUT',
  body: JSON.stringify({
    ...current,
    cancelAtPeriodEnd: true, // not a real field
  }),
});
```

```typescript
// Recommended — explicit skip-then-cancel or pause-then-cancel automation
async function cancelAtEndOfPrepaidPeriod(
  subscriptionId: string,
  lastPaidCycleDate: string,
  reasonCode: string,
) {
  // Pause until the prepaid period ends
  await pauseSubscription(subscriptionId, { until: lastPaidCycleDate });

  // Schedule the cancellation job
  await scheduleJob({
    runAt: lastPaidCycleDate,
    task: () => cancelSubscription(subscriptionId, reasonCode),
  });
}
```

### Reactivating a Cancelled Subscription

```typescript
// Wrong — Cancelled is terminal; PUT-ing status: Active is not documented to work
await updateSubscriptionStatus(cancelledSubscriptionId, 'Active');
```

```typescript
// Recommended — create a new Subscription with the old customer's account
const old = await getSubscription(cancelledSubscriptionId);
const fresh = await fetch('/commerce/subscriptions', {
  method: 'POST',
  body: JSON.stringify({
    customerAccountId: old.customerAccountId,
    items: old.items,
    frequency: old.frequency,
    fulfillmentInfo: old.fulfillmentInfo,
    payment: old.payment,
    // ... full payload
  }),
});
// fresh has a new id and subscriptionNumber; old stays Cancelled
```

### Cancel without a reason code

```typescript
// Wrong — cancellation requires a reason code; this call is rejected
await updateSubscriptionStatus(subscriptionId, 'Cancelled');
```

```typescript
// Recommended — always send a reason code from the configured list
const reasons = await fetch('/commerce/subscriptions/reasons').then(r => r.json());
const reasonCode = pickReasonCode(reasons, userSelection);
await updateSubscriptionStatus(subscriptionId, 'Cancelled', { reasonCode });
```

### Cancel when the customer wanted to pause

```typescript
// Wrong — cancellation surface as the only "I want to stop" option
function StopSubscriptionButton({ id }: { id: string }) {
  return <button onClick={() => cancel(id)}>Cancel</button>;
}
```

```typescript
// Recommended — offer Pause first, with Cancel as the destructive secondary
function StopSubscriptionDialog({ id }: { id: string }) {
  return (
    <>
      <button onClick={() => pause(id)}>Pause my subscription</button>
      <p>You can resume at any time, and your account history is preserved.</p>
      <button onClick={() => cancel(id)} className="secondary destructive">
        Cancel permanently
      </button>
      <p>Cancellation is final. To come back, you will need to start a new subscription.</p>
    </>
  );
}
```

### Cancellation copy that ignores in-flight Orders

```text
// Wrong — implies no charges, but an in-flight Order will still capture
"Your subscription has been cancelled. You will not be charged again."
```

```text
// Recommended — explicit about any in-flight Order
"Your subscription has been cancelled. Your final order, shipping on {inFlightOrderDate},
 has already been prepared and will be charged and shipped. After that, you will not be charged again."
```

### Treating Cancelled and Paused identically in win-back

```typescript
// Wrong — sends both groups the same "click here to resume" email
const winBackTargets = await getSubscriptionsByStatus(['Paused', 'Cancelled']);
await sendCampaign(winBackTargets, 'resume-link');
```

```typescript
// Recommended — different CTAs, different mechanics
const paused = await getSubscriptionsByStatus(['Paused']);
await sendCampaign(paused, 'one-click-resume'); // links to resume action

const cancelled = await getSubscriptionsByStatus(['Cancelled']);
await sendCampaign(cancelled, 'resubscribe-pdp-with-offer'); // links to PDP with offer code
```

## Checklist

Before going live with cancellation, pause, and retention flows:

- [ ] No code references `cancelAtPeriodEnd` or expects an end-of-period cancellation flag.
- [ ] No code attempts to reactivate a `Cancelled` Subscription via status update.
- [ ] Cancellation always sends a Reason Code from the configured list (`GET /commerce/subscriptions/reasons`).
- [ ] The "stop my subscription" surface offers Pause first, with Cancel as the secondary destructive action.
- [ ] Cancellation confirmation copy explicitly addresses any in-flight cycle Order — does it ship or get cancelled.
- [ ] Resume confirmation email includes the post-resume `nextOrderDate` (the platform's exact computation is verified in a sandbox).
- [ ] Win-back automation distinguishes Paused (one-click resume) from Cancelled (re-subscribe PDP + offer).
- [ ] Re-subscribing a previously-Cancelled customer creates a new Subscription on the existing CustomerAccount, not a "reactivate" call.
- [ ] CSR tooling shows in-flight cycle Order status alongside the Cancel button.
- [ ] Operator-initiated and customer-initiated cancellations are distinguishable in the audit trail.
- [ ] `subscription.cancelled` and `subscription.paused` event handlers are wired to retention / churn analysis pipelines.
- [ ] System-wide Pause Subscription Duration Limits are configured deliberately; pause-limit-reached emails are customized.
- [ ] Reactivation reminder email is customized (or disabled) per the operator's retention strategy.
- [ ] Reason-code list is reviewed with customer success / product before launch — wide enough to capture cause-of-churn, narrow enough that each code has non-trivial volume.
- [ ] Cancelling a `Paused` or `Errored` Subscription's behavior is verified in a sandbox before relying on it.
