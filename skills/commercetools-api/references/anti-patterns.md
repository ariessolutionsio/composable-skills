# Common Anti-Patterns

A consolidated reference of the most frequent and damaging mistakes in commercetools implementations. Each anti-pattern includes the symptom, what goes wrong, and the correct approach. Use this as a quick-scan checklist during code review or debugging.

## SDK & Client Anti-Patterns

### Creating a New Client Per Request

**What goes wrong:** Each `ClientBuilder.build()` creates a new auth token manager. Creating one per request causes memory leaks and token exhaustion in long-running services.

**Anti-Pattern:**
```typescript
async function getProduct(id: string) {
  // New client on every request — leaks memory and tokens
  const client = new ClientBuilder()
    .withClientCredentialsFlow(authOptions)
    .withHttpMiddleware(httpOptions)
    .build();
  const apiRoot = createApiBuilderFromCtpClient(client)
    .withProjectKey({ projectKey });
  return apiRoot.products().withId({ ID: id }).get().execute();
}
```

**Recommended:**
```typescript
// Create once, export, reuse everywhere
const client = new ClientBuilder()
  .withClientCredentialsFlow(authOptions)
  .withHttpMiddleware(httpOptions)
  .build();
export const apiRoot = createApiBuilderFromCtpClient(client)
  .withProjectKey({ projectKey });
```

### Importing Types from the Wrong API Package

**What goes wrong:** Multiple commercetools APIs define types with the same name (e.g., `Asset` exists in the HTTP API, Import API, and Audit Log API). Importing from the wrong package causes silent runtime failures.

**Anti-Pattern:**
```typescript
// Importing from the wrong package
import { Asset } from '@commercetools/importapi-sdk'; // Wrong!
// Using this with the HTTP API causes silent serialization errors
```

**Recommended:**
```typescript
// Always use API-specific imports
import { Asset } from '@commercetools/platform-sdk'; // HTTP API
import { Asset as ImportAsset } from '@commercetools/importapi-sdk'; // Import API
```

### Custom Middleware Ordering

**What goes wrong:** `withMiddleware()` inserts custom middleware at the START of the execution chain, not the end. Custom middleware executes before built-in auth, retry, and error handling.

**Recommended:** Understand the middleware execution order. If your custom middleware depends on authentication being complete, structure it to delegate to `next()` first and process the response.

## Concurrency Anti-Patterns

### Not Including Version in Updates

**What goes wrong:** Every update and delete request fails with a 409 ConcurrentModification error.

**Anti-Pattern:**
```typescript
// Missing version field
await apiRoot.orders().withId({ ID: orderId }).post({
  body: {
    // version: ??? — omitted
    actions: [{ action: 'changeOrderState', orderState: 'Confirmed' }],
  },
}).execute(); // 400: version is required
```

### Guessing the Next Version

**What goes wrong:** Background processes, extensions, and other clients can increment the version by more than 1. Guessed versions cause 409 errors.

**Anti-Pattern:**
```typescript
const order = await apiRoot.orders().withId({ ID: orderId }).get().execute();
// WRONG: Assuming version increments by exactly 1
await apiRoot.orders().withId({ ID: orderId }).post({
  body: {
    version: order.body.version + 1, // WRONG
    actions: [{ action: 'changeOrderState', orderState: 'Confirmed' }],
  },
}).execute();
```

**Recommended:** Always use the version from the most recent API response. Never assume the increment.

### Blind Retry on 409

**What goes wrong:** The concurrent modification may have already achieved the desired state. Retrying without checking can double-apply changes (e.g., adding a line item twice).

**Recommended:** On a 409 error, re-read the resource, check if the desired change is still needed, and only then retry.

### Sequential Single-Action Updates

**What goes wrong:** Multiple sequential updates create multiple version conflict windows. Slow and prone to 409 errors under concurrent load.

**Anti-Pattern:**
```typescript
// Three separate requests where one would suffice
await update(cartId, v1, [{ action: 'setShippingAddress', address }]);
await update(cartId, v2, [{ action: 'setBillingAddress', address }]);
await update(cartId, v3, [{ action: 'setShippingMethod', shippingMethod }]);
```

