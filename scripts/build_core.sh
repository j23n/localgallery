#!/usr/bin/env bash
#
# Build the Rust core and assemble everything Xcode needs:
#
#   build/core/GalleryCore.xcframework     static lib (no clang module)
#   build/core/headers/GalleryCoreFFI.h    C FFI, via the app bridging header
#   build/core/Generated/GalleryCore.swift UniFFI Swift, compiled into the app
#
# Usage:
#   ./scripts/build_core.sh [--release] [--sdk iphoneos|iphonesimulator|all]
#
# Xcode's LocalGallery target runs this as a pre-build script. Inside Xcode
# it reads CONFIGURATION (Release → --release) and PLATFORM_NAME (so a
# simulator build does not also compile the device slice). User Script
# Sandboxing is off on the project: cargo needs ~/.cargo, rustup, core/target,
# and the ORT download cache.
#
# From the CLI, both slices are built so the xcframework can switch
# destinations without a rebuild.
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
# is handed (arm64, matching iOS / iOS-simulator platform) rather than trusting
# it, since a macOS archive merged in here fails hundreds of lines into an
# Xcode link. When building both slices, prefer letting ort-sys pick the
# per-target cache entry over a single ORT_LIB_LOCATION.

set -euo pipefail

readonly DEVICE_TARGET="aarch64-apple-ios"
readonly SIM_TARGET="aarch64-apple-ios-sim"
readonly LIB_NAME="libgallery_ffi.a"
readonly DYLIB_NAME="libgallery_ffi.dylib"
readonly MODULE="GalleryCore"
# LC_BUILD_VERSION platform ids (otool prints the numeric form).
readonly PLATFORM_IOS=2
readonly PLATFORM_IOSSIMULATOR=7

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
SDK="all"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --release) PROFILE="release"; CARGO_PROFILE="release"; shift ;;
        --sdk)
            SDK="${2:?--sdk requires iphoneos, iphonesimulator, or all}"
            shift 2
            ;;
        --sdk=*)
            SDK="${1#--sdk=}"
            shift
            ;;
        # Everything from the shebang to the `set -e` is the doc comment.
        -h|--help) sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d'; exit 0 ;;
        *) echo "error: unknown argument '$1' (expected --release or --sdk)" >&2; exit 2 ;;
    esac
done

# Inside Xcode, match the destination and configuration so a Debug simulator
# run is not also a device Release compile.
if [[ -n "${XCODE_VERSION_ACTUAL:-}" ]]; then
    if [[ "$PROFILE" == "debug" && "${CONFIGURATION:-}" == "Release" ]]; then
        PROFILE="release"
        CARGO_PROFILE="release"
    fi
    if [[ "$SDK" == "all" ]]; then
        case "${PLATFORM_NAME:-}" in
            iphoneos) SDK="iphoneos" ;;
            iphonesimulator) SDK="iphonesimulator" ;;
        esac
    fi
fi

case "$SDK" in
    all|iphoneos|iphonesimulator) ;;
    *) echo "error: --sdk must be iphoneos, iphonesimulator, or all (got $SDK)" >&2; exit 2 ;;
esac

BUILD_DEVICE=0
BUILD_SIM=0
if [[ "$SDK" == "all" || "$SDK" == "iphoneos" ]]; then
    BUILD_DEVICE=1
fi
if [[ "$SDK" == "all" || "$SDK" == "iphonesimulator" ]]; then
    BUILD_SIM=1
fi

# Homebrew's rustup is keg-only, so cargo isn't on a default PATH.
# Xcode's script PATH is also too thin for cargo.
if ! command -v cargo >/dev/null 2>&1; then
    export PATH="/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH"
fi
if ! command -v cargo >/dev/null 2>&1; then
    echo "error: cargo not found. Install rustup (brew install rustup) and" >&2
    echo "       add its bin dir to PATH." >&2
    exit 1
fi

# Match the app's deployment target. The `cc` crate reads this when it builds
# rusqlite's bundled sqlite3; without it those objects are stamped with the
# host SDK's version and every app link emits "built for newer
# 'iOS-simulator' version". Keep in step with `project.yml`.
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-18.0}"

