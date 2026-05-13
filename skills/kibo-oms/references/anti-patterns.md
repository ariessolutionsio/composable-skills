# Common Anti-Patterns

A quick-reference index of the most frequent and damaging mistakes in Kibo OMS implementations. Each entry summarizes the problem and points to the domain file with the full explanation and recommended pattern.

## Table of Contents
- [Order Intake Anti-Patterns](#order-intake-anti-patterns)
- [Fulfillment Anti-Patterns](#fulfillment-anti-patterns)
- [Order Routing Anti-Patterns](#order-routing-anti-patterns)
- [Inventory Anti-Patterns](#inventory-anti-patterns)
- [Returns Anti-Patterns](#returns-anti-patterns)
- [Shipping Anti-Patterns](#shipping-anti-patterns)
- [Platform & Webhook Anti-Patterns](#platform--webhook-anti-patterns)
- [Quick-Scan Review Checklist](#quick-scan-review-checklist)

## Order Intake Anti-Patterns

### Importing Orders with `isImport=false` from an External Source

Kibo tries to re-validate the order through its checkout pipeline — re-runs inventory allocation, re-attempts payment capture against an already-captured gateway transaction, and double-decrements inventory. The order's `type` should be `"Offline"` and `isImport` should be `true` for any non-Kibo cart. See `order-intake.md`.

### Pricing-Total Drift on Import

`sum(items[].subtotal) + tax + shipping − discount ≠ order total` → 422 on `POST /commerce/orders`. The most common cause of import rejection. Compute totals in the source platform's currency precision; mirror the source's own pre-computed line totals rather than recomputing in the integration. See `order-intake.md`.

### Stuffing Tracking or Other Data Into `externalId`

`externalId` is the source-platform order foreign key — the canonical identifier Kibo uses for round-tripping. Tracking belongs on the Package (`shipments[].packages[].trackingNumber`); auxiliary identifiers belong in custom order attributes. Conflation breaks reconciliation and idempotency lookup. See `order-intake.md`.

### No Pre-Post Idempotency Check on Order Push

Upstream retries (Shopify's `order_paid` webhook firing multiple times, integration crash + replay) duplicate orders without a pre-check. Always query `GET /commerce/orders?filter=externalId eq <id>` before posting, or use a deterministic ID strategy that lets Kibo reject the duplicate cleanly. See `order-intake.md`.

### Generic `external_id` Naming on Custom Attributes

When custom attributes carry foreign keys, name them after the source system and entity (`shopify_order_id`, `sfcc_order_number`, `oms_legacy_id`). Generic `external_id` collides across integrations and obscures intent. See `order-intake.md`.

### Forgetting `fulfillmentMethod` on Each Line Item

Routing cannot dispatch a line without a `fulfillmentMethod`. The line stays pre-Accept and the order surfaces in the `Customer Care` rollup. Always set `Ship`, `Pickup`, `DirectShip`, `Digital`, or `Delivery`. See `order-intake.md`.

### Using Parent SKU as `productCode` When Variants Exist

Kibo expects one `productCode` per variant. Submitting the parent SKU for a variant-level Shopify product fails the lookup or — worse — attaches inventory to a phantom record. Map Shopify `variant.sku` (not the parent SKU) → Kibo `productCode`. See `order-intake.md`.

### Capture-Then-Import at Checkout

If Kibo rejects the import after the PSP has captured funds, the integration has to refund — gateway fees, audit-trail noise, customer confusion. Prefer `authorize → import → capture` where the source platform allows it. Imports that fail become clean auth cancellations. See `order-intake.md`.

### Treating Bundled and Standalone Modes the Same Way

Bundled (orders originate in Kibo eCommerce) and standalone (imported from Shopify/SFCC) have different ownership boundaries. Code that assumes everything is bundled breaks on standalone deals; code that assumes everything is standalone misses Kibo's cart events. Branch on `isImport`. See `order-intake.md`.

## Fulfillment Anti-Patterns

### Treating the Order as the Unit of Fulfillment Work

The Shipment is the unit, not the Order. Subscribing only to `order.*` events means you see orders arrive but never see them ship. One Order produces N Shipments, each with its own BPMN workflow and its own event stream. See `fulfillment.md`.

### Subscribing Only to `order.opened` and Never to `shipment.*`

You see orders arrive but never see them ship. Order webhooks give ID-only metadata; the shipment lifecycle never appears in order events. Subscribe to `shipment.statuschanged`, `shipment.workflowstatechanged`, `shipment.partialpickupready`. See `fulfillment.md`.

### Hand-Coding Shipment Status Transitions

`PUT /commerce/shipments/{id}` with a direct status field bypasses the BPMN engine's audit log, side-effects, and downstream task hooks. Use `PUT /commerce/shipments/{shipmentNumber}/tasks/{taskName}/completed`. The BPMN workflow enforces order; skipping tasks via direct status writes bypasses validation. See `fulfillment.md`.

### One-Shipment-Per-Order Assumption

A mixed BOPIS + ship order splits into multiple shipments. Code that creates exactly one Shopify Fulfillment per Kibo Order can't represent the pickup shipment separately from the ship-to-home shipment. Build for N shipments per order from day one. See `fulfillment.md`.

### Trusting the Order `status` Alone for "Is This Done?"

Use the rollups: `Fulfillment = Fulfilled AND Payment ∈ {Paid, Paid And Errored}` is the actual closed test. `order.status == Completed` alone misses the Customer Care escalation and the rare paid-but-unfulfilled state. See `fulfillment.md`.

### Ignoring the `Customer Care` Fulfillment Rollup

Orders sit silently in `Customer Care` when a shipment hits a manual hold. Kibo does not auto-resolve. Production dashboards must surface `Customer Care` as an exception queue. See `fulfillment.md`.

### Building a Custom Dropship Workflow Instead of Using `Default_Dropship_Process`

The Vendor Portal's Order Acknowledgement + ASN flow expects the default workflow's task names. Custom workflows lose the vendor UX end-to-end. Customize via attributes and routing scenarios, not by replacing the dropship BPMN. See `fulfillment.md`.

### Hard-Coding Workflow Names

`Default_STH_Process` exists on most tenants but customers fork freely (`TLG_Custom_STH`, `AFG_Custom_STH`). Look up the active workflow per `fulfillmentType` on the location/site config rather than hard-coding the default name. See `fulfillment.md`.

### Driving BOPIS Pickup-Ready Notifications from Order Events

"Your order is ready for pickup" must fire on the shipment's `Awaiting Collection` state or the `shipment.partialpickupready` event — not on order-level status, which doesn't model pickup readiness. Order-driven notifications produce stale or wrong messages on mixed-mode orders. See `fulfillment.md`.

### Polling for Shipment Status

Polling burns rate limit and lags real state. Kibo expects event-driven; subscribe to `shipment.statuschanged` and re-fetch on the event ID. See `fulfillment.md`.

## Order Routing Anti-Patterns

### Enabling Split Shipments Without Modeling Carrier-Cost Downside

Split shipments multiply shipping cost. Enabling "Allow Split" as an After Action without an excess-inventory or consolidation strategy in front of it produces a high-split shop. Model the cost in reporting before turning it on. See `order-routing.md`.

### Treating the Order Routing Explain Agent as a Routing Engine

The Q1 2026 Order Routing Explain Agent is an observability / audit tool — it explains routing decisions in natural language. It does not change them. Building automation that feeds the Explain Agent's output back into routing is a category error. See `fulfillment.md`.

### Routing to Locations Without Capacity Constraints

Each Location has an optional `fulfillmentCapacity` (e.g., 50 shipments/day). Without it, ship-from-store routes can flood stores beyond their picking capacity on traffic spikes. Set capacity per location for any store-fulfillment program. See `order-routing.md`.

### Ignoring Location Capabilities in Routing Filters

Locations have per-capability flags (BOPIS-eligible, Curbside-eligible, STH-eligible, Dropship-eligible). Routing rules that don't filter on capability try to fulfill from disabled locations and surface in `Customer Care`. Always filter on the capability that matches the line's `fulfillmentMethod`. See `order-routing.md`.

## Inventory Anti-Patterns

### Reading Aggregate Inventory and Treating It as Authoritative

Inventory in Kibo is tracked at (UPC × Location) granularity. Aggregating across locations to a single number is a derived view, not the source of truth. Oversells happen at high-velocity SKUs when routing assumes the aggregate but the actual location lacks stock. See `inventory.md`.

### Mixing `Refresh` and `Adjust` Inventory Calls Without Ordering

`Refresh` sets absolute quantities; `Adjust` applies deltas. A Refresh after Adjusts already landed silently reverts the deltas. Pick one mode per data path: Refresh for full periodic re-syncs (nightly), Adjust for real-time event-driven deltas. Mixing the two carelessly is a classic race-condition source. See `inventory.md`.

### Calling `Refresh` Per-Item in a Loop

`Refresh` is queued and processed serially. 10k items in 10k calls = hours of latency. Batch up to 3,000 items per call (Kibo recommends; the hard limit is 12,000). See `inventory.md`.

### Treating Source-Platform Inventory as Real-Time Truth

The inventory sync from Kibo to the source is eventual, not synchronous. Under load, the storefront's inventory mirror lags. PDPs that need accurate availability should query Kibo's Real-Time Inventory Service directly, not the source platform's mirror. See `order-intake.md`.

### Conflating Backorder, Out-of-Stock, and Pre-Order

`Pending` quantity type (Kibo's opt-in backorder buffer), unallocatable-zero (out of stock), and confirmed-future inventory (`Future` quantity type) are different states. Conflating them produces wrong delivery-promise dates and inventory accounting drift. See `inventory.md`.

### Modeling Source-Platform Inventory as a Single Per-SKU Number When Network Has Nuance

BOPIS-eligible inventory at a store, ship-only inventory at a DC, and dropship-only inventory at a vendor are different products from the storefront's perspective. Collapsing all three into one "available" number on the source platform loses the BOPIS pickup-locations affordance. Collapse only after explicit choice. See `order-intake.md`.

## Returns Anti-Patterns

### Modeling Returns as an Order Edit

Returns / RMA is a separate entity with its own state machine (`Created → Authorized → Closed`). Treating return as an `UpdateOrder` mutation produces stuck states, miscounted inventory, and incorrect webhook subscriptions. See `returns.md`.

### Assuming Kibo Refunds via the PSP Automatically

On OMS-only deployments, Kibo records the credit decision but does not call the PSP. The integration must listen for `payment.credited` and trigger the actual PSP refund (typically via the source platform's refund API — Shopify's refund call, etc.). See `returns.md`.

### Treating Kibo's `Refunded` State as Customer-Side Authoritative

Kibo's `Refunded` state means the OMS ledger has reconciled — not that the customer has been refunded. The actual money back to the customer is the operator's PSP refund call. These are two distinct operations; both must succeed. See `returns.md`.

### Conflating Cancellation with Refund Pre-Shipment

Cancellation pre-shipment and refund post-shipment both flow through the same Returns / RMA workflow with appropriate state. There is no separate "cancel" entity. See `returns.md`.

### Hard-Coding Disposition Outcomes

`Good`, `Bad / Damaged`, `Refurbished`, `Liquidation` dispositions drive different inventory effects. Hard-coding "always restock to On Hand" loses refurbished and damaged inventory buckets, and skips liquidation routing. Use the Disposition API. See `returns.md`.

## Shipping Anti-Patterns

### Re-Shopping Carrier Rates in OMS

For OMS-only deployments, the source platform did rate shopping at checkout. Kibo records the chosen `shippingMethodCode` and `shippingMethodName` on import. Re-shopping in Kibo can produce a different rate than the customer was shown — surprise upcharges or unexpected SLAs. See `shipping.md`.

### Storing Tracking on the Shipment Instead of the Package

Carrier tracking belongs on the Package. A single Shipment can have N Packages (sofa + frame + hardware kit), each with its own tracking number. Storing tracking at the Shipment level can't represent this. See `fulfillment.md`.

## Platform & Webhook Anti-Patterns

### Returning HTTP 4xx from a Webhook Receiver

Kibo expects HTTP 200 within 20 seconds. 24 consecutive hours of failures **auto-disables the subscription** (manual re-enable required). Returning 400 because "your order schema doesn't have this field yet" silently kills production event flow. Return 200 for malformed/unknown events (log internally); return 500 only for genuine processing failures. See `webhooks-events.md` (planned) / `fulfillment.md`.

### Trusting Webhook Payloads as Full State

Kibo webhook payloads are ID-only. The subscriber must call the API to fetch full entity state. Code that reads fields from the payload body (beyond `entityId`, `topic`, `timestamp`) is reading data that isn't there. See `fulfillment.md`.

### Synchronous Processing in the Webhook Handler

Slow handlers risk the 20-second ACK budget. Persist the raw event + ID durably, ACK 200 fast, process async. See `fulfillment.md`.

### No Alert for Disabled Webhooks

A disabled webhook silently stops production data flow until manually re-enabled. Treat "webhook disabled" status as P1. Poll the subscription status endpoint or wire up alerting. See `fulfillment.md`.

### Skipping HMAC / Signature Verification

Kibo's event-notification docs are silent on HMAC body signing — verify against your Dev Center whether signing is now offered for your instance. Until verified, standard mitigations apply: hard-to-guess endpoint paths, IP allowlist (Kibo publishes egress IPs per environment), and re-fetch via the credentialed API call (the trust boundary is the API call, not the payload). This is a notable contrast with Marketplacer, which is explicitly HMAC-signed. See `fulfillment.md`.

### Treating Kibo Connect Hub as a Rules Engine

Connect Hub is integration plumbing — pre-built connectors for WMS, carriers, etc. It is not a customization layer. Business rules belong in API Extensions (Arc.js) or in routing Scenarios. Code that tries to express business logic in Connect Hub configuration eventually hits the ceiling. See `order-intake.md`.

### Per-Request Auth Token Acquisition

The OAuth client-credentials flow returns a bearer token with a TTL. Acquiring a fresh token per API call reads secrets repeatedly, ignores the cache, and risks hitting the auth endpoint's rate limit. Cache the token until ~80% of its TTL. See `api-setup.md`.

### Hardcoding Tenant / Site IDs in Code

`x-vol-tenant` and `x-vol-site` should come from environment configuration. Hardcoding them in source means a sandbox deployment hits production data the first time someone forgets to override. See `api-setup.md`.

## Quick-Scan Review Checklist

During code review, scan for these:

- [ ] Any `POST /commerce/orders` call from an external source without `isImport: true` and `type: "Offline"`.
- [ ] Any `externalId` value that's not the source-platform's primary order ID (no concatenation, no encoding, no tracking number stuffed in).
- [ ] Any import order without a pre-post `externalId` idempotency check.
- [ ] Any computed order total that doesn't reconcile line subtotals + tax + shipping − discount to the penny.
- [ ] Any line item missing `fulfillmentMethod`.
- [ ] Any `productCode` resolution that uses the parent SKU instead of the variant SKU.
- [ ] Any webhook subscription that targets `order.*` for shipment lifecycle tracking.
- [ ] Any direct `PUT /commerce/shipments/{id}` status write instead of `PUT /tasks/{taskName}/completed`.
- [ ] Any code path that assumes exactly one Shipment per Order.
- [ ] Any "is this order done?" check using `order.status` alone instead of the rollups.
- [ ] Any production system without a `Customer Care` exception queue.
- [ ] Any BOPIS pickup-ready notification driven from order-level status rather than the shipment state / `shipment.partialpickupready`.
- [ ] Any hard-coded workflow name (`Default_STH_Process`, etc.) instead of per-instance lookup.
- [ ] Any inventory write path that mixes `Refresh` and `Adjust` against the same SKUs.
- [ ] Any `Refresh` call that processes items one at a time instead of batching.
- [ ] Any aggregate-inventory read treated as the source of truth for "available."
- [ ] Any storefront PDP reading inventory from the source-platform mirror instead of Kibo's Real-Time Inventory Service.
- [ ] Any return / RMA modeled as an order edit.
- [ ] Any "Kibo refunded the customer" assumption on OMS-only deployments (Kibo records the decision; the integration triggers the PSP).
- [ ] Any rate-shopping logic in the OMS path for orders imported from an external storefront.
- [ ] Any tracking number stored on the Shipment instead of the Package.
- [ ] Any webhook handler returning 4xx for unknown events.
- [ ] Any webhook handler reading fields from the payload body beyond `entityId` and `topic`.
- [ ] Any webhook handler doing synchronous processing inside the 20-second ACK window.
- [ ] Any production deployment without alerting on disabled-webhook state.
- [ ] Any per-request OAuth token fetch instead of cached token reuse.
- [ ] Any hard-coded `x-vol-tenant` / `x-vol-site` value in source.
- [ ] Any "Connect Hub as the rules engine" architecture diagram.