**Recommended:**
```typescript
// One request with all actions batched
await update(cartId, version, [
  { action: 'setShippingAddress', address: shippingAddress },
  { action: 'setBillingAddress', address: billingAddress },
  { action: 'setShippingMethod', shippingMethod },
]);
```

## Query Anti-Patterns

### Using Products Endpoint for Storefront

**What goes wrong:** `/products` returns both staged and current data, roughly doubling the response size. Response times and bandwidth usage are significantly worse.

**Recommended:** Use `/product-projections` with `staged: false` for all user-facing applications.

### Using Query API for Product Search

**What goes wrong:** The Query API is not search-optimized. Queries on product attributes are not indexed by default and become extremely slow on large catalogs.

**Recommended:** Use the Product Search API for all storefront search, product listing pages, and faceted navigation.

### Expanding All References

**What goes wrong:** Response payloads balloon from kilobytes to hundreds of kilobytes. API latency increases. Query complexity score rises.

**Anti-Pattern:**
```typescript
// Expanding everything "just in case"
const order = await apiRoot.orders().withId({ ID: orderId }).get({
  queryArgs: {
    expand: [
      'lineItems[*].variant',
      'lineItems[*].variant.prices[*].customerGroup',
      'lineItems[*].variant.prices[*].channel',
      'lineItems[*].productType',
      'paymentInfo.payments[*]',
      'paymentInfo.payments[*].customer',
      'customer',
      'store',
      'state',
    ],
  },
}).execute();
```

**Recommended:** Only expand references that the consuming code actually uses. Use GraphQL for precise field selection.

### Not Omitting Total in Paginated Queries

**What goes wrong:** The `total` count computation adds overhead to every paginated query, even when the total is not displayed.

**Recommended:** Set `withTotal: false` on queries where the total count is not needed in the UI.

### High-Offset Pagination

**What goes wrong:** Offset-based pagination degrades linearly as offset increases. Offset 10,000 means the API must scan and skip 10,000 records.

**Recommended:** Use cursor-based pagination (ID-based) for large datasets. Use `where: 'id > "lastId"'` with `sort: ['id asc']`.

## Cart & Checkout Anti-Patterns

### Creating Empty Carts for Every Visitor

**What goes wrong:** Massive proliferation of empty carts. The 10,000,000 cart limit per project is consumed by carts that never had items.

**Recommended:** Only create a cart when the customer adds their first item.

### Not Freezing Cart Before Payment

**What goes wrong:** Promotions expire or prices change during the payment flow (especially redirect-based flows like 3D Secure or PayPal). The customer is charged a different amount than displayed.

**Recommended:** Freeze the cart before initiating payment. This locks all prices and prevents background recalculations.

### Reusing or Deleting Payment Resources

**What goes wrong:** Redirect-based payment methods (3D Secure, PayPal) can complete asynchronously. Deleting the Payment resource loses the webhook target and audit trail.

**Recommended:** Create a new Payment resource for each attempt. Never delete old Payments.

### Setting Store After Cart Creation

**What goes wrong:** There is no update action to set the Store on an existing Cart. The cart must be recreated.

**Recommended:** Always set the Store at cart creation time, via the store-specific endpoint.

### Deferring Shipping Address

**What goes wrong:** Without a shipping address, tax rates and shipping methods cannot be calculated. Cart totals are inaccurate throughout the shopping experience.

**Recommended:** Set at least the country in the shipping address as early as possible (even using geo-IP estimation).

## Extension Anti-Patterns

### Using Extensions for Async Work

**What goes wrong:** Extensions block the API response. If the external service is slow, the entire API call fails. This affects ALL clients, including the Merchant Center.

**Recommended:** Use Subscriptions for all asynchronous processing (emails, sync, analytics).

### Slow Extension Handlers

**What goes wrong:** Extensions have a strict 2-second timeout (10 seconds for payments). Exceeding the timeout causes the entire API call to fail.

**Recommended:** Parallelize external calls within the handler. Move complex orchestration to a BFF layer.

### One Extension Per Business Rule

**What goes wrong:** The 25-extension-per-project limit is consumed quickly. No room for new integrations.

**Recommended:** Consolidate related extensions into multi-purpose handlers with internal routing.

