# Checkout & Wishlist UI Patterns

Checkout patterns including commercetools Checkout SDK integration, shipping method selection, wishlist management, and cart/checkout checklist for commercetools storefronts.

## Checkout Patterns

### Pattern 6: Dual-Mode Checkout Tastic (from the official scaffold repos)

The official scaffold supports two checkout modes in a single tastic, controlled by the `isCtPaymentOnly` flag set in the commercetools Frontend Studio. When `isCtPaymentOnly` is false, the entire checkout is handled by the embedded commercetools Checkout SDK. When true, the storefront renders its own address/shipping forms and only delegates payment to commercetools Checkout.

```typescript
// frontastic/tastics/checkout/index.tsx
import { useCart } from 'frontastic/hooks/useCart';
import { CommercetoolsCheckout } from 'components/commercetools-ui/organisms/checkout/ct-checkout';
import { Checkout } from 'components/commercetools-ui/organisms/checkout';
import type { TasticProps } from 'frontastic/tastics/types';

interface CheckoutTasticData {
  logo?: { media: { mediaId: string; file: string } };
  callbackUrl?: string;
  isCtPaymentOnly?: boolean;
}

const CheckoutTastic = ({ data }: TasticProps<CheckoutTasticData>) => {
  const {
    data: cart, transaction, updateCart, setShippingMethod,
    redeemDiscountCode, removeDiscountCode, shippingMethods,
  } = useCart();

  // Mode 1: Full embedded commercetools Checkout -- handles everything
  if (!data.isCtPaymentOnly) {
    return <CommercetoolsCheckout logo={data.logo} callbackUrl={data.callbackUrl} />;
  }

  // Mode 2: Custom checkout UI with commercetools payment only
  return (
    <Checkout
      logo={data.logo}
      isCtPaymentOnly
      cart={cart}
      transaction={transaction}
      onUpdateCart={updateCart}
      onSetShippingMethod={setShippingMethod}
      onApplyDiscount={redeemDiscountCode}
      onRemoveDiscount={removeDiscountCode}
      shippingMethods={shippingMethods.data ?? []}
      callbackUrl={data.callbackUrl}
    />
  );
};
```

### Pattern 7: commercetools Checkout SDK Integration (from the official scaffold repos)

The scaffold wraps the commercetools Checkout Browser SDK in a dedicated component. Key details: it uses a `useRef` guard to prevent double-initialization in React strict mode, manages a session token via a `useCheckout` hook, and handles three critical lifecycle events (`checkout_loaded`, `checkout_cancelled`, `checkout_completed`).

```typescript
// components/checkout/ct-checkout/index.tsx
'use client';

import { useEffect, useRef, useState } from 'react';
import { checkoutFlow } from '@commercetools/checkout-browser-sdk';
import { useRouter } from 'next/navigation';
import { useProjectSettings } from '@/hooks/useProjectSettings';
import { useCheckout } from '@/hooks/useCheckout';
import { Header } from '@/components/checkout/header';

const CommercetoolsCheckout = ({ logo, callbackUrl }: {
  logo?: { media: { mediaId: string; file: string } };
  callbackUrl?: string;
}) => {
  const { projectSettings } = useProjectSettings();
  const { session, isExpired } = useCheckout();
  const { push: pushRoute } = useRouter();
  const initiatedCheckout = useRef(false);
  const [isLoading, setIsLoading] = useState(true);

  const projectKey = projectSettings?.projectKey;
  const region = projectSettings?.region; // e.g., 'us-central1.gcp'
  const locale = projectSettings?.locale ?? 'en-US';

  useEffect(() => {
    // Guard: don't re-initialize, and wait for required config
    if (initiatedCheckout.current || !projectKey || !region || !session?.token) return;
    initiatedCheckout.current = true;

    checkoutFlow({
      region,
      projectKey,
      sessionId: session.token,
      locale,
      styles: {
        '--font-family': "'Inter', sans-serif",
        '--button': '#212121',
      },
      onInfo: (message) => {
        switch (message.code) {
          case 'checkout_cancelled':
            pushRoute('/cart');
            break;
          case 'checkout_loaded':
            setIsLoading(false);
            break;
          case 'checkout_completed':
            pushRoute(`${callbackUrl}?orderId=${message.payload?.order?.id}`);
            break;
        }
      },
      onWarn: (message) => console.warn('[Checkout SDK]', message),
      onError: (message) => console.error('[Checkout SDK]', message),
    });
  }, [projectKey, region, locale, session]);

  // Handle expired sessions -- reset guard so checkout re-initializes
  useEffect(() => {
    if (isExpired) {
      initiatedCheckout.current = false;
    }
  }, [isExpired]);

  return (
    <div className="min-h-screen lg:bg-neutral-200">
      <Header logo={logo} />
      {isLoading && (
        <div className="flex justify-center py-12">
          <span className="animate-spin h-8 w-8 border-2 border-neutral-400 border-t-transparent rounded-full" />
        </div>
      )}
      {/* The checkout SDK renders into this container via the data-ctc attribute */}
      <div data-ctc className="checkout-Container" />
    </div>
  );
};
```

