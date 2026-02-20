# Extensions, Subscriptions & Connect

commercetools provides three mechanisms for extending platform behavior: API Extensions (synchronous, blocking), Subscriptions (asynchronous notifications), and Connect (hosted application runtime). Choosing the wrong mechanism or misconfiguring any of these causes cascading failures that affect every API client, including the Merchant Center.

## Table of Contents
- [API Extensions vs Subscriptions](#api-extensions-vs-subscriptions)
- [API Extension Configuration](#api-extension-configuration)
  - [HTTP Destination](#http-destination)
  - [AWS Lambda Destination](#aws-lambda-destination)
  - [Extension Timeout Constraints](#extension-timeout-constraints)
  - [Extension Limits](#extension-limits)
- [Subscription Configuration](#subscription-configuration)
  - [Google Cloud Pub/Sub](#google-cloud-pubsub)
  - [AWS SQS](#aws-sqs)
  - [Other Destinations](#other-destinations)
- [Subscription Reliability](#subscription-reliability)
  - [Idempotent Message Handlers](#idempotent-message-handlers)
  - [Handling Message Ordering](#handling-message-ordering)
  - [Monitoring Subscription Health](#monitoring-subscription-health)
  - [Eventual Consistency](#eventual-consistency)
- [Connect Applications](#connect-applications)
  - [Application Types](#application-types)
  - [Post-Deploy / Pre-Undeploy Scripts](#post-deploy--pre-undeploy-scripts)
  - [Connect Deployment Models](#connect-deployment-models)
- [Checklist](#checklist)

## API Extensions vs Subscriptions

| Feature | API Extensions | Subscriptions |
|---------|---------------|---------------|
| Timing | Synchronous, before persistence | Asynchronous, after persistence |
| Blocking | Yes -- blocks the API response | No -- fire and forget |
| Timeout | 2s (general), 10s (payments) | N/A |
| Max per project | 25 | 50 |
| Can modify data | Yes, up to 100 update actions | No |
| Affects all clients | Yes (including Merchant Center) | No |
| Use for | Validation, price calculation, enrichment | Notifications, sync, analytics |

**Anti-Pattern (using extensions for async work):**
```typescript
// WRONG: Sending emails synchronously in an extension
// This blocks the entire cart update and fails if the email service is slow
const extension = await apiRoot.extensions().post({
  body: {
    key: 'order-email-extension',
    destination: {
      type: 'HTTP',
      url: 'https://email-service.example.com/send-confirmation',
    },
    triggers: [{ resourceTypeId: 'order', actions: ['Create'] }],
    timeoutInMs: 2000,
  },
}).execute();
```

**Recommended (use subscriptions for async work):**
```typescript
// Extension: only for synchronous validation/enrichment
const extension = await apiRoot.extensions().post({
  body: {
    key: 'cart-validation-extension',
    destination: {
      type: 'HTTP',
      url: 'https://validation-service.example.com/validate',
      authentication: { type: 'AuthorizationHeader', headerValue: 'Bearer secret' },
    },
    triggers: [{ resourceTypeId: 'cart', actions: ['Create', 'Update'] }],
    timeoutInMs: 2000,
  },
}).execute();

// Subscription: for async post-processing
const subscription = await apiRoot.subscriptions().post({
  body: {
    key: 'order-notifications',
    destination: {
      type: 'SQS',
      queueUrl: 'https://sqs.eu-west-1.amazonaws.com/123456789/order-events',
      region: 'eu-west-1',
      authenticationMode: 'IAM',
    },
    messages: [
      { resourceTypeId: 'order', types: ['OrderCreated', 'OrderStateChanged'] },
    ],
  },
}).execute();
```

## API Extension Configuration

### HTTP Destination

```typescript
const extension = await apiRoot.extensions().post({
  body: {
    key: 'cart-validation-extension',
    destination: {
      type: 'HTTP',
      url: 'https://my-service.example.com/api/cart-validate',
      authentication: {
        type: 'AuthorizationHeader',
        headerValue: 'Bearer my-secret-token',
      },
    },
    triggers: [
      {
        resourceTypeId: 'cart',
        actions: ['Create', 'Update'],
        condition: 'cartState = "Active"', // optional: only fire for active carts
      },
    ],
    timeoutInMs: 2000,
  },
}).execute();
```

### AWS Lambda Destination

```typescript
const lambdaExtension = await apiRoot.extensions().post({
  body: {
    key: 'payment-validation-lambda',
    destination: {
      type: 'AWSLambda',
      arn: 'arn:aws:lambda:eu-west-1:123456789:function:validate-payment',
      accessKey: process.env.AWS_ACCESS_KEY!,
      accessSecret: process.env.AWS_SECRET_KEY!,
    },
    triggers: [
      { resourceTypeId: 'payment', actions: ['Create', 'Update'] },
    ],
    timeoutInMs: 10000, // payments allow up to 10 seconds
  },
}).execute();
```

### Extension Timeout Constraints

**Anti-Pattern (slow extension):**
```typescript
// Extension handler that calls multiple external services
export async function handler(event: ExtensionInput) {
  // Calls inventory service (500ms)
  await checkInventory(event.resource);
  // Calls tax service (800ms)
  await calculateTax(event.resource);
  // Calls fraud check (1200ms)
  await fraudCheck(event.resource);
  // Total: ~2500ms — exceeds the 2000ms timeout
  // The entire API call fails
}
```

**Recommended (fast extension with parallel calls or BFF):**
```typescript
// Option 1: Parallelize calls within the timeout
export async function handler(event: ExtensionInput) {
  const [inventory, tax, fraud] = await Promise.all([
    checkInventory(event.resource),  // 500ms
    calculateTax(event.resource),     // 800ms
    fraudCheck(event.resource),       // 1200ms
  ]);
  // Total: ~1200ms (parallel) — within 2000ms timeout
  return buildResponse(inventory, tax, fraud);
}

// Option 2: Move orchestration to a BFF layer
// Do not use an extension at all — orchestrate from your backend
async function checkoutHandler(cartId: string) {
  const cart = await apiRoot.carts().withId({ ID: cartId }).get().execute();
  const [tax, shipping] = await Promise.all([
    taxService.calculate(cart.body),
    shippingService.getRates(cart.body),
  ]);
  // Apply results via update actions
  await apiRoot.carts().withId({ ID: cartId }).post({
    body: {
      version: cart.body.version,
      actions: [
        { action: 'setLineItemTaxRate', lineItemId: '...', externalTaxRate: tax },
        { action: 'setShippingMethod', shippingMethod: shipping },
      ],
    },
  }).execute();
}
```

**Why This Matters:** Extension timeouts cause the entire API call to fail with a generic error. This affects all clients, including the Merchant Center, making it impossible for business users to work. The failure also offers no retry mechanism -- the caller must retry the entire operation.

### Extension Limits

- Maximum 25 extensions per project
- Maximum 100 update actions returned per extension response
- Changes take up to 1 minute to propagate

**Anti-Pattern (one extension per rule):**
```typescript
// Using all 25 slots for individual business rules
// Extension 1: validate cart minimum
// Extension 2: validate shipping address
// Extension 3: validate inventory
// ...extension 25: no room for new integrations
```

**Recommended (consolidated extension with routing):**
```typescript
// Single extension that routes to specific handlers
export async function handler(event: ExtensionInput) {
  const actions: CartUpdateAction[] = [];

  if (event.action === 'Create' || event.action === 'Update') {
    actions.push(...validateMinimumOrder(event.resource));
    actions.push(...validateShippingAddress(event.resource));
    actions.push(...enrichLineItems(event.resource));
  }

  return {
    statusCode: 200,
    body: JSON.stringify({ actions }),
  };
}
```

## Subscription Configuration

### Google Cloud Pub/Sub

```typescript
const pubsubSubscription = await apiRoot.subscriptions().post({
  body: {
    key: 'order-events-subscription',
    destination: {
      type: 'GoogleCloudPubSub',
      topic: 'projects/my-gcp-project/topics/order-events',
      projectId: 'my-gcp-project',
    },
    messages: [
      {
        resourceTypeId: 'order',
        types: ['OrderCreated', 'OrderStateChanged'],
      },
    ],
  },
}).execute();
```

### AWS SQS

```typescript
const sqsSubscription = await apiRoot.subscriptions().post({
  body: {
    key: 'customer-events-sqs',
    destination: {
      type: 'SQS',
      queueUrl: 'https://sqs.eu-west-1.amazonaws.com/123456789/customer-events',
      region: 'eu-west-1',
      authenticationMode: 'IAM', // recommended over static credentials
    },
    messages: [
      {
        resourceTypeId: 'customer',
        types: ['CustomerCreated', 'CustomerAddressAdded'],
      },
    ],
  },
}).execute();
```

### Other Destinations

Other destinations (Azure Service Bus, EventBridge, SNS, Azure Event Grid, Confluent Cloud) follow the same pattern -- set the `destination` field to the appropriate type with its credentials.

## Subscription Reliability

### Idempotent Message Handlers

**Anti-Pattern (non-idempotent handler):**
```typescript
// WRONG: Sending a confirmation email for every message received
// Messages can be delivered more than once
async function handleOrderCreated(message: any) {
  await sendOrderConfirmation(message.resource.id);
  // Customer receives 2-3 confirmation emails
}
```

**Recommended (idempotent handler with deduplication):**
```typescript
async function handleOrderCreated(message: any) {
  const messageId = message.id; // unique per delivery attempt
  const resourceVersion = message.resourceVersion;

  // Check if we already processed this message
  const alreadyProcessed = await deduplicationStore.exists(messageId);
  if (alreadyProcessed) {
    console.log(`Skipping duplicate message: ${messageId}`);
    return;
  }

  await sendOrderConfirmation(message.resource.id);
  await deduplicationStore.record(messageId, resourceVersion);
}
```

### Handling Message Ordering

**Anti-Pattern (assuming chronological order):**
```typescript
// WRONG: Blindly applying the latest message state
async function handleOrderStateChanged(message: any) {
  // "OrderShipped" might arrive before "OrderConfirmed"
  await updateExternalSystem(message.resource.id, message.orderState);
}
```

**Recommended (version-based ordering):**
```typescript
async function handleOrderStateChanged(message: any) {
  const currentVersion = await getStoredVersion(message.resource.id);

  if (message.resourceVersion <= currentVersion) {
    console.log(`Stale message (version ${message.resourceVersion} <= ${currentVersion})`);
    return; // Skip stale updates
  }

  await updateExternalSystem(message.resource.id, message.orderState);
  await storeVersion(message.resource.id, message.resourceVersion);
}
```

### Monitoring Subscription Health

**Anti-Pattern (set and forget):**
```typescript
// Create subscription and never check on it again
// It silently enters ConfigurationError state when the queue is deleted
// Notifications are lost for up to 7 days before being discarded
```

**Recommended (active health monitoring):**
```typescript
async function checkSubscriptionHealth(): Promise<void> {
  const subscriptions = await apiRoot.subscriptions().get({
    queryArgs: { limit: 50 },
  }).execute();

  for (const sub of subscriptions.body.results) {
    if (sub.status !== 'Healthy') {
      await alertOps(
        `Subscription "${sub.key}" is unhealthy: ${sub.status}`,
        sub
      );
    }
  }
}

// Run on a schedule (e.g., every 5 minutes)
```

**Subscription health status values:**

| Status | Meaning |
|--------|---------|
| `Healthy` | Notifications delivering normally |
| `TemporaryError` | Delivery failing temporarily; system retries up to 48 hours |
| `ConfigurationError` | Destination unreachable; notifications may be lost |
| `ConfigurationErrorDeliveryStopped` | Delivery stopped after prolonged configuration errors |
| `ManuallySuspended` | Suspended due to destination issues; requires support to restore |

### Eventual Consistency

Subscription changes take up to 1 minute to propagate. Events during this window may be missed.

```typescript
// After creating a subscription, do not rely on it immediately
await apiRoot.subscriptions().post({ body: subscriptionDraft }).execute();
// Wait before expecting messages
// For critical operations, also implement polling as a fallback
```

## Connect Applications

### Application Types

| Type | Timeout | Use Case |
|------|---------|----------|
| Service | 5 minutes | HTTP endpoints, webhooks |
| Event | 5 min request / 10s ack | Subscription message processing |
| Job | 30 minutes | Scheduled tasks, batch processing |
| MC Custom App | N/A | Merchant Center extensions |
| MC Custom View | N/A | Merchant Center embedded views |
| Assets | N/A | Static file hosting with CDN |

### Post-Deploy / Pre-Undeploy Scripts

```typescript
// post-deploy.ts — creates extension after deployment
async function postDeploy() {
  try {
    const serviceUrl = process.env.CONNECT_SERVICE_URL!;

    await apiRoot.extensions().post({
      body: {
        key: 'my-connector-extension',
        destination: { type: 'HTTP', url: serviceUrl },
        triggers: [{ resourceTypeId: 'cart', actions: ['Update'] }],
      },
    }).execute();

    console.log('Extension created successfully');
  } catch (error: any) {
    process.stderr.write(`Post-deploy failed: ${error.message}\n`);
    process.exitCode = 1;
  }
}

postDeploy();
```

```typescript
// pre-undeploy.ts — cleans up extension before undeployment
async function preUndeploy() {
  try {
    const existing = await apiRoot.extensions()
      .withKey({ key: 'my-connector-extension' }).get().execute();

    await apiRoot.extensions()
      .withKey({ key: 'my-connector-extension' })
      .delete({ queryArgs: { version: existing.body.version } })
      .execute();

    console.log('Extension deleted successfully');
  } catch (error: any) {
    process.stderr.write(`Pre-undeploy failed: ${error.message}\n`);
    process.exitCode = 1;
  }
}

preUndeploy();
```

### Connect Deployment Models

| Model | Scaling | Use Case |
|-------|---------|----------|
| Preview | Scales to zero, short-lived | Development testing |
| Sandbox | Autoscale, scales to zero | Non-production environments |
| Production | Pre-warmed instances | Live traffic |

**Anti-Pattern (merging unrelated integrations):**
```typescript
// WRONG: One mega-connector for everything
// A deployment failure in the tax service breaks the email service
// connect.yaml
// applications:
//   - name: everything-service
//     (tax calculation + email + inventory sync + analytics)
```

**Recommended (separate connectors per domain):**
```
// connect.yaml for tax connector
applications:
  - name: tax-calculation-service
    // Only tax calculation logic

// connect.yaml for notification connector
applications:
  - name: notification-service
    // Only email/SMS notifications
```

## Checklist

- [ ] Extensions are used only for synchronous validation/enrichment
- [ ] Subscriptions are used for all async processing (emails, sync, analytics)
- [ ] Extension handlers complete within 2 seconds (10 seconds for payments)
- [ ] Related extensions are consolidated to stay under the 25-extension limit
- [ ] Subscription handlers are idempotent (handle duplicate messages)
- [ ] Subscription handlers use version numbers to ignore stale messages
- [ ] Subscription health is monitored programmatically
- [ ] Dead letter queues are configured for unprocessable messages
- [ ] Extension trigger conditions are used to limit unnecessary invocations
- [ ] Connect applications are separated by domain
- [ ] Connect applications are deployed to the same region as the commercetools project
- [ ] Post-deploy and pre-undeploy scripts handle resource cleanup
