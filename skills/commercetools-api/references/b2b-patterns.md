# B2B Commerce Patterns

commercetools B2B features revolve around Business Units, Associate Roles, Approval Rules, and Quotes. These features model real-world organizational hierarchies with permission-based access control. Getting the hierarchy design wrong early is extremely costly to fix because approval workflows, catalog visibility, and pricing all depend on the Business Unit structure.

## Business Unit Hierarchy

Business Units are organized in a tree with Companies at the top and Divisions as children. Maximum 5 levels deep, maximum 2,000 associates per unit.

| Type | Position | Inheritance |
|------|----------|-------------|
| Company | Always top-level | Explicitly manages stores, associates, approval rules |
| Division | Child of Company or another Division | Can inherit from parent or manage explicitly |

### Creating a Company

```typescript
const company = await apiRoot.businessUnits().post({
  body: {
    key: 'acme-corp',
    name: 'ACME Corporation',
    unitType: 'Company',
    contactEmail: 'procurement@acme.com',
    addresses: [
      {
        key: 'hq-address',
        country: 'US',
        city: 'San Francisco',
        streetName: 'Market St',
        streetNumber: '123',
        postalCode: '94102',
      },
    ],
    defaultShippingAddress: 0,
    defaultBillingAddress: 0,
  },
}).execute();
```

### Creating Divisions

```typescript
const engineering = await apiRoot.businessUnits().post({
  body: {
    key: 'acme-engineering',
    name: 'ACME Engineering Division',
    unitType: 'Division',
    parentUnit: { typeId: 'business-unit', key: 'acme-corp' },
    contactEmail: 'engineering@acme.com',
    // storeMode: 'FromParent' — inherits stores from parent
    // associateMode: 'ExplicitAndFromParent' — has own + inherits parent associates
  },
}).execute();

const marketing = await apiRoot.businessUnits().post({
  body: {
    key: 'acme-marketing',
    name: 'ACME Marketing Division',
    unitType: 'Division',
    parentUnit: { typeId: 'business-unit', key: 'acme-corp' },
  },
}).execute();
```

### Inheritance Modes

Divisions can inherit three resource types from their parent:

| Resource | Modes | Default |
|----------|-------|---------|
| Stores | `Explicit`, `FromParent` | `FromParent` |
| Associates | `Explicit`, `ExplicitAndFromParent` | `ExplicitAndFromParent` |
| Approval Rules | `Explicit`, `ExplicitAndFromParent` | `ExplicitAndFromParent` |

**Anti-Pattern (accidentally disabling inheritance):**
```typescript
// WRONG: Setting associateMode to Explicit removes parent associates
// All approval workflows that depend on parent-level approvers break
await apiRoot.businessUnits().withKey({ key: 'acme-engineering' }).post({
  body: {
    version,
    actions: [
      { action: 'setAssociateMode', associateMode: 'Explicit' },
    ],
  },
}).execute();
// Parent company admins can no longer approve orders for this division
```

**Recommended (plan inheritance before changing modes):**
```typescript
// Document the inheritance model for each division
// Test changes in staging before applying to production
// Consider: who needs to approve orders? who manages carts? who sees orders?
```

**Why This Matters:** Inheritance changes are eventually consistent and can break existing approval workflows without warning. A parent admin who could previously approve orders for a division may suddenly lose access.

## Associate Roles and Permissions

Associates are customers who hold specific roles within a Business Unit. Roles define what actions they can perform.

### Creating Roles

```typescript
// Admin role — full management capabilities
const adminRole = await apiRoot.associateRoles().post({
  body: {
    key: 'admin',
    name: 'Admin',
    buyerAssignable: true,
    permissions: [
      'AddChildUnits',
      'UpdateBusinessUnitDetails',
      'UpdateAssociates',
      'CreateMyCarts',
      'CreateOthersCarts',
      'UpdateMyCarts',
      'UpdateOthersCarts',
      'ViewMyCarts',
      'ViewOthersCarts',
      'CreateMyOrdersFromMyCarts',
      'ViewMyOrders',
      'ViewOthersOrders',
      'UpdateMyOrders',
      'UpdateOthersOrders',
      'CreateApprovalRules',
      'UpdateApprovalRules',
      'UpdateApprovalFlows',
    ],
  },
}).execute();

// Buyer role — can create carts and orders, request quotes
const buyerRole = await apiRoot.associateRoles().post({
  body: {
    key: 'buyer',
    name: 'Buyer',
    buyerAssignable: true,
    permissions: [
      'CreateMyCarts',
      'UpdateMyCarts',
      'ViewMyCarts',
      'CreateMyOrdersFromMyCarts',
      'ViewMyOrders',
      'UpdateMyOrders',
      'CreateMyQuoteRequestsFromMyCarts',
      'ViewMyQuotes',
      'AcceptMyQuotes',
      'DeclineMyQuotes',
      'RenegotiateMyQuotes',
    ],
  },
}).execute();

// Approver role — can view and approve others' orders and quotes
const approverRole = await apiRoot.associateRoles().post({
  body: {
    key: 'approver',
    name: 'Approver',
    buyerAssignable: true,
    permissions: [
      'ViewOthersCarts',
      'ViewOthersOrders',
      'UpdateApprovalFlows',
      'ViewMyQuotes',
      'ViewOthersQuotes',
      'AcceptOthersQuotes',
      'DeclineOthersQuotes',
    ],
  },
}).execute();
```

