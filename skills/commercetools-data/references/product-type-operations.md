# Product Type Operations & Maintenance

Variant strategy, adding attributes after launch, enum management, attribute naming rules, search indexing limits, update actions, and design checklist for commercetools product types.

## Pattern 6: Variant Strategy (The 100-Variant Limit)

Each product supports up to 100 variants. Plan your variant axes carefully.

```typescript
import { ProductDraft } from '@commercetools/platform-sdk';

// Good: Variants defined by color + size (manageable combinations)
// 5 colors x 6 sizes = 30 variants -- well within the 100 limit
const tshirtDraft: ProductDraft = {
  key: 'classic-tee',
  name: { en: 'Classic T-Shirt' },
  slug: { en: 'classic-tee' },
  productType: { typeId: 'product-type', key: 'apparel' },
  masterVariant: {
    sku: 'TEE-BLK-XS',
    key: 'tee-black-xs',
    attributes: [
      { name: 'color', value: { key: 'black' } },
      { name: 'size', value: { key: 'XS' } },
    ],
    prices: [{
      value: { type: 'centPrecision', currencyCode: 'EUR', centAmount: 2999, fractionDigits: 2 },
      country: 'DE',
    }],
  },
  variants: [
    {
      sku: 'TEE-BLK-S',
      key: 'tee-black-s',
      attributes: [
        { name: 'color', value: { key: 'black' } },
        { name: 'size', value: { key: 'S' } },
      ],
      prices: [{
        value: { type: 'centPrecision', currencyCode: 'EUR', centAmount: 2999, fractionDigits: 2 },
        country: 'DE',
      }],
    },
    // ... additional color+size combinations
  ],
  publish: true,
};
```

**When you hit the 100-variant limit:** Split the product into multiple products grouped by a shared attribute (e.g., one product per color family). Use Product Selections or category assignments to present them together on the storefront.

## Pattern 7: Adding Attributes After Launch

You can safely add new attributes to an existing Product Type. Existing products will have `undefined` for the new attribute until updated.

```typescript
// Adding a new attribute to an existing Product Type
const updatedType = await apiRoot
  .productTypes()
  .withKey({ key: 'apparel' })
  .post({
    body: {
      version: currentVersion,
      actions: [
        {
          action: 'addAttributeDefinition',
          attribute: {
            name: 'sustainabilityCertification',
            label: { en: 'Sustainability Certification' },
            type: {
              name: 'enum',
              values: [
                { key: 'gots', label: 'GOTS Certified' },
                { key: 'oeko-tex', label: 'OEKO-TEX Standard' },
                { key: 'bluesign', label: 'Bluesign Approved' },
              ],
            },
            isRequired: false,  // MUST be false when adding to a type with products
            attributeConstraint: 'SameForAll',
            isSearchable: true,
            inputHint: 'SingleLine',
          },
        },
      ],
    },
  })
  .execute();
```

**Warning:** When adding an attribute to a type that already has products, set `isRequired: false`. If you set it to `true`, every existing product immediately violates the constraint and cannot be updated until the attribute is populated.

## Pattern 8: Enum Value Management

Enum values can be added to existing types but cannot be removed if any product uses them.

```typescript
// Adding a new enum value -- safe
await apiRoot
  .productTypes()
  .withKey({ key: 'apparel' })
  .post({
    body: {
      version: currentVersion,
      actions: [
        {
          action: 'addPlainEnumValue',
          attributeName: 'size',
          value: { key: 'XXL', label: 'Double Extra Large' },
        },
      ],
    },
  })
  .execute();

// Adding a new localized enum value
await apiRoot
  .productTypes()
  .withKey({ key: 'apparel' })
  .post({
    body: {
      version: currentVersion,
      actions: [
        {
          action: 'addLocalizedEnumValue',
          attributeName: 'color',
          value: {
            key: 'forest-green',
            label: { en: 'Forest Green', de: 'Waldgruen' },
          },
        },
      ],
    },
  })
  .execute();

// Changing enum sort order (presentation only, does not affect data)
await apiRoot
  .productTypes()
  .withKey({ key: 'apparel' })
  .post({
    body: {
      version: currentVersion,
      actions: [
        {
          action: 'changePlainEnumValueOrder',
          attributeName: 'size',
          values: [
            { key: 'XS', label: 'XS' },
            { key: 'S', label: 'S' },
            { key: 'M', label: 'M' },
            { key: 'L', label: 'L' },
            { key: 'XL', label: 'XL' },
            { key: 'XXL', label: 'Double Extra Large' },
          ],
        },
      ],
    },
  })
  .execute();
```

