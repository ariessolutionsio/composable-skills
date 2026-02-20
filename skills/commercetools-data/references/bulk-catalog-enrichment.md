# Bulk Catalog Operations: AI Enrichment & Publishing

Patterns for AI-assisted product descriptions, SEO metadata generation, attribute normalization, MCP usage, and publishing changes in commercetools.

## Shared Utilities

This file depends on the following utilities. These are defined in `bulk-catalog-audit.md`. If using both files together, load the audit file for the full implementations.

```typescript
// Paginates through all products using cursor-based pagination.
declare function iterateAllProducts(options?: {
  where?: string[];
  expand?: string[];
  staged?: boolean;
  limit?: number;
}): AsyncGenerator<ProductProjection>;

// Applies batched update actions with retry on ConcurrentModification (409).
declare function batchUpdateProducts(
  updates: ProductUpdate[],
  options?: { concurrency?: number; retries?: number; delayMs?: number }
): Promise<{ succeeded: number; failed: number; errors: string[] }>;

// The shape of each update passed to batchUpdateProducts.
interface ProductUpdate {
  productId: string;
  version: number;
  actions: ProductUpdateAction[];
}
```

## Table of Contents
- [Pattern 7: AI-Assisted Description Generation](#pattern-7-ai-assisted-description-generation)
- [Pattern 8: AI-Assisted SEO Metadata](#pattern-8-ai-assisted-seo-metadata)
- [Pattern 9: Bulk Attribute Value Normalization](#pattern-9-bulk-attribute-value-normalization)
- [Using MCP for Catalog Operations](#using-mcp-for-catalog-operations)
- [Publishing Changes](#publishing-changes)
- [Important Constraints](#important-constraints)
- [Checklist: Bulk Operations](#checklist-bulk-operations)
- [Reference](#reference)

## Pattern 7: AI-Assisted Description Generation

Use an LLM to generate product descriptions from existing product data (name, attributes, categories). This pattern works with any AI provider (Claude, OpenAI, etc.).

```typescript
import Anthropic from '@anthropic-ai/sdk';

const anthropic = new Anthropic();

/**
 * Generate a product description using AI based on product attributes.
 */
async function generateDescription(
  product: ProductProjection,
  locale: string,
  options: {
    tone?: string;
    maxLength?: number;
    includeAttributes?: boolean;
  } = {}
): Promise<string> {
  const {
    tone = 'professional and engaging',
    maxLength = 300,
    includeAttributes = true,
  } = options;

  const name = product.name[locale] || product.name['en'] || 'Unknown Product';

  // Gather product context
  const context: string[] = [`Product name: ${name}`];

  if (product.categories?.length) {
    context.push(`Categories: ${product.categories.map(c => c.id).join(', ')}`);
  }

  if (includeAttributes && product.masterVariant.attributes) {
    const attrs = product.masterVariant.attributes
      .filter(a => a.value !== null && a.value !== undefined)
      .map(a => {
        const value = typeof a.value === 'object' && a.value !== null
          ? (a.value.label || a.value.key || JSON.stringify(a.value))
          : String(a.value);
        return `${a.name}: ${value}`;
      })
      .join(', ');
    if (attrs) context.push(`Attributes: ${attrs}`);
  }

  if (product.masterVariant.prices?.length) {
    const price = product.masterVariant.prices[0];
    const amount = (price.value.centAmount / Math.pow(10, price.value.fractionDigits)).toFixed(2);
    context.push(`Price: ${amount} ${price.value.currencyCode}`);
  }

  const message = await anthropic.messages.create({
    model: 'latest', // use the latest Claude model available
    max_tokens: 1024,
    messages: [{
      role: 'user',
      content: `Write a ${tone} product description for an e-commerce website.
Keep it under ${maxLength} characters. Do not include the product name in the description.
Do not use markdown formatting. Write plain text only.

${context.join('\n')}`,
    }],
  });

  const content = message.content[0];
  if (content.type === 'text') {
    return content.text.slice(0, maxLength);
  }
  throw new Error('Unexpected AI response format');
}

/**
 * Generate and apply AI descriptions for products missing them.
 */
async function enrichProductDescriptions(
  locale: string,
  options: {
    dryRun?: boolean;
    tone?: string;
    maxLength?: number;
    maxProducts?: number;
  } = {}
): Promise<ProductUpdate[]> {
  const {
    dryRun = false,
    tone = 'professional and engaging',
    maxLength = 300,
    maxProducts = Infinity,
  } = options;
  const updates: ProductUpdate[] = [];

  for await (const product of iterateAllProducts({ staged: true })) {
    if (updates.length >= maxProducts) break;
    if (product.description?.[locale]) continue;  // Already has description

    try {
      const description = await generateDescription(product, locale, { tone, maxLength });

      if (dryRun) {
        const name = product.name[locale] || product.name['en'];
        console.log(`\n--- ${name} ---`);
        console.log(description);
      }

      updates.push({
        productId: product.id,
        version: product.version,
        actions: [{
          action: 'setDescription',
          description: { ...product.description, [locale]: description },
          staged: true,
        }],
      });

      // Rate limit AI calls
      await new Promise(r => setTimeout(r, 200));
    } catch (error) {
      console.error(`Failed to generate description for product ${product.id}:`, error);
    }
  }

  console.log(`Generated ${updates.length} description updates`);

  if (!dryRun && updates.length > 0) {
    await batchUpdateProducts(updates);
  }

  return updates;
}

// Usage
// Preview first 10 products
await enrichProductDescriptions('en', { dryRun: true, maxProducts: 10 });

// Apply to all products missing descriptions
await enrichProductDescriptions('en', {
  tone: 'conversational and benefit-focused',
  maxLength: 250,
});
```

## Pattern 8: AI-Assisted SEO Metadata

```typescript
/**
 * Generate SEO meta title and description for products missing them.
 */
async function enrichSEOMetadata(
  locale: string,
  options: { dryRun?: boolean; maxProducts?: number } = {}
): Promise<ProductUpdate[]> {
  const { dryRun = false, maxProducts = Infinity } = options;
  const updates: ProductUpdate[] = [];

  for await (const product of iterateAllProducts({ staged: true })) {
    if (updates.length >= maxProducts) break;

    const missingMetaTitle = !product.metaTitle?.[locale];
    const missingMetaDesc = !product.metaDescription?.[locale];
    if (!missingMetaTitle && !missingMetaDesc) continue;

    const name = product.name[locale] || product.name['en'] || 'Product';
    const description = product.description?.[locale] || '';
    const actions: ProductUpdateAction[] = [];

    try {
      const message = await anthropic.messages.create({
        model: 'latest', // use the latest Claude model available
        max_tokens: 512,
        messages: [{
          role: 'user',
          content: `Generate SEO metadata for this product.

Product name: ${name}
Description: ${description}

Return EXACTLY two lines:
Line 1: Meta title (max 60 characters, include product name)
Line 2: Meta description (max 155 characters, compelling and keyword-rich)

No labels, no prefixes, just the two lines of text.`,
        }],
      });

      const content = message.content[0];
      if (content.type !== 'text') continue;

      const lines = content.text.trim().split('\n').filter(l => l.trim());
      const metaTitle = lines[0]?.slice(0, 60);
      const metaDesc = lines[1]?.slice(0, 155);

      if (missingMetaTitle && metaTitle) {
        actions.push({
          action: 'setMetaTitle',
          metaTitle: { ...product.metaTitle, [locale]: metaTitle },
          staged: true,
        });
      }

      if (missingMetaDesc && metaDesc) {
        actions.push({
          action: 'setMetaDescription',
          metaDescription: { ...product.metaDescription, [locale]: metaDesc },
          staged: true,
        });
      }

      if (actions.length > 0) {
        updates.push({
          productId: product.id,
          version: product.version,
          actions,
        });
      }

      await new Promise(r => setTimeout(r, 200));
    } catch (error) {
      console.error(`Failed to generate SEO for product ${product.id}:`, error);
    }
  }

  console.log(`Generated ${updates.length} SEO metadata updates`);

  if (!dryRun && updates.length > 0) {
    await batchUpdateProducts(updates);
  }

  return updates;
}
```

## Pattern 9: Bulk Attribute Value Normalization

```typescript
/**
 * Find and fix inconsistent attribute values across the catalog.
 * Example: normalize "color" text values to match enum definitions.
 */
async function normalizeAttributeValues(
  attributeName: string,
  normalizationMap: Record<string, string>,
  options: { dryRun?: boolean } = {}
): Promise<ProductUpdate[]> {
  const updates: ProductUpdate[] = [];

  for await (const product of iterateAllProducts({ staged: true })) {
    const allVariants = [product.masterVariant, ...(product.variants || [])];

    for (const variant of allVariants) {
      const attr = variant.attributes?.find(a => a.name === attributeName);
      if (!attr) continue;

      const currentValue = typeof attr.value === 'string' ? attr.value : attr.value?.key;
      const normalizedValue = normalizationMap[currentValue];

      if (normalizedValue && normalizedValue !== currentValue) {
        updates.push({
          productId: product.id,
          version: product.version,
          actions: [{
            action: 'setAttribute',
            variantId: variant.id,
            name: attributeName,
            value: normalizedValue,
            staged: true,
          }],
        });
      }
    }
  }

  console.log(`Found ${updates.length} values to normalize for "${attributeName}"`);

  if (!options.dryRun && updates.length > 0) {
    await batchUpdateProducts(updates);
  }

  return updates;
}

// Usage: normalize free-text color values
await normalizeAttributeValues('color', {
  'Red': 'red',
  'RED': 'red',
  'Blue': 'blue',
  'BLUE': 'blue',
  'Dark Blue': 'navy',
}, { dryRun: true });
```

## Using MCP for Catalog Operations

If you have the **commercetools Commerce MCP** configured, you can perform catalog operations interactively:

```
# Query products missing descriptions (via Commerce MCP)
"Find all products where the description for locale 'en' is not set"

# Update a specific product's slug
"Update product with key 'classic-tee' to add a French slug 'tee-shirt-classique'"

# Check product completeness
"For product 'summer-dress', show me all locales where name, slug, and description are set"
```

The Commerce MCP provides 95+ tools for CRUD operations on commercetools resources. Use it for:
- **Exploratory queries** -- quickly check data without writing code
- **Single-resource updates** -- fix individual products interactively
- **Schema inspection** -- look up product type definitions, custom type fields
- **Verification** -- confirm bulk operations were applied correctly

For bulk operations (100+ products), use the scripted patterns above. The MCP is best for ad-hoc queries and single-resource operations.

## Publishing Changes

All update patterns above use `staged: true` (the default). To make changes visible on the storefront, products must be published:

```typescript
/**
 * Publish all products that have staged changes.
 */
async function publishStagedChanges(
  options: { dryRun?: boolean } = {}
): Promise<number> {
  const updates: ProductUpdate[] = [];

  for await (const product of iterateAllProducts({ staged: true })) {
    if (product.hasStagedChanges) {
      updates.push({
        productId: product.id,
        version: product.version,
        actions: [{ action: 'publish' }],
      });
    }
  }

  console.log(`Found ${updates.length} products with staged changes to publish`);

  if (!options.dryRun && updates.length > 0) {
    await batchUpdateProducts(updates);
  }

  return updates.length;
}
```

## Important Constraints

| Constraint | Value |
|-----------|-------|
| Product slug pattern | `[a-zA-Z0-9_-]{2,256}` |
| Product slug uniqueness | Must be unique per locale across the entire project |
| Max update actions per request | 500 |
| Query results per request | 500 (max offset 10,000) |
| Product Search results per request | 100 |
| Staged vs Current | Updates default to staged; must explicitly publish |

## Checklist: Bulk Operations

- [ ] Start with a **dry run** before applying changes
- [ ] Use **staged updates** (do not publish automatically)
- [ ] Handle **ConcurrentModification** (409) with retry logic
- [ ] Implement **rate limiting** between API calls
- [ ] **Cursor-based pagination** for catalogs > 10,000 products
- [ ] **Log all changes** for auditability
- [ ] **Verify results** after bulk operations complete
- [ ] **Publish explicitly** after reviewing staged changes
- [ ] For AI-generated content, **human review** before publishing

## Reference

- [Product Projections Query API](https://docs.commercetools.com/api/projects/productProjections)
- [Product Update Actions](https://docs.commercetools.com/api/projects/products#update-actions)
- [Product Search API](https://docs.commercetools.com/api/projects/product-search)
- [API Limits](https://docs.commercetools.com/api/limits)
- [Commerce MCP](https://docs.commercetools.com/sdk/mcp/commerce-mcp)
