import Testing
import CairnCore
@testable import CairnIOSCore

#if canImport(Photos)
import Photos

/// Tests for `PhotoKitPhotoEnumerator`.
///
/// Why this suite is structural-only:
/// PhotoKit requires a running Photos library — a real device or an iOS
/// simulator with seeded photos. `swift test` on macOS runs against the
/// macOS Photos library, but CI and most contributors don't have a
/// curated library to assert against. Full integration coverage will land
/// when the iOS app target exists; until then we pin the type's existence
/// and conformance, plus the pure resource-selection helper.
///
/// **Manual test plan (run on a device once the iOS app target lands):**
///   1. Grant Full Library Access to the host app.
///   2. Seed the device with a known mix: regular photo, edited photo,
///      regular video, Live Photo, edited Live Photo.
///   3. Call `PhotoKitPhotoEnumerator().currentChecksums()`.
///   4. Expected: count == regular photos + videos + (2 * Live Photos).
///   5. Verify each Live Photo contributes exactly two checksums by
///      comparing against `shasum -a 1 -b` on the `PHAssetResource` bytes
///      exported via `PHAssetResourceManager.writeData(for:toFile:...)`.
///   6. Delete one Live Photo from Photos.app, empty Recently Deleted,
///      re-run: the set should shrink by exactly two checksums.
@Suite("PhotoKitPhotoEnumerator")
struct PhotoKitPhotoEnumeratorTests {

    @Test("type conforms to PhotoEnumerator and instantiates")
    func conformsToProtocol() {
        let enumerator = PhotoKitPhotoEnumerator()
        #expect((enumerator as Any) is any PhotoEnumerator)
    }

    @Test("selectResourcesToHash returns empty for empty input")
    func selectionEmpty() {
        let picked = PhotoKitPhotoEnumerator.selectResourcesToHash(from: [])
        #expect(picked.isEmpty)
    }

    // We can't construct `PHAssetResource` instances by hand (no public
    // initializer), so the deeper unit tests for `selectResourcesToHash`
    // would need either a runtime-loaded fixture library or an internal
    // protocol seam. For now the priority-ordering logic is documented in
    // the function's doc comment and pinned by code review; introducing a
    // protocol abstraction over `PHAssetResource` would leak into Core's
    // surface for marginal test value. Revisit if the selection logic
    // grows.
}

#endif
