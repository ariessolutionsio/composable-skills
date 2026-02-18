# Customer Management

Customers in commercetools hold authentication credentials, addresses, group memberships, and custom fields. The API supports up to 10,000,000 customers per project. Getting authentication flows, email verification, and customer scoping wrong leads to security vulnerabilities, broken login, and data isolation failures.

## Customer Creation

```typescript
const customerResponse = await apiRoot.customers().post({
  body: {
    key: 'customer-max',
    email: 'max@example.com',
    password: 'securePassword123',
    firstName: 'Max',
    lastName: 'Mustermann',
    addresses: [
      {
        key: 'home-address',
        country: 'DE',
        firstName: 'Max',
        lastName: 'Mustermann',
        streetName: 'Hauptstrasse',
        streetNumber: '1',
        postalCode: '10115',
        city: 'Berlin',
      },
    ],
    defaultShippingAddress: 0, // index into addresses array
    defaultBillingAddress: 0,
  },
}).execute();

// Response wraps the customer in a CustomerSignInResult
const customer = customerResponse.body.customer;
// customer.isEmailVerified === false (always starts unverified)
```

## Customer Authentication

### Login

```typescript
const loginResult = await apiRoot.login().post({
  body: {
    email: 'max@example.com',
    password: 'securePassword123',
  },
}).execute();

const authenticatedCustomer = loginResult.body.customer;
```

### Login with Anonymous Cart Merge

When a guest user logs in, merge their anonymous cart with their customer cart.

```typescript
const loginResult = await apiRoot.login().post({
  body: {
    email: 'max@example.com',
    password: 'securePassword123',
    anonymousCart: {
      typeId: 'cart',
      id: 'anonymous-cart-id',
    },
    anonymousCartSignInMode: 'MergeWithExistingCustomerCart',
    // Alternative: 'UseAsNewActiveCustomerCart'
  },
}).execute();

// loginResult.body.cart contains the merged cart
```

### Authentication Modes

| Mode | Use Case |
|------|----------|
| `Password` | Standard email/password authentication |
| `ExternalAuth` | SSO or external identity providers (no password stored in commercetools) |

```typescript
// Creating a customer for external auth (SSO)
const externalCustomer = await apiRoot.customers().post({
  body: {
    email: 'sso-user@example.com',
    authenticationMode: 'ExternalAuth',
    // No password required
    firstName: 'SSO',
    lastName: 'User',
  },
}).execute();
```

## Email Verification Flow

**Anti-Pattern (skipping verification):**
```typescript
// WRONG: Trusting unverified email addresses
const customer = await apiRoot.customers().post({
  body: { email: input.email, password: input.password },
}).execute();
// Immediately using the email for order confirmations, password resets, etc.
// without verification allows account takeover
```

**Recommended (full verification flow):**
```typescript
// Step 1: Create the customer (isEmailVerified starts as false)
const customerResponse = await apiRoot.customers().post({
  body: { email: 'max@example.com', password: 'securePassword123' },
}).execute();
const customer = customerResponse.body.customer;

// Step 2: Generate an email verification token
const tokenResponse = await apiRoot.customers().emailToken().post({
  body: {
    id: customer.id,
    ttlMinutes: 60, // token valid for 60 minutes
  },
}).execute();
const emailToken = tokenResponse.body.value;

// Step 3: Send the token to the customer via email (your email service)
await sendVerificationEmail(customer.email, emailToken);

// Step 4: When the customer clicks the verification link
const verified = await apiRoot.customers().emailConfirm().post({
  body: { tokenValue: emailToken },
}).execute();
// verified.body.isEmailVerified === true
```

## Password Management

### Password Reset Flow

```typescript
// Step 1: Customer requests a password reset
const resetToken = await apiRoot.customers().passwordToken().post({
  body: {
    email: 'max@example.com',
    ttlMinutes: 30,
  },
}).execute();

// Step 2: Send the token to the customer via email
await sendPasswordResetEmail('max@example.com', resetToken.body.value);

// Step 3: Customer submits new password with the token
const resetResult = await apiRoot.customers().passwordReset().post({
  body: {
    tokenValue: resetToken.body.value,
    newPassword: 'newSecurePassword456',
  },
}).execute();
```

### Password Change (Authenticated)

```typescript
const changed = await apiRoot.customers().password().post({
  body: {
    id: customer.id,
    version: customer.version,
    currentPassword: 'currentPassword',
    newPassword: 'newPassword',
  },
}).execute();
```

## Customer Groups

Customer groups drive price selection and discount targeting. When a customer belongs to a group, prices specific to that group are selected from product variant prices.

```typescript
// Assign a customer to a group
const updated = await apiRoot.customers().withKey({ key: 'customer-max' }).post({
  body: {
    version: customer.version,
    actions: [
      {
        action: 'setCustomerGroup',
        customerGroup: { key: 'gold-tier' },
      },
    ],
  },
}).execute();
```

### Multiple Group Assignments

For B2B scenarios where a customer needs multiple pricing tiers, use `customerGroupAssignments`.

```typescript
const multiGroup = await apiRoot.customers().withId({ ID: customerId }).post({
  body: {
    version: customer.version,
    actions: [
      {
        action: 'addCustomerGroupAssignment',
        customerGroupAssignment: {
          customerGroup: { typeId: 'customer-group', key: 'wholesale' },
        },
      },
      {
        action: 'addCustomerGroupAssignment',
        customerGroupAssignment: {
          customerGroup: { typeId: 'customer-group', key: 'preferred-vendor' },
        },
      },
    ],
  },
}).execute();
```

