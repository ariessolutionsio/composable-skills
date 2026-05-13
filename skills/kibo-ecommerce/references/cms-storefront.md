# CMS & Storefront Patterns

Kibo's built-in CMS is for marketing pages, content slots, and commerce-adjacent thin content — **not** a product information master. Storefronts are always headless from the API's point of view; this file covers what the built-in CMS does (and doesn't), when to use Kibo's CMS vs an external one (Builder.io, Contentful), and the storefront patterns the official Next.js starters codify: GraphQL-first reads, SSR/ISR cache shape, and personalization. Cross-references: `catalog.md` for product/category reads, `api-setup.md` for GraphQL endpoint and auth.

## Table of Contents
- [What Kibo's Built-in CMS Is (And Isn't)](#what-kibos-built-in-cms-is-and-isnt)
- [The Documents API](#the-documents-api)
- [Page Builder UI: What It Actually Provides](#page-builder-ui-what-it-actually-provides)
- [Kibo CMS vs External CMS: Decision Criteria](#kibo-cms-vs-external-cms-decision-criteria)
- [GraphQL Storefront API](#graphql-storefront-api)
- [The Official Next.js Storefront Starters](#the-official-nextjs-storefront-starters)
- [SSR vs ISR vs SSG for Kibo Pages](#ssr-vs-isr-vs-ssg-for-kibo-pages)
- [Personalization](#personalization)
- [Why Storefront Catalog Reads Use GraphQL Not REST](#why-storefront-catalog-reads-use-graphql-not-rest)
- [Anti-Pattern / Recommended-Pattern Pairs](#anti-pattern--recommended-pattern-pairs)
- [Checklist](#checklist)

## What Kibo's Built-in CMS Is (And Isn't)

Kibo positions itself as having a CMS. The honest scope:

| Concern | Kibo's built-in CMS | Owner if not Kibo CMS |
|---------|---------------------|------------------------|
| Marketing pages (About, Help, Returns Policy) | Yes — Documents API | External CMS or static files |
| Content slots / banners / homepage modules | Yes — Documents API | External CMS |
| Email and packing-slip templates | Yes — template management in admin | N/A |
| File / image asset management | Yes — file management in admin | DAM (Cloudinary, Bynder) |
| **Product master data** | **No** | **Product attributes (catalog) or external PIM** |
| **Product images** | **No** (use product `images[]` on the catalog entity) | Catalog or DAM |
| Localization of marketing copy | Yes — locale-tagged documents | External CMS |
| Visual page builder with block-level editing | Limited / largely absent for headless | External CMS (Builder.io, Contentful, Sanity) |
| Branching / preview environments / workflow | Draft / active toggle only | External CMS |
| Personalization via segments | Yes — segment-targeted content | External CMS or personalization platform |

**The CRITICAL anti-pattern (called out in SKILL.md):** treating the CMS as a product information master.

```jsonc
// Wrong — product master data shoved into a CMS document.
{
  "documentTypeFQN": "product_descriptions@my_tenant",
  "name": "product/SKU-1234",
  "properties": {
    "fullDescription": "...",
    "specifications": [/* ... */],
    "compatibleWith": ["SKU-2001", "SKU-2002"],
    "warrantyTerms": "...",
    "sustainability": { /* ... */ }
  }
}
```

Consequences:
- Product attributes are not filterable in search (they're in the wrong system).
- Catalog search merchandising rules cannot target them.
- The product page has to join two systems (catalog + CMS) to render.
- The OMS, marketplace, and analytics integrations all miss the data because they read the catalog.
- Migration off Kibo CMS becomes a multi-system data move.

**Recommended pattern:** product data lives in **product attributes** on the catalog. Use the catalog's `properties`, `options`, `extras`, and custom attributes for everything product-shaped. Use the CMS for marketing pages, banners, hero slots, and content that genuinely is not product master data.

```jsonc
// Right — product master data in the catalog.
{
  "productCode": "SKU-1234",
  "productType": "Widget",
  "content": { /* localized name, description, slug, SEO */ },
  "properties": [
    { "attributeFQN": "tenant~specifications", "values": [/* ... */] },
    { "attributeFQN": "tenant~warranty",       "values": [/* ... */] }
  ],
  "associations": [/* compatibleWith — use product associations, not CMS links */]
}
```

See `catalog.md` for the full attribute placement model (Options vs Properties vs Extras).

## The Documents API

The Documents API is the actual headless content surface. The hierarchy:

```
DocumentListType   (defines what document types a list can hold)
   │
   ▼
DocumentList       (a folder/scope — e.g. "web_pages")
   │
   ▼
Document           (an instance — e.g. "homepage-hero")
   │
   ├── properties  (structured fields per DocumentType schema)
   └── content     (sub-resource: the binary — HTML, image, file)

DocumentType       (defines the schema for a document — properties, required fields)
```

Document fields:

| Field | Purpose |
|-------|---------|
| `id` | 32-digit system identifier |
| `name` | Fully qualified path; unique within a document list |
| `documentTypeFQN` | Required at create; declares the schema |
| `listFQN` | Read-only; which list it belongs to |
| `properties` | JSON object holding the structured data per the document type schema |
| `publishState` | `draft` or `active` |
| `content` | Sub-resource — the binary (HTML, image, file) with `contentMimeType`, `contentLength`, `contentUpdateDate` |

DocumentTypes are FQN-addressable (`web_pages@mozu`, `images@mozu`, custom `hero_modules@my_tenant`, etc.). Authors create DocumentTypes to define schemas (a `Hero` document type with `headline`, `body`, `image`, `cta` properties), and storefront code reads documents conforming to those types.

Endpoints:

| Operation | Endpoint |
|-----------|----------|
| List documents | `GET /content/documentlists/{listFQN}/documents` |
| Get document | `GET /content/documentlists/{listFQN}/documents/{id}` |
| Create document | `POST /content/documentlists/{listFQN}/documents` |
| Update document | `PUT /content/documentlists/{listFQN}/documents/{id}` |
| Get document content (binary) | `GET /content/documentlists/{listFQN}/documents/{id}/content` |
| List document types | `GET /content/documenttypes` |

The shape is closer to Contentful's content model (typed documents with structured properties) than to a WYSIWYG block builder. Authors edit document property values; the storefront renders.

Source: <https://docs.kibocommerce.com/api-reference/documents/create-document.md>.

## Page Builder UI: What It Actually Provides

The Admin UI's Content section provides:

| Capability | Notes |
|------------|-------|
| Theme Customization | Hosted-theme tenants only; not relevant for headless storefronts |
| Template Management | Email + packing-slip templates; view-only in the editor for hosted themes |
| File Management | Image and file asset management |
| Document editing | The actual headless-CMS surface — edit DocumentList contents |

The page-builder URLs in Kibo's help portal (`/help/page-builder`, `/help/page-builder-overview`) 404 at the time of writing. **Kibo's "page builder" for headless implementations is the Documents API** — authors create documents conforming to a DocumentType, and the storefront does its own rendering with those documents as data.

**Practical interpretation:** if your editors expect a Builder.io-style drag-and-drop WYSIWYG, Kibo's CMS will disappoint them. If they're comfortable editing typed content in a form-based editor (analogous to Contentful), it works fine for marketing-page scope.

## Kibo CMS vs External CMS: Decision Criteria

**Use Kibo Documents when:**

- The marketing-page scope is small (handful of pages, no heavy page-building) and tightly bound to commerce.
- Editors already use the Kibo Admin and adding another tool is overhead.
- Localization needs align with Kibo's locale model and the catalog's localized content.
- The team is small enough that workflow ("draft → active") is sufficient — no branching, no scheduled publishes beyond the catalog publish set, no preview environments.
- Cost: keeping content + commerce on one tenant avoids a second vendor contract.

**Use an external CMS (Contentful, Builder.io, Sanity, Storyblok) when:**

- A visual page builder with block-level editing is required. Kibo doesn't ship one for headless storefronts in any meaningful way.
- Content workflow is heavier than commerce workflow — multi-step approvals, branching content, multiple staging environments.
- A content-only API rate-limit budget separate from commerce is needed (a heavy content load shouldn't compete with cart/checkout traffic for Kibo rate budget).
- Preview environments / branching content workflows beyond Kibo's draft/active toggle are required.
- The content surface spans channels Kibo doesn't serve (mobile app, in-store kiosks, OOH displays) and needs to be the content master across them.

**In practice:** most Kibo Next.js storefronts pair Kibo with an external CMS for marketing pages and use Kibo Documents only for thin commerce-adjacent content — size guides, return policy, email templates. The split is usually:

| Surface | Owner |
|---------|-------|
| Homepage hero, marketing banners, landing pages | External CMS |
| Category-page banner content, brand pages | External CMS |
| Email templates, packing-slip templates | Kibo |
| Return policy, shipping FAQ, size guides | Kibo (low-volume, commerce-adjacent) |
| Product detail page content (description, attributes, specs) | Kibo catalog (NOT CMS) |
| Product images | Kibo catalog or DAM |

## GraphQL Storefront API

Source: <https://docs.kibocommerce.com/pages/graphql>.

Kibo exposes a **storefront-shaped GraphQL surface** at the site-aware hostname:

```
https://t{tenant}-s{site}.{env}.{region}/graphql
```

The endpoint is site-aware. Scope (tenant, site, master catalog, catalog, currency, locale) is derived from the hostname; no `x-vol-*` scope headers required (see `api-setup.md`).

Auth: Bearer token in `Authorization`. Two flavours:

| Token type | Used by | Purpose |
|------------|---------|---------|
| Application token (client_credentials) | Server-side (SSR, ISR builds) | Acts with App's Behaviors |
| Shopper token (anonymous or authenticated) | Client-side (browser fetches) | Acts as the shopper; carries cart context |

Client library: `@kibocommerce/graphql-client`. It handles the token shuffle (anonymous → shopper → cart-takeover on login).

**Coverage:** the GraphQL schema is **storefront-shaped, not admin-shaped**.

| What's in GraphQL | What's not |
|-------------------|------------|
| `productSearch`, `product`, `category`, `categoryTree` | Discount creation, category creation, product publishing |
| `currentCart`, cart mutations (add item, update qty, apply coupon) | Promotion engine configuration |
| `checkout`, checkout actions (set destination, perform payment action, submit) | Catalog admin (master catalog edits, attribute definitions) |
| `customerAccount`, account mutations | B2B account onboarding (create + approve) |
| `quotes`, quote mutations (B2B storefront) | Tenant/site/application configuration |
| `documents`, document reads (CMS) | Document write/publish (use REST) |

Default to GraphQL for shopper-facing reads and writes; default to REST for admin/back-office work. Kibo does publish storefront-shaped REST endpoints too — `CatalogStorefront`, `LocationStorefront`, `StorefrontAuthTicket` — so REST is not strictly "admin-only." But for the storefront request path (PDP / PLP / cart / checkout), GraphQL is the optimized surface the official starters use, and mixing in REST calls is rarely worth the round-trips.

Interactive playground: `/graphql` (same URL). Set `"request.credentials": "include"` in the playground's gear icon so the cookie-based shopper ticket gets sent.

## The Official Next.js Storefront Starters

The canonical reference implementations:

| Repo | Scope |
|------|-------|
| [`KiboSoftware/nextjs-storefront`](https://github.com/KiboSoftware/nextjs-storefront) | B2C — full Next.js + MUI 5 + React Query + next-i18next storefront |
| [`KiboSoftware/nextjs-storefront-b2b`](https://github.com/KiboSoftware/nextjs-storefront-b2b) | B2B — same stack plus account hierarchy, quotes, user/role management |

Stack: Next.js, Material UI 5, React Query, next-i18next, TypeScript (~98%). Production-shaped: i18n routing, server-side auth, codegen against the live GraphQL schema (`npm run generate-types`).

Repo structure that matters when you're picking from it:

```
lib/api/                     # API client
lib/gql/queries/             # GraphQL queries (cart/, checkout/, quotes/,
                             #   product-search.ts, get-product.ts, ...)
lib/gql/mutations/           # GraphQL mutations (cart/, checkout/, b2b/, ...)
hooks/queries/               # React Query wrappers (useCart, useProductSearch, ...)
hooks/mutations/             # React Query mutation wrappers
codegen.yml                  # graphql-code-generator config — TS types from live schema
```

The B2B repo adds `lib/gql/queries/b2b/`, `lib/gql/mutations/account-hierarchy/`, `quotes/`, etc.

**Recommended pattern:** clone the starter (B2C or B2B) as your baseline. The structure encodes the right separation between API layer, GraphQL operations, hooks, and components. Code that diverges from this structure without reason tends to end up with cart logic in components and direct fetch calls everywhere.

**Anti-pattern:** building a storefront from scratch using `fetch` directly against `/graphql`. You'll re-derive the token shuffle (anonymous → shopper → takeover), the React Query cache shape, and the i18n routing — all of which the starter has already solved correctly.

For Vue: officially supported integration at `https://docs.kibocommerce.com/pages/vue-storefront`. Same shape, Vue Storefront 3 instead of Next.js.

## SSR vs ISR vs SSG for Kibo Pages

Pricing and inventory must be live; pure SSG is rare. The typical mix in a Kibo Next.js storefront:

| Page type | Strategy | Why |
|-----------|----------|-----|
| **Homepage** | ISR with short revalidate (60–300 s) or SSR | Often hits the search index + CMS; tolerates short staleness |
| **Category / PLP** | ISR (revalidate ~60 s) with client-side React Query refetch for live data | Catalog reads are bursty; ISR amortizes them; React Query refreshes prices/availability |
| **PDP** | ISR (revalidate ~60–300 s) + client-side refetch for price/inventory | The product-content fields change rarely; the price/inventory fields change often. ISR handles the slow-change fields, React Query refreshes the fast-change ones. |
| **Search results** | SSR or client-side | Per-query — caching by query is rarely worth the cache key explosion |
| **Cart / Checkout / Account** | SSR with per-request data | Authenticated context; never cache shared |
| **Marketing pages (CMS)** | ISR with on-demand revalidation tied to CMS publish webhooks | Stale OK between publishes |

**The ISR cost-vs-freshness tradeoff:**

| Revalidate window | Freshness | Cost (origin requests per page) |
|-------------------|-----------|----------------------------------|
| 5 s | Near-live | High — close to SSR |
| 60 s | Within a minute | Moderate |
| 300 s (5 min) | Within five minutes | Low |
| 3600 s (1 hour) | Within an hour | Very low |
| Indefinite (manual revalidate) | Whatever the last publish set | Near zero; needs on-demand revalidation |

The right window depends on the page. PDPs with promotional pricing want 60 s. Brand pages with static content want 3600 s + on-demand revalidate. Pick per route; do not pick one global value.

**On-demand revalidation triggers** (Next.js `res.revalidate` / route handlers):

- CMS publish webhook → revalidate marketing pages.
- Catalog publish webhook (or scheduled batch on the publish set) → revalidate PDPs/PLPs.
- Promotion start/end events → revalidate affected pages.

Cross-reference `extensions-events.md` for the Event Subscription wiring.

**Anti-pattern.** ISR with a 5-second window across the whole site to "stay fresh":

```typescript
// Wrong — every page revalidates every 5s; origin gets hammered.
export const revalidate = 5;
```

**Recommended.** Per-route revalidation tuned to the actual change rate, plus on-demand revalidation for known events:

```typescript
// app/(catalog)/p/[slug]/page.tsx
export const revalidate = 60;  // PDP — price/inventory live enough at 60s + client refetch

// app/(brand)/brand/[slug]/page.tsx
export const revalidate = 3600;  // Brand page — content rarely changes; on-demand revalidate on publish
```

## Personalization

Customer segments are Kibo's segmentation primitive:

| Endpoint | Purpose |
|----------|---------|
| `POST /commerce/customer/segments` | Create segment |
| `POST /commerce/customer/segments/accounts` | Add account to segment |
| `GET /commerce/customer/segments` | List segments |

Segment membership drives:

| Surface | How segment matters |
|---------|---------------------|
| Price-list resolution | Segment → price list mapping (see `catalog.md`) |
| Discount applicability | Discount conditions can target customer segments — verify exact field on the Discounts schema |
| Search merchandising | Search Campaigns can target segments for boost/bury/pin |
| Content (CMS) | Documents can be tagged with segment visibility — **verify against tenant** for the exact field shape |

**Real-time personalization (browse-time behavior — recently-viewed, similar-items, dynamic recommendations) is not in the documented core.** It's typically delegated to a behavioral platform (Bloomreach, Dynamic Yield, Algolia AI, Nosto) that either mutates the GraphQL request or layers a separate read path over the storefront.

**Anti-pattern.** Building real-time recommendation logic in the storefront ("show me products similar to this one") by post-processing search results client-side:

```typescript
const allProducts = await searchAll();  // big request
const similar = allProducts.filter(p => p.category === current.category && p.id !== current.id).slice(0, 4);
```

Performance is bad and the relevance is worse than any dedicated recommender.

**Recommended.** Use segment-driven content/price lists for "campaign-level" personalization Kibo can do natively. For browse-time recommendations, integrate a recommender (Algolia, Bloomreach, etc.) and let it own the recommendation read path.

The exact field shape for segment-targeted documents/components is **unknown — verify against your tenant** before relying on a specific schema.

## Why Storefront Catalog Reads Use GraphQL Not REST

The SKILL.md priority table says "Storefront catalog reads should default to GraphQL." This section spells out why and how, and where REST still fits.

Kibo does publish storefront-shaped REST surfaces — `CatalogStorefront`, `LocationStorefront`, `StorefrontAuthTicket` — so the choice is "which storefront-facing API," not "storefront vs admin." GraphQL wins for most shopper request paths because it composes the multi-entity reads a page actually needs into one call.

**Why GraphQL is the default on the storefront path:**

| Concern | Admin REST | Storefront REST (`CatalogStorefront`, etc.) | GraphQL |
|---------|------------|----------------------------------------------|---------|
| Endpoint shape | Site-unaware unless scoped | Site-aware | Site-aware at `/graphql` |
| Round-trips | N+1 across services | Often N+1 (product, then prices, then inventory) | Single request with nested selection |
| Overfetching | Full entities | Full entities | Field-level selection |
| Shopper context | Awkward — admin token only | Supports shopper ticket | First-class via `@kibocommerce/graphql-client` |
| Caching shape | Per-endpoint | Per-endpoint | Per-query (Apollo / React Query) coalesces |

**Why not pure REST for storefront pages:**

- Admin REST endpoints aren't tuned for storefront request rates. A PDP doing three calls (product, price, inventory) at storefront RPS will hit rate limits faster than the equivalent single GraphQL query.
- REST returns full entities. A PDP needing 8 fields gets all 80. Over a year of traffic, that's measurable bandwidth and parse cost.
- Anonymous-ticket / cart-takeover shopper context is built into `@kibocommerce/graphql-client`; replicating it over REST is doable but unnecessary work.

**Where storefront REST still fits:** off-path admin-style reads from the storefront stack (one-off scripts, server-side jobs), or endpoints the GraphQL schema doesn't cover (e.g., `StorefrontAuthTicket` for shopper login flows when not using the client's built-in handling).

**Anti-pattern.**

```typescript
// Wrong — storefront PDP doing three REST round-trips per page render.
const product   = await restApi.products.get({ productCode: slug });
const price     = await restApi.prices.get({ productCode: slug });
const inventory = await restApi.inventory.get({ productCode: slug });
```

**Recommended.**

```graphql
# One round-trip; field-selected; site-aware via hostname.
query ProductPage($code: String!) {
  product(productCode: $code) {
    productCode
    content { productName productFullDescription }
    price { price salePrice }
    properties { attributeFQN values }
    inventoryInfo { onlineStockAvailable }
  }
}
```

```typescript
// Storefront — uses Apollo's React hooks via the starter's lib/gql/.
const { data } = useQuery(ProductPageDoc, { variables: { code: slug } });
```

Cross-reference: `api-setup.md` for endpoint, auth, and client setup; `catalog.md` for what fields exist on the product.

## Anti-Pattern / Recommended-Pattern Pairs

### Storing product master data in the CMS

Covered above — see [What Kibo's Built-in CMS Is](#what-kibos-built-in-cms-is-and-isnt). Product attributes belong on the catalog, not in CMS documents.

### Mixing admin REST with storefront GraphQL at storefront request rates

**Anti-pattern.**

```typescript
// PDP server component
const cmsBlock = await graphql.query({ /* ... */ });
const stockInfo = await fetch('https://t26507.tp0.mozu.com/api/commerce/inventory/...', {
  headers: { 'x-vol-tenant': '26507', 'x-vol-master-catalog': '1', /* ... */ }
});  // admin REST
```

Half storefront, half admin. Rate limit accounting is split, the admin token cache fights the shopper token cache, and one PDP render burns two different rate budgets.

**Recommended.** Storefront calls go through the GraphQL client; only off-path admin reads (one-off scripts, backoffice tools) go through admin REST.

### Tying ISR to a 5-second window globally

Covered above — see [SSR vs ISR vs SSG](#ssr-vs-isr-vs-ssg-for-kibo-pages).

### Building browse-time personalization client-side from search results

Covered above — see [Personalization](#personalization). Use a dedicated recommender for browse-time; use segments for campaign-level.

### Hardcoding document FQNs across environments

**Anti-pattern.**

```typescript
const homepage = await documents.get({ listFQN: 'web_pages@my_tenant_prod', name: 'homepage' });
```

The `@my_tenant_prod` suffix encodes the environment into the code. Sandboxes won't find the document.

**Recommended.**

```typescript
const homepage = await documents.get({
  listFQN: process.env.KIBO_CMS_PAGES_LIST!,  // env-driven
  name: 'homepage',
});
```

Or use the namespace-less list name and let Kibo's scope resolution find the right environment via the tenant context.

### Reusing the homepage's ISR window for the cart

**Anti-pattern.**

```typescript
// app/cart/page.tsx
export const revalidate = 60;  // wrong — cart is per-shopper
```

Cart pages are per-shopper authenticated context. ISR shares the response across shoppers — a cached "cart" page now serves shopper A's cart to shopper B.

**Recommended.** Cart, checkout, and account pages are SSR per-request, never ISR. Only public pages (homepage, PDP, PLP, marketing) are ISR candidates.

```typescript
export const dynamic = 'force-dynamic';  // SSR per request for authenticated routes
```

## Checklist

Before shipping CMS / storefront code:

- [ ] Product master data lives in **catalog attributes**, not CMS documents.
- [ ] Marketing pages and content slots are in Kibo Documents API **or** an external CMS — decided based on workflow/page-builder requirements, documented in the architecture.
- [ ] Storefront catalog reads go through **GraphQL** at the site-aware hostname; admin REST is not on the storefront request path.
- [ ] The GraphQL client (`@kibocommerce/graphql-client`) handles the anonymous → shopper → takeover token flow; no hand-rolled shopper-token logic.
- [ ] One of the official starters (`nextjs-storefront` or `nextjs-storefront-b2b`) is the structural baseline.
- [ ] ISR revalidation windows are **per-route**, tuned to actual change rate; no global 5-second-fits-all.
- [ ] Cart, checkout, and account routes are SSR (per-request); they are **not** ISR.
- [ ] On-demand ISR revalidation is wired to catalog publish events and CMS publish webhooks (see `extensions-events.md`).
- [ ] Personalization at "campaign level" (segment → content, segment → price list, segment → discount) uses Kibo segments; browse-time recommendations are delegated to a dedicated recommender.
- [ ] Document FQNs are env-driven, not hardcoded with environment suffixes.
- [ ] CMS scope is contained: marketing copy, banners, email templates, commerce-adjacent thin content. Anything product-master-shaped belongs in the catalog or an external PIM.
- [ ] Editors have been shown a realistic Kibo Documents demo before commitments to scope; if they need WYSIWYG block-building, an external CMS is in the plan from day one.
