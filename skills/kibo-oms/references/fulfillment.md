# Fulfillment Workflows

Kibo's OMS has one structural quirk that determines almost every integration decision: **the Shipment is the unit of fulfillment work, not the Order**. One Order produces N Shipments (one per fulfillment location × fulfillment-method), each running an independent BPMN workflow with its own task queue. Get this wrong and the integration appears to work in single-shipment test scenarios then silently breaks when a real mixed-mode cart lands.

## Table of Contents
- [Shipment-as-Unit-of-Work](#shipment-as-unit-of-work)
- [Order Lifecycle](#order-lifecycle)
- [Rollup Statuses](#rollup-statuses)
- [The Shipment Workflow Catalog](#the-shipment-workflow-catalog)
- [STH (Ship-to-Home) State Diagram](#sth-ship-to-home-state-diagram)
- [BOPIS / Curbside State Diagram](#bopis--curbside-state-diagram)
- [Transfer Shipments](#transfer-shipments)
- [Partial Shipments](#partial-shipments)
- [Mixed-Mode Orders](#mixed-mode-orders)
- [Backorder](#backorder)
- [Fulfillment API Surface](#fulfillment-api-surface)
- [Shipment vs Package](#shipment-vs-package)
- [Tasks vs Status Writes](#tasks-vs-status-writes)
- [The Order Routing Explain Agent](#the-q1-2026-order-routing-explain-agent)
- [Webhook Events to Subscribe](#webhook-events-to-subscribe)
- [Anti-Patterns](#anti-patterns)
- [Checklist](#checklist)

## Shipment-as-Unit-of-Work

The Order in Kibo is the customer-facing financial record. The Shipment is the operational record — what gets picked, packed, labeled, transferred, and handed off. Every webhook subscription, every reporting query, and every operational UI rotates around Shipments.

**Concrete consequences:**

- Order-level events (`order.opened`, `order.fulfilled`) fire once per order and carry only the ID. They do not stream the lifecycle.
- A two-location order fires N events at each shipment state change, not one event on the order.
- Status rollups on the Order are derived from the Shipments — never written directly.
- A Customer Care escalation on one shipment puts the **whole order** in `Customer Care` rollup, even if the other shipment is healthy. The escalation must be cleared on the shipment.
- "Has this order shipped?" is `all_shipments.state == Complete` — not `order.status == Completed`.

**Anti-pattern:**

```typescript
// Wrong — order.fulfilled fires once with only the ID; you never see partial shipments,
// per-location label generation, or per-shipment exceptions.
webhook.subscribe(['order.opened', 'order.fulfilled']);
```

**Recommended:**

```typescript
// Subscribe to shipment events as the primary lifecycle stream; aggregate to order
// in the consuming system if a customer-facing order view needs it.
webhook.subscribe([
  'shipment.statuschanged',
  'shipment.workflowstatechanged',
  'shipment.adjusted',
  'shipment.itemscanceled',
  'shipment.partialpickupready',
  'return.opened',
  'return.authorized',  // fires when label is issued / item in flight
  'return.closed',
]);
```

## Order Lifecycle

Source: <https://docs.kibocommerce.com/help/order-statuses>

```
┌─────────┐   submit    ┌───────────┐   validate    ┌───────────┐
│ Pending │ ──────────► │ Submitted │ ────────────► │ Validated │
└─────────┘             └───────────┘               └───────────┘
     │ 2-day timeout         │ validation fail            │
     ▼                       ▼                            ▼
┌───────────┐         ┌────────────────┐           ┌──────────┐
│ Abandoned │         │ Pending Review │           │ Accepted │
└───────────┘         └────────────────┘           └──────────┘
                                                          │ first action
                                                          ▼
                                                   ┌────────────┐
                                                   │ Processing │
                                                   └────────────┘
                                                          │ all fulfilled & paid
                                                          ▼
                                                   ┌───────────┐
                                                   │ Completed │
                                                   └───────────┘
```

Terminal-but-reversible: `Cancelled`, `Errored`, `Abandoned`. `Completed` is reversible via the **Reopen** action (returns to `Processing` — useful for late returns or address corrections).

**Imported orders typically land at `Validated` or `Accepted` directly**, skipping `Pending`/`Submitted` because the source platform already did the checkout. Kibo doesn't expose a knob to land them in a non-default status; you control this by how completely the import payload satisfies validation.

## Rollup Statuses

The Order's effective state is the cross-product of three rollups:

| Rollup | Values |
|--------|--------|
| **Payment** | `Unpaid`, `Pending`, `Paid`, `Pending And Errored`, `Paid And Errored`, `Errored` |
| **Fulfillment** | `Not Fulfilled`, `Partially Fulfilled`, `Fulfilled`, `Customer Care` |
| **Return** | `None`, `In Progress`, `Order Partially Returned`, `Order Fully Returned` |

`Completed` requires `Fulfillment = Fulfilled` AND `Payment ∈ {Paid, Paid And Errored}`. The `Customer Care` fulfillment rollup is the "human needs to intervene" trapdoor — any shipment that hits a manual hold puts the whole order there until the shipment-level state clears.

**Anti-pattern:**

```typescript
// Wrong — using order.status alone misses the "stuck in Customer Care" case
// and counts paid-but-unfulfilled orders as closed.
const isClosed = order.status === 'Completed';
```

**Recommended:**

```typescript
const isClosed =
  order.fulfillmentStatus === 'Fulfilled' &&
  ['Paid', 'Paid And Errored'].includes(order.paymentStatus);
const needsAttention = order.fulfillmentStatus === 'Customer Care';
```

## The Shipment Workflow Catalog

Each Shipment runs a BPMN workflow chosen by `fulfillmentType`. Workflows live in the open-source repo <https://github.com/KiboSoftware/kibo-fulfillment-workflows> as BPMN files deployed into a jBPM Business Process Management Suite. The default set:

| Workflow name | BPMN file | Use |
|---------------|-----------|-----|
| `Default_STH_Process` | `Default_STH_Process.bpmn` | Ship-to-home from a fulfillment location |
| `FulfillmentProcess-STH` | `FulfillmentProcess-STH.bpmn` | Newer STH variant |
| `FulfillmentProcess-BOPIS` | `FulfillmentProcess-BOPIS.bpmn` | Buy online, pickup in store |
| `FulfillmentProcess-BOPIS_Curbside` | `FulfillmentProcess-BOPIS_Curbside.bpmn` | Curbside pickup variant of BOPIS |
| `FulfillmentProcess-Curbside` | `FulfillmentProcess-Curbside.bpmn` | Curbside-only flow |
| `FulfillmentProcess-Transfer` | `FulfillmentProcess-Transfer.bpmn` | Inter-location transfer (child of STH/BOPIS) |
| `FulfillmentProcess-Digital` | `FulfillmentProcess-Digital.bpmn` | Digital goods (no physical ship) |
| `Default_Delivery_Process` | `Default_Delivery_Process.bpmn` | Local delivery (own fleet or 3rd-party) |
| `Default_Enhanced_Delivery_Process` | `Default_Enhanced_Delivery_Process.bpmn` | Delivery with assembly/install |
| `Default_Dropship_Process` | `Default_Dropship_Process.bpmn` | Vendor-fulfilled dropship |
| `Default_FXCB_Process` | `Default_FXCB_Process.bpmn` | Purpose unknown — verify against your instance (possibly "Fulfilled by Cross-Border" or a customer-specific custom workflow) |

This **is** the OMS engine — these BPMN processes drive the Fulfiller UI screens and the task-queue API. Customers commonly fork these workflows when their physical operation diverges from the defaults; the repo includes `TLG_Custom_*` and `AFG_Custom_*` variants as examples.

**Customizing workflows: fork the BPMN, do not bypass tasks.** The BPMN workflow enforces task order, side-effects, and audit hooks. Skipping tasks via direct status writes (`PUT /shipments/{id}` with a hand-crafted state) bypasses validation and silently misaligns inventory/payment state. If a custom step is needed, fork the workflow.

## STH (Ship-to-Home) State Diagram

Source: <https://docs.kibocommerce.com/help/ship-to-home>

```
                          ┌──────────────────┐
                          │ Accept Shipment  │
                          └──────────────────┘
                                   │ yes
                                   ▼
                          ┌──────────────────┐
                          │  Validate Stock  │◄─┐
                          └──────────────────┘  │ partial w/ consolidation
                                   │            │
                ┌──────────────────┼──────────────────┐
                │ in stock         │ partial         │ no stock
                ▼                  ▼                  ▼
   ┌──────────────────┐    ┌──────────────────┐  ┌───────────┐
   │Print Packing Slip│    │ Waiting for      │  │ Reassign  │──┐
   └──────────────────┘    │ Transfer         │  └───────────┘  │
                │           └──────────────────┘                │ goes back to
                ▼                  │ transfer received          │ Order Routing
   ┌──────────────────────┐        ▼                            │
   │ Prepare for Shipment │ ◄─── (consolidated)                 │
   └──────────────────────┘                                     │
                │                                               │
                ▼                                               ▼
            ┌──────────┐                                  (new shipment)
            │ Complete │
            └──────────┘
```

Signal names: `Accept`, `Validate Stock`, `Pack`, `Print Packing Slip`, `Print Shipping Label`, `Complete`. Each is a **task** on the shipment, completed via `PUT /commerce/shipments/{shipmentNumber}/tasks/{taskName}/completed`. Tasks can be reverted (auditing-friendly) or skipped (when the workflow permits).

## BOPIS / Curbside State Diagram

```
┌──────────────────┐  ┌─────────────────┐  ┌──────────────────┐
│ Accept Shipment  │─►│ Print Pick Sheet│─►│  Validate Stock  │
└──────────────────┘  └─────────────────┘  └──────────────────┘
                                                    │
                          ┌─────────────────────────┼────────────┐
                          │ in stock                │ partial   │ no stock
                          ▼                          ▼           ▼
                ┌───────────────────┐    ┌──────────────────┐  reassign
                │ Customer Pickup   │    │ Transfer needed  │
                │ (Awaiting         │    │ (Waiting for ...│
                │  Collection)      │    │                 │
                └───────────────────┘    └──────────────────┘
                          │                          │
                          ▼                          ▼
                 ┌────────────┐               (back to Pickup
                 │  Complete  │                after transfer)
                 │ (Collected)│
                 └────────────┘
```

Curbside is identical to BOPIS until the pickup step (curbside hand-off vs in-store hand-off). Both use the same `customerPickup` task gate.

**BOPIS-specific lifecycle states the integration must surface:**
- `Awaiting Collection` — picked, packed, ready for the customer.
- `Collected` — handed off; shipment closes.

The transition from `Awaiting Collection` → `Collected` is triggered by store staff in the Fulfiller UI (or the corresponding API task). The customer notification ("Your order is ready for pickup") should fire on `shipment.partialpickupready` or the workflow state transition into `Awaiting Collection` — **not** on order-level status, which doesn't model pickup readiness.

## Transfer Shipments

When `Validate Stock` returns `PARTIAL_STOCK` and STH-consolidation is enabled, Kibo creates a **child Transfer shipment** for the missing-from-this-location items, sourced from another location via Order Routing. The parent shipment enters `Waiting for Transfer`. The transfer shipment runs `FulfillmentProcess-Transfer` and reaches `Validate Transfer Stock` on the receiving end; once acknowledged, the parent resumes at `Print Packing Slip`.

Key tasks on the parent during waiting: `Receive Transfer`. Tasks on the child: standard pick-pack-ship targeted at the parent location instead of customer address.

Without consolidation enabled, partial stock causes a **split** instead: the original shipment continues with what's in stock; a brand-new shipment for the missing items is created and re-routed.

## Partial Shipments

Partial shipments are first-class. Multiple Shipments per Order, summed quantities ≤ ordered:

```
sum(shipments[].items[lineItemX].quantity) ≤ order.items[lineItemX].quantity
```

Useful for:
- Backorder fulfillment that ships in waves.
- Multi-package orders that physically split.
- Multi-warehouse fulfillment where items dispatch on different days.
- Transfer-consolidation followed by a single ship-out.

**Anti-pattern:** modeling the source-platform-side fulfillment with a hard "one shipment per order" constraint. Build for N from day one. Shopify, SFCC, and most modern OMS schemas all natively support multiple fulfillments per order — use them.

## Mixed-Mode Orders

A single Order can mix `Ship` and `Pickup` lines:

```
Order
 ├─ Line A: Ship (qty 1)       → Shipment 1 (STH, location DC01)
 ├─ Line B: Ship (qty 2)       → Shipment 1 (same — same location/method)
 └─ Line C: Pickup (qty 1)     → Shipment 2 (BOPIS, location STORE-042)
```

The Order Routing engine splits on `(location × fulfillmentMethod)`. Each resulting shipment runs its own workflow independently — Shipment 1's STH state machine and Shipment 2's BOPIS state machine progress separately, fire separate webhooks, and complete on different timelines.

**Anti-pattern: representing a mixed-mode order as a single fulfillment unit on the source-platform side.** Shopify and SFCC both model multiple fulfillments per order; Kibo's shipment split should be mirrored to multiple source-platform fulfillments, not collapsed.

## Backorder

`POST /commerce/shipments/{shipmentNumber}/backordered` (and the item-level variant) puts a shipment or line into backorder state. The shipment doesn't move forward until inventory becomes available; on inventory replenishment, the pending → allocated conversion (Kibo's background job, every 30 min) releases the backorder.

Backorder is opt-in via the `Pending` quantity type (see `inventory.md` in the OMS skill). Disabled by default — if a tenant hasn't enabled it, a `Validate Stock` failure goes straight to `Reassign`, not Backorder.

## Fulfillment API Surface

Sources: <https://docs.kibocommerce.com/help/fulfillment-api-overview>, <https://docs.kibocommerce.com/developer-guides/shipment-packages>

| Endpoint | Purpose |
|----------|---------|
| `GET /commerce/shipments?filter=orderId=={orderId}` | List shipments for an order |
| `GET /commerce/shipments/{shipmentNumber}` | Get one shipment + workflowState |
| `GET /commerce/shipments/{shipmentNumber}/tasks` | List current tasks + active task |
| `PUT /commerce/shipments/{shipmentNumber}/tasks/{taskName}/completed` | Advance the workflow |
| `PUT /commerce/shipments/{shipmentNumber}/fulfilled` | Mark fulfilled (terminal) |
| `POST /commerce/shipments/{shipmentNumber}/packages` | Create a package (box) |
| `PUT /commerce/shipments/{shipmentNumber}/packages/{packageId}` | Update package dims/contents (pre-label) |
| `DELETE /commerce/shipments/{shipmentNumber}/packages/{packageId}` | Delete package (pre-label only) |
| `POST /commerce/shipments/{shipmentNumber}/backordered` | Backorder shipment/items |
| `PUT /commerce/shipments/{shipmentNumber}/canceled` | Cancel shipment |
| `PUT /commerce/shipments/{shipmentNumber}/reassigned` | Manual reassign to another location |
| `PUT /commerce/shipments/{shipmentNumber}/rejected` | Reject (returns to routing) |
| `PUT /commerce/shipments/{shipmentNumber}/transferred` | Mark as transferred |
| `PUT /commerce/shipments/{shipmentNumber}/received` | Receive a transfer |

## Shipment vs Package

A **Shipment** is the logical unit (group of items to one destination). A **Package** is one physical box.

- One Shipment can have N Packages.
- Each Package has its own weight, dimensions, and tracking number.
- Packages can only be created when the shipment is in `Ready` status.
- Once a carrier label is generated against a Package, it becomes immutable.

```typescript
// One shipment, three boxes (a sofa shipping in pieces)
const shipment = { shipmentNumber: 12345, items: [/* sofa, frame, hardware */] };
const packages = [
  { packageId: 'P1', items: ['sofa-cushions'], weight: 12, trackingNumber: '1Z...' },
  { packageId: 'P2', items: ['sofa-frame'],    weight: 65, trackingNumber: '1Z...' },
  { packageId: 'P3', items: ['hardware-kit'],  weight: 3,  trackingNumber: '1Z...' },
];
```

Carrier tracking belongs on the Package, not the Shipment, and not on the order's `externalId` (see `order-intake.md`).

## Tasks vs Status Writes

The BPMN workflow enforces task order, side-effects, and audit hooks. The correct way to advance a shipment is via the task API:

```typescript
// Recommended — runs through the BPMN engine
await api.put(`/commerce/shipments/${shipmentNumber}/tasks/${taskName}/completed`);
```

**Anti-pattern:**

```typescript
// Wrong — direct status write bypasses the BPMN side-effects (audit log,
// inventory deallocation, package immutability, downstream signals).
await api.put(`/commerce/shipments/${shipmentNumber}`, { status: 'Completed' });
```

Tasks can be **reverted** when the workflow permits (audit-friendly: a packer marks a shipment Packed, then realizes a SKU mismatch and reverts to re-pick). Tasks can also be **skipped** when the workflow permits. Both operations are first-class API calls; don't hand-roll equivalents.

## The Order Routing Explain Agent

Part of Kibo's broader Agentic Commerce suite (recently released). Operations can ask in natural language "why was order X routed to location Y?" and the agent surfaces:

- Which locations were considered.
- Which Filters eliminated each one.
- Which Sort rule selected the winner.
- A plain-language explanation.

**This is an observability / audit tool, not a new routing engine.** It does not change routing decisions — it explains them. The same engine still picks; the agent translates the trace into prose. Investigation drops from "hours pulling logs" to seconds.

Code that integrates with this agent should treat it as a UX surface for ops teams, not a decision input — don't build automation that loops back through the Explain Agent's output to second-guess routing. The Routing API is the source of truth for "which location"; the Explain Agent is the source of truth for "why."

URL: <https://kibocommerce.com/platform/agentic-commerce/>

## Webhook Events to Subscribe

Source: <https://docs.kibocommerce.com/help/event-notifications-overview>

| Topic group | Use these for |
|-------------|---------------|
| `shipment.statuschanged`, `shipment.workflowstatechanged` | Primary lifecycle stream — every state transition |
| `shipment.adjusted` | Line-quantity adjustments on the shipment |
| `shipment.itemscanceled`, `shipment.itemsdeclined`, `shipment.itemsrejected` | Partial-cancel / decline signaling |
| `shipment.partialpickupready` | BOPIS pickup notification trigger |
| `return.opened`, `return.closed`, `return.authorized`, `return.cancelled` | Reverse logistics lifecycle |
| `payment.captured`, `payment.credited`, `payment.refunded` | Money-movement signals |
| `inventory.cartitemallocated`, `inventory.cartpendingitemcreated` | Cart-side inventory holds (bundled mode only) |
| `order.opened`, `order.fulfilled`, `order.cancelled` | Order-level rollup signals only — **not** the primary lifecycle |

`order.imported` fires specifically for `isImport=true` orders — useful for "post-import enrichment" workflows.

**Payloads are ID-only.** The subscriber calls the API to fetch full entity state. This is unlike Marketplacer's caller-shaped queries — closer to Stripe-style "ping with ID, GET to enrich." The receiver should always re-fetch via the credentialed API call rather than trusting the payload body.

**Reliability semantics:**
- Kibo expects HTTP 200 within 20 seconds.
- Retries: 5 min → 1 hr → 6 hr → 24 hr → final 24 hr — over 14 days.
- **24 consecutive hours of failures auto-disables the subscription.**

Return 200 for malformed/unknown events (log internally); return 500 only for genuine processing failures (gets retries). See `anti-patterns.md` for the failure modes.

## Anti-Patterns

### Subscribing Only to `order.*` Events

You see orders arrive but never see them ship. Order events are once-per-order ID-only pings; the shipment lifecycle never appears. Subscribe to `shipment.*` as the primary lifecycle stream.

### Hand-Coding Status Transitions Instead of Using the Task API

`PUT /commerce/shipments/{id}` with a direct status write bypasses the BPMN engine's audit log, inventory deallocation, and downstream task hooks. Use `PUT /commerce/shipments/{shipmentNumber}/tasks/{taskName}/completed`.

### One-Shipment-Per-Order Assumption

A mixed BOPIS + ship order splits into multiple shipments. Code that creates exactly one Shopify Fulfillment per Kibo Order can't represent the pickup shipment separately from the ship-to-home shipment.

### Trusting the Order `status` Alone

"Is this order done?" requires checking the fulfillment rollup AND the payment rollup together. `order.status == Completed` alone misses the Customer Care escalation case and the rare paid-but-unfulfilled state.

### Hard-Coding Workflow Names

`Default_STH_Process` exists on most tenants but customers fork freely (`TLG_Custom_STH`, etc.). Look up the active workflow per `fulfillmentType` on the location/site config rather than assuming the default name.

### Polling for Shipment Status

Polling burns rate limit and lags real state. Kibo's webhook reliability is good enough to rely on; subscribe to `shipment.statuschanged` and re-fetch on the event ID.

### Building a Custom Dropship Workflow

`Default_Dropship_Process` integrates with the Vendor Portal (Order Acknowledgement + ASN). Bespoke workflows lose the vendor-side UX; the portal expects the default workflow's task names.

### Mixing Customer-Notification Triggers Across Order and Shipment Events

"Your order is ready for pickup" must fire on the shipment's `Awaiting Collection` state, not the order-level status. Driving notifications from order events produces stale or wrong messages on mixed-mode orders.

### Treating `Customer Care` as Just a Display State

`Customer Care` rollup means a human needs to intervene on a shipment. Production dashboards must surface it as an exception queue. Orders sit there silently otherwise — Kibo does not auto-resolve.

## Checklist

Before shipping fulfillment code:

- [ ] Webhook subscription targets `shipment.*` as the primary lifecycle stream.
- [ ] Order-level events used only for once-per-order rollups, not for tracking.
- [ ] Status transitions go through `PUT /tasks/{taskName}/completed`, not raw status writes.
- [ ] OMS / source-platform model supports N Shipments per Order from day one.
- [ ] Mixed-mode (Ship + Pickup) orders represented as multiple source-platform fulfillments.
- [ ] BOPIS pickup-ready notification fires on `shipment.partialpickupready` or the `Awaiting Collection` workflow state.
- [ ] Partial shipments first-class — `sum(shipped[lineX]) ≤ ordered[lineX]`.
- [ ] Tracking is on the Package, not the Shipment and not the Order.
- [ ] Workflow-name lookup is per-instance config, not hard-coded.
- [ ] `Customer Care` rollup surfaced as an ops exception queue.
- [ ] Webhook receiver returns 200 for unknown events, fetches full entity via API.
- [ ] Order Routing Explain Agent treated as observability, not as a decision input.
