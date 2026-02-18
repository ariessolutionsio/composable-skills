# Promotions & Pricing

commercetools has three distinct discount mechanisms -- Product Discounts, Cart Discounts, and Discount Codes -- each with different scoping, timing, and stacking behavior. Misconfiguring their interaction is the most common source of pricing bugs in production, often resulting in customers getting larger or smaller discounts than intended.

## Discount Types Overview

| Type | When Applied | Where Visible | Limit |
|------|-------------|---------------|-------|
| Product Discount | Before cart (on catalog prices) | PDP, PLP, search results | 500 active |
| Cart Discount | In the cart calculation | Cart, checkout | 100 active (without code) |
| Discount Code | When customer enters a code | Cart, checkout | Unlimited codes, but each activates Cart Discounts |

## Product Discounts

Product Discounts modify prices in the catalog before items enter a cart. They are eventually consistent (updates propagate with a small delay).

```typescript
const productDiscount = await apiRoot.productDiscounts().post({
  body: {
    name: { en: '20% Off Summer Collection' },
    key: 'summer-sale-20',
    value: {
      type: 'relative',
      permyriad: 2000, // 20% = 2000 per ten thousand
    },
    predicate: 'categories.id = "summer-collection-id"',
    sortOrder: '0.5',
    isActive: true,
    validFrom: '2025-06-01T00:00:00.000Z',
    validUntil: '2025-08-31T23:59:59.000Z',
  },
}).execute();
```

### Product Discount Value Types

| Type | Description | Example |
|------|-------------|---------|
| `relative` | Percentage off (permyriad) | `permyriad: 1000` = 10% off |
| `absolute` | Fixed amount off per currency | `money: [{ currencyCode: 'EUR', centAmount: 500 }]` |
| `external` | Price set by external service | Discount value provided via API |

## Cart Discounts

Cart Discounts apply during cart calculation. They can target line items, custom line items, shipping, or the total price.

### Percentage Off Line Items

```typescript
const cartDiscount = await apiRoot.cartDiscounts().post({
  body: {
    name: { en: '10% Off All Items' },
    key: 'ten-percent-off',
    value: {
      type: 'relative',
      permyriad: 1000, // 10%
    },
    cartPredicate: 'totalPrice.centAmount > 5000', // min cart value
    target: {
      type: 'lineItems',
      predicate: '1 = 1', // all line items
    },
    sortOrder: '0.1', // higher = applied first
    isActive: true,
    requiresDiscountCode: false,
  },
}).execute();
```

### Absolute Amount Off Shipping

```typescript
const shippingDiscount = await apiRoot.cartDiscounts().post({
  body: {
    name: { en: '$5 Off Shipping' },
    key: 'five-off-shipping',
    value: {
      type: 'absolute',
      money: [
        { currencyCode: 'EUR', centAmount: 500 },
        { currencyCode: 'USD', centAmount: 500 },
      ],
    },
    cartPredicate: '1 = 1',
    target: { type: 'shipping' },
    sortOrder: '0.2',
    isActive: true,
    requiresDiscountCode: true,
  },
}).execute();
```

### Free Gift Line Item

```typescript
const freeGift = await apiRoot.cartDiscounts().post({
  body: {
    name: { en: 'Free Gift with Purchase' },
    key: 'free-gift',
    value: {
      type: 'giftLineItem',
      product: { typeId: 'product', id: 'gift-product-id' },
      variantId: 1,
    },
    cartPredicate: 'totalPrice.centAmount >= 10000', // orders over $100
    // No target needed for gift line items
    sortOrder: '0.05',
    isActive: true,
    requiresDiscountCode: false,
  },
}).execute();
```

### Fixed Price (Set Price)

