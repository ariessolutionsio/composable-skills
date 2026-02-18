# Custom Types vs Custom Objects

**Impact: CRITICAL -- One Custom Type per resource. Field type changes silently fail.**

commercetools provides two distinct extensibility mechanisms for custom data, and confusing them is one of the most common mistakes in implementations. Using the wrong one puts data in unreachable places and creates architectural debt that is expensive to unwind.

## The Core Distinction

| | Custom Types (Custom Fields) | Custom Objects |
|---|---|---|
| **Purpose** | Extend an existing resource with additional fields | Store standalone data unrelated to a specific resource instance |
| **Attached to** | A specific resource instance (Customer, LineItem, Order, Category, etc.) | Nothing -- standalone container/key storage |
| **Schema** | Typed fields defined in a Type definition | Arbitrary JSON (no schema enforcement) |
| **Constraint** | **Only ONE Type per resource at a time** | No limit on containers or keys |
| **Query** | Queryable via resource predicates: `custom(fields(name="value"))` | Queryable by container and key; limited predicate support on value |
| **When to use** | Loyalty points on Customer, gift wrap on LineItem, metadata on Order | Feature flags, lookup tables, app config, sync tracking, cross-cutting reference data |

## The One-Type-Per-Resource Constraint

This is the most misunderstood limitation in commercetools extensibility:

> "Multiple Types can be created for a single resource or data type, but a particular resource or data type can be customized with only one Type at the same time."

**Anti-Pattern (multiple services each assigning their own type):**

```typescript
import { TypeDraft } from '@commercetools/platform-sdk';

// Service A creates its own type for line items
const taxServiceType: TypeDraft = {
  key: 'tax-service-fields',
  name: { en: 'Tax Service Fields' },
  resourceTypeIds: ['line-item'],
  fieldDefinitions: [
    {
      name: 'taxRate',
      label: { en: 'Tax Rate' },
      type: { name: 'Number' },
      required: false,
      inputHint: 'SingleLine',
    },
    {
      name: 'taxExempt',
      label: { en: 'Tax Exempt' },
      type: { name: 'Boolean' },
      required: false,
      inputHint: 'SingleLine',
    },
  ],
};

// Service B creates a DIFFERENT type for line items
const loyaltyServiceType: TypeDraft = {
  key: 'loyalty-service-fields',
  name: { en: 'Loyalty Service Fields' },
  resourceTypeIds: ['line-item'],
  fieldDefinitions: [
    {
      name: 'pointsEarned',
      label: { en: 'Points Earned' },
      type: { name: 'Number' },
      required: false,
      inputHint: 'SingleLine',
    },
  ],
};

// PROBLEM: When Service B sets its type on a line item,
// it OVERWRITES Service A's type. Service A's data is GONE.
await apiRoot.carts().withId({ ID: cartId }).post({
  body: {
    version,
    actions: [{
      action: 'setLineItemCustomType',
      lineItemId: lineItemId,
      type: { key: 'loyalty-service-fields', typeId: 'type' },
      fields: { pointsEarned: 100 },
      // This silently destroys the tax data set by Service A
    }],
  },
}).execute();
```

**Recommended (Composable Custom Type pattern):**

```typescript
import { TypeDraft } from '@commercetools/platform-sdk';

// ONE shared type with namespace-prefixed field names
const composableLineItemType: TypeDraft = {
  key: 'line-item-custom-fields',
  name: { en: 'Line Item Custom Fields' },
  resourceTypeIds: ['line-item'],
  fieldDefinitions: [
    // Tax service fields -- prefixed with "tax-"
    {
      name: 'tax-rate',
      label: { en: 'Tax Rate' },
      type: { name: 'Number' },
      required: false,
      inputHint: 'SingleLine',
    },
    {
      name: 'tax-exempt',
      label: { en: 'Tax Exempt' },
      type: { name: 'Boolean' },
      required: false,
      inputHint: 'SingleLine',
    },
    // Loyalty service fields -- prefixed with "loyalty-"
    {
      name: 'loyalty-pointsEarned',
      label: { en: 'Points Earned' },
      type: { name: 'Number' },
      required: false,
      inputHint: 'SingleLine',
    },
    // Shipping service fields -- prefixed with "shipping-"
    {
      name: 'shipping-trackingNumber',
      label: { en: 'Tracking Number' },
      type: { name: 'String' },
      required: false,
      inputHint: 'SingleLine',
    },
  ],
};

// Each service sets only its own fields using setCustomField
// This does NOT overwrite other services' fields

// Tax service updates its fields
await apiRoot.carts().withId({ ID: cartId }).post({
  body: {
    version,
    actions: [
      {
        action: 'setLineItemCustomField',
        lineItemId,
        name: 'tax-rate',
        value: 0.19,
      },
      {
        action: 'setLineItemCustomField',
        lineItemId,
        name: 'tax-exempt',
        value: false,
      },
    ],
  },
}).execute();

// Loyalty service updates its fields (without touching tax fields)
await apiRoot.carts().withId({ ID: cartId }).post({
  body: {
    version: newVersion,
    actions: [{
      action: 'setLineItemCustomField',
      lineItemId,
      name: 'loyalty-pointsEarned',
      value: 100,
    }],
  },
}).execute();
```

