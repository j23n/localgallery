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

# `git rev-list --count HEAD` on a shallow clone is the graft depth (often 1),
# not the commit count used as CFBundleVersion. CI must checkout with
# fetch-depth: 0. If we still see a shallow repo, deepen before counting.
if [[ "$(git -C "$ROOT" rev-parse --is-shallow-repository 2>/dev/null || echo true)" == "true" ]]; then
    echo "warning: shallow history; deepening so CFBundleVersion is the commit count" >&2
    if ! git -C "$ROOT" fetch --unshallow --quiet \
        && ! git -C "$ROOT" fetch --deepen=2147483647 --quiet; then
        echo "error: git history is still shallow; checkout with fetch-depth: 0" >&2
        echo "       so \`git rev-list --count HEAD\` is the real build number" >&2
        exit 1
    fi
    if [[ "$(git -C "$ROOT" rev-parse --is-shallow-repository)" == "true" ]]; then
        echo "error: git history is still shallow after fetch; refusing to stamp CFBundleVersion=1" >&2
        exit 1
    fi
fi

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
