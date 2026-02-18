# Category Hierarchy Design

**Impact: CRITICAL -- No automatic inheritance. Deep hierarchies degrade search and navigation.**

Categories in commercetools form a tree structure used for storefront navigation and product organization. Unlike many traditional commerce platforms, commercetools does **not** automatically inherit products from child categories to parent categories. This single behavior difference causes more broken category pages than any other design mistake.

## The Inheritance Trap

In most e-commerce platforms, querying "Footwear" automatically returns products from "Boots", "Sneakers", and "Sandals". In commercetools, it does **not**.

**Anti-Pattern (assuming automatic inheritance):**

```typescript
import { CategoryDraft } from '@commercetools/platform-sdk';

// Create parent category
const footwear = await apiRoot.categories().post({
  body: {
    name: { en: 'Footwear' },
    slug: { en: 'footwear' },
    key: 'footwear',
    orderHint: '0.1',
  } as CategoryDraft,
}).execute();

// Create child category
const boots = await apiRoot.categories().post({
  body: {
    name: { en: 'Boots' },
    slug: { en: 'boots' },
    key: 'boots',
    parent: { typeId: 'category', id: footwear.body.id },
    orderHint: '0.1',
  } as CategoryDraft,
}).execute();

// Assign product to child category only
await apiRoot.products().withId({ ID: productId }).post({
  body: {
    version,
    actions: [{
      action: 'addToCategory',
      category: { typeId: 'category', id: boots.body.id },
    }],
  },
}).execute();

// PROBLEM: Querying products in "Footwear" returns NOTHING
// because the product is only assigned to "Boots"
const footwearProducts = await apiRoot.productProjections().get({
  queryArgs: {
    where: `categories(id="${footwear.body.id}")`,
    staged: false,
  },
}).execute();
// footwearProducts.body.results = [] -- EMPTY!
```

**Recommended (explicit parent assignment or subtree search):**

```typescript
// Option A: Assign product to BOTH parent and child categories
await apiRoot.products().withId({ ID: productId }).post({
  body: {
    version,
    actions: [
      {
        action: 'addToCategory',
        category: { typeId: 'category', id: footwear.body.id },
      },
      {
        action: 'addToCategory',
        category: { typeId: 'category', id: boots.body.id },
      },
    ],
  },
}).execute();

// Option B: Use Product Search API with subtree filter
// This searches the category AND all its descendants
const searchResponse = await apiRoot.productSearch().post({
  body: {
    query: {
      filter: [{
        exact: {
          field: 'categories.id',
          value: footwear.body.id,
          // The Product Search API supports subtree queries
        },
      }],
    },
  },
}).execute();

// Option C: In the Query API, build subtree logic yourself
// Fetch all descendant category IDs, then query with "in" predicate
async function getCategorySubtreeIds(parentId: string): Promise<string[]> {
  const ids = [parentId];
  const children = await apiRoot.categories().get({
    queryArgs: { where: `parent(id="${parentId}")`, limit: 500 },
  }).execute();

  for (const child of children.body.results) {
    const descendantIds = await getCategorySubtreeIds(child.id);
    ids.push(...descendantIds);
  }
  return ids;
}

const allFootwearIds = await getCategorySubtreeIds(footwear.body.id);
const productsInSubtree = await apiRoot.productProjections().get({
  queryArgs: {
    where: `categories(id in (${allFootwearIds.map(id => `"${id}"`).join(',')}))`,
    staged: false,
    limit: 100,
  },
}).execute();
```

**Why This Matters:** If you build a category landing page that queries products by a parent category ID, the page will appear empty even though child categories have products. This is not a bug -- it is by design. You must either assign products to all ancestor categories or use subtree search logic.

## Pattern 1: Shallow Hierarchies

Keep category trees shallow -- 2 to 3 levels is ideal for most storefronts. Deep nesting (5+ levels) creates poor navigation UX and does not add meaningful value.

**Anti-Pattern (deep nesting mirroring internal taxonomy):**

```
Men's Clothing                       (Level 1)
  └── Outerwear                      (Level 2)
       └── Jackets                   (Level 3)
            └── Winter Jackets       (Level 4)
                 └── Down Jackets    (Level 5)
                      └── Hooded Down Jackets (Level 6)
```

