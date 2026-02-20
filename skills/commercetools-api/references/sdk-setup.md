# SDK Setup & Client Configuration

The commercetools TypeScript SDK (`@commercetools/ts-client` v3 + `@commercetools/platform-sdk`) is the recommended way to interact with the API. Getting client setup wrong causes auth failures, memory leaks, and subtle concurrency bugs that only surface under production load.

## Table of Contents
- [Required Packages](#required-packages)
- [Client Credentials Flow (Server-Side)](#client-credentials-flow-server-side)
- [Singleton Client Pattern](#singleton-client-pattern)
- [Password Flow (Customer Authentication)](#password-flow-customer-authentication)
- [Anonymous Session Flow](#anonymous-session-flow)
- [Production Middleware Stack](#production-middleware-stack)
  - [HTTP Retry Configuration](#http-retry-configuration)
  - [Concurrent Modification Middleware](#concurrent-modification-middleware)
  - [Queue Middleware (Request Throttling)](#queue-middleware-request-throttling)
  - [Correlation ID Middleware](#correlation-id-middleware)
- [Optimistic Concurrency Control](#optimistic-concurrency-control)
- [Batching Update Actions](#batching-update-actions)
- [GraphQL via the SDK](#graphql-via-the-sdk)
- [Region-Specific Endpoints](#region-specific-endpoints)
- [Checklist](#checklist)

## Required Packages

```bash
npm install @commercetools/ts-client @commercetools/platform-sdk
```

The v2 client (`@commercetools/sdk-client-v2`) was deprecated October 2024. Do not use it for new projects.

## Client Credentials Flow (Server-Side)

The standard pattern for backend services. Tokens are automatically fetched and refreshed by the auth middleware.

**Anti-Pattern (hardcoded credentials, no middleware):**
```typescript
// DO NOT hardcode credentials or create raw HTTP calls
const token = await fetch('https://auth.commercetools.com/oauth/token', {
  method: 'POST',
  body: `grant_type=client_credentials&scope=manage_project:my-project`,
  headers: {
    Authorization: `Basic ${btoa('clientId:clientSecret')}`,
  },
});
// Manual token management is fragile and error-prone
```

**Recommended (middleware-based client):**
```typescript
import {
  ClientBuilder,
  type AuthMiddlewareOptions,
  type HttpMiddlewareOptions,
} from '@commercetools/ts-client';
import { createApiBuilderFromCtpClient } from '@commercetools/platform-sdk';

const projectKey = process.env.CTP_PROJECT_KEY!;

const authMiddlewareOptions: AuthMiddlewareOptions = {
  host: 'https://auth.europe-west1.gcp.commercetools.com',
  projectKey,
  credentials: {
    clientId: process.env.CTP_CLIENT_ID!,
    clientSecret: process.env.CTP_CLIENT_SECRET!,
  },
  scopes: [`manage_project:${projectKey}`],
  httpClient: fetch,
};

const httpMiddlewareOptions: HttpMiddlewareOptions = {
  host: 'https://api.europe-west1.gcp.commercetools.com',
  httpClient: fetch,
};

const client = new ClientBuilder()
  .withProjectKey(projectKey)
  .withClientCredentialsFlow(authMiddlewareOptions)
  .withHttpMiddleware(httpMiddlewareOptions)
  .withLoggerMiddleware() // optional: logs request/response for debugging
  .build();

const apiRoot = createApiBuilderFromCtpClient(client).withProjectKey({
  projectKey,
});

export { apiRoot, projectKey };
```

**Why This Matters:** The middleware chain handles token lifecycle, retries, and error handling automatically. Manual token management leads to expired tokens in production and race conditions when multiple requests refresh simultaneously.

## Singleton Client Pattern

**Anti-Pattern (new client per request):**
```typescript
// Creating a new client for every API call leaks memory and tokens
async function getOrder(orderId: string) {
  const client = new ClientBuilder()
    .withClientCredentialsFlow(authOptions)
    .withHttpMiddleware(httpOptions)
    .build();
  const apiRoot = createApiBuilderFromCtpClient(client)
    .withProjectKey({ projectKey });
  return apiRoot.orders().withId({ ID: orderId }).get().execute();
}
```

**Recommended (shared singleton):**
```typescript
// client.ts — create once, export and reuse everywhere
import { ClientBuilder } from '@commercetools/ts-client';
import { createApiBuilderFromCtpClient } from '@commercetools/platform-sdk';

const projectKey = process.env.CTP_PROJECT_KEY!;

const client = new ClientBuilder()
  .withProjectKey(projectKey)
  .withClientCredentialsFlow(authMiddlewareOptions)
  .withHttpMiddleware(httpMiddlewareOptions)
  .build();

export const apiRoot = createApiBuilderFromCtpClient(client).withProjectKey({
  projectKey,
});
```

**Why This Matters:** Each `ClientBuilder.build()` creates a new auth token manager. Creating one per request leads to token exhaustion and memory leaks in long-running services.

## Password Flow (Customer Authentication)

Used when authenticating a specific customer for `/me` endpoints.

```typescript
import {
  ClientBuilder,
  type PasswordAuthMiddlewareOptions,
} from '@commercetools/ts-client';

const passwordFlowOptions: PasswordAuthMiddlewareOptions = {
  host: 'https://auth.europe-west1.gcp.commercetools.com',
  projectKey,
  credentials: {
    clientId: process.env.CTP_CLIENT_ID!,
    clientSecret: process.env.CTP_CLIENT_SECRET!,
    user: {
      username: customerEmail,
      password: customerPassword,
    },
  },
  scopes: [`manage_my_profile:${projectKey}`],
  httpClient: fetch,
};

const customerClient = new ClientBuilder()
  .withPasswordFlow(passwordFlowOptions)
  .withHttpMiddleware(httpMiddlewareOptions)
  .build();

const customerApiRoot = createApiBuilderFromCtpClient(customerClient)
  .withProjectKey({ projectKey });
```

## Anonymous Session Flow

For guest checkout. Can be merged with a customer account later.

```typescript
import {
  ClientBuilder,
  type AuthMiddlewareOptions,
} from '@commercetools/ts-client';

const anonymousFlowOptions: AuthMiddlewareOptions = {
  host: 'https://auth.europe-west1.gcp.commercetools.com',
  projectKey,
  credentials: {
    clientId: process.env.CTP_CLIENT_ID!,
    clientSecret: process.env.CTP_CLIENT_SECRET!,
    anonymousId: crypto.randomUUID(),
  },
  scopes: [`manage_my_orders:${projectKey}`],
  httpClient: fetch,
};

const anonymousClient = new ClientBuilder()
  .withAnonymousSessionFlow(anonymousFlowOptions)
  .withHttpMiddleware(httpMiddlewareOptions)
  .build();
```

## Production Middleware Stack

### HTTP Retry Configuration

```typescript
const httpMiddlewareOptions: HttpMiddlewareOptions = {
  host: 'https://api.europe-west1.gcp.commercetools.com',
  includeResponseHeaders: true,
  maskSensitiveHeaderData: true,
  includeRequestInErrorResponse: true,
  enableRetry: true,
  retryConfig: {
    maxRetries: 3,
    retryDelay: 200,
    backoff: true,
    retryCodes: [503],
  },
  httpClient: fetch,
};
```

### Concurrent Modification Middleware

Automatically retries on 409 version conflicts. Essential for high-concurrency environments.

```typescript
import {
  ClientBuilder,
  type ConcurrentModificationMiddlewareOptions,
} from '@commercetools/ts-client';

const concurrentModOptions: ConcurrentModificationMiddlewareOptions = {
  concurrentModificationHandlerFn: (version, request) => {
    const body = request.body as Record<string, any>;
    body.version = version;
    return Promise.resolve(body);
  },
};

const client = new ClientBuilder()
  .withClientCredentialsFlow(authMiddlewareOptions)
  .withConcurrentModificationMiddleware(concurrentModOptions)
  .withHttpMiddleware(httpMiddlewareOptions)
  .build();
```

### Queue Middleware (Request Throttling)

Prevents overwhelming the API with parallel requests. Default concurrency is 20.

```typescript
const client = new ClientBuilder()
  .withClientCredentialsFlow(authMiddlewareOptions)
  .withQueueMiddleware({ concurrency: 10 })
  .withHttpMiddleware(httpMiddlewareOptions)
  .build();
```

### Correlation ID Middleware

Adds a correlation ID to every request for distributed tracing.

```typescript
import { randomUUID } from 'crypto';
import {
  ClientBuilder,
  type CorrelationIdMiddlewareOptions,
} from '@commercetools/ts-client';

const correlationOptions: CorrelationIdMiddlewareOptions = {
  generate: () => randomUUID(),
};

const client = new ClientBuilder()
  .withClientCredentialsFlow(authMiddlewareOptions)
  .withCorrelationIdMiddleware(correlationOptions)
  .withHttpMiddleware(httpMiddlewareOptions)
  .build();
```

## Optimistic Concurrency Control

Every mutable resource in commercetools has a `version` field. All update and delete operations require the current version. This is the single most important concept to understand.

**Anti-Pattern (guessing versions):**
```typescript
// NEVER assume versions increment by 1
const order = await apiRoot.orders().withId({ ID: orderId }).get().execute();
await apiRoot.orders().withId({ ID: orderId }).post({
  body: {
    version: order.body.version + 1, // WRONG: background processes may change version
    actions: [{ action: 'changeOrderState', orderState: 'Confirmed' }],
  },
}).execute();
```

**Recommended (always use the returned version):**
```typescript
// Always use the version from the most recent API response
const order = await apiRoot.orders().withId({ ID: orderId }).get().execute();

const updated = await apiRoot.orders().withId({ ID: orderId }).post({
  body: {
    version: order.body.version, // Use exactly what the API returned
    actions: [{ action: 'changeOrderState', orderState: 'Confirmed' }],
  },
}).execute();

// For the next update, use updated.body.version
```

**Anti-Pattern (blind retry on 409):**
```typescript
// WRONG: retrying without checking state can double-apply changes
try {
  await apiRoot.carts().withId({ ID: cartId }).post({
    body: { version: staleVersion, actions: [{ action: 'addLineItem', sku: 'ABC' }] },
  }).execute();
} catch (e) {
  if (e.statusCode === 409) {
    // Blindly retrying might add the line item twice!
    const fresh = await apiRoot.carts().withId({ ID: cartId }).get().execute();
    await apiRoot.carts().withId({ ID: cartId }).post({
      body: { version: fresh.body.version, actions: [{ action: 'addLineItem', sku: 'ABC' }] },
    }).execute();
  }
}
```

**Recommended (check state before retry):**
```typescript
async function addLineItemSafely(cartId: string, sku: string): Promise<Cart> {
  const cart = await apiRoot.carts().withId({ ID: cartId }).get().execute();

  // Check if item already exists (idempotency check)
  const alreadyInCart = cart.body.lineItems.some(
    (li) => li.variant?.sku === sku
  );
  if (alreadyInCart) {
    return cart.body; // Already applied, skip
  }

  try {
    const updated = await apiRoot.carts().withId({ ID: cartId }).post({
      body: {
        version: cart.body.version,
        actions: [{ action: 'addLineItem', sku }],
      },
    }).execute();
    return updated.body;
  } catch (e: any) {
    if (e.statusCode === 409) {
      // Re-fetch and check again before retrying
      return addLineItemSafely(cartId, sku);
    }
    throw e;
  }
}
```

**Why This Matters:** Background processes, API extensions, and other clients can increment a resource's version at any time. Guessing the version or blindly retrying causes silent data corruption in production.

## Batching Update Actions

**Anti-Pattern (sequential single-action updates):**
```typescript
// Each request opens a new version conflict window
await apiRoot.carts().withId({ ID: cartId }).post({
  body: { version: v1, actions: [{ action: 'setShippingAddress', address }] },
}).execute();
await apiRoot.carts().withId({ ID: cartId }).post({
  body: { version: v2, actions: [{ action: 'setBillingAddress', address }] },
}).execute();
await apiRoot.carts().withId({ ID: cartId }).post({
  body: { version: v3, actions: [{ action: 'setShippingMethod', shippingMethod }] },
}).execute();
```

**Recommended (batch into a single request):**
```typescript
const updated = await apiRoot.carts().withId({ ID: cartId }).post({
  body: {
    version: cart.body.version,
    actions: [
      { action: 'setShippingAddress', address: shippingAddress },
      { action: 'setBillingAddress', address: billingAddress },
      { action: 'setShippingMethod', shippingMethod: { typeId: 'shipping-method', id: methodId } },
    ],
  },
}).execute();
```

**Why This Matters:** Batching reduces the version conflict window from three separate windows to one. It also reduces network round trips and latency.

## GraphQL via the SDK

```typescript
const query = `
  query GetOrder($orderId: String!) {
    order(id: $orderId) {
      id
      orderNumber
      orderState
      totalPrice { centAmount currencyCode }
      lineItems {
        name(locale: "en")
        quantity
        totalPrice { centAmount currencyCode }
      }
    }
  }
`;

const result = await apiRoot
  .graphql()
  .post({
    body: {
      query,
      variables: { orderId: 'your-order-id' },
    },
  })
  .execute();
```

## Region-Specific Endpoints

commercetools operates in multiple regions. Always match your auth and API hosts.

| Region | Auth Host | API Host |
|--------|-----------|----------|
| Europe (GCP, Belgium) | `https://auth.europe-west1.gcp.commercetools.com` | `https://api.europe-west1.gcp.commercetools.com` |
| Europe (AWS, Frankfurt) | `https://auth.eu-central-1.aws.commercetools.com` | `https://api.eu-central-1.aws.commercetools.com` |
| North America (GCP, Iowa) | `https://auth.us-central1.gcp.commercetools.com` | `https://api.us-central1.gcp.commercetools.com` |
| North America (AWS, Ohio) | `https://auth.us-east-2.aws.commercetools.com` | `https://api.us-east-2.aws.commercetools.com` |
| Australia (GCP, Sydney) | `https://auth.australia-southeast1.gcp.commercetools.com` | `https://api.australia-southeast1.gcp.commercetools.com` |

Regions are completely isolated -- no data is transferred between them. Always use environment variables for region configuration so the same code runs in any region.

## Checklist

- [ ] Using `@commercetools/ts-client` (v3), not the deprecated v2 SDK
- [ ] Client is created as a singleton, not per-request
- [ ] Credentials come from environment variables, never hardcoded
- [ ] Auth and API host regions match
- [ ] Concurrent modification middleware is enabled for write-heavy services
- [ ] Queue middleware is configured for bulk operations
- [ ] Version numbers always come from the most recent API response
- [ ] Update actions are batched into single requests where possible
- [ ] Retry logic checks resource state before re-applying changes
- [ ] Logger middleware is enabled in development, disabled or rate-limited in production