### Pattern 8: Custom Checkout Flow (Without Hosted Checkout)

For full control over the checkout experience instead of using commercetools Checkout. The flow is a step-based state machine: address -> shipping -> review -> payment. Each step validates before progression. Errors are shown inline.

```typescript
// app/[locale]/checkout/page.tsx
'use client';

import { useState } from 'react';
import { useCart } from '@/context/CartContext';
import { AddressForm } from '@/components/checkout/AddressForm';
import { ShippingMethodSelector } from '@/components/checkout/ShippingMethodSelector';
import { OrderReview } from '@/components/checkout/OrderReview';
import { PaymentForm } from '@/components/checkout/PaymentForm';

type CheckoutStep = 'address' | 'shipping' | 'review' | 'payment';

export default function CheckoutPage() {
  const { cart } = useCart();
  const [step, setStep] = useState<CheckoutStep>('address');
  const [error, setError] = useState<string | null>(null);

  if (!cart || cart.lineItems.length === 0) return <p>Your cart is empty.</p>;

  return (
    <div className="max-w-2xl mx-auto">
      <nav className="flex gap-4 mb-8">
        {(['address', 'shipping', 'review', 'payment'] as const).map((s, i) => (
          <span key={s} className={`text-sm ${step === s ? 'font-bold' : 'text-gray-400'}`}>
            {i + 1}. {s.charAt(0).toUpperCase() + s.slice(1)}
          </span>
        ))}
      </nav>
      {error && <div className="p-4 bg-red-50 text-red-700 rounded mb-4">{error}</div>}
      {step === 'address' && (
        <AddressForm onSubmit={async (address) => {
          try {
            await fetch('/api/cart/set-address', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(address) });
            setStep('shipping');
          } catch { setError('Failed to save address. Please try again.'); }
        }} />
      )}
      {step === 'shipping' && (
        <ShippingMethodSelector cartId={cart.id} onSelect={async (methodId) => {
          try {
            await fetch('/api/cart/set-shipping', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ shippingMethodId: methodId }) });
            setStep('review');
          } catch { setError('Failed to set shipping method.'); }
        }} />
      )}
      {step === 'review' && <OrderReview cart={cart} onConfirm={() => setStep('payment')} onBack={() => setStep('shipping')} />}
      {step === 'payment' && <PaymentForm cart={cart} onSuccess={(orderId) => { window.location.href = `/order-confirmation/${orderId}`; }} onError={(msg) => setError(msg)} />}
    </div>
  );
}
```

### Pattern 9: Shipping Method Selection

Fetch shipping methods for the cart (only matching methods for the shipping address), display them as radio options with price, and set the selected method on the cart.

```typescript
// components/checkout/ShippingMethodSelector.tsx
'use client';

import { useEffect, useState } from 'react';
import { formatPrice } from '@/lib/commercetools/localization';

interface ShippingMethod {
  id: string;
  name: string;
  description?: string;
  price: { centAmount: number; currencyCode: string };
}

export function ShippingMethodSelector({ cartId, onSelect }: { cartId: string; onSelect: (methodId: string) => Promise<void> }) {
  const [methods, setMethods] = useState<ShippingMethod[]>([]);
  const [selected, setSelected] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    fetch(`/api/shipping-methods?cartId=${cartId}`)
      .then((res) => res.json())
      .then((data) => { setMethods(data); setLoading(false); });
  }, [cartId]);

  if (loading) return <p>Loading shipping options...</p>;

  return (
    <div className="space-y-3">
      <h2 className="text-xl font-semibold">Shipping Method</h2>
      {methods.map((method) => (
        <label key={method.id} className={`flex items-center justify-between p-4 border rounded cursor-pointer ${selected === method.id ? 'border-black' : 'border-gray-200'}`}>
          <div className="flex items-center gap-3">
            <input type="radio" name="shipping" value={method.id} checked={selected === method.id} onChange={() => setSelected(method.id)} />
            <div>
              <p className="font-medium">{method.name}</p>
              {method.description && <p className="text-sm text-gray-500">{method.description}</p>}
            </div>
          </div>
          <span className="font-medium">{method.price.centAmount === 0 ? 'Free' : formatPrice(method.price.centAmount, method.price.currencyCode, 'en-US')}</span>
        </label>
      ))}
      <button onClick={() => selected && onSelect(selected)} disabled={!selected} className="w-full py-3 bg-black text-white rounded disabled:opacity-50">Continue to Review</button>
    </div>
  );
}
```