**Recommended (shallow hierarchy with attribute-based filtering):**

```
Men's                                (Level 1)
  └── Outerwear                      (Level 2)
       └── Jackets                   (Level 3)

// Use product attributes for further classification:
// - Season: Winter, Spring, Summer, Fall
// - Type: Down, Fleece, Rain, Windbreaker
// - Features: Hooded, Waterproof, Insulated
// These become search facets, not category levels.
```

```typescript
// Build the recommended shallow hierarchy
const mensCategory = await apiRoot.categories().post({
  body: {
    name: { en: "Men's", de: 'Herren' },
    slug: { en: 'mens', de: 'herren' },
    key: 'mens',
    orderHint: '0.1',
  } as CategoryDraft,
}).execute();

const outerwear = await apiRoot.categories().post({
  body: {
    name: { en: 'Outerwear', de: 'Oberbekleidung' },
    slug: { en: 'mens-outerwear', de: 'herren-oberbekleidung' },
    key: 'mens-outerwear',
    parent: { typeId: 'category', id: mensCategory.body.id },
    orderHint: '0.1',
  } as CategoryDraft,
}).execute();

const jackets = await apiRoot.categories().post({
  body: {
    name: { en: 'Jackets', de: 'Jacken' },
    slug: { en: 'mens-jackets', de: 'herren-jacken' },
    key: 'mens-jackets',
    parent: { typeId: 'category', id: outerwear.body.id },
    orderHint: '0.1',
  } as CategoryDraft,
}).execute();

// Classification below this point is handled by product attributes:
// season (enum), jacketType (enum), features (set of enum)
// These appear as search facets on the storefront.
```

## Pattern 2: Customer-Centric Category Names

**Anti-Pattern (overly specific internal terminology):**

```typescript
// Bad: Too specific, mirrors internal product taxonomy
const badCategories = [
  { key: 'womens-wool-work-pants', name: { en: "Women's Wool Work Pants" } },
  { key: 'mens-organic-cotton-crew-neck-tees', name: { en: "Men's Organic Cotton Crew Neck Tees" } },
  { key: 'kids-moisture-wicking-athletic-shorts', name: { en: "Kids' Moisture-Wicking Athletic Shorts" } },
];
```

**Recommended (simple, browsable names):**

```typescript
// Good: How customers actually browse
const goodCategories = [
  { key: 'womens-pants', name: { en: "Women's Pants", de: 'Damenhosen' } },
  { key: 'mens-t-shirts', name: { en: "Men's T-Shirts", de: 'Herren T-Shirts' } },
  { key: 'kids-shorts', name: { en: "Kids' Shorts", de: 'Kinder-Shorts' } },
];

// Specifics like "wool", "organic cotton", "moisture-wicking" become
// filterable product attributes or search facets.
```

**Why This Matters:** Categories should match customer mental models and browsing patterns. Specifics encoded in category names cannot be used as search facets. A customer searching for "organic cotton t-shirts" will use search, not navigate a 6-level-deep category tree.

## Pattern 3: Category Assignment Strategy

**Anti-Pattern (assigning products to too many categories):**

```typescript
// Assigning a product to every conceivable category
await apiRoot.products().withId({ ID: productId }).post({
  body: {
    version,
    actions: [
      { action: 'addToCategory', category: { typeId: 'category', key: 'all-products' } },
      { action: 'addToCategory', category: { typeId: 'category', key: 'mens' } },
      { action: 'addToCategory', category: { typeId: 'category', key: 'mens-clothing' } },
      { action: 'addToCategory', category: { typeId: 'category', key: 'mens-tops' } },
      { action: 'addToCategory', category: { typeId: 'category', key: 'mens-t-shirts' } },
      { action: 'addToCategory', category: { typeId: 'category', key: 'summer-collection' } },
      { action: 'addToCategory', category: { typeId: 'category', key: 'new-arrivals' } },
      { action: 'addToCategory', category: { typeId: 'category', key: 'sale' } },
      { action: 'addToCategory', category: { typeId: 'category', key: 'best-sellers' } },
      { action: 'addToCategory', category: { typeId: 'category', key: 'gift-ideas' } },
      { action: 'addToCategory', category: { typeId: 'category', key: 'cotton-products' } },
      { action: 'addToCategory', category: { typeId: 'category', key: 'casual-wear' } },
      // ... 20 more categories
    ],
  },
}).execute();
// Product documents become bloated, search re-indexing slows down
```

