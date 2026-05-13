# Common Anti-Patterns

A quick-reference index of the most frequent and damaging mistakes in Marketplacer implementations. Each entry summarizes the problem and points to the domain file with the full explanation and recommended pattern.

## Table of Contents
- [API & Auth Anti-Patterns](#api--auth-anti-patterns)
- [Data-Model Anti-Patterns](#data-model-anti-patterns)
- [Catalog Anti-Patterns](#catalog-anti-patterns)
- [Order & Fulfillment Anti-Patterns](#order--fulfillment-anti-patterns)
- [Payment & Payout Anti-Patterns](#payment--payout-anti-patterns)
- [Webhook Anti-Patterns](#webhook-anti-patterns)
- [Composable-Stack Anti-Patterns](#composable-stack-anti-patterns)
- [Quick-Scan Review Checklist](#quick-scan-review-checklist)

## API & Auth Anti-Patterns

### Using the Legacy Seller REST API for New Builds

The Legacy Seller REST API is deprecated. New integrations must use the GraphQL Operator API (or Seller GraphQL API for seller-side tooling). The Legacy API persists only for a small handful of features documented in the feature matrix. See `api-setup.md`.

### Sending Both Auth Headers

`Authorization: Bearer` and `marketplacer-api-key` are mutually exclusive — sending both rejects the request. Use one, except when HTTP Basic Auth is also present on non-production environments, where Basic Auth occupies `Authorization` and the API key uses the direct header. See `api-setup.md`.

### Per-Request Client Construction

Creating a fresh GraphQL client per request reads secrets repeatedly, prevents connection reuse, and complicates error handling. Use a singleton per Marketplacer instance per process. See `api-setup.md`.

### Decoding Base64 IDs

Marketplacer IDs are opaque Relay-style base64 strings. Decoding to extract the integer breaks on schema evolution. Use `legacyId` for human display; pass `id` opaquely for all API operations. See `api-setup.md`.

### Designing UI Around Backward Pagination

Marketplacer supports forward-only pagination (`first` + `after`). UIs that depend on `previous page` or `last` operations break. Materialize pages in your own datastore if backward paging is required. See `api-setup.md`.

### Using Fractional Cents or Floats for Money

All money is integer in lowest denomination (cents). Fractional cents round silently; floats lose precision. Always integer cents. See `api-setup.md`.

### Mixing Tax Presence Across Line Items

If `cost.tax` is set on any line item in an order, every line item must include `cost.tax`. Mixed presence fails order creation. See `api-setup.md` and `orders-fulfillment.md`.

### Treating the GraphQL Endpoint as a Constant

Each Marketplacer instance has its own hostname (`https://<instance>/graphql`). Hardcoding the endpoint breaks multi-environment deployments. The hostname is per-environment configuration. See `api-setup.md`.

### Assuming One Instance Can Serve Multiple Regions

One instance = one hostname = one currency. Multi-region implementations use multiple Marketplacer instances. Designing currency or region as a field on a single instance assumes a model that doesn't exist. See `api-setup.md` and `composable-integration.md`.

## Data-Model Anti-Patterns

### Treating Adverts as Marketplace-Wide Product Records

Adverts are per-seller. Two sellers offering "the same product" each own a distinct Advert with distinct IDs. The marketplace-level master record is the **Golden Product**. PIM sync should target Golden Products; Adverts are seller-owned commercial listings. See `data-model.md` and `catalog-management.md`.

### Storing Foreign-System Keys in `metadata`

`metadata` is not queryable. Using it for foreign keys means you can never look up "the Marketplacer record corresponding to PIM ID X" without scanning. Use `externalIds` — explicitly queryable, plural-writeable. See `data-model.md`.

### Confusing `customFields`, `externalIds`, and `metadata`

Three surfaces with different jobs: `externalIds` for queryable foreign-system identifiers, `customFields` for typed business extensions with admin-UI editability, `metadata` for non-queryable display/audit data. Putting business logic in `metadata` makes it un-queryable; putting foreign keys in `customFields` adds unnecessary schema coupling. See `data-model.md`.

### Expecting `metadata` to Appear in the REST API or Admin UI

`metadata` is only surfaced via GraphQL. It's not in the legacy REST API responses and not in the operator portal UI. Anyone relying on those surfaces won't see metadata-stored data. See `data-model.md`.

### Modeling RefundRequest as an Invoice Status

RefundRequest is a separate entity with its own state machine (Created → Returned → Processed → Refunded). Treating refund as an Invoice mutation produces stuck states and incorrect webhook subscriptions. See `data-model.md` and `orders-fulfillment.md`.

## Catalog Anti-Patterns

### Submitting Variant-Level Option Values at Advert Level (or Vice Versa)

The Taxon's Prototype dictates which OptionTypes are variant-level and which are advert-level. Submitting Color as an advert-level option (`advertOptionValues`, or `featureOptionValueIds` on older instances) when the Prototype expects it at variant-level fails validation. Always query the Prototype before constructing the upsert. See `catalog-management.md`.

### Slow Image Source URLs

`sourceUrl` images must resolve in < 5 seconds. Signed/auth-protected internal URLs and slow CDNs silently drop images. Pre-cache to a fast public CDN or inline as `dataBase64`. See `catalog-management.md`.

### Partial Image Array Submissions

The `images` array is treated as the canonical list on every update. Omitting `imageId`s on update deletes those images. Always submit the full list, or use a targeted image mutation. See `catalog-management.md`.

### Expecting Immediate Cross-Seller Backfill from `advertUpsert`

The Golden Product → seller Advert backfill via `advertUpsert` is batch, ~1 hour. For immediate backfill (e.g., seller-scans-barcode UX), use `variantUpsertFromBarcode`. See `catalog-management.md`.

### High-Concurrency `advertUpsert` for Bulk Catalog Sync

The GraphQL Operator API is not optimized for sustained bulk write throughput. Parallel `advertUpsert` calls hit rate limits (429/503). Use Golden Products + batch backfill for bulk catalog; use the dedicated bulk inventory endpoint (REST-only) for inventory. See `catalog-management.md`.

### Trusting Marketplacer HTML Output

Marketplacer does not sanitize HTML in free-text fields like `description`. Rendering raw HTML on the storefront is an XSS vector — particularly dangerous on multi-seller marketplaces. Sanitize at the storefront before render. See `catalog-management.md`.

## Order & Fulfillment Anti-Patterns

### Subscribing to an `Order` Webhook Event

There is no `Order` event. Subscribe to `Invoice`, `Shipment`, and `RefundRequest`. Code that subscribes to "order.create" receives nothing. See `orders-fulfillment.md` and `webhooks-events.md`.

### Designing Single-Seller-Only Order Code Paths

A real marketplace cart will span sellers. `orderCreate` returns one Order with N Invoices. Code that handles only the single-Invoice case breaks the first time a multi-seller cart is placed. Build for N from day one. See `orders-fulfillment.md`.

### Capture-Then-OrderCreate at Checkout

If Marketplacer rejects `orderCreate` after the PSP has captured funds, you have to refund — gateway fees, audit-trail noise, customer confusion. Use authorize → `orderCreate` → capture. Failed `orderCreate` cancels a clean auth. See `orders-fulfillment.md` and `composable-integration.md`.

### Retrying After Stock Errors

Marketplacer enforces stock at order creation; no overstocking, no backorder. Stock errors are terminal — there is no race condition where stock magically reappears. Surface to the customer as out-of-stock; do not retry. See `orders-fulfillment.md`.

### One Shipment Per Invoice

Partial shipments are first-class — multiple Shipments per Invoice, summed quantities ≤ ordered. Code that creates one Shipment per Invoice can't handle backorder fulfillment, multi-package orders, or multi-warehouse picking. See `orders-fulfillment.md`.

### Calling a Fictional Cancel Endpoint

Pre-shipment cancellations use the same RefundRequest workflow as post-shipment refunds. There is no separate "cancel order" entity. See `orders-fulfillment.md`.

## Payment & Payout Anti-Patterns

### Designing Marketplacer as Stripe Connect

Marketplacer is not a split-payment processor. It does not capture customer funds, does not split payments at capture time, does not provide connected-account-style seller payment links. The operator's PSP captures; Marketplacer reconciles after the fact via the deposit-and-reconcile flow. Designing checkout around split-capture is an architectural rewrite. See `payments-payouts.md`.

### Using an Internal Reference as `paymentReferences[].paymentReference`

Each `paymentReferences[]` entry should carry the PSP's primary transaction ID (Stripe PaymentIntent, Adyen pspReference, etc.) so MPay can reconcile deposits against orders. Internal references make reconcile a manual matching exercise. Store internal references in `externalIds`. See `payments-payouts.md`.

### Treating `paymentReferences` as a Singular String Field

The input field is plural: `paymentReferences: [{ paymentReference, amount }]`. Even single-tender orders pass an array of one entry. Coding it as a string causes order creation to fail and rules out split tender (gift card + card) entirely. See `payments-payouts.md`.

### Wrong Sign on Refund Mutation Amounts

`refundRequestRefund` and `refundRequestApprove` take **positive** amounts; Marketplacer flips the sign internally. The lower-level `invoiceAmendmentUpdate` takes **negative** amounts. Mixing them up drifts the deposit reconciliation in the opposite direction. See `payments-payouts.md`.

### Conflating Remittance with RemittanceAdvice

A Remittance is per-Invoice (a debt owed for one invoice). A RemittanceAdvice is per-Seller, per-payout (a grouping of Remittances released together). ERP AP feeds that treat the two as the same entity post duplicate or missing bills. See `payments-payouts.md`.

### Treating Additional Charges as Operator Revenue

Additional Charges (return shipping, restocking) issued via `refundRequestApprove` with `issueInvoice: true` flow to the **seller**, not the operator. Operator-side accounting that captures them as operator revenue is wrong by design. See `payments-payouts.md`.

### Treating Marketplacer's `Refunded` State as the Customer-Side Refund

Marketplacer's `Refunded` state means MPay has reconciled the marketplace ledger — not that the customer has been refunded. The actual money back to the customer is the operator's PSP refund call. These are two distinct operations; both must succeed. See `payments-payouts.md`.

### Reporting Gross Commission Without Modeling Reversal

Commission is reversed on refund. `SUM(invoice.commissionAmount)` overstates operator revenue by the value of refunded commission. Pull net commission (earned − reversed) for any time period. Subscribe to `refundrequest.refunded` events. See `payments-payouts.md`.

### Skipping Tax in Some Line Items

Tax is all-or-nothing across line items in an order. Mixing produces order rejection. The tax engine must produce tax for every line item, even if zero. See `payments-payouts.md` and `orders-fulfillment.md`.

## Webhook Anti-Patterns

### Returning HTTP 4xx from a Webhook Receiver

Marketplacer auto-disables the webhook on 4xx (except 429). One bad deploy that returns 400 on an unknown event type silently kills production event flow. Return 200 for malformed/unknown events (log it); return 500 only for genuine processing failures (gets retries). See `webhooks-events.md`.

### Returning HTTP 4xx on Auth Failure with Bad-Faith Auto-Disable

Even 401 auto-disables the webhook. The mitigation is upstream: verify HMAC before processing reaches any code that could fail, so well-formed signed requests always succeed. See `webhooks-events.md`.

### HMAC Verification Against Re-Stringified JSON

Re-stringifying parsed JSON produces a different byte sequence than the wire-format body. HMAC verification fails intermittently. Verify against the raw request bytes. See `webhooks-events.md`.

### Trusting Webhook Payloads Without HMAC Verification

The webhook endpoint is public. Unsigned acceptance allows attackers to forge order/inventory events. Always HMAC-verify operator-configured webhooks (HMAC available for Operators, not Sellers). See `webhooks-events.md`.

### Relying on Default Webhook Payloads

Without a registered GraphQL query, Marketplacer sends a minimal default payload (essentially just `{ id }`). The receiver has to make follow-up API calls to enrich, multiplying latency and rate-limit pressure. Always register a query. See `webhooks-events.md`.

### Including `updatedAt` in Webhook Queries with Allow-Skip On

Allow-Skip dedup is payload-equality-based. Including `updatedAt` defeats it since every event has a unique timestamp. For "notify on material change" semantics, omit timestamps. For "every state transition" semantics, leave Allow-Skip off. See `webhooks-events.md`.

### Synchronous Processing in the Webhook Handler

Slow handlers risk the 30-second ACK budget and serialize event throughput. Persist the raw event durably, ACK fast, process async. See `webhooks-events.md`.

### Relying on Marketplacer for Long-Term Replay

In high-volume mode (>50k undelivered events), Marketplacer purges delivered events immediately. Failed events retained 3 days. The operator's durable event store is the replay source of truth past these windows. See `webhooks-events.md`.

### No Alert for Disabled Webhooks

A disabled webhook silently stops production data flow. Treat "webhook disabled" status as P1. Poll the status endpoint or set up alerting. See `webhooks-events.md`.

## Composable-Stack Anti-Patterns

### Serving Storefront Catalog Reads from Marketplacer GraphQL

The Operator API is not optimized for storefront read rates. Listing pages, PDPs, search, and faceting must read from the search engine. Marketplacer is the write-side source of truth; the search engine subscribes to webhooks and feeds the storefront. See `composable-integration.md`.

### Treating Marketplacer's Order as the Customer Order

Marketplacer's Order records the marketplace transaction; the customer-facing order is owned by the OMS / commerce platform. Aggregating customer order status from Invoice/Shipment events is the OMS's job. See `composable-integration.md`.

### Generic `external_id` Naming

`externalIds` keys should name the source system and entity (`commercetools_product_id`, `akeneo_variant_id`, `oms_fulfillment_id`). Generic `external_id` collides across integrations and obscures intent. See `composable-integration.md`.

### Forgetting the Instance Dimension on Multi-Instance Implementations

When the operator runs multiple Marketplacer instances (multi-region), every cross-system foreign key needs the instance. A single global `marketplacer_order_id` collides across regions. See `composable-integration.md`.

### Attempting Distributed Transactions Across PSP / Marketplacer / OMS

Distributed transactions don't work in practice across these systems. The integration relies on idempotency: deterministic references (`paymentReferences[].paymentReference`, `externalIds`) so retries don't double-create. See `composable-integration.md`.

## Quick-Scan Review Checklist

During code review, scan for these:

- [ ] Any code that decodes a base64 ID to extract an integer.
- [ ] Any `orderCreate` call that passes `paymentReference` as a string instead of `paymentReferences: [{paymentReference, amount}, …]`.
- [ ] Any refund mutation passing negative amounts to `refundRequestRefund` / `refundRequestApprove` (should be positive — only `invoiceAmendmentUpdate` takes negatives).
- [ ] Any ERP integration that treats Remittance and RemittanceAdvice as the same entity.
- [ ] Any retry loop that ignores the `Retry-After` header on 429/503.
- [ ] Any error handler that reports `MISSING_SCOPE` errors as schema errors.
- [ ] Any webhook subscription including `order.create` / `order.update`.
- [ ] Any webhook handler returning a 4xx for unrecognized event types.
- [ ] Any HMAC verification using `JSON.stringify(req.body)`.
- [ ] Any catalog read in a storefront request path that talks to Marketplacer GraphQL (it should be the search engine).
- [ ] Any storefront component rendering `dangerouslySetInnerHTML` from Advert fields without sanitization.
- [ ] Any commission reporting that uses `SUM(commissionAmount)` without modeling reversal.
- [ ] Any `metadata` write where the data needs to be queried later (should be `externalIds`).
- [ ] Any Stripe Connect / split-payment language in the design doc.
- [ ] Any "previous page" pagination affordance in a Marketplacer-driven list.
- [ ] Any single-Invoice assumption in OMS / fulfillment code.
- [ ] Any retry loop around a stock error.
- [ ] Any `float` or string-with-currency-symbol money handling.
- [ ] Any hardcoded Marketplacer hostname.
- [ ] Any check that only verifies HMAC after the receiver has already done significant work.
