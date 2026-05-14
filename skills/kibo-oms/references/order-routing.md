# Order Routing

Kibo's order routing engine is a four-level decision pipeline — **Strategy → Scenario → Filter → Sort → After-Action** — that decides which location (or locations) fulfill each line of an order. Get the configuration right at config time and the integration never needs to override; get it wrong and operators end up reassigning shipments by hand all day.

## Table of Contents
- [The Routing Hierarchy](#the-routing-hierarchy)
- [What Each Level Does](#what-each-level-does)
- [Location Capabilities as Filter Inputs](#location-capabilities-as-filter-inputs)
- [Filter Categories](#filter-categories)
- [Sort Rules](#sort-rules)
- [Capacity Constraints](#capacity-constraints)
- [Routing Patterns: Inventory vs Distance vs Cost](#routing-patterns-inventory-vs-distance-vs-cost)
- [Multi-Location Splits](#multi-location-splits)
- [Manual Reassignment](#manual-reassignment)
- [The Order Routing Explain Agent](#the-q1-2026-order-routing-explain-agent)
- [Other Agentic Commerce Agents](#other-agentic-commerce-agents)
- [Anti-Patterns](#anti-patterns)
- [Checklist](#checklist)

## What Routing Decides (and What It Doesn't)

Before the hierarchy: routing decides the source location for **ship-from** fulfillment — Ship-to-Home, Dropship, ship-from-store, and inter-location transfers. For **In-Store Pickup (BOPIS) and Curbside**, the customer chooses the pickup location at the cart/checkout step, so the initial store assignment is fixed *before* the order is created. The routing engine does not pick a "best" pickup store for the customer. BOPIS-related routing behavior is therefore limited to follow-on cases (e.g., reassigning to a nearby store on a short-pick / decline, or Transfer sourcing the pickup store's stock from another location) — not initial assignment.

This is a frequent point of confusion when designing routing rules: don't write a Scenario whose purpose is "pick the closest pickup store for this BOPIS order." The customer already made that choice.

## The Routing Hierarchy

Source: <https://docs.kibocommerce.com/help/order-routing-overview>

```
Tenant
 └─ Strategy            (a named routing policy — attached to a fulfillment type or order condition)
     └─ Scenario        (an ordered list — first match wins)
         ├─ Filter      (eligibility predicates over locations)
         ├─ Sort        (rank surviving locations)
         └─ After Action (what happens if no match — fall through, split, cancel)
```

A Strategy is what gets attached at the dispatch level. Each Strategy contains one or more Scenarios that run in order. A Scenario applies Filters to the candidate location pool, Sorts the survivors, and an After Action handles what happens if no location qualifies (try the next Scenario, split the shipment across multiple locations, or cancel/reject the item).

The four-level shape is the entire mental model. Every operator change, every "why did this route there" question, and every routing-config defect lives at one of these four levels.

## What Each Level Does

### Strategy

The named routing policy attached to a fulfillment type, a site, or an order condition. A tenant typically has a handful of Strategies — `"Standard Ship"`, `"Expedited"`, `"BOPIS"`, `"Dropship-Preferred"`, `"Clearance-Excess-First"` — and the dispatch decision picks one Strategy per (line × fulfillmentMethod).

### Scenario

The conditional rule inside a Strategy. Scenarios run in order; the **first one that produces a winning location is selected**. Example shape: a Strategy `"Standard Ship"` might contain:

```
Scenario 1: "Items in category 'Hazmat'"            → only hazmat-certified locations
Scenario 2: "Order total > $500"                    → DCs only (avoid store shrinkage)
Scenario 3: "Default"                               → all ship-eligible locations
```

The Scenario condition is itself a filter expression — typically over order, customer, or item attributes — that gates whether the Scenario applies. If it doesn't apply, the engine moves to the next Scenario.

### Filter

The eligibility predicates that prune the candidate location list. A location either passes a Filter or it doesn't — no partial matches.

```
Candidate locations: [DC01, DC02, STORE-042, STORE-099, DROPSHIP-Acme]
   ├─ Filter: ship-eligible              → [DC01, DC02, STORE-042, STORE-099]
   ├─ Filter: within 500 miles of buyer  → [DC02, STORE-042, STORE-099]
   ├─ Filter: in-stock for this SKU      → [DC02, STORE-042]
   └─ Filter: open during cutoff window  → [DC02, STORE-042]
```

Filters are AND'd. A location must pass every filter in the scenario.

### Sort

How to rank the survivors. Sort dimensions decide which location wins among multiple eligible ones. A single Sort rule (e.g., "closest to buyer") or a composite (primary by distance, secondary by excess inventory). The top-ranked location is the winner.

### After Action

What happens if no location passes the filters or if the Sort produces no candidates. Three documented behaviors:

- **Fall through** to the next Scenario in the Strategy.
- **Split** the line across multiple locations (one shipment per location with available stock).
- **Cancel / reject** the line (route to a cancellation reason code; surfaces in `Customer Care` rollup).

After Actions are also where consolidation behavior is gated: with consolidation enabled, a partial-stock-at-top-ranked-location case triggers a Transfer shipment instead of a split (see `fulfillment.md`).

## Location Capabilities as Filter Inputs

Each Location carries a set of capability data that acts as the primary Filter inputs. The two load-bearing pieces are the **`fulfillmentTypes` array** (which fulfillment methods this location supports) and the operational metadata (`hoursOfOperation`, `fulfillmentCapacity`, `latitude`/`longitude`).

| Field | Documented values / shape | Filter usage |
|-------|---------------------------|--------------|
| `fulfillmentTypes[]` | Ship-to-home (commonly modeled as `DirectShip`) and in-store pickup (commonly modeled as `InStorePickup`) — verify exact enum strings against your tenant's Location admin API; the docs describe these in prose but the OpenAPI string values can vary by tenant version | Excludes the location from strategies for the missing types. |
| `supportsInventory` | boolean | Excludes from inventory-aware filters if false |
| `allowFulfillmentWithoutStock` | boolean | Permits shipping ahead of On-Hand entry (rarely used) |
| `hoursOfOperation` + `timezone` | per-day open/close, IANA tz | Time-window filters; routing to a closed store is the classic bug |
| `fulfillmentCapacity` | `{ count, period }` | N shipments per (hours/days/weeks/months) — capacity constraint |
| `latitude` / `longitude` | decimal | Required for distance-based sort |

**Other concepts (Curbside, Delivery, Dropship, Transfer)** are typically modeled as either additional `fulfillmentTypes` values (where tenant supports them), custom location attributes, or location-group memberships rather than first-class boolean fields. Verify against your tenant's Location admin API before treating any of those as a top-level field on the Location resource.

**Wrong filter inputs cause routing to closed stores.** A common defect is to add `InStorePickup` to a store's `fulfillmentTypes` and forget to populate `hoursOfOperation` or `fulfillmentCapacity` — the location appears eligible, gets routed (for transfer sourcing or ship-from-store, since the customer picks the BOPIS store directly), and the customer arrives at a dark storefront. Customer-service tickets follow.

**Anti-pattern:**

```typescript
// Wrong — enabling InStorePickup without modeling hours
await api.put(`/commerce/admin/locations/${code}`, {
  fulfillmentTypes: ['DirectShip', 'InStorePickup'],
  // No hoursOfOperation, no fulfillmentCapacity — Kibo will route here 24/7.
});
```

**Recommended:**

```typescript
await api.put(`/commerce/admin/locations/${code}`, {
  fulfillmentTypes: ['DirectShip', 'InStorePickup'],
  timezone: 'America/New_York',
  hoursOfOperation: [
    { dayOfWeek: 'Monday',   open: '09:00', close: '20:00' },
    { dayOfWeek: 'Tuesday',  open: '09:00', close: '20:00' },
    // ...
    { dayOfWeek: 'Sunday',   open: '11:00', close: '18:00' },
  ],
  fulfillmentCapacity: { count: 50, period: 'Day' },  // 50 shipments/day cap
});
```

Exact field shapes above (`fulfillmentTypes`, `hoursOfOperation`, `fulfillmentCapacity.period`) — verify against your tenant's Location admin API. `DirectShip` and `InStorePickup` are the documented `fulfillmentTypes` enum values.

## Filter Categories

Filters can reference both first-class fields and **Extensible Attributes** (custom attributes on Product, Location, Order, Customer, or Inventory). Custom attribute → routing rule is the documented escape hatch for "we have a unique requirement" — explicitly meant to avoid bespoke code.

| Category | Example filters |
|----------|-----------------|
| **Item** | Weight thresholds, hazmat-certified, fragile flag, freight-eligible, custom item attributes |
| **Location** | Zip-code region, ship-eligible, BOPIS-eligible, insulated-packaging available, hours / blackout windows |
| **Order** | Total price, gift order, expedited shipping requested, blackout dates |
| **Customer** | Account type (B2B / B2C), loyalty tier, customer segment |
| **Inventory** | On-hand thresholds, excess-inventory flag, hold flag, safety-stock-inclusion toggle |

Each filter compiles to a predicate the engine evaluates against the candidate set. The order of filters within a Scenario is documented as not affecting the final eligibility set (AND is commutative); the order of Scenarios within a Strategy does matter.

## Sort Rules

Documented sort dimensions:

| Dimension | Use |
|-----------|-----|
| **Distance to customer** | Geographic proximity; requires `latitude` / `longitude` on every location |
| **Inventory LTD** (Lifetime-to-Date) | Prefer slowest-moving stock — clears aged inventory |
| **Excess inventory** | Prefer locations holding most surplus |
| **Custom score** | Sort by a numeric custom attribute (e.g., labor-cost-index) |

Common combinations:

- A `"fast"` strategy sorts by distance first → ship from the nearest location.
- An `"efficient"` strategy sorts by excess-inventory first → ship from where the merchandise has been sitting longest.
- A `"hybrid"` strategy uses distance as primary, excess as tiebreaker.

**Distance sort requires lat/long on every location.** Without geocoded coordinates, the distance dimension returns `null` and the sort silently degrades to whatever the secondary key is — usually alphabetical by location code, which is meaningless.

## Capacity Constraints

Each Location has an optional `fulfillmentCapacity` — e.g., 50 shipments per day. When the location hits its quota for the period, routing excludes it for the rest of the period. This is the toggle that makes **ship-from-store viable in practice**: stores can opt in without flooding the floor with picks during peak hours.

```
STORE-042 capacity: 50 shipments / day
  10am — already used 30 shipments
  Routing engine: STORE-042 still eligible (20 remaining)
  3pm  — used 50 shipments
  Routing engine: STORE-042 excluded for the rest of the day → next location in the sorted list wins
```

Capacity counts are by shipment, not by line. A shipment with 12 line items counts as 1 against capacity. Surfacing capacity remaining to operations dashboards is a common operational requirement — verify the exact endpoint against your instance.

## Routing Patterns: Inventory vs Distance vs Cost

Three dominant routing patterns; each makes sense in different operational shapes.

### Inventory-Based Routing

Sort primarily by excess inventory or LTD. Best for retailers with a strong "move aged stock first" KPI — apparel, seasonal goods, electronics with rapid depreciation.

```
Strategy: "Move Aged Stock First"
  Scenario: Default
    Filter: ship-eligible AND in-stock
    Sort:   inventory_LTD descending  (oldest stock first)
    After:  fall through to "Closest Location" strategy if nothing qualifies
```

Trade-off: shipping cost goes up (you might ship from Boston to a Los Angeles customer because Boston has the oldest stock). Mitigated by adding a max-distance filter.

### Distance-Based Routing

Sort by distance to customer. Best for retailers optimizing for delivery speed / customer experience and where shipping cost is roughly equivalent across the network.

```
Strategy: "Fastest Delivery"
  Scenario: Default
    Filter: ship-eligible AND in-stock AND within 1000 miles
    Sort:   distance ascending
    After:  fall through to "Anywhere Eligible" strategy
```

Trade-off: aged stock accumulates at low-velocity locations. Mitigated by periodic clearance runs that override to LTD-based routing.

### Cost-Based Routing

Sort by a custom location attribute representing fulfillment cost (labor index, shipping zone, carrier contract rate). Best for retailers with significant cost variance across the network.

```
Strategy: "Lowest Cost"
  Scenario: Default
    Filter: ship-eligible AND in-stock
    Sort:   custom_attribute(fulfillment_cost_index) ascending
    After:  fall through to "Closest Location"
```

Kibo doesn't natively model carrier-rate-aware routing; the `fulfillment_cost_index` is typically a tenant-maintained attribute updated nightly from a cost feed. Live rate-shopping at routing time is a known gap — partners like Shipium fill it.

## Multi-Location Splits

When a line item has insufficient stock at the top-ranked location and the Strategy allows `Split` as the After Action, Kibo splits the line across multiple locations — one shipment per location.

```
Order: Line A, qty 5
  Top-ranked location: STORE-042  — has 2
  Next-ranked:         DC02       — has 3
  After Action: Split

Result:
  Shipment 1: STORE-042, Line A qty 2
  Shipment 2: DC02,      Line A qty 3
```

Toggling **consolidation** changes the behavior. With consolidation enabled, the same case triggers a Transfer shipment: DC02 ships 3 units to STORE-042, which then ships all 5 to the customer as one shipment.

| Mode | Customer receives | Network cost |
|------|-------------------|--------------|
| **Split** | 2 packages | 2 shipping charges, faster availability |
| **Consolidate** | 1 package | 1 customer shipping charge + 1 internal transfer cost, slower (transfer delay) |

The choice between Split and Consolidate is a business-rule decision, not a technical one. Kibo lets you set either per Strategy, and many tenants run different policies per category (high-value goods → consolidate to avoid two-shipment shrinkage; commodity goods → split for speed).

**Anti-pattern:** enabling Split without modeling the carrier-cost downside in reporting. Splits multiply shipping cost; without an excess-inventory or consolidation strategy in front, you get a high-split shop and a confused finance team.

## Manual Reassignment

Operations can manually move a shipment to a different location:

```typescript
// Operator clicks "Reassign" in the Fulfiller UI, or API call:
await api.put(`/commerce/shipments/${shipmentNumber}/reassigned`, {
  toLocationCode: 'STORE-099',
  reasonCode: 'OriginalLocationOOS',
});
```

`PUT /commerce/shipments/{shipmentNumber}/reassigned` sends the shipment back through the routing engine with the original location blacklisted. The engine then picks the next best location per the same Strategy / Scenario / Filter / Sort chain.

Manual reassignment is the operational pressure valve when routing config is wrong. Patterns of reassignment to the same target location (e.g., "STORE-042 always gets reassigned to DC02") are the signal to fix the routing rules upstream.

**Anti-pattern:** building automation that auto-reassigns shipments based on its own heuristics, bypassing the routing engine. The engine is the source of truth for "which location"; layered automation creates conflicting decisions and audit gaps.

## The Order Routing Explain Agent

Part of Kibo's broader Agentic Commerce suite (recently released). Operations can ask in natural language "why was order X routed to location Y?" and the agent surfaces:

- Which locations were considered.
- Which Filters eliminated each one.
- Which Sort rule selected the winner.
- A plain-language explanation.

**This is an observability / audit tool, not a new routing engine.** It does not change routing decisions — it explains them. The same engine still picks; the agent translates the trace into prose. Investigation drops from "hours pulling logs" to seconds.

API surface: **unknown — verify against your instance / Kibo support.** The release notes describe an Admin UI experience; whether there's a structured query API (vs UI-only) is not yet publicly documented at the time of this writing. Likely a conversational endpoint over a managed agent rather than a deterministic query API.

**Anti-pattern:** building automation that loops back through the Explain Agent's output to second-guess routing. The Routing API is the source of truth for "which location"; the Explain Agent is the source of truth for "why." Don't conflate them.

URLs: <https://kibocommerce.com/platform/agentic-commerce/>, <https://docs.kibocommerce.com/solutions/agentic-commerce>

## Other Agentic Commerce Agents

The broader suite includes:

| Agent | Purpose (per Kibo's positioning) |
|-------|----------------------------------|
| **Shopper Agent** | Buyer-facing conversational shopping |
| **CSR Agent** | Customer-service rep co-pilot for order inquiries, exception handling |
| **Order Routing Agent** | The Explain Agent above |
| **Reverse Logistics Agent** | Return disposition / authorization assistance |
| **Forecasting Agent** | Demand and inventory forecasting |

All are observability / decision-support surfaces rather than autonomous decision engines (at time of this writing). Integration surface for each is **not yet publicly documented — verify against live docs and Kibo's release-notes feed before building against them**.

URL: <https://kibocommerce.com/platform/agentic-commerce/>

## Anti-Patterns

### Wrong-Filter Routing to Closed Stores

A location with `InStorePickup` in `fulfillmentTypes` but no `hoursOfOperation` populated is eligible 24/7 for transfer sourcing and follow-on reassignment. Routing then sends work to a store that's closed. **Always pair capability data with the operational metadata that bounds it** — hours, capacity, blackout dates.

### Distance Sort Without Geocoded Locations

A location without `latitude` / `longitude` silently degrades the distance sort to an alphabetical fallback (or worse, excludes from the candidate set entirely on some configurations). Verify every location has coordinates before turning on distance-based routing.

### Splits Without Cost Visibility

Enabling Split as an After Action without surfacing the per-order shipping cost in reporting means the finance team discovers the shipping-spend blowout months after the fact. Either keep Split off, or pair it with shipping-cost dashboards.

### Hard-Coding Strategy Names in Integration Code

Strategies are tenant config; the integration shouldn't reference them by name. If business logic depends on "is this a BOPIS order," check `fulfillmentMethod` on the line item, not the Strategy name.

### Building Routing Logic in the Integration Layer

If the integration is computing "which Kibo location should fulfill this" before posting the order, you've duplicated the routing engine. Post the order with `fulfillmentMethod` set per line, optionally `fulfillmentLocationCode` pre-set when the source platform legitimately knows (e.g., POS), and let Kibo route. Wrapping Kibo's engine in another engine creates two sources of truth.

### Auto-Reassigning via External Heuristics

Reassign is an operator action, not an automation target. Patterns of reassignment to the same target are a signal to fix the upstream routing rules — not to encode the same heuristic in code.

### Treating the Explain Agent as a Decision Input

The Explain Agent reports on past decisions. Feeding its output into routing logic creates a circular loop (explain → re-decide → re-explain). Use it for audit and UX, not for control flow.

### Ignoring `Customer Care` Rollup as a Routing Signal

When routing fails (no location passes the filters or all Scenarios fall through), the shipment lands in `Customer Care`. A production dashboard must surface this as an exception queue. Otherwise, orders silently sit waiting for a human who isn't watching.

### Modeling Dropship Without a Dedicated Strategy

Dropship locations have different cost, latency, and capacity profiles than DCs or stores. Routing them under the same Strategy as DCs produces frequent mis-routes. Maintain a separate "Dropship-Preferred" or "Dropship-Fallback" Strategy and gate it on the right Scenario condition.

## Checklist

Before shipping order-routing configuration:

- [ ] Every location has `latitude` / `longitude` populated if distance sort is in use.
- [ ] Every `InStorePickup`-capable location has `hoursOfOperation` and `timezone` set (BOPIS store assignment comes from the customer's checkout choice, but routing still drives transfer sourcing and reassignment to those stores).
- [ ] Every store opted in to ship-from-store has a `fulfillmentCapacity` cap.
- [ ] Each Strategy is mapped to one or more fulfillment types — no orphan Strategies.
- [ ] Each Strategy has at least one Default Scenario as a terminal fall-through.
- [ ] Custom location attributes used for routing are populated on every location they're filtered against (no `null` capability tests).
- [ ] Split vs Consolidate decision is explicit per Strategy, with the trade-off documented.
- [ ] Manual-reassignment patterns are tracked in reporting (frequent reassign-from / reassign-to pairs indicate routing-config gaps).
- [ ] `Customer Care` rollup surfaced as an ops exception queue (no silent stuck shipments).
- [ ] Dropship locations have their own Strategy, not lumped under DC routing.
- [ ] Integration code does not pre-compute the fulfillment location — Kibo routes, source platform sends `fulfillmentMethod` only (and optionally `fulfillmentLocationCode` when the source legitimately knows).
- [ ] Strategy names are not hard-coded in integration code — branch on `fulfillmentMethod` or capability data instead.
- [ ] Order Routing Explain Agent treated as observability surface, not as a decision input.
