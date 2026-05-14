# API Setup & Client Configuration

The Kibo Composable Commerce Platform is one product served across eCommerce, OMS, and Subscriptions. Every Kibo API shares the same authentication model, tenant/site/catalog scoping, REST + GraphQL surface, event subscription mechanism, and API Extensions runtime. Getting any of these wrong — the wrong hostname, the wrong scope header, the wrong Behavior on the App Key — produces failures that look like missing data or "permission denied" bugs but are actually transport/context issues.

## Table of Contents
- [Endpoint & Host Pattern](#endpoint--host-pattern)
- [Authentication (OAuth 2.0)](#authentication-oauth-20)
  - [The OAuth Endpoint](#the-oauth-endpoint)
  - [The Refresh Endpoint](#the-refresh-endpoint)
  - [Token Caching](#token-caching)
- [Behaviors (Permission Model)](#behaviors-permission-model)
- [Tenant / Master Catalog / Catalog / Site Hierarchy](#tenant--master-catalog--catalog--site-hierarchy)
- [The `x-vol-*` Scope Headers](#the-x-vol--scope-headers)
- [Client Setup (TypeScript)](#client-setup-typescript)
- [REST vs GraphQL — When to Use Which](#rest-vs-graphql--when-to-use-which)
- [Pagination](#pagination)
- [IDs and Money](#ids-and-money)
- [Rate Limits & Error Handling](#rate-limits--error-handling)
- [Event Subscriptions](#event-subscriptions)
- [API Extensions (formerly Arc.js)](#api-extensions-formerly-arcjs)
- [Known Unknowns](#known-unknowns)
- [Checklist](#checklist)

## Endpoint & Host Pattern

Kibo splits hosting across two host families: a **single auth host** and **per-tenant API hosts**. The auth host issues OAuth tokens for every tenant in its region. The API host is derived from the tenant ID and the environment.

```
Auth host (US prod + sandbox):
https://home.mozu.com/api/platform/applications/authtickets/...

Tenant-only API host (admin / back-office):
https://t{tenantId}.{env}.{region}/api/...

Site-aware API host (storefront REST + GraphQL):
https://t{tenantId}-s{siteId}.{env}.{region}/api/...
https://t{tenantId}-s{siteId}.{env}.{region}/graphql
```

US sandbox is `t{id}.sandbox.mozu.com`; US production is `t{id}.tp0.mozu.com`. Kibo never finished its rebrand from "Mozu" — `home.kibocommerce.com` resolves but the SDKs, docs, and live OAuth flow all use `home.mozu.com`.

**Non-US regions** have their own host patterns documented in the getting-started guide: EU sandbox `t{id}.sb.euw0.kibocommerce.com`, EU prod `t{id}.tp0.euw1.kibocommerce.com`; GCP regional variants under `*.gcp.kibocommerce.com` (e.g., `*.sb.usc1.gcp.kibocommerce.com`, `*.sb.euw4.gcp.kibocommerce.com`). Authentication for non-US regions is relative to the **tenant base URL**, not `home.mozu.com`. Confirm the exact host for your tenant before shipping.

The site-aware vs tenant-only distinction is not cosmetic. It determines whether Kibo can resolve catalog scope from the URL or whether your code must supply it in headers — see [The `x-vol-*` Scope Headers](#the-x-vol--scope-headers).

Source: <https://docs.kibocommerce.com/api-overviews/getting-started>, <https://docs.kibocommerce.com/help/making-api-calls>.

## Authentication (OAuth 2.0)

Every Kibo API call needs an OAuth 2.0 bearer token. Kibo uses the **client credentials grant** — there is no end-user OAuth dance for back-office work. App Key (`clientId`, e.g. `KIBO_APP.1.0.0.Release`) and Shared Secret (`client_secret`) come from the Kibo **Dev Center** (separate from the Admin Console) under **Develop → Applications → [app] → Application Details**. Both survive forever unless rotated; they are **not** Admin Console user credentials.

### The OAuth Endpoint

```http
POST https://home.mozu.com/api/platform/applications/authtickets/oauth
Content-Type: application/json

{
  "client_id":     "KIBO_APP.1.0.0.Release",
  "client_secret": "12345_Secret",
  "grant_type":    "client_credentials"
}
```

Response:

```json
{
  "access_token":  "eyJhbGciOi…",
  "token_type":    "bearer",
  "expires_in":    3600,
  "refresh_token": "ab12cd34…",
  "refresh_token_expires_in": 1209600
}
```

- `expires_in` is **seconds**. Access token lifetime is **1 hour** (3600 s). Refresh token lifetime is **14 days** (1209600 s). Trust the value the server returns; don't hard-code.
- `token_type` is always `"bearer"`. Subsequent calls go out as `Authorization: Bearer <access_token>`.

### The Refresh Endpoint

```http
POST https://home.mozu.com/api/platform/applications/authtickets/refresh-oauth
Content-Type: application/json

{
  "refreshToken": "ab12cd34…"
}
```

Returns the same envelope as the OAuth endpoint. On a 4xx response (refresh expired or revoked), **re-authenticate with client credentials** — do not retry the refresh.

### Token Caching

**Anti-Pattern (re-authenticating every call):**
```typescript
async function callKibo(path: string) {
  // New OAuth round-trip on every request
  const { access_token } = await fetchOAuth(clientId, sharedSecret);
  return fetch(`https://t26507.sandbox.mozu.com${path}`, {
    headers: { Authorization: `Bearer ${access_token}` },
  });
}
```

This burns rate-limit budget on the auth host, doubles latency on every call, and makes 401s harder to diagnose because the token always looks "fresh".

**Recommended (cache the access token, refresh proactively):**
```typescript
// Use the SDK — it caches in memory (or a caller-provided AuthTicketCache),
// refreshes proactively before expiry, and falls back to client_credentials
// if the refresh token is itself expired.
import { Configuration } from '@kibocommerce/rest-sdk';

const configuration = new Configuration({
  clientId:     process.env.KIBO_CLIENT_ID!,
  sharedSecret: process.env.KIBO_SHARED_SECRET!,
  authHost:     'home.mozu.com',
  apiEnv:       'sandbox',
  tenantId:     26507,
  // ...
});
// Every Api client built from this Configuration shares the same token cache.
```

`@kibocommerce/sdk-authentication` is what `@kibocommerce/rest-sdk` and `@kibocommerce/graphql-client` use under the hood. Hand-rolled OAuth in Kibo integrations is a common source of "phantom 401s exactly one hour after deploy" bugs. Use the SDK.

Source: <https://github.com/KiboSoftware/sdk-authentication>, <https://docs.kibocommerce.com/help/getting-started>.

## Behaviors (Permission Model)

Kibo's equivalent of OAuth scopes is called **Behaviors**. Behaviors are assigned to an Application in Dev Center under **Packages → Behaviors**. Each Behavior is a resource × permission tuple — `Product Read`, `Order Update`, `Inventory Read`, and so on. There are 100+ Behaviors organized by domain.

Two facts make Behaviors easy to misuse:

1. **Behaviors are tenant-wide for the App Key.** They are not per-site or per-catalog. An App installed with `Order Update` can update orders against any site under that tenant.
2. **Behaviors are editable post-creation, but the change requires action.** When you add or remove a Behavior on an installed App you must:
   - Re-install the Application on each affected sandbox.
   - Re-enable it in Dev Center.
   - **Flush your token cache.** Existing access tokens encode the old Behaviors and remain valid for up to an hour.

**Anti-pattern:** granting `Super Admin` or every Behavior to an integration app "to avoid 403s in dev". Kibo's certification will reject this, and the blast radius of a leaked key is the entire tenant.

**Recommended pattern:** least-privilege Apps per integration. PIM sync gets catalog Behaviors. OMS adapter gets order/shipment Behaviors. Subscriptions worker gets subscription + customer Behaviors. One leaked key, one bounded blast radius.

Source: <https://docs.kibocommerce.com/help/application-behaviors>.

## Tenant / Master Catalog / Catalog / Site Hierarchy

This is the single most load-bearing concept in the platform. Everything from price localization to where a shopper's cart lives is decided by this hierarchy.

```
Tenant
 └── Master Catalog     (canonical product set; defines supported locales)
      └── Catalog       (subset/override of Master; one currency per catalog)
           └── Site     (storefront/channel; bound to exactly one catalog)
```

- A **Tenant** is the customer's top-level container — typically one per Kibo contract.
- A **Master Catalog** holds the canonical product data. Multiple catalogs inherit from it. **Supported locales (`en-US`, `fr-FR`) are declared at the master catalog level**; per-locale content overrides (`productName`, slug, description) then live in the **child Catalog** under the `localizedContent` arrays — see `catalog.md` for the v2 shape.
- A **Catalog** is a child of a Master Catalog. It can override price, name, description, and other product fields. **Currency is set at the catalog level** — not on the site, not on the product.
- A **Site** is a storefront/channel binding. **Each site is bound to exactly one catalog** (non-negotiable). Multiple sites can share a catalog.

Practical consequences:

- **Multi-currency = multi-catalog.** USD + EUR is two catalogs. Two sites if they front different storefronts; one storefront swapping catalog scope per request if it has a currency switcher.
- **Multi-locale within one currency is fine** — supported locales are declared on the master catalog and per-locale content lives on the child catalog, so one master can serve `en-US` and `es-US` against USD.
- **A site cannot "borrow" a catalog from another master catalog.** The chain is fixed at site creation.

Tenant and site IDs are integers (rendered `t26507`, `s41315` in URLs). Catalog and master catalog are small integers (`1`, `2`, ...).

Source: <https://docs.kibocommerce.com/help/catalog-and-site-structure-settings>.

## The `x-vol-*` Scope Headers

Kibo expects scope (tenant, master catalog, catalog, site, locale, currency) on every request. There are **two ways to supply it**, and mixing them is the #1 cause of "the API returned 200 but the data is wrong" bugs.

| Header | Purpose | When required |
|---|---|---|
| `x-vol-tenant` | Top-level tenant scope | Always, on tenant-only hostname |
| `x-vol-master-catalog` | Master catalog scope | Most catalog/storefront calls (default `1`) |
| `x-vol-catalog` | Catalog scope | Most catalog/storefront calls (default `1`) |
| `x-vol-site` | Site scope | Storefront, cart, checkout, customer self-service |
| `x-vol-locale` | Content language | Content-bearing endpoints (`en-US`) |
| `x-vol-currency` | Pricing currency | Price-bearing endpoints (ISO 4217) |
| `x-vol-user-claims` | Shopper auth ticket | Storefront REST and GraphQL for shopper context |
| `x-vol-version`, `x-vol-correlation` | API version pin, trace ID | Optional |

### The #1 Footgun

**Sending `x-vol-site` without `x-vol-master-catalog` + `x-vol-catalog` on a tenant-only hostname silently returns wrong-catalog data.** The call returns 200, the shape looks right, but you're seeing a different catalog's prices/overrides/translations than the site is actually bound to.

**Anti-Pattern (partial scope on tenant-only host):**
```http
GET https://t26507.sandbox.mozu.com/api/commerce/catalog/admin/products/SKU-1
Authorization: Bearer eyJhbGc…
x-vol-tenant: 26507
x-vol-site:   41315
```
No master catalog. No catalog. Kibo applies a default catalog that may not be the one site `41315` is bound to. The response is "successful" but wrong.

**Recommended pattern A (site-aware hostname — preferred for storefront):**
```http
GET https://t26507-s41315.sandbox.mozu.com/api/commerce/catalog/storefront/products/SKU-1
Authorization: Bearer eyJhbGc…
```
With `s41315` in the hostname, Kibo resolves master catalog, catalog, locale, and currency from the Site record. No `x-vol-*` scope headers required.

**Recommended pattern B (tenant-only hostname for admin — send all four):**
```http
GET https://t26507.sandbox.mozu.com/api/commerce/catalog/admin/products/SKU-1
Authorization: Bearer eyJhbGc…
x-vol-tenant:         26507
x-vol-master-catalog: 1
x-vol-catalog:        1
x-vol-site:           41315
```

The rule: **either use the site-aware hostname, or send all four of `x-vol-tenant`, `x-vol-master-catalog`, `x-vol-catalog`, `x-vol-site` together.** Never send `x-vol-site` without `x-vol-master-catalog` + `x-vol-catalog`.

Source: <https://docs.kibocommerce.com/help/making-api-calls>.

## Client Setup (TypeScript)

`@kibocommerce/rest-sdk` is **OpenAPI-generated** from ~20 service specs (`CatalogStorefront`, `CatalogAdministration`, `Commerce`, `Customer`, `Fulfillment`, `Inventory`, `Subscription`, etc.), each producing a `clients/<Service>/` namespace. `@kibocommerce/graphql-client` is **hand-written TypeScript** wrapping Apollo Client — not codegen. Both share `@kibocommerce/sdk-authentication` underneath for OAuth.

**Anti-Pattern (per-request client construction):**
```typescript
async function getProduct(productCode: string) {
  // New Configuration on every call — defeats the token cache,
  // re-authenticates each time, and is impossible to instrument once.
  const cfg = new Configuration({
    clientId:     process.env.KIBO_CLIENT_ID!,
    sharedSecret: process.env.KIBO_SHARED_SECRET!,
    authHost:     'home.mozu.com',
    apiEnv:       'sandbox',
    tenantId:     26507,
    siteId:       41315,
  });
  const api = new ProductSearchApi(cfg);
  return api.storefrontSearch({ query: productCode });
}
```

**Recommended (singleton Configuration, multiple Api clients):**
```typescript
// kibo/client.ts
import { Configuration } from '@kibocommerce/rest-sdk';
import { ProductSearchApi } from '@kibocommerce/rest-sdk/clients/CatalogStorefront';
import { OrderApi } from '@kibocommerce/rest-sdk/clients/Commerce';

// One Configuration per (tenant, env) tuple, constructed at boot.
// All Api clients built from it share the same token cache.
export const configuration = new Configuration({
  tenantId:      Number(process.env.KIBO_TENANT),
  siteId:        Number(process.env.KIBO_SITE),
  masterCatalog: Number(process.env.KIBO_MASTER_CATALOG ?? 1),
  catalog:       Number(process.env.KIBO_CATALOG ?? 1),
  clientId:      process.env.KIBO_CLIENT_ID!,
  sharedSecret:  process.env.KIBO_SHARED_SECRET!,
  authHost:      process.env.KIBO_AUTH_HOST ?? 'home.mozu.com',
  apiEnv:        process.env.KIBO_API_ENV ?? 'sandbox',
});

export const productSearch = new ProductSearchApi(configuration);
export const orders        = new OrderApi(configuration);
```

`Configuration.fromEnv()` will read the canonical env-var names (`KIBO_TENANT`, `KIBO_SITE`, `KIBO_MASTER_CATALOG`, `KIBO_CATALOG`, `KIBO_LOCALE`, `KIBO_CURRENCY`, `KIBO_AUTH_HOST`, `KIBO_CLIENT_ID`, `KIBO_SHARED_SECRET`, `KIBO_API_ENV`) if you'd rather not pass them explicitly.

Middleware hooks (`pre`, `post`, `onError`) attach to the `Configuration` for logging, metrics, and `x-vol-correlation` propagation — see the SDK README for the interface shape.

For GraphQL:

```typescript
import { CreateApolloClient } from '@kibocommerce/graphql-client';

export const graphql = CreateApolloClient({
  api: {
    apiHost:      `t${process.env.KIBO_TENANT}-s${process.env.KIBO_SITE}.sandbox.mozu.com`,
    authHost:     'home.mozu.com',
    clientId:     process.env.KIBO_CLIENT_ID!,
    sharedSecret: process.env.KIBO_SHARED_SECRET!,
  },
  clientAuthHooks: {
    onTicketChange: (ticket) => writeCookie(ticket),
    onTicketRead:   () => readCookie(),
    onTicketRemove: () => clearCookie(),
  },
});
```

`clientAuthHooks` persist the shopper ticket — cookie in SSR storefronts, in-memory for SPAs paired with a session cookie. If `@kibocommerce/graphql-client` runs in a browser bundle, **the App Key and Shared Secret are visible**; configure the App with storefront-only Behaviors in that case, or render server-side.

Source: <https://github.com/KiboSoftware/typescript-rest-sdk>, <https://github.com/KiboSoftware/graphql-client>.

## REST vs GraphQL — When to Use Which

| Concern | REST | GraphQL |
|---|---|---|
| Primary use | Back-office, admin, server-to-server, OMS, subscriptions | Storefront — PDP, PLP, cart, checkout, customer self-service |
| Endpoint | `https://t{tenant}.{env}/api/commerce/...` | `https://t{tenant}-s{site}.{env}/graphql` |
| Auth | `Authorization: Bearer <app-token>` | `Authorization: Bearer <app-token>` **plus** `x-vol-user-claims: <shopper-ticket>` |
| Scope coverage | Full platform — every entity, every CRUD operation (~20 service namespaces) | Storefront-shaped subset (products, categories, cart, orders for the shopper, customer accounts) |
| Mutations | Yes (POST/PUT/DELETE) | Yes — both queries and mutations (e.g., `addToCart`) |
| Schema source | OpenAPI specs at `apidocs.kibocommerce.com` | Live introspection at `/graphql` plus Voyager at `/graphql/voyager` |

The boundary is sharper than commercetools' "all things possible in both":

- **Don't do admin CRUD over GraphQL.** Kibo's GraphQL schema is intentionally storefront-shaped. Missing admin fields aren't bugs — they're not exposed.
- **Don't put storefront page rendering on admin REST.** Cart merging, anonymous shopper tickets, and price-list resolution depend on `x-vol-user-claims` and the site-aware hostname. *Admin* REST loses that context. Kibo does publish storefront-shaped REST endpoints (`CatalogStorefront`, `LocationStorefront`, `StorefrontAuthTicket`) that **do** carry shopper context — those are fine for off-path reads, but GraphQL is still the optimized surface for PDP/PLP/cart/checkout where you want one composed call instead of N round-trips.

Shopper context uses `x-vol-user-claims`. The same header works for both anonymous and authenticated shoppers — anonymous tickets enable guest checkout. To force-drop the ticket on a single GraphQL request, set `x-vol-user-claims: null`.

The GraphQL Playground at `/graphql` requires you to open its gear icon and set `"request.credentials": "include"` so the cookie-based shopper ticket gets sent.

Source: <https://docs.kibocommerce.com/help/graphql>.

## Pagination

### REST

Offset-based — `startIndex` + `pageSize`. No cursors. Optional `sortBy` and Kibo's own `filter` expression syntax (`categoryCode eq Shoes`, `isActive eq true`).

**Anti-Pattern (page size above the cap, no stable sort):**
```http
GET /api/commerce/catalog/admin/products?startIndex=0&pageSize=5000
```
`pageSize` is silently capped (or rejected, depending on endpoint) at **200**. Without `sortBy`, paginating across mutations can skip or repeat records.

**Recommended:**
```http
GET /api/commerce/catalog/admin/products?startIndex=0&pageSize=200&sortBy=createDate%20desc&filter=isActive%20eq%20true
```
Response includes `totalCount`, `pageCount`, `pageSize`, `startIndex`, `items`. Walk `startIndex` in steps of `pageSize` until you've consumed `totalCount`. For exports beyond a few hundred thousand records, use the Import/Export API instead of REST pagination.

### GraphQL

Same offset model — `startIndex` + `pageSize` arguments on list-returning fields (e.g. `productSearch(query, startIndex, pageSize)`). Response shape includes the equivalent of `pageInfo` (totalCount, pageCount, etc.). No Relay-style cursors.

Source: <https://docs.kibocommerce.com/help/api-best-practices>.

## IDs and Money

Kibo IDs are not UUIDs and not opaque base64. They mix integers and string codes that you assign:

- **Integers** for `tenantId`, `siteId`, `accountId` (customer), shipment ID.
- **String GUID-style `orderId`** is internal; **`orderNumber`** is the human-facing sequence (`12000123`) — the two are **distinct** and the APIs are picky about which goes where.
- **String codes** for catalog-domain entities: `productCode`, `categoryCode`, `discountCode`, `couponCode`. `productCode` is the closest thing to a natural key — you assign it at creation; downstream systems (search, OMS, analytics) all join on it. Treat as immutable post-launch.

There is no global "external ID" field analogous to commercetools' `key` or Marketplacer's `ExternalIds`. For cross-system mapping, use **custom attributes** on the entity (Catalog → Attributes for products, etc.) and query by attribute filter.

### Money

**Anti-Pattern (assuming cents):**
```typescript
{ price: { price: 1999 } }   // wrong — Kibo treats this as $1,999.00
```
If you're arriving from Marketplacer or Stripe, this trips up almost everyone.

**Recommended (decimals at face value):**
```typescript
{ price: { price: 19.99 } }  // correct — $19.99
```

- Monetary values are **decimals, not integer cents**. `price = 19.99`, not `1999`.
- Currency is set on the **catalog**, not on the record. Every product price on a given catalog is in that catalog's currency.
- Multi-currency = multiple catalogs (or multiple sites against multiple catalogs).
- Price Lists layer regional/B2B-account pricing within a single currency.

Use a decimal-safe type (`Big.js`, `decimal.js`, native `Decimal` on your platform) for arithmetic. Never naive JS `number` for accumulation — round at presentation, not during the math.

Source: <https://docs.kibocommerce.com/pages/price-lists>.

## Rate Limits & Error Handling

**Sandbox** (per developer account, pooled across that account's sandboxes):
- General APIs: **500 req/min, 10,000 req/hour**
- Inventory Refresh + Inventory Adjust: **50 req/min, 200 req/hour** (queued operations)

**Production:** currently unenforced per-tenant, but Kibo reserves the right to throttle abusive activity. Pre-prod / performance environments have per-tenant limits similar to sandbox.

The hourly bucket is a **rolling 60-minute window in four 15-minute sub-buckets**. Bursting at 500 RPM for a full minute can exhaust your hourly allowance in 20 minutes — design for sustained rate, not peak.

On 429:
```http
HTTP/1.1 429 Too Many Requests
Retry-After: 60
```

`Retry-After` values are **discrete**: `60`, `900`, `1800`, `2700`, or `3600` seconds (1, 15, 30, 45, or 60 minutes). Treat the header as authoritative; don't roll your own exponential backoff and ignore it — Kibo specifically advises to wait the stated time and then resume at a reduced rate.

| Status | Meaning | Action |
|---|---|---|
| `200` with response body | Success | Process the response |
| `400` | Malformed request, invalid scope combination | Do not retry — fix the request |
| `401` | Missing/expired bearer token | Flush token cache, re-auth, retry once |
| `403` | App lacks the required Behavior | Do not retry — add the Behavior in Dev Center and re-install |
| `404` | Wrong scope (catalog/site mismatch) or genuinely missing | Verify `x-vol-*` headers before concluding the resource is missing |
| `429` | Rate limit exceeded | Honour `Retry-After`; resume at reduced rate |
| `5xx` | Transient | Retry with backoff up to a cap; respect `Retry-After` when present |

`403` responses surface as a permission failure. If you're inside an API Extension and you see a permission error you don't expect, suspect the Behavior set on the App Key first and the `x-vol-*` headers second.

Source: <https://docs.kibocommerce.com/help/api-best-practices>.

## Event Subscriptions

Kibo's webhook system is called **Event Subscriptions**. Configured in Dev Center under **Develop → Applications → [app] → Packages → Events**. Topics span the entire platform (`order.*`, `payment.*`, `inventory.*`, `subscriptions.*`, `customer.account.*`, app lifecycle, etc.).

Foundational facts:

- **Payload is thin.** Kibo POSTs `eventID`, `topic`, `entityID`, `timestamp`, `correlationID`, `isTest`, and a topic-specific `extendedProperties` object — **not** the full entity.
- **20-second response deadline.** Return `200 OK` within 20 s or it's treated as a failed delivery.
- **Retry schedule** (production only — sandboxes do not retry): 5 min → 1 hr → 6 hr → 24 hr → 24 hr.
- **24 hours of continuous failure auto-disables the subscription.** After auto-disable, push-mode events are considered undeliverable (Kibo docs cite ~24-hour push expiry). Pull-mode retention is longer (community-cited ~14 days); verify the pull-mode window against your tenant before depending on it for replay.
- **At-least-once delivery** (dedupe on `eventID`), **out-of-order across topics** (don't assume `order.opened` arrives before `payment.captured`).

**Anti-Pattern (trusting payload data for state):**
```typescript
app.post('/kibo/webhook', (req, res) => {
  const { topic, entityID, extendedProperties } = req.body;
  if (topic === 'order.opened') {
    // BAD: extendedProperties does not carry full order state
    persistOrder({ id: entityID, total: extendedProperties.total });
  }
  res.sendStatus(200);
});
```

**Recommended (treat payload as a notification; read state via REST):**
```typescript
app.post('/kibo/webhook', async (req, res) => {
  // Acknowledge fast — within the 20s window
  res.sendStatus(200);

  const { eventID, topic, entityID } = req.body;
  if (await alreadyProcessed(eventID)) return;

  // Read the canonical state from Kibo by ID
  const order = await orders.getOrder({ orderId: entityID });
  await projectOrder(order);
  await markProcessed(eventID);
});
```

For the full event model (topic catalogue, HMAC story, cloud-event delivery, retry/expiry semantics in depth), see `extensions-events.md` in this skill.

Source: <https://docs.kibocommerce.com/help/event-subscription>, <https://docs.kibocommerce.com/help/event-notifications-overview>.

## API Extensions (formerly Arc.js)

API Extensions (the framework Kibo never finished rebranding — the npm package is still `mozu-node-sdk`) is **in-platform server-side JavaScript** running inside Kibo's V8 sandbox at defined hook points in the request pipeline.

Foundational facts:

- **V8 runtime, Node.js-compatible API surface.** Bundled SDK is `mozu-node-sdk`. NPM packages supported via bundling at deploy time.
- **Action types** are named `Type.Domain.Action.Occurrence` (e.g. `embedded.commerce.orders.price.after`). Twelve documented domains: `commerce.carts`, `commerce.catalog.admin`, `commerce.catalog.storefront.products`, `commerce.catalog.storefront.shipping`, `commerce.catalog.storefront.tax`, `commerce.customer`, `commerce.orders`, `commerce.payments`, `commerce.return`, `commerce.settings`, `platform.applications`, `storefront`.
- **Authoring + deployment:** Yeoman + Grunt. `yo mozu-actions` scaffolds, `grunt build` bundles, `grunt` uploads to Dev Center. Install the App on a sandbox and enable specific actions via Action Management.
- **`context.apiContext` exposes both `appClaims` and `userClaims`.** Use app claims for elevated operations; preserve user claims for calls that should reflect the shopper's session.

**Unknown — verify with Kibo support:** execution-time and memory ceilings for Extensions are not publicly documented. Community guidance is "treat it like a Lambda — sub-second, no large buffers." Confirm before shipping anything heavy, or move the work to an external service triggered by an Event Subscription.

For the full Extension model (`functions.json` manifest, callback semantics, Promise gotchas, Extension-vs-Event decision criteria), see `extensions-events.md`.

Source: <https://docs.kibocommerce.com/help/introduction-api-extensions-reference>, <https://docs.kibocommerce.com/help/the-structure-of-an-api-extension-application>.

## Known Unknowns

Surface these explicitly so the integrator doesn't blunder into them:

1. **Webhook HMAC mechanism.** Kibo's public docs do not document an HMAC signature header, signing algorithm, or per-subscription signing secret for verifying Event Subscription webhook authenticity. The Cloud Event Notification Services delivery path (GCP Pub/Sub, AWS EventBridge) sidesteps this with cloud-platform auth. For HTTPS webhook receivers, **treat all received payloads as untrusted and call back into Kibo's REST API to read state** — never trust the payload alone for a state mutation. If you have a doc-portal login, verify the current signing story with Kibo support before relying on payload authentication.

2. **API Extension execution and memory limits.** Public docs are silent on exact ceilings. Design for "Lambda-like" budgets — sub-second execution, no large buffer allocations, prefer streaming external HTTP — and confirm specifics with Kibo support before shipping anything that approaches those bounds.

3. **45-second vs 20-second webhook response deadline.** The Event Subscription overview page still cites 45 seconds; the app-specific Event Subscription pages cite 20 seconds. The docs are self-contradictory. Treat **20 seconds** as the safe ceiling for the receiver and design for the tighter budget.

5. **`expires_in` units in legacy fields.** Some older Kibo docs render token lifetimes in milliseconds. The live OAuth endpoint returns seconds. Trust the server response; don't hard-code lifetimes.

## Checklist

Before shipping any code that talks to a Kibo API:

- [ ] Tenant ID, site ID, master catalog, catalog are **all** in config — not hard-coded.
- [ ] Auth host is region- and environment-aware: `home.mozu.com` for US prod/sandbox; EU and GCP regions auth via the tenant base URL (not `home.mozu.com`) — `t{id}.sb.euw0.kibocommerce.com`, `t{id}.tp0.euw1.kibocommerce.com`, GCP `*.gcp.kibocommerce.com`. Confirm the specific values for your tenant.
- [ ] App Key and Shared Secret are in a secret manager, not committed.
- [ ] Application Behaviors are least-privilege — no "Super Admin" outside isolated dev work.
- [ ] After every Behavior change: re-installed app on sandbox, re-enabled in Dev Center, **flushed token cache**.
- [ ] Using `@kibocommerce/sdk-authentication` (directly or via `rest-sdk` / `graphql-client`) — not hand-rolled OAuth.
- [ ] One `Configuration` instance per (tenant, env) pair, reused across `Api` clients.
- [ ] Storefront calls use the site-aware hostname `t{tenant}-s{site}.{env}` and/or the GraphQL endpoint.
- [ ] Admin calls use tenant-only hostname with **all four** of `x-vol-tenant`, `x-vol-master-catalog`, `x-vol-catalog`, `x-vol-site`.
- [ ] Never send `x-vol-site` without `x-vol-master-catalog` + `x-vol-catalog`.
- [ ] REST pagination is offset (`startIndex` + `pageSize`); `pageSize ≤ 200`; stable `sortBy` for any walked dataset.
- [ ] Monetary values are decimals; arithmetic uses a decimal-safe library.
- [ ] Currency is treated as a catalog-level fact; multi-currency = multi-catalog.
- [ ] `productCode` is used where the API wants a product code; `orderId` and `orderNumber` are not interchanged.
- [ ] Cross-system foreign keys live in entity **attributes**, not in notes or arbitrary metadata.
- [ ] 429 responses respect the `Retry-After` header (discrete values 60 / 900 / 1800 / 2700 / 3600 s); no homemade backoff that ignores it.
- [ ] Webhook receiver dedupes on `eventID`, treats payload as untrusted, reads state back from REST.
- [ ] Webhook receiver returns 200 OK within 20 s; receivers are out-of-order tolerant across topics.
- [ ] GraphQL client in the browser is paired with an App that has storefront-only Behaviors.
- [ ] API Extensions are sub-second, stateless, no large buffer allocations; heavy work moved to external services triggered by Events.
