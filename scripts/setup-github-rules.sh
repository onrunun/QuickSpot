#!/bin/bash
set -euo pipefail

# Applies professional GitHub repository rulesets and security settings via `gh api`.
# Usage:
#   ./scripts/setup-github-rules.sh --dry-run
#   ./scripts/setup-github-rules.sh --repo owner/QuickSpot

REPO=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      REPO="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [--repo owner/name] [--dry-run]"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

MAIN_RULESET_JSON="$(cat <<'JSON'
{
  "name": "Protect main",
  "target": "branch",
  "enforcement": "active",
  "bypass_actors": [
    {
      "actor_id": 5,
      "actor_type": "RepositoryRole",
      "bypass_mode": "always"
    }
  ],
  "conditions": {
    "ref_name": {
      "include": ["~DEFAULT_BRANCH"],
      "exclude": []
    }
  },
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    {
      "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 1,
        "dismiss_stale_reviews_on_push": true,
        "require_code_owner_review": true,
        "require_last_push_approval": false,
        "required_review_thread_resolution": true
      }
    },
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": true,
        "do_not_enforce_on_create": false,
        "required_status_checks": [
          { "context": "Privacy & Secret Gate" },
          { "context": "Build, Test & App Bundle (macOS)" }
        ]
      }
    }
  ]
}
JSON
)"

TAG_RULESET_JSON="$(cat <<'JSON'
{
  "name": "Protect release tags",
  "target": "tag",
  "enforcement": "active",
  "bypass_actors": [
    {
      "actor_id": 5,
      "actor_type": "RepositoryRole",
      "bypass_mode": "always"
    }
  ],
  "conditions": {
    "ref_name": {
      "include": ["refs/tags/v*.*.*"],
      "exclude": []
    }
  },
  "rules": [
    { "type": "deletion" },
    { "type": "update" },
    { "type": "non_fast_forward" }
  ]
}
JSON
)"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "=== DRY RUN: Main Branch Ruleset ==="
  printf '%s\n' "$MAIN_RULESET_JSON" | python3 -m json.tool
  echo "=== DRY RUN: Release Tag Ruleset ==="
  printf '%s\n' "$TAG_RULESET_JSON" | python3 -m json.tool
  echo "DRY RUN OK: JSON payloads are valid."
  exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "Error: GitHub CLI (gh) is required." >&2
  exit 1
fi

if [[ -z "$REPO" ]]; then
  REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
fi

echo "Configuring repository security & rulesets for: $REPO"

# 1. Repository merge hygiene
gh api -X PATCH "repos/$REPO" \
  -F delete_branch_on_merge=true \
  -F allow_squash_merge=true \
  -F allow_auto_merge=true >/dev/null
echo "OK: Repository merge settings updated."

# 2. Security & analysis (Secret Scanning, Push Protection, Dependabot Alerts, Private Vulnerability Reporting)
gh api -X PATCH "repos/$REPO" \
  -f security_and_analysis[secret_scanning][status]=enabled \
  -f security_and_analysis[secret_scanning_push_protection][status]=enabled >/dev/null 2>&1 \
  && echo "OK: Secret Scanning & Push Protection enabled." \
  || echo "NOTE: Secret Scanning / Push Protection requires a public repo or GitHub Advanced Security."

gh api -X PUT "repos/$REPO/vulnerability-alerts" >/dev/null 2>&1 \
  && echo "OK: Dependabot vulnerability alerts enabled." \
  || echo "NOTE: Could not toggle vulnerability alerts (check repo permissions)."

gh api -X PUT "repos/$REPO/private-vulnerability-reporting" >/dev/null 2>&1 \
  && echo "OK: Private Vulnerability Reporting enabled." \
  || echo "NOTE: Could not enable Private Vulnerability Reporting (check repo visibility)."

# 3. Upsert branch and tag rulesets idempotently
upsert_ruleset() {
  local name="$1"
  local payload="$2"
  local existing_id
  existing_id="$(gh api "repos/$REPO/rulesets" --jq ".[] | select(.name == \"$name\") | .id" 2>/dev/null | head -n 1 || true)"

  if [[ -n "$existing_id" ]]; then
    printf '%s' "$payload" | gh api -X PUT "repos/$REPO/rulesets/$existing_id" --input - >/dev/null
    echo "OK: Updated ruleset '$name' (id: $existing_id)."
  else
    printf '%s' "$payload" | gh api -X POST "repos/$REPO/rulesets" --input - >/dev/null
    echo "OK: Created ruleset '$name'."
  fi
}

upsert_ruleset "Protect main" "$MAIN_RULESET_JSON"
upsert_ruleset "Protect release tags" "$TAG_RULESET_JSON"

echo "Done! All GitHub rulesets and security guards are active on $REPO."
