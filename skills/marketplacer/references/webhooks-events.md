# Webhooks & Events

Marketplacer's webhook system has two unusual features compared to typical webhook implementations: **payload shapes are caller-defined GraphQL queries**, and **HTTP 4xx responses auto-disable the webhook**. Both surprise integrators on first encounter. The third trap is more subtle: deduplication respects payload equality, so what you put in your query affects whether duplicate-suppression works.

## Table of Contents
- [Caller-Shaped Payloads](#caller-shaped-payloads)
- [Event Matrix (What Emits Events)](#event-matrix-what-emits-events)
- [Standard Headers](#standard-headers)
- [HMAC Signature Verification](#hmac-signature-verification)
- [Retry Policy & The 4xx Auto-Disable Trap](#retry-policy--the-4xx-auto-disable-trap)
- [Deduplication & The `updatedAt` Trap](#deduplication--the-updatedat-trap)
- [High-Volume Mode](#high-volume-mode)
- [Subscription Strategy: Catalog vs Commerce Split](#subscription-strategy-catalog-vs-commerce-split)
- [Receiver Pattern (Production-Ready)](#receiver-pattern-production-ready)
- [Seller-Side Auth Header Alternative](#seller-side-auth-header-alternative)
- [Checklist](#checklist)

## Caller-Shaped Payloads

When configuring a webhook, the operator supplies a GraphQL query with one variable: `$id: ID!`. Marketplacer injects the triggered object's ID into that variable and runs the query against the API, then POSTs the result as the webhook body.

**Without a registered query**, Marketplacer sends a minimal default payload containing just the ID. Almost always insufficient — register a query.

**Example query for `Advert` events:**
```graphql
query AdvertEvent($id: ID!) {
  node(id: $id) {
    __typename
    ... on Advert {
      id legacyId title state
      seller { id legacyId businessName externalIds { key value } }
      taxon { id name }
      variants {
        nodes {
          id legacyId sku barcode countOnHand
          optionValueIds
        }
      }
      images { id sourceUrl }
      externalIds { key value }
    }
  }
}
```

**Example query for `Invoice` events:**
```graphql
query InvoiceEvent($id: ID!) {
  node(id: $id) {
    __typename
    ... on Invoice {
      id legacyId statusFlags deliveryType
      seller { id legacyId externalIds { key value } }
      order {
        id legacyId paymentReference
        externalIds { key value }
      }
      lineItems {
        nodes {
          id quantity
          variant { id legacyId sku }
          cost { amount tax }
        }
      }
    }
  }
}
```

**Why this design is useful:** the operator controls what arrives on the wire. The webhook receiver doesn't have to make follow-up GraphQL calls to enrich the event — the query has already enriched it. This reduces per-event latency and rate-limit consumption.

**Why this design is tricky:** every field you include in the query becomes part of the deduplication signature (see below).

**Design guideline:** include in the query exactly the fields the downstream consumer needs to act on the event. Not more, not less.

## Event Matrix (What Emits Events)

| Entity | Events |
|--------|--------|
| Advert | Create, Update, Destroy |
| Variant | Create, Update, Destroy (also cascades to Advert Update) |
| Invoice | Create (on order creation), Update (on shipment, refund flow) |
| Shipment | Create, Update |
| RefundRequest | Create, Returned, Processed, Refunded, Update |
| RefundRequestLineItem | per-state |
| Seller | Create, Update, Destroy |
| Promotion | Create, Update, Destroy |
| Category | Create, Update, Destroy |
| OptionType | Create, Update, Destroy (cascades to OptionValue destroy) |
| OptionValue | Create, Update, Destroy |
| ShippingRule | Create, Update, Destroy |
| GoldenProduct | Create, Update, Destroy (cascades to Advert + Variant Update on link/unlink) |
| GoldenVariant | Create, Update, Destroy |

**Critical absence: there is no `Order` event.** Subscribe to `Invoice` for order-status-equivalent signals. See `orders-fulfillment.md`.

For the current canonical list, defer to the live event matrix at [api.marketplacer.com/docs/webhooks/eventmatrix/](https://api.marketplacer.com/docs/webhooks/eventmatrix/).

## Standard Headers

Every webhook delivery includes:

| Header | Purpose |
|--------|---------|
| `Content-Type: application/json` | Standard |
| `Idempotency-Key` | A unique key per logical event. Receiver uses this for replay-safe processing. |
| `Marketplacer-HMAC-256` | Optional — base64(HMAC-SHA256(secret, raw_body)). Present when HMAC is configured. |
| `Marketplacer-Sequence` | Monotonic sequence number for event ordering within a webhook. |
| `Marketplacer-Vertical` | Identifies which Marketplacer instance sent the event (useful when one receiver serves multiple instances). |

**Use `Idempotency-Key` for deduplication on the receiver side.** Marketplacer also dedupes server-side (see below), but receivers should not assume server-side dedup is sufficient — replays after restarts, retries after timeouts, and the high-volume mode can all produce duplicate deliveries.

## HMAC Signature Verification

Available to Operators (not to individual Sellers — sellers use the custom-header-token alternative). Configure the HMAC secret in the operator portal.

**Signature algorithm:**
```
signature = base64(HMAC-SHA256(secret, raw_request_body))
```

The `Marketplacer-HMAC-256` header carries the signature.

**Anti-pattern (parsing JSON before verifying):**
```typescript
app.post('/webhook', async (req, res) => {
  const body = req.body;             // already JSON-parsed by middleware
  const signature = req.headers['marketplacer-hmac-256'];
  const expected = crypto.createHmac('sha256', SECRET)
    .update(JSON.stringify(body))    // re-stringify — likely won't match!
    .digest('base64');
  // ...
});
```
Re-stringifying parsed JSON can produce a different byte sequence (key order, whitespace, escaping). Signature verification fails inconsistently.

**Recommended (verify against the raw bytes):**
```typescript
import crypto from 'crypto';
import express from 'express';

const app = express();

// Capture raw body for HMAC verification
app.post(
  '/webhook',
  express.raw({ type: 'application/json' }),
  (req, res) => {
    const signature = req.headers['marketplacer-hmac-256'] as string;
    if (!signature) return res.status(401).end();

    const expected = crypto
      .createHmac('sha256', process.env.MKP_WEBHOOK_SECRET!)
      .update(req.body)                 // req.body is now Buffer of raw bytes
      .digest('base64');

    // Constant-time comparison
    const sigBuf = Buffer.from(signature, 'base64');
    const expBuf = Buffer.from(expected, 'base64');
    if (sigBuf.length !== expBuf.length || !crypto.timingSafeEqual(sigBuf, expBuf)) {
      return res.status(401).end();
    }

    const event = JSON.parse(req.body.toString());
    // ... process event
    res.status(200).end();
  }
);
```

**Critical:** verify before processing. Return 401 on signature failure (not 400 — 4xx will auto-disable the webhook; 401 is the documented response for auth failure and is also treated as auto-disabling, so this is somewhat moot; the safer pattern is to verify and never let an attacker-crafted request reach processing).

**Why IP allowlisting is not enough:** Marketplacer explicitly says IP allowlisting is not supported — IPs are cloud-dynamic. HMAC is the only documented signature mechanism for Operators.

## Retry Policy & The 4xx Auto-Disable Trap

Marketplacer retries on transient failure but **disables the webhook on persistent client errors**.

| Response | Marketplacer's action |
|----------|----------------------|
| 2xx within 30 s | Success |
| Network error / timeout | Retry |
| 5xx | Retry |
| 429 | Retry |
| **4xx (other than 429)** | **Auto-disable the webhook** |
| Excessive 3xx redirects | Auto-disable |

Default retries: **25 attempts** (configurable 1–50). Up to 30-day retention. Exponential backoff: `retry_count^4` seconds, clamped between 60 s and 4 days.

**The trap:** a deploy that ships a bug causing the receiver to return 400 (e.g., "validation error: unknown event type") will auto-disable the webhook on first delivery. Production stops getting events until someone notices and re-enables. By default, no one notices for hours or days.

**Recommended receiver pattern:**

```typescript
app.post('/webhook', async (req, res) => {
  try {
    await handleEvent(req.body);
    res.status(200).end();
  } catch (err) {
    // Log and return 500 — get retries, not auto-disable
    logger.error({ err, body: req.body }, 'webhook processing failed');
    res.status(500).end();
  }
});
```

**Never return 4xx from a webhook receiver** unless the request is genuinely unauthenticated (401 — which is also auto-disabling, but the alternative is processing forged traffic). If the payload is malformed or the event type is unknown, **log and accept (return 200)** rather than reject. Marketplacer will not send well-formed events you don't expect — if you got one, it's almost always a schema evolution you missed.

**Monitor for disabled webhooks.** Add an alert that checks webhook status periodically; treat "disabled webhook" as a P1 — production data is being lost.

## Deduplication & The `updatedAt` Trap

Marketplacer dedupes at two levels:

1. **Built-in burst dedup** — collapses rapid sequential events (e.g., a flurry of `countOnHand` updates within a short window) into the last one.
2. **Opt-in "Allow Skip?" mode** — skips events whose payload is byte-identical to the previously delivered event of the same type.

The opt-in dedup is payload-equality-based. If you include `updatedAt` in your webhook query, every event has a unique timestamp and dedup never fires. This is sometimes what you want (you want every state transition delivered), but if you're using webhooks as a "let me know when this changes" signal, including timestamps defeats the purpose.

**Pattern:**

| You want | Include `updatedAt`? | Allow Skip? |
|----------|---------------------|-------------|
| Every event delivered, no skipping | Either | Off |
| Notify only when something material changed | Omit it | On |
| Dedupe but keep a recent-change timestamp | Use `recordedAt` if available, or pull from headers/server time | On |

**Recommended:** for catalog sync webhooks (Advert/Variant), turn Allow Skip on and omit `updatedAt`. The receiver doesn't need to know that "updatedAt changed" — it cares about whether the data it indexes changed.

For order/fulfillment webhooks (Invoice/Shipment/RefundRequest), turn Allow Skip off. Every state transition matters.

## High-Volume Mode

When a webhook accumulates **50,000 undelivered events**, Marketplacer flips it into **high-volume mode**. Behavior changes:

- **Successfully delivered events are immediately purged from Marketplacer's side.** Failed events are retained for 3 days.
- Replay after the fact is not possible for delivered-but-lost events.

This kicks in when the receiver is down for an extended period, or when an unusually high event rate (e.g., bulk catalog import generating thousands of Advert.update events) overwhelms steady-state processing.

**Anti-pattern:** relying on Marketplacer as the replay source of truth past 50k events. The retention window collapses to 3 days for failed events; delivered events are gone immediately.

**Recommended:**
- Maintain receiver-side durable storage of all events as they arrive. Re-process from your own store if downstream systems need replay.
- Monitor the undelivered count if Marketplacer exposes it; alert before hitting the 50k threshold.

## Subscription Strategy: Catalog vs Commerce Split

Marketplacer lets the operator register multiple webhook subscriptions, each with its own GraphQL query, `Allow Skip?` setting, and event filter. For most non-trivial integrations, **two subscriptions are cleaner than one** because catalog events and commerce events want fundamentally different dedup behavior:

| Subscription | Events | Allow Skip? | Include `updatedAt`? | Why |
|--------------|--------|-------------|----------------------|-----|
| **Catalog** | Advert, Variant, GoldenProduct, GoldenVariant, OptionType, Category | **On** | **No** | "Tell me when something I care about changed." Bulk catalog imports generate flurries of identical-content events — dedup keeps the search-index pipeline sane. |
| **Commerce** | Invoice, Shipment, RefundRequest, RemittanceAdvice, Promotion | **Off** | OK to include | Every state transition matters for fulfillment/payout. Don't dedup; you'll lose audit trail. |

This split also gives you per-lane control over the GraphQL payload query (a catalog query is enrichment-heavy; a commerce query is state-heavy), and per-lane control over the receiver's downstream fan-out (the catalog lane goes to the search index; the commerce lane goes to OMS / ERP / commerce platform).

Some operators add a **third subscription for high-volume Variant inventory updates** with Allow Skip on and a minimal payload, separate from the catalog lane — useful when stock churn would otherwise drown out lower-frequency catalog changes.

Avoid the inverse pattern: one subscription per entity type. It works, but the subscription count multiplies fast, and the per-entity tuning rarely justifies the overhead. The catalog/commerce split is the right level of granularity for most integrations.

## Receiver Pattern (Production-Ready)

```typescript
// Pseudocode for a production webhook receiver
app.post(
  '/webhook/marketplacer',
  express.raw({ type: 'application/json' }),
  async (req, res) => {
    // 1) Verify HMAC signature on raw bytes
    if (!verifyHmac(req.headers['marketplacer-hmac-256'], req.body, secret)) {
      return res.status(401).end();
    }

    const idempotencyKey = req.headers['idempotency-key'] as string;
    const sequence = req.headers['marketplacer-sequence'] as string;
    const vertical = req.headers['marketplacer-vertical'] as string;
    const event = JSON.parse(req.body.toString());

    // 2) Persist raw event before doing anything else
    try {
      await durableEventStore.insertIfNew(idempotencyKey, {
        sequence, vertical, body: req.body, receivedAt: new Date(),
      });
    } catch (err) {
      logger.error({ err }, 'durable store failed — returning 500 for retry');
      return res.status(500).end();
    }

    // 3) Acknowledge fast, process async
    res.status(200).end();

    // 4) Enqueue for processing (fire-and-forget)
    queue.enqueue('marketplacer.event', {
      idempotencyKey, sequence, vertical, event,
    });
  }
);
```

Key properties:
- **HMAC verified before any processing.**
- **Raw event persisted before ACK** — durable replay source even if downstream processing fails.
- **Fast ACK** — Marketplacer's 30-second budget is generous, but slow ACK risks timeout retries and dedup confusion.
- **Async processing** — the actual business logic (update search index, post to OMS, etc.) runs in a worker, not in the HTTP handler.
- **Idempotency** — keyed by `Idempotency-Key`. Even if the same event arrives twice, only one durable record and one downstream side-effect.

## Seller-Side Auth Header Alternative

For seller-configured webhooks, HMAC is not available. The alternative is a **custom header token**: the seller configures a header name and a static token; Marketplacer sends `<HeaderName>: <token>` with each delivery. Operator-configured webhooks can also use this if HMAC is overkill.

**Use HMAC for operator webhooks** wherever supported — static tokens leak as soon as a log file is exposed. Custom-header tokens are an acceptable fallback only when HMAC isn't an option (seller-side).

## Checklist

Before deploying any webhook receiver:

- [ ] Webhook query is registered — receivers don't rely on default minimal payloads.
- [ ] Query includes the fields the receiver actually needs, including `externalIds` for cross-system mapping.
- [ ] HMAC signature is verified against raw bytes (not re-stringified JSON), in constant time.
- [ ] Receiver returns 2xx on every well-formed delivery — including for events it doesn't recognize (log and accept).
- [ ] Receiver returns 5xx (not 4xx) on processing failure — to get retries, not auto-disable.
- [ ] Alert exists for "webhook disabled" status — treat as P1.
- [ ] Raw event is persisted before ACK; processing happens async from the HTTP handler.
- [ ] Receiver dedupes on `Idempotency-Key` — does not assume Marketplacer's server-side dedup is sufficient.
- [ ] Allow Skip? setting and `updatedAt` inclusion match the receiver's needs (catalog: skip on, timestamps off; order: skip off, timestamps on).
- [ ] Subscriptions cover Invoice / Shipment / RefundRequest — **not** Order.
- [ ] Capacity plan accounts for high-volume mode (50k undelivered → delivered-events-purged behavior).
