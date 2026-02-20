# Product Type Design Patterns

**Impact: CRITICAL -- Irreversible once products are assigned**

Product Types are the schema for your product catalog. Once a Product Type is assigned to a Product, it **cannot be changed**. Once a Product Type has Products, it **cannot be deleted** without first deleting all those Products. You can add attributes later, but removing or changing existing attributes on a type with products ranges from painful to impossible.

This is the single most consequential data modeling decision in any commercetools implementation.

## Table of Contents
- [The Immutability Rules](#the-immutability-rules)
- [Pattern 1: Right-Sizing Product Types (The 80% Rule)](#pattern-1-right-sizing-product-types-the-80-rule)
- [Pattern 2: Lean Attributes (Only What the Storefront Needs)](#pattern-2-lean-attributes-only-what-the-storefront-needs)
- [Pattern 3: Choosing the Right Attribute Types](#pattern-3-choosing-the-right-attribute-types)
- [Pattern 4: Attribute Constraints](#pattern-4-attribute-constraints)
- [Pattern 5: The Mega-Type Anti-Pattern](#pattern-5-the-mega-type-anti-pattern)

## The Immutability Rules

1. A Product's `productType` reference is set at creation and **never changes**
2. A Product Type **cannot be deleted** while any Product references it
3. Attribute **names** can be renamed via `changeAttributeName` (eventually consistent -- updates all products asynchronously)
4. Attribute **types** cannot be changed (e.g., `text` to `enum`) on a Product Type
5. Removing an attribute from a type that has products removes the attribute value from all products (eventually consistent)
6. Attribute names must be **globally consistent** -- the same attribute name across different Product Types must have the same type definition
7. Attribute constraint changes are **limited**: only `SameForAll` → `None` and `Unique` → `None` are supported
8. Enum keys can be changed via `changeEnumKey` (eventually consistent)

## Pattern 1: Right-Sizing Product Types (The 80% Rule)

Products within a Product Type should share roughly 80% of their attributes.

**Anti-Pattern (too many granular types):**

```typescript
import { ProductTypeDraft } from '@commercetools/platform-sdk';

// Creating separate types for minor variations -- maintenance nightmare
const shortsDraft: ProductTypeDraft = {
  name: 'Shorts',
  key: 'shorts',
  description: 'Short pants',
  attributes: [
    { name: 'color', label: { en: 'Color' }, type: { name: 'lenum', values: [] },
      isRequired: true, attributeConstraint: 'None', isSearchable: true, inputHint: 'SingleLine' },
    { name: 'size', label: { en: 'Size' }, type: { name: 'enum', values: [] },
      isRequired: true, attributeConstraint: 'None', isSearchable: true, inputHint: 'SingleLine' },
    { name: 'material', label: { en: 'Material' }, type: { name: 'lenum', values: [] },
      isRequired: false, attributeConstraint: 'SameForAll', isSearchable: true, inputHint: 'SingleLine' },
    { name: 'inseamLength', label: { en: 'Inseam' }, type: { name: 'number' },
      isRequired: false, attributeConstraint: 'None', isSearchable: false, inputHint: 'SingleLine' },
  ],
};

// Nearly identical type for long pants
const longPantsDraft: ProductTypeDraft = {
  name: 'Long Pants',
  key: 'long-pants',
  description: 'Long pants',
  attributes: [
    { name: 'color', label: { en: 'Color' }, type: { name: 'lenum', values: [] },
      isRequired: true, attributeConstraint: 'None', isSearchable: true, inputHint: 'SingleLine' },
    { name: 'size', label: { en: 'Size' }, type: { name: 'enum', values: [] },
      isRequired: true, attributeConstraint: 'None', isSearchable: true, inputHint: 'SingleLine' },
    { name: 'material', label: { en: 'Material' }, type: { name: 'lenum', values: [] },
      isRequired: false, attributeConstraint: 'SameForAll', isSearchable: true, inputHint: 'SingleLine' },
    { name: 'inseamLength', label: { en: 'Inseam' }, type: { name: 'number' },
      isRequired: false, attributeConstraint: 'None', isSearchable: false, inputHint: 'SingleLine' },
  ],
};

// And another nearly identical type for cropped pants...
// Result: 3+ types with 95% attribute overlap. Maintenance burden explodes.
```

**Recommended (single type for the category):**

```typescript
import { ProductTypeDraft } from '@commercetools/platform-sdk';

const bottomsDraft: ProductTypeDraft = {
  name: 'Bottoms',
  key: 'bottoms',
  description: 'Pants, shorts, skirts, and other bottom-wear',
  attributes: [
    {
      name: 'color',
      label: { en: 'Color', de: 'Farbe' },
      type: {
        name: 'lenum',
        values: [
          { key: 'black', label: { en: 'Black', de: 'Schwarz' } },
          { key: 'navy', label: { en: 'Navy', de: 'Marineblau' } },
          { key: 'khaki', label: { en: 'Khaki', de: 'Khaki' } },
        ],
      },
      isRequired: true,
      attributeConstraint: 'None',  // varies per variant
      isSearchable: true,
      inputHint: 'SingleLine',
    },
    {
      name: 'size',
      label: { en: 'Size' },
      type: {
        name: 'enum',
        values: [
          { key: 'XS', label: 'XS' },
          { key: 'S', label: 'S' },
          { key: 'M', label: 'M' },
          { key: 'L', label: 'L' },
          { key: 'XL', label: 'XL' },
        ],
      },
      isRequired: true,
      attributeConstraint: 'CombinationUnique',  // size+color = unique variant
      isSearchable: true,
      inputHint: 'SingleLine',
    },
    {
      name: 'material',
      label: { en: 'Material' },
      type: {
        name: 'lenum',
        values: [
          { key: 'cotton', label: { en: 'Cotton', de: 'Baumwolle' } },
          { key: 'denim', label: { en: 'Denim', de: 'Jeansstoff' } },
          { key: 'polyester', label: { en: 'Polyester', de: 'Polyester' } },
        ],
      },
      isRequired: false,
      attributeConstraint: 'SameForAll',  // same material across all variants
      isSearchable: true,
      inputHint: 'SingleLine',
    },
    {
      name: 'gender',
      label: { en: 'Gender' },
      type: {
        name: 'enum',
        values: [
          { key: 'mens', label: "Men's" },
          { key: 'womens', label: "Women's" },
          { key: 'unisex', label: 'Unisex' },
        ],
      },
      isRequired: true,
      attributeConstraint: 'SameForAll',
      isSearchable: true,
      inputHint: 'SingleLine',
    },
    {
      name: 'bottomType',
      label: { en: 'Type' },
      type: {
        name: 'enum',
        values: [
          { key: 'shorts', label: 'Shorts' },
          { key: 'long-pants', label: 'Long Pants' },
          { key: 'cropped', label: 'Cropped Pants' },
          { key: 'skirt', label: 'Skirt' },
        ],
      },
      isRequired: true,
      attributeConstraint: 'SameForAll',
      isSearchable: true,
      inputHint: 'SingleLine',
    },
  ],
};
```

**Why This Matters:** Managing 3 nearly identical Product Types means 3x the maintenance, 3x the integration mapping, and 3x the Merchant Center configuration. Use attributes to differentiate within a type. Use separate types only when the attribute schemas genuinely diverge (e.g., Electronics vs. Apparel).

## Pattern 2: Lean Attributes (Only What the Storefront Needs)

**Anti-Pattern (mirroring the ERP/PIM schema):**

```typescript
import { ProductTypeDraft } from '@commercetools/platform-sdk';

// Mirroring every field from the source system
const overEngineered: ProductTypeDraft = {
  name: 'Apparel',
  key: 'apparel',
  description: 'All apparel products',
  attributes: [
    // Storefront-relevant attributes
    { name: 'color', label: { en: 'Color' }, type: { name: 'lenum', values: [] },
      isRequired: true, attributeConstraint: 'None', isSearchable: true, inputHint: 'SingleLine' },
    { name: 'size', label: { en: 'Size' }, type: { name: 'enum', values: [] },
      isRequired: true, attributeConstraint: 'None', isSearchable: true, inputHint: 'SingleLine' },

    // ERP/PIM fields that serve no storefront purpose
    { name: 'erpMaterialCode', label: { en: 'ERP Material Code' }, type: { name: 'text' },
      isRequired: false, attributeConstraint: 'None', isSearchable: false, inputHint: 'SingleLine' },
    { name: 'warehouseLocation', label: { en: 'Warehouse Location' }, type: { name: 'text' },
      isRequired: false, attributeConstraint: 'None', isSearchable: false, inputHint: 'SingleLine' },
    { name: 'internalNotes', label: { en: 'Internal Notes' }, type: { name: 'text' },
      isRequired: false, attributeConstraint: 'None', isSearchable: false, inputHint: 'MultiLine' },
    { name: 'legacySystemId', label: { en: 'Legacy ID' }, type: { name: 'text' },
      isRequired: false, attributeConstraint: 'None', isSearchable: false, inputHint: 'SingleLine' },
    { name: 'supplierCode', label: { en: 'Supplier Code' }, type: { name: 'text' },
      isRequired: false, attributeConstraint: 'None', isSearchable: false, inputHint: 'SingleLine' },
    { name: 'costPrice', label: { en: 'Cost Price' }, type: { name: 'money' },
      isRequired: false, attributeConstraint: 'None', isSearchable: false, inputHint: 'SingleLine' },
    // ... 20 more attributes nobody queries
  ],
};
```

**Recommended (storefront-driven attributes only):**

```typescript
import { ProductTypeDraft } from '@commercetools/platform-sdk';

const lean: ProductTypeDraft = {
  name: 'Apparel',
  key: 'apparel',
  description: 'Clothing, footwear, and accessories',
  attributes: [
    {
      name: 'color',
      label: { en: 'Color', de: 'Farbe' },
      type: {
        name: 'lenum',
        values: [
          { key: 'black', label: { en: 'Black', de: 'Schwarz' } },
          { key: 'white', label: { en: 'White', de: 'Weiss' } },
        ],
      },
      isRequired: true,
      attributeConstraint: 'None',
      isSearchable: true,
      inputHint: 'SingleLine',
    },
    {
      name: 'size',
      label: { en: 'Size' },
      type: {
        name: 'enum',
        values: [
          { key: 'S', label: 'Small' },
          { key: 'M', label: 'Medium' },
          { key: 'L', label: 'Large' },
        ],
      },
      isRequired: true,
      attributeConstraint: 'CombinationUnique',
      isSearchable: true,
      inputHint: 'SingleLine',
    },
    {
      name: 'material',
      label: { en: 'Material' },
      type: { name: 'lenum', values: [] },
      isRequired: false,
      attributeConstraint: 'SameForAll',
      isSearchable: true,
      inputHint: 'SingleLine',
    },
    {
      name: 'gender',
      label: { en: 'Gender' },
      type: {
        name: 'enum',
        values: [
          { key: 'mens', label: "Men's" },
          { key: 'womens', label: "Women's" },
          { key: 'unisex', label: 'Unisex' },
        ],
      },
      isRequired: true,
      attributeConstraint: 'SameForAll',
      isSearchable: true,
      inputHint: 'SingleLine',
    },
  ],
};

// ERP/PIM-only data stays in the source system.
// If you need a cross-reference key, use the Product's `key` field
// or a single Custom Object for sync metadata.
```

**Why This Matters:** Attribute-heavy types cause bloated API responses (every variant carries every attribute), degraded search indexing performance, and a cluttered Merchant Center editing experience. You can always **add** attributes later. Removing them from a type with products is extremely difficult.

## Pattern 3: Choosing the Right Attribute Types

**Anti-Pattern (using text for everything):**

```typescript
// Using plain text for data that should be structured
const badAttributes = [
  { name: 'color', type: { name: 'text' } },       // Cannot facet on free text
  { name: 'isWaterproof', type: { name: 'text' } }, // "yes"/"no"/"Yes"/"TRUE" chaos
  { name: 'weight', type: { name: 'text' } },       // Cannot sort numerically
  { name: 'brand', type: { name: 'text' } },        // Typos, inconsistent casing
];
```

**Recommended (type-appropriate attributes):**

```typescript
const goodAttributes = [
  // Filterable options --> enum or lenum
  { name: 'color', type: { name: 'lenum', values: [
    { key: 'red', label: { en: 'Red', de: 'Rot' } },
  ] } },

  // Boolean flags --> boolean
  { name: 'isWaterproof', type: { name: 'boolean' } },

  // Numeric data --> number (enables range queries and sorting)
  { name: 'weightGrams', type: { name: 'number' } },

  // Controlled vocabularies --> enum (no translation needed)
  { name: 'brand', type: { name: 'enum', values: [
    { key: 'nike', label: 'Nike' },
    { key: 'adidas', label: 'Adidas' },
  ] } },

  // Multi-value --> set of enum
  { name: 'features', type: { name: 'set', elementType: {
    name: 'enum', values: [
      { key: 'breathable', label: 'Breathable' },
      { key: 'quick-dry', label: 'Quick Dry' },
    ],
  } } },
];
```

## Pattern 4: Attribute Constraints

```typescript
import { ProductTypeDraft } from '@commercetools/platform-sdk';

const productTypeDraft: ProductTypeDraft = {
  name: 'Furniture',
  key: 'furniture',
  description: 'Tables, chairs, sofas',
  attributes: [
    // SameForAll: product-level attribute, identical across variants
    // Use for brand, material, designer -- things that do not vary by variant
    {
      name: 'designer',
      label: { en: 'Designer' },
      type: { name: 'text' },
      isRequired: false,
      attributeConstraint: 'SameForAll',
      isSearchable: true,
      inputHint: 'SingleLine',
    },

    // None: variant-level, each variant can have a different value
    // Use for color, finish, upholstery -- things that define the variant
    {
      name: 'finish',
      label: { en: 'Finish' },
      type: { name: 'lenum', values: [] },
      isRequired: true,
      attributeConstraint: 'None',
      isSearchable: true,
      inputHint: 'SingleLine',
    },

    // CombinationUnique: the combination across marked attributes must be unique
    // Use when finish + size together define a unique variant
    {
      name: 'dimensions',
      label: { en: 'Dimensions' },
      type: { name: 'enum', values: [
        { key: 'small', label: 'Small (60x60cm)' },
        { key: 'medium', label: 'Medium (80x80cm)' },
        { key: 'large', label: 'Large (120x120cm)' },
      ] },
      isRequired: true,
      attributeConstraint: 'CombinationUnique',
      isSearchable: true,
      inputHint: 'SingleLine',
    },

    // Unique: value must be unique across ALL variants of this product
    // Use for variant-specific identifiers
    {
      name: 'supplierSku',
      label: { en: 'Supplier SKU' },
      type: { name: 'text' },
      isRequired: false,
      attributeConstraint: 'Unique',
      isSearchable: false,
      inputHint: 'SingleLine',
    },
  ],
};
```

## Pattern 5: The Mega-Type Anti-Pattern

**Anti-Pattern (one type for everything):**

```typescript
// DO NOT: Cramming all products into a single Product Type
const megaType: ProductTypeDraft = {
  name: 'Product',
  key: 'product',
  description: 'All products',
  attributes: [
    // Apparel attributes
    { name: 'clothingSize', label: { en: 'Clothing Size' }, type: { name: 'enum', values: [] },
      isRequired: false, attributeConstraint: 'None', isSearchable: true, inputHint: 'SingleLine' },
    { name: 'material', label: { en: 'Material' }, type: { name: 'lenum', values: [] },
      isRequired: false, attributeConstraint: 'None', isSearchable: true, inputHint: 'SingleLine' },
    // Electronics attributes
    { name: 'screenSize', label: { en: 'Screen Size' }, type: { name: 'number' },
      isRequired: false, attributeConstraint: 'None', isSearchable: true, inputHint: 'SingleLine' },
    { name: 'batteryCapacity', label: { en: 'Battery (mAh)' }, type: { name: 'number' },
      isRequired: false, attributeConstraint: 'None', isSearchable: true, inputHint: 'SingleLine' },
    // Food attributes
    { name: 'calories', label: { en: 'Calories' }, type: { name: 'number' },
      isRequired: false, attributeConstraint: 'None', isSearchable: true, inputHint: 'SingleLine' },
    { name: 'allergens', label: { en: 'Allergens' }, type: { name: 'set', elementType: { name: 'text' } },
      isRequired: false, attributeConstraint: 'None', isSearchable: true, inputHint: 'SingleLine' },
    // ... 50+ attributes, most empty for any given product
  ],
};
// Result: Every API response includes 50+ empty fields. Merchant Center editing
// shows irrelevant fields. Search index is bloated.
```

**Recommended:** Create separate Product Types when attribute schemas genuinely diverge. If you manage data in the Merchant Center, more specific types give content managers a better editing experience with only relevant fields displayed.
