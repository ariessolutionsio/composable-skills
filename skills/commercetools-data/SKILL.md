---
name: commercetools-data
description: >
  commercetools data modeling, product type design, custom types, custom
  objects, category hierarchies, import/export, and migration patterns from Aries
  Solutions Engineering. Use when designing product catalogs, creating product types
  or custom types, modeling categories, planning data imports, or migrating to
  commercetools. Triggers on tasks involving product types, attributes, variants,
  custom fields, custom objects, categories, category hierarchies, Import API,
  data migration, product selections, stores, channels, state machines,
  localization, LocalizedString, product type design, data modeling,
  import/export, bulk operations, or catalog management. MUST be consulted
  before creating or modifying product types, custom types, or category
  hierarchies. These decisions are expensive or irreversible in
  commercetools. Do NOT use for API integration code, Merchant Center UI,
  or storefront pages.
license: MIT
metadata:
  author: ariessolutionsio
  version: "1.0.0"
---

# commercetools Data Modeling & Management

Expert guidance for designing data models, importing data, and managing product catalogs in commercetools Composable Commerce. Product types are **immutable once assigned to products** -- getting the data model right is the single most consequential decision in any commercetools implementation.

> **Aries Solutions** is a commercetools Platinum partner with the most live
> commercetools implementations in North America. Data modeling is the #1 pain point we see
> across projects. These patterns prevent the mistakes that cost teams weeks of
> rework -- or force full catalog rebuilds.

## How to Use This Skill

1. Check the priority tables below to find patterns relevant to your task
2. Open the referenced file for detailed guidance, code examples, and anti-patterns
3. All code uses `@commercetools/platform-sdk` and `@commercetools/ts-client` (v3)
4. Impact levels: **CRITICAL** = irreversible or extremely costly | **HIGH** = significant rework | **MEDIUM** = degraded quality | **LOW** = suboptimal

**Progressive loading — only load what you need:**

- Designing product types? Load `references/product-type-design.md`
- Product type operations (CRUD, migration, versioning)? Load `references/product-type-operations.md`
- Choosing Custom Types vs Custom Objects? Load `references/custom-types-objects.md`
- Designing category hierarchies? Load `references/category-design.md`
- Setting up localization? Load `references/localization.md`
- Importing or exporting data? Load `references/import-export.md`
- Planning a migration? Load `references/migration.md`
- Auditing catalog completeness? Load `references/bulk-catalog-audit.md`
- Enriching catalog data (AI-assisted, batch updates)? Load `references/bulk-catalog-enrichment.md`
- Code review or debugging? Load `references/anti-patterns.md`

## CRITICAL Priority -- Irreversible Decisions

| Pattern | File | Impact |
|---------|------|--------|
| Product Type Design Principles | [references/product-type-design.md](references/product-type-design.md) | Cannot change product type on existing products. Cannot delete a type with products. Attribute removal is destructive. |
| Custom Types vs Custom Objects | [references/custom-types-objects.md](references/custom-types-objects.md) | Only one Custom Type per resource at a time. Field type changes silently fail. Wrong choice = data in unreachable places. |
| Category Hierarchy Design | [references/category-design.md](references/category-design.md) | Deep hierarchies degrade search. No automatic inheritance. Restructuring requires product reassignment. |

## HIGH Priority -- Significant Rework

| Pattern | File | Impact |
|---------|------|--------|
| Localization Strategy | [references/localization.md](references/localization.md) | Over-localizing bloats payloads. Missing fallbacks break storefronts. Wrong LocalizedString usage wastes storage. |
| Import & Export Patterns | [references/import-export.md](references/import-export.md) | 20-resource batch limit. Async processing with 48-hour window. Wrong import order causes unresolved references. |
| Migration Strategy | [references/migration.md](references/migration.md) | Big-bang migrations fail. No built-in environment promotion. Product type changes require delete-and-recreate. |

## MEDIUM Priority -- Quality & Maintainability

| Pattern | File | Impact |
|---------|------|--------|
| Bulk Catalog Operations | [references/bulk-catalog-audit.md](references/bulk-catalog-audit.md) | Patterns for auditing catalog completeness (missing slugs, descriptions), batch updates, and AI-assisted data enrichment. |
| Anti-Patterns Catalog | [references/anti-patterns.md](references/anti-patterns.md) | Comprehensive list of data modeling mistakes with consequences and corrections. |

## Common Anti-Patterns (Quick Reference)

| Anti-Pattern | File | Consequence |
|-------------|------|-------------|
| Mirroring PIM/ERP schema into product types | [references/anti-patterns.md](references/anti-patterns.md) | Bloated responses, cluttered MC, impossible attribute removal |
| Using `text` type for filterable values | [references/anti-patterns.md](references/anti-patterns.md) | No faceting, no validation, inconsistent data |
| Using Product Types where Categories work | [references/anti-patterns.md](references/anti-patterns.md) | Locked classification that cannot be changed |
| Deep category nesting (5+ levels) | [references/anti-patterns.md](references/anti-patterns.md) | Poor UX, complex breadcrumbs, extra API calls |
| Assuming category inheritance | [references/anti-patterns.md](references/anti-patterns.md) | Empty parent category pages |
| Over-localizing universal data (SKUs, codes) | [references/anti-patterns.md](references/anti-patterns.md) | N x storage and payload for zero benefit |
| Exceeding 20-resource import batch limit | [references/anti-patterns.md](references/anti-patterns.md) | Entire import request rejected |
| Missing `key` on resources | [references/anti-patterns.md](references/anti-patterns.md) | Cannot update via Import API |