**Why This Matters:** With `setCustomType`, you replace the entire type and all its field values. With `setCustomField`, you update a single field without affecting others. The composable pattern requires that the shared type is set once (typically by the first service that touches the resource), then all services use `setCustomField` for their individual fields.

## Custom Type Field Definitions

### Supported Field Types

```typescript
// All available field types for Custom Type definitions
const fieldExamples = [
  { name: 'stringField',     type: { name: 'String' } },
  { name: 'localizedField',  type: { name: 'LocalizedString' } },
  { name: 'numberField',     type: { name: 'Number' } },
  { name: 'booleanField',    type: { name: 'Boolean' } },
  { name: 'moneyField',      type: { name: 'Money' } },
  { name: 'dateField',       type: { name: 'Date' } },
  { name: 'timeField',       type: { name: 'Time' } },
  { name: 'dateTimeField',   type: { name: 'DateTime' } },
  { name: 'enumField',       type: { name: 'Enum', values: [
    { key: 'option-a', label: 'Option A' },
  ] } },
  { name: 'localizedEnum',   type: { name: 'LocalizedEnum', values: [
    { key: 'option-a', label: { en: 'Option A', de: 'Option A' } },
  ] } },
  { name: 'referenceField',  type: { name: 'Reference', referenceTypeId: 'product' } },
  { name: 'setOfStrings',    type: { name: 'Set', elementType: { name: 'String' } } },
];
```

### Field Definition Constraints

- **Field name pattern:** `^[A-Za-z0-9_-]+$` (alphanumeric, underscores, hyphens)
- **Field name length:** 2-36 characters
- **Field names must be unique** per `resourceTypeId`
- **`inputHint`:** `SingleLine` (default) or `MultiLine` for string-based types

### Applicable Resource Types

Custom Types can extend 40+ resource and data types. Key `resourceTypeId` values:

**Core commerce:** `customer`, `category`, `order`, `cart`, `payment`, `review`, `store`, `channel`, `shopping-list`

**Line items:** `line-item`, `custom-line-item`, `shopping-list-text-line-item`

**Order sub-resources:** `order-delivery`, `order-parcel`, `order-return-item`

**Pricing:** `product-price`, `standalone-price`, `inventory-entry`

**Discounts:** `cart-discount`, `discount-code`

**Payments:** `payment`, `payment-interface-interaction`, `transaction`

**Addresses & Assets:** `address` (on Customer, Cart, Order, Channel, BusinessUnit), `asset` (on Category, ProductVariant)

**B2B:** `business-unit`, `associate-role`, `approval-flow`, `approval-rule`, `quote`

**Other:** `customer-group`, `order-edit`, `product-selection`, `product-tailoring`, `shipping-method`, `shipping`, `recurring-order`

## The Field Type Change Trap

**Anti-Pattern (changing a field type after creation):**

```typescript
// DANGER: Attempting to change a field type
// This may appear to succeed but does NOT actually change the type
await apiRoot.types().withKey({ key: 'my-type' }).post({
  body: {
    version,
    actions: [
      {
        action: 'removeFieldDefinition',
        fieldName: 'status',
      },
      {
        action: 'addFieldDefinition',
        fieldDefinition: {
          name: 'status',  // Same name, different type
          label: { en: 'Status' },
          type: { name: 'String' },  // Was Enum, now String
          required: false,
          inputHint: 'SingleLine',
        },
      },
    ],
  },
}).execute();
// This is UNRELIABLE. The remove-and-add with the same name in the same
// request may cause unexpected behavior. Even across separate requests,
// existing resource data may not align with the new type.
```

