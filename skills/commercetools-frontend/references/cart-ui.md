# Cart UI Patterns

Cart state management with SWR hooks, cost calculation, line item display, cart summary with discount codes, and wishlist integration for commercetools storefronts.

**Impact: CRITICAL -- Race conditions in cart state cause lost items, quantity bugs, and broken checkout. Silent payment failures cause abandoned orders.**

Cart and checkout are the most stateful, interactive parts of a commerce storefront. These patterns cover cart state management, optimistic updates, checkout flow UI, and integration with commercetools Checkout (the hosted checkout product).

## Cart State Management

### Pattern 1: SWR-Based Cart Hook (from the official scaffold repos)

The official commercetools Frontend scaffold uses SWR for cart state management. SWR provides automatic revalidation, deduplication, and built-in optimistic update support via `mutate`. Every cart mutation calls the SDK extension, then updates the SWR cache with the server response. This is the pattern from `frontastic/hooks/useCart/index.ts`.

**INCORRECT -- blocking UI on every cart mutation:**

```typescript
// WRONG: UI freezes until the API responds
async function handleAddToCart(productId: string, variantId: number) {
  setLoading(true);
  const response = await fetch('/api/cart/add', {
    method: 'POST',
    body: JSON.stringify({ productId, variantId, quantity: 1 }),
  });
  const cart = await response.json();
  setCart(cart); // UI blocked for 200-500ms per click
  setLoading(false);
}
```

**CORRECT -- SWR-based hook with cache-based optimistic updates:**

```typescript
// frontastic/hooks/useCart/index.ts
import useSWR, { mutate } from 'swr';
import { useCallback, useMemo } from 'react';
import { sdk } from 'sdk';
import { useI18n } from 'helpers/hooks/useI18n';
import { mapCosts } from 'helpers/utils/mapCosts';
import type { Cart, Variant, Discount } from 'shared/types';

interface UseCartReturn {
  data?: Cart;
  totalItems: number;
  isEmpty: boolean;
  isLoading: boolean;
  transaction: ReturnType<typeof mapCosts>;
  shippingMethods: { data?: ShippingMethod[] };
  addItem: (variant: Variant, quantity: number) => Promise<void>;
  removeItem: (lineItemId: string) => Promise<void>;
  updateItem: (lineItemId: string, count: number) => Promise<void>;
  updateCart: (payload: CartPayload) => Promise<void>;
  redeemDiscountCode: (code: string) => Promise<void>;
  removeDiscountCode: (discount: Discount) => Promise<void>;
  setShippingMethod: (shippingMethodId: string) => Promise<void>;
}

const useCart = (): UseCartReturn => {
  const extensions = sdk.composableCommerce;
  const { currency } = useI18n();

  // SWR fetches and caches the cart -- revalidates on window focus and stale data
  const result = useSWR(
    '/action/cart/getCart',
    extensions.cart.getCart,
    { revalidateIfStale: true }
  );

  // Shipping methods fetched in parallel, filtered to matching ones
  const shippingMethodsResults = useSWR(
    '/action/cart/getShippingMethods',
    () => extensions.cart.getShippingMethods({ query: { onlyMatching: true } })
  );

  const data = result.data?.isError ? {} : { data: result.data?.data };
  const totalItems = (data.data?.lineItems ?? []).reduce(
    (acc, curr) => acc + (curr.count as number), 0
  );
  const isEmpty = !data.data?.lineItems?.length;

  // Derived cost breakdown -- recalculated when cart or currency changes
  const transaction = useMemo(
    () => mapCosts({ cart: data.data, currency }),
    [data.data, currency]
  );

  const addItem = useCallback(async (variant: Variant, quantity: number) => {
    const payload = { variant: { sku: variant.sku, count: quantity } };
    const res = await extensions.cart.addItem(payload);
    mutate('/action/cart/getCart', res); // Update SWR cache with server response
  }, []);

  const removeItem = useCallback(async (lineItemId: string) => {
    const payload = { lineItem: { id: lineItemId } };
    const res = await extensions.cart.removeItem(payload);
    mutate('/action/cart/getCart', res);
  }, []);

  const updateItem = useCallback(async (lineItemId: string, count: number) => {
    const payload = { lineItem: { id: lineItemId, count } };
    const res = await extensions.cart.updateItem(payload);
    mutate('/action/cart/getCart', res);
  }, []);

  const updateCart = useCallback(async (payload: CartPayload) => {
    const res = await extensions.cart.updateCart(payload);
    mutate('/action/cart/getCart', res);
  }, []);

  const redeemDiscountCode = useCallback(async (code: string) => {
    const res = await extensions.cart.redeemDiscountCode({ code });
    // Validate the response is actually a cart (not an error disguised as success)
    if (!res.isError && (res.data as Cart).cartId) {
      mutate('/action/cart/getCart', res);
    } else {
      throw new Error(res.isError ? res.error.message : 'code not valid');
    }
  }, []);

  const removeDiscountCode = useCallback(async (discount: Discount) => {
    const res = await extensions.cart.removeDiscountCode({
      discountCodeId: discount.discountCodeId as string,
    });
    mutate('/action/cart/getCart', res);
  }, []);

  const setShippingMethod = useCallback(async (shippingMethodId: string) => {
    const res = await extensions.cart.setShippingMethod({ shippingMethod: { id: shippingMethodId } });
    mutate('/action/cart/getCart', res);
  }, []);

  return {
    ...data,
    totalItems,
    isEmpty,
    isLoading: result.isLoading,
    transaction,
    shippingMethods: shippingMethodsResults.data?.isError ? {} : shippingMethodsResults.data ?? {},
    addItem, removeItem, updateItem, updateCart,
    redeemDiscountCode, removeDiscountCode, setShippingMethod,
  };
};
```

