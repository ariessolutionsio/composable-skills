# Shipping & Carriers

Kibo's shipping integration handles rate shopping, label generation, and tracking propagation — but the rate-shop boundary is the part that most often gets misplaced. **Rate shopping happens at checkout (or at the source platform), not in OMS.** Code that re-shops rates in OMS produces numbers that don't match what the customer was shown, and the integration ends up explaining a discrepancy that didn't have to exist.

## Table of Contents
- [Where Rate Shopping Happens](#where-rate-shopping-happens)
- [Built-In Carriers](#built-in-carriers)
- [Carrier Accounts and Inheritance](#carrier-accounts-and-inheritance)
- [Shipping Methods and Service-Level Mapping](#shipping-methods-and-service-level-mapping)
- [Label Generation](#label-generation)
- [Tracking Number Propagation](#tracking-number-propagation)
- [Multi-Carrier Scenarios](#multi-carrier-scenarios)
- [International Shipping](#international-shipping)
- [Returns Shipping](#returns-shipping)
- [Partner Integrations](#partner-integrations)
- [Anti-Patterns](#anti-patterns)
- [Checklist](#checklist)

## Where Rate Shopping Happens

Source: <https://docs.kibocommerce.com/pages/shipping-carriers>

| Mode | Who rate-shops | What Kibo OMS receives |
|------|----------------|------------------------|
| **OMS-only (Shopify, SFCC, custom)** | Source platform at checkout | A frozen `shippingMethodCode` + `shippingMethodName` on the imported order |
| **Bundled (Kibo eCommerce + OMS)** | Kibo's storefront shipping-method resolver at checkout | The same — chosen method recorded on the order |

In both modes, by the time the order lands in OMS, **the shipping decision is already made**. Kibo OMS records what was chosen; it does not re-shop. The `shippingMethodCode` is the customer-shown service level (e.g., `fedex_2_DAY`, `ups_GROUND`); the `shippingMethodName` is the human-readable label.

**Critical:** OMS-side re-shopping (calling carrier APIs at label-generation time to "find a better rate") produces a different rate than the one the customer was shown at checkout. The customer paid for `fedex_2_DAY` based on the checkout-time quote; if OMS re-shops and picks a cheaper ground service, the order ships slower than promised. Doing the inverse (OMS picks a faster service than promised) loses money on every label.

**Anti-pattern:**

```typescript
// Wrong — OMS re-shops rates at label time
async function generateLabel(shipment: Shipment) {
  const rates = await fedex.getRates({ origin, destination, weight });
  const cheapest = rates.sort((a, b) => a.cost - b.cost)[0];
  await api.post(`/commerce/shipments/${shipment.shipmentNumber}/packages/${pkgId}/label`, {
    serviceCode: cheapest.serviceCode,  // ← different from what the customer paid for
  });
}

// Recommended — use the shipment's recorded shippingMethodCode
async function generateLabel(shipment: Shipment) {
  await api.post(`/commerce/shipments/${shipment.shipmentNumber}/packages/${pkgId}/label`, {
    serviceCode: shipment.shippingMethodCode,  // ← what the customer paid for
  });
}
```

If the customer's choice was wrong (rate quoted at checkout doesn't actually work for the routed location's carrier account), surface to `Customer Care` rollup and let an operator decide — don't silently re-shop.

## Built-In Carriers

Kibo directly supports these carriers for both outbound shipping labels and return labels:

| Carrier | Notes |
|---------|-------|
| **UPS** | Direct API integration |
| **USPS** | Uses an EasyPost API key under the hood (verify against current docs) |
| **FedEx** | Requires a company-address profile for the originating account |
| **Canada Post** | Direct integration |
| **Purolator** | Direct integration |

For carriers outside this list, integration is via a partner (Shipium, ShipStation, ShipWorks) or a custom adapter using the carrier's own API. Kibo Connect Hub lists 100+ shipping-carrier integrations across the long tail.

## Carrier Accounts and Inheritance

Carrier accounts are configured at **System → Settings → Shipping → Carrier Accounts**. Inheritance follows the location hierarchy:

```
Site default carrier accounts
  └─ Location Group carrier accounts
       └─ Location-specific carrier accounts
```

A Location uses its own carrier account if set; otherwise the Location Group's; otherwise the Site default. Per-location carrier accounts are how multi-tenant retailers run **different store-specific shipping accounts** — e.g., regional UPS contracts, store-level FedEx accounts negotiated independently.

### Per-Tenant Configuration

Carrier credentials are tenant-scoped. There is no global Kibo-provided carrier account — every tenant configures their own UPS / FedEx / USPS / Canada Post / Purolator credentials. Credentials live in the Admin under Shipping → Carrier Accounts and are not exposed via standard API endpoints (verify against your instance — there may be admin APIs for credential management, but they're typically not used outside the Admin UI).

## Shipping Methods and Service-Level Mapping

A `shippingMethodCode` is a tenant-defined identifier mapping to a carrier service. The mapping is configured under Shipping → Shipping Methods.

```
shippingMethodCode  | shippingMethodName    | Carrier  | Service code
─────────────────────────────────────────────────────────────────────
fedex_2_DAY         | FedEx 2-Day           | FedEx    | FEDEX_2_DAY
ups_GROUND          | UPS Ground            | UPS      | UPS_GROUND
usps_PRIORITY       | USPS Priority         | USPS     | PRIORITY
fedex_INTL_PRIORITY | FedEx Intl Priority   | FedEx    | INTERNATIONAL_PRIORITY
```

The source platform's checkout exposes the friendly name (`shippingMethodName`); the import payload carries the code (`shippingMethodCode`). At label-generation time, Kibo translates the code to the carrier's own service code via the tenant configuration.

**Anti-pattern:** hard-coding carrier service codes in integration code (`'FEDEX_2_DAY'`). The mapping is tenant config and changes over time — read the `shippingMethodCode` from the shipment, let Kibo resolve to the carrier service.

## Label Generation

Source: <https://docs.kibocommerce.com/developer-guides/shipment-packages>

`POST /commerce/shipments/{shipmentNumber}/packages/{packageId}/label` generates the carrier label and writes the `trackingNumber` onto the Package. **Verify the exact endpoint against the live API reference** — Kibo's package label endpoint signature has varied across versions.

### Lifecycle

```
1. Shipment reaches Ready state (after Validate Stock, Pack)
2. POST /packages — create a Package with weight + dimensions
3. POST /packages/{id}/label — generate the carrier label
4. trackingNumber written onto the Package
5. Package becomes immutable
6. Shipment proceeds to Print Shipping Label task → Complete
```

### Pre-Label vs Post-Label Mutability

| State | Package operations |
|-------|--------------------|
| **Pre-label** (Package created, no label generated) | `PUT /packages/{id}` to update dims / contents; `DELETE /packages/{id}` to remove |
| **Post-label** (label generated, tracking number assigned) | **Immutable** — must `DELETE` and create a new package to change anything |

The reason for the immutability: once a label has a tracking number, that number is registered with the carrier. Mutating the package post-label produces a label/data mismatch in the carrier's system and triggers carrier-side data-quality alerts.

### What Triggers Label Generation

In the standard STH workflow, label generation is triggered by the `Print Shipping Label` task. The task signal posts the label endpoint, the label is returned (typically as a PDF or ZPL byte stream), and the Fulfiller UI presents it for printing. The task is then marked complete, and the shipment proceeds to `Complete`.

For automated / lights-out fulfillment, the task can be completed programmatically — the integration generates the label via API, prints it via a label printer integration, and marks the task done.

## Tracking Number Propagation

Tracking flows from carrier → Kibo (on label generation) → external storefront (via webhook):

```
1. Label generated  →  carrier returns trackingNumber
2. trackingNumber stored on Package
3. shipment.statuschanged / shipment.workflowstatechanged event fires
4. Integration listener catches the event
5. Listener fetches shipment + packages via Kibo API (events are ID-only)
6. Listener pushes tracking to source platform
       (Shopify Fulfillment API, SFCC ShipOrder, etc.)
```

Source-platform fields typically include:

| Source platform | Tracking fields |
|-----------------|-----------------|
| **Shopify** | `tracking_number`, `tracking_company`, `tracking_url`, `status` (`fulfilled`, `partially_fulfilled`) |
| **SFCC** | `c_trackingNumber`, `c_carrierCode`, fulfillment status on ShipOrder |
| **BigCommerce** | `tracking_number`, `tracking_carrier`, `tracking_link` |

**Tracking belongs on the Package, not on the Shipment, and not on the order's `externalId`.** A Shipment with multiple Packages carries one tracking number per Package — the source-platform fulfillment record needs to mirror that (Shopify supports multiple tracking numbers per fulfillment; verify the equivalent on other platforms).

```typescript
// Recommended — push one source-platform fulfillment per Kibo shipment,
// with all Package tracking numbers attached
await shopify.createFulfillment({
  orderId: shopifyOrderId,
  trackingInfo: shipment.packages.map(p => ({
    number: p.trackingNumber,
    company: shipment.shippingMethodCode.startsWith('fedex') ? 'FedEx' : 'UPS',
    url: `https://www.fedex.com/track?trknbr=${p.trackingNumber}`,
  })),
});
```

## Multi-Carrier Scenarios

A single Order with multiple Shipments can use different carriers on different shipments:

```
Order ORD-789
  ├─ Shipment 1 (STH from DC01)         → FedEx 2-Day      → trackingNumber 1Z...
  ├─ Shipment 2 (BOPIS at STORE-042)    → no carrier (pickup)
  └─ Shipment 3 (Dropship from Vendor)  → UPS Ground       → trackingNumber 1Z...
```

This is the norm, not an edge case. Each Shipment carries its own `shippingMethodCode` (chosen at order time per fulfillment method), and label generation runs independently per Shipment. The source platform's order needs to model N fulfillments per order to mirror this — see `fulfillment.md` for the partial-shipments discussion.

A Shipment with multiple Packages can also span carriers in unusual cases (a heavy item shipping freight + a small item shipping parcel), but Kibo's standard model is one carrier per Shipment. Multi-carrier within a single Shipment is rare enough to verify against your instance's configuration before designing for it.

## International Shipping

International shipping is supported via FedEx International, UPS Worldwide, USPS International, etc., with the standard `shippingMethodCode` mapping. Cross-border-specific concerns:

- **Customs documentation** — Kibo's label endpoint typically generates the commercial invoice / customs forms alongside the shipping label (verify per carrier — FedEx vs UPS implementation details differ).
- **HS codes / country-of-origin** — these are product-level attributes the carrier needs at label time. Whether Kibo carries them on the Product, the Inventory, or a custom attribute is **tenant-specific — verify against your instance's data model**.
- **Duties and taxes** — DDP (Delivered Duty Paid) vs DDU (Delivered Duty Unpaid) is a shipping-method choice; the customer-facing checkout decides, and OMS records the choice via `shippingMethodCode`. Calculation of duty / VAT typically happens at the source platform's checkout, not in OMS.
- **`Default_FXCB_Process`** — Kibo's BPMN repo contains a workflow with this name; "FXCB" possibly stands for "Fulfilled by Cross-Border" or is a customer-specific custom workflow. **Purpose unknown — verify against your instance or Kibo support.**

International shipping is a thin layer in this skill. Tenants doing significant cross-border volume should treat this as a starting point and validate every detail against their carrier contracts and Kibo's per-tenant configuration.

## Returns Shipping

Return labels are issued via `getReturnLabel` after the return reaches `ReturnAuthorized` state. The carrier and service for return shipping can differ from outbound — many retailers use a different (cheaper, ground-only) return service even when outbound was expedited.

```
Outbound:  fedex_2_DAY      (customer paid for fast)
Return:    fedex_GROUND     (cheaper, slower — retailer pays)
```

Return shipping configuration is tenant-side, under Shipping → Return Shipping Methods. The same carrier-account inheritance (Location → Group → Site) applies.

**Anti-pattern:** issuing return labels via the same outbound method without an explicit return-method configuration. Costs add up; many retailers' P&L assumes return-shipping uses the cheaper service.

## Partner Integrations

Documented partners that integrate at the shipping layer:

| Partner | What it adds |
|---------|--------------|
| **Shipium** | Rate-shopping, split-shipment reduction, carrier-optimization layer in front of Kibo's routing |
| **Narvar** | Branded tracking-page experience (replaces carrier tracking URLs with retailer-branded tracking) |
| **ShipStation** | Multi-channel shipping management; common for retailers with smaller WMS |
| **ShipWorks** | Similar to ShipStation; warehouse-side shipping software |

Kibo Connect Hub lists the broader 100+ carrier and shipping-partner integrations. Most are pre-built; some require integrator setup.

URL: <https://kibocommerce.com/platform/connect-hub/>

## Anti-Patterns

### Re-Shopping Rates in OMS

The HIGH anti-pattern. The customer paid for the service chosen at checkout. OMS-side re-shopping produces a rate that doesn't match the customer's quote — silent over-spend or silent under-deliver. Use the shipment's recorded `shippingMethodCode`; surface mismatches to `Customer Care`.

### Hard-Coding Carrier Service Codes

`shippingMethodCode` maps to a carrier service via tenant config. Hard-coding `'FEDEX_2_DAY'` in integration code couples to a specific tenant configuration and breaks the moment the tenant remaps. Read the code from the shipment.

### Mutating Packages Post-Label

Packages are immutable once a label is generated. Mutating dims, contents, or address post-label triggers carrier-side data-quality alerts and produces label-data mismatches. Delete and recreate the package if a change is needed before ship.

### Tracking on the Order, Not the Package

Tracking belongs on the Package. An Order with N Shipments and M Packages per Shipment has N×M tracking numbers (worst case); collapsing them to a single field on the order loses the fan-out. The source-platform fulfillment record needs to model multiple tracking numbers per fulfillment.

### One Carrier Per Order

A mixed-mode order (Ship + BOPIS) involves different carrier concerns per shipment. A multi-location split involves different carrier accounts per shipment. Code that assumes "this order ships via UPS" breaks on the first realistic order. Model carrier at the Shipment level, not the Order.

### Re-Using the Outbound Method for Returns

Most retailers' P&L assumes returns ship via a cheaper service than outbound. Skipping the explicit return-method configuration silently inflates return-shipping cost.

### Generating Labels Before Pack

`POST /label` requires the package to exist with correct weight and dimensions. Generating before pack uses estimated dims and produces overweight surcharges (carrier-side dim-weight billing) that surface weeks later as variance charges.

### Ignoring Carrier-Account Inheritance

A location without its own carrier account uses the Location Group's, then the Site's. When a tenant migrates to per-location accounts, locations missing the new credentials fall back silently to the Site account — which may not be the intended account for that store. Verify carrier-account presence at every location after a credential migration.

### Hard-Coding the Carrier from `shippingMethodCode` Prefix

Code like `code.startsWith('fedex') ? 'FedEx' : 'UPS'` works for naming conventions until a tenant adds a method without that prefix (e.g., `expedited_PRIORITY`). Read the carrier from the tenant's Shipping Methods config rather than parsing the code.

### Assuming International Customs Forms Are Auto-Generated

Customs document generation is per-carrier and depends on the tenant having HS codes / country-of-origin populated on products. **Don't assume — verify against your instance** before promising international shipping in the integration scope.

## Checklist

Before shipping shipping-and-carrier code:

- [ ] No code path re-shops rates in OMS — `shippingMethodCode` is read from the shipment, not re-computed.
- [ ] Package dimensions and weight reflect the packed reality before `POST /label`.
- [ ] Tracking is read from `shipment.packages[].trackingNumber`, propagated as one tracking number per package to the source-platform fulfillment.
- [ ] One source-platform fulfillment per Kibo shipment (not one per order).
- [ ] Carrier is derived from tenant Shipping Methods config, not from prefix-parsing `shippingMethodCode`.
- [ ] Return labels use the configured return-shipping method, not the outbound method.
- [ ] Carrier-account presence verified at every location (Location → Group → Site fallback chain understood).
- [ ] Mismatch between recorded `shippingMethodCode` and what the carrier account can actually fulfill surfaces to `Customer Care`, not silent re-shop.
- [ ] Package label generation tied to the `Print Shipping Label` task — not to a status write.
- [ ] Packages not mutated post-label (delete + recreate if needed).
- [ ] International shipping concerns (HS codes, country-of-origin, DDP/DDU) verified against tenant data model before scope commitment.
- [ ] `Default_FXCB_Process` purpose verified against the tenant's instance before relying on it.
- [ ] Partner integrations (Shipium, Narvar, ShipStation) evaluated against the in-house build before custom-building rate-shopping or tracking-page features.
