# Data Modeling Anti-Patterns Catalog

**Impact: MEDIUM to CRITICAL -- Comprehensive reference of the most common and costly data modeling mistakes in commercetools implementations.**

This file catalogs the full spectrum of data modeling anti-patterns. Each entry includes the mistake, why developers make it, the consequence, and the correct approach. Use this as a review checklist before finalizing any data model design.

## Table of Contents
- [Product Type Anti-Patterns](#product-type-anti-patterns)
  - [1. Mirroring the PIM/ERP Schema](#1-mirroring-the-pimerp-schema)
  - [2. Using Text for Everything](#2-using-text-for-everything)
  - [3. Single-Use Attributes](#3-single-use-attributes)
  - [4. Ignoring Attribute Name Consistency](#4-ignoring-attribute-name-consistency)
  - [5. Using Product Types Where Categories Would Work](#5-using-product-types-where-categories-would-work)
  - [6. Not Testing with Real Data](#6-not-testing-with-real-data)
- [Custom Type Anti-Patterns](#custom-type-anti-patterns)
  - [7. Confusing Custom Types with Custom Objects](#7-confusing-custom-types-with-custom-objects)
  - [8. Field Name Collisions in Shared Types](#8-field-name-collisions-in-shared-types)
  - [9. Attempting In-Place Field Type Changes](#9-attempting-in-place-field-type-changes)
- [Category Anti-Patterns](#category-anti-patterns)
  - [10. Deep Category Nesting (5+ Levels)](#10-deep-category-nesting-5-levels)
  - [11. Assuming Category Inheritance](#11-assuming-category-inheritance)
  - [12. Using Categories for Dynamic Collections](#12-using-categories-for-dynamic-collections)
  - [13. Exceeding 10,000 Categories](#13-exceeding-10000-categories)
- [Localization Anti-Patterns](#localization-anti-patterns)
  - [14. Over-Localizing Universal Data](#14-over-localizing-universal-data)
  - [15. No Locale Fallback Strategy](#15-no-locale-fallback-strategy)
  - [16. Separate Projects Per Country](#16-separate-projects-per-country)
- [Import Anti-Patterns](#import-anti-patterns)
  - [17. Exceeding the 20-Resource Batch Limit](#17-exceeding-the-20-resource-batch-limit)
  - [18. Ignoring Import Order Dependencies](#18-ignoring-import-order-dependencies)
  - [19. Not Monitoring Import Operations](#19-not-monitoring-import-operations)
  - [20. Missing Keys on Resources](#20-missing-keys-on-resources)
- [Architecture Anti-Patterns](#architecture-anti-patterns)
  - [21. Multiple Projects Instead of Stores](#21-multiple-projects-instead-of-stores)
  - [22. Storing Non-Price Data in Prices](#22-storing-non-price-data-in-prices)
  - [23. Not Using Product Projections for Storefront](#23-not-using-product-projections-for-storefront)
  - [24. Not Leveraging the Product Search API](#24-not-leveraging-the-product-search-api)
- [Data Model Review Checklist](#data-model-review-checklist)
  - [Product Types](#product-types)
  - [Custom Types](#custom-types)
  - [Categories](#categories)
  - [Localization](#localization)
  - [Import](#import)
  - [Architecture](#architecture)
- [Reference](#reference)

## Product Type Anti-Patterns

### 1. Mirroring the PIM/ERP Schema

**Mistake:** Replicating every field from the source system (ERP, PIM, MDM) into commercetools product type attributes.

**Why developers do it:** They want a "single source of truth" or think they might need the data later.

**Consequence:** Bloated API responses, degraded search performance, cluttered Merchant Center. Removing attributes later is painful or impossible.

**Correct approach:** Only create attributes that feed into the storefront experience or a concrete business process. Keep ERP/PIM-only data in the source system. Use a simple `key` or Custom Object for cross-reference tracking.

### 2. Using Text for Everything

**Mistake:** Defaulting to `text` type for all attributes, including values that should be enums, numbers, or booleans.

```typescript
// Anti-pattern
{ name: 'color', type: { name: 'text' } }        // "Red", "red", "RED", "Rot"
{ name: 'isOrganic', type: { name: 'text' } }     // "yes", "true", "Y", "1"
{ name: 'weight', type: { name: 'text' } }        // "500g", "500", "0.5 kg"
```

**Consequence:** No faceting on free text. No data validation. No sorting for numeric values. Inconsistent data quality.

**Correct approach:**

```typescript
// Correct types
{ name: 'color', type: { name: 'lenum', values: [...] } }  // Validated, facetable
{ name: 'isOrganic', type: { name: 'boolean' } }            // true/false only
{ name: 'weightGrams', type: { name: 'number' } }           // Numeric, sortable
```

### 3. Single-Use Attributes

**Mistake:** Adding attributes to a Product Type that apply to only one product in the catalog.

**Why developers do it:** They model one specific product's unique features without considering the broader catalog.

**Consequence:** Every product using that type carries an empty attribute that is irrelevant to it.

**Correct approach:** If an attribute applies to only one product, store it as a Custom Object linked to the product by key. Reserve Product Type attributes for data shared by the majority of products in that type.

### 4. Ignoring Attribute Name Consistency

**Mistake:** Using the same attribute name with different types across Product Types.

```typescript
// Product Type "Apparel": color is lenum
{ name: 'color', type: { name: 'lenum', values: [...] } }

// Product Type "Electronics": color is text -- CONFLICT
{ name: 'color', type: { name: 'text' } }
```

**Consequence:** commercetools requires that attribute names be consistent across all Product Types. The same name must have the same base type. This will cause an API error on the second Product Type creation.

**Correct approach:** Maintain a global attribute registry. Before creating any attribute, check if the name already exists in another Product Type and ensure the type matches. Exception: `enum` and `lenum` types can have different values across types.

### 5. Using Product Types Where Categories Would Work

**Mistake:** Creating separate Product Types to classify products when Categories would provide the same classification with more flexibility.

**Why developers do it:** Product Types feel like the primary way to classify products.

**Consequence:** Products are locked to a classification that cannot be changed (because Product Types are immutable on products). Categories, by contrast, can be freely reassigned.

**Correct approach:** Ask "Could this Product Type be modeled as a Category?" If the distinction is about where the product appears in navigation or how customers browse, use Categories. If the distinction is about what attributes the product has, use Product Types.

### 6. Not Testing with Real Data

**Mistake:** Designing the data model on paper or with synthetic data, then discovering problems after importing real production data.

**Why developers do it:** They want to move fast and design ahead of data availability.

**Consequence:** Products do not fit the model. Too many variants for the 100-variant limit. Attribute values do not match enum definitions. Missing locales. Discovery happens after product types are already in use and cannot be changed.

**Correct approach:** Before finalizing any Product Type, import a representative sample of real products. Include:
- The product with the most variants
- The product with the most attributes
- Products from each planned Product Type
- Edge cases (discontinued products, bundles, configurable products)

## Custom Type Anti-Patterns

### 7. Confusing Custom Types with Custom Objects

**Mistake:** Storing resource-specific data as Custom Objects (requiring extra lookups) or storing standalone configuration as Custom Fields on an arbitrary resource.

```typescript
// Anti-pattern: Loyalty points as a Custom Object instead of a Customer Custom Field
const loyaltyPoints = await apiRoot.customObjects().post({
  body: {
    container: 'loyalty',
    key: `customer-${customerId}`,  // Manually linking to customer
    value: { points: 500 },
  },
}).execute();
// Now every loyalty check requires TWO API calls: fetch customer + fetch custom object

// Anti-pattern: Storing app config as a Custom Field on a Category
// because you already had a Custom Type on categories
await apiRoot.categories().withKey({ key: 'root' }).post({
  body: {
    version,
    actions: [{
      action: 'setCustomField',
      name: 'globalFeatureFlags',  // This is not category-specific data
      value: '{"enableWishlist": true}',
    }],
  },
}).execute();
```

**Correct approach:** Custom Fields extend the resource they are attached to. Custom Objects are standalone. Loyalty points on a Customer = Custom Field. App configuration = Custom Object.

### 8. Field Name Collisions in Shared Types

**Mistake:** Using generic field names in composable Custom Types where multiple services write fields.

```typescript
// Two services both add a field called "status" to the same shared type
// Service A: "status" means tax calculation status
// Service B: "status" means loyalty enrollment status
// Result: They overwrite each other
```

**Correct approach:** Always prefix field names with the service or domain name: `tax-status`, `loyalty-status`.

### 9. Attempting In-Place Field Type Changes

**Mistake:** Removing a field and re-adding it with a different type in the same or consecutive requests.

**Consequence:** The API may report success but the actual field type may not change. Data written under the old type definition may become unreadable. Silent data corruption.

**Correct approach:** Create a new field with the correct type, migrate data, update consumers, then remove the old field.

## Category Anti-Patterns

### 10. Deep Category Nesting (5+ Levels)

**Mistake:** Creating deeply nested category hierarchies that mirror internal product taxonomy.

**Consequence:** Poor storefront UX (users get lost). No automatic product inheritance. Complex breadcrumb logic. More API calls to resolve the full path.

**Correct approach:** Keep hierarchies to 2-3 levels for primary navigation. Use product attributes for further classification below that point.

### 11. Assuming Category Inheritance

**Mistake:** Expecting products assigned to "Boots" to automatically appear in queries for the parent "Footwear" category.

**Consequence:** Category landing pages appear empty. Navigation shows zero products for parent categories.

**Correct approach:** Either assign products to all ancestor categories explicitly, or use the Product Search API with subtree filters.

### 12. Using Categories for Dynamic Collections

**Mistake:** Creating categories for "Sale", "New Arrivals", "Best Sellers", "Featured" and manually assigning products to them.

**Consequence:** High maintenance burden. Products must be manually added/removed. "New Arrivals" must be constantly updated. "Best Sellers" requires manual recalculation.

**Correct approach:**
- **Sale:** Drive via Product Discounts or Cart Discounts
- **New Arrivals:** Sort by `createdAt` or `lastModifiedAt` in search
- **Best Sellers:** Maintain a Custom Object with ranked product keys, updated by an analytics pipeline
- **Featured:** Use Product Selections for curated collections

### 13. Exceeding 10,000 Categories

**Mistake:** Creating categories for data that should be attributes (one category per brand, per color, per vendor).

**Consequence:** Hitting the 10,000 category limit, requiring a support review to increase.

**Correct approach:** Categories are for hierarchical navigation. Attributes are for flat classification and filtering.

## Localization Anti-Patterns

### 14. Over-Localizing Universal Data

**Mistake:** Using `LocalizedString` for data that is identical across all locales (SKUs, part numbers, technical specs).

**Consequence:** N x storage and payload size for zero benefit, where N is the number of locales.

**Correct approach:** Use `LocalizedString` (`ltext`) only for genuinely translatable content. Use `text` or `number` for universal data.

### 15. No Locale Fallback Strategy

**Mistake:** Reading localized fields without fallback logic.

```typescript
// Displays "undefined" when the locale is missing
const name = product.name[requestedLocale];
```

**Consequence:** Blank product names, empty descriptions, or JavaScript errors on the storefront for locales without translations.

**Correct approach:** Implement a fallback chain: requested locale -> language without region -> default language -> first available value.

### 16. Separate Projects Per Country

**Mistake:** Creating separate commercetools projects for each country instead of using stores within a single project.

**Consequence:** Duplicate catalog management, no shared customers, 3x operational cost, data inconsistency across markets.

**Correct approach:** Single project with Stores, Channels, Product Selections, and localized pricing.

## Import Anti-Patterns

### 17. Exceeding the 20-Resource Batch Limit

**Mistake:** Sending more than 20 resources in a single Import API request.

**Consequence:** The request is rejected entirely.

**Correct approach:** Batch all imports into groups of 20 or fewer.

### 18. Ignoring Import Order Dependencies

**Mistake:** Importing products before their product types exist, or importing child categories before parent categories.

**Consequence:** Unresolved references. The Import API retries up to 5 times over 48 hours, but if dependencies are never resolved, the import fails permanently.

**Correct approach:** Import in dependency order: types -> categories (top-down) -> products -> variants -> inventory -> prices.

### 19. Not Monitoring Import Operations

**Mistake:** Sending import requests and assuming they all succeed without checking operation status.

**Consequence:** Silent failures. Products missing from the catalog with no notification. Data inconsistency between source system and commercetools.

**Correct approach:** Poll import operation status. Log all rejected and failed operations. Implement alerting for import failures.

### 20. Missing Keys on Resources

**Mistake:** Creating resources without `key` values, making them impossible to reference in the Import API.

**Consequence:** Resources cannot be updated via the Import API (which uses keys for upsert matching). Manual ID-based updates required.

**Correct approach:** Always set `key` on every resource: products, product types, categories, customers, custom types, channels, stores.

## Architecture Anti-Patterns

### 21. Multiple Projects Instead of Stores

**Mistake:** Creating separate commercetools projects for each brand, channel, or region.

**Consequence:** Complete catalog duplication, no shared customers, exponentially higher operational costs.

**Correct approach:** Single project with Stores, scoped OAuth tokens, Product Selections for assortment control.

### 22. Storing Non-Price Data in Prices

**Mistake:** Using the commercetools pricing system for MSRP, "compare at" prices, or reference prices.

**Consequence:** Price calculation is computationally expensive due to the complex selection fallback logic. Adding non-purchase prices to the system increases computation for every price resolution.

**Correct approach:** Store only actual purchase prices in the Prices system. Store MSRP and reference prices as product attributes.

### 23. Not Using Product Projections for Storefront

**Mistake:** Using the `/products` endpoint for storefront-facing API calls.

**Consequence:** Responses contain both current and staged data -- approximately double the payload size.

**Correct approach:** Always use `/product-projections` for storefront. Use `/products` only for administration and import/export.

### 24. Not Leveraging the Product Search API

**Mistake:** Using the Product Projections Query API for storefront discovery (search bars, product listing pages, faceted navigation).

**Consequence:** Dramatically worse performance. Queries on attributes are not indexed by default and become slow for large catalogs.

**Correct approach:** Use the Product Search API for all storefront discovery. It is backed by a search-optimized technology stack.

## Data Model Review Checklist

Run through this checklist before finalizing any data model:

### Product Types
- [ ] Each Product Type has 80%+ attribute overlap among its products
- [ ] No single-use attributes (use Custom Objects instead)
- [ ] Filterable values use `enum`/`lenum`, not `text`
- [ ] Attribute constraints are set correctly (`SameForAll` vs `None` vs `CombinationUnique`)
- [ ] Attribute names are globally consistent across all types
- [ ] `isSearchable` is `true` only for search/faceting attributes
- [ ] Variant count will not exceed 100 for any product
- [ ] Design tested with real production data

### Custom Types
- [ ] Only one Custom Type per resource type is planned
- [ ] Field names are prefixed with service/domain name
- [ ] No field type changes planned after initial deployment
- [ ] Custom Objects used for standalone data, Custom Types for resource extensions

### Categories
- [ ] Hierarchy depth is 3 levels or fewer
- [ ] Application handles lack of automatic inheritance
- [ ] Dynamic collections use search/selections, not category assignments
- [ ] Category count is well under 10,000

### Localization
- [ ] Only genuinely translatable content uses `LocalizedString`
- [ ] Locale fallback chain is implemented
- [ ] `localeProjection` is used in queries

### Import
- [ ] All resources have `key` values
- [ ] Batch size is 20 or fewer
- [ ] Import order respects dependencies
- [ ] Operation status is monitored

### Architecture
- [ ] Single project with Stores (not multiple projects)
- [ ] Product Projections used for storefront (not Products)
- [ ] Product Search API used for discovery (not Query API)
- [ ] Non-purchase prices stored as attributes (not in Prices)

## Reference

- [Product Data Modeling Best Practices](https://docs.commercetools.com/foundry/best-practice-guides/product-data-modeling)
- [Category Best Practices](https://docs.commercetools.com/learning-model-your-product-catalog/categorization/best-practices-and-advanced-category-management)
- [Composable Custom Types](https://docs.commercetools.com/tutorials/composable-custom-types)
- [Performance Tips](https://docs.commercetools.com/api/performance-tips)
- [API Limits](https://docs.commercetools.com/api/limits)
