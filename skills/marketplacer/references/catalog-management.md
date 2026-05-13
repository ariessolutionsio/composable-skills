# Catalog Management

The Marketplacer catalog has two tiers: **Adverts** (per-seller listings) and **Golden Products** (marketplace-level masters). The integration question is almost always: which tier owns which data, and how does the PIM/source-of-truth keep both in sync? This file covers the operator-side patterns for both.

## Table of Contents
- [`advertUpsert` — The Master Mutation](#advertupsert--the-master-mutation)
- [Image Handling](#image-handling)
- [Brand & Taxon Assignment](#brand--taxon-assignment)
- [Prototype-Driven Attributes](#prototype-driven-attributes)
- [Draft, Publish, and Vetting](#draft-publish-and-vetting)
- [Variants & Inventory](#variants--inventory)
- [Golden Products Flow](#golden-products-flow)
- [Catalog Rules](#catalog-rules)
- [Bulk Operations](#bulk-operations)
- [HTML & Sanitization](#html--sanitization)
- [Checklist](#checklist)

## `advertUpsert` — The Master Mutation

A single mutation handles both create and update. Operators interact with Adverts mostly via the seller-driven flow (sellers call `advertUpsert` against the Seller API). The Operator API exposes Advert updates but not creates — new Adverts originate from sellers or from Golden Product barfill.

**Shape:**

```graphql
mutation AdvertUpsert($input: AdvertUpsertInput!) {
  advertUpsert(input: $input) {
    advert {
      id legacyId title state
      variants { nodes { id legacyId sku countOnHand } }
      images { id sourceUrl alt }
    }
    errors { path message }
  }
}
```

```typescript
const input = {
  attributes: {
    title: 'Wool Beanie',
    description: 'Hand-knitted merino wool beanie',
    price: 4500,                    // integer cents
    taxonId: 'VGF4b24tMTI=',        // or use taxonMappings instead
    brandId: 'QnJhbmQtNQ==',        // or brandMappings
    attemptAutoPublish: true,
    images: [
      { sourceUrl: 'https://cdn.acme.com/beanie-front.jpg', alt: 'Front view' },
      { sourceUrl: 'https://cdn.acme.com/beanie-side.jpg', alt: 'Side view' },
    ],
    advertOptionValues: [{ optionTypeId: '...', optionValueId: 'T1ZhbC0xMjM=' }], // advert-level option values (older builds: featureOptionValueIds)
    variants: [
      {
        sku: 'BEANIE-RED',
        barcode: '9300675001234',
        countOnHand: 12,
        variantOptionValues: [{ optionTypeId: '...', optionValueId: '...' }],
      },
    ],
    externalIds: [{ key: 'pim_id', value: 'AK-12345' }],
  },
};
```

**Why `attributes` wraps everything:** the API distinguishes the act of upserting from the data. Future input fields (e.g., versioning controls) sit beside `attributes` at the top level. Keep this nesting — it's not redundant.

**Mutually exclusive ID vs mapping inputs:**

| Direct ID | Fuzzy/name mapping |
|-----------|--------------------|
| `taxonId` | `taxonMappings` |
| `brandId` | `brandMappings` |
| `optionValueIds` | (no mapping form) |

Use the mapping form during initial PIM import when you don't yet have Marketplacer IDs cached; use the direct ID form once the cache is warm. Don't mix the two in a single call.

## Image Handling

`ImageInput` accepts one of two source forms per image:

| Form | Use when |
|------|----------|
| `sourceUrl` | The image is publicly fetchable; URL resolves in < 5 s; PNG/GIF/JPG/JPEG; < 32 MB |
| `dataBase64` + `filename` | The image is private or you're uploading from a non-public source |

**Anti-Pattern (slow CDN, missed validation):**
```typescript
{ sourceUrl: 'https://internal-pim.example/img?path=a&secure=signed' }
```
If the URL takes longer than 5 seconds to respond, Marketplacer drops the image silently. Internal/signed URLs that go through auth checks routinely fail this constraint.

**Recommended:**
```typescript
// Either: pre-cache to a fast public CDN before uploading
{ sourceUrl: 'https://cdn-public.example.com/products/abc-123.jpg', alt: 'Front' }

// Or: read and inline as base64 (works for any source, larger payload)
{ dataBase64: await fileToBase64(privatePath), filename: 'front.jpg', alt: 'Front' }
```

**Storage and serving:** Marketplacer stores uploaded images and serves them via Imgix at `https://marketplacer.imgix.net/…`. The Imgix URLs are **signed** — manually editing query parameters (e.g., to resize) returns `sig_invalid`. Use the Imgix transformations the Marketplacer admin or API exposes; don't construct URLs by hand.

**Order matters:** the order of the `images` array determines display order. The first image is the primary/hero.

**Updating vs deleting:**

| Intent | How |
|--------|-----|
| Keep an image as-is | Include `{ imageId: '...' }` in the array |
| Replace an image | Submit the new image without `imageId`; submit the old `imageId` in a removal call |
| Remove an image | Omit its `imageId` from the next upsert (the absence triggers delete) |

This "absence-deletes" semantics is unusual — it means a partial update that omits the `images` field entirely will treat all images as removed. Always submit the full image list on every update, or use a more targeted image mutation if available.

## Brand & Taxon Assignment

Two ways to attach a Taxon and Brand to an Advert.

**By ID (after caching IDs):**
```graphql
{ taxons(first: 200) { nodes { id legacyId name parent { id } } } }
{ brands(first: 500)  { nodes { id legacyId name } } }
```

Cache the result. PIM sync loops do not need to query taxons on every upsert.

**By mapping (during initial import, or when the PIM owns names):**
```typescript
{
  taxonMappings: [
    { source: 'akeneo', value: 'Apparel > Hats > Beanies' }
  ],
  brandMappings: [
    { source: 'akeneo', value: 'Acme Knitwear' }
  ],
}
```

Mappings let Marketplacer match by configured rules (exact name, hierarchy path, custom mapping table). Coordinate with the operator on which mappings are configured before relying on this in production.

## Prototype-Driven Attributes

The Taxon's Prototype dictates the schema. Two categories of attribute:

| Category | Stored on | Differentiates |
|----------|-----------|---------------|
| Variant-level OptionTypes | `variant.optionValueIds` | Per-variant (e.g., color, size — distinct SKUs) |
| Advert-level OptionTypes | `advert.advertOptionValues` on current builds (some older instances expose `featureOptionValueIds`), or `productDetails` / `productFeatures` depending on the Prototype | Per-Advert (e.g., country of origin, material) |

**Anti-pattern:** assuming a fixed schema. The same OptionType may be variant-level in one Taxon's Prototype and advert-level in another's. The integration must inspect the Prototype.

**Recommended pattern:** query the Prototype before constructing the upsert.

```graphql
query Prototype($taxonId: ID!) {
  taxon(id: $taxonId) {
    prototype {
      id
      variantOptionTypes { id name kind optionValues { id name } }
      advertOptionTypes   { id name kind optionValues { id name } }   # named featureOptionTypes on some older instances
    }
  }
}
```

`kind` is one of `SINGLE_SELECT`, `MULTI_SELECT`, `FREE_TEXT`. Validate the source data against the Prototype shape before calling `advertUpsert` — Marketplacer will reject mismatches, but catching them upstream gives better error messages to the seller/operator.

## Draft, Publish, and Vetting

Three concepts gate whether an Advert is visible to shoppers:

| Gate | Controlled by | Effect |
|------|---------------|--------|
| Validation | Marketplacer (automatic) | Adverts missing required Prototype fields fall to Offline state on publish attempt |
| `attemptAutoPublish` | Seller / API caller | Whether the upsert tries to flip to Online on completion |
| Advert vetting | Operator (per-seller setting) | If `seller.advertVettingRequired` is true, an operator must manually approve before Online |

The state values surfaced on the Advert:

- **Online** — Visible to shoppers.
- **Offline** — Not visible. Either failed validation, awaiting vetting, or explicitly hidden.
- **Draft** — In-progress; not yet attempted to publish.

**Recommended pattern during PIM sync:**
- Set `attemptAutoPublish: true` for fully populated records — Marketplacer makes the right decision per Prototype and per vetting setting.
- Track the returned `state`. If it lands as Offline, query `errors` and fix the underlying data; do not retry blindly.

## Variants & Inventory

Inventory is per-Variant.

| Field | Notes |
|-------|-------|
| `countOnHand` | Integer stock. Must be ≥ 0. |
| `infiniteQuantity` | Boolean. When true, `countOnHand` is irrelevant; orders never block on stock. |
| `sku` | Seller's SKU; not unique across the marketplace |
| `barcode` | Used for Golden Product auto-link |
| `optionValueIds` | The variant axes per Prototype |

**Stock enforcement on order:** Marketplacer rejects orders that would exceed `countOnHand`. There is no overstocking, no backorder, no pre-order through the API. If the operator wants those, model it as a separate flag (e.g., `infiniteQuantity: true` plus an `advert.metadata.preorder = true` for display) and have the OMS handle the actual fulfillment delay.

**Bulk variant `countOnHand` updates** are documented as one of the remaining **REST-only** features per the feature matrix. For high-volume inventory sync, defer to the live Legacy REST docs for that single endpoint; everything else stays on GraphQL.

## Golden Products Flow

The marketplace-level master record. Use it when:

- The operator (not the seller) owns the canonical product attributes.
- Multiple sellers can offer the same SKU and the operator wants consistent presentation.
- A PIM is the upstream source of truth.

### PIM → Golden Product → Seller Advert backfill

```
   PIM
    │  (operator-side middleware)
    ▼
  goldenProductUpsert (operator API)
    │
    ▼
  GoldenProduct + GoldenVariants
    │
    │  Two backfill pathways:
    │
    ├─ variantUpsertFromBarcode  (immediate)
    │     Seller (or operator) supplies a Variant with matching barcode
    │     → Marketplacer auto-links to the GoldenVariant
    │     → backfilled within seconds
    │
    └─ advertUpsert (golden flow)  (batch, ~1 hour)
          Operator updates the Golden record
          → batch job propagates to linked seller Adverts
```

**Pick deliberately.**

- Use `variantUpsertFromBarcode` when the UI flow expects immediacy — e.g., a seller has just scanned a barcode and the next page should show the matched Golden Product.
- Use `advertUpsert` (golden flow) for bulk PIM sync where the storefront refresh happens within the hour.

### What stays seller-owned

Even with Golden Products, these always belong to the seller's Advert and never to the Golden record:

- `price`
- `countOnHand` / inventory state
- Seller-specific SKU
- Seller-specific images (if any beyond the Golden gallery)
- Custom seller fields (e.g., the seller's note about condition for second-hand goods)

The PIM is the source of truth for attributes, images, taxonomy, brand. The seller is the source of truth for commercial fields.

## Catalog Rules

Catalog Rules are operator-defined policies that automatically classify or restrict Adverts based on their content. They're how the operator enforces marketplace-wide rules without manual vetting of every Advert.

**Typical uses:**

- Auto-assign Taxon based on title/description keywords (e.g., "any Advert with 'beanie' in the title gets Taxon `Apparel > Hats > Beanies`").
- Restrict prohibited content (e.g., disallow listings in certain Taxons for sellers not approved for them).
- Apply default commission overrides for specific product categories.
- Flag Adverts for vetting when they match risk patterns.

**Integration implication:**

When a PIM-driven upsert lands on Marketplacer, Catalog Rules may rewrite the Advert's Taxon or set it to vetting-required after the upsert call returns. The post-rule state shows up in the next webhook delivery for that Advert. Code that assumes the Advert's Taxon matches what was submitted will drift — read the post-rule state from the webhook or a follow-up query, not from the submitted payload.

**Where docs are thin:** the mutation surface for managing Catalog Rules (creating, updating, listing) is documented under [api.marketplacer.com/docs/operator-api/](https://api.marketplacer.com/docs/operator-api/) — defer to the live docs for the current shape, which has evolved across instances.

## Bulk Operations

The public docs reference spreadsheet upload paths for product creation and at least one bulk variant inventory update path (REST-only). Several detailed how-tos were behind 403 during this skill's research.

**Where docs are thin:** consult the live operator-API docs at [api.marketplacer.com/docs/operator-api/](https://api.marketplacer.com/docs/operator-api/) for the current bulk-import options. The recommended path remains:

- **PIM-driven bulk catalog: Golden Product upserts via GraphQL.**
- **Inventory bulk sync: dedicated bulk endpoint** (currently REST-only).
- **Per-seller spreadsheet upload: seller portal UI** for ad-hoc one-time imports.

Avoid building a "bulk advertUpsert loop" that hammers the GraphQL endpoint at high concurrency — rate limits will throttle (429/503), and the GraphQL surface is not optimized for sustained bulk write throughput.

## HTML & Sanitization

`description` and other free-text fields **are not sanitized by Marketplacer on output**. The consuming system is responsible.

**Anti-pattern (storefront rendering raw HTML from Advert.description):**
```tsx
<div dangerouslySetInnerHTML={{ __html: advert.description }} />
```

**Recommended:**
```tsx
import DOMPurify from 'isomorphic-dompurify';
<div dangerouslySetInnerHTML={{ __html: DOMPurify.sanitize(advert.description) }} />
```

This is an XSS risk vector on multi-seller marketplaces specifically — sellers may inject script content into descriptions either through negligence or maliciously. Treat every free-text field from Marketplacer as untrusted.

## Checklist

Before any catalog write:

- [ ] The PIM-to-Marketplacer mapping target is decided (Golden Product or seller Advert) and documented.
- [ ] Foreign-system IDs go into `externalIds`, not `metadata`.
- [ ] Prototype is queried (or cached) per Taxon before constructing variants.
- [ ] Variant-level vs advert-level OptionTypes are correctly placed.
- [ ] All money values are integer cents.
- [ ] Image URLs are public and resolve in < 5 s; or `dataBase64` is used for private sources.
- [ ] Image array is supplied in full on every update (absence deletes).
- [ ] Sellers requiring vetting will land in Offline after publish — UI surfaces this clearly.
- [ ] HTML output is sanitized on the storefront before render.
- [ ] Bulk catalog sync uses Golden Products + batch backfill rather than parallel `advertUpsert` calls.
- [ ] Bulk inventory sync uses the REST-only endpoint (defer to live docs).