For a custom Next.js App Router project (not using the commercetools Frontend scaffold), the same principle applies but with a `useReducer`-based Context. The key pattern: dispatch an optimistic action immediately, fire the API call, then dispatch `SET_CART` with the server response. On error, refetch the cart to reconcile.

### Pattern 2: Cart Cost Calculation with mapCosts (from the official scaffold repos)

The scaffold computes all cart cost breakdowns in a pure helper function. This avoids duplicating cost math across components and handles edge cases like gift line items, included-in-price taxes, and cart-level discounts.

```typescript
// helpers/utils/mapCosts/index.ts
import type { Cart } from '@/types';

interface CostEntry {
  centAmount: number;
  currencyCode: string;
  fractionDigits: number;
}

interface Transaction {
  subtotal: CostEntry;
  discount: CostEntry;
  shipping: CostEntry;
  tax: CostEntry;
  total: CostEntry;
}

const mapCosts = ({ cart, currency = 'USD' }: { cart?: Cart; currency?: string }): Transaction => {
  if (!cart) {
    const zero = { centAmount: 0, currencyCode: currency, fractionDigits: 2 };
    return { subtotal: zero, discount: zero, shipping: zero, tax: zero, total: zero };
  }

  const totalAmount = cart.sum?.centAmount ?? 0;

  // Subtotal: sum of (unit price * quantity) minus included-in-price tax, skipping gift items
  const subTotalAmount = (cart.lineItems ?? []).reduce((acc, curr) => {
    if (curr.isGift) return acc;
    return (
      acc +
      (curr.price?.centAmount || 0) * (curr.count as number) -
      (curr.taxRate?.includedInPrice ? curr.taxed?.taxAmount?.centAmount || 0 : 0)
    );
  }, 0);

  // Discounts: cart-level discount + line-level discount (difference between unit*qty and totalPrice)
  const discountedAmount =
    (cart.discountOnTotalPrice?.discountedAmount?.centAmount || 0) +
    (cart.lineItems ?? []).reduce((acc, curr) => {
      if (curr.isGift) return acc;
      return (
        acc +
        ((curr.price?.centAmount || 0) * (curr.count as number) - (curr.totalPrice?.centAmount || 0))
      );
    }, 0);

  const shippingAmount = cart.shippingInfo?.price?.centAmount ?? 0;
  const taxAmount = cart.taxed?.taxPortions?.reduce(
    (acc, curr) => acc + (curr.amount?.centAmount || 0), 0
  ) ?? 0;

  const mkEntry = (centAmount: number): CostEntry => ({
    centAmount,
    currencyCode: cart.sum?.currencyCode ?? currency,
    fractionDigits: cart.sum?.fractionDigits ?? 2,
  });

  return {
    subtotal: mkEntry(subTotalAmount),
    discount: mkEntry(discountedAmount),
    shipping: mkEntry(shippingAmount),
    tax: mkEntry(taxAmount),
    total: mkEntry(totalAmount),
  };
};
```