## Attribute Name Rules

- Pattern: `^[A-Za-z0-9_-]+$` (alphanumeric, underscores, hyphens)
- Length: 2-256 characters
- Must be unique within a Product Type
- Must be type-consistent across all Product Types (same name = same base type)

## Search Indexing Limits

The Product Search API indexes attributes up to these limits:

| Limit | Value |
|-------|-------|
| Searchable product-level attributes | 50 per Product Type |
| Searchable variant-level attributes | 50 per Product Type |
| Searchable field content size | 10,922 characters |
| Nested type depth (with sets) | 5 iteration steps |

Attributes are indexed in the order they are defined on the Product Type. Attributes beyond the 50-attribute limit are not indexed for search but remain accessible via the API.

## Product Type Update Actions

20 update actions are available for Product Types:

| Action | Description |
|--------|-------------|
| `setKey` | Set or unset the key |
| `changeName` | Change the name |
| `changeDescription` | Change the description |
| `addAttributeDefinition` | Add a new attribute |
| `removeAttributeDefinition` | Remove an attribute (eventually consistent) |
| `changeAttributeName` | Rename an attribute (eventually consistent) |
| `changeLabel` | Change an attribute's label |
| `setInputTip` | Set an attribute's input tip |
| `changeInputHint` | Change SingleLine/MultiLine hint |
| `changeAttributeConstraint` | Change constraint (only SameForAll→None, Unique→None) |
| `changeIsSearchable` | Toggle search indexing |
| `changeAttributeOrderByName` | Reorder attributes |
| `addPlainEnumValue` | Add an enum value |
| `addLocalizedEnumValue` | Add a localized enum value |
| `removeEnumValues` | Remove enum values |
| `changePlainEnumValueLabel` | Change an enum label |
| `changeLocalizedEnumValueLabel` | Change a localized enum label |
| `changePlainEnumValueOrder` | Reorder enum values |
| `changeLocalizedEnumValueOrder` | Reorder localized enum values |
| `changeEnumKey` | Change an enum key |

## Design Checklist

Before committing to a Product Type design:

- [ ] Verify 80%+ attribute overlap among products that will use this type
- [ ] Confirm no single-use attributes (use Custom Objects for one-off data)
- [ ] Use `enum`/`lenum` instead of `text` for any filterable values
- [ ] Set `attributeConstraint` correctly: `SameForAll` for product-level, `None` or `CombinationUnique` for variant-level
- [ ] Use `lenum` (not `ltext`) for translatable options that need faceting
- [ ] Test with real product data before committing -- create sample products with worst-case variant counts
- [ ] Validate variant count: will any product exceed 100 variants?
- [ ] Ask for each attribute: "Does the storefront or a business process actually use this?"
- [ ] Ask: "Could this Product Type be modeled as a Category instead?"
- [ ] Confirm attribute names are consistent with any existing Product Types in the project
- [ ] Set `isSearchable: true` only for attributes used in search/faceting (indexing has a cost)
- [ ] Plan for enum value growth -- start with a core set, add values over time
- [ ] Document the design rationale for future maintainers

## Reference

- [Product Types API](https://docs.commercetools.com/api/projects/productTypes)
- [Products API](https://docs.commercetools.com/api/projects/products)
- [Product Data Modeling Best Practices](https://docs.commercetools.com/foundry/best-practice-guides/product-data-modeling)
