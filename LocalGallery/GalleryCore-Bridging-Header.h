// C FFI for the Rust core. `scripts/build_core.sh` writes the header in
// the same run as `GalleryCore.swift`. A bridging header (not the
// xcframework's GalleryCoreFFI clang module) is what Swift compiles
// against, so a stale DerivedData module cannot hide new symbols.
#include "../build/core/headers/GalleryCoreFFI.h"