### Adding Associates to a Business Unit

```typescript
await apiRoot.businessUnits().withKey({ key: 'acme-corp' }).post({
  body: {
    version: company.body.version,
    actions: [
      {
        action: 'addAssociate',
        associate: {
          customer: { typeId: 'customer', id: 'buyer-customer-id' },
          associateRoleAssignments: [
            {
              associateRole: { typeId: 'associate-role', key: 'buyer' },
              inheritance: 'Enabled', // inherits to child divisions
            },
          ],
        },
      },
    ],
  },
}).execute();
```

### Security: Associate Endpoints

**Anti-Pattern (calling associate endpoints from the frontend):**
```typescript
// WRONG: Associate endpoints verify permissions based on URL parameters
// but do NOT validate those parameters against OAuth scopes
// A malicious user could access data outside their authorization
const orders = await fetch(
  `/proxy/as-associate/${userId}/in-business-unit/${unitKey}/orders`
);
// Frontend can manipulate userId and unitKey
```

**Recommended (call from trusted backend only):**
```typescript
// Associate endpoints should only be called from your backend/BFF
// Validate the associate's identity against your session before making the call
async function getAssociateOrders(sessionUserId: string, businessUnitKey: string) {
  // Validate session user is actually an associate of this BU
  const bu = await apiRoot.businessUnits().withKey({ key: businessUnitKey }).get().execute();
  const isAssociate = bu.body.associates.some(
    (a) => a.customer.id === sessionUserId
  );
  if (!isAssociate) throw new ForbiddenError('Not an associate of this unit');

  return apiRoot
    .asAssociate()
    .withAssociateIdValue({ associateId: sessionUserId })
    .inBusinessUnitKeyWithBusinessUnitKeyValue({ businessUnitKey })
    .orders()
    .get()
    .execute();
}
```

## Associate-Scoped Operations

B2B operations use the `/as-associate/` path to enforce role-based permissions.

```typescript
// Create a cart as an associate
const b2bCart = await apiRoot
  .asAssociate()
  .withAssociateIdValue({ associateId: 'buyer-customer-id' })
  .inBusinessUnitKeyWithBusinessUnitKeyValue({ businessUnitKey: 'acme-corp' })
  .carts()
  .post({
    body: {
      currency: 'USD',
      lineItems: [{ sku: 'BULK-WIDGET-001', quantity: 500 }],
    },
  })
  .execute();

// Create an order as an associate
const b2bOrder = await apiRoot
  .asAssociate()
  .withAssociateIdValue({ associateId: 'buyer-customer-id' })
  .inBusinessUnitKeyWithBusinessUnitKeyValue({ businessUnitKey: 'acme-corp' })
  .orders()
  .post({
    body: {
      cart: { id: b2bCart.body.id, typeId: 'cart' },
      version: b2bCart.body.version,
    },
  })
  .execute();
```

## Approval Rules

Approval Rules define when orders require approval and who can approve them. They are scoped to a Business Unit.

### Creating an Approval Rule

```typescript
const approvalRule = await apiRoot
  .asAssociate()
  .withAssociateIdValue({ associateId: 'admin-customer-id' })
  .inBusinessUnitKeyWithBusinessUnitKeyValue({ businessUnitKey: 'acme-corp' })
  .approvalRules()
  .post({
    body: {
      name: 'High Value Order Approval',
      description: 'Orders over $1000 require approver sign-off',
      status: 'Active',
      predicate: 'order.totalPrice.centAmount >= 100000', // >= $1000.00
      requesters: [
        { associateRole: { typeId: 'associate-role', key: 'buyer' } },
      ],
      approvers: {
        tiers: [
          {
            and: [
              { associateRole: { typeId: 'associate-role', key: 'approver' } },
            ],
          },
        ],
      },
    },
  })
  .execute();
```

### Multi-Tier Approval

```typescript
// Manager approves first, then director
const multiTierRule = await apiRoot
  .asAssociate()
  .withAssociateIdValue({ associateId: 'admin-customer-id' })
  .inBusinessUnitKeyWithBusinessUnitKeyValue({ businessUnitKey: 'acme-corp' })
  .approvalRules()
  .post({
    body: {
      name: 'Executive Approval for Large Orders',
      status: 'Active',
      predicate: 'order.totalPrice.centAmount >= 500000', // >= $5000
      requesters: [
        { associateRole: { typeId: 'associate-role', key: 'buyer' } },
      ],
      approvers: {
        tiers: [
          // Tier 1: Manager approval
          {
            and: [
              { associateRole: { typeId: 'associate-role', key: 'approver' } },
            ],
          },
          // Tier 2: Director approval (after tier 1 passes)
          {
            and: [
              { associateRole: { typeId: 'associate-role', key: 'admin' } },
            ],
          },
        ],
      },
    },
  })
  .execute();
```

