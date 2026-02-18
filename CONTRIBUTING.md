# Contributing to Composable Skills

Guidelines for the Aries Solutions engineering team on building, improving, and maintaining skills in this repository.

## Quality Standards

Every skill must meet these requirements before merging to `main`:

### Frontmatter Rules

- `name` is required, must match the directory name exactly
- `name` format: lowercase alphanumeric and hyphens only, 1-64 characters, no consecutive hyphens
- `description` is required, must be under 1024 characters
- `description` must include: what the skill does, task-oriented triggers ("Use when..."), keyword list ("Triggers on tasks involving..."), and action mandates ("MUST be consulted before...")
- `license: MIT` required
- `metadata.author: ariessolutionsio` required
- `metadata.version` required, follows semver (`"1.0.0"`)

### Body Rules

- SKILL.md body must be under 500 lines (excluding frontmatter)
- Use priority tables: CRITICAL > HIGH > MEDIUM > LOW
- Every reference file link must resolve to an existing file in `references/`
- Every cross-reference (`../skill-name/SKILL.md`) must resolve to an existing sibling skill

### Reference Files

- Keep individual reference files focused on one topic
- Include correct/incorrect code pairs where applicable
- Use TypeScript with `@commercetools/platform-sdk` or `@commercetools/ts-client` for commercetools examples
- Include checklists for verification steps
- Target 200-500 lines per reference file

## How to Add a New Skill

1. **Create the directory:**

   ```
   skills/{skill-name}/
   ├── SKILL.md
   └── references/
       └── .gitkeep
   ```

2. **Write the SKILL.md** with valid frontmatter following the rules above.

3. **Add reference files** in the `references/` directory. Start with the highest-impact patterns.

4. **Update CLAUDE.md** — Add the new skill to the Skill Routing section with keywords, and update Cross-Skill Combinations if relevant.

5. **Update README.md** — Add the skill to the catalog table.

6. **Add cross-references** — Update the Related Skills section in sibling skills that are related.

7. **Run validation:**

   ```bash
   ./scripts/validate-skills.sh
   ```

8. **Open a PR** targeting `main`.

## How to Improve an Existing Skill

1. **Read the current SKILL.md** and identify what to change.

2. **For new reference files:** Create the file in `references/`, then add a link in the appropriate priority table in SKILL.md.

3. **For corrections:** Edit the reference file directly. If changing code examples, ensure both anti-pattern and recommended pattern are updated.

4. **For new patterns:** Add to the appropriate priority level table. If unsure about priority level:
   - **CRITICAL**: Irreversible decisions or production-breaking mistakes
   - **HIGH**: Significant rework or security/performance impact
   - **MEDIUM**: Quality degradation or maintainability issues
   - **LOW**: Suboptimal but functional

5. **Run validation** and open a PR.

## PR Process

1. **Branch** from `main` with a descriptive name:
   - `feat/{skill-name}-{topic}` for new content
   - `fix/{skill-name}-{issue}` for corrections
   - `docs/{description}` for documentation updates

2. **Validate** locally:

   ```bash
   ./scripts/validate-skills.sh
   ```

3. **Open PR** with a clear description of what changed and why.

4. **Review** — At least one team member reviews before merge.

5. **Merge** to `main`. CI runs validation automatically.

## Naming Conventions

| Element | Convention | Example |
|---------|-----------|---------|
| Skill directory | lowercase, hyphens | `commercetools-api` |
| Reference files | lowercase, hyphens | `cart-checkout.md` |
| Frontmatter name | matches directory | `name: commercetools-api` |
| Platform prefixes | platform name first | `commercetools-`, `akeneo-`, `algolia-` |
| Generic skills | descriptive name | `composable-architecture` |

## Versioning

Skills use semantic versioning in `metadata.version`:

| Change Type | Version Bump | Examples |
|-------------|-------------|---------|
| Typo fixes, wording improvements | Patch (0.0.x) | Fix code example, clarify description |
| New reference files, new patterns | Minor (0.x.0) | Add B2B reference file, new anti-pattern section |
| Restructure skill, rename, breaking changes | Major (x.0.0) | Split skill into two, change directory name |

## Content Guidelines

- Write for mid-level developers who know TypeScript but may be new to the platform
- Lead with consequences ("This causes...") not just rules ("Don't do...")
- Include real error messages and performance numbers where possible
- Reference the commercetools MCP for API lookups — don't duplicate schema documentation
- Keep the Aries Platinum partner positioning in the intro blockquote
- Cross-reference related skills in every SKILL.md

## Running CI Locally

```bash
# From repo root
./scripts/validate-skills.sh
```

The same script runs in GitHub Actions on every push to `main` and on PRs.
