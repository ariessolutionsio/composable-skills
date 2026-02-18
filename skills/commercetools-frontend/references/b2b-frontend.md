# B2B Storefront Patterns

**Impact: HIGH -- B2B storefronts require fundamentally different architecture patterns for business units, permissions, approval workflows, quotes, and multi-user cart management. Getting these wrong breaks the entire buying experience.**

Patterns extracted from the official FrontasticGmbH/scaffold-b2b launchpad repository.

## Architecture: B2B Provider Layer

The B2B scaffold wraps the entire app in a `StoreAndBusinessUnitsProvider` that provides business unit and store context:

```typescript
// providers/store-and-business-units/index.tsx
const StoreAndBusinessUnitsProvider = ({ children }) => {
  const { businessUnits } = useBusinessUnits();
  const [selectedBusinessUnit, setSelectedBusinessUnit] = useState();
  const [selectedStore, setSelectedStore] = useState();
  // When BU changes, store and all data must refresh
  return (
    <StoreAndBusinessUnitsContext.Provider value={{ selectedBusinessUnit, selectedStore, ... }}>
      {children}
    </StoreAndBusinessUnitsContext.Provider>
  );
};
```

Every B2B API call is triple-scoped: `(accountId, businessUnitKey, storeKey)`.

## Pattern 1: Permission-Gated UI

The `useAccountRoles` hook provides per-business-unit permissions:

```typescript
// hooks/useAccountRoles/index.ts
const useAccountRoles = (businessUnitKey?: string) => {
  // SWR fetch of associate data for this BU
  const roles = data.roles ?? [];
  const isAdmin = roles.findIndex((role) => role.key === 'admin') !== -1;
  const rolePermissions = roles.reduce(
    (acc, curr) => [...acc, ...(curr.permissions ?? [])], [] as Permission[]
  );
  const permissions = rolePermissions.reduce(
    (acc, permission) => ({ ...acc, [permission]: true }), {} as Record<Permission, boolean>
  );
  return { roles, isAdmin, permissions };
};
```

47 permissions available (type `Permission`):
- Cart: `CreateMyCarts`, `ViewMyCarts`, `UpdateMyCarts`, `DeleteMyCarts`, `CreateOthersCarts`, `ViewOthersCarts`, `UpdateOthersCarts`, `DeleteOthersCarts`
- Orders: `CreateMyOrdersFromMyCarts`, `ViewMyOrders`, `UpdateMyOrders`, `CreateOrdersFromOthersCarts`, `ViewOthersOrders`, `UpdateOthersOrders`
- Quotes: `AcceptMyQuotes`, `DeclineMyQuotes`, `RenegotiateMyQuotes`, `ReassignMyQuotes`, `CreateMyQuoteRequestsFromMyCarts`, `CreateMyOrdersFromMyQuotes`, `ViewMyQuotes`, `ViewMyQuoteRequests`, `UpdateMyQuoteRequests`, `AcceptOthersQuotes`, `DeclineOthersQuotes`, `RenegotiateOthersQuotes`, `ReassignOthersQuotes`, `CreateOrdersFromOthersQuotes`, `CreateQuoteRequestsFromOthersCarts`, `ViewOthersQuotes`, `ViewOthersQuoteRequests`, `UpdateOthersQuoteRequests`
- Shopping Lists (Purchase Lists): `ViewMyShoppingLists`, `ViewOthersShoppingLists`, `CreateMyShoppingLists`, `CreateOthersShoppingLists`, `UpdateMyShoppingLists`, `UpdateOthersShoppingLists`, `DeleteMyShoppingLists`, `DeleteOthersShoppingLists`
- Admin: `UpdateBusinessUnitDetails`, `UpdateAssociates`, `UpdateParentUnit`, `AddChildUnits`, `CreateApprovalRules`, `UpdateApprovalRules`, `UpdateApprovalFlows`

Usage pattern -- disable UI elements based on permissions:
```typescript
const { permissions } = useAccountRoles(selectedBusinessUnit?.key);

<Cart
  viewCartDisabled={!permissions.ViewMyCarts}
  checkoutDisabled={!permissions.CreateMyOrdersFromMyCarts || invalidAddressesRequirements}
  quoteRequestDisabled={!permissions.CreateMyQuoteRequestsFromMyCarts || invalidAddressesRequirements}
/>
```

## Pattern 2: Business Unit Selector