# `libonnxruntime.a` must be arm64 *and* built for the requested Apple
# platform. Every member carries an LC_BUILD_VERSION / LC_VERSION_MIN with the
# platform, so one object is enough to tell an iOS archive from a macOS one.
validate_ort_arch() {
    local lib="$1" expected_platform="$2" expected_name="$3" archs platforms
    archs="$(lipo -info "$lib" 2>/dev/null || true)"
    case "$archs" in
        *arm64*) ;;
        *)
            echo "error: $lib is not arm64" >&2
            echo "       lipo says: ${archs:-<unreadable>}" >&2
            return 1 ;;
    esac
    # `otool -l` over the whole archive prints one load-command dump per
    # member; PLATFORM 2 is IOS, 7 is IOSSIMULATOR, 1 is MACOS.
    platforms="$(otool -l "$lib" 2>/dev/null | awk '/platform/ { print $2 }' | sort -u)"
    if [[ -n "$platforms" ]] && ! grep -qx "$expected_platform\|$expected_name" <<<"$platforms"; then
        echo "error: $lib is not built for $expected_name" >&2
        echo "       otool reports platform(s): $(tr '\n' ' ' <<<"$platforms")" >&2
        echo "       ($expected_platform / $expected_name expected; 1 / MACOS means a host archive)" >&2
        return 1
    fi
    return 0
}

find_ort_lib() {
    local built_dir="$1"
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
    done < <(ls -t "$built_dir"/build/ort-sys-*/output 2>/dev/null)
    return 1
}

# UniFFI C symbol names (no leading `_`). Bindgen reads the *dylib*;
# Xcode links the *staticlib*. The staticlib is allowed to have extra
# names (it is an archive of every .o); what must not happen is the
# dylib advertising a function the .a does not define.
uniffi_syms() {
    # `-j` is Apple nm: names only, so archive member headers cannot
    # leak into the list. Fall back to the last field if `-j` is absent.
    local names
    names="$(nm -gU -j "$1" 2>/dev/null || nm -gU "$1" 2>/dev/null | awk '{ print $NF }')"
    printf '%s\n' "$names" \
        | grep -E '^_?uniffi_gallery_ffi_(fn|checksum)_' \
        | sed 's/^_//' \
        | sort -u
}

assert_staticlib_has_dylib_uniffi() {
    local static_lib="$1" dylib="$2"
    local dylib_syms static_syms missing
    dylib_syms="$(uniffi_syms "$dylib")"
    static_syms="$(uniffi_syms "$static_lib")"
    if [[ -z "$dylib_syms" ]]; then
        echo "error: $dylib has no UniFFI exports" >&2
        return 1
    fi
    if [[ -z "$static_syms" ]]; then
        echo "warning: could not read UniFFI symbols from $static_lib (nm); continuing" >&2
        return 0
    fi
    missing="$(comm -23 <(printf '%s\n' "$dylib_syms") <(printf '%s\n' "$static_syms"))"
    if [[ -n "$missing" ]]; then
        echo "error: staticlib is missing UniFFI symbols the dylib exported:" >&2
        echo "$missing" | sed 's/^/       /' >&2
        echo "       staticlib: $static_lib" >&2
        echo "       dylib:     $dylib" >&2
        return 1
    fi
    return 0
}

