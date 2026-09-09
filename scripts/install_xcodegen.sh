#!/usr/bin/env bash
#
# Install a checksummed XcodeGen release (not `brew install xcodegen`).
# Pin: yonaskolb/XcodeGen 2.46.0 xcodegen.zip, digest from the GitHub
# release API (2026-07-16).
set -euo pipefail

VERSION="${XCODEGEN_VERSION:-2.46.0}"
# sha256 of https://github.com/yonaskolb/XcodeGen/releases/download/2.46.0/xcodegen.zip
SHA256="${XCODEGEN_SHA256:-4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806}"
URL="https://github.com/yonaskolb/XcodeGen/releases/download/${VERSION}/xcodegen.zip"
BIN_DIR="${XCODEGEN_BIN_DIR:-${HOME}/.local/bin}"

mkdir -p "${BIN_DIR}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/xcodegen.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

curl --fail --location --retry 5 --retry-delay 2 --output "${TMP}/xcodegen.zip" "${URL}"
if command -v sha256sum >/dev/null 2>&1; then
    echo "${SHA256}  ${TMP}/xcodegen.zip" | sha256sum -c -
else
    echo "${SHA256}  ${TMP}/xcodegen.zip" | shasum -a 256 -c -
fi

unzip -q "${TMP}/xcodegen.zip" -d "${TMP}/out"
BIN="$(find "${TMP}/out" -type f -name xcodegen -print -quit)"
if [[ -z "${BIN}" ]]; then
    echo "error: xcodegen binary missing from ${URL}" >&2
    exit 1
fi
chmod +x "${BIN}"
install -m 0755 "${BIN}" "${BIN_DIR}/xcodegen"
# SettingPresets sit next to the binary in the official zip; copy if present.
PRESETS="$(find "${TMP}/out" -type d -name SettingPresets | head -n 1)"
if [[ -n "${PRESETS}" ]]; then
    rm -rf "${BIN_DIR}/SettingPresets"
    cp -R "${PRESETS}" "${BIN_DIR}/SettingPresets"
fi

if [[ -n "${GITHUB_PATH:-}" ]]; then
    echo "${BIN_DIR}" >> "${GITHUB_PATH}"
fi
export PATH="${BIN_DIR}:${PATH}"
"${BIN_DIR}/xcodegen" --version
echo "ok: XcodeGen ${VERSION} -> ${BIN_DIR}/xcodegen"
