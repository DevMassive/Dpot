#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 vX.Y.Z" >&2
  exit 1
fi

TAG="$1"
REMOTE="${REMOTE:-origin}"

# Basic safety checks so we don't publish a bad tag by accident.
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Working tree has uncommitted changes. Commit or stash them before tagging." >&2
  exit 1
fi

if git show-ref --verify --quiet "refs/tags/$TAG"; then
  echo "Tag '$TAG' already exists." >&2
  exit 1
fi

echo "Creating annotated tag $TAG"
git tag -a "$TAG" -m "Release $TAG"

echo "Pushing tag $TAG to $REMOTE"
git push "$REMOTE" "$TAG"

cat <<'EOF'
Tag pushed.
GitHub Actions will build both Apple Silicon and Intel macOS app bundles and attach them to the release.
EOF
