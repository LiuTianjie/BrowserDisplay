#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_ROOT=${SCRIPT_DIR:h}
APP_NAME=${APP_NAME:-BrowserDisplay}
DIST_DIR=${DIST_DIR:-"$PROJECT_ROOT/dist"}

usage() {
  echo "Usage: tools/release-github.sh v1.0.0" >&2
  exit 1
}

TAG=${1:-}
[[ -n "$TAG" ]] || usage

if [[ "$TAG" != v* ]]; then
  echo "Release tags should start with v, for example: v1.0.0" >&2
  exit 1
fi

cd "$PROJECT_ROOT"

if ! command -v gh >/dev/null 2>&1; then
  echo "GitHub CLI is required. Install it with: brew install gh" >&2
  exit 1
fi

gh auth status >/dev/null

if [[ -n "$(git status --porcelain)" && "${ALLOW_DIRTY:-NO}" != "YES" ]]; then
  echo "Working tree has uncommitted changes. Commit them first, or rerun with ALLOW_DIRTY=YES." >&2
  exit 1
fi

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  TAG_COMMIT=$(git rev-list -n 1 "$TAG")
  HEAD_COMMIT=$(git rev-parse HEAD)
  if [[ "$TAG_COMMIT" != "$HEAD_COMMIT" ]]; then
    echo "Local tag $TAG points to $TAG_COMMIT, but HEAD is $HEAD_COMMIT." >&2
    exit 1
  fi
else
  git tag -a "$TAG" -m "$TAG"
fi

if ! git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
  git push origin "refs/tags/$TAG"
fi

SAFE_TAG="${TAG//\//-}"
export DIST_DIR
export ZIP_BASENAME="${APP_NAME}-macOS-${SAFE_TAG}"
export DMG_BASENAME="$ZIP_BASENAME"
export CREATE_APP_ZIP=${CREATE_APP_ZIP:-NO}
export CREATE_DMG=${CREATE_DMG:-YES}
export REQUIRE_SIGNING=${REQUIRE_SIGNING:-YES}
export NOTARIZE=${NOTARIZE:-YES}
export NOTARYTOOL_PROFILE=${NOTARYTOOL_PROFILE:-BrowserDisplayNotary}

tools/package-macos.sh

assets=(
  "$DIST_DIR"/*.dmg(N)
  "$DIST_DIR"/*.zip(N)
  "$DIST_DIR"/SHA256SUMS.txt
)

if (( ${#assets[@]} == 0 )); then
  echo "No release assets found in $DIST_DIR." >&2
  exit 1
fi

if gh release view "$TAG" >/dev/null 2>&1; then
  gh release upload "$TAG" "${assets[@]}" --clobber
else
  gh release create "$TAG" "${assets[@]}" \
    --title "$TAG" \
    --notes "Signed and notarized macOS release." \
    --verify-tag
fi

echo "Released $TAG:"
gh release view "$TAG" --web
