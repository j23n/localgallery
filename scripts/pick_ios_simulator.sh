#!/usr/bin/env bash
#
# Print the name of an available iPhone simulator (newest iOS runtime).
# Used by CI and as the documented xcodebuild destination helper.
# Requires: xcrun, jq. Fails if no iPhone simulator is available.
set -euo pipefail

if ! command -v xcrun >/dev/null 2>&1; then
    echo "error: xcrun not found; pick any available iPhone simulator (iOS 18+)" >&2
    echo "  xcrun simctl list devices available" >&2
    exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "error: jq is required to pick a simulator" >&2
    echo "  xcrun simctl list devices available" >&2
    exit 1
fi

NAME="$(xcrun simctl list devices available -j | jq -r '
  .devices
  | to_entries
  | map(select(.key | contains("iOS")))
  | sort_by(.key)
  | reverse
  | .[0].value
  | map(select(.name | startswith("iPhone")))
  | sort_by(.name)
  | reverse
  | .[0].name // empty
')"

if [[ -z "${NAME}" ]]; then
    echo "error: no available iPhone simulator on iOS 18+" >&2
    xcrun simctl list devices available >&2 || true
    exit 1
fi

echo "${NAME}"
