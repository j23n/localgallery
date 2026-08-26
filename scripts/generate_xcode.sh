#!/usr/bin/env bash
#
# Regenerates UniFFI bindings, then the Xcode project.
#
# `xcodegen` alone does not emit HeicDecoder / writePlaces — those live in
# build/core/Generated/GalleryCore.swift, which build_core.sh refreshes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
/bin/bash "$ROOT/scripts/build_core.sh" "$@"
(cd "$ROOT" && xcodegen)