### Pattern 3: Cart Line Item Display

Line items must display unit price, quantity with selector, line total (including discounts), variant attributes, and a remove button. Use `totalPrice` for the line total since it accounts for quantity and applied discounts. Show `discountedPricePerQuantity` when present.

```typescript
// components/cart/CartLineItem.tsx
'use client';

import Image from 'next/image';
import type { LineItem } from '@commercetools/platform-sdk';
import { useCart } from '@/context/CartContext';
import { localize, formatPrice } from '@/lib/commercetools/localization';
import { QuantitySelector } from '@/components/ui/QuantitySelector';

export function CartLineItem({ lineItem, locale }: { lineItem: LineItem; locale: string }) {
  const { removeItem, updateQuantity, getEffectiveQuantity } = useCart();
  const effectiveQuantity = getEffectiveQuantity(lineItem.id);
  const image = lineItem.variant?.images?.[0];
  const name = localize(lineItem.name, locale);
  const lineTotal = lineItem.totalPrice;
  const unitPrice = lineItem.price.discounted ? lineItem.price.discounted.value : lineItem.price.value;

  return (
    <div className="flex gap-4 py-4 border-b">
      {image && (
        <div className="relative w-20 h-20 flex-shrink-0">
          <Image src={image.url} alt={image.label || name} fill sizes="80px" className="object-cover rounded" />
        </div>
      )}
      <div className="flex-1">
        <h3 className="font-medium">{name}</h3>
        {lineItem.variant?.attributes?.map((attr) => (
          <p key={attr.name} className="text-sm text-gray-500 capitalize">
            {attr.name}: {typeof attr.value === 'object' ? attr.value.label || attr.value.key : attr.value}
          </p>
        ))}
        <p className="text-sm mt-1">{formatPrice(unitPrice.centAmount, unitPrice.currencyCode, locale)} each</p>
        {lineItem.discountedPricePerQuantity.length > 0 && <p className="text-sm text-green-600">Discount applied</p>}
      </div>
      <div className="flex flex-col items-end gap-2">
        <QuantitySelector value={effectiveQuantity} onChange={(qty) => updateQuantity(lineItem.id, qty)} min={1} max={99} />
        <p className="font-medium">{formatPrice(lineTotal.centAmount, lineTotal.currencyCode, locale)}</p>
        <button onClick={() => removeItem(lineItem.id)} className="text-sm text-red-600 hover:underline">Remove</button>
      </div>
    </div>
  );
}
```

### Pattern 4: Cart Summary with Discount Codes

The cart summary shows subtotal, shipping, tax, applied discount codes, a promo code input, and the total. When using the scaffold's SWR hook, wire `redeemDiscountCode` and `removeDiscountCode` directly. For a custom setup, POST to your API route and handle error states inline.

