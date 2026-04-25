#!/bin/bash
# Xcode Cloud post-clone hook: sync the project's version fields to /VERSION
# and the git commit count.
#
# - MARKETING_VERSION (CFBundleShortVersionString) ← contents of /VERSION
#   You bump this manually by editing /VERSION (any of major/minor/patch).
# - CURRENT_PROJECT_VERSION (CFBundleVersion / build number) ← `git rev-list --count HEAD`
#   Auto-increments per commit so every push is a uniquely-numbered TestFlight upload.
#
# Modern Xcode projects with `GENERATE_INFOPLIST_FILE = YES` keep the version
# in pbxproj build settings (not Info.plist), so we rewrite those directly.

set -euo pipefail

REPO_ROOT="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$REPO_ROOT"

VERSION_FILE="$REPO_ROOT/VERSION"
if [ ! -f "$VERSION_FILE" ]; then
    echo "error: VERSION file missing at $VERSION_FILE" >&2
    exit 1
fi

MARKETING_VERSION=$(tr -d '[:space:]' < "$VERSION_FILE")
if ! echo "$MARKETING_VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "error: VERSION must be MAJOR.MINOR.PATCH (e.g., 0.0.2). Got: '$MARKETING_VERSION'" >&2
    exit 1
fi

BUILD_NUMBER=$(git rev-list --count HEAD)

PBXPROJ=$(find "$REPO_ROOT" -maxdepth 3 -name 'project.pbxproj' -type f | head -1)
if [ -z "$PBXPROJ" ]; then
    echo "error: no project.pbxproj found under $REPO_ROOT" >&2
    exit 1
fi

echo "Setting MARKETING_VERSION=$MARKETING_VERSION CURRENT_PROJECT_VERSION=$BUILD_NUMBER in $PBXPROJ"

# In-place rewrite. Match every existing assignment regardless of value.
sed -i.bak -E \
    -e "s|MARKETING_VERSION = [^;]+;|MARKETING_VERSION = ${MARKETING_VERSION};|g" \
    -e "s|CURRENT_PROJECT_VERSION = [^;]+;|CURRENT_PROJECT_VERSION = ${BUILD_NUMBER};|g" \
    "$PBXPROJ"
rm -f "${PBXPROJ}.bak"

echo "done."