```typescript
// hooks/useBusinessUnits/index.ts
const useBusinessUnits = () => {
  const { loggedIn } = useAccount();
  const { data, mutate } = useSWR(
    !loggedIn ? null : '/action/business-unit/getBusinessUnits',  // null key prevents fetch before login
    () => sdk.composableCommerce.businessUnit.getBusinessUnits()
  );
  const addBusinessUnit = useCallback(async (payload) => {
    const res = await sdk.composableCommerce.businessUnit.addBusinessUnit(payload);
    mutate(); // Refresh list
    return res.data;
  }, [mutate]);
  // Also: updateBusinessUnit, addAssociate, updateAssociate, removeAssociate, addAddress, ...
  return { businessUnits: data?.data ?? [], addBusinessUnit, ... };
};
```

## Pattern 3: Quote Lifecycle

The complete quote flow: `Cart -> QuoteRequest -> Quote -> Order`

```typescript
// Quote request from cart (frontend hook):
const requestQuote = useCallback(async (payload: QuoteRequestPayload) => {
  const result = await sdk.composableCommerce.quote.createQuote(
    { comment: payload.buyerComment, purchaseOrderNumber: payload.purchaseOrderNumber },
    { businessUnitKey, storeKey },
  );
  mutate(); // Cart is consumed, refresh
  return result.isError ? {} : result.data;
}, [businessUnitKey, storeKey]);
```

**Critical:** Creating a quote request CONSUMES the cart. The backend deletes the cart and clears the session cartId:
```typescript
// QuoteController.ts - createQuoteRequest (backend)
const cart = await CartFetcher.fetchCart(request, actionContext.frontasticContext);
quoteRequest = await quoteApi.createQuoteRequest(quoteRequest, cart);
await cartApi.deleteCart(cart);  // Cart is consumed
return {
  statusCode: 200,
  body: JSON.stringify(quoteRequest),
  sessionData: { ...request.sessionData, cartId: undefined },
};
```

Accepting a quote creates an order:
```typescript
// QuoteApi.ts
async acceptQuote(quoteId: string) {
  await this.createOrderFromQuote(quoteId);
  return await this.getQuote(quoteId);
}

async createOrderFromQuote(quoteId: string) {
  return this.associateEndpoints(this.accountId, this.businessUnitKey)
    .orders().orderQuote().post({
      body: {
        version: quote.quoteVersion,
        quote: { typeId: 'quote', id: quote.quoteId },
        quoteStateToAccepted: true,
      },
    }).execute();
}
```

The quote checkout is a separate tastic that reuses the `<Checkout>` component with different translations:
```typescript
<Checkout
  translations={{
    header: translate('checkout.quote-checkout'),
    purchase: translate('checkout.submit-quote-request'),
  }}
  buyerCanAddComment  // B2B: allows buyer comment
  onSubmitPurchase={async ({ buyerComment }) => {
    const quoteRequestId = await selectedPaymentMethod.makePayment({ ...paymentData, buyerComment });
    if (quoteRequestId) router.push(`/quote-thank-you?quoteRequestId=${quoteRequestId}`);
  }}
/>
```

## Pattern 4: Approval Workflows

Two-entity model: `ApprovalRule` (configuration) vs `ApprovalFlow` (runtime instance).

```typescript
// types/business-unit/ApprovalRule.ts
interface ApprovalRule {
  approvalRuleId?: string;
  name: string;
  predicate: string;  // e.g., "order.totalPrice > \"1000 EUR\""
  approvers: ApproverHierarchy;  // Multi-tier AND/OR logic
  requesters: AssociateRole[];
  approvalRuleStatus?: 'Active' | 'Inactive';
}

interface ApproverHierarchy {
  tiers: ApproverConjunction[];  // Tiered approval
}
```

```typescript
// types/business-unit/ApprovalFlow.ts
interface ApprovalFlow {
  approvalFlowId: string;
  order: Order;  // The order being approved
  businessUnitKey: string;
  approvalRules: ApprovalRule[];
  approvalFlowStatus?: 'Pending' | 'Approved' | 'Rejected';
  eligibleApprovers: AssociateRole[];
  pendingApprovers: AssociateRole[];
  currentTierPendingApprovers: AssociateRole[];
}
```

**Critical:** Rejecting an approval flow auto-cancels the order:
```typescript
export const rejectApprovalFlow: ActionHook = async (request, actionContext) => {
  const { approvalFlowId, reason } = parseRequestBody(request.body);
  const approvalFlow = await businessUnitApi.rejectApprovalFlow(businessUnitKey, accountId, approvalFlowId, reason);
  const order = await cartApi.updateOrderState(approvalFlow.order.orderId, OrderState.Cancelled);
  approvalFlow.order = order;
};
```

