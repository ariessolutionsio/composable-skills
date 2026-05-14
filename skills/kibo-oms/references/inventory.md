# Inventory & Locations

Kibo's inventory model has one rule that determines everything else: **inventory is location-scoped, and aggregate inventory is a derived view, never authoritative.** Treat the aggregate as the truth and you oversell at high-velocity SKUs. Pick the wrong inventory mutation operation — `Refresh` vs `Adjust` — and you silently revert state.

## Table of Contents
- [Location-Scoped Inventory](#location-scoped-inventory)
- [Quantity Types and Routing Signals](#quantity-types-and-routing-signals)
- [Available and ATP Formulas](#available-and-atp-formulas)
- [Granular Inventory Fields](#granular-inventory-fields)
- [Allocations and Reservations](#allocations-and-reservations)
- [Backorder vs Out-of-Stock vs Preorder](#backorder-vs-out-of-stock-vs-preorder)
- [Inventory APIs](#inventory-apis)
- [`Refresh` vs `Adjust` — The Silent-Revert Trap](#refresh-vs-adjust--the-silent-revert-trap)
- [Pending → Allocated Background Job](#pending--allocated-background-job)
- [Real-Time Inventory Service (RIS)](#real-time-inventory-service-ris)
- [Inventory Sync to External Storefronts](#inventory-sync-to-external-storefronts)
- [External WMS Integration](#external-wms-integration)
- [Anti-Patterns](#anti-patterns)
- [Checklist](#checklist)

## Location-Scoped Inventory

Inventory is tracked at **(UPC × Location)** granularity. A SKU has N records — one per location it lives at — and each record carries its own quantity types, attributes, and audit history.

```
Product code  | Location   | On Hand | Allocated | Available
─────────────────────────────────────────────────────────────
SKU-001       | DC01       |     200 |        40 |       160
SKU-001       | DC02       |     150 |        25 |       125
SKU-001       | STORE-042  |      12 |         2 |        10
SKU-001       | STORE-099  |       3 |         0 |         3

Aggregate (derived): SUM(Available) = 298
```

The aggregate (298) is not stored anywhere — it's computed by summing the location records. Any code that treats "aggregate Available" as a single authoritative number is computing a view, not reading a fact. Two consequences:

1. **Concurrent allocations at different locations can produce phantom sells against the aggregate.** Two orders for SKU-001, qty 5 each, arrive simultaneously. Routing dispatches one to STORE-042 (only 10 available) and one to STORE-099 (only 3 available). The second order's allocation against STORE-099 fails — but the aggregate said 298, so the customer-facing storefront promised it.
2. **A single SKU can be in-stock network-wide but out-of-stock for a specific fulfillment method.** Aggregate says 298 available; STORE-042 (the only BOPIS-eligible location near the customer) has 10. The customer's BOPIS request is against the 10, not the 298.

**This is the CRITICAL anti-pattern.** Sync aggregate-only inventory to a storefront and that storefront promises stock that doesn't exist at the locations that can fulfill the order. See [Inventory Sync to External Storefronts](#inventory-sync-to-external-storefronts) for the mitigation.

## Quantity Types and Routing Signals

Source: <https://docs.kibocommerce.com/help/inventory-quantity-types>

The documented quantity types at the (UPC × Location) level cover both stored physical-state values and computed analytical values:

| Type | Definition | Computed or stored |
|------|------------|---------------------|
| **On Hand** | Physical units at the location | Stored (source of truth from WMS / cycle count) |
| **Allocated** | Reserved by confirmed orders / accepted shipments | Stored (incremented by accept, decremented by ship / cancel) |
| **Pending** | Overallocated; waiting for replenishment to convert to Allocated | Stored (incremented by backorder accept) |
| **Safety Stock** | Withheld buffer not visible as Available | Stored |
| **Floor** | Minimum-on-hand target — replenishment trigger | Stored (used by replenishment policies, not enforced by routing) |
| **Future** | Confirmed incoming stock within a configurable future window, with a `deliveryDate` | Stored |
| **LTD** (Lifetime-to-Date) | Inventory age — days the oldest unit has been at the location | Computed (drives the LTD sort dimension in routing) |
| **Excess** | `Available − ExcessInventoryThreshold` (floored at 0) | Computed (drives the Excess sort dimension in routing) |
| **Excess Inventory Threshold** | The cutoff used to compute `Excess` | Stored (per-location config) |
| **Available** | The sellable number | Computed (see formula below) |

(The narrative concept "Future Available to Promise" — Available + Future — is sometimes referred to as ATP. Treat ATP as a computed view rather than a separately stored quantity type; it does not appear in the documented quantity-type list independently.)

### Available and ATP Formulas

```
Available = On Hand − Allocated − Pending [− Safety Stock]
ATP       = Available + Future
```

`ATP` (Available to Promise) includes Future inventory when the tenant has the Future-ATP setting on; otherwise `ATP == Available`. The `[− Safety Stock]` term is gated by the tenant's "include safety stock in Available" setting.

```
Example:
  On Hand        = 100
  Allocated      =  20  (orders accepted but not shipped)
  Pending        =   5  (backorder waiting for replenishment)
  Safety Stock   =  10
  Future         =  50  (incoming within the configured window)

  Available (safety stock excluded) = 100 − 20 − 5 − 10 = 65
  ATP (with Future)                  = 65 + 50 = 115
```

`Excess` and `LTD` are computed quantity types — the routing engine reads them per (UPC × Location) for use as Sort inputs (see `order-routing.md`).

## Granular Inventory Fields

Inventory records can carry deeper fields for FEFO (first-expired-first-out), lot tracking, serial tracking, and condition logic:

| Field | Use |
|-------|-----|
| `sku` | UPC or finer SKU (variant-level) |
| `lotCode` | Lot for FEFO / FIFO logic |
| `serialNumber` | Per-unit serial for serialized inventory |
| `condition` | `New`, `Refurbished`, `Damaged`, etc. — separate buckets |
| `deliveryDate` | For Future inventory, the expected receipt date |
| `binID` | Location-internal bin assignment |
| `externalID` | Reference to a WMS record |
| `tags` | Free-form labels for routing filters |

These feed the routing engine via inventory filters: "prefer earliest `lotCode`" for FEFO; "exclude `condition=Refurbished`" for new-only orders; "match on `tags=insulated`" for cold-chain orders.

## Allocations and Reservations

Two separate concepts:

| Concept | When | Behavior |
|---------|------|----------|
| **Reservation** | Cart-level hold (Kibo eCommerce only — `POST /commerce/reservation`) | Soft hold for a TTL; not validated against cart existence; useful for high-demand drops. **OMS-only deployments don't use this** — the source platform owns the cart and its own reservation logic. |
| **Allocation** | Order-accepted; shipment created | Hard reservation against `On Hand`. Decrements `Available` immediately. Released by cancel or return. |

In OMS-only deployments fronted by Shopify / SFCC, by the time Kibo receives the order, payment is captured and the order is committed. Inventory goes straight to Allocated; the cart-side Reservation step never happens.

**Allocations are created at order accept, released at:**

- Shipment cancel (`PUT /commerce/shipments/{id}/canceled`) — releases Allocated back to On Hand.
- Order cancel (`PUT /commerce/orders/{id}/canceled`) — releases all shipment allocations.
- Return close (after restock) — increments On Hand at the receiving location.

## Backorder vs Out-of-Stock vs Preorder

Three different states; conflating them produces wrong promise dates.

| State | Meaning | Order outcome |
|-------|---------|---------------|
| **Out-of-Stock** | `Available == 0` and no `Future` incoming | Order fails at routing — falls into the next Scenario or `Customer Care` |
| **Backorder** | `Available == 0` but the tenant has the `Pending` quantity type enabled | Order accepted; goes to `Pending`; converts to `Allocated` when replenishment lands |
| **Preorder** | `Available == 0` but `Future` inventory carries a known `deliveryDate` | Order accepted; promises shipment on the Future delivery date |

**The Backorder path is opt-in.** A tenant that hasn't enabled the Pending quantity type sees `Validate Stock` failure go straight to `Reassign`, not Backorder. Don't assume backorder is universally available.

```typescript
// Wrong — assumes Backorder is universally available
if (inventory.available === 0) {
  await api.post(`/commerce/shipments/${shipmentNumber}/backordered`);
}

// Recommended — check tenant config first, fall back to reject
const tenantConfig = await getTenantInventoryConfig();
if (tenantConfig.backorderEnabled && inventory.available === 0) {
  await api.post(`/commerce/shipments/${shipmentNumber}/backordered`);
} else if (inventory.available === 0) {
  await api.put(`/commerce/shipments/${shipmentNumber}/rejected`, { reasonCode: 'OOS' });
}
```

## Inventory APIs

| Endpoint | Use | Limit |
|----------|-----|-------|
| `POST /commerce/inventory/v5/inventory/refresh` | **Set** absolute quantities — full overwrite per location | 12,000 items / call (Kibo recommends batches of 3,000) |
| `POST /commerce/inventory/v5/inventory/adjust` | **Delta** quantity changes (+5, −2) | 1,000 items / call |
| `POST /commerce/realtime-inventory/v5/inventory` (REST) | Real-time read for storefront PDP/PLP | — |
| `/api/commerce/realtime-inventory/graphql` | GraphQL read endpoint | — |
| `POST /commerce/reservation` | Soft-reserve for cart (Kibo eCommerce only) | — |

Source: <https://docs.kibocommerce.com/reference/post_commerce-inventory-v5-inventory-refresh>

The `Refresh` payload shape (verify against your tenant's OpenAPI spec — the exact field list has evolved):

```json
{
  "items": [
    {
      "sku": "SKU-001",
      "locationCode": "DC01",
      "quantity": 200,
      "safetyStock": 10,
      "floor": 20,
      "lotCode": "L2026-05-13",
      "binID": "A-12-3"
    }
  ]
}
```

Documented `RefreshItem` fields include `sku`, `quantity`, `safetyStock`, `floor`. **Whether `onHand`, `allocated`, and `pending` are direct fields on `Refresh` (vs derived from `quantity`) is not explicitly listed in the schema surface — verify against the live OpenAPI spec.** The `Adjust` API may be the only path for some of those quantity types.

## `Refresh` vs `Adjust` — The Silent-Revert Trap

This is the single most expensive inventory bug in Kibo OMS integrations. The two operations have fundamentally different contracts:

| Operation | Contract | Effect of missing items |
|-----------|----------|-------------------------|
| **`Refresh`** | Full overwrite per location | **A SKU absent from the call has its quantity wiped to 0** |
| **`Adjust`** | Delta per SKU | A SKU absent from the call is untouched |

```
Starting state at DC01:
  SKU-A:  200
  SKU-B:  150
  SKU-C:   80

REFRESH call with only {SKU-A: 210}:
  SKU-A:  210
  SKU-B:    0  ← wiped to 0
  SKU-C:    0  ← wiped to 0

ADJUST call with only {SKU-A: +10}:
  SKU-A:  210
  SKU-B:  150  (unchanged)
  SKU-C:   80  (unchanged)
```

Refresh is meant for **full periodic re-syncs** (nightly snapshot from WMS — every SKU at every location is in the payload). Adjust is meant for **real-time deltas** (every WMS movement event — one SKU, one location, one delta).

### The Silent-Revert Race

Mixing the two without ordering produces silent state reversion:

```
T=0   WMS snapshot taken; SKU-A onHand = 200
T=1   WMS records a pick: SKU-A −5  → onHand should be 195
T=2   Adjust call: {SKU-A: −5}   → Kibo onHand = 195  ✓
T=3   Refresh call posts the T=0 snapshot: {SKU-A: 200}
T=4   Kibo onHand = 200  ← the Adjust at T=2 is silently reverted
```

The Refresh isn't wrong — it's expressing the state at T=0. But because it landed after the Adjust, it overwrites the more recent delta. The result is an undetectable inventory error that surfaces as oversells.

### The Fix: Pick One Per Integration Path

```typescript
// Wrong — same data path uses both, no ordering guarantee
async function syncInventory(skus: Sku[]) {
  for (const sku of skus) {
    if (sku.changeType === 'snapshot') await refresh([sku]);   // full
    else                                await adjust([sku]);   // delta
  }
}

// Recommended — separate paths, single direction each
async function nightlySnapshot(allSkus: Sku[]) {
  // ALL skus at ALL locations in the payload; chunk to 3,000 each
  for (const chunk of batches(allSkus, 3000)) {
    await refresh(chunk);
  }
}

async function realTimeDelta(deltaEvents: DeltaEvent[]) {
  // Only the events that happened since last call; chunk to 1,000
  for (const chunk of batches(deltaEvents, 1000)) {
    await adjust(chunk);
  }
}

// Crucially: nightlySnapshot and realTimeDelta share NO writer paths,
// and the nightly job runs while deltas are paused (or against a
// timestamp-fenced snapshot).
```

### Refresh Performance Trap

Refresh is queued and processed serially. Calling Refresh per-item in a loop (10k items in 10k calls) produces hours of latency as the queue backs up. **Always batch up to 3,000 items per call** — the documented sweet spot per Kibo's recommendation.

## Pending → Allocated Background Job

Kibo runs a background job approximately every **30 minutes** that converts `Pending` quantities (backordered) to `Allocated` when replenishment lands.

```
T=0     Backorder accepted: Pending += 5
T=15m   WMS receives stock: On Hand += 20 (via Adjust)
T=15m   At this instant: On Hand=20, Pending=5, Allocated=0, Available=15
T=30m   Background job runs: Pending → Allocated for backordered shipments
T=30m   Now: On Hand=20, Pending=0, Allocated=5, Available=15
```

**Implication: claims of "real-time" backorder release are wrong.** Even on optimal traffic, a backordered shipment moves at the 30-minute job cadence. A storefront UI promising "your backorder will ship the moment stock lands" misleads customers.

## Real-Time Inventory Service (RIS)

A dedicated read service for storefront PDP / PLP. Standard reads:

| Operation | Returns |
|-----------|---------|
| **Get Product Site Availability** | One product, all locations |
| **Get Group Site Availability** | Many products, all locations |
| **Get Product Availability at Locations** | One product, specified locations |
| **Get Group Available Pickup Locations** | Which stores can fulfill pickup for the given products |

RIS responses include per-fulfillment-type processing-time estimates:

| Field | Meaning |
|-------|---------|
| `bopisProcessingTimeHours` | Pickup-ready window |
| `sthProcessingTimeHours` | Ship-to-home processing |
| `transferProcessingTimeHours` | Internal transfer time |
| `receiveProcessingTimeHours` | Receiving / putaway time |

These drive PDP delivery-promise messaging — they're computed from location SLA settings + carrier hand-off cutoffs. Use them rather than hand-rolling delivery promises in the storefront.

URL: <https://docs.kibocommerce.com/help/real-time-inventory>

## Inventory Sync to External Storefronts

Direction: Kibo → source platform, real-time per inventory change. **Eventual, not synchronous.**

```
Kibo inventory.changed event (per UPC × Location)
   └─► integration listener
        ├─► aggregate to network-wide ATP per UPC
        └─► PUT Shopify InventoryLevel / SFCC Inventory
```

The source platform usually has one inventory bucket per SKU (or per location, if it supports multi-location — but most external platforms don't model locations with the depth Kibo does). Three translation strategies:

| Strategy | Pros | Cons |
|----------|------|------|
| **Aggregate sum** — total Available across all Kibo locations → one number | Simple | Loses BOPIS-eligibility nuance; oversells possible at fulfillment-method boundaries |
| **Buffer** — subtract a safety percentage from the published number | Mitigates the timing race | Tunes against shrinkage rather than fixes it |
| **Source-side multi-location** — mirror Kibo locations 1:1 (Shopify Locations, SFCC inventory lists) | Closer fidelity to OMS truth | Requires real-time per-location updates and stable location naming on both sides |

**Critical: a UI expecting real-time inventory shows stale numbers.** The propagation chain Kibo event → listener → source-platform API → CDN cache → browser typically lands at seconds-to-minutes of latency. Under traffic bursts (flash sale, product drop), the lag stretches.

**Mitigation for PDPs that need accurate live availability:** query the Kibo RIS directly from the storefront rather than relying on the source-platform mirror. The mirror is fine for PLP listings and category pages; the PDP "add to cart" step is where the freshness matters.

```typescript
// Storefront PDP — read live from Kibo RIS, not from the source-platform mirror
const ris = await fetch(`${kiboHost}/api/commerce/realtime-inventory/graphql`, {
  method: 'POST',
  headers: { 'x-vol-tenant': tenantId, 'x-vol-site': siteId, /* ... */ },
  body: JSON.stringify({ query: GET_PRODUCT_AVAILABILITY_AT_LOCATIONS, variables: { productCode, locationCodes } }),
});
```

## External WMS Integration

Real-time WMS → Kibo flow (recommended):

```
WMS event ──► event queue ──► transform ──► Kibo Adjust API
            (pick, putaway,                  (delta per location)
             cycle count,
             receive)
```

Periodic reconciliation:

```
Nightly:  WMS snapshot ──► Kibo Refresh API (full overwrite per location)
```

**The Refresh and Adjust paths must not interleave.** Run the nightly Refresh during a low-traffic window with deltas paused (or against a timestamp-fenced WMS snapshot taken before the cutover).

Kibo Connect Hub lists 80+ WMS / 3PL pre-built connectors — Manhattan, SAP EWM, NetSuite WMS, HighJump/Körber are documented as common. For custom WMS, the integrator builds the event listener + transform.

URL: <https://kibocommerce.com/platform/connect-hub/>

## Anti-Patterns

### Treating Aggregate as Authoritative

**The CRITICAL anti-pattern.** Aggregate `Available` is a derived view; the per-location records are the truth. Code that sums and stores aggregate as a single number oversells at the fulfillment-method boundary (BOPIS, ship-from-store).

```typescript
// Wrong — single number, no location nuance
const productAvailable = inventoryRecords.reduce((s, r) => s + r.available, 0);
publishToStorefront(sku, productAvailable);

// Recommended — preserve location, let the source platform decide aggregation strategy
publishToStorefront(sku, inventoryRecords);  // array of {location, available}
```

### Mixing `Refresh` and `Adjust` Without Ordering

A Refresh that lands after an Adjust silently reverts the delta. See [`Refresh` vs `Adjust` — The Silent-Revert Trap](#refresh-vs-adjust--the-silent-revert-trap). Pick one mode per integration path.

### Calling `Refresh` Per-Item in a Loop

Refresh is queued; 10k items in 10k calls = hours of latency. **Batch up to 3,000 per call** (Kibo's recommendation).

### Claiming Real-Time Backorder Release

The Pending → Allocated job runs ~every 30 minutes. UI copy like "your backorder ships the moment stock lands" misleads customers — it ships up to 30 minutes after stock lands.

### Reading Source-Platform Inventory From the Storefront PDP

Kibo → source-platform inventory sync is eventual. PDPs needing accurate availability should read Kibo's RIS directly, not the source platform's mirror.

### Mixing Cart Reservation and OMS-Only Mode

`POST /commerce/reservation` is Kibo's cart-side reservation API. OMS-only deployments fronted by Shopify / SFCC don't use it — the source platform owns the cart. Calling it from an OMS-only integration creates phantom holds.

### Trusting `Floor` to Trigger Replenishment Automatically

`Floor` is analytical — Kibo doesn't enforce or trigger anything when On Hand drops below Floor. Replenishment workflow is the WMS / ERP's job; Kibo just reports the gap.

### Ignoring Safety Stock Toggle Between Tenants

The "include safety stock in Available" setting varies per tenant. Code that hard-codes the formula `Available = OnHand − Allocated − Pending − SafetyStock` produces different numbers than Kibo on tenants where the toggle is off.

### Confusing Backorder With Out-of-Stock

Backorder requires the Pending quantity type to be enabled on the tenant. On tenants where it's off, the same scenario produces a hard Reassign or `Customer Care` outcome, not a Backorder. Check tenant config before posting `/backordered`.

### Storing Inventory by Parent SKU When Variants Exist

Kibo expects inventory at variant-level `productCode`, not at the parent SKU. Importing inventory at the parent collapses N variants' stock into one record — and Kibo can't dispatch routing decisions against it.

## Checklist

Before shipping inventory code:

- [ ] No code path treats aggregate `Available` as authoritative; per-location records are preserved through the integration.
- [ ] `Refresh` and `Adjust` are on separate code paths; they don't interleave in time.
- [ ] `Refresh` calls batch to ~3,000 items each (Kibo's recommendation; max 12,000).
- [ ] `Adjust` calls batch to ≤ 1,000 items each.
- [ ] The nightly Refresh runs in a fenced window with deltas paused (or against a timestamp-snapshotted WMS state).
- [ ] PDPs needing real-time availability read Kibo's RIS directly, not the source-platform mirror.
- [ ] Storefront copy doesn't claim real-time backorder release (the Pending → Allocated job runs ~every 30 min).
- [ ] Tenant's "include safety stock" and "Pending enabled" settings are looked up at integration time, not hard-coded.
- [ ] Backorder code paths fall back to Reject when Pending is disabled on the tenant.
- [ ] Inventory is stored at variant-level `productCode`, not at parent SKU.
- [ ] Lat/long / `lotCode` / `serialNumber` / `condition` fields populated when the routing engine filters or sorts against them.
- [ ] Reservation API (`POST /commerce/reservation`) is **not** called from OMS-only integrations.
- [ ] WMS event listener writes via `Adjust`; nightly reconciliation via `Refresh` — these paths share no writer.
- [ ] Source-platform inventory sync uses a strategy explicit about aggregation (sum, buffer, or 1:1 location mirror) — not a silent default.