### Approval Rule Constraints

- Maximum 5 tiers per rule
- Only ONE approval rule applies per order (the most specific match)
- A single rejection at any tier rejects the entire flow
- The order must be resubmitted from scratch after rejection

**Anti-Pattern (not freezing carts before approval):**
```typescript
// WRONG: Prices can change during a multi-day approval cycle
// The approved price may differ from the final charged price
const order = await apiRoot.asAssociate()
  .withAssociateIdValue({ associateId: buyerId })
  .inBusinessUnitKeyWithBusinessUnitKeyValue({ businessUnitKey })
  .orders().post({
    body: { cart: { id: cartId, typeId: 'cart' }, version: cartVersion },
  }).execute();
// Approval takes 3 days; a promotion expires during that time
```

**Recommended (freeze cart before submission for approval):**
```typescript
// Freeze the cart to lock prices during the approval period
const frozen = await apiRoot.carts().withId({ ID: cartId }).post({
  body: {
    version: cartVersion,
    actions: [{ action: 'freezeCart' }],
  },
}).execute();

// Then create the order (which enters the approval flow)
const order = await apiRoot.asAssociate()
  .withAssociateIdValue({ associateId: buyerId })
  .inBusinessUnitKeyWithBusinessUnitKeyValue({ businessUnitKey })
  .orders().post({
    body: { cart: { id: frozen.body.id, typeId: 'cart' }, version: frozen.body.version },
  }).execute();
```

## Quote Lifecycle (B2B Negotiation)

The quote flow: QuoteRequest -> StagedQuote -> Quote -> Order

```typescript
// Step 1: Buyer creates a Quote Request from a Cart
const quoteRequest = await apiRoot.quoteRequests().post({
  body: {
    cart: { typeId: 'cart', id: 'buyer-cart-id' },
    cartVersion: cartVersion,
    comment: 'Requesting bulk discount for 500+ units',
  },
}).execute();

// Step 2: Seller creates a Staged Quote (begins preparing the offer)
const stagedQuote = await apiRoot.stagedQuotes().post({
  body: {
    quoteRequest: { typeId: 'quote-request', id: quoteRequest.body.id },
    quoteRequestVersion: quoteRequest.body.version,
    quoteRequestStateToAccepted: true,
  },
}).execute();

// Step 3: Seller finalizes and creates a legally binding Quote
const quote = await apiRoot.quotes().post({
  body: {
    stagedQuote: { typeId: 'staged-quote', id: stagedQuote.body.id },
    stagedQuoteVersion: stagedQuote.body.version,
    stagedQuoteStateToSent: true,
  },
}).execute();

// Step 4: Buyer accepts the Quote
const accepted = await apiRoot.quotes().withId({ ID: quote.body.id }).post({
  body: {
    version: quote.body.version,
    actions: [{ action: 'changeQuoteState', quoteState: 'Accepted' }],
  },
}).execute();

// Step 5: Create an Order from the accepted Quote
const order = await apiRoot.orders().post({
  body: {
    quote: { typeId: 'quote', id: accepted.body.id },
    version: accepted.body.version,
    quoteStateToAccepted: true,
  },
}).execute();
```

### Quote Constraints

- Quote Requests cannot be modified after submission
- Implement a "draft" stage in your application before creating the commercetools Quote Request
- Direct Discounts from quotes block discount codes on the resulting cart
- Required Quote-related permissions must be explicitly assigned to Associate Roles

**Anti-Pattern (missing quote permissions):**
```typescript
// Buyer gets AssociateMissingPermission error when trying to request a quote
// Because the role is missing CreateMyQuoteRequestsFromMyCarts permission
```

**Recommended (complete quote permissions):**
```typescript
// Ensure buyer role includes all quote-related permissions
const buyerPermissions = [
  'CreateMyQuoteRequestsFromMyCarts',
  'AcceptMyQuotes',
  'DeclineMyQuotes',
  'RenegotiateMyQuotes',
  'ViewMyQuotes',
];
```

## Checklist

- [ ] Business Unit hierarchy is designed at the start of the project
- [ ] Inheritance modes (stores, associates, approval rules) are explicitly set
- [ ] Associate endpoints are called only from trusted backend services
- [ ] Approval rules use frozen carts to lock prices during approval cycles
- [ ] Quote permissions are explicitly assigned to relevant associate roles
- [ ] Single-rejection-kills-flow constraint is accounted for in approval design
- [ ] Quote Requests are validated thoroughly before submission (immutable after)
- [ ] Inheritance changes are tested in staging before production
- [ ] Associate roles follow least-privilege principle
- [ ] B2B operations use the `/as-associate/` path for permission enforcement