# Build one Rust target and merge its ORT archive. Sets MERGED_LIB to the
# resulting archive path. (Avoid `$(build_and_merge …)` — bash suppresses
# `set -e` inside command substitutions, so a failed cargo would race ahead.)
build_and_merge() {
    local target="$1" expected_platform="$2" expected_name="$3"
    local built_dir static_lib ort_lib

    built_dir="$CORE_DIR/target/$target/$PROFILE"
    # Force both crate-types to relink. cargo incremental has been seen to
    # refresh the cdylib (so bindgen emits new Swift) and keep yesterday's
    # staticlib (so the xcframework is missing those C symbols).
    rm -f "$built_dir/$LIB_NAME" "$built_dir/$DYLIB_NAME"

    echo "==> cargo build ($PROFILE, $target)"
    (cd "$CORE_DIR" && cargo build --locked -p gallery-ffi --target "$target" --profile "$CARGO_PROFILE")

    static_lib="$built_dir/$LIB_NAME"
    [[ -f "$static_lib" ]] || { echo "error: $static_lib missing after build" >&2; exit 1; }
    [[ -f "$built_dir/$DYLIB_NAME" ]] || {
        echo "error: $built_dir/$DYLIB_NAME missing after build" >&2
        exit 1
    }
    if ! assert_staticlib_has_dylib_uniffi "$static_lib" "$built_dir/$DYLIB_NAME"; then
        echo "==> cargo clean -p gallery-ffi ($target) and rebuild"
        (cd "$CORE_DIR" && cargo clean -p gallery-ffi --target "$target")
        (cd "$CORE_DIR" && cargo build --locked -p gallery-ffi --target "$target" --profile "$CARGO_PROFILE")
        assert_staticlib_has_dylib_uniffi "$static_lib" "$built_dir/$DYLIB_NAME" || exit 1
    fi

    ort_lib="$(find_ort_lib "$built_dir" || true)"
    if [[ -z "$ort_lib" ]]; then
        echo "error: could not locate libonnxruntime.a for $target." >&2
        echo "       ort-sys downloads it on the first build (needs network);" >&2
        echo "       set ORT_LIB_LOCATION=<dir with libonnxruntime.a> to build offline." >&2
        exit 1
    fi
    validate_ort_arch "$ort_lib" "$expected_platform" "$expected_name" || {
        echo "       (${ORT_LIB_LOCATION:+ORT_LIB_LOCATION=$ORT_LIB_LOCATION; }target is $target)" >&2
        exit 1
    }

    echo "==> merging $(basename "$ort_lib") into $LIB_NAME ($target)"
    echo "    $ort_lib"
    MERGED_LIB="$built_dir/libgallery_core_merged.a"
    rm -f "$MERGED_LIB"
    # `libtool -static` is the only Apple tool that merges archives while keeping
    # every member's architecture and symbol table intact; `ar` on macOS mangles
    # duplicate member names, which ORT's archive has plenty of.
    #
    # stderr is *not* suppressed. Two warning families are expected from ORT's
    # archive and only those two are filtered — hiding the whole stream also hid
    # the ones that matter (a table-of-contents failure, an object built for the
    # wrong architecture), which is how a bad merge could reach Xcode unnoticed.
    libtool -static -o "$MERGED_LIB" "$static_lib" "$ort_lib" 2> >(
        grep -Ev 'same member name|has no symbols' >&2
    )
    [[ -f "$MERGED_LIB" ]] || { echo "error: libtool produced no archive" >&2; exit 1; }
    validate_ort_arch "$MERGED_LIB" "$expected_platform" "$expected_name" || exit 1

    echo "core:      $(du -h "$static_lib" | cut -f1)  $static_lib"
    echo "+onnxrt:   $(du -h "$MERGED_LIB" | cut -f1)  $MERGED_LIB"
}

DEVICE_MERGED=""
SIM_MERGED=""
if [[ "$BUILD_DEVICE" -eq 1 ]]; then
    build_and_merge "$DEVICE_TARGET" "$PLATFORM_IOS" "IOS"
    DEVICE_MERGED="$MERGED_LIB"
fi
if [[ "$BUILD_SIM" -eq 1 ]]; then
    build_and_merge "$SIM_TARGET" "$PLATFORM_IOSSIMULATOR" "IOSSIMULATOR"
    SIM_MERGED="$MERGED_LIB"
fi

