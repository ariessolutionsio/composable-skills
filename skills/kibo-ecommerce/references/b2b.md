# B2B Patterns

Kibo's B2B surface is a distinct entity family — `B2BAccount`, B2B users, quotes, purchase rules, PO payments — not a B2C `CustomerAccount` with extra fields. Code that models B2B as "B2C plus a few flags" loses the approval state machine, the account hierarchy, the quote workflow, and the price-list resolution path. This file covers the B2B account model, the quote lifecycle, approvals, punchout, and net-terms payment, with cross-references to `catalog.md` for price-list resolution and `cart-checkout.md` for the quote-to-checkout handoff.

## Table of Contents
- [B2B vs B2C: Why They Are Not the Same Entity](#b2b-vs-b2c-why-they-are-not-the-same-entity)
- [The Account Hierarchy](#the-account-hierarchy)
- [The B2B Account State Machine](#the-b2b-account-state-machine)
- [Users, Roles, and Permissions](#users-roles-and-permissions)
- [Price-List Resolution for B2B](#price-list-resolution-for-b2b)
- [Quotes — Lifecycle and State Machine](#quotes--lifecycle-and-state-machine)
- [Quote-to-Cart Conversion](#quote-to-cart-conversion)
- [Approval Workflows](#approval-workflows)
- [Punchout / cXML](#punchout--cxml)
- [Net Terms, Purchase Orders, and Credit](#net-terms-purchase-orders-and-credit)
- [Anti-Pattern / Recommended-Pattern Pairs](#anti-pattern--recommended-pattern-pairs)
- [Checklist](#checklist)

## B2B vs B2C: Why They Are Not the Same Entity

Kibo's customer surface has two top-level shapes:

| Shape | Endpoint | Owner | Use for |
|-------|----------|-------|---------|
| `CustomerAccount` | `/commerce/customer/accounts` | One human shopper | B2C |
| `B2BAccount` | `/commerce/customer/b2baccounts` | A company / organization | B2B |

A `B2BAccount` is a **container for many users**, has its own approval state, its own assigned `priceList`, its own `salesReps[]`, its own hierarchy of child accounts, and its own quote workflow. None of that exists on `CustomerAccount`.

**Anti-pattern (the SKILL.md's CRITICAL anti-pattern made concrete):**

```typescript
// Wrong — modeling B2B as a B2C customer plus custom fields.
await api.customer.createAccount({
  body: {
    emailAddress: 'buyer@acme.com',
    firstName: 'Pat',
    lastName: 'Buyer',
    attributes: [
      { fullyQualifiedName: 'company',    values: ['Acme Industrial'] },
      { fullyQualifiedName: 'creditLimit', values: ['50000'] },
      { fullyQualifiedName: 'salesRep',   values: ['rep@operator.com'] },
    ],
  },
});
```

Consequences:
- No approval state machine. The account is "active" the instant it's created. There's no `Pending Approval → Active` transition.
- No price-list-by-account resolution. Wholesale pricing has to be applied via segment hacks.
- No quote workflow. Buyers cannot save a quote, route to a sales rep, and convert back to a cart.
- No account hierarchy. Corporate-HQ → Division → Location does not exist; every user is an island.
- The reporting surface (orders by company, AR by company, commission by sales rep) does not light up.

**Recommended pattern:**

```typescript
// Create a B2BAccount in Pending Approval, then go through the documented transitions.
const b2b = await api.customer.b2b.createAccount({
  body: {
    companyOrOrganization: 'Acme Industrial',
    taxId: '12-3456789',
    users: [
      { emailAddress: 'buyer@acme.com', firstName: 'Pat', lastName: 'Buyer',
        roles: [{ roleId: 1, roleName: 'Buyer' }] },
    ],
    contacts: [/* billing + shipping */],
    attributes: [/* company-specific custom data, NOT identity fields */],
  },
});
// b2b.approvalStatus === 'Pending'

await api.customer.b2b.assignSalesRep({ accountId: b2b.id, userId: REP_USER_ID });
await api.customer.b2b.performStatusAction({ accountId: b2b.id, actionName: 'Approve' });
```

The B2B path is more code on day one and saves rebuilding everything from approvals to AR reporting on day 200.

Source: <https://docs.kibocommerce.com/api-reference/b2baccount/add-account.md>, <https://docs.kibocommerce.com/pages/b2b-overview>.

## The Account Hierarchy

B2B accounts form a tree:

```
CustomerAccount (B2C)             (separate root — does not interoperate)

B2BAccount  rootAccountId = null  (corporate HQ)
 ├── B2BAccount  parentAccountId = HQ      (Division A)
 │    ├── B2BAccount  parentAccountId = A   (Location A-1)
 │    └── B2BAccount  parentAccountId = A   (Location A-2)
 └── B2BAccount  parentAccountId = HQ      (Division B)
```

The fields that drive the tree:

| Field | Purpose |
|-------|---------|
| `id` | Integer account ID |
| `parentAccountId` | The immediate parent, or null for a root |
| `rootAccountId` | The root of the tree (for fast top-of-hierarchy joins) |
| `companyOrOrganization` | Display name |
| `accountType` | `Corporation`, `Division`, etc. (tenant-configurable) |

`GET /commerce/customer/b2baccounts/{accountId}/hierarchy` returns the full subtree below a given account. The hierarchy is **not** automatic — when you create a child account you supply the `parentAccountId`; Kibo derives `rootAccountId` from there.

Hierarchical relationships drive:
- **Aggregated reporting** — show all orders rolled up to the corporate HQ.
- **Inherited contracts** — child accounts can inherit the parent's price list (configuration-dependent; verify against your tenant).
- **Cross-account approval routing** — an approver at HQ can authorize a buyer's order at a child location.

**Anti-pattern:** flattening hierarchy into custom attributes (`parentCompanyName` strings on independent B2B accounts). The hierarchy becomes un-walkable by Kibo's own queries, the rollup reports stop working, and approval routing fails the first time HQ needs visibility into Division A's purchases.

**Recommended pattern:** always use `parentAccountId` for the relationship. Use `rootAccountId` for "give me everything under this corporation" queries.

Source: <https://docs.kibocommerce.com/api-reference/b2baccount/get-b2b-account-hierarchy.md>.

## The B2B Account State Machine

New B2B accounts start in `Pending Approval`. They are **not orderable** until two prerequisites are met:

1. A sales rep is assigned: `POST /commerce/customer/b2baccounts/{id}/salesrep/{userId}`.
2. Status is transitioned via the action endpoint: `POST /commerce/customer/b2baccounts/{id}/status/{actionName}`.

```
Pending Approval ──Approve──▶ Active ──Suspend──▶ Suspended
                                        │
                                        └──Close──▶ Closed
```

| State | Meaning | Orderable |
|-------|---------|-----------|
| `Pending` | Created, not yet approved | No |
| `Active` | Approved and orderable | Yes |
| `Suspended` | Temporarily blocked (collections, dispute, etc.) | No |
| `Closed` | Terminated | No |

Fields involved:

| Field | Purpose |
|-------|---------|
| `approvalStatus` | The state above |
| `isActive` | Independent boolean; `approvalStatus = Active` AND `isActive = true` is the orderable combination |
| `priority` | Integer used by order-release/queue ordering when fulfillment is contended |

**Anti-pattern:** auto-approving B2B accounts on signup (e.g., for a self-service B2B portal). The state machine exists because the operator needs to do credit checks, tax-exemption validation, and rep assignment before the account starts placing PO-backed orders.

**Recommended pattern:** keep the human-in-the-loop step in `Pending`. If self-service signup is required for top-of-funnel reasons, route new accounts to a low-credit-limit, sales-rep-managed default and let the rep upgrade after a manual review.

Source: <https://docs.kibocommerce.com/pages/b2b-overview>.

## Users, Roles, and Permissions

A B2B account contains a `users[]` array. Each user has:

| Field | Purpose |
|-------|---------|
| `userId` | Integer, distinct from the B2C `CustomerAccount` ID space |
| `emailAddress` | Login identifier |
| `firstName`, `lastName` | Identity |
| `roles[]` | Role assignments — each `{roleId, roleName}` |
| `isLocked`, `isRemoved` | Operational state |

The role catalogue is tenant-configurable. Common roles:

| Role | Typical permissions |
|------|---------------------|
| **Buyer** | Place orders within their limits; request quotes; view their own order history |
| **Approver** | Approve carts/orders above a threshold; view the team's pending orders |
| **Admin** | Manage users on the account; manage shipping/billing addresses; act as approver of last resort |
| **Purchaser** | Convert approved quotes to orders; less common; tenant-defined |

Roles are assigned via `POST /commerce/customer/b2baccounts/{id}/roles` and removed via `DELETE`. The exact permission grid per role is **unknown — verify against your tenant** in the admin UI. Treat the role-to-permission mapping as configuration, not as a Kibo-level constant.

**Anti-pattern:** assuming role names map 1:1 to fixed permissions across tenants. A "Buyer" on tenant A may have different limits and approvals than a "Buyer" on tenant B.

**Recommended pattern:** query the role's effective permissions through the platform when permissions matter for an integration, or document the role-to-permission map per-tenant as part of the implementation contract.

## Price-List Resolution for B2B

Pricing for a B2B shopper resolves down a **deterministic priority order**. Same path used by quote pricing.

```
1. B2B account direct assignment              (highest priority)
   B2BAccount.priceList → if set, this list wins.

2. Customer segment match
   Resolve all segments the B2B account / user belongs to.
   For each segment with a mapped price list, take the lowest rank.

3. Catalog default                            (lowest priority)
   The catalog's default prices, with no overrides.
```

| Layer | Driver | Tie-break |
|-------|--------|-----------|
| B2B-direct | `B2BAccount.priceList` field | N/A — only one direct assignment |
| Segment | `mappedCustomerSegments[]` on the price list | Lowest `rank` integer wins |
| Default | Catalog prices | N/A |

The resolved price list code lands on the cart as `priceListCode` (see `cart-checkout.md`) and is **set by the platform**, not by the integration. Do not write `priceListCode` on cart creation as a way to "force" a price tier — it bypasses the resolution logic and may violate contract terms.

**Quote pricing uses the same path.** A quote inherits the buyer's resolved price list at the moment the quote is opened, then locks that list for the duration of the quote. Repricing passes (triggered by item/quantity/shipping changes) recompute against the same locked list.

Cross-reference: `catalog.md` "Pricing & Price Lists" for the full resolution rules and `cart-checkout.md` for where `priceListCode` lives on the cart.

Source: <https://docs.kibocommerce.com/concept-guides/pricing>.

## Quotes — Lifecycle and State Machine

Quotes are first-class in B2B. They are **not carts** — they have their own state machine, their own inventory reservation, and their own draft/discard semantics. A quote-to-order flow goes through Quote → Cart → Checkout → Order; quotes do not bypass checkout.

```
Pending ──submit──▶ In Review ──approve──▶ Ready for Checkout ──convert──▶ Completed
   ▲                    │                          │
   │                    │                          └──expire──▶ Expired ──reopen──▶ In Review
   └────reject──────────┘
```

| State | Editable by | Notes |
|-------|-------------|-------|
| `Pending` | Buyer + seller | Draft; both sides can edit. Buyer can save and return. |
| `In Review` | Seller only | Buyer has submitted; sales rep adjusts pricing/quantity/lines. |
| `Ready for Checkout` | Buyer only | Seller approved; buyer either converts or requests changes. |
| `Completed` | None | Converted to an order; immutable. |
| `Expired` | None (read-only until reopened) | Past `expirationDate`. Can be reopened back to `In Review`. |

**Behavioral notes:**

- **Inventory holds for the duration of the quote.** Items on the quote are reserved on creation and released on expire/cancel. A 90-day quote with 100 widgets removes 100 widgets from available stock for 90 days. Model accordingly.
- **Repricing trigger.** Changes to items, quantities, shipping, or adjustments trigger a repricing pass against the buyer's resolved price list.
- **Drafts.** Edits during `Pending` are uncommitted; discarding reverts to the last approved version. Useful for "let me float a counter-offer without losing the current state."
- **Comment cap.** Comments are capped at **250 characters per entry** (verified in the storefront repo). Multi-paragraph negotiations need multiple comment entries.

Quote endpoints:

| Operation | Endpoint |
|-----------|----------|
| Create quote | `POST /commerce/quotes` |
| Get quote | `GET /commerce/quotes/{id}` |
| Submit for review | `POST /commerce/quotes/{id}/actions` with `actionName: "Submit"` |
| Approve | `POST /commerce/quotes/{id}/actions` with `actionName: "Approve"` |
| Convert to cart | `POST /commerce/quotes/{id}/convert-to-cart` (storefront-side GraphQL mutation is `quoteConvertToCart`) |

The exact action vocabulary, field shape, and GraphQL mutation names are best confirmed against the live tenant — verify in the Kibo MCP server or admin UI before coding.

Source: <https://docs.kibocommerce.com/help/b2b-quotes>, B2B storefront repo (`lib/gql/queries/quotes/`, `lib/gql/mutations/quotes/`).

## Quote-to-Cart Conversion

A quote that reaches `Ready for Checkout` does not become an order directly. The handoff is:

```
Quote (Ready for Checkout)
   │
   ▼  POST /commerce/quotes/{quoteId}/convert-to-cart
   │
Cart (preloaded with quote items + locked priceListCode)
   │
   ▼  POST /commerce/checkouts?cartId={cartId}
   │
Checkout (destinations, groupings, payments — standard flow)
   │
   ▼  POST /commerce/checkouts/{id}/actions  actionName: SubmitOrder
   │
Order
```

The conversion preserves:
- Items and quantities (with the quote's locked prices).
- `priceListCode` (locked at quote open; does not re-resolve on conversion).
- Quote ID as a reference on the cart/order (for audit and reporting).

The conversion releases the quote's inventory reservation back into general stock once the order is submitted (the reservation lifecycle hands off from quote-side to order-side).

Cross-reference: `cart-checkout.md` for the cart → checkout → order side of the flow, including multi-ship-to via `destinations[]` and `groupings[]`. B2B orders fan out to multiple destinations more often than B2C; the architecture is designed around it.

**Anti-pattern:** "fast-path" code that skips the checkout step and creates an order directly from a quote. The order misses destinations/groupings, payment records, tax recalculation, and any cart-level discounts that should have applied — and downstream OMS routing breaks because there are no groupings to route on.

**Recommended pattern:** always go through the cart → checkout → order path. The intermediate stages are doing real work.

## Approval Workflows

The B2B solution page mentions "purchase limit rules" and "B2B order release workflows" but does not fully enumerate the rule model. What is verifiable:

- **Per-user role/permission flags** on `users[]` inside the B2B account. Roles like "Approver" gate `Approve` actions on carts/orders above threshold.
- **`priority` field** on the account, used by the order release queue ordering when fulfillment is contended.
- **Threshold-based approvals.** Orders above a configured dollar threshold can be routed for approval before submission. Threshold values, multi-step routing rules, and the exact rule schema are **unknown — verify against your tenant's admin UI**.

Common shape (verify before relying on it):

| Concept | Likely model |
|---------|--------------|
| Approval rule | Trigger (threshold / category / fulfillment method) + approver(s) (roles or named users) + escalation path |
| Cart-level approval | Holds the cart in `PendingApproval` state; buyer cannot proceed to checkout until cleared |
| Order-level approval | Holds the order in `PendingApproval` after submission; OMS does not release until cleared |
| Multi-step approval | Sequential approver chain; each step must approve before the next is notified |

**Anti-pattern:** building approval logic in the storefront. If the storefront checks "is this order over $5,000? then route to approver," the platform's own approval rules either fight that logic or silently bypass it.

**Recommended pattern:** model approvals in the platform (admin UI or API where exposed) and let the storefront react to the resulting cart/order state. The storefront shows "Awaiting Approval" when the platform says so; it does not decide approval itself.

Source: <https://docs.kibocommerce.com/pages/b2b-overview> (mentions only; specifics unverified in fetched docs).

## Punchout / cXML

Punchout (procurement-system integration via cXML — Ariba, Coupa, SAP SRM, etc.) is **not surfaced as a first-party feature in the indexed Kibo concept guides**. The capability is **unknown — verify with Kibo** before scoping a punchout integration.

Likely paths (none confirmed in public docs):

1. **Partner add-on.** A Kibo partner may offer cXML support as a packaged integration.
2. **Custom API Extension.** Implement the punchout protocol (`PunchOutSetupRequest`, `PunchOutOrderMessage`) inside an Extension that handles the SSO handoff and the `cXML` order POST. See `extensions-events.md`.
3. **External middleware.** A standalone service (your own or a vendor's) speaks cXML to the procurement system and Kibo REST to the platform.

Until verified, treat punchout requirements as a **separately-scoped sub-project**, not a checkbox feature. The differences between cXML versions, the SSO handoff requirements (Ariba's `From/To/Sender` identity blocks), and the specific procurement system's quirks (Coupa's level-2/3 invoice data, SAP SRM's hashed cookie auth) make it material work even if a base feature exists.

**Recommended pattern:** during requirements discovery, surface punchout early and confirm Kibo's path. Do not assume it exists OOTB; do not assume a B2C-only integration plan can be retrofitted later without significant work.

## Net Terms, Purchase Orders, and Credit

The **Purchase Order** payment type is a first-party Kibo payment when enabled on the seller side (per the B2B overview). It is selected at checkout the same way a credit card would be — `CreatePayment` with the PO payment method — except funds are not authorized at a PSP; the order ships against credit on file.

What is verifiable:

| Concept | Status |
|---------|--------|
| PO as a payment method | Confirmed in B2B overview |
| Credit balance management | Referenced |
| Per-account credit limit fields | **Unknown — verify against tenant.** Storefront repo references `get-customer-purchase-order-account.ts` suggesting a dedicated query exists |
| Aging buckets (30/60/90) | **Unknown — verify against tenant.** Likely tenant- or partner-specific reporting |

The plausible field shape on the PO account (not fully documented):

```typescript
// Plausible — verify against the live GraphQL schema before relying on it.
type PurchaseOrderAccount = {
  customerAccountId: number;
  isEnabled: boolean;
  creditLimit: number;
  availableBalance: number;
  paymentTerms: string;   // e.g. "Net 30"
  // ... aging fields likely exist; shape not confirmed in fetched docs
};
```

**Anti-pattern:** computing credit limits and available balance in your own integration code (subtracting open orders from a static credit limit you store yourself). When the operator updates the credit limit in Kibo, or a customer pays an invoice and increases the available balance, your computation goes stale.

**Recommended pattern:** read the platform's PO account state at checkout time. If the platform exposes available balance and term, use it. If field shape is uncertain, verify in the GraphQL playground or via Kibo support before relying on a specific schema.

**At submission:** PO orders go through the same checkout flow as credit-card orders, but the payment action sequence is `CreatePayment` with the PO method — no `AuthorizePayment`/`CapturePayment` against a PSP. The order is created in a payment-pending state and reconciled against the PO/AR ledger downstream.

Source: <https://docs.kibocommerce.com/pages/b2b-overview>, B2B storefront repo (`get-customer-purchase-order-account.ts`).

## Anti-Pattern / Recommended-Pattern Pairs

### Modeling B2B as B2C plus custom fields

Covered above — see [B2B vs B2C](#b2b-vs-b2c-why-they-are-not-the-same-entity).

### Flattening account hierarchy into custom strings

**Anti-pattern.**

```typescript
// Wrong — hierarchy stored as denormalized strings.
await api.customer.b2b.createAccount({
  body: {
    companyOrOrganization: 'Acme Division A',
    attributes: [
      { fullyQualifiedName: 'parentCompany', values: ['Acme Industrial'] },
    ],
  },
});
```

`GET /b2baccounts/{id}/hierarchy` returns nothing. Rollup reports break. Approval routing across the tree fails.

**Recommended.**

```typescript
const hq = await api.customer.b2b.createAccount({ body: { companyOrOrganization: 'Acme Industrial' } });

const divisionA = await api.customer.b2b.createAccount({
  body: {
    companyOrOrganization: 'Acme Division A',
    parentAccountId: hq.id,
    // rootAccountId is derived by the platform from the parent chain
  },
});
```

### Skipping the Pending Approval state

**Anti-pattern.** Auto-creating B2B accounts in `Active` state through a self-service signup.

```typescript
// Wrong — no manual review, no rep assignment, no credit check.
const b2b = await api.customer.b2b.createAccount({ body: { /* ... */ approvalStatus: 'Active' } });
```

**Recommended.** Let the platform create the account in `Pending`, then perform the operator-side validation (credit pull, tax-exemption verification, rep assignment) before the `Approve` action.

```typescript
const b2b = await api.customer.b2b.createAccount({ body: { /* ... */ } });
// b2b.approvalStatus === 'Pending'

// Operator side runs credit + tax checks asynchronously, then:
await api.customer.b2b.assignSalesRep({ accountId: b2b.id, userId: REP_USER_ID });
await api.customer.b2b.performStatusAction({ accountId: b2b.id, actionName: 'Approve' });
```

### Writing `priceListCode` on the cart to force B2B pricing

**Anti-pattern.**

```typescript
await api.cart.create({ body: { priceListCode: 'B2B_WHOLESALE' } });
```

Bypasses segment + B2B-account resolution. The cart shows wholesale prices for a buyer who may not be entitled to them.

**Recommended.** Let the platform resolve `priceListCode` from the buyer's B2B account assignment or segment membership. If a specific price tier is desired, change the buyer's segment membership or B2B account, not the cart.

### Building approval thresholds in the storefront

**Anti-pattern.**

```typescript
if (cart.total > 5000) {
  await routeForApproval(cart);
}
```

The platform may have its own approval rules. Now there are two systems making the decision and they disagree.

**Recommended.** Read approval state from the cart/order. The storefront renders "Awaiting Approval" when the platform says so.

```typescript
if (cart.approvalStatus === 'PendingApproval') {
  renderAwaitingApprovalUI(cart);
}
```

### Treating quotes as a synonym for "saved cart"

**Anti-pattern.**

```typescript
// "Save for later" stores the cart in the storefront's own DB.
await db.savedCarts.insert({ userId, cartSnapshot });
```

No inventory hold. No pricing lock. No sales-rep workflow. No conversion-to-order audit trail.

**Recommended.** Use the Quote entity for any "save and revisit" B2B flow. The inventory reservation, price locking, and rep-side workflow are the whole point.

```typescript
const quote = await api.quotes.create({ body: { items: cart.items, expirationDate: in90Days } });
// Quote is now in Pending; inventory reserved; can be submitted, reviewed, and converted.
```

### Computing credit limits client-side

**Anti-pattern.**

```typescript
const remaining = customAccountCreditLimit - (await getOpenOrderTotal(accountId));
if (cart.total <= remaining) proceed();
```

Stale the moment the operator updates the credit limit or an invoice is paid.

**Recommended.** Read the PO account state at checkout time; let the platform decide whether the PO payment can be created.

```typescript
const poAccount = await api.customer.b2b.getPurchaseOrderAccount({ accountId });
if (poAccount.availableBalance >= cart.total) {
  await api.checkout.performPaymentAction({
    checkoutId, paymentId,
    actionName: 'CreatePayment',
    body: { paymentType: 'PurchaseOrder', /* ... */ },
  });
}
```

## Checklist

Before shipping B2B integration code:

- [ ] B2B accounts are created via `/commerce/customer/b2baccounts`, **not** as `CustomerAccount` with extra fields.
- [ ] Account hierarchy uses `parentAccountId` / `rootAccountId`; hierarchy is **not** denormalized into custom attributes.
- [ ] New accounts go through `Pending Approval`; sales rep is assigned and status is transitioned before the account is orderable.
- [ ] Users on a B2B account carry explicit `roles[]`; role-to-permission mapping is documented per tenant.
- [ ] Price-list resolution flows B2B-direct → segment (lowest `rank`) → catalog default; `priceListCode` is never written on the cart to force a tier.
- [ ] Quotes are used for "save and revisit" — not a custom saved-cart store. Inventory reservation and price locking are leveraged.
- [ ] Quote-to-order goes through Cart → Checkout — no fast-path that skips checkout.
- [ ] Quote inventory reservation lifetime is understood; long-lived quotes are time-boxed against available stock.
- [ ] Approval rules live in the platform; the storefront reads `approvalStatus` and renders accordingly — it does not make the approval decision.
- [ ] Multi-ship-to is supported via `destinations[]` + `groupings[]` on Checkout (see `cart-checkout.md`); B2B orders frequently fan out to multiple locations.
- [ ] PO payments go through `CreatePayment` with the PO method; available credit/balance is read from the platform at checkout time, not computed client-side.
- [ ] Punchout / cXML scope is confirmed with Kibo (or scoped as a separate sub-project) **before** the B2B requirements are finalized — not retrofitted later.
- [ ] Storefront uses the B2B starter (`KiboSoftware/nextjs-storefront-b2b`) as the reference, not the B2C starter retrofitted with custom queries.
