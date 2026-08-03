// Swift-specific generator: unlike `uniffi-bindgen generate --language swift`
// it can emit the header / modulemap / sources selectively and produce an
// XCFramework-shaped modulemap. `scripts/build_core.sh` uses this one.
fn main() {
    uniffi::uniffi_bindgen_swift()
}
