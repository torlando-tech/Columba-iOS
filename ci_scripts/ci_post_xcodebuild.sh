#!/bin/bash
# Validate the actual device archive before Cloud's distribution/export step.
set -euo pipefail

if [ -z "${CI_ARCHIVE_PATH:-}" ]; then
    echo "ci_post_xcodebuild: no archive; skipping distribution artifact checks."
    exit 0
fi

REPO_ROOT="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "$0")/.." && pwd)}"
APP="$CI_ARCHIVE_PATH/Products/Applications/ColumbaApp.app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
python3 "$REPO_ROOT/support/verify-flavor-artifact.py" unified "$APP"
