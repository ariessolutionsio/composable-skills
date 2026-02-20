#!/usr/bin/env bash
set -euo pipefail

# Validate all skills in the skills/ directory.
# Checks frontmatter, naming conventions, description length, body size,
# reference file links, and cross-reference links.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILLS_DIR="$REPO_ROOT/skills"
ERRORS=0

error() {
  echo "  ERROR: $1" >&2
  ERRORS=$((ERRORS + 1))
}

warn() {
  echo "  WARN:  $1" >&2
}

echo "Validating skills in $SKILLS_DIR"
echo "================================"

for skill_dir in "$SKILLS_DIR"/*/; do
  skill_name="$(basename "$skill_dir")"
  skill_file="$skill_dir/SKILL.md"

  echo ""
  echo "--- $skill_name ---"

  # 1. SKILL.md exists
  if [[ ! -f "$skill_file" ]]; then
    error "$skill_name: SKILL.md not found"
    continue
  fi

  # 2. Frontmatter exists (opening and closing ---)
  first_line="$(head -1 "$skill_file")"
  if [[ "$first_line" != "---" ]]; then
    error "$skill_name: Missing opening frontmatter delimiter (---)"
    continue
  fi

  # Find the closing --- (second occurrence, searching from line 2)
  closing_line="$(tail -n +2 "$skill_file" | grep -n '^---$' | head -1 | cut -d: -f1 || true)"
  if [[ -z "$closing_line" ]]; then
    error "$skill_name: Missing closing frontmatter delimiter (---)"
    continue
  fi

  # Extract frontmatter (between the two --- lines)
  frontmatter="$(sed -n "2,${closing_line}p" "$skill_file")"

  # 3. name field exists and is non-empty
  fm_name="$(echo "$frontmatter" | grep -E '^name:\s*' | head -1 | sed 's/^name:\s*//' | xargs)"
  if [[ -z "$fm_name" ]]; then
    error "$skill_name: 'name' field missing or empty in frontmatter"
  else
    # 4. name matches directory name
    if [[ "$fm_name" != "$skill_name" ]]; then
      error "$skill_name: name '$fm_name' does not match directory name '$skill_name'"
    fi

    # 5. name format: lowercase alphanumeric + hyphens, 1-64 chars, no consecutive hyphens
    if ! echo "$fm_name" | grep -qE '^[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?$'; then
      error "$skill_name: name '$fm_name' does not match required format (lowercase alphanumeric + hyphens, 1-64 chars)"
    fi
    if echo "$fm_name" | grep -q -- '--'; then
      error "$skill_name: name '$fm_name' contains consecutive hyphens"
    fi
  fi

  # 6. description exists and under 1024 chars
  # Extract multi-line description (handles folded scalar >)
  desc_start="$(echo "$frontmatter" | grep -n '^description:' | head -1 | cut -d: -f1)"
  if [[ -z "$desc_start" ]]; then
    error "$skill_name: 'description' field missing in frontmatter"
  else
    # Collect description lines: from description: line to next top-level key or end
    desc_lines=""
    in_desc=false
    while IFS= read -r line; do
      if [[ "$in_desc" == false ]]; then
        if echo "$line" | grep -qE '^description:'; then
          in_desc=true
          # Get inline value after "description:"
          inline="$(echo "$line" | sed 's/^description:\s*//' | sed 's/^>\s*//')"
          if [[ -n "$inline" ]]; then
            desc_lines="$inline"
          fi
        fi
      else
        # If line starts with a non-space character and contains ":", it's a new key
        if echo "$line" | grep -qE '^[a-z]'; then
          break
        fi
        trimmed="$(echo "$line" | sed 's/^[ ]*//')"
        if [[ -n "$desc_lines" ]]; then
          desc_lines="$desc_lines $trimmed"
        else
          desc_lines="$trimmed"
        fi
      fi
    done <<< "$frontmatter"

    desc_len="${#desc_lines}"
    if [[ "$desc_len" -eq 0 ]]; then
      error "$skill_name: 'description' is empty"
    elif [[ "$desc_len" -gt 1024 ]]; then
      error "$skill_name: 'description' is $desc_len chars (max 1024)"
    else
      echo "  description: ${desc_len} chars (OK)"
    fi
  fi

  # 7. Only name and description allowed in frontmatter
  extra_keys="$(echo "$frontmatter" | grep -E '^[a-z][a-z_-]*:' | grep -vE '^(name|description):' | head -5 || true)"
  if [[ -n "$extra_keys" ]]; then
    while IFS= read -r key_line; do
      key="$(echo "$key_line" | cut -d: -f1)"
      error "$skill_name: unexpected frontmatter field '$key' (only 'name' and 'description' allowed)"
    done <<< "$extra_keys"
  fi

  # 8. Body under 500 lines
  body_start=$((closing_line + 1))
  total_lines="$(wc -l < "$skill_file")"
  body_lines=$((total_lines - body_start))
  if [[ "$body_lines" -gt 500 ]]; then
    error "$skill_name: body is $body_lines lines (max 500)"
  else
    echo "  body: $body_lines lines (OK)"
  fi

  # 9. All references/*.md links resolve to existing files
  ref_links="$(grep -oE 'references/[a-zA-Z0-9_-]+\.md' "$skill_file" | sort -u || true)"
  if [[ -n "$ref_links" ]]; then
    while IFS= read -r ref; do
      if [[ ! -f "$skill_dir/$ref" ]]; then
        error "$skill_name: broken reference link '$ref'"
      fi
    done <<< "$ref_links"
    ref_count="$(echo "$ref_links" | wc -l)"
    echo "  references: $ref_count links checked (OK)"
  else
    echo "  references: none"
  fi

  # 10. Reference file size check (warn if over 500 lines)
  if [[ -d "$skill_dir/references" ]]; then
    for ref_file in "$skill_dir"/references/*.md; do
      [[ -f "$ref_file" ]] || continue
      ref_lines="$(wc -l < "$ref_file")"
      ref_basename="$(basename "$ref_file")"
      if [[ "$ref_lines" -gt 500 ]]; then
        warn "$skill_name: references/$ref_basename is $ref_lines lines (target: ≤500)"
      fi
    done
  fi

  # 11. All ../*/SKILL.md cross-references resolve to existing files
  xref_links="$(grep -oE '\.\./[a-zA-Z0-9_-]+/SKILL\.md' "$skill_file" | sort -u || true)"
  if [[ -n "$xref_links" ]]; then
    while IFS= read -r xref; do
      target="$skill_dir/$xref"
      if [[ ! -f "$target" ]]; then
        error "$skill_name: broken cross-reference '$xref'"
      fi
    done <<< "$xref_links"
    xref_count="$(echo "$xref_links" | wc -l)"
    echo "  cross-refs: $xref_count links checked (OK)"
  else
    echo "  cross-refs: none"
  fi
done

echo ""
echo "================================"
if [[ "$ERRORS" -gt 0 ]]; then
  echo "FAILED: $ERRORS error(s) found"
  exit 1
else
  echo "PASSED: All skills valid"
  exit 0
fi
