# Catalog Data Model

Kibo's catalog sits within a four-level scope hierarchy (**Tenant → Master Catalog → Catalog → Site**) that drives which `x-vol-*` header you send, where you put attributes, and how publishing behaves. Product and Category records live within that hierarchy (not as another level above or below it). Most "the API returned nothing" and "we can't have different prices per brand" tickets trace back to a misunderstanding of where data lives in this scope tree. This file is the deep dive; the request-time header contract lives in `api-setup.md`, and inventory-at-locations crosses the boundary into `kibo-oms`.

## Table of Contents
- [The Four-Level Hierarchy](#the-four-level-hierarchy)
- [What Lives Where](#what-lives-where)
- [Publishing is All-or-Nothing per Master](#publishing-is-all-or-nothing-per-master)
- [Product Entity](#product-entity)
- [The Three Attribute Types: Options, Properties, Extras](#the-three-attribute-types-options-properties-extras)
- [Variations and SKUs](#variations-and-skus)
- [Categories](#categories)
- [The Three Category Types](#the-three-category-types)
- [Pricing: Price Lists and Resolution Order](#pricing-price-lists-and-resolution-order)
- [Inventory Boundary (Hands Off to kibo-oms)](#inventory-boundary-hands-off-to-kibo-oms)
- [Search Schema and Faceting](#search-schema-and-faceting)
- [Locale and Localized Content](#locale-and-localized-content)
- [Anti-Pattern / Recommended-Pattern Pairs](#anti-pattern--recommended-pattern-pairs)
- [Checklist](#checklist)

## The Four-Level Hierarchy

Source: [docs.kibocommerce.com/concept-guides/catalog](https://docs.kibocommerce.com/concept-guides/catalog).

```
Tenant
  └── Master Catalog (1..N per tenant)
         │  Universal product database: codes, weights, dimensions,
         │  attribute definitions, product types, options/properties/extras.
         │  THIS is where product structure lives.
         │
         └── Catalog (1..N per master, often called "Child Catalog")
                │  Curated subset of the master. Locale + currency
                │  overrides, price-list overrides, status, active dates,
                │  category assignments, localized content.
                │
                └── Site (1..N per catalog — but each site is bound to
                        exactly one catalog)
                        │  Transactional endpoint — the storefront.
                        │  This is what shoppers hit.
                        │
                        └── Product / Category records flow down from
                                master, surfaced via catalog, transacted
                                on at the site.
```

The split is: **shared data at the master, override-able fields at the child.** Product code, weight, dimensions, attribute definitions, options, properties, and extras live at the Master. Status, active dates, category assignments, price-list resolution, and localized content live at the Catalog (child). The Site is the runtime context — it inherits everything from its bound Catalog.

Concretely:

| Concern | Lives At |
|---------|----------|
| Product code, productType, options/properties/extras definitions | Master Catalog |
| Weight, dimensions, mustShipAlone, fulfillmentTypesSupported | Master Catalog |
| Per-catalog visibility flag `isActive` on `ProductInCatalogInfo`, active dates | Catalog (child) — set via `PUT /commerce/catalog/admin/products/{productCode}/ProductInCatalogs/{catalogId}` |
| Category assignments | Catalog (child) |
| Price-list selection / overrides | Catalog (child) |
| Localized content (productName, description, slug) | Catalog (child), localized per locale |
| Storefront-facing reads, cart, checkout | Site (via `x-vol-site`) |

## What Lives Where

The request you make determines which level you're addressing, and you control that via `x-vol-*` headers (full contract in `api-setup.md`). Quick map:

| Header set | What you're hitting |
|------------|---------------------|
| `x-vol-tenant` only | Tenant-level resources (applications, event subscriptions, location config) |
| `x-vol-tenant` + `x-vol-master-catalog` | Master-catalog admin (product type definitions, attribute defs, options) |
| `x-vol-tenant` + `x-vol-master-catalog` + `x-vol-catalog` | Catalog-level admin (price lists, categories, product status) |
| `x-vol-tenant` + `x-vol-site` | Storefront / transactional (cart, checkout, storefront product read) |

Omitting the wrong header doesn't error — it returns empty or wrong-scope results. See `anti-patterns.md` for the silent-failure mode.

## Publishing is All-or-Nothing per Master

Source: [docs.kibocommerce.com/pages/publishing-introduction](https://docs.kibocommerce.com/pages/publishing-introduction).

The publishing docs state plainly: **"catalog updates are all or nothing across sites sharing a master catalog."** You cannot publish a product change to one site but not another if both sites are bound to catalogs under the same master. The unit of publish is the **master**, not the catalog or the site.

This is the multi-brand footgun. Teams come from platforms where each site is independent and try to model "Brand A's site goes live with the new spring collection on April 1, Brand B's site goes live on April 15." If A and B share a master catalog, you cannot do this — the moment you publish the spring collection drafts, both sites get them.

**Three architectural responses:**

1. **Accept the constraint.** Use catalog-level overrides for the per-brand differences (price, status, category assignments, localized copy) and accept that the underlying product structure publishes together.
2. **Split into separate master catalogs.** If the brands really are independent product universes — different product types, different attribute schemas, different go-to-market cadences — give each its own master. You'll duplicate cross-brand products but get true independent publishing.
3. **Use Publish Sets.** Publish Sets group drafts for scheduled release. Two sites still get the change at the same instant, but you can stage what's in the set. This addresses "when does the change land," not "which sites does it land on."

Staged vs immediate mode is a **tenant-level toggle** — once flipped, every change goes through the staged pipeline (drafts then publish) until the toggle is flipped back. Plan this early; switching mid-flight is disruptive.

## Product Entity

Core fields, from the catalog concept guide:

| Field | Purpose |
|-------|---------|
| `productCode` | Unique internal identifier / SKU root |
| `productType` | Template that determines available attributes. **Attribute schema is on the product type, not the product.** |
| `productUsage` | `Standard`, `Bundle`, or `Configurable` (product with variations) |
| `content` | Wrapper that holds two parallel per-locale arrays: `localizedContent[]` (productName, descriptions, meta tags) and `localizedSEOContent[]` (`seoFriendlyUrl` / slug, SEO redirects). `localeCode` uses underscore format (`en_US`). |
| `price` | Pricing block — but real pricing comes from Price Lists, see below |
| `fulfillmentTypesSupported` | Array of fulfillment codes (e.g. `DirectShip`, `InStorePickup`) |
| `mustShipAlone` | If true, this product ships in its own package |
| `measurements` | Weight + dimensions |
| `properties` | Non-variation attributes (Brand, Material) |
| `options` | Variation attributes (Size, Color) — each unique combination is a variation with its own variation product code |
| `extras` | Optional purchasable add-ons (e.g. Extended Warranty) |
| `variations` | Generated rows when options × values cross |

**Attribute definitions are not on the product.** They are on the **product type**. When you put "Color" on a product, what you've done is bind that product to a product type whose schema includes a Color option (or property). The product type controls cardinality, allowed values, and whether the attribute is an option/property/extra.

## The Three Attribute Types: Options, Properties, Extras

This is a hard distinction, not stylistic. Source: catalog concept guide.

| Type | Generates Variations? | Filterable? | Storefront UI |
|------|----------------------|-------------|---------------|
| **Option** | Yes — every combination becomes a variation/SKU | Yes | Shopper-selectable (the swatch / dropdown) |
| **Property** | No | Yes | Displayed but not selectable (in PDP attribute table, faceted in search) |
| **Extra** | No | No | Optional add-on the shopper can attach at the cart line (e.g. Extended Warranty) |

**Only Options generate SKUs.** That is the load-bearing fact. If Color is modeled as a Property:

- There is no per-color variation product code.
- There is no per-color inventory (inventory keys on UPC × Location; no separate UPC per color = no per-color stock).
- There is no per-color pricing (price entries key on variation; no separate variation = same price for all colors).
- The PDP cannot let the shopper "pick the red one."

This is one of the most expensive mistakes to recover from. Once a product is live and selling with Color as a Property, "fixing" it is a data migration: new product type, new variations, new product codes, repointed orders/returns/inventory, re-indexed search. Get it right at the product-type design stage.

**Rule of thumb:** if the shopper picks it, it's an Option. If the shopper filters on it but doesn't pick a specific one, it's a Property. If it's optional and adds cost, it's an Extra.

## Variations and SKUs

When a product is `productUsage: Configurable` with options like Size (S/M/L) and Color (Red/Blue), Kibo generates one variation per combination:

```
Product code: TSHIRT-001
  Variation: TSHIRT-001-S-RED
  Variation: TSHIRT-001-S-BLUE
  Variation: TSHIRT-001-M-RED
  Variation: TSHIRT-001-M-BLUE
  Variation: TSHIRT-001-L-RED
  Variation: TSHIRT-001-L-BLUE
```

Each variation has its own variation product code (acts as the SKU root) and its own UPCs (one per fulfillable unit — usually 1:1 with variation but can differ for packaging variants). Inventory keys on UPC × Location (see boundary section).

You can suppress specific combinations that don't exist commercially (e.g. no Size XS in Color Black) by deactivating the variation or by configuring the product type's `valuesAreConstrained` logic. Verify the constraint mechanism against your tenant's admin UI — the exact field shape evolves.

## Categories

Source: [docs.kibocommerce.com/api-reference/categories/get-category.md](https://docs.kibocommerce.com/api-reference/categories/get-category.md).

Category fields:

| Field | Purpose |
|-------|---------|
| `id` | Numeric primary key |
| `categoryCode` | External identifier, stable across publishes |
| `slug` | URL component, localizable |
| `parentCategoryId` | Hierarchy pointer |
| `localizedContent` | Per-locale name, description, page metadata |
| `isDisplayed` | Whether category appears in storefront nav |
| `categoryType` | `Static`, `DynamicPrecomputed`, or `DynamicRealtime` (see below) |
| `dynamicExpression` | Rule expression for dynamic categories |

Two identifiers worth keeping straight: `categoryCode` is the stable external identifier and is what foreign-system mappings should target; `slug` is the URL component and is localized. Building integrations off `slug` couples them to URL changes and locale strategy.

The full tree is fetched via `GET /commerce/catalog/admin/categories/tree`. Storefront reads can pull a flatter shape via the GraphQL `categories` query.

## The Three Category Types

| Type | Evaluation | Sees Discounted Prices? | When to Use |
|------|-----------|-------------------------|-------------|
| **Static** | Products assigned manually | n/a (no rule) | Curated collections, editorial pages, "New Arrivals" hand-picks |
| **Dynamic Precomputed** | Rule evaluated at catalog index time | **No** | Most rule-based browse categories where rule depends on stable attributes (brand, material, size) |
| **Dynamic Realtime** | Rule evaluated on every request | **Yes** | Rule must consider current sale price (e.g. "All items under $50 after discount", "Clearance") |

**Only Dynamic Realtime sees promotional/sale prices.** This is because precomputed runs at indexing time, before promotion engine has applied discounts to a given cart context. Dynamic Realtime re-evaluates per request and can include the active pricing context.

The trade-off is load. Realtime categories execute the rule per request — heavier than serving a precomputed list. Reserve them for the cases where the rule explicitly depends on discounted price; use Precomputed for everything else.

**Example expressions:** the rule grammar uses dotted attribute paths and comparison operators, e.g. `properties.brand eq 'Sony'`, `price.salePrice lt 50`. The full operator vocabulary is **unknown — verify against your tenant's admin UI rule builder or the validate endpoint** (`POST /commerce/catalog/admin/discounts/expressions/validate`).

## Pricing: Price Lists and Resolution Order

Source: [docs.kibocommerce.com/concept-guides/pricing](https://docs.kibocommerce.com/concept-guides/pricing).

The default `price` block on a product is the fallback. Real pricing happens through **Price Lists**, which override the default per condition.

### Price entry fields

| Field | Purpose |
|-------|---------|
| `listPrice` | Strikethrough / base price |
| `salePrice` | Promotional price; shown in place of list when set |
| `msrp` | Manufacturer's suggested retail (display only) |
| `cost` | Internal cost (reporting only, never shown to shopper) |
| `map` | Minimum advertised price (compliance floor) |
| `volumePrices` | Tiered breakpoints by quantity |
| `currencyCode` | ISO 4217 |
| `priceListCode` | Which list this entry belongs to |

### Price List metadata

| Field | Purpose |
|-------|---------|
| `priceListCode` | Identifier |
| `rank` | Integer priority — **lower wins** on tie |
| `filteredInStorefront` | If true, only products with explicit entries in this list are visible / buyable when the list resolves |
| `parentPriceListCode` | Child price lists inherit from parent and selectively override |
| `mappedCustomerSegments` | Segment IDs that trigger this list |
| `currencyCode` | List-level currency — you have one list per (currency × tier) |

### Resolution order

When the platform resolves what price to show / charge:

1. **B2B account direct assignment.** If the customer is signed in to a B2B account with a `priceList` directly assigned, that list wins. Highest priority.
2. **Customer segment match.** Any price lists whose `mappedCustomerSegments[]` include a segment the customer belongs to. If multiple match, the one with the lowest `rank` wins.
3. **Catalog default.** The catalog's default price list, or the product-level fallback price.

The resolved list lands on the cart as `priceListCode`. Once resolved, every subsequent line-item price lookup uses that list (until the cart context changes).

**Anti-pattern:** treating `priceListCode` on a cart as a writeable field. It's a resolution result. Setting it manually via API risks bypassing segment-gating that the operator put in place for compliance or contract reasons. See `anti-patterns.md`.

## Inventory Boundary (Hands Off to kibo-oms)

Source: [docs.kibocommerce.com/concept-guides/inventory](https://docs.kibocommerce.com/concept-guides/inventory).

The catalog publishes **logical product IDs, UPCs, and shipping dimensions**. Stock-aware concerns belong to the OMS skill. Specifically:

| Concern | Lives In |
|---------|----------|
| Product code, variation product code, UPC | Catalog (this skill) |
| Weight, dimensions, mustShipAlone | Catalog (this skill) |
| Stock quantity per location (`OnHand`, `Allocated`, `Available`) | OMS (see `kibo-oms`) |
| ATP (Available to Promise — what storefront should display) | OMS, served via Real-Time Inventory Service |
| Safety stock, future inventory, lot/serial/condition, FEFO | OMS |
| Inventory location config (`inventoryEnabled`, `locationType`) | OMS |

For storefront PDP availability reads, the storefront product API embeds an ATP read so you get availability with the product data. For fulfiller-side allocation logic (reservation, release, transfer), use the OMS inventory APIs — that surface is documented in `kibo-oms`, not here.

**Do not duplicate inventory data into product attributes or properties.** Stock is volatile; the catalog should not be the system of record. Always read availability from the storefront product API (which calls the inventory service) or from the OMS APIs directly.

## Search Schema and Faceting

Source: [docs.kibocommerce.com/concept-guides/search-and-merchandizing](https://docs.kibocommerce.com/concept-guides/search-and-merchandizing).

Kibo's search is **native, not an external wrapper** — Algolia/Elastic aren't exposed under the hood. The model:

- **Search Schema** — declares which attributes are indexed and with which analyzer (`lenient` for stemming/synonyms, `exact_match`, or code-specific). Facets are attributes flagged "Available as Filter & Sort."
- **Search Configurations** — relevancy tuning: field weights (1–20), MinMatch %, phrase slop, autocorrect. Four search types tuned independently: Site Search, Category Suggestion, Product Suggestion, Listing.
- **Merchandizing Rules** ("Search Campaigns") — boost/bury/pin/block, triggered by query terms or category browsing. Admin endpoints: `GET /commerce/catalog/admin/search/campaigns`.

For most B2C catalogs, native search is sufficient. Teams that need vector search, deep query rewriting, or sub-50ms global latency typically layer Algolia or Coveo over Kibo and feed the index from event subscriptions.

**Implication for attribute design:** if you want to facet on Brand, Brand must be a Property (or an Option, but Options are usually inappropriate for cross-product facets). Brand-as-`metadata` will not facet. The schema design must precede the catalog import.

## Locale and Localized Content

As of API v2 (post-May 2024), product content lives under **two parallel per-locale arrays**: `localizedContent[]` (display content — productName, descriptions, meta tags) and `localizedSEOContent[]` (SEO-only fields — `seoFriendlyUrl` / slug, SEO redirects). The two arrays are keyed by `localeCode` independently. Legacy clients can pin `x-api-version: "1"` for the pre-localized shape, but new code should consume v2.

**Locale code format:** Kibo's schema uses **underscore** (`en_US`, `fr_FR`, `fr_CA`), not the IETF hyphen format (`en-US`). The hyphen format appears in some docs prose and in `x-vol-locale` examples; the schema enum value is the underscore form. If you write `en-US` into a `localeCode` field, validation will reject or silently drop it depending on the endpoint.

```jsonc
// product.content (v2 shape)
{
  "localizedContent": [
    {
      "localeCode": "en_US",
      "productName": "Red Cotton T-Shirt",
      "productShortDescription": "..."
    },
    {
      "localeCode": "fr_FR",
      "productName": "T-shirt en coton rouge",
      "productShortDescription": "..."
    }
  ],
  "localizedSEOContent": [
    {
      "localeCode": "en_US",
      "seoFriendlyUrl": "red-cotton-tshirt"
    },
    {
      "localeCode": "fr_FR",
      "seoFriendlyUrl": "tshirt-coton-rouge"
    }
  ]
}
```

The dual-level model: **supported locales are declared at the Master Catalog level** (which locales the master allows), while **per-locale content overrides live at the child Catalog level** (the actual `localizedContent[]` and `localizedSEOContent[]` entries — productName, slug, description per locale). A multi-locale storefront uses per-locale entries in those arrays, or a per-locale child catalog where the override surface is larger. The runtime locale resolution context comes from `x-vol-locale` on the request.

## Anti-Pattern / Recommended-Pattern Pairs

### Modeling Color/Size as a Property instead of an Option

**Anti-pattern.** Color modeled as a Property on the product type because "it's just an attribute":

```jsonc
// product type definition (wrong)
{
  "code": "TShirt",
  "properties": [
    { "attributeFQN": "tenant~color", "isRequired": true },
    { "attributeFQN": "tenant~size", "isRequired": true }
  ],
  "options": []
}
```

Consequence: no variation generation, one SKU for the whole product, no per-color inventory or pricing, PDP can't let the shopper pick Red vs Blue.

**Recommended.** Variation-bearing attributes go in `options`, not `properties`:

```jsonc
{
  "code": "TShirt",
  "options": [
    { "attributeFQN": "tenant~color", "isRequired": true },
    { "attributeFQN": "tenant~size", "isRequired": true }
  ],
  "properties": [
    { "attributeFQN": "tenant~brand" },
    { "attributeFQN": "tenant~material" }
  ]
}
```

Variations are auto-generated for each (color × size) combination. Each has its own product code, its own UPC, and its own inventory + price entries.

### Trying to publish per-site when sites share a master

**Anti-pattern.** Two sites (`storeA`, `storeB`) bound to catalogs under the same master, with logic that tries to "publish to A only":

```typescript
// There is no per-site publish target — this is fiction
await publish({ targetSite: 'storeA', productCode: 'TSHIRT-001' });
```

Consequence: publishing is master-scoped. Whatever you ship lands on both sites simultaneously.

**Recommended.** Decide upfront whether the sites should share a master.

- If they should diverge in product structure or go to market on different cadences → **separate master catalogs**.
- If they only need to diverge in price, status, or copy → **single master, catalog-level overrides**, and accept simultaneous publish.

```typescript
// Catalog-level overrides on the same master
await api.catalog.priceList.update({ catalog: 'A', priceListCode: 'A_SPRING' });
await api.catalog.priceList.update({ catalog: 'B', priceListCode: 'B_SPRING' });
// When the master publishes, both A and B see the new structure;
// each catalog's price list governs its own site's pricing.
```

### Building real-time category targeting on Dynamic Precomputed

**Anti-pattern.** A "Clearance — Under $25" category modeled as Dynamic Precomputed with `price.salePrice lt 25`:

```jsonc
{
  "categoryType": "DynamicPrecomputed",
  "dynamicExpression": { "tree": { /* ... */ } }
}
```

Consequence: precomputed runs at indexing time and doesn't see the active promotion context. Items that go on sale via a promotion engine rule (vs a hard `salePrice` field) never enter the clearance category.

**Recommended.** Use Dynamic Realtime when the rule depends on discounted pricing:

```jsonc
{
  "categoryType": "DynamicRealtime",
  "dynamicExpression": { /* ... */ }
}
```

Accept the per-request cost; cache the result at the storefront layer with a short TTL if traffic is heavy.

### Overriding `priceListCode` on the cart manually

**Anti-pattern.** Setting `priceListCode` directly on cart-create to force a B2B price list onto a B2C shopper:

```typescript
await api.commerce.cart.update({
  cartId,
  body: { priceListCode: 'B2B_WHOLESALE' }, // bypasses segment gating
});
```

Consequence: bypasses customer-segment + B2B-account resolution logic. Risks contract violations (selling at wholesale to non-wholesale buyers) and breaks reporting that assumes resolution provenance.

**Recommended.** Drive price list selection through the legitimate path — segment membership or B2B account assignment — and let resolution happen naturally:

```typescript
// Assign the customer to the right segment; the cart's priceListCode
// resolves on its own at next cart create/update.
await api.commerce.customer.segments.addAccountToSegment({
  segmentId, accountId,
});
```

### Storing foreign-system keys in product `properties`

**Anti-pattern.** Stashing the PIM ID in a property called `akeneoId` because "properties are queryable":

```jsonc
{ "attributeFQN": "tenant~akeneoId", "values": ["AKE-12345"] }
```

Consequence: pollutes the storefront facet space (Akeneo ID surfaces as a filter), couples PIM identifiers to publish cycles, and abuses the catalog schema as a foreign-key store.

**Recommended.** Use the **Entities API** for sync-state and foreign keys:

```typescript
// Custom entity list keyed by PIM ID.
// REST endpoint: PUT /platform/entitylists/{entityListFullName}/entities/{id}
//                POST /platform/entitylists/{entityListFullName}/entities
// SDK exposes insertEntity() and updateEntity() (no upsert helper — branch on existence yourself):
const existing = await api.platform.entities.getEntity({
  entityListFullName: 'pimSync@tenant',
  id: 'AKE-12345',
}).catch(() => null);

if (existing) {
  await api.platform.entities.updateEntity({
    entityListFullName: 'pimSync@tenant',
    id: 'AKE-12345',
    body: { productCode: 'TSHIRT-001', lastSyncedAt: '2026-05-13T10:00:00Z' },
  });
} else {
  await api.platform.entities.insertEntity({
    entityListFullName: 'pimSync@tenant',
    body: { id: 'AKE-12345', productCode: 'TSHIRT-001', lastSyncedAt: '2026-05-13T10:00:00Z' },
  });
}
```

Properties stay clean and storefront-shaped; foreign-system state lives where it can be queried by source-system key. The `entityListFullName` identifier (`<listname>@<tenant>`) is the same in both the SDK call and the REST path.

## Checklist

Before shipping catalog/data-model code:

- [ ] Product type uses **Options** for variation-bearing attributes (color, size) and **Properties** for filterable-only attributes (brand, material).
- [ ] Extras are reserved for optional add-ons the shopper attaches at the cart line, not for variations.
- [ ] Each shopper-pickable attribute generates a distinct variation/SKU with its own UPC, inventory, and price.
- [ ] Sites that need independent publishing have **separate master catalogs**, not shared masters.
- [ ] Catalog-level overrides (status, active dates, price lists, localized content) are used for per-site divergence within a shared master.
- [ ] Categories that depend on discounted price use **Dynamic Realtime**, not Dynamic Precomputed.
- [ ] `priceListCode` on the cart is never written directly; price-list resolution flows from segment / B2B-account assignment.
- [ ] Inventory data is **not duplicated into product attributes** — all stock reads go through the storefront product API or OMS inventory API.
- [ ] Foreign-system identifiers (PIM ID, ERP ID, search-index doc ID) live in the **Entities API**, not in product properties or `metadata`.
- [ ] Facet design is reviewed against the search schema — every facet you want is on a Property flagged "Available as Filter & Sort."
- [ ] Locale strategy uses the `localizedContent` array (v2 shape) and `x-vol-locale` on read requests.
- [ ] `x-vol-master-catalog` is set on master-catalog admin calls; `x-vol-catalog` is set on catalog-level admin; `x-vol-site` is set on storefront / cart / checkout calls. See `api-setup.md`.
- [ ] Publish cadence is documented and the team understands that master-level publish hits all sites under it simultaneously.
