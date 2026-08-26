#!/usr/bin/env bash
#
# Stamp CFBundleVersion on the built product with `git rev-list --count HEAD`.
# Same rule as j23n/localcontacts: the marketing version stays 1.0.0, the
# build number is the commit count, and only the copy in TARGET_BUILD_DIR is
# touched — source Info.plists stay $(CURRENT_PROJECT_VERSION).
#
# Invoked from the app and widget Run Script phases. Requires
# ENABLE_USER_SCRIPT_SANDBOXING=NO so git can read .git (listing HEAD as an
# input is not enough; rev-list walks objects and packed-refs).

set -euo pipefail
export PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin:${PATH:-}"

ROOT="${SRCROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BUILD="$(git -C "$ROOT" rev-list --count HEAD)"
if [[ -z "$BUILD" ]]; then
    echo "error: git rev-list --count HEAD returned empty" >&2
    exit 1
fi

plist="${TARGET_BUILD_DIR:?}/${INFOPLIST_PATH:?}"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$plist"

dsym="${DWARF_DSYM_FOLDER_PATH:-}/${DWARF_DSYM_FILE_NAME:-}/Contents/Info.plist"
if [[ -f "$dsym" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$dsym"
fi

echo "note: set CFBundleVersion=$BUILD"
