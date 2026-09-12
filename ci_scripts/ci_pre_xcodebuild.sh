#!/bin/bash
# Xcode Cloud pre-xcodebuild hook: stamp MARKETING_VERSION from the release tag.
#
# Release builds are triggered by pushing a tag vMAJOR.MINOR.PATCH (workflow
# start condition: "Tags beginning with v"). Xcode Cloud exposes the tag as
# $CI_TAG. We overwrite the MARKETING_VERSION fallback in
# Config/Signing.xcconfig so the built/uploaded CFBundleShortVersionString
# is EXACTLY the tag - it can never drift from the release that triggered it.
#
# For non-tag builds (branch/manual start conditions) $CI_TAG is unset and
# the committed xcconfig fallback is used unchanged.
#
# A malformed tag FAILS THE BUILD rather than silently shipping the fallback:
# if a tag triggered the build, the version must come from that tag.

set -euo pipefail

REPO_ROOT="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "$0")/.." && pwd)}"
XCCONFIG="$REPO_ROOT/Config/Signing.xcconfig"

if [ ! -f "$XCCONFIG" ]; then
    echo "error: Config/Signing.xcconfig not found at $XCCONFIG" >&2
    exit 1
fi

if [ -z "${CI_TAG:-}" ]; then
    echo "ci_pre_xcodebuild: no CI_TAG (non-tag build); keeping xcconfig MARKETING_VERSION fallback."
    exit 0
fi

# Accept v0.0.5 and 0.0.5 forms.
VERSION="${CI_TAG#v}"
if ! echo "$VERSION" | grep -Eq "^[0-9]+\.[0-9]+\.[0-9]+$"; then
    echo "error: tag '$CI_TAG' is not a release tag (expected vMAJOR.MINOR.PATCH, e.g. v0.0.5)" >&2
    exit 1
fi

echo "ci_pre_xcodebuild: stamping MARKETING_VERSION=$VERSION from tag $CI_TAG"
# xcconfig assignments have no trailing semicolon; match the whole line.
sed -i.bak -E "s|^MARKETING_VERSION = .*|MARKETING_VERSION = ${VERSION}|" "$XCCONFIG"
rm -f "${XCCONFIG}.bak"

if ! grep -q "^MARKETING_VERSION = ${VERSION}$" "$XCCONFIG"; then
    echo "error: MARKETING_VERSION stamp did not land in $XCCONFIG" >&2
    exit 1
fi
echo "ci_pre_xcodebuild: done."
