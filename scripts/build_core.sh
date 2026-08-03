#!/usr/bin/env bash
#
# Build the Rust core and assemble everything Xcode needs:
#
#   build/core/GalleryCore.xcframework   static lib + headers + modulemap
#   build/core/Generated/GalleryCore.swift  UniFFI-generated Swift bindings
#
# Usage:  ./scripts/build_core.sh [--release]
#
# Run this before `xcodegen`/`xcodebuild` whenever the Rust sources change.
# Cargo is deliberately *not* wired into an Xcode script phase: Xcode's script
# sandboxing (ENABLE_USER_SCRIPT_SANDBOXING) fights cargo's file access, and a
# sandbox escape hatch is worse than one explicit command.
#
# Simulator slice only (standing decision 3 in _plans/00-rust-core-overview.md).
# Adding the device slice later means one more `cargo build --target
# aarch64-apple-ios` and one more `-library` pair below.
#
# ## ONNX Runtime
#
# Since Phase 1, gallery-ffi depends on gallery-ml, which links ONNX Runtime
# through the `ort` crate. `ort-sys` downloads pyke's prebuilt *static*
# `libonnxruntime.a` at build time (~85 MB, cached under
# `~/Library/Caches/ort.pyke.io/`) and emits a `-L`/`-l` pair for it. Cargo
# does **not** fold external static libraries into a `staticlib` rlib output,
# so `libgallery_ffi.a` on its own is missing every ORT symbol and the failure
# only surfaces when Xcode links the app.
#
# This script therefore merges the two archives with `libtool -static` before
# assembling the xcframework. Merging (rather than shipping a second `-library`
# in the xcframework, or a bare `-L`/`-l` in project.yml) keeps the Xcode side
# exactly as it was: one framework dependency, no search paths pointing into a
# user-specific cache directory. The linker still pulls in only the archive
# members it needs, so the merged 85 MB does not become 85 MB of app.
#
# `project.yml` does carry the two link flags ORT asks for that an archive
# cannot express: `-lc++` and `-framework CoreML`.
#
# First build needs network access for that download. `ORT_LIB_LOCATION=<dir
# containing libonnxruntime.a>` is the offline escape hatch and is honoured
# both by `ort-sys` and by the merge step below — which validates whatever it
# is handed (arm64, iOS-simulator platform) rather than trusting it, since a
# macOS archive merged in here fails hundreds of lines into an Xcode link.

set -euo pipefail

readonly TARGET="aarch64-apple-ios-sim"
readonly LIB_NAME="libgallery_ffi.a"
readonly DYLIB_NAME="libgallery_ffi.dylib"
readonly MODULE="GalleryCore"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_DIR="$ROOT/core"
OUT_DIR="$ROOT/build/core"
HEADERS_DIR="$OUT_DIR/headers"
GENERATED_DIR="$OUT_DIR/Generated"
XCFRAMEWORK="$OUT_DIR/$MODULE.xcframework"

# `--profile dev` and `--profile release` name the same output directories
# cargo uses for the default builds ("debug" / "release").
PROFILE="debug"
CARGO_PROFILE="dev"
for arg in "$@"; do
    case "$arg" in
        --release) PROFILE="release"; CARGO_PROFILE="release" ;;
        # Everything from the shebang to the `set -e` is the doc comment.
        -h|--help) sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d'; exit 0 ;;
        *) echo "error: unknown argument '$arg' (expected --release)" >&2; exit 2 ;;
    esac
done

# Homebrew's rustup is keg-only, so cargo isn't on a default PATH.
if ! command -v cargo >/dev/null 2>&1; then
    export PATH="/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH"
fi
if ! command -v cargo >/dev/null 2>&1; then
    echo "error: cargo not found. Install rustup (brew install rustup) and" >&2
    echo "       add its bin dir to PATH." >&2
    exit 1
fi

