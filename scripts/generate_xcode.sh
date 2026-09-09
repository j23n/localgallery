#!/usr/bin/env bash
#
# Bootstrap a clean checkout for Xcode: optional model pack, Rust bindings /
# xcframework, then the Xcode project. Order matters — `xcodegen` lists
# `build/core/Generated/GalleryCore.swift` and `GalleryCore.xcframework`,
# which `build_core.sh` creates, and `build/pack` as a folder resource.
#
# `xcodegen` alone does not emit HeicDecoder / writePlaces — those live in
# build/core/Generated/GalleryCore.swift, which build_core.sh refreshes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# CI and pack-less checkouts: create empty build/pack so xcodegen can see it.
# A real pack under build/model_packs is staged when present.
/bin/bash "$ROOT/scripts/prepare_pack.sh" --optional
/bin/bash "$ROOT/scripts/build_core.sh" "$@"
(cd "$ROOT" && xcodegen)