## Address Management

Customers can have multiple addresses with designated defaults and shipping/billing categorization.

```typescript
// Add a new address
const addressAdded = await apiRoot.customers().withId({ ID: customerId }).post({
  body: {
    version: customer.version,
    actions: [
      {
        action: 'addAddress',
        address: {
          key: 'vacation-home',
          streetName: 'Strandweg',
          streetNumber: '7',
          postalCode: '23669',
          city: 'Timmendorfer Strand',
          country: 'DE',
        },
      },
    ],
  },
}).execute();

// Set as default shipping address
const defaultSet = await apiRoot.customers().withId({ ID: customerId }).post({
  body: {
    version: addressAdded.body.version,
    actions: [
      { action: 'setDefaultShippingAddress', addressKey: 'vacation-home' },
    ],
  },
}).execute();

// Add to billing address IDs (makes it selectable as a billing address)
await apiRoot.customers().withId({ ID: customerId }).post({
  body: {
    version: defaultSet.body.version,
    actions: [
      { action: 'addBillingAddressId', addressKey: 'home-address' },
    ],
  },
}).execute();
```

**Why This Matters:** Address keys prevent duplicate addresses. Always use keys when managing addresses programmatically so you can reference them without tracking internal IDs.

## Custom Fields on Customers

```typescript
// Set a custom type with fields
await apiRoot.customers().withId({ ID: customerId }).post({
  body: {
    version: customer.version,
    actions: [
      {
        action: 'setCustomType',
        type: { key: 'customer-preferences', typeId: 'type' },
        fields: {
          loyaltyPoints: 500,
          preferredContactMethod: 'email',
          marketingOptIn: true,
        },
      },
    ],
  },
}).execute();

// Update a single custom field
await apiRoot.customers().withId({ ID: customerId }).post({
  body: {
    version: newVersion,
    actions: [
      { action: 'setCustomField', name: 'loyaltyPoints', value: 750 },
    ],
  },
}).execute();
```

## Store-Scoped Customers

commercetools supports two customer scoping models:

| Model | Behavior |
|-------|----------|
| **Global** | Customer is unique across the entire project (no `stores` set) |
| **Store-Specific** | Customer is unique within their assigned stores only |

**Anti-Pattern (mixing global and store-specific):**
```typescript
// Creating a customer without understanding scoping leads to
// duplicate accounts or inaccessible customers
const customer = await apiRoot.customers().post({
  body: { email: 'user@example.com', password: 'pass' },
}).execute();
// This is a global customer — accessible from any store

// Later, trying to access via store endpoint fails if customer has no store
const storeCustomer = await apiRoot
  .inStoreKeyWithStoreKeyValue({ storeKey: 'us-store' })
  .customers()
  .withId({ ID: customer.body.customer.id })
  .get()
  .execute(); // May fail if customer is not associated with this store
```

**Recommended (intentional scoping):**
```typescript
// Store-specific customer: create through the store endpoint
const storeCustomer = await apiRoot
  .inStoreKeyWithStoreKeyValue({ storeKey: 'us-store' })
  .customers()
  .post({
    body: {
      email: 'store-user@example.com',
      password: 'securePassword',
      stores: [{ key: 'us-store' }],
    },
  })
  .execute();
// This customer can only be accessed via the us-store endpoint
// Email uniqueness is enforced within the store scope only
```

## Querying Customers

```typescript
// By email
const byEmail = await apiRoot.customers().get({
  queryArgs: {
    where: `email="${encodeURIComponent('max@example.com')}"`,
  },
}).execute();

// By custom field
const byLoyalty = await apiRoot.customers().get({
  queryArgs: {
    where: 'custom(fields(loyaltyPoints > 100))',
    sort: ['custom.fields.loyaltyPoints desc'],
    limit: 50,
  },
}).execute();

// By customer group
const goldCustomers = await apiRoot.customers().get({
  queryArgs: {
    where: 'customerGroup(key="gold-tier")',
    limit: 100,
  },
}).execute();
```

## Anonymous-to-Customer Conversion

When a guest user creates an account, consolidate their anonymous activity.

```typescript
// Create customer with anonymous cart and ID
const customerResponse = await apiRoot.customers().post({
  body: {
    email: 'new@example.com',
    password: 'securePassword',
    anonymousCart: { typeId: 'cart', id: 'anonymous-cart-id' },
    anonymousId: 'anonymous-session-id',
    // This associates the anonymous cart, orders, and payments with the new customer
  },
}).execute();
```

## Checklist

- [ ] Email verification flow is implemented (never trust unverified emails)
- [ ] Password reset uses time-limited tokens (30-60 minutes)
- [ ] Customer scoping (global vs store-specific) is decided upfront
- [ ] Address keys are used for programmatic address management
- [ ] Customer groups are assigned for pricing tier differentiation
- [ ] Anonymous carts are merged on login or account creation
- [ ] Custom type fields use unique, prefixed names to avoid conflicts
- [ ] Authentication mode is set correctly (Password vs ExternalAuth)
- [ ] Store-scoped customers are created through store endpoints
- [ ] Customer queries use server-side predicates, not client-side filtering