**Recommended (new field with migration):**

```typescript
// Step 1: Add new field with correct type
await apiRoot.types().withKey({ key: 'my-type' }).post({
  body: {
    version,
    actions: [{
      action: 'addFieldDefinition',
      fieldDefinition: {
        name: 'statusV2',
        label: { en: 'Status' },
        type: { name: 'String' },
        required: false,
        inputHint: 'SingleLine',
      },
    }],
  },
}).execute();

// Step 2: Migrate data from old field to new field on all resources
// (batch process using query + update)

// Step 3: Update all consumers to read from 'statusV2'

// Step 4: Remove old field once migration is verified
await apiRoot.types().withKey({ key: 'my-type' }).post({
  body: {
    version: newVersion,
    actions: [{
      action: 'removeFieldDefinition',
      fieldName: 'status',
    }],
  },
}).execute();
```

**Why This Matters:** The API may report success when you change a field type, but the change may not actually take effect. This leads to silent data corruption where the schema says one thing and the data says another. Always create a new field and migrate.

## Custom Objects: When and How

### Good Use Cases for Custom Objects

```typescript
import { CustomObjectDraft } from '@commercetools/platform-sdk';

// 1. Application configuration
const appConfig: CustomObjectDraft = {
  container: 'app-config',
  key: 'storefront-settings',
  value: {
    featuredCategoryId: 'cat-summer-2025',
    maxCartItems: 50,
    enableWishlist: true,
    maintenanceMode: false,
  },
};

// 2. Lookup tables / reference data
const sizeLookup: CustomObjectDraft = {
  container: 'size-charts',
  key: 'mens-tops',
  value: {
    XS: { chest: '34-36', length: '27' },
    S:  { chest: '36-38', length: '28' },
    M:  { chest: '38-40', length: '29' },
    L:  { chest: '40-42', length: '30' },
    XL: { chest: '42-44', length: '31' },
  },
};

// 3. Sync tracking metadata
const syncState: CustomObjectDraft = {
  container: 'erp-sync',
  key: 'last-product-sync',
  value: {
    lastSyncTimestamp: '2025-12-01T10:30:00.000Z',
    lastSyncedProductKey: 'product-abc-123',
    recordsProcessed: 15420,
    status: 'completed',
  },
};

// 4. Feature flags
const featureFlags: CustomObjectDraft = {
  container: 'feature-flags',
  key: 'storefront',
  value: {
    newCheckoutFlow: true,
    enableProductRecommendations: false,
    a11yImprovements: true,
    betaSearchAlgorithm: false,
  },
};
```

### Custom Object CRUD

```typescript
// CREATE or UPDATE (upsert behavior -- same container+key updates existing)
const result = await apiRoot
  .customObjects()
  .post({ body: appConfig })
  .execute();

// READ by container + key
const fetched = await apiRoot
  .customObjects()
  .withContainerAndKey({ container: 'app-config', key: 'storefront-settings' })
  .get()
  .execute();

// QUERY all objects in a container
const allConfigs = await apiRoot
  .customObjects()
  .withContainer({ container: 'app-config' })
  .get()
  .execute();

// DELETE (requires version for optimistic concurrency)
await apiRoot
  .customObjects()
  .withContainerAndKey({ container: 'app-config', key: 'storefront-settings' })
  .delete({ queryArgs: { version: result.body.version } })
  .execute();
```

### Custom Object Key and Container Constraints

| Property | Min Length | Max Length | Allowed Characters |
|----------|-----------|-----------|-------------------|
| `container` | 1 | 256 | `^[-_~.a-zA-Z0-9]+$` (alphanumeric, hyphens, underscores, tildes, periods) |
| `key` | 1 | 256 | `^[-_~.a-zA-Z0-9]+$` (same pattern) |

**Limit:** 20,000,000 Custom Objects per project (can be increased by support).

### Custom Object Pitfalls