After checkout, approval flows are refreshed:
```typescript
const { mutateAll: mutateAllApprovalFlows } = useApprovalFlows({ businessUnitKey });
onSubmitPurchase={async () => {
  const orderId = await selectedPaymentMethod.makePayment(paymentData);
  mutateAllApprovalFlows();  // Refresh approval flows
  router.push(`${data.callbackUrl}?orderId=${orderId}`);
}}
```

## Pattern 5: B2B Cart Differences

B2B carts are always scoped to `businessUnitKey + storeKey`:

```typescript
const useCart = (businessUnitKey?: string, storeKey?: string) => {
  const { data, mutate } = useSWR(
    businessUnitKey && storeKey ? `/action/cart/getCart/${businessUnitKey}/${storeKey}` : null,
    getCart,
  );
  const isQuotationCart = data?.origin === 'Quote';
};
```

Backend validates cart belongs to the BU:
```typescript
// CartFetcher.ts
if (cartId) {
  const cart = await cartApi.getById(cartId);
  if (
    cartApi.assertCartIsActive(cart) &&
    cartApi.assertCartForBusinessUnitAndStore(cart, businessUnitKey, storeKey) &&
    cartApi.assertCartOrigin(cart)
  ) { return cart; }
}
```

B2B checkout includes Purchase Order Number (required):
```typescript
interface CheckoutPayload { purchaseOrderNumber: string; }
interface QuoteRequestPayload { buyerComment: string; purchaseOrderNumber: string; }
```

## Pattern 6: B2B Checkout Differences

1. Uses BU addresses (not personal): `addresses={selectedBusinessUnit?.addresses ?? []}`
2. Address addition gated by permission: `canAddAddress = permissions.UpdateBusinessUnitDetails`
3. Purchase Order form (required field):
```typescript
const PurchaseOrderForm = ({ defaultValues, onChange }) => (
  <form>
    <Input label="PO Number" {...register('purchaseOrderNumber', { required: true })} required />
    <Input label="Invoice Memo" showOptionalLabel {...register('invoiceMemo')} />
  </form>
);
```
4. Payment by invoice as default B2B payment method
5. Triggers approval flow refresh after placement

## Pattern 7: Quick Order (B2B Exclusive)

```typescript
// components/organisms/quick-order/quick-order-desktop/index.tsx
const QuickOrderDesktop = ({ searchText, items, csvProducts, onSearch, addItem, handleSKUsUpdate }) => (
  <Drawer direction="right" headline="Quick add to cart">
    <QuickOrderAccordion ... />       {/* SKU search with autocomplete */}
    <QuickOrderCSVUpload ... />       {/* CSV upload for bulk add */}
  </Drawer>
);
```

## Pattern 8: Purchase Lists (B2B Exclusive)

Purchase Lists are built on top of the commercetools Wishlist API but presented as reusable order templates. This is a full CRUD feature with its own types, hooks, tastics, and dashboard pages.

```typescript
// types/entity/purchase-list.ts
interface PurchaseList {
  id: string;
  name: string;
  store: string;
  description: string;
  items: PurchaseListItem[];
  businessUnitKey: string;
  account: { accountId: string };
  createdAt: string;
}

interface PurchaseListItem {
  id: string;
  sku: string;
  name: string;
  image: string;
  price: number;
  currency: string;
  quantity: number;
  inStock: boolean;
  maxQuantity: number;
  specifications: Array<{ label: string; value: string }>;
}
```

Two hooks manage purchase lists:

```typescript
// hooks/usePurchaseLists/index.ts -- all lists
const usePurchaseLists = () => {
  // Fetches all purchase lists (limit 500) via sdk.composableCommerce.wishlist.queryWishlists
  // Provides: createPurchaseList, updatePurchaseList, deletePurchaseList, addToWishlists, removeFromWishlists
};

// hooks/usePurchaseList/index.ts -- single list
const usePurchaseList = (id: string) => {
  // Fetches a single purchase list by ID
  // Provides: addItem, updateItem, removeItem
};
```

Dashboard pages include a table listing all purchase lists (with store, description, BU, item count columns) and a detail page with per-item actions (add to cart, remove, quantity change) and bulk "Add All to Cart". Permission-gated: `ViewMyShoppingLists`/`ViewOthersShoppingLists` for viewing, `CreateMyShoppingLists`/`CreateOthersShoppingLists` for creation.

A mapper (`utils/mappers/map-purchase-list.ts`) converts commercetools `Wishlist` and `LineItem` types to the frontend `PurchaseList` and `PurchaseListItem` types.

## Pattern 9: Company Admin Dashboard