```typescript
const fixedPrice = await apiRoot.cartDiscounts().post({
  body: {
    name: { en: 'Bundle Price: $49.99' },
    key: 'bundle-fixed-price',
    value: {
      type: 'fixed',
      money: [{ currencyCode: 'USD', centAmount: 4999 }],
    },
    cartPredicate: 'lineItemCount(sku = "BUNDLE-A") >= 1',
    target: {
      type: 'lineItems',
      predicate: 'sku = "BUNDLE-A"',
    },
    sortOrder: '0.3',
    isActive: true,
    requiresDiscountCode: false,
  },
}).execute();
```

## Discount Codes

Discount Codes are strings that activate Cart Discounts. A single code can reference up to 10 Cart Discounts.

```typescript
const discountCode = await apiRoot.discountCodes().post({
  body: {
    key: 'save-five-shipping',
    name: { en: 'Free Shipping Code' },
    code: 'FREESHIP',
    cartDiscounts: [
      { typeId: 'cart-discount', id: shippingDiscount.body.id },
    ],
    cartPredicate: 'totalPrice.centAmount > 3000',
    isActive: true,
    maxApplications: 1000,
    maxApplicationsPerCustomer: 1,
    validFrom: '2025-01-01T00:00:00.000Z',
    validUntil: '2025-06-30T23:59:59.000Z',
  },
}).execute();
```

Maximum of 10 discount codes per cart.

## Discount Stacking and Sort Order

This is the most misunderstood aspect of commercetools pricing.

### Sort Order

The `sortOrder` field (decimal between 0 and 1) determines application sequence. **Higher values are applied first.**

**Anti-Pattern (not considering sort order impact):**
```typescript
// Cart total: $100
// Discount A: 10% off (sortOrder: 0.2) — applied first
// Discount B: $10 off (sortOrder: 0.1) — applied second

// Result: $100 * 0.90 = $90, then $90 - $10 = $80

// But if sort orders were reversed:
// Discount B: $10 off (sortOrder: 0.2) — applied first
// Discount A: 10% off (sortOrder: 0.1) — applied second

// Result: $100 - $10 = $90, then $90 * 0.90 = $81
// Different final price!
```

**Recommended (explicit sort order strategy):**
```typescript
// Document your discount priority strategy
// Higher sortOrder = applied first
// 0.9 - Exclusive/VIP discounts
// 0.7 - Percentage-based discounts
// 0.5 - Fixed amount discounts
// 0.3 - Shipping discounts
// 0.1 - Low-priority/fallback discounts
```

### Stacking Mode

**Anti-Pattern (misunderstanding StopAfterThisDiscount):**
```typescript
// WRONG assumption: StopAfterThisDiscount stops ALL subsequent discounts
const exclusiveDiscount = await apiRoot.cartDiscounts().post({
  body: {
    name: { en: 'VIP 25% Off' },
    value: { type: 'relative', permyriad: 2500 },
    cartPredicate: 'customerGroup.key = "vip"',
    target: { type: 'lineItems', predicate: '1 = 1' },
    stackingMode: 'StopAfterThisDiscount', // stops line item discounts
    sortOrder: '0.9',
    isActive: true,
  },
}).execute();
// BUT: Total Price discounts still apply! They always execute last, ignoring stacking mode.
```

**Why This Matters:** `StopAfterThisDiscount` only prevents lower-ranked discounts of the SAME target type from applying. Total Price discounts always apply last, regardless of stacking mode.

### Product Discount + Cart Discount Interaction

The Promotion Prioritization setting (Project Settings > Miscellaneous) controls how Product Discounts and Cart Discounts interact:

| Mode | Behavior |
|------|----------|
| **Best Deal** | Only the type (Product or Cart) that gives the lower total applies |
| **Stacking** | Product Discount applies first, then Cart Discounts reduce the already-discounted price |

**Anti-Pattern (not configuring the setting):**
```typescript
// Product has a 20% Product Discount
// Cart has a 10% Cart Discount
// In "Stacking" mode: customer gets 20% + 10% off the discounted price
// In "Best Deal" mode: customer gets whichever is better
// Default behavior may not match business intent
```

