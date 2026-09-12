#!/bin/bash
# Xcode Cloud post-clone hook: stamp the build number and fetch build inputs.
#
# - CURRENT_PROJECT_VERSION (CFBundleVersion / build number) <- `git rev-list --count HEAD`
#   Auto-increments per commit so every upload is uniquely numbered.
# - MARKETING_VERSION is NOT handled here anymore: it lives in
#   Config/Signing.xcconfig and is stamped from the release tag by
#   ci_pre_xcodebuild.sh (tag-driven releases). The old /VERSION file was
#   removed with that change.
#
# Modern Xcode projects with `GENERATE_INFOPLIST_FILE = YES` keep the build
# number in pbxproj build settings (not Info.plist), so we rewrite that
# directly.

set -euo pipefail

REPO_ROOT="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$REPO_ROOT"

BUILD_NUMBER=$(git rev-list --count HEAD)

PBXPROJ="$REPO_ROOT/Columba.xcodeproj/project.pbxproj"
if [ ! -f "$PBXPROJ" ]; then
    echo "error: project.pbxproj not found at $PBXPROJ" >&2
    exit 1
fi

echo "Setting CURRENT_PROJECT_VERSION=$BUILD_NUMBER in $PBXPROJ"

# In-place rewrite. Match every existing assignment regardless of value.
sed -i.bak -E \
    -e "s|CURRENT_PROJECT_VERSION = [^;]+;|CURRENT_PROJECT_VERSION = ${BUILD_NUMBER};|g" \
    "$PBXPROJ"
rm -f "${PBXPROJ}.bak"

# Fetch the embedded Python.xcframework (BeeWare Python-Apple-support). Like the
# wheels it's gitignored (too large for git, see .gitignore), but the Columba
# target *links* it, so a fresh CI clone has nothing to link against and the
# build fails without this. fetch-python.sh is a plain curl+tar of a pinned
# BeeWare release (no host toolchain needed) and is itself version-aware: it
# bails fast when Frameworks/VERSIONS already matches the pinned build and
# re-fetches when it's missing or stale. Call it unconditionally rather than
# guarding on directory existence here - an outer guard would mask the
# stale-version upgrade fetch-python.sh applies, and would duplicate the pinned
# build tag in two places.
"$REPO_ROOT/support/fetch-python.sh"

# Fetch Python wheels. The wheel dirs are gitignored (not committed), but the
# "Install Python stdlib & process dylibs" build phase hard-requires them, so a
# fresh CI clone must build them here. fetch-wheels.sh resolves RNS from the
# fork branch (torlando-tech/Reticulum @ patches/columba-ios) plus the
# cryptography/cffi binary wheels for iOS. Skipped if already present (local
# incremental runs).
if [ ! -s "$REPO_ROOT/wheels-iphoneos/ble_reticulum/BLEInterface.py" ] || \
   [ ! -s "$REPO_ROOT/wheels-iphonesimulator/ble_reticulum/BLEInterface.py" ]; then
    echo "Fetching Python wheels (RNS from fork branch + binary deps)..."
    "$REPO_ROOT/support/fetch-wheels.sh"
else
    echo "Python wheels already present, skipping fetch."
fi

echo "done."
