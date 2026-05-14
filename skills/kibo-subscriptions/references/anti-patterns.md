# Common Anti-Patterns

A quick-reference index of the most frequent and damaging mistakes in Kibo Subscriptions implementations. Each entry summarizes the problem and points to the domain file with the full explanation and recommended pattern.

## Table of Contents
- [Lifecycle Anti-Patterns](#lifecycle-anti-patterns)
- [Billing & Dunning Anti-Patterns](#billing--dunning-anti-patterns)
- [Modification Anti-Patterns](#modification-anti-patterns)
- [Retention & Cancellation Anti-Patterns](#retention--cancellation-anti-patterns)
- [Platform & Integration Anti-Patterns](#platform--integration-anti-patterns)
- [Quick-Scan Review Checklist](#quick-scan-review-checklist)

## Lifecycle Anti-Patterns

### Treating the Subscription as the Revenue Unit

Revenue lives on continuity Orders, not on the Subscription. The Subscription is a template that generates Orders; each cycle is a first-class Order with its own line totals, tax, and capture. `SUM(subscription.total)` returns the wrong number — there is no per-cycle revenue field on the Subscription. Compute MRR by summing continuity Orders in the period. See `subscription-model.md`.

### Modeling Plans as a Separate Entity

There is no `Plan` resource in Kibo Subscriptions. Configuration lives in three places: product type attributes (`Subscription Mode`, `Subscription Frequency`, `Trial Days`), product-level overrides, and the per-cart-item `SubscriptionInfo` block. Engineers coming from Stripe Billing, Recharge, or Chargebee will look for `/plans` and waste hours not finding it. The Plan is encoded on the product type, not as a standalone entity. See `subscription-model.md`.

### Confusing `Errored` with `Failed`

`Errored` means payment failed and Payment Recycling is retrying it. `Failed` means recycling exhausted its retry budget and manual intervention is required. They are distinct states with different operational meaning. Code that retries `Failed` captures bypasses the policy that has already given up; reports that count both as "involuntary churn" overstate churn because Errored subscriptions often recover. See `subscription-model.md` and `billing-dunning.md`.

### Reactivating a Cancelled Subscription

`Cancelled` is terminal. There is no documented action to move a Cancelled Subscription back to Active. The recovery path is re-creation: either an offline-order flow (CSR creates a new Subscription) or storefront re-subscribe (customer goes through checkout again). UI affordances that show a "Reactivate" button on a Cancelled Subscription will fail at the API call. See `subscription-model.md`.

### Counting Multi-Frequency Cart Items as One Subscription

Different frequencies in one cart produce **multiple** Subscriptions, not one Subscription with mixed cadences. Same-frequency items with the same shipping address consolidate; different-frequency or different-address items split. Cross-subscription customer reporting must aggregate by `customerAccountId`, not by `subscriptionNumber`. See `subscription-model.md`.

### Polling for Status Changes

Subscribe to `subscription.statuschanged`, `subscription.activated`, `subscription.cancelled`, `subscription.errored`, `subscription.paused`, and `subscription.paymentupdated` event topics. Polling a Subscription's status on a timer wastes API budget, adds latency to dunning workflows, and misses brief state transitions. The event payload carries only entity IDs — fetch full state from `GET /commerce/subscriptions/{id}` after the event. See `subscription-model.md`.

## Billing & Dunning Anti-Patterns

### Custom Retry Loop on Capture Failure

Payment Recycling is the configured retry policy. Application-level retry loops bypass it: they ignore the configured time slots, ignore the per-brand decline-code rules, may double-charge the customer if recycling also runs, and produce notifications outside the platform's template system. On capture failure, the Subscription moves to `Errored` automatically; that is the signal to surface to CSR tooling, not a signal to retry from your code. See `billing-dunning.md`.

### Wildcards in Recycling Reason Code

`Recycling Reason Code` is compared byte-for-byte against `payments.interactions.gatewayResponseCode`. Wildcards aren't documented. A rule with `05*` matches nothing. A rule with `05` does not match `0500`. Audit the actual decline codes the PSP returns and configure one rule per exact code, per card brand, before going live. This is the most common silent failure in Kibo dunning. See `billing-dunning.md`.

### Dunning That Fires While Subscription Is `Active`

Recycling only runs on `Errored`. A "fail fast and retry now" design has to wait for the status flip from `Active` to `Errored` — there is no preemptive retry. Code that calls a recycling endpoint directly while the Subscription is Active will not trigger a retry. The retry is triggered by the capture failure itself moving the Subscription into `Errored`. See `billing-dunning.md`.

### One-Time PSP Flow for Off-Session Captures

Continuity captures are off-session, merchant-initiated transactions (MIT). The PSP integration must support MIT and recurring-indicator flags. A configuration that requires SCA on every charge lands every continuity capture in `Errored`, recycling exhausts, the Subscription flips to `Failed`. This is a fit-check at platform-selection time, not a setting you flip later — verify the chosen gateway's MIT support before launch. See `billing-dunning.md`.

### Storing Card Data on the Subscription

The Subscription's `payment` block is a reference to a tokenized Card on the customer's `CustomerAccount`. The PAN never lives on the Subscription record. Attempting to write card data directly to the Subscription expands PCI scope and the shape doesn't support it anyway. Tokenize via the PSP, attach to the customer account, then point the Subscription's `payment` block at the tokenized card. See `billing-dunning.md`.

### Treating `Failed` as Recoverable Automatically

Recycling has already given up by the time the Subscription reaches `Failed`. Auto-retry from application code at this point charges the customer outside policy and produces audit-trail noise. `Failed` is the manual-intervention bucket: CSR contacts the customer, updates the payment method, reactivates the Subscription manually. Build CSR tooling, not auto-retry. See `billing-dunning.md`.

### Modeling Installments as Subscriptions

Installment plans are per-Order. They live on a single Order that sits in `Fulfilled` until all installments collect. They do not roll forward onto continuity Orders. AR projection that treats `installmentPlanCode` as "this Subscription recurs N more times" overstates future revenue. Model installments as a per-Order AR balance, separate from continuity-Order projections. See `billing-dunning.md`.

## Modification Anti-Patterns

### Sending PUT Updates as Partial Objects

`PUT /commerce/subscriptions/{id}` replaces the resource. Omitted fields null out. There is no version-mismatch rejection, no optimistic concurrency check — the API silently accepts the partial body and blanks the missing fields. Always GET the current Subscription, mutate in memory, PUT the full payload back. This is the single most common source of subscription bugs in Kibo. See `subscription-model.md`.

### Assuming Kibo Computes Mid-Cycle Proration

There is no proration engine. Mid-cycle item changes, frequency changes, and SKU swaps reprice the **next** continuity Order, not the in-flight one. Whatever was captured for the current cycle stays captured. Code that expects Kibo to issue a partial credit on mid-cycle changes will not get one. If proration is a business requirement, compute it externally and apply it as an adjustment to the next continuity Order. See `subscription-model.md`.

### Designing a Plan-Upgrade Mutation

There is no "switch plan" mutation. The closest primitives are: modify items (add/remove/change-quantity) and change frequency. Operators implementing tier upgrades typically remove the old item, add the new one, accept the reprice on the next cycle. There is no atomic "upgrade from Basic to Pro" call. See `subscription-model.md`.

### Frequency Changes on Bundle Subscriptions Without Checking Item Allow-Lists

Frequency change is constrained to frequencies supported by **every** item on the subscription. A bundle whose constituent products have different `Subscription Frequency` allowed-lists will refuse a frequency change that violates any of them. The error surfaces at the API call, not earlier. Query each product's allowed frequencies and intersect before showing frequency choices in the storefront UI. See `subscription-model.md`.

### Hardcoded Next-Charge-Date Computation

`nextOrderDate` math depends on the previous order date, the current frequency, the pause history, the `Order Now Resets Next Order Date` setting, the `Create Continuity Order X Days Before Next Order Date` lead time, and the calendar-vs-fixed-days distinction (`1 Month` vs `30 Days`). Reimplementing this in application code drifts from the platform's actual schedule. Read `subscription.nextOrderDate` and display that — don't recompute. See `billing-dunning.md`.

## Retention & Cancellation Anti-Patterns

### Designing for `cancelAtPeriodEnd`

Cancel is **terminal and immediate** in Kibo. There is no `cancelAtPeriodEnd` flag. UI patterns that promise "you'll keep access until your renewal date" cannot be implemented with a single cancel call. The approximation: skip all remaining cycles and cancel after the last continuity Order ships, or pause until period end and cancel then. See `retention.md` for the skip-then-cancel and pause-then-cancel workaround patterns.

### Pause Modeled as a Temporary Cancel

Pause and Cancel are distinct lifecycle paths. Pause is reversible (auto-reactivates after N cycles or manual). Cancel is terminal. Treating Pause as "cancel then re-create" loses the retention signal, forces re-onboarding, and breaks customer LTV reporting. Pause is the primary retention lever in Kibo — use it. See `retention.md`.

### Skipping the Cancellation Reason Code

Cancellation requires a Reason Code from the configured Subscription Reasons list (managed at System -> Settings -> General -> Subscriptions tab). Reason codes drive churn-cause reporting; without them, the operator can't separate "too expensive" from "moving away" from "got it elsewhere." Capture the reason at cancel time in the storefront/CSR UI and pass it on the cancel call. See `retention.md`.

### Address Change Applies to Current Cycle

Address changes apply to the **next** continuity Order onward, not the in-flight one. If a cycle Order has already been cut (which happens at `nextOrderDate - lead time`), the address on that Order is locked. Customer-facing UX should warn that the address change takes effect from the next cycle, and the storefront should expose "Edit Next Order Only" as a separate affordance for one-time-only changes. See `subscription-model.md`.

### Reactivating a Cancelled Subscription via PUT

`PUT /commerce/subscriptions/{id}` with `status: "Active"` on a Cancelled Subscription will not work as a reactivation. Cancelled is terminal and the platform does not document a reactivation path. The recovery path is re-create the Subscription via offline-order flow or storefront re-subscribe. See `subscription-model.md`.

## Platform & Integration Anti-Patterns

### Expecting Immediate Continuity-Order Creation in Tests

The internal scheduler runs every ~30 minutes. Creating a Subscription in a sandbox does not immediately produce a continuity Order. End-to-end tests that expect an Order within seconds will fail. Use `POST /commerce/subscriptions/{id}/orderNow` to force a cycle, or assert on `subscription.nextOrderDate` rather than expecting an Order to exist. See `billing-dunning.md`.

### Treating the Subscription's First Order as a Continuity Order

The initial Order at checkout has `orderType: "initialSubscription"` — it's not a continuity Order. Continuity Orders begin after the initial. Reporting that lumps the initial Order in with continuities will misattribute first-purchase metrics; reporting that filters them out cleanly needs to read `orderType`. See `subscription-model.md`.

### Mutating Cycle Orders Across Cycles

Each cycle is its own Order with its own state machine. There is no "amend the previous cycle's Order to include this cycle's items" pattern. Code that tries to mutate an old cycle's Order to track current-cycle changes breaks reporting, refunds, and OMS routing. Treat each cycle Order as immutable after fulfillment. See `subscription-model.md`.

### Conflating `subscription.activated` with `subscription.created`

The Event Notifications catalog lists `subscription.activated`. Whether a separate `subscription.created` topic exists is **unknown**. Designs that subscribe to `subscription.created` may receive no events. Either subscribe to `subscription.activated` as the canonical "subscription started" signal, or verify the topic in a live tenant before depending on it. See `subscription-model.md`.

### Building Storefront Reads Against the Subscription API on Every Page Load

`GET /commerce/subscriptions/{id}` is fine for CSR tooling and storefront My-Account pages, but rendering "you have N active subscriptions" on every page load by calling the API per render burns request budget and adds latency. Cache the list per-session, refresh on subscription-related events. See `subscription-model.md`.

### Ignoring the `subscriptionNumber` vs `id` Distinction

`id` is the API call key. `subscriptionNumber` is the human-readable number used in admin UI search. They are not interchangeable: admin staff search by `subscriptionNumber`; code calls by `id`. Storing only one means CSR tools and code paths can't bridge to each other. Persist both if you need bidirectional lookup. See `subscription-model.md`.

### Treating Multi-Currency as a Per-Subscription Switch

Kibo Subscriptions sets `currencyCode` at creation and does not document a way to mutate it. Whether multi-currency support on a single tenant matches the multi-currency model of Kibo Orders is **unknown**. Verify against the live tenant before designing a multi-currency subscription flow. See `subscription-model.md`.

### Designing the Storefront Self-Service Surface Against the Operator API

The customer-self-service surface (pause, skip, resume, cancel) is documented as available to shoppers with account access, but whether it exposes a separate buyer-scoped API or shares the operator API with customer-scoped tokens is **unknown** in the research. Confirm the auth model before building the storefront so the token strategy and scope set match what's actually supported. See `subscription-model.md`.

### Decoding Subscription IDs to Extract Internal Structure

The Subscription `id` is opaque. Code that pattern-matches on it, parses substrings, or assumes a format is fragile against schema evolution. Use `subscriptionNumber` for human display; pass `id` opaquely for all API operations. See `subscription-model.md`.

### Synchronous Webhook Processing

Webhook receivers should `200 OK` within the 20-second safe ceiling (older docs cite 45 s — treat 20 s as the ceiling; see `api-setup.md`). Heavy synchronous processing in the handler risks the budget and serializes throughput. Persist the raw event durably (with `eventID` for idempotency), ACK fast, process async. The production retry schedule is `5 min → 1 hr → 6 hr → 24 hr → 24 hr`, then expiry at 14 days — the receiver's persistent store is the replay source past that window. See `subscription-model.md`.

### Trusting Webhook Payloads Without Verifying the Source

The webhook payload includes only entity IDs; the receiver fetches full state from the API. That fetch is implicitly authenticated. If the webhook endpoint is public and accepts unsigned payloads, an attacker can trigger spurious state-fetches against arbitrary subscription IDs. Verify the request source (HMAC, IP allowlist, mTLS — whatever the platform supports for the configured endpoint) before fetching detail. See `subscription-model.md`.

### Mixing Customer Emails and Event Notifications in the Same Pipeline

Customer emails (configured at System -> Settings -> General) and event notifications (configured per topic) are different surfaces with different recipients. Customer-facing changes (pause confirmation, payment failure warning) flow through the email surface. System integrations (CSR alerting, ERP sync, churn analytics) flow through the event notification surface. Routing both through a single handler conflates the templating and authorization concerns. See `subscription-model.md` and `billing-dunning.md`.

### Building Reports Against `subscription.status` Alone for Involuntary Churn

`status = Errored` and `status = Failed` are both snapshots — and they mean different things. Subscriptions in `Errored` can still recover on a recycling retry and re-enter `Active`; `Failed` means recycling has exhausted retries and recovery is manual-only. A daily report that only counts `Failed` Subscriptions misses the (often larger) `Errored` cohort that hasn't resolved yet, and the involuntary-churn signal is undercounted. Subscribe to `subscription.statuschanged` and accumulate `Active → Errored → Active` and `Errored → Failed` transitions over the period; the time-series view is the accurate one. See `billing-dunning.md`.

## Quick-Scan Review Checklist

During code review, scan for these:

- [ ] Any code that calls `PUT /commerce/subscriptions/{id}` with a body that is not the result of GET -> mutate -> PUT.
- [ ] Any reference to a `/plans` endpoint or a `Plan` entity in Kibo Subscriptions.
- [ ] Any code that attempts to move a `Cancelled` Subscription back to `Active`.
- [ ] Any application-level retry loop wrapping a capture call for a continuity Order.
- [ ] Any auto-retry path triggered by `status === 'Failed'`.
- [ ] Any Recycling Reason Code configured with a wildcard or a substring assumption.
- [ ] Any MRR / revenue calculation that sums fields on the Subscription rather than continuity Orders.
- [ ] Any customer aggregation query that joins by `subscriptionNumber` rather than `customerAccountId`.
- [ ] Any UI that exposes a "cancel at end of period" toggle without an explicit skip-then-cancel implementation.
- [ ] Any AR projection that treats `installmentPlanCode` as forward-rolling subscription revenue.
- [ ] Any test that expects a continuity Order within seconds of creating a Subscription (without calling `/orderNow`).
- [ ] Any frequency-change UI that doesn't intersect per-item allowed-frequency lists for bundles.
- [ ] Any subscription-status polling loop that should be an event subscription instead.
- [ ] Any storefront UI that promises a specific charge date after pause-resume without verifying `nextOrderDate` behavior.
- [ ] Any PSP integration for subscriptions that doesn't flag continuity captures as off-session / MIT.
- [ ] Any cancellation flow that omits the Reason Code.
- [ ] Any code that re-stringifies the event payload before processing rather than persisting the raw payload.
- [ ] Any webhook handler that returns 4xx for unknown event types (should 200 OK and log).
- [ ] Any subscription bundle modification flow that ignores per-line fulfillment semantics.
- [ ] Any code that assumes the initial Order and continuity Orders are interchangeable for reporting.