echo "==> cargo build ($PROFILE, $TARGET)"
# Match the app's deployment target. The `cc` crate reads this when it builds
# rusqlite's bundled sqlite3; without it those objects are stamped with the
# host SDK's version and every app link emits "built for newer
# 'iOS-simulator' version". Keep in step with `project.yml`.
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-18.0}"
(cd "$CORE_DIR" && cargo build -p gallery-ffi --target "$TARGET" --profile "$CARGO_PROFILE")

BUILT_DIR="$CORE_DIR/target/$TARGET/$PROFILE"
STATIC_LIB="$BUILT_DIR/$LIB_NAME"
DYLIB="$BUILT_DIR/$DYLIB_NAME"
[[ -f "$STATIC_LIB" ]] || { echo "error: $STATIC_LIB missing after build" >&2; exit 1; }
[[ -f "$DYLIB" ]] || { echo "error: $DYLIB missing after build" >&2; exit 1; }

# --- merge libonnxruntime.a into the staticlib -----------------------------
#
# `ort-sys`'s build script records where it put (or found) the prebuilt
# archive in its cargo output log, as `-L native=<dir>`. Reading that is more
# robust than re-deriving pyke's cache layout, and it automatically follows
# ORT_LIB_LOCATION when the build was run offline.
#
# Two traps this used to fall into, both silent:
#
#   * Several `ort-sys-*` build directories accumulate across feature/profile
#     changes, and the first glob hit is not the freshest. We sort by mtime.
#   * A hand-set ORT_LIB_LOCATION (or a stale build dir) can point at a *macOS*
#     archive. Merging it produces an xcframework that links until the
#     simulator refuses the slice, hundreds of lines into an Xcode build log.
#     We check the architecture and the platform load command before merging.

# `libonnxruntime.a` must be arm64 *and* built for the iOS simulator. Every
# member carries an LC_BUILD_VERSION / LC_VERSION_MIN with the platform, so one
# object is enough to tell an iOS-simulator archive from a macOS one.
validate_ort_arch() {
    local lib="$1" archs platforms
    archs="$(lipo -info "$lib" 2>/dev/null || true)"
    case "$archs" in
        *arm64*) ;;
        *)
            echo "error: $lib is not arm64" >&2
            echo "       lipo says: ${archs:-<unreadable>}" >&2
            return 1 ;;
    esac
    # `otool -l` over the whole archive prints one load-command dump per
    # member; PLATFORM 7 is IOSSIMULATOR, 1 is MACOS.
    platforms="$(otool -l "$lib" 2>/dev/null | awk '/platform/ { print $2 }' | sort -u)"
    if [[ -n "$platforms" ]] && ! grep -qx '7\|IOSSIMULATOR' <<<"$platforms"; then
        echo "error: $lib is not built for the iOS simulator" >&2
        echo "       otool reports platform(s): $(tr '\n' ' ' <<<"$platforms")" >&2
        echo "       (7 / IOSSIMULATOR expected; 1 / MACOS means a host archive)" >&2
        return 1
    fi
    return 0
}

find_ort_lib() {
    if [[ -n "${ORT_LIB_LOCATION:-}" && -f "$ORT_LIB_LOCATION/libonnxruntime.a" ]]; then
        echo "$ORT_LIB_LOCATION/libonnxruntime.a"
        return 0
    fi
    local log dir
    # Newest build directory first: `ls -t` on the output logs, so a stale
    # ort-sys-* left over from an earlier feature set cannot win.
    while IFS= read -r log; do
        [[ -f "$log" ]] || continue
        while IFS= read -r dir; do
            [[ -f "$dir/libonnxruntime.a" ]] && { echo "$dir/libonnxruntime.a"; return 0; }
        done < <(sed -n 's/^cargo:rustc-link-search=native=//p' "$log")
    done < <(ls -t "$BUILT_DIR"/build/ort-sys-*/output 2>/dev/null)
    return 1
}

ORT_LIB="$(find_ort_lib || true)"
if [[ -z "$ORT_LIB" ]]; then
    echo "error: could not locate libonnxruntime.a for $TARGET." >&2
    echo "       ort-sys downloads it on the first build (needs network);" >&2
    echo "       set ORT_LIB_LOCATION=<dir with libonnxruntime.a> to build offline." >&2
    exit 1