4-tab structure:
```typescript
<Tabs>
  <Tabs.TabList>
    <Tabs.Tab>General</Tabs.Tab>
    <Tabs.Tab>Addresses</Tabs.Tab>
    <Tabs.Tab>Associates</Tabs.Tab>
    <Tabs.Tab>Business Units</Tabs.Tab>
  </Tabs.TabList>
</Tabs>
```

Adding associates auto-creates accounts if needed:
```typescript
// Backend: BusinessUnitController.ts - addAssociate
let account = await accountApi.getAccountByEmail(email);
if (!account) {
  account = await accountApi.create({ email, password: crypto.randomBytes(6).toString('base64').slice(0, 8) });
  const resetToken = await accountApi.generatePasswordResetToken(email);
  emailApi.sendAssociateVerificationAndPasswordResetEmail(account, resetToken);
}
businessUnit = await businessUnitApi.addAssociate(businessUnitKey, accountId, account.accountId, roleKeys);
```

## Pattern 10: Shared Components with B2B Props

Core components are shared between B2C and B2B through optional props:

| Component | Shared | B2B-Specific Props |
|-----------|--------|-------------------|
| `<Checkout>` | Yes | `buyerCanAddComment`, BU addresses, PO number |
| `<Cart>` | Yes | `viewCartDisabled`, `checkoutDisabled`, `quoteRequestDisabled` |
| `<Dashboard>` | Layout only | B2B sidebar items (9 sections vs ~4 in B2C) |
| Product List | Yes | No changes |
| Header | Yes | Quick Order integrated |

B2B-exclusive components: Quick Order, Quote Thank You, Purchase Lists, Approval Flows/Rules pages, Company Admin, Quote Details, Verify Associate.

## Pattern 11: B2B Data Fetching

All B2B SDK calls pass `businessUnitKey` and `storeKey`:
```typescript
sdk.composableCommerce.cart.addItem(payload, {
  businessUnitKey: businessUnitKey as string,
  storeKey: storeKey as string,
});
```

SWR conditional fetching prevents requests before BU context is ready:
```typescript
useSWR(!businessUnitKey ? null : ['/action/quote/query', limit, cursor, ...], ...)
```

Backend uses `associateRequestBuilder` for all B2B API calls (enforces CT-level permissions):
```typescript
this.associateRequestBuilder(accountId)
  .businessUnits().withKey({ key: businessUnitKey })
  .post({ body: { version, actions } }).execute()
```

B2B adds 2 action controller namespaces beyond B2C:
- `business-unit` -> BusinessUnitActions (getBusinessUnits, addAssociate, queryApprovalFlows/Rules, approve/reject)
- `quote` -> QuoteAction (createQuoteRequest, query, accept, decline, renegotiate, cancel)

## B2B Frontend Checklist

- [ ] `StoreAndBusinessUnitsProvider` wraps the app and provides BU/store context
- [ ] All API calls include `businessUnitKey` and `storeKey` parameters
- [ ] `useAccountRoles(businessUnitKey)` gates UI elements based on 47 permissions
- [ ] Cart SWR key includes BU+store to prevent cross-BU data leaks
- [ ] Quote flow handles cart consumption (cart is deleted when quote request is created)
- [ ] Approval flow status is refreshed after checkout
- [ ] Rejection auto-cancels the associated order
- [ ] B2B checkout uses BU addresses, not personal addresses
- [ ] Purchase Order Number field is present and required in checkout
- [ ] Company admin validates `UpdateBusinessUnitDetails` and `UpdateAssociates` permissions
- [ ] Associate auto-creation sends verification and password reset emails
- [ ] Quick Order supports both SKU search and CSV upload
- [ ] SWR uses null key pattern to prevent fetching before BU context is established
- [ ] Purchase Lists use the Wishlist API with proper mapper (Wishlist -> PurchaseList)
- [ ] Purchase Lists gate creation on `CreateMyShoppingLists`/`CreateOthersShoppingLists` permissions
- [ ] Shared components accept optional B2B props without breaking B2C usage

## Reference

- [Business Units API](https://docs.commercetools.com/api/projects/business-units)
- [Associate Roles](https://docs.commercetools.com/api/projects/associate-roles)
- [Approval Rules](https://docs.commercetools.com/api/projects/approval-rules)
- [Approval Flows](https://docs.commercetools.com/api/projects/approval-flows)
- [Quotes API](https://docs.commercetools.com/api/projects/quotes)
- [Quote Requests API](https://docs.commercetools.com/api/projects/quote-requests)
- [B2B Associate Endpoints](https://docs.commercetools.com/api/associates-overview)