```typescript
// PITFALL 1: Null values are silently dropped
const objectWithNulls: CustomObjectDraft = {
  container: 'test',
  key: 'null-test',
  value: {
    name: 'Test',
    description: null,  // This field will NOT be saved
    metadata: {
      tag: null,        // This field will NOT be saved
    },
  },
};
// After saving, the object will be: { name: 'Test', metadata: {} }
// Use empty string '' or a sentinel value if you need to represent "no value"

// PITFALL 2: No referential integrity
const objectWithRef: CustomObjectDraft = {
  container: 'config',
  key: 'featured',
  value: {
    productId: 'some-product-id',  // If this product is deleted,
                                    // the reference becomes dangling.
                                    // No cascade, no error, no warning.
  },
};
// Always validate references in application code

// PITFALL 3: Concurrent modifications
// Even without providing a version, concurrent updates cause ConcurrentModification errors
// Always handle 409 responses with retry logic
```

## Custom Types on Resources: Complete Example

```typescript
import { TypeDraft } from '@commercetools/platform-sdk';

// Step 1: Create the Type definition
const orderMetadataType: TypeDraft = {
  key: 'order-metadata',
  name: { en: 'Order Metadata' },
  resourceTypeIds: ['order'],
  fieldDefinitions: [
    {
      name: 'fulfillment-source',
      label: { en: 'Fulfillment Source' },
      type: {
        name: 'Enum',
        values: [
          { key: 'warehouse-east', label: 'East Warehouse' },
          { key: 'warehouse-west', label: 'West Warehouse' },
          { key: 'dropship', label: 'Dropship' },
        ],
      },
      required: false,
      inputHint: 'SingleLine',
    },
    {
      name: 'erp-orderNumber',
      label: { en: 'ERP Order Number' },
      type: { name: 'String' },
      required: false,
      inputHint: 'SingleLine',
    },
    {
      name: 'erp-syncedAt',
      label: { en: 'ERP Sync Timestamp' },
      type: { name: 'DateTime' },
      required: false,
      inputHint: 'SingleLine',
    },
  ],
};

await apiRoot.types().post({ body: orderMetadataType }).execute();

// Step 2: Set the Custom Type on an Order (first time -- use setCustomType)
await apiRoot.orders().withId({ ID: orderId }).post({
  body: {
    version,
    actions: [{
      action: 'setCustomType',
      type: { key: 'order-metadata', typeId: 'type' },
      fields: {
        'fulfillment-source': 'warehouse-east',
      },
    }],
  },
}).execute();

// Step 3: Update individual fields (subsequent updates -- use setCustomField)
await apiRoot.orders().withId({ ID: orderId }).post({
  body: {
    version: newVersion,
    actions: [
      {
        action: 'setCustomField',
        name: 'erp-orderNumber',
        value: 'ERP-2025-00001234',
      },
      {
        action: 'setCustomField',
        name: 'erp-syncedAt',
        value: new Date().toISOString(),
      },
    ],
  },
}).execute();

// Step 4: Query by custom field
const syncedOrders = await apiRoot.orders().get({
  queryArgs: {
    where: 'custom(fields(erp-syncedAt is defined))',
    sort: ['custom.fields.erp-syncedAt desc'],
    limit: 20,
  },
}).execute();
```

## Decision Checklist

Before choosing between Custom Types and Custom Objects:

- [ ] Is the data about a specific resource instance? --> Custom Type
- [ ] Is the data standalone (config, lookups, cross-cutting)? --> Custom Object
- [ ] Will multiple services need to write fields on the same resource? --> Composable Custom Type with prefixed field names
- [ ] Do you need schema validation on the custom data? --> Custom Type (typed fields)
- [ ] Do you need arbitrary JSON flexibility? --> Custom Object (no schema)
- [ ] Do you need to query resources by this data? --> Custom Type (predicate queries)
- [ ] Is it a one-off piece of product data? --> Custom Object (avoid single-use product type attributes)
- [ ] Have you checked if a Custom Type already exists for this resource in the project?
- [ ] Are all field names prefixed with the service/domain name to avoid collisions?
- [ ] Have you planned for field type changes? (New field + migration, never in-place change)

## Reference

- [Custom Types Tutorial](https://docs.commercetools.com/tutorials/custom-types)
- [Composable Custom Types](https://docs.commercetools.com/tutorials/composable-custom-types)
- [Custom Objects API](https://docs.commercetools.com/api/projects/custom-objects)
- [Types API](https://docs.commercetools.com/api/projects/types)
