# API Extensions, Event Subscriptions & Custom Entities

Kibo has three distinct customization surfaces — synchronous in-platform JavaScript (**API Extensions**, formerly Arc.js), asynchronous webhooks (**Event Subscriptions**), and a tenant-side JSON document store (**Custom Entities**). They look similar at a glance and they are not interchangeable; picking the wrong one is the source of most "this works in dev but melts in prod" customization stories. This file covers what each one is, when to reach for it, and the operational gotchas that bite integrations the moment they leave the sandbox.

## Table of Contents
- [The Three Customization Surfaces](#the-three-customization-surfaces)
- [Decision Matrix: Which Surface to Use](#decision-matrix-which-surface-to-use)
- [API Extensions](#api-extensions)
  - [Action Naming](#action-naming)
  - [The Context Object](#the-context-object)
  - [`mozu-node-sdk` for In-Extension Kibo Calls](#mozu-node-sdk-for-in-extension-kibo-calls)
  - [Yeoman + Grunt Deploy Pipeline](#yeoman--grunt-deploy-pipeline)
  - [Execution Limits (Unknown — Verify with Kibo)](#execution-limits-unknown--verify-with-kibo)
- [Event Subscriptions](#event-subscriptions)
  - [The Payload Shape](#the-payload-shape)
  - [Retry Policy and Auto-Disable](#retry-policy-and-auto-disable)
  - [Delivery Semantics](#delivery-semantics)
  - [Cloud Event Notification Services](#cloud-event-notification-services)
  - [Webhook Authentication (Unknown — Verify with Kibo)](#webhook-authentication-unknown--verify-with-kibo)
- [Custom Entities](#custom-entities)
- [Anti-Pattern / Recommended-Pattern Pairs](#anti-pattern--recommended-pattern-pairs)
- [Checklist](#checklist)

## The Three Customization Surfaces

| Surface | Runtime | Mode | Use for |
|---------|---------|------|---------|
| **API Extensions** (formerly Arc.js) | In-platform V8 (Node-compatible) | Synchronous — runs in the request path | Sub-100ms checkout/cart/payment customization; payload mutation; in-line validation |
| **Event Subscriptions** | Out-of-platform (your service or cloud queue) | Asynchronous — fire-and-forget HTTPS POST or cloud-event | Downstream sync (ERP, search index, email, analytics); audit |
| **Custom Entities** | Kibo storage; you read/write via REST | N/A (data store) | Configuration data, foreign-key maps, integration metadata that doesn't fit on first-class entities |

The mental model:

```
                     ┌────────────────────────┐
   Storefront ──────▶│   Kibo request path    │
                     │                        │
                     │  ┌─────────────────┐   │
                     │  │ API Extension   │   │  in-line, sub-second
                     │  │ (V8)            │   │
                     │  └────────┬────────┘   │
                     │           │ commits    │
                     │           ▼            │
                     │   (response returned)  │──┐
                     └────────────────────────┘  │
                                                 │ fires after
                                                 ▼
                                       ┌──────────────────┐
                                       │ Event Sub.       │ async, retried
                                       │ → your webhook   │
                                       │   or Pub/Sub /   │
                                       │   EventBridge    │
                                       └──────────────────┘

      ┌──────────────────────┐
      │ Custom Entities      │  config & metadata store
      │ (your data + Kibo's) │  read/write via REST
      └──────────────────────┘
```

## Decision Matrix: Which Surface to Use

| Requirement | API Extension | Event Subscription | Custom Entity |
|-------------|---------------|--------------------|---------------|
| Sub-100ms response-time budget | Yes | No — async | N/A |
| Mutate the request/response payload | Yes | No | No |
| Reject a checkout action with a reason | Yes | No (too late) | No |
| Sync an ERP / search index / CRM after the fact | No — too expensive | Yes | No |
| Long-running work (>1 s) | No | Yes (your receiver decides) | No |
| Call a slow external API | No (latency adds to checkout) | Yes (off the request path) | No |
| Store integration mapping (`our_id → kibo_code`) | No | No | Yes |
| Persist per-tenant configuration | No | No | Yes |
| At-least-once delivery | No (sync — either commits or fails) | Yes | N/A |
| Easy to test/version externally | No (in-platform) | Yes | Yes |

**Rule of thumb:**

- If the work has to happen **before** Kibo returns a response → API Extension.
- If the work can happen **after** Kibo returns a response → Event Subscription.
- If the data is **integration-side state** (mappings, config) → Custom Entity.

## API Extensions

API Extensions (the framework Kibo never finished rebranding from Arc.js — the npm package is still `mozu-node-sdk`) are **in-platform server-side JavaScript** that runs inside Kibo's V8 sandbox at named hook points in the request pipeline.

What that means in practice:

- Your JS executes **inside Kibo's infrastructure** — not in your AWS account, not in your Vercel function.
- It runs **synchronously** in the request path. Your code's execution time is added to the request's response time.
- It can **mutate the request/response payload**, **call other Kibo APIs** via the bundled SDK, and **make external HTTPS calls** within its time budget.

### Action Naming

Actions are named `Type.Domain.Action.Occurrence`:

```
embedded.commerce.carts.applyCoupon.before
embedded.commerce.carts.addItemToCart.before
embedded.commerce.orders.price.after
embedded.platform.applications.install.after
```

The exact action names available in each domain are enumerated in Kibo's Action Management UI and the public reference docs; treat the examples above as illustrative of the *shape*, not as a list you should copy verbatim into a `functions.json` without confirming the action exists in your tenant.

| Segment | Values |
|---------|--------|
| Type | `embedded` (interception) / `http` (route handling) |
| Domain | One of the 12 action domains below |
| Action | The specific operation (`applyCoupon`, `price`, `submit`, etc.) |
| Occurrence | `before` (intercept request) / `after` (post-process response) |

The twelve documented action domains:

| Domain | Used for |
|--------|----------|
| `commerce.carts` | Cart mutations (add item, apply coupon, etc.) |
| `commerce.catalog.admin` | Admin-side catalog operations |
| `commerce.catalog.storefront.products` | Storefront product reads |
| `commerce.catalog.storefront.shipping` | Storefront shipping-method/cost reads |
| `commerce.catalog.storefront.tax` | Storefront tax reads |
| `commerce.customer` | Customer account operations |
| `commerce.orders` | Order lifecycle |
| `commerce.payments` | Payment actions (auth, capture, void) |
| `commerce.return` | Returns workflow |
| `commerce.settings` | Tenant settings access |
| `platform.applications` | App lifecycle (install, uninstall) |
| `storefront` | Storefront request routing (custom URL handlers) |

The exact list of available actions per domain is best discovered in the admin UI's Action Management screen for a specific tenant; the public docs do not enumerate every action. Treat the registry as something you confirm against your sandbox before scoping work.

### The Context Object

Every extension function receives a `context` object:

```typescript
// extension.js — runs inside Kibo's V8 sandbox
module.exports = function (context, callback) {
  // Identity and scope
  const tenantId   = context.apiContext.tenantId;
  const siteId     = context.apiContext.siteId;
  const appClaims  = context.apiContext.appClaims;   // elevated app token
  const userClaims = context.apiContext.userClaims;  // shopper context

  // Configuration (set in Action Management UI)
  const config = context.configuration;              // your action-level config

  // Other extensions in the same pipeline (rare — usually leave alone)
  const exec = context.exec;
  const get  = context.get;

  // The request/response being intercepted
  const req  = context.request;
  const res  = context.response;

  // Mutate, then signal completion
  // ... your logic ...
  callback();  // call with callback(err) to fail the action
};
```

| Field | Purpose |
|-------|---------|
| `context.apiContext` | Identity + claims. `appClaims` for elevated ops; `userClaims` for shopper-scoped calls |
| `context.apiContext.tenantId`, `siteId`, `masterCatalogId`, `catalogId` | Scope context |
| `context.configuration` | Per-action JSON config (set in admin UI) — feature flags, thresholds, external endpoint URLs |
| `context.exec`, `context.get` | Inter-extension communication; usually unused |
| `context.request`, `context.response` | The intercepted payloads — mutate for `before` actions, inspect for `after` actions |

**`appClaims` vs `userClaims`** is the key decision: use `appClaims` when the extension needs to do something the shopper can't do themselves (read a back-office price list, check an inventory location's safety stock). Use `userClaims` when the operation should reflect the shopper's session and entitlements (do not let an extension impersonate elevated capability on a shopper's behalf — keep the surface honest).

### `mozu-node-sdk` for In-Extension Kibo Calls

Kibo APIs called from inside an extension use the bundled SDK:

```javascript
const Client = require('mozu-node-sdk/clients/commerce/cart');

module.exports = function (context, callback) {
  const cartClient = Client(context.apiContext);  // inherits scope + auth

  cartClient.getCart({ cartId: context.request.body.cartId })
    .then(cart => {
      // ... act on cart ...
      callback();
    })
    .catch(callback);
};
```

The SDK reads scope and auth from `context.apiContext` automatically — no manual OAuth, no manual `x-vol-*` header construction. NPM packages are supported via bundling at deploy time; the bundled extension package is a single file Kibo's V8 sandbox can execute.

### Yeoman + Grunt Deploy Pipeline

Authoring + deployment uses a Yeoman generator and Grunt:

```bash
# Scaffold a new extension
yo mozu-actions

# Bundle the extension
grunt build

# Deploy to Dev Center
grunt
```

The scaffolding sets up a `functions.json` manifest declaring which actions the extension implements, a `package.json` for npm dependencies, and the action JS files themselves. `grunt build` resolves the dependency tree into a single bundle; `grunt` uploads it.

After upload:
1. Install the Application on the target sandbox in Dev Center.
2. Enable specific actions via Action Management on the tenant.
3. Configure per-action JSON (the value that becomes `context.configuration`) via the admin UI.

The deploy loop is heavier than a typical serverless function. Iterating on an extension means rebundling and uploading; there is no "edit in browser, redeploy in 5 seconds" flow.

Source: <https://docs.kibocommerce.com/help/the-structure-of-an-api-extension-application>, <https://docs.kibocommerce.com/help/introduction-api-extensions-reference>.

### Execution Limits (Unknown — Verify with Kibo)

**Execution-time and memory ceilings for Extensions are not publicly documented.** Community guidance is "treat it like a Lambda — sub-second, no large buffers." Confirm before shipping anything heavy:

| Concern | Pragmatic budget (unverified) |
|---------|-------------------------------|
| Execution time | Aim for sub-second. The action runs in the request path — anything that pushes past 1 s is visible to the shopper |
| Memory | Avoid large buffer allocations; stream external HTTP rather than buffering full responses |
| External HTTP calls | Allowed; latency is added to the action time |
| Disk / persistent state | None — extensions are stateless across invocations |
| Concurrency | Each invocation is isolated; do not rely on in-memory state between calls |

**Recommended pattern:** treat the extension like a Lambda with a sub-second budget. If the work might exceed that, do the cheap-and-fast slice in the extension and emit an event for the heavy lifting:

```javascript
// Extension does the fast validation; emits an event for the rest.
module.exports = function (context, callback) {
  const valid = quickValidate(context.request.body);
  if (!valid) return callback(new Error('Invalid request'));

  // The heavy work happens out-of-band, triggered by a subsequent Event.
  callback();
};
```

**Verify execution and memory limits with Kibo support before shipping anything close to the line.**

### When to Use an Extension vs Something Else

| Situation | Use |
|-----------|-----|
| Sub-100ms checkout customization (custom validation, payload enrichment) | Extension |
| Inject a discount code based on session attributes at cart-create | Extension |
| Call a tax engine or fraud-scoring service in-line | Extension (within time budget) |
| Sync an ERP after order submit | Event Subscription, not extension |
| Maintain a search index | Event Subscription, not extension |
| Send a transactional email | Event Subscription, not extension |
| Multi-second business logic | External service triggered by Event Subscription |

The wrong choice goes either way: extensions for slow work add latency the shopper feels; webhooks for sub-100ms work add latency the storefront can't recover.

## Event Subscriptions

Event Subscriptions are Kibo's webhook system. Configured in Dev Center under **Develop → Applications → [app] → Packages → Events**.

Topics span the platform — `order.*`, `payment.*`, `inventory.*`, `subscriptions.*`, `customer.account.*`, `cart.*`, `category.*`, `discount.*`, `product.*`, `return.*`, `shipment.*`, `location.*`, `segment.*`, app lifecycle, and more. The full topic catalogue lives in the admin UI; treat the discovery surface as "browse the Events screen in Dev Center" rather than memorizing a list.

### The Payload Shape

The payload is **thin** by design:

```jsonc
{
  "eventID":          "abc123",
  "topic":            "order.opened",
  "entityID":         "order-guid-or-orderNumber",
  "timestamp":        "2026-05-13T14:00:00Z",
  "correlationID":    "trace-uuid",
  "isTest":           false,
  "extendedProperties": {
    // Topic-specific minimal fields — NOT the full entity.
    // Treat as hints, not as state.
  }
}
```

| Field | Purpose |
|-------|---------|
| `eventID` | Unique event identifier. Use for deduplication |
| `topic` | The event topic (e.g. `order.opened`, `payment.captured`) |
| `entityID` | ID of the affected entity — what to fetch back from REST |
| `timestamp` | When Kibo emitted the event |
| `correlationID` | Trace ID for cross-system observability |
| `isTest` | True for sandbox / test events; false in production |
| `extendedProperties` | Topic-specific minimal data; **not** the full entity |

**The payload is a notification, not state.** It tells you "something happened to this entity ID" — to act on it, fetch the full state via REST.

**Anti-pattern (trusting `extendedProperties` as the state):**

```typescript
app.post('/kibo/webhook', (req, res) => {
  const { topic, entityID, extendedProperties } = req.body;
  if (topic === 'order.opened') {
    // BAD — extendedProperties may not carry the fields you need,
    // and what's there may be stale by the time you read it.
    persistOrder({ id: entityID, total: extendedProperties.total });
  }
  res.sendStatus(200);
});
```

**Recommended (read state via REST callback, dedupe on `eventID`):**

```typescript
app.post('/kibo/webhook', async (req, res) => {
  res.sendStatus(200);  // ack within the response deadline

  const { eventID, topic, entityID } = req.body;
  if (await alreadyProcessed(eventID)) return;

  const order = await orders.getOrder({ orderId: entityID });
  await projectOrder(order);
  await markProcessed(eventID);
});
```

### Retry Policy and Auto-Disable

| Concern | Value |
|---------|-------|
| Response deadline | **20 seconds** (older docs cite 45 s; treat 20 s as the safe ceiling) |
| Retry schedule (production only) | 5 min → 1 hr → 6 hr → 24 hr → 24 hr |
| Sandboxes | **Do not retry** — single delivery attempt |
| Auto-disable | **24 hours of continuous failure auto-disables the subscription** |
| Event expiry | Push-mode events expire ~**24 hours** after subscription auto-disable; pull-mode retention is longer (~14 days, verify per tenant) |

The 24-hour auto-disable is the operational hazard. A receiver that's been down overnight wakes up to find the subscription disabled — events that happened during the outage are queued for the retry window but **new events stop arriving** until someone re-enables the subscription in Dev Center.

**Monitor for this.** A receiver that goes quiet for >24h is a signal to check the subscription status, not just the receiver's own health.

**Anti-pattern.** Re-enabling a disabled subscription and assuming Kibo will replay every event the receiver missed:

```typescript
// Wrong assumption — re-enable, all events replay.
await kibo.platform.subscriptions.enable(subscriptionId);
```

Push-mode events that aged past the ~24-hour delivery-failure window are gone (Kibo's documented push expiry); pull-mode retention is wider but tenant-specific. Events that were in the retry window when the subscription auto-disabled may or may not replay depending on where in the retry schedule they were.

**Recommended.** Treat re-enable as resumption from "now," not replay. Reconcile missed state by reading entities directly (full sweep of orders modified in the outage window, etc.) rather than expecting Kibo to backfill.

### Delivery Semantics

| Property | Behavior |
|----------|----------|
| Delivery | **At-least-once** — duplicates are possible (network, retry races). Dedupe on `eventID`. |
| Ordering | **Out-of-order across topics.** Do not assume `order.opened` arrives before `payment.captured` for the same order. |
| Ordering within a single topic | Best-effort, not guaranteed. Sort by `timestamp` when ordering matters. |
| Sandboxes vs production | Sandboxes deliver once and do not retry. Test the retry path with caution — sandbox events that fail are gone. |

**Anti-pattern.** Sequencing logic that assumes topics arrive in cause-and-effect order:

```typescript
if (topic === 'order.opened') createOrder(entityID);
if (topic === 'payment.captured') {
  const order = await db.orders.find(entityID);
  order.status = 'paid';  // wrong if order.opened hasn't arrived yet
}
```

**Recommended.** Make handlers idempotent and tolerant of arbitrary topic order:

```typescript
if (topic === 'payment.captured') {
  // Upsert. If the order doesn't exist yet, create a stub; fill it in
  // when order.opened arrives (or by reading order state via REST now).
  const order = await db.orders.findOrFetch(entityID);
  order.payments = await listPayments(entityID);
  await db.orders.save(order);
}
```

### Cloud Event Notification Services

In addition to HTTPS webhooks, Kibo supports **Cloud Event Notification Services** — events delivered to:

- **Google Cloud Pub/Sub** (your GCP project's Pub/Sub topic)
- **AWS EventBridge** (your AWS account's event bus)

Why pick cloud delivery over HTTPS webhooks:

| Concern | HTTPS webhook | Cloud delivery |
|---------|---------------|----------------|
| Authentication | **Unknown — see below** | Cloud-platform IAM (Service Account / IAM Role) |
| Reliability | Your endpoint must be reachable | Cloud queue absorbs delivery |
| Backpressure | Your endpoint must handle the rate | Queue handles bursts |
| Receiver location | Your service | Cloud-side consumers |
| Setup complexity | Endpoint URL | Cloud project + IAM grant configuration |

For high-volume integrations (think order events at scale), cloud delivery sidesteps webhook-receiver scaling and gives you a queue you can pause/replay against. For lower volume, HTTPS is simpler.

### Webhook Authentication (Unknown — Verify with Kibo)

**Kibo's public docs do not describe an HMAC signing scheme for Event Subscription webhook payloads.** No documented signature header, no signing algorithm, no per-subscription secret.

This is a meaningful gap. Without HMAC, an HTTPS webhook receiver cannot verify the payload's provenance — anyone with the receiver's URL can POST forged events.

**Mitigation (the only safe pattern):**

```typescript
app.post('/kibo/webhook', async (req, res) => {
  res.sendStatus(200);  // ack fast

  const { eventID, topic, entityID } = req.body;

  // DO NOT trust the payload. Read the entity from Kibo's REST API
  // using OAuth credentials only you and Kibo know.
  const entity = await kiboApi.read(topic, entityID);  // authoritative
  if (!entity) return;  // bogus event ID — drop silently

  await project(entity);
});
```

This sidesteps the missing HMAC story: the payload is just a hint, the state comes from an authenticated API call. A forged event can at worst trigger an unnecessary REST read.

Cloud Event Notification Services delivery (Pub/Sub, EventBridge) bypasses the HMAC question via cloud-platform IAM.

**Verify the current signing story with Kibo support before relying on payload authentication.** Absence in docs does not equal absence in product; this may have changed since this skill was written.

Source: <https://docs.kibocommerce.com/help/event-subscription>, <https://docs.kibocommerce.com/help/event-notifications-overview>.

## Custom Entities

Kibo's **Custom Entities** are a tenant-side JSON document store, useful for integration-side metadata that doesn't fit on Kibo's first-class entities.

```
EntityList   (a schema-bearing container — like a table/collection)
   │
   ▼
Entity       (a JSON document with up to 5 indexed properties)
```

Endpoints:

| Operation | Endpoint |
|-----------|----------|
| Create list | `POST /platform/entitylists` |
| Add entity | `POST /platform/entities/{listFQN}` |
| Get entity | `GET /platform/entities/{listFQN}/{id}` |
| Query | `GET /platform/entities/{listFQN}` with filter |
| Update entity | `PUT /platform/entities/{listFQN}/{id}` |

What's useful about them:

- **Up to 5 indexed properties per list.** Lets you query by those properties without scanning.
- **Tenant- or site-scoped** (configurable on the list).
- **Read/write via standard REST APIs** with the same auth + scope model as everything else.

Good fits for Custom Entities:

| Use case | Example |
|----------|---------|
| Foreign-key mappings | `{ kiboProductCode: "SKU-1234", erpItemNumber: "A0001-Z", lastSyncedAt: "..." }` |
| Per-tenant integration configuration | `{ feature: "promo-engine", enabled: true, threshold: 100 }` |
| Cross-system state Kibo doesn't track | `{ orderId: "...", erpInvoiceId: "INV-456", erpStatus: "Booked" }` |
| Lookup tables not in Kibo's schema | `{ countryCode: "US", carrierAccount: "..." }` |

**What not to put in Custom Entities:**

- Anything Kibo has a first-class entity for (orders, products, customers, etc.) — use those.
- Data you need to query with complex predicates (>5 indexed properties, joins, etc.) — that's a real database.
- High-volume transactional logs — Custom Entities are config/metadata-shaped, not log-shaped.

**Anti-pattern.** Stuffing product master data into Custom Entities:

```typescript
// Wrong — this should be on the product itself.
await entities.create({ listFQN: 'product_descriptions', body: { sku: 'X', description: 'Y' } });
```

**Recommended.** Custom Entities for foreign keys and metadata; first-class Kibo entities for product/order/customer data:

```typescript
await entities.create({
  listFQN: 'erp_product_map@my_tenant',
  body: {
    kiboProductCode: 'SKU-1234',
    erpItemNumber:   'A0001-Z',
    lastSyncedAt:    new Date().toISOString(),
  },
});
```

Source: <https://docs.kibocommerce.com/api-reference/entities/add-entity.md>.

## Anti-Pattern / Recommended-Pattern Pairs

### Using an extension for work that should be a webhook

**Anti-pattern.** Sync an ERP from inside a cart-submit extension:

```javascript
// extension.js — runs in the cart-submit path
const erp = require('our-erp-client');

module.exports = async function (context, callback) {
  const order = context.response.body;
  await erp.createOrder(order);   // adds 800ms to every checkout
  callback();
};
```

The shopper waits for the ERP. If the ERP is slow, the shopper waits longer. If the ERP is down, the checkout fails.

**Recommended.** Subscribe to `order.opened` and sync in your own service:

```typescript
// External webhook receiver
app.post('/kibo/webhook', async (req, res) => {
  res.sendStatus(200);
  const { eventID, topic, entityID } = req.body;
  if (topic !== 'order.opened') return;
  if (await alreadyProcessed(eventID)) return;

  const order = await orders.getOrder({ orderId: entityID });
  await erp.createOrder(order);
  await markProcessed(eventID);
});
```

Slow ERP no longer affects checkout. Failed ERP write is retryable in your own infrastructure.

### Trusting webhook payload state

Covered above — see [The Payload Shape](#the-payload-shape). Always read the entity back from REST; treat the payload as a notification.

### Assuming sandboxes will retry

**Anti-pattern.** Testing webhook retry logic in a sandbox:

```typescript
// In a sandbox — expecting Kibo to retry when the receiver returns 500.
app.post('/kibo/webhook', (req, res) => {
  if (Math.random() < 0.5) return res.sendStatus(500);  // flap to test retries
  // ...
});
```

Sandboxes don't retry. The flaky events are gone.

**Recommended.** Test retry behavior only in production (or a tenant configured for production-style delivery, if Kibo provides one). In sandboxes, assume one-shot delivery.

### Re-enabling an auto-disabled subscription and expecting replay

Covered above — see [Retry Policy and Auto-Disable](#retry-policy-and-auto-disable). Reconcile missed state by reading entities; do not expect Kibo to backfill.

### Storing extension state in module-level variables

**Anti-pattern.**

```javascript
// extension.js
let lastShopperId;  // wrong — invocations are isolated

module.exports = function (context, callback) {
  lastShopperId = context.apiContext.userClaims.userId;
  callback();
};
```

There is no shared memory across invocations. The variable's value is unreliable.

**Recommended.** Persist state externally — Custom Entities for config-shaped state, or a real database for anything bigger.

### Building integration mappings as custom attributes on products

**Anti-pattern.**

```typescript
await api.catalog.products.update({
  productCode: 'SKU-1234',
  body: {
    properties: [
      { attributeFQN: 'tenant~erp_item_number', values: ['A0001-Z'] },
    ],
  },
});
```

Now `erp_item_number` is in the storefront facet space and may appear in search filters. Product properties are for storefront-facing attributes.

**Recommended.** Foreign keys go in Custom Entities, not in product properties:

```typescript
await entities.create({
  listFQN: 'erp_product_map@my_tenant',
  body: { kiboProductCode: 'SKU-1234', erpItemNumber: 'A0001-Z' },
});
```

### Skipping `eventID`-based deduplication

**Anti-pattern.**

```typescript
app.post('/kibo/webhook', async (req, res) => {
  const order = await orders.getOrder({ orderId: req.body.entityID });
  await projectOrder(order);
  res.sendStatus(200);
});
```

At-least-once delivery means duplicates. The same order is projected multiple times — sometimes producing duplicate downstream actions (extra emails, extra invoices).

**Recommended.** Dedupe on `eventID`:

```typescript
app.post('/kibo/webhook', async (req, res) => {
  res.sendStatus(200);
  const { eventID, entityID } = req.body;
  if (await alreadyProcessed(eventID)) return;
  const order = await orders.getOrder({ orderId: entityID });
  await projectOrder(order);
  await markProcessed(eventID);
});
```

## Checklist

Before shipping extension / event / custom-entity code:

- [ ] Each piece of customization is in the right surface: in-platform JS for sub-100ms request-path work; webhooks for out-of-band sync; Custom Entities for integration metadata.
- [ ] API Extensions stay within a sub-second budget; heavy work emits an event for an external service to handle.
- [ ] Extensions are stateless across invocations; no module-level shared state.
- [ ] Extensions use `context.apiContext.appClaims` only when elevated capability is required; otherwise `userClaims` preserves shopper scope.
- [ ] Extension execution and memory limits are confirmed with Kibo support before shipping anything close to a Lambda-scale budget.
- [ ] Webhook receivers acknowledge with HTTP 200 within **20 seconds**; long work happens after `res.sendStatus(200)`.
- [ ] Webhook receivers dedupe on `eventID`.
- [ ] Webhook receivers treat payload as a notification; full state is read back via REST using the entity ID.
- [ ] Webhook handlers tolerate out-of-order delivery across topics (`order.opened` may arrive after `payment.captured`).
- [ ] Production subscriptions are monitored for the 24-hour auto-disable condition; alerting fires when the receiver goes quiet.
- [ ] Re-enabling a disabled subscription is paired with a reconciliation sweep, not a "Kibo will replay" assumption.
- [ ] Webhook authentication is **verified with Kibo support**; if no HMAC scheme exists, the receiver does not act on payload data without a REST callback.
- [ ] Cloud Event Notification Services (Pub/Sub / EventBridge) is the chosen delivery mode when volume, reliability, or IAM-grade auth matters.
- [ ] Custom Entities are used for foreign-key mappings and integration config — **not** for product or order data Kibo already models first-class.
- [ ] Custom Entity lists have at most 5 indexed properties used for queries; complex query needs are handed off to a real database.
- [ ] Sandboxes are not used to test retry/deduplication behavior — sandboxes do not retry; production is where the retry path is exercised.