fi
validate_ort_arch "$ORT_LIB" || {
    echo "       (${ORT_LIB_LOCATION:+ORT_LIB_LOCATION=$ORT_LIB_LOCATION; }target is $TARGET)" >&2
    exit 1
}

echo "==> merging $(basename "$ORT_LIB") into $LIB_NAME"
echo "    $ORT_LIB"
MERGED_LIB="$BUILT_DIR/libgallery_core_merged.a"
rm -f "$MERGED_LIB"
# `libtool -static` is the only Apple tool that merges archives while keeping
# every member's architecture and symbol table intact; `ar` on macOS mangles
# duplicate member names, which ORT's archive has plenty of.
#
# stderr is *not* suppressed. Two warning families are expected from ORT's
# archive and only those two are filtered — hiding the whole stream also hid
# the ones that matter (a table-of-contents failure, an object built for the
# wrong architecture), which is how a bad merge could reach Xcode unnoticed.
libtool -static -o "$MERGED_LIB" "$STATIC_LIB" "$ORT_LIB" 2> >(
    grep -Ev 'same member name|has no symbols' >&2
)
[[ -f "$MERGED_LIB" ]] || { echo "error: libtool produced no archive" >&2; exit 1; }
validate_ort_arch "$MERGED_LIB" || exit 1

# UniFFI reads the interface metadata straight out of the built library, so the
# bindings can never drift from the binary they describe.
#
# Note: *not* `--xcframework`. That flag emits `framework module GalleryCoreFFI`,
# which only resolves inside a real .framework bundle; a library-based
# xcframework exposes a plain Headers directory, so it needs a plain
# `module` declaration or `#if canImport(GalleryCoreFFI)` silently fails and the
# app fails to compile with "Cannot find type 'RustBuffer' in scope".
echo "==> uniffi-bindgen (swift)"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
(cd "$CORE_DIR" && cargo run --quiet -p uniffi-bindgen --bin uniffi-bindgen-swift -- \
    --swift-sources --headers --modulemap \
    --module-name "${MODULE}FFI" \
    --modulemap-filename module.modulemap \
    "$DYLIB" "$STAGING")

for expected in "$MODULE.swift" "${MODULE}FFI.h" "module.modulemap"; do
    [[ -f "$STAGING/$expected" ]] || {
        echo "error: uniffi-bindgen did not produce $expected" >&2
        ls -1 "$STAGING" >&2
        exit 1
    }
done

# Copy only on change: an unchanged GalleryCore.swift keeps Xcode from
# recompiling the whole app target on every core rebuild.
copy_if_changed() {
    local src="$1" dst="$2"
    if [[ ! -f "$dst" ]] || ! cmp -s "$src" "$dst"; then
        cp "$src" "$dst"
        echo "    updated $(basename "$dst")"
    fi
}

mkdir -p "$HEADERS_DIR" "$GENERATED_DIR"
copy_if_changed "$STAGING/$MODULE.swift" "$GENERATED_DIR/$MODULE.swift"
copy_if_changed "$STAGING/${MODULE}FFI.h" "$HEADERS_DIR/${MODULE}FFI.h"
copy_if_changed "$STAGING/module.modulemap" "$HEADERS_DIR/module.modulemap"

echo "==> $MODULE.xcframework"
# -create-xcframework refuses to overwrite, so this is a clean rebuild every
# time. It is fast (a copy) compared to the cargo build above.
rm -rf "$XCFRAMEWORK"
xcodebuild -create-xcframework \
    -library "$MERGED_LIB" -headers "$HEADERS_DIR" \
    -output "$XCFRAMEWORK" >/dev/null

echo
echo "core:      $(du -h "$STATIC_LIB" | cut -f1)  $STATIC_LIB"
echo "+onnxrt:   $(du -h "$MERGED_LIB" | cut -f1)  $MERGED_LIB"
echo "framework: $XCFRAMEWORK"
echo "bindings:  $GENERATED_DIR/$MODULE.swift"
echo
echo "Next: xcodegen && xcodebuild ..."
