# Common Anti-Patterns

A quick-reference index of the most frequent and damaging mistakes in commercetools implementations. Each entry summarizes the problem and points to the domain file with the full explanation, code examples, and recommended pattern.

## Table of Contents
- [SDK & Client Anti-Patterns](#sdk--client-anti-patterns)
- [Concurrency Anti-Patterns](#concurrency-anti-patterns)
- [Query Anti-Patterns](#query-anti-patterns)
- [Cart & Checkout Anti-Patterns](#cart--checkout-anti-patterns)
- [Extension Anti-Patterns](#extension-anti-patterns)
- [Subscription Anti-Patterns](#subscription-anti-patterns)
- [Discount Anti-Patterns](#discount-anti-patterns)
- [B2B Anti-Patterns](#b2b-anti-patterns)
- [Inventory Anti-Patterns](#inventory-anti-patterns)
- [Quick-Scan Review Checklist](#quick-scan-review-checklist)

## SDK & Client Anti-Patterns

### Creating a New Client Per Request

Each `ClientBuilder.build()` creates a new auth token manager. Creating one per request causes memory leaks and token exhaustion. See `sdk-setup.md` for the correct singleton pattern.

### Importing Types from the Wrong API Package

Multiple commercetools APIs define types with the same name (e.g., `Asset`). Importing from the wrong package causes silent runtime failures. See `sdk-setup.md` for correct import conventions.

### Custom Middleware Ordering

`withMiddleware()` inserts custom middleware at the START of the execution chain, not the end. Custom middleware executes before built-in auth, retry, and error handling. See `sdk-setup.md` for middleware details.

## Concurrency Anti-Patterns

### Not Including Version in Updates

Every update and delete request requires the current resource version. Omitting it causes a 400 error. See `sdk-setup.md` for the optimistic concurrency pattern.

### Guessing the Next Version

Background processes, extensions, and other clients can increment the version by more than 1. Guessed versions cause 409 errors. Always use the version from the most recent API response. See `sdk-setup.md` for correct version handling.

### Blind Retry on 409

The concurrent modification may have already achieved the desired state. Retrying without checking can double-apply changes (e.g., adding a line item twice). See `sdk-setup.md` for the re-read-then-retry pattern.

### Sequential Single-Action Updates

Multiple sequential updates create multiple version conflict windows and are slow under concurrent load. Batch related actions into a single request. See `sdk-setup.md` for action batching.

## Query Anti-Patterns

### Using Products Endpoint for Storefront

`/products` returns both staged and current data, roughly doubling the response size. Use `/product-projections` with `staged: false` for user-facing applications. See `performance.md` for query optimization.

### Using Query API for Product Search

The Query API is not search-optimized and becomes extremely slow on large catalogs. Use the Product Search API for storefront search, listing pages, and faceted navigation. See `search-discovery.md` for search patterns.

### Expanding All References

Response payloads balloon when expanding references "just in case." Only expand what the consuming code actually uses, or use GraphQL for precise field selection. See `performance.md` for expansion guidelines.

### Not Omitting Total in Paginated Queries

The `total` count computation adds overhead to every paginated query. Set `withTotal: false` when the total count is not displayed. See `performance.md` for pagination best practices.

### High-Offset Pagination

Offset-based pagination degrades linearly as offset increases. Use cursor-based pagination (`where: 'id > "lastId"'` with `sort: ['id asc']`) for large datasets. See `performance.md` for cursor pagination.

## Cart & Checkout Anti-Patterns

### Creating Empty Carts for Every Visitor

Massive proliferation of empty carts consumes the 10,000,000 cart limit per project. Only create a cart when the customer adds their first item. See `cart-checkout.md` for the correct creation pattern.

### Not Freezing Cart Before Payment

Promotions or prices can change during redirect-based payment flows, causing the customer to be charged a different amount than displayed. Freeze the cart before initiating payment. See `cart-checkout.md` for the freeze-pay-order sequence.

### Reusing or Deleting Payment Resources

Redirect-based payments can complete asynchronously. Deleting the Payment resource loses the webhook target and audit trail. Create a new Payment resource for each attempt. See `cart-checkout.md` for payment patterns.

### Setting Store After Cart Creation

There is no update action to set the Store on an existing Cart; it must be set at creation time. See `cart-checkout.md` for store-scoped cart creation.

### Deferring Shipping Address

Without a shipping address, tax rates and shipping methods cannot be calculated, making cart totals inaccurate throughout the shopping experience. Set at least the country early. See `cart-checkout.md` for early address setting.

## Extension Anti-Patterns

### Using Extensions for Async Work

Extensions block the API response. If the external service is slow, the entire API call fails, affecting all clients including the Merchant Center. Use Subscriptions for async processing. See `extensions-subscriptions.md` for the correct split.

### Slow Extension Handlers

Extensions have a strict 2-second timeout (10 seconds for payments). Exceeding it fails the entire API call. Parallelize external calls or move orchestration to a BFF layer. See `extensions-subscriptions.md` for timeout strategies.

### One Extension Per Business Rule

The 25-extension-per-project limit is consumed quickly. Consolidate related extensions into multi-purpose handlers with internal routing. See `extensions-subscriptions.md` for consolidation patterns.

## Subscription Anti-Patterns

### Non-Idempotent Message Handlers

Messages can be delivered more than once. Non-idempotent handlers cause duplicate side effects (double emails, double inventory adjustments). Use message IDs or resource versions for deduplication. See `extensions-subscriptions.md` for idempotent handler patterns.

### Assuming Message Ordering

Messages do not arrive in chronological order. Use version numbers to detect and discard stale messages. See `extensions-subscriptions.md` for ordering strategies.

### Set and Forget Subscriptions

Subscriptions silently enter `ConfigurationError` state when the destination becomes unreachable, and notifications are lost. Monitor subscription health programmatically. See `extensions-subscriptions.md` for health monitoring.

### Polling Instead of Subscribing

Polling wastes API calls, delays change detection, and adds unnecessary load against rate limits. Use Subscriptions for change detection. See `extensions-subscriptions.md` for subscription setup.

## Discount Anti-Patterns

### Not Configuring Promotion Prioritization

The interaction between Product Discounts and Cart Discounts is unpredictable without explicit configuration. Configure the Promotion Prioritization setting in Project Settings. See `promotions-pricing.md` for prioritization details.

### Direct Discounts Blocking Discount Codes

Applying a Direct Discount to a cart silently disables all matching Cart Discounts and makes Discount Codes unusable. These are mutually exclusive on a cart. See `promotions-pricing.md` for discount interaction rules.

### Not Testing Discount Combinations

Sort order and stacking mode interactions are subtle. Discounts that work individually may produce unexpected results when combined. See `promotions-pricing.md` for testing strategies.

## B2B Anti-Patterns

### Calling Associate Endpoints from the Frontend

Associate endpoints verify permissions based on URL parameters but do not validate those parameters against OAuth scopes. Only call Associate endpoints from trusted backend services. See `b2b-patterns.md` for secure B2B patterns.

### Not Modeling Business Units Upfront

Bolting on B2B features after a B2C implementation results in an organizational model that does not support the customer's actual structure. Design the Business Unit hierarchy at project start. See `b2b-patterns.md` for hierarchy planning.

### Disabling Inheritance Accidentally

Changing a division's `associateMode` to `Explicit` removes all inherited associates, breaking approval workflows. Plan and test inheritance changes in staging first. See `b2b-patterns.md` for inheritance configuration.

## Inventory Anti-Patterns

### Using quantityOnStock for Availability

`quantityOnStock` includes reserved quantities. The storefront shows more availability than actually exists, leading to overselling. Always use `availableQuantity`. See `order-management.md` for inventory patterns.

### Assuming Returns Auto-Update Inventory

Processing returns in commercetools does NOT automatically adjust InventoryEntry quantities. Implement explicit inventory reconciliation triggered by return events. See `order-management.md` for return handling.

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