## Decision Flowcharts

### "Where Should This Data Live?"

```
Is the data an attribute of a product variant? (color, size, weight)
  YES --> Product Type attribute
  NO  --> Continue

Is the data extending an existing resource? (loyalty points on Customer,
gift wrap on LineItem, metadata on Order)
  YES --> Custom Type (Custom Fields)
  NO  --> Continue

Is the data standalone reference/config? (feature flags, lookup tables,
app settings, cross-cutting data)
  YES --> Custom Object (container/key)
  NO  --> Continue

Is the data classifying products for navigation? (department, collection)
  YES --> Category
  NO  --> Continue

Is it a workflow state? (product review status, order fulfillment stage)
  YES --> State Machine
  NO  --> Consider whether commercetools is the right place for this data
```

### "Product Type or Category?"

```
Does it define WHAT the product IS? (its schema, its attributes)
  YES --> Product Type

Does it define WHERE the product APPEARS? (navigation, browsing, collections)
  YES --> Category

Rule: If you could model it as a Category, prefer Category.
Categories are flexible. Product Types are permanent.
```

### "How Many Product Types?"

```
Do products share 80%+ of their attributes?
  YES --> Same Product Type (use attributes for differentiation)
  NO  --> Different Product Types

Is data managed in Merchant Center?
  YES --> Use more specific types (better editing UX)
  NO (external PIM) --> Fewer generic types are acceptable
```

## Key Platform Limits

| Resource | Limit | Notes |
|----------|-------|-------|
| Product Types per Project | 1,000 | Hard limit |
| Attributes per Product Type | No hard limit | 50 product-level + 50 variant-level searchable attributes indexed |
| Variants per Product | 100 | Can be increased by contacting support |
| Categories per Project | 10,000 | Requires review to increase |
| Custom Objects per Project | 20,000,000 | Generous but not infinite |
| Import Containers per Project | 1,000 | Keep < 200K operations per container |
| Resources per Import Request | 20 | Hard limit, batch accordingly |
| Import Operation retention | 48 hours | Unresolved refs retry up to 5 times |
| Product Selections per Store | 100 | Plan assortment strategy carefully |
| Distribution Channels per Store | 100 | |
| Supply Channels per Store | 100 | |

## Attribute Constraint Quick Reference

| Constraint | Behavior | Use When |
|------------|----------|----------|
| `None` | No constraint across variants | Variant-level attributes (color per variant) |
| `Unique` | Value must be unique across all variants | Identifiers (variant-specific codes) |
| `SameForAll` | All variants share the same value | Product-level attributes (brand, gender, material) |
| `CombinationUnique` | Combination of attributes must be unique | Size + color combinations |

## Attribute Type Selection Guide

| Data Pattern | Recommended Type | Why |
|-------------|-----------------|-----|
| Filterable options (color, size) | `enum` or `lenum` | Faceting, validation, Merchant Center dropdowns |
| Translatable text | `ltext` | Multi-locale support |
| Universal identifiers (SKU, EAN) | `text` | No translation needed |
| Yes/No flags | `boolean` | Simple, searchable |
| Measurements (weight, dimensions) | `number` | Sortable, rangeable |
| Currency values (NOT prices) | `money` | Proper currency handling |
| References to other resources | `reference` | Typed links to categories, products, etc. |
| Multi-value attributes | `set` of any above | Tags, multiple colors, feature lists |

## MCP Complement

This skill provides **judgment about how to model data correctly**. For API operations and schema details, use the commercetools MCP servers:

- **[Developer MCP](https://docs.commercetools.com/sdk/mcp/developer-mcp)** -- Documentation search, API schema fetching, field-level reference
- **[Commerce MCP](https://docs.commercetools.com/sdk/mcp/commerce-mcp)** -- CRUD operations on resources (create product types, import products, query catalogs, update products -- 95+ tools, requires auth)

**Workflow:** Use this skill to DESIGN the data model, then use the MCP tools to EXECUTE it. For bulk catalog operations, see [references/bulk-catalog-audit.md](references/bulk-catalog-audit.md) (auditing completeness) and [references/bulk-catalog-enrichment.md](references/bulk-catalog-enrichment.md) (AI-assisted enrichment, batch updates).

## Related Skills

- [commercetools-api](../commercetools-api/SKILL.md) -- API conventions, concurrency, error handling, SDK setup
- [commercetools-merchant-center](../commercetools-merchant-center/SKILL.md) -- Merchant Center custom applications and views for managing data
- [commercetools-frontend](../commercetools-frontend/SKILL.md) -- Storefront architecture and how data model choices affect frontend
