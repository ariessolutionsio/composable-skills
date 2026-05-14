# Cart & Checkout

Cart, Checkout, and Order are **three separate entities** in Kibo — promotion happens Cart → Checkout → Order, and code that conflates them loses the multi-ship-to model, mis-handles coupon failures, and ships orders that fail downstream. This file covers all three stages, the promotion engine that runs across them, and the payment lifecycle. Pricing resolution and B2B quote handoff cross-reference `catalog.md` and `b2b.md` respectively.

## Table of Contents
- [The Three-Stage Promotion: Cart → Checkout → Order](#the-three-stage-promotion-cart--checkout--order)
- [Cart Entity](#cart-entity)
- [Cart Lifecycle](#cart-lifecycle)
- [Anonymous → Authenticated Merge](#anonymous--authenticated-merge)
- [Checkout Entity](#checkout-entity)
- [Multi-Ship-to: `destinations[]` + `groupings[]`](#multi-ship-to-destinations--groupings)
- [Checkout State Machine (Actions, not PATCHes)](#checkout-state-machine-actions-not-patches)
- [Promotions and Discounts](#promotions-and-discounts)
- [Coupons: the Silent-Bug Trap](#coupons-the-silent-bug-trap)
- [Payments](#payments)
- [PCI Boundary](#pci-boundary)
- [B2B Handoff (see also `b2b.md`)](#b2b-handoff-see-also-b2bmd)
- [Anti-Pattern / Recommended-Pattern Pairs](#anti-pattern--recommended-pattern-pairs)
- [Checklist](#checklist)

## The Three-Stage Promotion: Cart → Checkout → Order

```
Cart                Checkout                  Order
─────               ────────                  ─────
items[]             items[] (snapshot)        items[] (immutable)
couponCodes[]       couponCodes[]             couponCodes[]
priceListCode       priceListCode             priceListCode
reservationId       destinations[]            destinations[]
cartMessages[]      groupings[]               groupings[]
                    payments[]                payments[]
                    suggestedDiscounts[]      submittedDate
                    [stage actions]           [immutable]
```

| Stage | What it is | What it owns |
|-------|------------|--------------|
| **Cart** | Shopper's working list. Mutable freely; resolves prices and applies cart-level promotions. | Items, coupons, the resolved `priceListCode`, an inventory reservation token |
| **Checkout** | Snapshot of cart at checkout-start, accumulating shipping destinations, groupings, and payment actions. | Destinations, groupings, payment records, suggested discounts, taxes |
| **Order** | Immutable post-submit record. | Submitted facts, audit info |

A cart is **never** "the customer's checkout" — code that drives shipping address, payment, and submission off the Cart loses the multi-ship-to model and breaks the moment a real B2B order needs to fan out to multiple destinations. The transition is explicit: `POST /commerce/checkouts?cartId={guid}` creates the Checkout from the Cart, and **the cart is emptied at order creation**.

## Cart Entity

Source: [docs.kibocommerce.com/api-reference/cart/get-or-create-cart.md](https://docs.kibocommerce.com/api-reference/cart/get-or-create-cart.md).

Top-level fields:

| Field | Purpose |
|-------|---------|
| `id` (GUID) | Cart identifier |
| `userId`, `customerAccountId` | Owner — anonymous or authenticated |
| `isActive` | Whether this is the current cart for the owner |
| `siteId`, `tenantId`, `currencyCode` | Scope context |
| `items[]` | CartItems |
| `couponCodes[]` | Successfully applied coupons |
| `invalidCoupons[]` | `{couponCode, reasonCode (int32), reason, discountId, createDate}` — see coupon section |
| `priceListCode` | Resolved at cart create/update (see `catalog.md`) |
| `reservationId` | Soft inventory hold token |
| `cartMessages[]` | System notifications (oversold, removed item) |
| `handlingAmount`, `handlingSubTotal`, `handlingTotal` | Handling fees |
| `zipCode` | Shopper-provided for pre-checkout tax/shipping estimation |

CartItem fields worth knowing:

| Field | Purpose |
|-------|---------|
| `id` | Cart-item ID, **not** productCode |
| `product` | Embedded snapshot: `productCode`, `variationProductCode`, `name`, `imageUrl`, options selected |
| `quantity`, `fulfillmentMethod`, `fulfillmentLocationCode` | Quantity + fulfillment route |
| `unitPrice`, `subtotal`, `discountTotal`, `discountedTotal`, `total`, `itemTaxTotal`, `shippingTotal` | Per-line money math |
| `productDiscounts[]`, `shippingDiscounts[]` | Discount instances applied to this line |
| `subscription` | Recurring purchase config (see `kibo-subscriptions`) |
| `parentItemId`, `childItemIds` | Bundle relationships |

## Cart Lifecycle

Endpoints under `/commerce/carts`:

| Operation | Endpoint |
|-----------|----------|
| Get-or-create current cart | `GET /commerce/carts/current` |
| Add item | `POST /commerce/carts/current/items` |
| Update quantity | `PUT /commerce/carts/{cartId}/items/{itemId}/quantity/{q}` |
| Remove item | `DELETE /commerce/carts/{cartId}/items/{itemId}` |
| Apply coupon | `PUT /commerce/carts/{cartId}/coupons/{couponCode}` |
| Remove coupon | `DELETE /commerce/carts/{cartId}/coupons/{couponCode}` |

`/commerce/carts/current` is **get-or-create** — calling it on a Bearer token (anonymous or shopper) returns the active cart for that token, or creates one. There is no separate "create cart" call for normal flows. The current cart is determined by the Bearer token, not by query params.

## Anonymous → Authenticated Merge

The concept guide acknowledges "registered or anonymous" shoppers but does not enumerate the merge semantics. Empirically, by inspecting the official Next.js storefront (`lib/gql/queries/cart-takeover/`), the pattern is:

1. Shopper builds an anonymous cart on an anonymous token.
2. Shopper logs in; storefront receives a shopper token.
3. Storefront calls a **cart-takeover mutation** that merges the anonymous cart's items into the authenticated cart on the server.

**The exact merge strategy is unknown — verify against your tenant.** The plausible behaviors are:
- **Sum quantities** for matching `variationProductCode` (additive).
- **Replace** the authenticated cart entirely.
- **Append** items, leaving duplicates if the same SKU appears in both.

It may also be configurable via cart settings. Before relying on a specific behavior:

1. Test with a known-good fixture (anonymous cart has 1 × SKU-A, authenticated cart has 2 × SKU-A; check the result).
2. Confirm with Kibo support or the tenant's configuration — do **not** infer from the storefront code, since that may be wrapping platform behavior.

Code that assumes a specific merge mode without verification is the most common source of "promotions disappeared after login" tickets.

## Checkout Entity

Source: [docs.kibocommerce.com/api-reference/checkout/create-checkout-from-cart.md](https://docs.kibocommerce.com/api-reference/checkout/create-checkout-from-cart.md).

Created with `POST /commerce/checkouts?cartId={guid}`. Response is a ~70-field Checkout. Key groups:

**Identification:** `id`, `number`, `originalCartId`, `type`, `submittedDate`.

**Customer:** `email`, `customerAccountId`, `customerTaxId`, `acceptsMarketing`, `alternateContact`, `shopperNotes` (`comments`, `deliveryInstructions`, `giftMessage`).

**Financials:** `subTotal`, `total`, `itemTotal`, `shippingTotal`, `handlingTotal`, `itemTaxTotal`, `shippingTaxTotal`, `handlingTaxTotal`, `dutyTotal`, `feeTotal`, `amountRemainingForPayment`, plus discount totals.

**Structural arrays:** `items[]`, `groupings[]`, `destinations[]`, `payments[]`, `couponCodes[]`, `orderDiscounts[]`, `suggestedDiscounts[]`.

**Context:** `channelCode`, `currencyCode`, `priceListCode`, `siteId`, `tenantId`.

**Audit/extension:** `auditInfo`, `attributes`, `data`, `taxData`.

The Checkout is fully populated when created — it inherits the cart's items, coupons, and resolved price list, and adds destinations/groupings/payments structure as the shopper progresses through checkout.

## Multi-Ship-to: `destinations[]` + `groupings[]`

This is the load-bearing reason Cart and Checkout are separate entities. The multi-ship-to model lives on **Checkout**, not Cart.

```
Checkout
  ├─ destinations[]
  │    ├─ { id: "d1", destinationContact: {address, name, phone}, ... }
  │    └─ { id: "d2", destinationContact: {address, name, phone}, ... }
  │
  └─ groupings[]
       ├─ { id: "g1", destinationId: "d1", fulfillmentMethod: "DirectShip",
       │    orderItemIds: ["item-1", "item-2"], shippingTotal, taxTotal, ... }
       └─ { id: "g2", destinationId: "d2", fulfillmentMethod: "InStorePickup",
            orderItemIds: ["item-3"], shippingTotal, taxTotal, ... }
```

| Concept | Shape |
|---------|-------|
| **Destination** | A shipping target. `{id, destinationContact, isDestinationCommercial, data}`. A destination is an address + contact. |
| **Grouping** | A bundle of items going to one destination via one fulfillment method. `{id, destinationId, fulfillmentMethod, orderItemIds[]}` plus per-grouping shipping/handling/duty/tax breakdowns. |

A single Checkout fans items across many groupings across many destinations, while remaining one transaction with one payment authorization. This is the architectural feature B2B leans on (one PO, many ship-to facilities) and the reason naive single-address checkout code is wrong from day one for B2B and gift-checkout flows.

**Implication for storefront design:**

- The cart UI is item-level. It does **not** show shipping addresses or fulfillment splits.
- The checkout UI is grouping-level. It shows N "shipment sections," one per grouping, each with its destination, fulfillment method, and items.
- B2C single-address checkouts are a degenerate case: one destination, one grouping, all items in that grouping. Build the UI for N first; collapse to one when N=1.

## Checkout State Machine (Actions, not PATCHes)

Source: [docs.kibocommerce.com/api-reference/checkout/perform-payment-action.md](https://docs.kibocommerce.com/api-reference/checkout/perform-payment-action.md).

The checkout state machine is exposed through **actions** rather than direct PATCH:

| Endpoint | Purpose |
|----------|---------|
| `GET /commerce/checkouts/{id}/actions` | Returns available actions for current state |
| `POST /commerce/checkouts/{id}/actions` | Perform an action (e.g. `SubmitOrder`) |
| `POST /commerce/checkouts/{id}/payments/{paymentId}/actions` | Perform a payment action (auth/capture/void/credit) |

Available actions evolve as the checkout fills in:

1. **Initial.** Items present, destinations + groupings empty. Available actions are "add destination," "set contact info," etc.
2. **Destinations + groupings set.** Tax calculation runs. Payment actions become available once shipping is resolved.
3. **Payment authorized.** `SubmitOrder` becomes available.
4. **SubmitOrder performed.** Checkout converts to Order; cart is emptied.

Calling `POST .../actions` before its preconditions are met fails the action — read `GET .../actions` to discover what's currently legal rather than guessing.

### Payment action sequence

| Action | Purpose |
|--------|---------|
| `CreatePayment` | Register a payment record (card, gift card, PO, etc.) on the checkout |
| `AuthorizePayment` | Reserve funds at the PSP |
| `CapturePayment` | Move funds at the PSP. Often deferred to fulfillment via Flexible Auto Capture Settings. |
| `VoidPayment` | Cancel an authorization (before capture) |
| `CreditPayment` | Refund / partial refund |

PaymentAction input fields: `actionName`, `amount`, `currencyCode`, `manualGatewayInteraction`, `newBillingInfo`, `externalTransactionId`, `installmentPlanCode`, `cancelUrl`/`returnUrl` (for 3DS / redirect PSPs), `recaptcha`, `data` (PSP-specific payload).

**Order of operations matters:** PSP **authorization** must happen before `SubmitOrder` so funds are reserved against the order; **capture** is deferred to fulfillment (Flexible Auto Capture is the standard pattern — see the "Authorize, don't capture, before SubmitOrder" anti-pattern). Submit-before-auth orders ship with `amountRemainingForPayment > 0` and stall downstream. The full sequence is `AuthorizePayment → SubmitOrder → CapturePayment` (on shipment).

## Promotions and Discounts

Source: [docs.kibocommerce.com/api-reference/discounts/create-discount.md](https://docs.kibocommerce.com/api-reference/discounts/create-discount.md).

Kibo's promotion entity is called a **Discount** (the term "promotion" is informal). Each Discount carries:

| Field | Values |
|-------|--------|
| `amountType` | `Percentage` / `Amount` / `Free` / `FixedPrice` |
| `scope` | `Order` (cart-level) or `LineItem` (per-line) |
| `target` | `Product` (or category) or `Shipping` |

### Conditions — the Container/Predicate tree

Conditions are an expression tree:

```jsonc
{
  "conditions": {
    "expression": {
      "tree": {
        "type": "Container",
        "logicalOperator": "And",
        "nodes": [
          { "type": "Predicate", "left": "cart.total", "operator": "gte", "right": "100" },
          { "type": "Predicate", "left": "customer.segment", "operator": "in", "right": "['VIP']" }
        ]
      }
    }
  }
}
```

- **Container** nodes have `logicalOperator: "And" | "Or"` and `nodes[]`.
- **Predicate** nodes have `left` (attribute path), `operator`, `right` (literal).

**Operator vocabulary is not fully enumerated in public docs.** `eq`, `ne`, `gt`, `gte`, `lt`, `lte`, `in`, `contains`, `startsWith` are commonly seen; the full list is **unknown — verify against the admin UI rule builder or `POST /commerce/catalog/admin/discounts/expressions/validate`.**

### Stacking and exclusivity

Stacking is **explicit, per-discount**:

| Field | Purpose |
|-------|---------|
| `canBeStackedUpon` | Whether other discounts can apply on top of this one |
| `stackingLayer` | Integer slot — discounts compose in tiers |
| `preventLineItemShippingDiscounts` | If true, suppresses line-item-level shipping discounts |
| `preventOrderProductDiscounts` | If true, suppresses order-level product discounts |
| `preventOrderShippingDiscounts` | If true, suppresses order-level shipping discounts |

Stacking is **not** "two discounts; pick the better one." It is "two discounts; both apply, in the order their `stackingLayer` dictates, unless a `prevent*` flag intervenes." Code that assumes mutual exclusion based on percentage-vs-amount or scope is wrong.

### Redemption limits

| Field | Purpose |
|-------|---------|
| `maximumRedemptionsPerOrder` | Per-cart redemption cap |
| `maximumUsesPerUser` | Lifetime per customer |
| `maxRedemptionCount` | Global cap across all customers |
| `currentRedemptionCount` | Read-only counter |

### BOGO / Buy X Get Y

Kibo does **not** have a dedicated "BOGO" discount type. BOGOs are configured via the combination of `scope: LineItem`, an `amountType` (typically `Free` or `Percentage`), and condition predicates on minimum quantity. Spell out the buy-side requirement in conditions, the get-side as the discount target.

## Coupons: the Silent-Bug Trap

Source: [docs.kibocommerce.com/api-reference/couponsets/*](https://docs.kibocommerce.com/api-reference/couponsets/).

Coupon Sets are a separate resource:

| Endpoint | Purpose |
|----------|---------|
| `POST /commerce/catalog/admin/couponsets` | Create coupon set |
| `POST /commerce/catalog/admin/couponsets/{id}/coupons` | Add codes (bulk) |
| `POST /commerce/catalog/admin/couponsets/{id}/discount/{discountId}` | Link a discount to a coupon set |

A Discount can carry a single named `couponCode` or be backed by a Coupon Set of generated codes. The `requiresCoupon` flag gates the discount on a coupon presence.

### Coupon application returns HTTP 200 on failure

This is the silent-bug trap. The endpoint `PUT /commerce/carts/{cartId}/coupons/{couponCode}` returns **HTTP 200 with the updated cart** even when the coupon is rejected. The rejection lives in `invalidCoupons[]`:

```jsonc
{
  "id": "cart-guid",
  "couponCodes": [],
  "invalidCoupons": [
    {
      "couponCode": "SAVE20",
      "reasonCode": 1004,                          // int32, not a string enum
      "reason": "This coupon has expired.",        // localized merchandiser-tuned message
      "discountId": 12345,                          // the discount that rejected the coupon (if known)
      "createDate": "2026-05-13T10:00:00Z"
    }
  ]
}
```

`reasonCode` is an **integer code**, not a string enum — code that pattern-matches on `"ExpiredCoupon"` won't work. Display `reason` (which is the localized, merchandiser-tuned text) rather than mapping codes yourself.

Code that checks `response.status` and treats 200 as success will silently swallow the rejection, leaving the shopper looking at an unchanged cart with no UI feedback.

**Anti-pattern:**

```typescript
const res = await fetch(`/commerce/carts/${cartId}/coupons/${code}`, { method: 'PUT' });
if (res.ok) {
  setMessage('Coupon applied');     // wrong — it may have been rejected
}
```

**Recommended:**

```typescript
const res = await fetch(`/commerce/carts/${cartId}/coupons/${code}`, { method: 'PUT' });
if (!res.ok) throw new Error(`HTTP ${res.status}`);
const cart = await res.json();
const rejected = cart.invalidCoupons?.find((c) => c.couponCode === code);
if (rejected) {
  setMessage(rejected.reason);      // surface the platform's reason text
  return;
}
setMessage('Coupon applied');
```

Always read `invalidCoupons[]` and surface `reason` to the shopper. The platform-provided reason text is usually localized and merchandiser-tuned; do **not** replace it with a generic "invalid coupon" message.

## Payments

Source: [docs.kibocommerce.com/concept-guides/payments](https://docs.kibocommerce.com/concept-guides/payments).

### Supported payment types

The concept guide confirms support for:
- **Credit cards** via PSP (Cybersource is the worked example in the docs)
- **Digital wallets** — PayPal, Apple Pay referenced
- **Gift cards** — both external-gateway and platform-internal
- **Purchase Order** — for B2B accounts when enabled

**Exhaustive PSP list is unknown — verify against your tenant or [docs.kibocommerce.com/pages/payment-gateways](https://docs.kibocommerce.com/pages/payment-gateways).** Braintree, Stripe, Adyen, and Worldpay are referenced anecdotally in community content but were not verified in the documentation pages this skill is built from. Treat the OOTB PSP list as something you confirm before scoping the integration.

### Payment lifecycle

```
CreatePayment → AuthorizePayment → CapturePayment (or VoidPayment / CreditPayment)
                                     ↑
                          deferred via Flexible Auto Capture Settings
                          (typically captured on fulfillment, not on submit)
```

| State | Meaning |
|-------|---------|
| `New` | Payment record created, not authorized |
| `Authorized` | PSP has reserved funds |
| `Captured` | PSP has moved funds |
| `Voided` | Authorization cancelled before capture |
| `Credited` | Funds returned |
| `Declined` | PSP rejected |

Auto-capture is configurable per fulfillment state via **Flexible Auto Capture Settings** — capture can fire when an order is fulfilled, partially fulfilled, or submitted. Default is usually "capture on fulfillment" for ship-to-home; verify the tenant's setting before assuming.

### Refunds

| Type | Trigger | Notes |
|------|---------|-------|
| **Automatic** | Successful return | Follows configured "Payment Ranking for refunds" (which method gets refunded first when there are multiple) |
| **Manual** | CSR / operator | Picks payment method explicitly |
| **Appeasements** | First-class concept | Refund cash without opening a return and without changing the order balance |

### Payment Interactions

There is **no separate "Transaction" object** in Kibo. The chain of **Payment Interactions** (the audit log of every Auth/Capture/Void/Credit/Decline) is the transaction history. To answer "what's happened on this payment," you read the interactions, not a single status field.

## PCI Boundary

Card data **must not transit the main API host**. Kibo runs a separate PCI host (`payments-sb.mozu.com` for sandbox, `pmts.mozu.com` for production) and the storefront tokenizes card data against the PCI host directly. Only the resulting token comes back through the main API.

The Next.js starter confirms this with `KIBO_PCI_HOST` as a dedicated env var — used only by the card-capture component, never by the rest of the storefront.

**Implication:** any storefront that routes raw card data through the main API expands its PCI scope unnecessarily and may violate PCI-DSS depending on the assessor. Always tokenize at the PCI host; pass only the token onwards.

## B2B Handoff (see also `b2b.md`)

Two cart/checkout behaviors differ for B2B:

1. **Pricing resolution.** B2B accounts can have a directly-assigned `priceList` that wins over customer-segment matches. The cart's `priceListCode` resolves accordingly. Full resolution order is in `catalog.md`.
2. **Quote-to-order handoff.** Quotes are a separate entity with their own state machine (Pending → In Review → Ready for Checkout → Completed). A quote does **not** bypass checkout — when the buyer converts the quote to an order, it flows through standard Cart → Checkout → Order. The quote acts as the cart's source. See `b2b.md` for the quote state machine, inventory reservation behavior, and conversion mutation shape.

PO-on-account payments are a first-party payment type for enabled B2B accounts (see `b2b.md`).

## Anti-Pattern / Recommended-Pattern Pairs

### Treating the cart as the customer-facing checkout

**Anti-pattern.** Building a "checkout" UI that reads and writes shipping address, fulfillment splits, and payment directly off the cart:

```typescript
// Wrong — cart has no destinations or groupings
await api.cart.update({ cartId, body: { shippingAddress: { /* ... */ } } });
```

Consequence: no multi-ship-to support, no per-grouping fulfillment method, no place to put payment records. Works for single-address B2C, breaks the moment a B2B order needs to split shipments.

**Recommended.** Convert the cart to a checkout, then operate on the Checkout's `destinations[]` and `groupings[]`:

```typescript
const checkout = await api.checkout.createFromCart({ cartId });
await api.checkout.addDestination({
  checkoutId: checkout.id,
  body: { destinationContact: { address, name, phone } },
});
await api.checkout.setGroupingFulfillment({
  checkoutId: checkout.id,
  groupingId: 'g1',
  fulfillmentMethod: 'DirectShip',
  destinationId: 'd1',
});
```

### Reading coupon failures as HTTP errors

(See coupon section above.) Always read `invalidCoupons[]`; do not trust HTTP status.

### Capture-before-submit ordering

**Anti-pattern.** Capturing the payment, then calling `SubmitOrder`:

```typescript
await api.checkout.performPaymentAction({ checkoutId, paymentId, actionName: 'CapturePayment' });
await api.checkout.performAction({ checkoutId, actionName: 'SubmitOrder' });
```

If `SubmitOrder` fails (validation, stock, downstream service), you've captured funds for an order that doesn't exist — gateway fees, audit-trail noise, and a manual refund.

**Recommended.** Authorize before submit; defer capture to the configured auto-capture trigger (fulfillment, by default for shippable goods):

```typescript
await api.checkout.performPaymentAction({ checkoutId, paymentId, actionName: 'AuthorizePayment' });
await api.checkout.performAction({ checkoutId, actionName: 'SubmitOrder' });
// Capture fires later, on fulfillment, via Flexible Auto Capture Settings
```

### Assuming a single payment record

**Anti-pattern.** Treating `payments[]` as a single payment:

```typescript
const payment = checkout.payments[0]; // wrong for split tender
```

Split tender (gift card + card, store credit + card) produces multiple payment records, each with its own authorize/capture lifecycle. Code that hardcodes index 0 fails the first time a customer applies a gift card.

**Recommended.** Iterate over `payments[]` and reconcile `amountRemainingForPayment` to zero before submit:

```typescript
const total = checkout.total;
const totalAuthorized = checkout.payments
  .filter(p => p.status === 'Authorized')
  .reduce((sum, p) => sum + p.amount, 0);
if (totalAuthorized < total) {
  throw new Error('Payments do not cover order total');
}
```

### Hardcoding stacking behavior

**Anti-pattern.** Code that assumes "percentage discounts and amount discounts don't stack":

```typescript
if (discount.amountType === 'Percentage' && otherDiscount.amountType === 'Amount') {
  // assume mutual exclusion
}
```

Stacking is governed by `canBeStackedUpon`, `stackingLayer`, and the `prevent*` flags on each discount, not by amount type. The platform's promotion engine resolves the stack; storefront code that pre-empts that logic produces incorrect cart totals.

**Recommended.** Trust the platform's discount resolution. Read the resulting `productDiscounts[]` and `shippingDiscounts[]` on each cart item, and `orderDiscounts[]` on the cart/checkout. Display the resolved discount; do not re-derive stacking.

### Bypassing the PCI host

**Anti-pattern.** Posting raw card numbers to the main API or to your own backend:

```typescript
await fetch('/api/checkout/pay', { body: JSON.stringify({ cardNumber, cvv }) });
```

Consequence: your storefront and backend are now in-scope for PCI-DSS. The assessor will not be happy.

**Recommended.** Tokenize at the PCI host; pass only the token onwards:

```typescript
// On the storefront, against KIBO_PCI_HOST
const token = await pciClient.tokenize({ cardNumber, cvv, exp });
// Then pass the token through the main API
await api.checkout.performPaymentAction({
  checkoutId, paymentId,
  actionName: 'CreatePayment',
  body: { newBillingInfo: { card: { paymentServiceCardId: token } } },
});
```

## Checklist

Before shipping cart/checkout code:

- [ ] The integration treats Cart, Checkout, and Order as three distinct entities — shipping address, groupings, and payment records live on Checkout, never on Cart.
- [ ] Multi-ship-to is supported via `destinations[]` and `groupings[]`, even if the launch UI starts with a single-address B2C flow. The model supports N from day one.
- [ ] Cart-takeover (anonymous → authenticated merge) behavior is **verified against the tenant**, not assumed.
- [ ] Coupon application reads `invalidCoupons[]` on every response; HTTP 200 is not interpreted as "applied."
- [ ] Coupon rejection reasons are surfaced from `invalidCoupons[].reason`, not replaced with a generic message.
- [ ] Checkout state is driven by `GET /commerce/checkouts/{id}/actions` — code does not assume action availability.
- [ ] Payment sequence is **Authorize → SubmitOrder → Capture (on fulfillment via Flexible Auto Capture)**, not capture-then-submit.
- [ ] `payments[]` is iterated; split tender (gift card + card) is supported.
- [ ] `amountRemainingForPayment` is reconciled to zero before `SubmitOrder` is called.
- [ ] Card data goes through the PCI host (`KIBO_PCI_HOST`); only tokens transit the main API.
- [ ] Discount stacking is **not** hardcoded in storefront logic; the platform's resolved `productDiscounts[]` / `shippingDiscounts[]` / `orderDiscounts[]` are trusted.
- [ ] B2B carts have the correct `priceListCode` resolved via segment / B2B-account assignment, not by manual override.
- [ ] Quotes (when in use) flow through standard Checkout — there is no "quote bypass" path.
- [ ] `x-vol-site` is set on every cart/checkout call (see `api-setup.md`).
- [ ] Code does not assume a specific PSP — the integration is built against the Kibo PaymentAction surface, with PSP-specific payload in `data`.
