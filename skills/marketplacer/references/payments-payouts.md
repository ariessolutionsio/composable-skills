# Payments & Payouts

The most commonly misunderstood part of a Marketplacer implementation. **Marketplacer is not a split-payment processor.** It does not capture customer funds, does not hold money in escrow at order time, and does not integrate with Stripe Connect / Adyen for Platforms in the way those platforms are designed to integrate. Designing checkout around split-capture leads to an architectural rewrite. This file makes the actual model explicit.

## Table of Contents
- [Big Idea: Deposit-and-Reconcile, Not Split-Capture](#big-idea-deposit-and-reconcile-not-split-capture)
- [The Five-Step Flow](#the-five-step-flow)
- [The Operator's PSP](#the-operators-psp)
- [`paymentReferences` Tagging (Note the Plural)](#paymentreferences-tagging-note-the-plural)
- [MPay, Airwallex, Hyperwallet, Xero](#mpay-airwallex-hyperwallet-xero)
- [The `mPayStartDepositReconciliation` Mutation](#the-mpaystartdepositreconciliation-mutation)
- [Commission Packages](#commission-packages)
  - [Commission Reversal on Refund](#commission-reversal-on-refund)
- [Remittance vs RemittanceAdvice](#remittance-vs-remittanceadvice)
- [Additional Charges (Advanced Amendments)](#additional-charges-advanced-amendments)
- [Refund Mutations and Sign Conventions](#refund-mutations-and-sign-conventions)
- [Marketplace Fees vs Commission](#marketplace-fees-vs-commission)
- [Tax Model](#tax-model)
- [Reconciling the Books](#reconciling-the-books)
- [Checklist](#checklist)

## Big Idea: Deposit-and-Reconcile, Not Split-Capture

**Anti-Pattern (designing Marketplacer as Stripe Connect):**
- Customer pays Marketplacer.
- Marketplacer splits the payment between the operator and each seller at capture time.
- Sellers' payment accounts are linked to Marketplacer like Stripe Connect connected accounts.

**None of this is how Marketplacer works.**

**Recommended mental model:**
- Customer pays **the operator's PSP** at checkout. Marketplacer is not in the payment flow.
- Operator periodically **deposits** aggregated funds into an MPay/Airwallex holding account.
- Operator **tells Marketplacer** which orders/refunds the deposit covers (`amountCollected`).
- Marketplacer's MPay **pays out** to sellers from the holding account on a configurable schedule.

Marketplacer's role is **per-seller settlement and accounting**, not money movement at capture. The operator owns the payment relationship with the customer.

## The Five-Step Flow

```
1. CAPTURE
   Customer ──$── Operator's PSP (Stripe / Adyen / Braintree / …)
                  └─ gateway transaction ID(s) issued (may be >1, e.g. gift-card + card)

2. RECORD
   Operator ── orderCreate(paymentReferences: [{paymentReference, amount}, …]) ──> Marketplacer
                                                                                    └─ Order + Invoices

3. DEPOSIT
   Operator ── batch transfer of (gross − gateway fees) ──> MPay holding account
                                                            └─ "amountCollected" total

4. RECONCILE
   Operator ── mPayStartDepositReconciliation(depositReference, amount, paymentReferences[]):
                "Deposit X covers PSP transactions [a, b, c, …]"
              └─ sum(amountCollected) must equal the deposit amount

5. PAYOUT
   MPay ──$── Sellers (per Seller, per CommissionPackage, per remittance schedule)
              └─ Remittance per dispatched invoice; RemittanceAdvice groups them
```

Step 3 and step 4 are decoupled in time — the deposit can land before reconcile is called, or vice versa. The reconcile call ties them together and validates the total balances. **If `sum(amountCollected)` does not equal the deposit amount, the reconciliation record is marked `unmatched`** and MPay holds payouts for that batch until resolved.

## The Operator's PSP

Marketplacer is **gateway-agnostic at capture time**. Supported PSPs include Stripe, Adyen, Braintree, and others. The integration with the PSP is the operator's concern; Marketplacer only cares about the resulting transaction ID.

**Implications:**
- Refund mechanics on the customer side are PSP-native. To refund the customer, the operator calls Stripe/Adyen/etc. directly.
- Chargebacks and disputes are handled in the PSP. Marketplacer's RefundRequest workflow records the marketplace-side accounting; the actual money movement back to the customer happens in the PSP.
- Subscription/recurring payments, saved cards, 3DS, SCA — all PSP concerns. Not Marketplacer's.

## `paymentReferences` Tagging (Note the Plural)

The bridge between PSP world and Marketplacer world is the `paymentReferences` argument on `orderCreate` / `orderUpdate` / refund mutations. **It's an array of objects, not a string** — a long-standing gotcha that misleads first-time integrators who see one PSP transaction per order and reach for a singular field.

```typescript
{
  // orderCreate input
  paymentReferences: [
    { paymentReference: 'pi_3RxYz...', amount: 4500 },  // Stripe PaymentIntent, gross cents
  ],
  // ... rest of input
}
```

Why a plural array: split tender is common in marketplaces (gift card + credit card, store credit + card, BNPL + card). Each PSP tender contributes one entry. Even single-tender orders use the array form with one element.

```typescript
// Split-tender example
paymentReferences: [
  { paymentReference: 'gc_4f9a...', amount: 2000 },   // gift card portion
  { paymentReference: 'pi_3RxYz...', amount: 2500 },  // card portion
]
```

Each entry's `paymentReference` is the PSP's primary identifier (Stripe PaymentIntent ID, Adyen pspReference, etc.); `amount` is the gross integer in lowest denomination paid against that reference. The sum across entries equals the Order's gross.

**For refunds:** the refund mutations (`refundRequestRefund`, `refundRequestApprove`, `invoiceAmendmentUpdate`) also accept `paymentReferences` so MPay can match the reversal to the original tender.

**Anti-pattern:** generating an opaque internal reference instead of the PSP transaction ID. Reconcile becomes manual matching. Store internal IDs in `externalIds`, not in `paymentReferences`.

## MPay, Airwallex, Hyperwallet, Xero

MPay is Marketplacer's branded payout layer. The underlying payout backend is **configurable per instance** — Airwallex is the headline integration, but Hyperwallet and Xero are also documented payment system options. The operator generally doesn't see the difference at the API surface; the same `mPayStartDepositReconciliation`/Remittance/RemittanceAdvice flow applies. The choice shows up in:

- Currency/country availability for seller payouts.
- The "payment system details" field set on each Seller's remittance account.
- The blocker codes that surface in `pendingReasons` when a payout cannot release.

**Setup is portal-driven.** The Airwallex/Hyperwallet/Xero account, payout schedules, and currency configuration are set up out-of-band by the Marketplacer onboarding team; integration code mostly calls the deposit-and-reconcile mutation and reads RemittanceAdvice.

## The `mPayStartDepositReconciliation` Mutation

This is the named entry point for step 4. Real shape (verify field names against the live schema before code-gen):

```graphql
mutation Reconcile($input: MPayStartDepositReconciliationInput!) {
  mPayStartDepositReconciliation(input: $input) {
    reconciliation { id status }
    errors { path message }
  }
}
```

```typescript
{
  input: {
    depositReference: 'bank-tx-2026-05-13-001',  // unique bank transfer ID
    amount: 1_250_00,                            // total deposit in cents
    paymentReferences: [
      { paymentReference: 'pi_3RxYz...', amountPaid: 5000, amountCollected: 4850 },
      { paymentReference: 'pi_4QwZb...', amountPaid: 8000, amountCollected: 7750 },
      // ... more PSP transactions covered by this deposit
    ],
  }
}
```

The two amount fields per entry are not interchangeable:

| Field | Meaning |
|-------|---------|
| `amountPaid` | The gross amount the shopper paid against this PSP transaction |
| `amountCollected` | The **net** amount the operator actually received after PSP/gateway fees |

**Validation rule:** `sum(amountCollected) === amount` (the deposit total). Mismatches create an `unmatched` reconciliation record; payouts for those orders are held until resolved.

**Defer to the live doc** at [api.marketplacer.com/docs/operator-api/examples/payouts/](https://api.marketplacer.com/docs/operator-api/examples/payouts/howto_automated_payouts/) for the current field set — input shapes occasionally pick up additional fields.

## Commission Packages

How the operator charges sellers. A `CommissionPackage` is assigned per Seller (`seller.commissionPackageId`).

| Field | Notes |
|-------|-------|
| `defaultRate` | Flat commission percentage applied to line item cost |
| `customCommissionRates` | Per-Taxon override rates (e.g., apparel 15%, electronics 5%) |
| `thresholdPrice` | Price above which `overThresholdRate` applies |
| `overThresholdRate` | Reduced commission for high-value items |
| `appliesToPostage` | Whether commission is taken on shipping cost as well as goods cost |

**Example structure:**
```typescript
{
  defaultRate: 0.12,                    // 12% default
  customCommissionRates: [
    { taxonId: 'electronics', rate: 0.05 },
    { taxonId: 'apparel', rate: 0.15 },
  ],
  thresholdPrice: 50000,                // $500 in cents
  overThresholdRate: 0.08,              // 8% above $500
  appliesToPostage: false,
}
```

Commission is calculated **per Invoice** at order time and stored on the Invoice. The seller's payout is `invoice.total − invoice.commissionAmount − invoice.refundsForReversedItems`.

### Commission Reversal on Refund

When a RefundRequest reaches `Refunded` state, **MPay reverses the commission portion** corresponding to the refunded line items. The seller is debited the commission they earned on those items; the operator's commission revenue is decremented.

**Reporting implication:** any operator dashboard that totals commission revenue must model the reversal, not just additive commission. A simple `SUM(invoice.commissionAmount)` overstates revenue by the value of refunded commission.

**Recommended pattern:**
- Pull commission as a net figure: commission earned − commission reversed in the same period.
- Subscribe to `refundrequest.refunded` events and flow them into the operator's financial reporting.

## Remittance vs RemittanceAdvice

These are **two distinct entities** and conflating them produces incorrect AP feeds. The skill's earlier drafts hand-waved the distinction; the live schema is precise:

| Entity | Granularity | When created |
|--------|-------------|--------------|
| **Remittance** | One per Invoice (or Invoice amendment) | When the invoice has at least one dispatched line item **and** no outstanding line items |
| **RemittanceAdvice** | One per payout cycle, per Seller | Generated nightly, grouping all Remittances ready to release for that Seller |

Think of it like this: every dispatched invoice generates a Remittance entry (a debt owed to the seller for that one invoice). A nightly job groups all releasable Remittances per Seller into one RemittanceAdvice (the actual payout transaction). The payout is a single bank movement; the RemittanceAdvice is the line-by-line breakdown of which invoices that movement covers.

**Release gating:** A Remittance only joins a RemittanceAdvice once these conditions are all true:

- The seller's `customRemittanceDelay` (holdback days) has elapsed.
- The Remittance is in `released` state.
- The seller has complete payout-system account details (Airwallex / Hyperwallet / Xero).

`pendingReasons` on the Remittance reveals which condition is blocking.

### Field names use the `Cents` suffix

The schema is explicit about denomination by naming integer cent fields with `…Cents`:

| Object | Field | Meaning |
|--------|-------|---------|
| RemittanceAdvice | `totalCents` | Suggested total to remit |
| RemittanceAdvice | `totalPaidCents` | Actual amount paid (post-confirmation) |
| Remittance | `amountCents` | This invoice's contribution to the payout |
| Remittance | `commissionAmountCents` | Commission deducted for this invoice |
| Invoice | `shippingCostCents` | Shipping included in the remittance line |

When mapping into an ERP, preserve the cent integers — don't divide by 100 until the display layer.

### Querying

```graphql
query Remittances($sellerId: ID!, $first: Int = 50, $after: String) {
  seller(id: $sellerId) {
    remittances(
      first: $first, after: $after,
      released: false        # filter to candidates ready to release
    ) {
      nodes {
        id legacyId amountCents commissionAmountCents
        invoice { id legacyId shippingCostCents }
        pendingReasons
      }
      pageInfo { hasNextPage endCursor }
    }
  }
}
```

### Releasing and confirming payouts

| Mutation | Purpose |
|----------|---------|
| `remittancesRelease` | Mark a set of remittances as released (eligible to join a RemittanceAdvice on the next cycle) |
| `remittanceAdviceUpdate` | Update an Advice (e.g., mark `totalPaidCents` once the bank movement is confirmed) |

### Webhook events

`RemittanceAdvice` emits **Create** and **Update** events. There is no **Destroy** — these are immutable financial records. Update fires when, e.g., `totalPaidCents` lands after the bank confirms.

**ERP integration target:** RemittanceAdvice is the primary feed into the operator's ERP for AP (accounts payable to sellers). Subscribe to the RemittanceAdvice webhook and post each delivery to the ERP as a bill payable, with the constituent Remittances as line items and the linked Invoice IDs stored in `externalIds` for audit.

## Additional Charges (Advanced Amendments)

If your instance has **Advanced Amendments** enabled, the operator can recover costs from a customer after the original invoice is issued (typically return shipping fees, restocking fees, etc.) by creating a **separate, linked invoice** — not by amending the original.

Why a separate invoice? In several tax jurisdictions, amending an already-issued invoice is not tax-compliant. Marketplacer issues an additional invoice with an ID suffix like `12345-1-CH` linked back to the original order.

**Two mutations create additional charges:**

| Mutation | When to use |
|----------|-------------|
| `refundRequestApprove` (with `issueInvoice: true` on the custom line items) | Most common — operator approves a refund and at the same time adds a return-shipping charge |
| `invoiceAmendmentCreate` | Bypasses the refunds workflow — direct additional charge creation |

**Important: additional charges flow to the seller, not the operator.** They are treated like postage refunds for payout purposes — "fully remitted to the seller" and included in seller payout calculations. They are also "excluded from the credit note to keep tax calculations clean."

Confirm `Advanced Amendments` is enabled on the instance before designing flows around this — it's an opt-in feature.

## Refund Mutations and Sign Conventions

The refund state machine has its own mutations (one per transition). The non-obvious detail is the **sign convention** — wrong sign causes the deposit reconciliation to drift in the opposite direction.

| Mutation | State transition | Sign convention for `paymentReferences[].amount` |
|----------|------------------|--------------------------------------------------|
| `refundRequestCreate` | (none) → Created | n/a — no money movement |
| `refundRequestReturn` | Created → Returned | n/a |
| `refundRequestProcess` | Returned → Processed | n/a |
| `refundRequestRefund` | Processed → Refunded | **Positive value** (Marketplacer flips the sign internally) |
| `refundRequestApprove` | (approval — may issue additional charges) | **Positive value** for charge amounts |
| `invoiceAmendmentUpdate` | (direct amendment) | **Negative value** for refunded amounts |

**Why the asymmetry:** the refund-specific mutations know the context is a refund and handle the sign themselves; `invoiceAmendmentUpdate` is a lower-level amendment surface that takes the value at face value.

**Anti-pattern:**
```typescript
// Wrong — refundRequestRefund expects positive
refundRequestRefund({
  paymentReferences: [{ paymentReference: 'pi_xx', amount: -4500 }],
})
```

**Recommended:**
```typescript
refundRequestRefund({
  paymentReferences: [{ paymentReference: 'pi_xx', amount: 4500 }],
})

// vs the lower-level amendment surface:
invoiceAmendmentUpdate({
  paymentReferences: [{ paymentReference: 'pi_xx', amount: -4500 }],
})
```

## Marketplace Fees vs Commission

Two distinct concepts the operator may charge:

| Mechanism | Where it sits | Notes |
|-----------|---------------|-------|
| **Commission** | CommissionPackage; deducted from seller payout | Percentage of sale; configured once per seller; automatically reversed on refund |
| **Custom invoice fees** | Per-Invoice fee fields | One-off operator charges (listing fees, premium placement fees); set at invoice creation or via a separate mutation |

The integration usually models these separately: commission is automatic per CommissionPackage; custom fees are explicit per-invoice additions driven by the commerce platform's pricing engine.

## Tax Model

Tax is **whole-cent integer**, per line item, **all-or-nothing across line items**.

| Pattern | Result |
|---------|--------|
| Every line item has `cost.tax` and `postage.tax` | Valid |
| No line items have `tax` | Valid (tax-exempt order) |
| Some line items have `tax`, others don't | **Rejected** |

**Where tax is calculated:** the operator's checkout / commerce platform calculates tax (using Avalara, TaxJar, or the commerce platform's native tax engine) and passes the result into `orderCreate`. Marketplacer does not run tax rules — it stores the result.

**Why this matters for marketplaces:** in a marketplace context, the tax obligation can differ per seller (e.g., a seller in a no-sales-tax state vs. a state with sales tax) and per shipping destination. The tax engine must understand the multi-seller order and produce per-line-item tax. The output goes into the per-line `cost.tax` and `postage.tax` fields.

## Reconciling the Books

The operator's books need to align with three sources of truth:

| Source of truth | What it owns |
|-----------------|--------------|
| Operator's PSP | Customer-side money movement (capture, refund, dispute) |
| Marketplacer | Per-seller commission, payout obligation, RemittanceAdvice |
| ERP | Accounts receivable (from customers, via PSP) + accounts payable (to sellers, via MPay) |

The reconciliation loop the operator builds (typically nightly):

1. Pull capture/refund events from the PSP for the day.
2. Pull Invoice/RefundRequest/RemittanceAdvice events from Marketplacer for the day.
3. Match on `paymentReference` and refund reference.
4. Post journal entries to the ERP: AR for captures, AP for upcoming seller payouts, commission revenue, refund reversals.
5. Flag any unmatched transactions for manual review.

**Anti-pattern:** treating Marketplacer's `Refunded` state as authoritative for the customer-side refund. The PSP is authoritative for customer money. Marketplacer's state is authoritative for the seller-side ledger.

## Checklist

Before going live with payments/payouts:

- [ ] Checkout integrates with the operator's chosen PSP — not with Marketplacer for capture.
- [ ] `paymentReferences` is sent as an array (even for single-tender) with `{paymentReference, amount}` per PSP transaction.
- [ ] Split-tender orders (gift card + card, etc.) include one entry per tender.
- [ ] Refunds call both the PSP (for customer money) and Marketplacer (for marketplace ledger).
- [ ] The deposit-and-reconcile job uses `mPayStartDepositReconciliation` with `amountPaid` and `amountCollected` per entry.
- [ ] `sum(amountCollected)` balances against the deposit amount; mismatches alert on `unmatched` reconciliations.
- [ ] CommissionPackage assignment per Seller is set up and tested.
- [ ] Operator-side reporting models commission reversal on refund, not gross commission.
- [ ] ERP code distinguishes Remittance (per-invoice) from RemittanceAdvice (per-payout grouping); RemittanceAdvice webhooks drive AP records.
- [ ] Refund mutations use positive values; `invoiceAmendmentUpdate` uses negative values.
- [ ] If `Advanced Amendments` is enabled, additional charges are issued via `refundRequestApprove`/`invoiceAmendmentCreate` and routed to the seller's payout.
- [ ] Tax presence is consistent across all line items in any order.
- [ ] PSP refunds and Marketplacer RefundRequests are kept in sync (both must succeed before the cycle is "done").
- [ ] Chargebacks/disputes from the PSP trigger corresponding Marketplacer refund actions (or manual adjustments via remittance).
