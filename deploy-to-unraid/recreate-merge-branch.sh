#!/usr/bin/env bash
set -euo pipefail

# Recreates the fork-deploy branch by merging all feature branches onto main.
# Run from anywhere inside the immich repo.

DEPLOY_BRANCH="fork-deploy"
BASE_BRANCH="main"

# Feature branches to merge, in order.
# fork-changes is first because it's just the README and fast-forwards.
FEATURE_BRANCHES=(
  fork-changes
  version-show-fork
  unraid-switch
  partner-sharing-improvements
  hide-album-from-timeline
  filmstrip-navigation
)

cd "$(git rev-parse --show-toplevel)"

current_branch=$(git branch --show-current)

echo "=== Rebuilding $DEPLOY_BRANCH ==="
echo
echo "Base:     $BASE_BRANCH"
echo "Merging:  ${FEATURE_BRANCHES[*]}"
echo

# Verify all feature branches exist locally
for branch in "${FEATURE_BRANCHES[@]}"; do
  if ! git rev-parse --verify "$branch" &>/dev/null; then
    echo "ERROR: Branch '$branch' does not exist locally."
    exit 1
  fi
done

# Reset fork-deploy to main
if git rev-parse --verify "$DEPLOY_BRANCH" &>/dev/null; then
  git checkout "$DEPLOY_BRANCH"
  git reset --hard "$BASE_BRANCH"
else
  git checkout -b "$DEPLOY_BRANCH" "$BASE_BRANCH"
fi

# Merge each feature branch
for branch in "${FEATURE_BRANCHES[@]}"; do
  echo "--- Merging $branch ---"
  if ! git merge "$branch" --no-edit; then
    echo
    echo "ERROR: Merge conflict while merging '$branch'."
    echo "Resolve conflicts, commit, then re-run this script"
    echo "or continue merging the remaining branches manually."
    exit 1
  fi
  echo
done

echo "=== $DEPLOY_BRANCH rebuilt successfully ==="
echo
git log --oneline "$BASE_BRANCH..HEAD"
echo