## Direct Discounts

Direct Discounts are applied programmatically to specific carts (e.g., from quotes or manual adjustments).

**Anti-Pattern (not understanding the mutual exclusion):**
```typescript
// Applying a Direct Discount silently blocks ALL matching Cart Discounts
// AND makes Discount Codes unusable on the cart
await apiRoot.carts().withId({ ID: cartId }).post({
  body: {
    version,
    actions: [
      {
        action: 'setDirectDiscounts',
        discounts: [
          {
            value: { type: 'relative', permyriad: 1500 }, // 15% off
            target: { type: 'lineItems', predicate: '1 = 1' },
          },
        ],
      },
    ],
  },
}).execute();
// Now: customer enters "SAVE10" discount code -> REJECTED
// Auto-applied cart discounts -> SILENTLY DISABLED
```

**Recommended (understand the trade-off):**
```typescript
// Direct Discounts and Discount Codes/Cart Discounts are mutually exclusive
// Use Direct Discounts ONLY for:
// - Quote-based pricing (B2B)
// - Manual price adjustments by customer service
// - Cases where no other discount codes should apply

// Communicate to the customer that additional discounts cannot be combined
```

## Active Discount Limits

| Resource | Limit |
|----------|-------|
| Active Product Discounts | 500 |
| Active Cart Discounts (auto-applied, no code required) | 100 |
| Cart Discounts requiring Discount Codes | No specific limit |
| Discount Codes per Cart | 10 |

**Anti-Pattern (granular product-specific discounts):**
```typescript
// Creating a separate Cart Discount for each product on sale
// "10% off Product A", "15% off Product B", "20% off Product C"...
// Quickly hits the 100 active discount limit
```

**Recommended (broad predicate-based discounts):**
```typescript
// Use predicates to target multiple products with a single discount
const broadDiscount = await apiRoot.cartDiscounts().post({
  body: {
    name: { en: 'Category Sale' },
    value: { type: 'relative', permyriad: 1500 },
    cartPredicate: '1 = 1',
    target: {
      type: 'lineItems',
      predicate: 'productType.key = "electronics" and attributes.onSale = true',
    },
    sortOrder: '0.5',
    isActive: true,
  },
}).execute();
```

## Pricing Best Practices

### Do Not Use Prices for Non-Price Data

**Anti-Pattern (MSRP as a price):**
```typescript
// WRONG: Storing MSRP/compare-at prices in the price system
// This adds computation overhead to every price calculation
const priceDraft = {
  value: { currencyCode: 'EUR', centAmount: 4999 },
  country: 'DE',
  custom: {
    type: { key: 'price-metadata' },
    fields: { msrp: 5999 }, // WRONG: use a product attribute instead
  },
};
```

**Recommended:**
```typescript
// Store MSRP/compare-at prices as product attributes
// They do not participate in price selection logic
const productUpdate = {
  action: 'setAttribute',
  name: 'msrp',
  value: { currencyCode: 'EUR', centAmount: 5999 },
};
```

**Why This Matters:** The commercetools price selection algorithm evaluates all prices for every calculation. Adding non-purchase prices increases computation time for every API call that returns prices.

## Checklist

- [ ] Promotion Prioritization setting is explicitly configured (Best Deal vs Stacking)
- [ ] Sort order strategy is documented and consistent
- [ ] StopAfterThisDiscount behavior is understood (does not stop Total Price discounts)
- [ ] Direct Discount / Discount Code mutual exclusion is accounted for
- [ ] Active discount count stays well under limits (100 auto-applied, 500 product)
- [ ] Discount predicates are broad and reusable, not product-specific
- [ ] Expired discounts are cleaned up regularly
- [ ] All discount combinations are tested (sort order, stacking, code interactions)
- [ ] MSRP/reference prices are stored as product attributes, not prices
- [ ] Discount code `maxApplications` and `maxApplicationsPerCustomer` are set
