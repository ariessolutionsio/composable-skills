# Order Management

Orders in commercetools are snapshots of a cart at the moment of purchase. They track the full lifecycle from placement through fulfillment, returns, and refunds. Understanding the state machine constraints and the separation between order states, payment states, and shipment states prevents broken workflows and inconsistent data.

## Table of Contents
- [Creating Orders from Carts](#creating-orders-from-carts)
- [Order State Machine](#order-state-machine)
  - [Order State](#order-state)
  - [Payment State](#payment-state)
  - [Shipment State](#shipment-state)
- [Delivery and Parcel Tracking](#delivery-and-parcel-tracking)
  - [Adding a Parcel to an Existing Delivery](#adding-a-parcel-to-an-existing-delivery)
- [Return and Refund Workflow](#return-and-refund-workflow)
- [Order Queries](#order-queries)
  - [Query Orders with Predicates](#query-orders-with-predicates)
  - [Reference Expansion](#reference-expansion)
- [Order Edits](#order-edits)
- [Custom Order Workflows with State Machines](#custom-order-workflows-with-state-machines)
- [Sync Info (External System Tracking)](#sync-info-external-system-tracking)
- [Creating Orders from Quotes (B2B)](#creating-orders-from-quotes-b2b)
- [Checklist](#checklist)

## Creating Orders from Carts

```typescript
// Convert a cart to an order — this is the "place order" step
const order = await apiRoot.orders().post({
  body: {
    cart: { id: cartId, typeId: 'cart' },
    version: cart.version,
    orderNumber: `ORD-${Date.now()}`, // optional but recommended
  },
}).execute();
// order.body.orderState === 'Open'
// order.body.paymentState === undefined (set separately)
// order.body.shipmentState === undefined (set separately)
```

After order creation, the cart transitions to `Ordered` state and becomes immutable.

## Order State Machine

commercetools has three independent state dimensions on an order. They are changed independently.

### Order State

Tracks the overall order lifecycle.

| State | Meaning | Transitions To |
|-------|---------|----------------|
| `Open` | Newly created, awaiting processing | `Confirmed`, `Cancelled` |
| `Confirmed` | Accepted for fulfillment | `Complete`, `Cancelled` |
| `Complete` | Fully fulfilled | (terminal) |
| `Cancelled` | Cancelled before completion | (terminal) |

```typescript
// Confirm an order
const confirmed = await apiRoot.orders().withId({ ID: orderId }).post({
  body: {
    version: order.version,
    actions: [{ action: 'changeOrderState', orderState: 'Confirmed' }],
  },
}).execute();
```

### Payment State

Tracks financial status. Set independently from order state.

| State | Meaning |
|-------|---------|
| `BalanceDue` | Payment expected but not received |
| `Pending` | Payment initiated, awaiting confirmation |
| `Paid` | Full payment received |
| `Failed` | Payment attempt failed |
| `CreditOwed` | Refund pending or overpayment |

```typescript
const paid = await apiRoot.orders().withId({ ID: orderId }).post({
  body: {
    version: confirmed.body.version,
    actions: [{ action: 'changePaymentState', paymentState: 'Paid' }],
  },
}).execute();
```

### Shipment State

Tracks physical fulfillment status.

| State | Meaning |
|-------|---------|
| `Pending` | Not yet shipped |
| `Ready` | Packed and ready to ship |
| `Shipped` | Handed to carrier |
| `Delivered` | Confirmed delivered |
| `Delayed` | Shipment delayed |
| `Partial` | Partial shipment |
| `Backorder` | Items on backorder |

```typescript
const shipped = await apiRoot.orders().withId({ ID: orderId }).post({
  body: {
    version: paid.body.version,
    actions: [{ action: 'changeShipmentState', shipmentState: 'Shipped' }],
  },
}).execute();
```

## Delivery and Parcel Tracking

Deliveries track what items were shipped and how to track them.

```typescript
const withDelivery = await apiRoot.orders().withId({ ID: orderId }).post({
  body: {
    version: order.version,
    actions: [
      {
        action: 'addDelivery',
        items: [
          { id: order.lineItems[0].id, quantity: 2 },
        ],
        parcels: [
          {
            trackingData: {
              trackingId: 'DHL-123456789',
              carrier: 'DHL',
              isReturn: false,
            },
            measurements: {
              heightInMillimeter: 100,
              widthInMillimeter: 200,
              lengthInMillimeter: 300,
              weightInGram: 500,
            },
          },
        ],
      },
    ],
  },
}).execute();
```

### Adding a Parcel to an Existing Delivery

```typescript
await apiRoot.orders().withId({ ID: orderId }).post({
  body: {
    version: currentVersion,
    actions: [
      {
        action: 'addParcelToDelivery',
        deliveryId: deliveryId,
        trackingData: {
          trackingId: 'FEDEX-987654',
          carrier: 'FedEx',
          isReturn: false,
        },
      },
    ],
  },
}).execute();
```

## Return and Refund Workflow

Returns in commercetools are tracked as `ReturnInfo` on the order. They do NOT automatically update inventory or trigger refunds -- those must be handled separately.

**Anti-Pattern (assuming returns auto-restock):**
```typescript
// WRONG assumption: adding return info automatically updates inventory
await apiRoot.orders().withId({ ID: orderId }).post({
  body: {
    version,
    actions: [{
      action: 'addReturnInfo',
      items: [{ quantity: 1, lineItemId: 'li-1', shipmentState: 'Returned' }],
    }],
  },
}).execute();
// Inventory is NOT updated. Product still shows as out of stock.
```

**Recommended (explicit return + inventory update):**
```typescript
// Step 1: Record the return on the order
const returnAdded = await apiRoot.orders().withId({ ID: orderId }).post({
  body: {
    version: order.version,
    actions: [
      {
        action: 'addReturnInfo',
        items: [
          {
            quantity: 1,
            lineItemId: order.lineItems[0].id,
            shipmentState: 'Returned',
            comment: 'Customer return — wrong size',
          },
        ],
        returnDate: new Date().toISOString(),
        returnTrackingId: 'RET-987654321',
      },
    ],
  },
}).execute();

// Step 2: Update return payment state
const returnItems = returnAdded.body.returnInfo[0].items;
const refunded = await apiRoot.orders().withId({ ID: orderId }).post({
  body: {
    version: returnAdded.body.version,
    actions: [
      {
        action: 'setReturnPaymentState',
        returnItemId: returnItems[0].id,
        paymentState: 'Refunded',
      },
    ],
  },
}).execute();

// Step 3: Update return shipment state
await apiRoot.orders().withId({ ID: orderId }).post({
  body: {
    version: refunded.body.version,
    actions: [
      {
        action: 'setReturnShipmentState',
        returnItemId: returnItems[0].id,
        shipmentState: 'BackInStock',
      },
    ],
  },
}).execute();

// Step 4: Update inventory SEPARATELY
// This is NOT automatic — you must do it yourself
await apiRoot.inventory().withId({ ID: inventoryEntryId }).post({
  body: {
    version: inventoryVersion,
    actions: [
      { action: 'addQuantity', quantity: 1 },
    ],
  },
}).execute();

// Step 5: Process refund through PSP SEPARATELY
await apiRoot.payments().withId({ ID: paymentId }).post({
  body: {
    version: paymentVersion,
    actions: [
      {
        action: 'addTransaction',
        transaction: {
          type: 'Refund',
          amount: { currencyCode: 'EUR', centAmount: 2999 },
          state: 'Initial',
        },
      },
    ],
  },
}).execute();
```

**Why This Matters:** Returns do not trigger inventory restocking or PSP refunds. Missing either step causes inventory counts to drift from reality and customers to wait indefinitely for refunds.

## Order Queries

### Query Orders with Predicates

```typescript
// Find orders by customer
const customerOrders = await apiRoot.orders().get({
  queryArgs: {
    where: `customerId="${customerId}"`,
    sort: ['createdAt desc'],
    limit: 20,
  },
}).execute();

// Find orders by state
const pendingOrders = await apiRoot.orders().get({
  queryArgs: {
    where: 'orderState="Open" and paymentState="Paid"',
    sort: ['createdAt asc'],
    limit: 50,
  },
}).execute();

// Find orders by date range
const recentOrders = await apiRoot.orders().get({
  queryArgs: {
    where: `createdAt > "2025-01-01T00:00:00.000Z"`,
    sort: ['createdAt desc'],
    limit: 100,
  },
}).execute();
```

### Reference Expansion

```typescript
// Expand payment and customer references in a single request
const orderWithDetails = await apiRoot.orders().withId({ ID: orderId }).get({
  queryArgs: {
    expand: [
      'paymentInfo.payments[*]',
      'customer',
      'lineItems[*].variant',
    ],
  },
}).execute();
```

## Order Edits

Order Edits allow modifications to orders after creation without directly mutating the order. They create a "staged" version that can be previewed and then applied.

**Anti-Pattern (direct mutation without audit):**
```typescript
// Direct order updates lose the ability to preview and approve changes
await apiRoot.orders().withId({ ID: orderId }).post({
  body: {
    version,
    actions: [
      { action: 'changeLineItemQuantity', lineItemId: 'li-1', quantity: 3 },
    ],
  },
}).execute();
```

**Recommended (use Order Edits for auditable changes):**
```typescript
// Step 1: Create an Order Edit
const orderEdit = await apiRoot.orders().edits().post({
  body: {
    resource: { typeId: 'order', id: orderId },
    stagedActions: [
      {
        action: 'changeLineItemQuantity',
        lineItemId: 'li-1',
        quantity: 3,
      },
    ],
  },
}).execute();

// Step 2: Preview the impact (dry run)
// The edit.result shows what the order would look like after applying

// Step 3: Apply the edit
await apiRoot.orders().edits().withId({ ID: orderEdit.body.id }).post({
  body: {
    version: orderEdit.body.version,
    actions: [
      {
        action: 'apply',
        editVersion: orderEdit.body.version,
        resourceVersion: currentOrderVersion,
      },
    ],
  },
}).execute();
```

**Important:** Order Edits do NOT trigger standard Order update subscription notifications. Subscribe to the `OrderEditApplied` message type separately if downstream systems need to react.

## Custom Order Workflows with State Machines

For complex workflows beyond the built-in states, use custom State resources.

```typescript
// Create custom states for a fulfillment workflow
const awaitingFulfillment = await apiRoot.states().post({
  body: {
    key: 'awaiting-fulfillment',
    type: 'OrderState',
    name: { en: 'Awaiting Fulfillment' },
    initial: true,
    transitions: [
      { typeId: 'state', key: 'picking' },
      { typeId: 'state', key: 'cancelled' },
    ],
  },
}).execute();

// Transition an order to a custom state
await apiRoot.orders().withId({ ID: orderId }).post({
  body: {
    version: order.version,
    actions: [
      {
        action: 'transitionState',
        state: { typeId: 'state', key: 'picking' },
      },
    ],
  },
}).execute();
```

## Sync Info (External System Tracking)

Track synchronization with external systems (ERP, WMS, etc.).

```typescript
await apiRoot.orders().withId({ ID: orderId }).post({
  body: {
    version: order.version,
    actions: [
      {
        action: 'updateSyncInfo',
        channel: { typeId: 'channel', key: 'erp-channel' },
        externalId: 'ERP-ORDER-12345',
        syncedAt: new Date().toISOString(),
      },
    ],
  },
}).execute();
```

## Creating Orders from Quotes (B2B)

```typescript
const quoteOrder = await apiRoot.orders().post({
  body: {
    quote: { typeId: 'quote', id: acceptedQuoteId },
    version: quoteVersion,
    quoteStateToAccepted: true,
  },
}).execute();
```

## Checklist

- [ ] Order numbers are unique and meaningful (not just UUIDs)
- [ ] Order state, payment state, and shipment state are managed independently
- [ ] Returns explicitly trigger inventory updates (not automatic)
- [ ] Returns explicitly trigger PSP refund transactions (not automatic)
- [ ] Order Edit subscriptions (`OrderEditApplied`) are configured if needed
- [ ] Custom state machines define valid transitions upfront
- [ ] Delivery tracking data includes carrier and tracking ID
- [ ] Payment references are expanded when displaying order details
- [ ] Sync info tracks which external systems have received the order
- [ ] Order queries use predicates and sorting, not client-side filtering
