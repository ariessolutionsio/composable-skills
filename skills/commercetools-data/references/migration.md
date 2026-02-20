# Migration Strategy

**Impact: HIGH -- No built-in environment promotion. Product type changes require delete-and-recreate. Big-bang migrations have high failure rates.**

commercetools does not provide built-in migration or environment promotion tools. Every migration -- whether from a legacy platform or between commercetools environments -- requires deliberate planning. The immutability of product types makes data model changes the highest-risk aspect of any migration.

## Table of Contents
- [Migration Types](#migration-types)
- [Legacy Platform Migration: The Strangler Pattern](#legacy-platform-migration-the-strangler-pattern)
- [Data Cleansing Before Migration](#data-cleansing-before-migration)
- [Environment Promotion with Terraform](#environment-promotion-with-terraform)
- [Product Type Evolution](#product-type-evolution)
  - [Adding Attributes (Safe)](#adding-attributes-safe)
  - [Adding Enum Values (Safe)](#adding-enum-values-safe)
  - [Removing Attributes (Destructive -- Requires Migration)](#removing-attributes-destructive----requires-migration)
  - [Changing Product Types (Nuclear Option -- Delete and Recreate)](#changing-product-types-nuclear-option----delete-and-recreate)
- [State Machine Migration](#state-machine-migration)
- [Product Selection Migration for Multi-Store](#product-selection-migration-for-multi-store)
- [Migration Testing Checklist](#migration-testing-checklist)
- [Reference](#reference)

## Migration Types

1. **Legacy Platform to commercetools** -- Replatforming from Magento, Salesforce Commerce Cloud, SAP Hybris, etc.
2. **Environment Promotion** -- Moving configuration from dev to staging to production
3. **Data Model Evolution** -- Changing product types, custom types, or categories on a live project

Each has different constraints and strategies.

## Legacy Platform Migration: The Strangler Pattern

**Anti-Pattern (big-bang migration):**

```
Week 1-8:  Build everything in parallel with legacy
Week 9:    "Go-live weekend" -- migrate all data, switch DNS
Week 10:   Discover data model is wrong, prices are missing,
           category hierarchy does not match navigation...
           Cannot roll back because legacy was decommissioned.
```

**Recommended (Strangler Pattern -- incremental migration):**

```
Phase 1: Product Catalog (lowest risk)
  - Migrate product types, categories, products
  - Legacy system remains the source of truth for orders/customers
  - Storefront reads from commercetools for catalog, legacy for everything else

Phase 2: Cart & Checkout
  - Migrate cart/checkout to commercetools
  - Orders flow through commercetools
  - Customer accounts still in legacy

Phase 3: Customer Management
  - Migrate customer accounts
  - Full commercetools stack operational

Phase 4: Decommission Legacy
  - Archive legacy data
  - Remove legacy integrations
```

## Data Cleansing Before Migration

**Anti-Pattern (migrating everything):**

```typescript
// Migrating all 50,000 products from legacy, including:
// - Products discontinued 5 years ago
// - Duplicate entries from past import errors
// - Test products with fake data
// - Products with missing required fields

// Result: New system starts bloated, hitting platform limits sooner,
// and carrying forward data quality problems.
```

**Recommended (audit and cleanse first):**

```typescript
// Define migration criteria BEFORE starting
interface MigrationCriteria {
  products: {
    includeDiscontinued: false;
    minimumLastOrderDate: '2023-01-01';  // Only active products
    requiredFields: ['name', 'sku', 'price', 'category'];
    excludeTestData: true;
  };
  customers: {
    includeInactive: false;
    minimumLastLoginDate: '2024-01-01';
    requireValidEmail: true;
  };
  orders: {
    migrationScope: 'last-2-years';  // Archive older orders
    excludeCanceled: true;
  };
}

// Data quality report before migration
async function generateMigrationReport(legacyData: any[]): Promise<{
  total: number;
  eligible: number;
  excluded: { reason: string; count: number }[];
  dataQualityIssues: { field: string; issue: string; count: number }[];
}> {
  const report = {
    total: legacyData.length,
    eligible: 0,
    excluded: [] as { reason: string; count: number }[],
    dataQualityIssues: [] as { field: string; issue: string; count: number }[],
  };

  // Analyze each record against criteria
  for (const record of legacyData) {
    // Check required fields, date thresholds, data quality
    // Categorize as eligible or excluded with reason
  }

  return report;
}
```

## Environment Promotion with Terraform

commercetools has no built-in "promote to production" feature. Use Infrastructure as Code.

**Anti-Pattern (manual configuration in each environment):**

```
Developer creates Product Type in dev via Merchant Center
  --> Manually recreates it in staging (slightly different)
    --> Manually recreates it in production (different again)
       --> Configuration drift causes bugs that only appear in production
```

**Recommended (Terraform-managed configuration):**

```hcl
# main.tf -- commercetools Product Type managed as code
# Uses the labd/commercetools Terraform provider

resource "commercetools_product_type" "apparel" {
  key         = "apparel"
  name        = "Apparel"
  description = "Clothing, footwear, and accessories"

  attribute {
    name = "color"
    label = {
      en = "Color"
      de = "Farbe"
    }
    type {
      name = "lenum"
      localized_value {
        key = "black"
        label = {
          en = "Black"
          de = "Schwarz"
        }
      }
      localized_value {
        key = "white"
        label = {
          en = "White"
          de = "Weiss"
        }
      }
    }
    constraint  = "None"
    searchable  = true
    input_hint  = "SingleLine"
  }

  attribute {
    name = "size"
    label = {
      en = "Size"
    }
    type {
      name = "enum"
      value {
        key   = "S"
        label = "Small"
      }
      value {
        key   = "M"
        label = "Medium"
      }
      value {
        key   = "L"
        label = "Large"
      }
    }
    constraint  = "CombinationUnique"
    searchable  = true
    input_hint  = "SingleLine"
  }
}

```

Create one `terraform.tfvars` per environment (repeat the pattern for dev, staging, production):

```hcl
# environments/<env>/terraform.tfvars
project_key   = "acme-<env>"
api_url       = "https://api.europe-west1.gcp.commercetools.com"
auth_url      = "https://auth.europe-west1.gcp.commercetools.com"
```

```bash
# Promote from dev to staging
cd environments/staging
terraform plan -var-file=terraform.tfvars   # Review changes
terraform apply -var-file=terraform.tfvars  # Apply

# Promote from staging to production (with approval gate)
cd environments/production
terraform plan -var-file=terraform.tfvars   # Review changes
# Require manual approval before:
terraform apply -var-file=terraform.tfvars
```

## Product Type Evolution

Changing a Product Type that has products is the most complex migration scenario.

### Adding Attributes (Safe)

```typescript
// Safe: Adding a new optional attribute to an existing type
await apiRoot.productTypes().withKey({ key: 'apparel' }).post({
  body: {
    version: currentVersion,
    actions: [{
      action: 'addAttributeDefinition',
      attribute: {
        name: 'sustainabilityCertification',
        label: { en: 'Sustainability Certification' },
        type: { name: 'enum', values: [
          { key: 'gots', label: 'GOTS Certified' },
          { key: 'oeko-tex', label: 'OEKO-TEX Standard' },
        ] },
        isRequired: false,  // MUST be false for types with existing products
        attributeConstraint: 'SameForAll',
        isSearchable: true,
        inputHint: 'SingleLine',
      },
    }],
  },
}).execute();
// Existing products will have undefined for this attribute until updated
```

### Adding Enum Values (Safe)

```typescript
// Safe: Adding values to an existing enum attribute
await apiRoot.productTypes().withKey({ key: 'apparel' }).post({
  body: {
    version: currentVersion,
    actions: [{
      action: 'addPlainEnumValue',
      attributeName: 'size',
      value: { key: 'XXL', label: 'Double Extra Large' },
    }],
  },
}).execute();
```

### Removing Attributes (Destructive -- Requires Migration)

```typescript
// DANGER: Removing an attribute from a type with products
// Step 1: Unset the attribute value on ALL products first
async function unsetAttributeOnAllProducts(
  productTypeKey: string,
  attributeName: string
): Promise<void> {
  let offset = 0;
  const limit = 100;

  while (true) {
    const products = await apiRoot.products().get({
      queryArgs: {
        where: `productType(key="${productTypeKey}")`,
        limit,
        offset,
      },
    }).execute();

    if (products.body.results.length === 0) break;

    for (const product of products.body.results) {
      const allVariants = [
        product.masterData.staged.masterVariant,
        ...product.masterData.staged.variants,
      ];

      const actions = allVariants
        .filter(v => v.attributes?.some(a => a.name === attributeName))
        .map(v => ({
          action: 'setAttribute' as const,
          variantId: v.id,
          name: attributeName,
          value: undefined,  // Unset the value
          staged: true,
        }));

      if (actions.length > 0) {
        await apiRoot.products().withId({ ID: product.id }).post({
          body: { version: product.version, actions },
        }).execute();
      }
    }

    offset += limit;
    if (products.body.results.length < limit) break;
  }
}

// Step 2: Remove the attribute definition
await unsetAttributeOnAllProducts('apparel', 'oldAttribute');

await apiRoot.productTypes().withKey({ key: 'apparel' }).post({
  body: {
    version: newVersion,
    actions: [{
      action: 'removeAttributeDefinition',
      name: 'oldAttribute',
    }],
  },
}).execute();
```

### Changing Product Types (Nuclear Option -- Delete and Recreate)

If you need to change a product's Product Type, there is no update action. You must:

```typescript
// WARNING: This is the nuclear option. Use only when absolutely necessary.
async function migrateProductToNewType(
  productKey: string,
  newProductTypeKey: string,
  transformAttributes: (oldAttrs: any[]) => any[]
): Promise<void> {
  // Step 1: Read the existing product
  const existing = await apiRoot.products().withKey({ key: productKey }).get().execute();
  const product = existing.body;
  const current = product.masterData.current ?? product.masterData.staged;

  // Step 2: Extract all data we want to preserve
  const preservedData = {
    key: product.key,
    name: current.name,
    slug: current.slug, // May need a temporary slug to avoid conflicts
    description: current.description,
    categories: current.categories,
    masterVariant: {
      ...current.masterVariant,
      attributes: transformAttributes(current.masterVariant.attributes ?? []),
    },
    variants: current.variants.map(v => ({
      ...v,
      attributes: transformAttributes(v.attributes ?? []),
    })),
  };

  // Step 3: Delete the existing product
  await apiRoot.products().withKey({ key: productKey }).delete({
    queryArgs: { version: product.version },
  }).execute();

  // Step 4: Recreate with the new product type
  await apiRoot.products().post({
    body: {
      ...preservedData,
      productType: { typeId: 'product-type', key: newProductTypeKey },
      publish: true,
    },
  }).execute();
}

// RISKS:
// - Product loses its ID (all external references break)
// - Brief window where product does not exist (lost SEO, broken links)
// - Reviews, state, and other references are not transferred
// - Must update all systems that reference the old product ID
```

## State Machine Migration

States enable custom workflows. Define them during project setup.

```
Draft (initial) --> In Review --> Approved --> Published
                  \            \
                   <-- reject -- <-- reject back to Draft
```

```typescript
// Step 1: Create all states (only the initial state shown; repeat for each)
const draftState = await apiRoot.states().post({
  body: {
    key: 'product-draft',
    type: 'ProductState',
    name: { en: 'Draft' },
    initial: true,
    transitions: [],  // Will be updated after all states exist
  },
}).execute();
// Repeat for: product-in-review, product-approved, product-published
// (set initial: false for all non-initial states)

// Step 2: Set allowed transitions on each state
await apiRoot.states().withKey({ key: 'product-draft' }).post({
  body: {
    version: draftState.body.version,
    actions: [{
      action: 'setTransitions',
      transitions: [
        { typeId: 'state', key: 'product-in-review' },
      ],
    }],
  },
}).execute();
// Repeat for each state: in-review -> [approved, draft],
// approved -> [published, draft]

// Step 3: Transition a product through the workflow
await apiRoot.products().withKey({ key: 'my-product' }).post({
  body: {
    version: productVersion,
    actions: [{
      action: 'transitionState',
      state: { typeId: 'state', key: 'product-in-review' },
    }],
  },
}).execute();
```

## Product Selection Migration for Multi-Store

```typescript
// Setting up Product Selections for a multi-store deployment

// Step 1: Create selections for each store's assortment
const sharedSelection = await apiRoot.productSelections().post({
  body: { key: 'shared-catalog', name: { en: 'Shared Catalog (All Stores)' } },
}).execute();
// Repeat for: 'premium-only', etc.

// Step 2: Assign products to selections
await apiRoot.productSelections().withKey({ key: 'shared-catalog' }).post({
  body: {
    version: sharedSelection.body.version,
    actions: [
      { action: 'addProduct', product: { typeId: 'product', key: 'classic-tee' } },
      { action: 'addProduct', product: { typeId: 'product', key: 'basic-jeans' } },
    ],
  },
}).execute();

// Step 3: Link selections to stores (each store can have multiple selections)
await apiRoot.stores().withKey({ key: 'premium-store' }).post({
  body: {
    version: premiumStoreVersion,
    actions: [
      { action: 'addProductSelection', productSelection: { typeId: 'product-selection', key: 'shared-catalog' }, active: true },
      { action: 'addProductSelection', productSelection: { typeId: 'product-selection', key: 'premium-only' }, active: true },
    ],
  },
}).execute();
```

## Migration Testing Checklist

- [ ] Migration scripts tested against a staging environment with production-equivalent data
- [ ] Product type definitions validated before product import
- [ ] Category hierarchy imported top-down and verified
- [ ] Sample products with worst-case variants tested (100 variants, all attributes populated)
- [ ] Price selection logic verified for all currency/country/channel combinations
- [ ] Custom type fields verified on all resource types
- [ ] Import operation errors reviewed and resolved
- [ ] Rollback plan documented and tested
- [ ] SEO redirects planned for slug changes
- [ ] External system references (ERP, PIM, CMS) updated for new resource IDs
- [ ] Performance tested with production-scale data volume
- [ ] Merchant Center access and permissions verified

## Reference

- [Terraform Provider for commercetools](https://github.com/labd/terraform-provider-commercetools)
- [Import API Overview](https://docs.commercetools.com/import-export/overview)
- [States API](https://docs.commercetools.com/api/projects/states)
- [Product Selections API](https://docs.commercetools.com/api/projects/product-selections)
- [Stores API](https://docs.commercetools.com/api/projects/stores)
