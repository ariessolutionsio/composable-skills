# Cart & Checkout Patterns

The cart is the most heavily modified resource in any commercetools implementation. It accumulates line items, addresses, shipping methods, discounts, payment references, and tax data -- all of which interact with each other. Getting the lifecycle wrong causes price discrepancies, failed order creation, and payment inconsistencies that are extremely difficult to debug in production.

## Table of Contents
- [Cart Creation](#cart-creation)
- [Setting the Store](#setting-the-store)
- [Setting the Shipping Address Early](#setting-the-shipping-address-early)
- [Line Item Operations](#line-item-operations)
- [Discount Code Application](#discount-code-application)
- [Shipping Method Selection](#shipping-method-selection)
- [Cart Recalculation](#cart-recalculation)
- [Freezing the Cart Before Payment](#freezing-the-cart-before-payment)
- [Handling PriceChanged Errors](#handling-pricechanged-errors)
- [Tax Mode Configuration](#tax-mode-configuration)
  - [Platform Tax Mode (default)](#platform-tax-mode-default)
  - [External Tax Mode](#external-tax-mode)
- [Payment Flow](#payment-flow)
  - [Creating Payment Resources](#creating-payment-resources)
  - [Transaction Types and States](#transaction-types-and-states)
  - [Payment Amount Validation](#payment-amount-validation)
- [Complete Checkout Flow](#complete-checkout-flow)
- [Checklist](#checklist)

## Cart Creation

Always set currency and country at creation time. Set a shipping address early to enable tax and shipping calculation.

**Anti-Pattern (creating carts for every visitor):**
```typescript
// DO NOT create a cart when the page loads
app.get('/storefront', async (req, res) => {
  // This creates millions of empty, unused carts
  const cart = await apiRoot.carts().post({
    body: { currency: 'EUR', country: 'DE' },
  }).execute();
  req.session.cartId = cart.body.id;
});
```

**Recommended (create on first interaction):**
```typescript
// Create the cart only when the customer adds the first item
async function addToCart(
  sessionCartId: string | undefined,
  sku: string,
  quantity: number
): Promise<Cart> {
  if (!sessionCartId) {
    // First interaction: create the cart with the item
    const response = await apiRoot.carts().post({
      body: {
        currency: 'EUR',
        country: 'DE',
        lineItems: [{ sku, quantity }],
      },
    }).execute();
    return response.body;
  }

  // Subsequent interactions: add to existing cart
  const cart = await apiRoot.carts().withId({ ID: sessionCartId }).get().execute();
  const updated = await apiRoot.carts().withId({ ID: sessionCartId }).post({
    body: {
      version: cart.body.version,
      actions: [{ action: 'addLineItem', sku, quantity }],
    },
  }).execute();
  return updated.body;
}
```

**Why This Matters:** commercetools supports up to 10,000,000 carts per project. Creating empty carts for every visitor wastes this budget and clutters analytics.

## Setting the Store

The Store must be set at cart creation. There is no update action to change it afterward.

**Anti-Pattern (setting store later):**
```typescript
// There is NO update action to set the store on an existing cart
const cart = await apiRoot.carts().post({ body: { currency: 'EUR' } }).execute();
// This will fail — no such action exists:
await apiRoot.carts().withId({ ID: cart.body.id }).post({
  body: { version: cart.body.version, actions: [{ action: 'setStore', store: { key: 'us' } }] },
}).execute(); // ERROR
```

**Recommended (set store at creation):**
```typescript
const cart = await apiRoot
  .inStoreKeyWithStoreKeyValue({ storeKey: 'us-store' })
  .carts()
  .post({
    body: {
      currency: 'USD',
      country: 'US',
    },
  })
  .execute();
```

## Setting the Shipping Address Early

**Anti-Pattern (deferring address to final step):**
```typescript
// Tax and shipping cannot be calculated without an address
// Cart shows $0.00 tax throughout shopping, then jumps at checkout
```

**Recommended (set address early, even with geo-IP estimation):**
```typescript
const cart = await apiRoot.carts().post({
  body: {
    currency: 'EUR',
    country: 'DE',
    shippingAddress: {
      country: 'DE', // Minimum: country for tax/shipping calculation
    },
    lineItems: [{ sku: 'PRODUCT-001', quantity: 1 }],
  },
}).execute();
// Tax rates and shipping methods are now calculable
```

**Why This Matters:** Without a shipping address, the cart total displayed to the customer is inaccurate. This causes "sticker shock" at checkout when taxes appear.

## Line Item Operations

```typescript
// Add a line item
const updated = await apiRoot.carts().withId({ ID: cartId }).post({
  body: {
    version: cart.version,
    actions: [
      { action: 'addLineItem', sku: 'TSHIRT-BLU-M', quantity: 2 },
    ],
  },
}).execute();

// Change quantity
const quantityChanged = await apiRoot.carts().withId({ ID: cartId }).post({
  body: {
    version: updated.body.version,
    actions: [
      {
        action: 'changeLineItemQuantity',
        lineItemId: updated.body.lineItems[0].id,
        quantity: 5,
      },
    ],
  },
}).execute();

// Remove a line item (set quantity to 0, or use removeLineItem)
const removed = await apiRoot.carts().withId({ ID: cartId }).post({
  body: {
    version: quantityChanged.body.version,
    actions: [
      { action: 'removeLineItem', lineItemId: quantityChanged.body.lineItems[0].id },
    ],
  },
}).execute();
```

## Discount Code Application

```typescript
const withDiscount = await apiRoot.carts().withId({ ID: cartId }).post({
  body: {
    version: cart.version,
    actions: [{ action: 'addDiscountCode', code: 'SAVE10' }],
  },
}).execute();

// Check if the code was actually applied
const codeInfo = withDiscount.body.discountCodes?.[0];
if (codeInfo?.state === 'DoesNotMatchCart') {
  // The code is valid but the cart does not meet the predicate conditions
  console.warn('Discount code does not match cart conditions');
}
```

## Shipping Method Selection

```typescript
const withShipping = await apiRoot.carts().withId({ ID: cartId }).post({
  body: {
    version: cart.version,
    actions: [
      {
        action: 'setShippingMethod',
        shippingMethod: { typeId: 'shipping-method', id: 'shipping-method-id' },
      },
    ],
  },
}).execute();
```

## Cart Recalculation

Force recalculation after external changes or stale data.

```typescript
const recalculated = await apiRoot.carts().withId({ ID: cartId }).post({
  body: {
    version: cart.version,
    actions: [
      {
        action: 'recalculate',
        updateProductData: true, // also refreshes product data from current projections
      },
    ],
  },
}).execute();
```

## Freezing the Cart Before Payment

**Anti-Pattern (no freeze before payment):**
```typescript
// A promotion expires during 3D Secure redirect
// Customer is charged a different amount than displayed
const order = await apiRoot.orders().post({
  body: { cart: { id: cartId, typeId: 'cart' }, version: cartVersion },
}).execute();
// May fail with PriceChanged error
```

**Recommended (freeze, then pay, then create order):**
```typescript
// Step 1: Freeze the cart to lock all prices
const frozen = await apiRoot.carts().withId({ ID: cartId }).post({
  body: {
    version: cart.version,
    actions: [{ action: 'freezeCart' }],
  },
}).execute();
// cart.cartState is now 'Frozen'
// All prices, taxes, and discounts are locked

// Step 2: Initiate payment (PSP interaction happens here)
// Prices will not change during the payment flow

// Step 3: Create order from frozen cart
const order = await apiRoot.orders().post({
  body: {
    cart: { id: frozen.body.id, typeId: 'cart' },
    version: frozen.body.version,
    orderNumber: `ORD-${Date.now()}`,
  },
}).execute();
```

**Frozen cart constraints to know:**
- No update actions allowed (except `unfreezeCart`)
- No background price recalculations
- Inventory is NOT reserved for line items
- Order creation fails if the frozen cart contains an invalid discount or tax rate
- Validate discounts and tax rates are current before freezing

## Handling PriceChanged Errors

**Anti-Pattern (ignoring price change errors):**
```typescript
try {
  await apiRoot.orders().post({
    body: { cart: { id: cartId, typeId: 'cart' }, version },
  }).execute();
} catch (e) {
  // "Something went wrong, please try again" — terrible UX
  throw new Error('Order creation failed');
}
```

**Recommended (handle price changes explicitly):**
```typescript
async function createOrderFromCart(cartId: string, version: number): Promise<Order> {
  try {
    const response = await apiRoot.orders().post({
      body: {
        cart: { id: cartId, typeId: 'cart' },
        version,
      },
    }).execute();
    return response.body;
  } catch (error: any) {
    if (error.body?.errors?.some((e: any) => e.code === 'PriceChanged')) {
      // Recalculate and show updated prices to customer
      const refreshed = await apiRoot.carts().withId({ ID: cartId }).post({
        body: {
          version: error.body?.errors?.[0]?.currentVersion ?? version,
          actions: [{ action: 'recalculate', updateProductData: true }],
        },
      }).execute();
      throw new PriceChangedError(refreshed.body);
    }
    throw error;
  }
}
```

## Tax Mode Configuration

### Platform Tax Mode (default)

commercetools calculates taxes automatically based on shipping address and configured tax categories. Requires a shipping address with at least a country.

### External Tax Mode

For external tax services (Avalara, Vertex, etc.). You must set tax rates on every line item, custom line item, and shipping method.

**Anti-Pattern (missing external tax rates):**
```typescript
// Forgetting to set tax on Custom Line Items or Shipping causes order creation to fail
await apiRoot.carts().withId({ ID: cartId }).post({
  body: {
    version,
    actions: [
      // Sets tax on line items but forgets custom line items and shipping
      { action: 'setLineItemTaxRate', lineItemId: 'li-1', externalTaxRate: taxRate },
    ],
  },
}).execute();
// Order creation will fail: "tax rate is not set for all items"
```

**Recommended (complete external tax rates):**
```typescript
// Set external tax rates on ALL taxable elements
const actions: CartUpdateAction[] = [];

// Line items
for (const lineItem of cart.lineItems) {
  actions.push({
    action: 'setLineItemTaxRate',
    lineItemId: lineItem.id,
    externalTaxRate: {
      name: 'Sales Tax',
      amount: 0.0875, // 8.75%
      country: 'US',
      state: 'CA',
      includedInPrice: false,
    },
  });
}

// Custom line items
for (const customLineItem of cart.customLineItems) {
  actions.push({
    action: 'setCustomLineItemTaxRate',
    customLineItemId: customLineItem.id,
    externalTaxRate: {
      name: 'Sales Tax',
      amount: 0.0875,
      country: 'US',
      state: 'CA',
      includedInPrice: false,
    },
  });
}

// Shipping
actions.push({
  action: 'setShippingMethodTaxRate',
  externalTaxRate: {
    name: 'Shipping Tax',
    amount: 0.0875,
    country: 'US',
    state: 'CA',
    includedInPrice: false,
  },
});

await apiRoot.carts().withId({ ID: cartId }).post({
  body: { version, actions },
}).execute();
```

**Why This Matters:** Incomplete tax data blocks order creation entirely. This is the most common cause of "order creation failed" errors in external tax implementations.

## Payment Flow

### Creating Payment Resources
**Anti-Pattern (reusing or deleting payments):**
```typescript
// WRONG: Deleting a failed payment loses the audit trail
// The PSP may still complete an async process (3D Secure, PayPal redirect)
await apiRoot.payments().withId({ ID: failedPaymentId })
  .delete({ queryArgs: { version } }).execute();

// WRONG: Updating an existing payment for a new attempt
await apiRoot.payments().withId({ ID: existingPaymentId }).post({
  body: {
    version,
    actions: [{ action: 'setMethodInfoMethod', method: 'NEW_METHOD' }],
  },
}).execute();
```

**Recommended (new Payment per attempt):**
```typescript
import { PaymentDraft } from '@commercetools/platform-sdk';

// Create a NEW payment for each attempt
const paymentDraft: PaymentDraft = {
  key: `payment-${cartId}-${Date.now()}`, // unique per attempt
  amountPlanned: {
    currencyCode: cart.totalPrice.currencyCode,
    centAmount: cart.totalPrice.centAmount,
  },
  paymentMethodInfo: {
    paymentInterface: 'STRIPE',
    method: 'CREDIT_CARD',
    name: { en: 'Credit Card' },
  },
};

const payment = await apiRoot.payments().post({ body: paymentDraft }).execute();

// Add Authorization transaction after PSP confirms
const authorized = await apiRoot.payments().withId({ ID: payment.body.id }).post({
  body: {
    version: payment.body.version,
    actions: [
      {
        action: 'addTransaction',
        transaction: {
          type: 'Authorization',
          amount: { currencyCode: 'EUR', centAmount: cart.totalPrice.centAmount },
          state: 'Success',
          interactionId: 'stripe-pi-abc123', // PSP reference
        },
      },
    ],
  },
}).execute();

// Add payment to cart
await apiRoot.carts().withId({ ID: cartId }).post({
  body: {
    version: cart.version,
    actions: [
      { action: 'addPayment', payment: { typeId: 'payment', id: payment.body.id } },
    ],
  },
}).execute();
```

**Why This Matters:** Redirect-based payment methods (3D Secure, PayPal) can complete asynchronously after the user returns. Deleting the Payment resource loses the webhook target. Always create a new Payment per attempt and iterate over all cart payments to find which succeeded.

### Transaction Types and States

| Transaction Type | Purpose |
|-----------------|---------|
| `Authorization` | Reserve funds without capturing |
| `Charge` | Capture/collect funds |
| `Refund` | Return funds to customer |
| `CancelAuthorization` | Release reserved funds |
| `Chargeback` | Customer-initiated dispute |

| Transaction State | Meaning |
|------------------|---------|
| `Initial` | Transaction created, not yet sent to PSP |
| `Pending` | Sent to PSP, awaiting confirmation |
| `Success` | PSP confirmed the transaction |
| `Failure` | PSP rejected the transaction |

### Payment Amount Validation

**Anti-Pattern (trusting the initial amount):**
```typescript
// User opens a second tab, modifies the cart, then completes payment
// The PSP charges the original amount — mismatch
```

**Recommended (validate at each step):**
```typescript
async function validatePaymentAmount(cartId: string, paymentAmount: number): Promise<boolean> {
  const cart = await apiRoot.carts().withId({ ID: cartId }).get().execute();
  return cart.body.totalPrice.centAmount === paymentAmount;
}
```

## Complete Checkout Flow

Validate cart completeness, recalculate prices, freeze the cart, process payment, and create the order.

## Checklist

- [ ] Carts are only created when the customer adds the first item
- [ ] Store is set at cart creation time (cannot be changed later)
- [ ] Shipping address is set as early as possible for accurate tax/shipping calculation
- [ ] Cart is frozen before initiating payment
- [ ] PriceChanged and TaxRateChanged errors are handled explicitly
- [ ] Every payment attempt creates a new Payment resource
- [ ] Failed payments are never deleted from the cart
- [ ] Payment amount is validated against cart total at each step
- [ ] External tax rates are set on ALL line items, custom line items, and shipping
- [ ] Update actions are batched and cart recalculation is triggered after external changes