**Recommended (assign to the most specific navigation categories):**

```typescript
// Assign to the leaf navigation category and one or two curated collections
await apiRoot.products().withId({ ID: productId }).post({
  body: {
    version,
    actions: [
      // Primary navigation category (required for breadcrumbs)
      { action: 'addToCategory', category: { typeId: 'category', key: 'mens-t-shirts' } },
      // Parent categories (for inheritance -- if not using subtree search)
      { action: 'addToCategory', category: { typeId: 'category', key: 'mens-tops' } },
      { action: 'addToCategory', category: { typeId: 'category', key: 'mens' } },
      // One curated collection (optional, time-bounded)
      { action: 'addToCategory', category: { typeId: 'category', key: 'summer-collection' } },
    ],
  },
}).execute();

// "Sale", "Best Sellers", "New Arrivals" should be driven by
// Product Discounts, search sorting, or Product Selections --
// NOT by category assignment.
```

## Pattern 4: Category Ordering

The `orderHint` field controls display order within a category level. It is a decimal between 0 and 1.

```typescript
// Set ordering for child categories within a parent
const tops = await apiRoot.categories().post({
  body: {
    name: { en: 'Tops' },
    slug: { en: 'mens-tops' },
    key: 'mens-tops',
    parent: { typeId: 'category', id: mensCategory.body.id },
    orderHint: '0.1',  // Displayed first
  } as CategoryDraft,
}).execute();

const bottoms = await apiRoot.categories().post({
  body: {
    name: { en: 'Bottoms' },
    slug: { en: 'mens-bottoms' },
    key: 'mens-bottoms',
    parent: { typeId: 'category', id: mensCategory.body.id },
    orderHint: '0.2',  // Displayed second
  } as CategoryDraft,
}).execute();

const accessories = await apiRoot.categories().post({
  body: {
    name: { en: 'Accessories' },
    slug: { en: 'mens-accessories' },
    key: 'mens-accessories',
    parent: { typeId: 'category', id: mensCategory.body.id },
    orderHint: '0.3',  // Displayed third
  } as CategoryDraft,
}).execute();

// Product ordering within a category uses categoryOrderHints on the product
await apiRoot.products().withId({ ID: productId }).post({
  body: {
    version,
    actions: [{
      action: 'setCategoryOrderHint',
      categoryId: tops.body.id,
      orderHint: '0.05',  // This product appears near the top in "Tops"
    }],
  },
}).execute();
```

## Pattern 5: Custom Fields on Categories

Extend categories with metadata for the storefront.

```typescript
import { TypeDraft } from '@commercetools/platform-sdk';

// Create a Custom Type for category metadata
const categoryMetaType: TypeDraft = {
  key: 'category-metadata',
  name: { en: 'Category Metadata' },
  resourceTypeIds: ['category'],
  fieldDefinitions: [
    {
      name: 'heroImageUrl',
      label: { en: 'Hero Image URL' },
      type: { name: 'String' },
      required: false,
      inputHint: 'SingleLine',
    },
    {
      name: 'seoDescription',
      label: { en: 'SEO Description' },
      type: { name: 'LocalizedString' },
      required: false,
      inputHint: 'MultiLine',
    },
    {
      name: 'showInNav',
      label: { en: 'Show in Navigation' },
      type: { name: 'Boolean' },
      required: false,
      inputHint: 'SingleLine',
    },
    {
      name: 'navIcon',
      label: { en: 'Navigation Icon' },
      type: {
        name: 'Enum',
        values: [
          { key: 'shirt', label: 'Shirt Icon' },
          { key: 'pants', label: 'Pants Icon' },
          { key: 'shoe', label: 'Shoe Icon' },
          { key: 'bag', label: 'Bag Icon' },
        ],
      },
      required: false,
      inputHint: 'SingleLine',
    },
  ],
};

await apiRoot.types().post({ body: categoryMetaType }).execute();

// Apply custom fields to a category
await apiRoot.categories().withKey({ key: 'mens-tops' }).post({
  body: {
    version: categoryVersion,
    actions: [{
      action: 'setCustomType',
      type: { key: 'category-metadata', typeId: 'type' },
      fields: {
        heroImageUrl: 'https://cdn.example.com/heroes/mens-tops.jpg',
        seoDescription: {
          en: 'Shop the latest men\'s tops, t-shirts, and shirts.',
          de: 'Entdecken Sie die neuesten Herren-Oberteile.',
        },
        showInNav: true,
        navIcon: 'shirt',
      },
    }],
  },
}).execute();
```