# UniFFI reads the interface metadata out of the dylib this run produced.
# Swift must not `import GalleryCoreFFI` from the xcframework: Xcode caches
# that clang module and a device-only (or sim-only) rebuild leaves the
# other slice's *old* header in DerivedData. New GalleryCore.swift then
# calls `uniffi_…_heicdecoder` symbols the cached module does not declare.
# C decls come from the bridging header instead (the .h this run wrote).
echo "==> uniffi-bindgen (swift)"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
SIM_DYLIB="$CORE_DIR/target/$SIM_TARGET/$PROFILE/$DYLIB_NAME"
DEVICE_DYLIB="$CORE_DIR/target/$DEVICE_TARGET/$PROFILE/$DYLIB_NAME"
# Use a dylib this run just produced. Preferring whichever sim slice
# happens to exist is how a device-only Xcode build links a new
# xcframework against Swift bindings generated from yesterday's sim
# dylib — UniFFI then fatalErrors on API checksum mismatch.
BINDGEN_DYLIB=""
if [[ "$BUILD_SIM" -eq 1 && -f "$SIM_DYLIB" ]]; then
    BINDGEN_DYLIB="$SIM_DYLIB"
elif [[ "$BUILD_DEVICE" -eq 1 && -f "$DEVICE_DYLIB" ]]; then
    BINDGEN_DYLIB="$DEVICE_DYLIB"
fi
if [[ -z "$BINDGEN_DYLIB" ]]; then
    echo "error: no gallery-ffi dylib from this build to run uniffi-bindgen against" >&2
    exit 1
fi
echo "    bindgen library: $BINDGEN_DYLIB"
(cd "$CORE_DIR" && cargo run --locked --quiet -p uniffi-bindgen --bin uniffi-bindgen-swift -- \
    --swift-sources --headers --modulemap \
    --module-name "${MODULE}FFI" \
    --modulemap-filename module.modulemap \
    "$BINDGEN_DYLIB" "$STAGING")

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

# Drop `#if canImport(GalleryCoreFFI) / import GalleryCoreFFI`. Those C
# types come from LocalGallery/GalleryCore-Bridging-Header.h instead.
strip_gallerycore_ffi_import() {
    python3 -c '
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
text = p.read_text()
patched, n = re.subn(
    r"\n#if canImport\(GalleryCoreFFI\)\nimport GalleryCoreFFI\n#endif\n",
    "\n",
    text,
    count=1,
)
if n:
    p.write_text(patched)
' "$1"
}

mkdir -p "$HEADERS_DIR" "$GENERATED_DIR"
copy_if_changed "$STAGING/$MODULE.swift" "$GENERATED_DIR/$MODULE.swift"
strip_gallerycore_ffi_import "$GENERATED_DIR/$MODULE.swift"
copy_if_changed "$STAGING/${MODULE}FFI.h" "$HEADERS_DIR/${MODULE}FFI.h"
# Do not install a clang module named GalleryCoreFFI. Xcode caches it.
rm -f "$HEADERS_DIR/module.modulemap"
APP_BINDINGS="$ROOT/LocalGallery/$MODULE.swift"
if [[ -e "$APP_BINDINGS" ]]; then
    copy_if_changed "$GENERATED_DIR/$MODULE.swift" "$APP_BINDINGS"
fi
if [[ -n "${MODULE_CACHE_DIR:-}" ]]; then
    rm -rf "$MODULE_CACHE_DIR"/GalleryCoreFFI-* 2>/dev/null || true
fi

echo "==> $MODULE.xcframework"
# Library only — headers are the bridging header, not a GalleryCoreFFI module.
rm -rf "$XCFRAMEWORK"
XC_ARGS=()
if [[ -n "$DEVICE_MERGED" ]]; then
    XC_ARGS+=(-library "$DEVICE_MERGED")
fi
if [[ -n "$SIM_MERGED" ]]; then
    XC_ARGS+=(-library "$SIM_MERGED")
fi
xcodebuild -create-xcframework \
    "${XC_ARGS[@]}" \
    -output "$XCFRAMEWORK" >/dev/null

echo
echo "framework: $XCFRAMEWORK"
echo "bindings:  $GENERATED_DIR/$MODULE.swift"
if [[ -z "${XCODE_VERSION_ACTUAL:-}" ]]; then
    echo
    echo "Next: xcodegen && xcodebuild ..."
fi