```typescript
// components/cart/CartSummary.tsx
'use client';

import { useState } from 'react';
import type { Cart } from '@commercetools/platform-sdk';
import { formatPrice } from '@/lib/commercetools/localization';

export function CartSummary({ cart, locale }: { cart: Cart; locale: string }) {
  const [promoCode, setPromoCode] = useState('');
  const [promoError, setPromoError] = useState('');
  const [applying, setApplying] = useState(false);

  const subtotal = cart.lineItems.reduce((sum, li) => sum + li.totalPrice.centAmount, 0);
  const currency = cart.totalPrice.currencyCode;

  const handleApplyPromo = async () => {
    setPromoError('');
    setApplying(true);
    try {
      const res = await fetch('/api/cart/apply-discount', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ code: promoCode }),
      });
      if (!res.ok) {
        const data = await res.json();
        setPromoError(data.error || 'Invalid promo code');
      } else {
        setPromoCode('');
      }
    } finally {
      setApplying(false);
    }
  };

  return (
    <div className="space-y-4">
      <div className="flex justify-between"><span>Subtotal</span><span>{formatPrice(subtotal, currency, locale)}</span></div>
      {cart.shippingInfo && (
        <div className="flex justify-between"><span>Shipping</span><span>{formatPrice(cart.shippingInfo.price.centAmount, currency, locale)}</span></div>
      )}
      {cart.taxedPrice && (
        <div className="flex justify-between text-sm text-gray-500"><span>Tax</span><span>{formatPrice(cart.taxedPrice.totalTax?.centAmount || 0, currency, locale)}</span></div>
      )}
      {cart.discountCodes.map((dc) => (
        <div key={dc.discountCode.id} className="flex justify-between text-green-600 text-sm">
          <span>Code: {dc.discountCode.obj?.code || 'Applied'}</span><span>{dc.state}</span>
        </div>
      ))}
      <div className="flex gap-2">
        <input type="text" value={promoCode} onChange={(e) => setPromoCode(e.target.value)} placeholder="Promo code" className="flex-1 border rounded px-3 py-2 text-sm" />
        <button onClick={handleApplyPromo} disabled={!promoCode || applying} className="px-4 py-2 bg-gray-900 text-white text-sm rounded disabled:opacity-50">Apply</button>
      </div>
      {promoError && <p className="text-red-600 text-sm">{promoError}</p>}
      <div className="flex justify-between font-bold text-lg border-t pt-4"><span>Total</span><span>{formatPrice(cart.totalPrice.centAmount, currency, locale)}</span></div>
    </div>
  );
}
```

### Pattern 5: Move to Wishlist from Cart (from the official scaffold repos)

The scaffold wires up a "move to wishlist" action in the cart tastic. This removes the item from the cart and adds it to the wishlist in parallel using `Promise.all`, avoiding sequential waits.

```typescript
// frontastic/tastics/cart/index.tsx (relevant excerpt)
import { useCart } from 'frontastic/hooks/useCart';
import { useWishlist } from 'frontastic/hooks/useWishlist';
import type { LineItem as CartLineItem } from 'shared/types/cart';

const CartTastic = ({ data }: TasticProps<CartTasticData>) => {
  const { data: cart, removeItem, updateItem, transaction, redeemDiscountCode, removeDiscountCode } = useCart();
  const { data: wishlist, addToWishlist } = useWishlist();

  // Move item from cart to wishlist -- parallel removal + addition
  const moveToWishlist = useCallback(
    async (lineItem: CartLineItem) => {
      if (!wishlist) return;
      await Promise.all([
        removeItem(lineItem.lineItemId),
        addToWishlist(wishlist, {
          lineItemId: lineItem.lineItemId,
          variant: lineItem.variant,
          name: lineItem.name,
          count: 1,
        }, 1),
      ]);
    },
    [removeItem, addToWishlist, wishlist]
  );

  return (
    <Cart
      cart={cart}
      transaction={transaction}
      onRemove={(lineItemId) => removeItem(lineItemId)}
      onUpdateQuantity={(lineItemId, count) => updateItem(lineItemId, count)}
      onMoveToWishlist={moveToWishlist}
      onApplyDiscount={redeemDiscountCode}
      onRemoveDiscount={removeDiscountCode}
    />
  );
};
```