## Pattern 6: Building the Category Navigation Tree

Fetching and caching the full category tree for storefront navigation.

```typescript
interface CategoryNode {
  id: string;
  key: string;
  name: Record<string, string>;
  slug: Record<string, string>;
  orderHint: string;
  children: CategoryNode[];
  custom?: Record<string, any>;
}

async function buildCategoryTree(): Promise<CategoryNode[]> {
  // Fetch all categories in a single request (cache this aggressively)
  const allCategories = await apiRoot.categories().get({
    queryArgs: {
      limit: 500,  // Adjust if you have more categories
      sort: ['orderHint asc'],
      expand: ['custom.type'],
    },
  }).execute();

  const categoryMap = new Map<string, CategoryNode>();
  const roots: CategoryNode[] = [];

  // Build nodes
  for (const cat of allCategories.body.results) {
    categoryMap.set(cat.id, {
      id: cat.id,
      key: cat.key ?? '',
      name: cat.name,
      slug: cat.slug,
      orderHint: cat.orderHint ?? '0.5',
      children: [],
      custom: cat.custom?.fields,
    });
  }

  // Build tree
  for (const cat of allCategories.body.results) {
    const node = categoryMap.get(cat.id)!;
    if (cat.parent) {
      const parentNode = categoryMap.get(cat.parent.id);
      if (parentNode) {
        parentNode.children.push(node);
      }
    } else {
      roots.push(node);
    }
  }

  // Sort children by orderHint at each level
  function sortChildren(nodes: CategoryNode[]) {
    nodes.sort((a, b) => parseFloat(a.orderHint) - parseFloat(b.orderHint));
    nodes.forEach(node => sortChildren(node.children));
  }
  sortChildren(roots);

  return roots;
}

// Cache the result -- categories change infrequently
// Invalidate via Subscription on CategoryCreated/CategorySlugChanged events
```

## The 10,000 Category Limit

commercetools enforces a limit of 10,000 categories per project. If you are approaching this limit, it typically means you are using categories for data that should be attributes.

**Signs you need to rethink:**
- Categories encoding attribute data ("Red Shirts", "Blue Shirts" instead of a color attribute)
- One category per brand or manufacturer
- Categories per vendor or supplier
- Categories duplicated per locale

## Design Checklist

- [ ] Hierarchy depth is 3 levels or fewer for primary navigation
- [ ] Category names reflect how customers browse, not internal taxonomy
- [ ] Products are assigned to both leaf and ancestor categories (if not using subtree search)
- [ ] Category count is well under the 10,000 limit
- [ ] `orderHint` values are set for display ordering
- [ ] Slugs are unique across the project and URL-friendly
- [ ] Custom fields provide storefront metadata (hero images, SEO text, nav visibility)
- [ ] Category tree is cached and invalidated via Subscriptions
- [ ] Dynamic collections (sale, new arrivals) use Product Selections or search, not categories
- [ ] Attribute-based filtering (material, color, brand) is NOT encoded as category levels
- [ ] Application code handles the lack of automatic inheritance explicitly

## Reference

- [Categories API](https://docs.commercetools.com/api/projects/categories)
- [Category Best Practices](https://docs.commercetools.com/learning-model-your-product-catalog/categorization/best-practices-and-advanced-category-management)
- [Product Search API (subtree queries)](https://docs.commercetools.com/api/projects/product-search)
