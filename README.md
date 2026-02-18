# Composable Commerce Skills

Production-tested patterns for composable commerce development from **[Aries Solutions](https://ariessolutions.io)** — a commercetools Platinum partner with the most live commercetools implementations in North America.

These skills give AI coding assistants expert-level knowledge of commercetools APIs, data modeling, Merchant Center customization, and storefront development. They encode hundreds of real-world lessons into structured guidance that prevents costly mistakes.

## Skill Catalog

| Skill | Description | Install |
|-------|-------------|---------|
| [commercetools-api](skills/commercetools-api/SKILL.md) | Backend API patterns — cart/checkout, orders, payments, extensions, subscriptions, B2B, promotions, search | `npx skills install ariessolutionsio/composable-skills/commercetools-api` |
| [commercetools-data](skills/commercetools-data/SKILL.md) | Data modeling — product types, custom types/objects, categories, import/export, migration | `npx skills install ariessolutionsio/composable-skills/commercetools-data` |
| [commercetools-merchant-center](skills/commercetools-merchant-center/SKILL.md) | MC customization — custom applications, custom views, UI Kit, deployment | `npx skills install ariessolutionsio/composable-skills/commercetools-merchant-center` |
| [commercetools-frontend](skills/commercetools-frontend/SKILL.md) | Storefront development — Next.js, React, SSR/SSG, commercetools Frontend, performance, SEO | `npx skills install ariessolutionsio/composable-skills/commercetools-frontend` |
| [akeneo](skills/akeneo/SKILL.md) | Akeneo PIM development and commercetools integration | *Coming soon* |
| [algolia](skills/algolia/SKILL.md) | Algolia commerce search and commercetools integration | *Coming soon* |

## Installation

Install individual skills into your project:

```bash
# Install a single skill
npx skills install ariessolutionsio/composable-skills/commercetools-api

# Install multiple skills
npx skills install ariessolutionsio/composable-skills/commercetools-api
npx skills install ariessolutionsio/composable-skills/commercetools-data
npx skills install ariessolutionsio/composable-skills/commercetools-frontend
```

After installation, your AI assistant will automatically consult the skill when working on matching tasks.

## How Skills Work

Each skill uses a **hub-and-spoke architecture**:

- **SKILL.md** (the hub) — Categorized index of patterns organized by priority level (CRITICAL > HIGH > MEDIUM > LOW). Contains trigger keywords so the AI knows when to activate, and links to reference files for detailed guidance.
- **references/*.md** (the spokes) — Focused reference files covering specific topics. Include correct/incorrect code pairs, checklists, pitfall warnings, and real error messages. Loaded on-demand — only what's needed for the current task.

This structure keeps context windows efficient. The AI reads the hub to understand what's available, then loads only the specific reference files relevant to the task at hand.

## Complements the commercetools MCP

These skills provide **judgment and patterns** — when to use which approach, what goes wrong in production, and how to structure code correctly. They complement (not replace) the commercetools MCP servers:

| Need | Use |
|------|-----|
| Understanding the right pattern and avoiding pitfalls | **These skills** |
| Searching documentation, fetching GraphQL/OAS schemas | [Developer MCP](https://docs.commercetools.com/sdk/mcp/developer-mcp) (free, 100 req/15 min) |
| CRUD operations on products, carts, orders | [Commerce MCP](https://docs.commercetools.com/sdk/mcp/commerce-mcp) (95+ tools, requires auth) |

**Best workflow:** Use a skill to understand the _right pattern_ → use the Developer MCP to look up exact field names and API shapes → write the code → use the Commerce MCP to test against your project.

## About Aries Solutions

[Aries Solutions](https://ariessolutions.io) is a commercetools Platinum partner specializing in composable commerce implementations. We build, launch, and maintain commerce platforms for brands across North America.

### Open Source

We maintain several open-source projects for the commercetools ecosystem:

- **[Shop Assist](https://github.com/ariessolutionsio/shop-assist)** — Merchant Center custom application for cart search and customer service workflows
- **[Emailer](https://github.com/ariessolutionsio/commercetools-emailer)** — Merchant Center custom application for email template management with drag-and-drop editing
- **[Custom Objects Editor](https://github.com/ariessolutionsio/custom-objects-editor)** — Merchant Center custom application for managing Custom Objects with schema-driven forms

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines on adding new skills, improving existing ones, and the PR process.

## License

[MIT](LICENSE)