## Wishlist Patterns

### Pattern 10: Wishlist with SWR Optimistic Updates (from the official scaffold repos)

The scaffold manages wishlists with SWR and uses its optimistic update API (`optimisticData` + `rollbackOnError`) to provide instant UI feedback. If the server call fails, SWR automatically rolls back to the previous state.

```typescript
// frontastic/hooks/useWishlist/index.ts
import useSWR, { mutate } from 'swr';
import { useCallback } from 'react';
import { sdk } from 'sdk';
import type { Wishlist, LineItem } from 'shared/types';

const useWishlist = () => {
  const extensions = sdk.composableCommerce;
  const result = useSWR('/action/wishlist/getWishlist', extensions.wishlist.getWishlist);
  const data = result.data?.isError ? {} : { data: result.data?.data };

  const addToWishlist = useCallback(
    async (wishlist: Wishlist, lineItem: LineItem, count = 1) => {
      // Build the optimistic next state immediately
      const newWishlist = { ...wishlist, lineItems: [...(wishlist.lineItems ?? []), lineItem] };

      const res = extensions.wishlist.addItem({
        variant: { sku: lineItem.variant?.sku },
        count,
      });

      // SWR optimistic update: show new state immediately, rollback on error
      await mutate('/action/wishlist/getWishlist', res, {
        optimisticData: { data: newWishlist },
        rollbackOnError: true,
      });
    },
    []
  );

  const removeFromWishlist = useCallback(
    async (wishlist: Wishlist, lineItem: LineItem) => {
      const newWishlist = {
        ...wishlist,
        lineItems: (wishlist.lineItems ?? []).filter((li) => li.lineItemId !== lineItem.lineItemId),
      };

      const res = extensions.wishlist.removeItem({ lineItem: { id: lineItem.lineItemId } });

      await mutate('/action/wishlist/getWishlist', res, {
        optimisticData: { data: newWishlist },
        rollbackOnError: true,
      });
    },
    []
  );

  return { ...data, isLoading: result.isLoading, addToWishlist, removeFromWishlist };
};
```

## Cart & Checkout Checklist

- [ ] Cart uses optimistic updates -- UI responds immediately, reconciles with server
- [ ] Cart state is managed via SWR with `mutate` (scaffold pattern) or React Context with a reducer
- [ ] Failed cart mutations gracefully revert optimistic state (SWR `rollbackOnError` or reload cart from server)
- [ ] Cart ID is stored in an HttpOnly, Secure cookie -- never in localStorage
- [ ] Line item display shows unit price, quantity, and line total (including discounts)
- [ ] Discount code input handles errors (invalid code, expired, already applied)
- [ ] `discountedPricePerQuantity` is used for accurate line-level discount display
- [ ] Cost breakdown uses a centralized `mapCosts` helper that handles gift items and included-in-price tax
- [ ] Checkout flow shows clear step progression (address, shipping, review, payment)
- [ ] Each checkout step validates before allowing progression
- [ ] Dual checkout mode is supported: full embedded checkout vs. custom UI with ct payment only
- [ ] Error states are shown inline, not just logged to console
- [ ] commercetools Checkout SDK is initialized only once (use `useRef` guard)
- [ ] Checkout handles `checkout_loaded`, `checkout_cancelled`, and `checkout_completed` events
- [ ] Checkout completion handler redirects to order confirmation page with orderId
- [ ] Session expiry is detected and handled (re-create session token)
- [ ] Anonymous cart merges into customer cart on login (`anonymousCartSignInMode`)
- [ ] Quantity selector has reasonable min/max bounds
- [ ] Cart page handles the empty cart state with a CTA to continue shopping
- [ ] Move-to-wishlist removes from cart and adds to wishlist in parallel (`Promise.all`)
- [ ] Wishlist uses SWR optimistic updates with `rollbackOnError` for instant UI feedback

## Reference

- [Carts API](https://docs.commercetools.com/api/projects/carts)
- [Discount Codes API](https://docs.commercetools.com/api/projects/discountCodes)
- [Shipping Methods API](https://docs.commercetools.com/api/projects/shippingMethods)
- [commercetools Checkout Browser SDK](https://docs.commercetools.com/checkout/browser-sdk)
- [Orders API](https://docs.commercetools.com/api/projects/orders)
- [commercetools Frontend SDK](https://docs.commercetools.com/frontend-development/sdk)
- [SWR Documentation](https://swr.vercel.app/)
