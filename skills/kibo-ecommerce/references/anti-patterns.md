# Common Anti-Patterns

A quick-reference index of the most frequent and damaging mistakes in Kibo eCommerce implementations. Each entry summarizes the trap and the consequence, and points to the domain file with the recommended pattern and code.

## Table of Contents
- [Catalog Anti-Patterns](#catalog-anti-patterns)
- [Cart & Checkout Anti-Patterns](#cart--checkout-anti-patterns)
- [B2B Anti-Patterns](#b2b-anti-patterns)
- [CMS & Storefront Anti-Patterns](#cms--storefront-anti-patterns)
- [Platform & Integration Anti-Patterns](#platform--integration-anti-patterns)
- [Quick-Scan Review Checklist](#quick-scan-review-checklist)

## Catalog Anti-Patterns

### Sending `x-vol-site` Without `x-vol-catalog` (or vice versa)

The `x-vol-*` headers select scope. Omitting the right header returns the wrong scope's data, not an error — site-scoped calls without `x-vol-site` quietly return master-catalog data, and admin calls without `x-vol-master-catalog` return tenant-default scope. See `api-setup.md` and `catalog.md`.

### Modeling Variation-Bearing Attributes as Properties

Color or Size modeled as a Property instead of an Option means **no variations, no per-color SKUs, no per-color inventory, no per-color pricing**. Once a product is live, recovering is a data migration. The Option/Property/Extra split is hard, not stylistic. See `catalog.md`.

### Trying to Publish Per-Site When Sites Share a Master

Kibo's publishing is "all or nothing across sites sharing a master catalog." Code or processes that assume per-site publish targets do not work. Either split into separate masters, or use catalog-level overrides for the per-site differences. See `catalog.md`.

### Building Real-Time Category Targeting on Dynamic Precomputed

Precomputed categories evaluate at indexing time and cannot see promotional/sale prices. A "Clearance" or "Under $X after discount" category needs **Dynamic Realtime**; using Precomputed gives incorrect membership. See `catalog.md`.

### Treating `priceListCode` on the Cart as a Writeable Field

`priceListCode` is the resolution result of (B2B account → segment → catalog default), not a free-form input. Overriding it manually bypasses segment-gating and risks selling at the wrong price to the wrong buyer. Drive resolution through segment / B2B-account assignment instead. See `catalog.md`.

### Storing Foreign-System Keys in Product `properties`

`properties` are catalog-scoped attributes meant for filtering and display. Stashing a PIM ID or ERP ID there pollutes the storefront facet space and couples external identifiers to publish cycles. Use the **Entities API** for sync state and foreign keys. See `catalog.md`.

### Duplicating Inventory into Catalog Attributes

Inventory is volatile and lives in the OMS subsystem (UPC × Location). Duplicating stock counts into product properties produces stale displays and breaks every time the OMS allocates or releases. Read availability from the storefront product API (which embeds ATP) or from the OMS APIs. See `catalog.md` and `kibo-oms`.

## Cart & Checkout Anti-Patterns

### Treating the Cart as the Customer-Facing Checkout

Shipping address, fulfillment splits, payment records, and `SubmitOrder` all live on Checkout, not Cart. Driving them off the Cart loses the multi-ship-to model (`destinations[]` + `groupings[]`) and breaks the moment a real B2B order needs to fan out. Convert cart → checkout explicitly. See `cart-checkout.md`.

### Reading Coupon Failures as HTTP Errors

`PUT /commerce/carts/{cartId}/coupons/{couponCode}` returns **HTTP 200 with `invalidCoupons[]` populated** when a coupon is rejected. Code that checks `res.status` and treats 200 as success silently swallows rejections. Always read `invalidCoupons[]` and surface `reason`. See `cart-checkout.md`.

### Capture-Before-Submit at Checkout

Capturing the PSP payment before `SubmitOrder` means a failed submit leaves you with captured funds and no order — gateway fees, audit-trail noise, manual refund. Sequence is **Authorize → SubmitOrder → Capture (deferred via Flexible Auto Capture, typically on fulfillment)**. See `cart-checkout.md`.

### Hardcoding Index 0 on `payments[]`

Split tender (gift card + card, store credit + card) produces multiple payment records. Code that reads `checkout.payments[0]` works in dev with one payment, fails the first time a real customer applies a gift card. Iterate; reconcile `amountRemainingForPayment` to zero. See `cart-checkout.md`.

### Hardcoding Discount Stacking Behavior in the Storefront

Stacking is governed by per-discount `canBeStackedUpon`, `stackingLayer`, and `prevent*` flags — not by amount type or scope. Storefront code that pre-empts the platform's promotion engine ("percentages and amounts don't stack") produces incorrect cart totals. Trust the resolved `productDiscounts[]` / `orderDiscounts[]`. See `cart-checkout.md`.

### Posting Raw Card Numbers to the Main API

Card data must transit `KIBO_PCI_HOST` (`payments-sb.mozu.com` / `pmts.mozu.com`), not the main API host. Bypassing the PCI host scopes the storefront and backend into PCI-DSS compliance and may fail an assessor. Tokenize at the PCI host; pass only the token onwards. See `cart-checkout.md`.

### Assuming a Specific Anonymous → Authenticated Merge Behavior

The merge strategy on cart-takeover (sum / replace / append) is **unknown without testing** and may be configurable per tenant. Code that hardcodes an assumption ships bugs like "promotions disappear after login." Verify against the tenant before committing to a behavior. See `cart-checkout.md`.

### Assuming a "Quote Bypass" Path

Quotes flow through standard Checkout — converting a quote to an order does not bypass cart/checkout. There is no quote-direct-to-order mutation. The quote is the source of the cart's line items; the standard checkout pipeline runs from there. See `cart-checkout.md` and `b2b.md`.

## B2B Anti-Patterns

### Modeling B2B Customers as B2C Customers + Custom Fields

B2B has a distinct entity hierarchy: B2B Account → Users (with roles) → Contacts → assigned Sales Reps. It carries directly-assigned price lists, approval workflows, purchase rules, and customer-set site gating. Mapping it onto "B2C customer with extra fields" loses all of that. See `b2b.md`.

### Building Quote Flows Against the Cart

Quotes have their own state machine (Pending → In Review → Ready for Checkout → Completed / Expired), their own inventory reservation (held for the quote duration), and their own draft/discard semantics. A "cart with a saved-for-later flag" does not model any of this. Use the quote entity. See `b2b.md`.

### Assuming Punchout / cXML Is First-Party

Punchout / cXML support is **unknown — not surfaced in the public documentation pages this skill is built from**. It may be available via partner add-ons or custom API Extensions. Before scoping a procurement integration, verify with Kibo support or the partner ecosystem. See `b2b.md`.

### Building Approval Workflows From Memory

The B2B approval-rule schema (purchase limits, multi-tier approval, order release rules) is referenced in marketing material but **not field-documented** in the public concept guides. Building approval logic on assumed shapes ships bugs. Verify against the admin UI and the tenant's actual rule configuration. See `b2b.md`.

### Treating Net-Terms / PO-on-Account Shapes as Documented

The Purchase Order payment method is a first-party payment type when enabled, but the **credit-limit / aging-bucket / PO-account field shapes are not fully documented**. The storefront repo references `get-customer-purchase-order-account.ts`, suggesting a dedicated query exists. Verify against the live GraphQL schema before implementing. See `b2b.md`.

## CMS & Storefront Anti-Patterns

### Treating Kibo CMS as the Product Master

Kibo Documents (the headless CMS surface) is for marketing pages, hero banners, size guides, and email/packing-slip templates — not for product master data. Product attributes belong in the catalog product type; "product copy" stored as a Document is unmaintainable and disconnected from the storefront product API. See `cms-storefront.md`.

### Expecting a Visual Page-Builder for Headless Storefronts

The Kibo Admin's "Page Builder" works against hosted-theme storefronts. For headless implementations, the CMS surface is the Documents API (DocumentType-driven schemas, not WYSIWYG blocks). Teams that expect Builder.io / Sanity-style block editing should layer an external CMS over Kibo. See `cms-storefront.md`.

### Serving Storefront Catalog Reads from REST

The REST API is admin/back-office-shaped and not optimized for storefront request rates. Listing pages, PDPs, search, and faceting must use the GraphQL storefront API (or an external search engine that subscribes to events). REST under traffic hits rate limits. See `cms-storefront.md` and `api-setup.md`.

### Using GraphQL for Admin Workflows

GraphQL is storefront-shaped — no discount creation, no category creation, no B2B account onboarding, no product type management. Trying to drive admin workflows through GraphQL hits missing fields. Switch to REST for admin/back-office work. See `api-setup.md`.

### Trusting Marketplacer-Style HTML Sanitization

Kibo does not sanitize HTML in product descriptions or CMS document content. Rendering raw HTML via `dangerouslySetInnerHTML` is an XSS vector. Sanitize on the storefront before render. See `cms-storefront.md`.

## Platform & Integration Anti-Patterns

### Hardcoding `mozu.com` (or Any Hostname) in Source

Hostnames are environment- and region-specific: US sandbox (`t{id}.sandbox.mozu.com`), US prod (`t{id}.tp0.mozu.com`), EU sandbox (`t{id}.sb.euw0.kibocommerce.com`), plus GCP regional variants. Hardcoding breaks every multi-environment promotion. Configure via env (`KIBO_API_HOST`). See `api-setup.md`.

### Forgetting Token Refresh

OAuth `client_credentials` tokens expire. A long-lived process or a singleton client must refresh on expiry; otherwise intermittent 401s that look like flaky network are actually expired tokens. See `api-setup.md`.

### Trusting Event Subscription Payloads Without Hydrating

Event payloads are minimal — `eventID`, `topic`, `entityID`, `timestamp`, `correlationID`, `isTest`, `extendedProperties`. Receivers expected to **call back to the API** with the `entityID` to fetch the full object. Code that builds projections from the event body alone ships stale or missing data. See `extensions-events.md`.

### Assuming HMAC on Event Subscription Webhooks

The public event-notifications docs do not describe HMAC signing for webhook payloads. **Verify per tenant; absence in docs ≠ absence in product.** If HMAC is not available on the tenant, treat the receiver endpoint as untrusted and verify payload identity by callback to the Get-by-ID API before acting. See `extensions-events.md`.

### Re-Stringifying Parsed JSON Before HMAC Verification (if HMAC Available)

When HMAC is in play, re-stringifying parsed JSON produces a different byte sequence than the wire-format body, causing intermittent verification failures. Verify against the raw request bytes. See `extensions-events.md`.

### Polling for Order or Return Status

The Event Subscription mechanism covers `order.created`, `order.updated`, `order.cancelled`, `order.fulfilled`, `order.closed`, `payment.authorized`, `payment.captured`, `payment.refunded`, `return.opened`, `return.closed`, `return.rejected`, and others. Polling burns rate budget and lags real state. Subscribe. See `extensions-events.md`.

### Building API Extensions for Things Events Should Handle

API Extensions (Arc.js) run synchronously in the platform — use for enrichment, validation, payload mutation, in-line third-party calls during checkout. Downstream sync (ERP, search index, email, analytics) is fire-after-the-fact and belongs in **Event Subscriptions**. Using Extensions for async work adds checkout latency you can't recover. See `extensions-events.md`.

### Returning HTTP 4xx From a Webhook Receiver

Event-subscription receivers must return 200 quickly. Returning 4xx (other than 429) on unknown event types or malformed payloads can cause the subscription to be disabled. Return 200 for malformed / unknown events (log it); return 500 only for genuine processing failures (which get retried per the retry schedule). See `extensions-events.md`.

### Synchronous Processing in the Event Receiver

Receivers have a 45-second budget to return 200. Slow handlers risk timeouts and serialize event throughput. Persist the raw event durably, ACK fast, process async. Retry schedule is 5min → 1hr → 24hr with 14-day TTL — long handler tails consume that budget. See `extensions-events.md`.

### Hardcoding Tenant IDs in Source

Tenant ID is environment configuration, not a constant. Hardcoded tenant IDs break multi-environment promotions and tenant migrations. Drive from env / config. See `api-setup.md`.

## Quick-Scan Review Checklist

During code review, scan for these:

- [ ] Any REST call missing the appropriate `x-vol-*` header for its scope (`x-vol-site` for storefront, `x-vol-master-catalog` for catalog admin, `x-vol-catalog` for child-catalog admin).
- [ ] Any product type definition where a shopper-selectable attribute (color, size) is in `properties` instead of `options`.
- [ ] Any code that writes `priceListCode` directly onto a cart or checkout.
- [ ] Any storage of PIM IDs, ERP IDs, or other foreign-system identifiers inside product `properties`.
- [ ] Any "publish to site X only" logic on a multi-site / shared-master setup.
- [ ] Any Dynamic Precomputed category whose rule depends on `salePrice` or discounted price.
- [ ] Any cart / checkout code that writes `shippingAddress` directly to the cart, bypassing Checkout's `destinations[]` + `groupings[]`.
- [ ] Any coupon-application code that checks `res.status` without reading `cart.invalidCoupons[]`.
- [ ] Any payment sequence that captures before `SubmitOrder`.
- [ ] Any `checkout.payments[0]` access (hardcoded index instead of iterating).
- [ ] Any storefront component rendering `dangerouslySetInnerHTML` from product or CMS fields without sanitization.
- [ ] Any storefront catalog read path that hits REST instead of GraphQL.
- [ ] Any admin workflow (discount creation, category creation, B2B onboarding) attempted via GraphQL.
- [ ] Any card capture that posts to the main API host instead of `KIBO_PCI_HOST`.
- [ ] Any HMAC verification using `JSON.stringify(req.body)` (must verify against raw bytes).
- [ ] Any event-subscription receiver returning 4xx on unknown event types.
- [ ] Any event-receiver handler that does substantial work synchronously before returning 200.
- [ ] Any projection code that reads only the event body without hydrating via API callback.
- [ ] Any polling loop for order/return/payment state that could be a subscription.
- [ ] Any hardcoded hostname (`mozu.com`, `kibocommerce.com`, sandbox/prod-specific).
- [ ] Any hardcoded tenant ID in source code.
- [ ] Any OAuth client without token refresh logic for expiry.
- [ ] Any B2B feature modeled as "B2C customer + custom field."
- [ ] Any quote flow that bypasses checkout / treats the cart as the quote.
- [ ] Any inventory read that comes from product attributes instead of the storefront product API or OMS inventory API.
- [ ] Any "Kibo CMS holds product copy" pattern; product copy belongs on the product type, not in Documents.
- [ ] Any Kibo Page Builder dependency on a headless storefront (the visual page builder is hosted-theme only).
- [ ] Any API Extension doing async / downstream-sync work that belongs in an Event Subscription.