## Subscription Anti-Patterns

### Non-Idempotent Message Handlers

**What goes wrong:** Messages can be delivered more than once. Non-idempotent handlers cause duplicate side effects (double emails, double inventory adjustments).

**Recommended:** Use message IDs or resource version numbers to detect and ignore duplicates.

### Assuming Message Ordering

**What goes wrong:** Messages do not arrive in chronological order. "OrderShipped" can arrive before "OrderConfirmed", corrupting downstream state.

**Recommended:** Use version numbers to detect stale messages. Discard messages with a version lower than the last processed version.

### Set and Forget Subscriptions

**What goes wrong:** Subscriptions silently enter `ConfigurationError` state when the destination becomes unreachable. Notifications are lost for up to 7 days before being discarded.

**Recommended:** Monitor subscription health programmatically. Alert on any status other than "Healthy".

### Polling Instead of Subscribing

**What goes wrong:** Wasted API calls, delayed change detection, higher latency, and unnecessary load against rate limits.

**Recommended:** Use Subscriptions for change detection. Reserve polling only for initial data sync or recovery scenarios.

## Discount Anti-Patterns

### Not Configuring Promotion Prioritization

**What goes wrong:** The interaction between Product Discounts and Cart Discounts is unpredictable. The default mode may not match business intent.

**Recommended:** Explicitly configure the Promotion Prioritization setting in Project Settings.

### Direct Discounts Blocking Discount Codes

**What goes wrong:** Applying a Direct Discount to a cart silently disables all matching Cart Discounts and makes Discount Codes unusable.

**Recommended:** Understand that Direct Discounts and Discount Codes are mutually exclusive on a cart.

### Not Testing Discount Combinations

**What goes wrong:** Sort order and stacking mode interactions are subtle. Discounts that work individually may produce unexpected results when combined.

**Recommended:** Create a test matrix of discount combinations. Test the impact of sort order, stacking modes, and Product Discount + Cart Discount interactions.

## B2B Anti-Patterns

### Calling Associate Endpoints from the Frontend

**What goes wrong:** Associate endpoints verify permissions based on URL parameters but do not validate those parameters against OAuth scopes. A malicious user could access data outside their authorization.

**Recommended:** Only call Associate endpoints from trusted backend services.

### Not Modeling Business Units Upfront

**What goes wrong:** Bolting on B2B features after a B2C implementation results in an organizational model that does not support the customer's actual structure.

**Recommended:** Design the Business Unit hierarchy at the beginning of the project.

### Disabling Inheritance Accidentally

**What goes wrong:** Changing a division's `associateMode` to `Explicit` removes all inherited associates, breaking approval workflows that depend on parent-level approvers.

**Recommended:** Plan and test inheritance changes in staging before applying to production.

## Inventory Anti-Patterns

### Using quantityOnStock for Availability

**What goes wrong:** `quantityOnStock` includes reserved quantities. The storefront shows more availability than actually exists, leading to overselling.

**Recommended:** Always use `availableQuantity` to determine what can be sold.

### Assuming Returns Auto-Update Inventory

**What goes wrong:** Processing returns in commercetools does NOT automatically adjust InventoryEntry quantities. Returned products are not restocked.

**Recommended:** Implement explicit inventory reconciliation triggered by return events.

## Quick-Scan Review Checklist

- [ ] Client is a singleton (not created per request)
- [ ] Versions come from API responses (never guessed)
- [ ] Update actions are batched where possible
- [ ] 409 retries check state before re-applying
- [ ] Storefront uses Product Search API or Product Projection Search
- [ ] Product data uses `/product-projections`, not `/products`
- [ ] Reference expansion is limited to what the consumer needs
- [ ] `withTotal: false` is set when total count is not displayed
- [ ] Cart is frozen before payment
- [ ] Each payment attempt creates a new Payment resource
- [ ] Extensions complete within 2 seconds (10s for payments)
- [ ] Subscription handlers are idempotent
- [ ] Subscription health is monitored
- [ ] Discount stacking behavior is explicitly configured and tested
- [ ] Associate endpoints are called from backend only
- [ ] Inventory uses `availableQuantity`, not `quantityOnStock`
