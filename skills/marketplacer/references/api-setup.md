# API Setup & Client Configuration

The Marketplacer Operator API is GraphQL only, served per-instance. Getting the foundation wrong — auth header, scope selection, pagination, ID handling, money type — causes failures that look like business-logic bugs but are actually transport issues.

## Table of Contents
- [Endpoint Pattern](#endpoint-pattern)
- [Authentication](#authentication)
  - [API Key Generation](#api-key-generation)
  - [Auth Headers](#auth-headers)
  - [Scopes](#scopes)
  - [HMAC Mutation Signing](#hmac-mutation-signing)
  - [HTTP Basic Auth on Non-Production](#http-basic-auth-on-non-production)
- [Client Setup (TypeScript)](#client-setup-typescript)
- [Pagination](#pagination)
- [ID Conventions](#id-conventions)
- [Money & Tax](#money--tax)
- [Query Constraints](#query-constraints)
- [Rate Limits & Error Handling](#rate-limits--error-handling)
- [Multi-Instance & Multi-Region](#multi-instance--multi-region)
- [Checklist](#checklist)

## Endpoint Pattern

Each Marketplacer customer runs on its own hostname. There is no shared `api.marketplacer.com` endpoint for runtime traffic.

```
https://<INSTANCE>/graphql
```

Examples:
- `https://bestfriendbazaar.com/graphql`
- `https://marketplace.acme.com/graphql`

**Implication:** the GraphQL URL is per-environment configuration, not a constant. Production, staging, and any non-production tenants each have distinct hostnames. Treat the hostname as a deployment input alongside the API key.

## Authentication

### API Key Generation

Operator keys are generated in the admin portal under **Configuration → API Access**. Seller keys are generated in the seller portal under **Extensions → API Access**.

**Key facts:**
- Keys are **one-time reveal**. After leaving the generation page the secret is no longer retrievable. If the secret is lost, regenerate — which invalidates the old key and breaks anything using it.
- Each key has a fixed set of scopes selected at generation time. Scopes cannot be edited later.
- One key per integration is the maintainable pattern — rotating one consumer doesn't break others.

### Auth Headers

The API accepts **either** of two header forms — never both.

**Anti-Pattern (sending both headers):**
```http
Authorization: Bearer mkp_live_xxx
marketplacer-api-key: mkp_live_xxx
```
The request will be rejected.

**Recommended (one of):**
```http
Authorization: Bearer mkp_live_xxx
```
or
```http
marketplacer-api-key: mkp_live_xxx
```

**Why this matters:** when a non-production environment has HTTP Basic Auth in front, the `Authorization` header is needed for Basic Auth. Use the `marketplacer-api-key` form on those environments so the two auth layers don't collide.

### Scopes

Scopes are a resource × permission-level matrix:

| Resource (examples) | Permissions |
|--------------------|-------------|
| `adverts`, `variants`, `images` | read / write / manage |
| `orders`, `invoices`, `shipments` | read / write / manage |
| `refunds`, `payouts`, `remittance` | read / write / manage |
| `sellers`, `users` | read / write / manage |
| `webhooks` | read / write / manage |
| `categories`, `brands`, `option_types` | read / write / manage |

Unticked scopes hide the corresponding fields/mutations entirely from that key. Calls return a GraphQL error with `extensions.code === "MISSING_SCOPE"` — a specific, searchable error code that's distinct from a genuine "field does not exist" schema failure. When debugging "the field exists in the schema docs but my key gets an error," check `extensions.code` first.

```json
{
  "errors": [
    {
      "message": "...",
      "extensions": { "code": "MISSING_SCOPE" }
    }
  ]
}
```

**Recommended pattern:**
- Use a **least-privilege key per integration**: PIM sync key has catalog write but no payouts; OMS key has order/invoice/shipment read but no admin scopes.
- Store keys in your secret manager keyed by integration name, not by environment alone.

### HMAC Mutation Signing

Marketplacer documents an additional **HMAC layer for mutations** as an optional hardening step in the Operator API overview. The detailed how-to was not publicly retrievable during this skill's research; **defer to the live doc** at `https://api.marketplacer.com/docs/operator-api/` when configuring mutation signing. The webhook HMAC layer (a separate mechanism, see `webhooks-events.md`) is documented in full.

### HTTP Basic Auth on Non-Production

Non-production Marketplacer environments commonly sit behind HTTP Basic Auth, with credentials issued by the Seller Onboarding team. When present:

```http
Authorization: Basic <base64(user:pass)>
marketplacer-api-key: mkp_test_xxx
```

This is the only common case where both header forms are correct — Basic Auth in `Authorization`, API key in the direct header.

## Client Setup (TypeScript)

There is no official Marketplacer TypeScript SDK. Use native `fetch` plus a thin client wrapper. The reference Node.js example Marketplacer publishes ([github.com/marketplacer/seller-integration-nodejs](https://github.com/marketplacer/seller-integration-nodejs)) follows this same shape.

**Anti-Pattern (per-request client, leaked secrets):**
```typescript
async function getAdvert(id: string) {
  return fetch('https://acme.com/graphql', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${process.env.MKP_KEY}`, // read on every call
    },
    body: JSON.stringify({ query: `{ advert(id: "${id}") { title } }` }), // injection
  }).then(r => r.json()); // no status check, no GraphQL error handling
}
```

**Recommended (singleton client with operation runner):**
```typescript
// marketplacer/client.ts
type GraphQLResponse<T> = {
  data?: T;
  errors?: Array<{ message: string; path?: string[]; extensions?: unknown }>;
};

export type MarketplacerClient = {
  request: <T, V extends Record<string, unknown> = Record<string, never>>(
    query: string,
    variables?: V
  ) => Promise<T>;
};

export function createMarketplacerClient(opts: {
  endpoint: string;     // https://<instance>/graphql
  apiKey: string;
  basicAuth?: { user: string; pass: string }; // non-prod only
  fetchImpl?: typeof fetch;
}): MarketplacerClient {
  const f = opts.fetchImpl ?? fetch;
  return {
    async request(query, variables) {
      const headers: Record<string, string> = {
        'Content-Type': 'application/json',
        'marketplacer-api-key': opts.apiKey,
      };
      if (opts.basicAuth) {
        const token = Buffer.from(
          `${opts.basicAuth.user}:${opts.basicAuth.pass}`
        ).toString('base64');
        headers['Authorization'] = `Basic ${token}`;
      }

      const res = await f(opts.endpoint, {
        method: 'POST',
        headers,
        body: JSON.stringify({ query, variables }),
      });

      if (res.status === 429 || res.status === 503) {
        const retryAfterMs = delayFor(res);  // see Rate Limits section
        throw new MarketplacerRetryableError(res.status, retryAfterMs, await res.text());
      }
      if (!res.ok) {
        throw new MarketplacerHttpError(res.status, await res.text());
      }

      const json = (await res.json()) as GraphQLResponse<unknown>;
      if (json.errors?.length) {
        throw new MarketplacerGraphQLError(json.errors);
      }
      return json.data as never;
    },
  };
}
```

Create one client per Marketplacer instance per process. Pass it through dependency injection rather than reaching for a module-level singleton in tests.

## Pagination

Marketplacer uses **Relay-style cursor pagination** and **only supports forward paging**. There is no `before` or `last` argument.

**Anti-Pattern (offset paging, backwards paging):**
```graphql
# Does not exist
query { adverts(offset: 1000, limit: 100) { nodes { id } } }
query { adverts(last: 50, before: $cursor) { nodes { id } } }
```

**Recommended (forward cursor):**
```graphql
query AdvertPage($after: String, $first: Int = 500) {
  allAdverts(first: $first, after: $after) {
    nodes { id legacyId title }
    pageInfo { hasNextPage endCursor }
    totalCount
  }
}
```

```typescript
async function* paginate<N>(
  client: MarketplacerClient,
  query: string,
  pageSize = 500
): AsyncGenerator<N[]> {
  let after: string | null = null;
  while (true) {
    const data = await client.request<{
      allAdverts: { nodes: N[]; pageInfo: { hasNextPage: boolean; endCursor: string } };
    }>(query, { first: pageSize, after });
    yield data.allAdverts.nodes;
    if (!data.allAdverts.pageInfo.hasNextPage) return;
    after = data.allAdverts.pageInfo.endCursor;
  }
}
```

**Page size:** the documented hard cap is 20,000 but the **practical recommended ceiling is 500**. Larger pages risk timeouts on the server side; smaller pages just multiply round trips. Use 500 unless you have a measured reason to deviate.

**UI implication:** never design a UI that depends on backward paging (e.g., "previous page" in a list view). If the design requires it, materialize pages in your own datastore.

## ID Conventions

Marketplacer IDs are **opaque base64-encoded global IDs** following the Relay specification.

```
Advert ID:  QWR2ZXJ0LTEyMzQ=    (base64 of "Advert-1234")
Variant ID: VmFyaWFudC03MTM3    (base64 of "Variant-7137")
```

Every node also exposes a `legacyId` — the integer used in the admin UI and the deprecated REST API.

**Anti-Pattern (decoding base64 to extract the integer):**
```typescript
const integerId = parseInt(Buffer.from(advertId, 'base64').toString().split('-')[1], 10);
```
Marketplacer explicitly reserves the right to change the internal shape — this code breaks on the next schema evolution.

**Recommended (use what the API gives you):**
```graphql
query { advert(id: $id) { id legacyId title } }
```
- Use `id` for all subsequent API calls (writes, references in mutations).
- Use `legacyId` for human-facing display, admin URL construction, log correlation, and joining against legacy REST data only when unavoidable.

**External-system mapping:** never store another system's ID inside `metadata` — `metadata` is not queryable. Use **`ExternalIds`** (key/value pairs) on Adverts, Sellers, Orders, and Invoices. See `data-model.md` for the full pattern.

## Money & Tax

All monetary values are **integers in the lowest denomination** (cents for USD/EUR/AUD, etc.). Fractional cents are rounded silently — they do not error.

**Anti-Pattern:**
```typescript
{ amount: 19.99 }              // float
{ amount: 1999.5 }             // fractional cent — rounds
{ amount: "$19.99" }           // string with currency symbol
```

**Recommended:**
```typescript
{ amount: 1999 }               // USD $19.99 as integer cents
```

**Tax must be all-or-nothing across line items in an order.** If `cost.tax` is set on any line item, every line item must include `cost.tax`. Mixing causes order creation to fail.

## Query Constraints

- **Maximum query depth: 30 levels.** Deeply nested GraphQL (e.g., walking Order → Invoices → LineItems → Adjustments → Promotions → relatedAdverts → Variants → …) will be rejected. Restructure into multiple shallower queries.
- **No automatic HTML sanitization on returned strings.** Adverts include free-text fields. The consuming system (storefront, search index) is responsible for sanitizing before render.
- **Content-Type must be `application/json`.**

## Rate Limits & Error Handling

Marketplacer does not publish specific rate-limit numbers, but the documented signals are concrete:

| Status | Meaning | Action |
|--------|---------|--------|
| `429 Too Many Requests` | Burst rate limit hit | Respect `Retry-After` header; retry |
| `503 Service Unavailable` | High-load condition | Respect `Retry-After` header; retry |
| `4xx` (other) | Client error | Do not retry — fix the request |
| `5xx` (other) | Server error | Retry with backoff up to a cap |
| `200` with `errors[]` | GraphQL-level error | Inspect; usually do not retry |

**`Retry-After` is the canonical signal.** Both 429 and 503 responses may include a `Retry-After` header (value in seconds). The documented fallback when the header is absent is **60 seconds**, not a generic exponential backoff starting at 500 ms. Honour the header when present; fall back to 60 s otherwise.

```typescript
function delayFor(res: Response): number {
  const header = res.headers.get('retry-after');
  if (header) {
    const seconds = parseInt(header, 10);
    if (!Number.isNaN(seconds)) return seconds * 1000;
  }
  return 60_000;  // documented default
}
```

**Recommended retry policy:**
- Retriable: 429, 503, 502, 504, network-level errors.
- Non-retriable: 400, 401, 403, 404, 422; GraphQL `errors[]` with validation messages or `extensions.code === "MISSING_SCOPE"`.
- Honour `Retry-After`; otherwise 60 s; max 5 attempts. Add jitter to prevent thundering-herd retries from concurrent workers.

Surface both transport-level (`MarketplacerHttpError`) and GraphQL-level (`MarketplacerGraphQLError`) errors as distinct types. Callers handle them differently — GraphQL errors often indicate a permanent data problem.

## Multi-Instance & Multi-Region

A single Marketplacer instance represents a single marketplace running on a single hostname in a single currency. **Multi-region is implemented as multiple Marketplacer instances**, not as multiple sites under one instance.

**Implications for the integration layer:**
- The client wrapper above should be constructed per-instance and per-environment.
- Sellers in different regions are distinct records — there is no out-of-the-box "global seller" abstraction. If the same vendor sells in AU and UK, they typically have two seller accounts.
- Catalog/PIM sync targets each instance separately. A single PIM Golden Product corresponds to one Golden Product per Marketplacer instance.
- The commerce platform / OMS / ERP must know which Marketplacer instance an order/seller/advert belongs to. This goes into the foreign-key mapping (see `composable-integration.md`).

If a client expects per-order currency switching, multi-currency catalogs, or country-restricted listings beyond shipping rules, this is **not documented as a single-instance feature**. Escalate to Marketplacer's solutions team during architecture rather than building around an unverified assumption.

## Checklist

Before shipping any code that talks to Marketplacer:

- [ ] Instance hostname is per-environment configuration, not a constant.
- [ ] API key is stored in the secret manager, not in source control or `.env` committed to git.
- [ ] Auth header is either `Authorization: Bearer` **or** `marketplacer-api-key` — not both (unless Basic Auth is present).
- [ ] Key scopes match the operations the integration performs; "least privilege" applied.
- [ ] Client is constructed once per instance, not per request.
- [ ] All money values are integer lowest-denomination units.
- [ ] Tax presence is consistent across all line items in any order.
- [ ] Pagination is forward-only with `first` + `after`; page size ≤ 500.
- [ ] IDs are treated as opaque strings; `legacyId` is used only for display.
- [ ] External system keys live in `ExternalIds`, not `metadata`.
- [ ] 429 and 503 are retried respecting the `Retry-After` header (default 60 s when absent); 4xx (other) is not.
- [ ] GraphQL `errors[]` are surfaced distinctly from transport errors; `extensions.code === "MISSING_SCOPE"` is treated as a permission error, not a schema error.
- [ ] HTML from Marketplacer fields is sanitized at the storefront.
