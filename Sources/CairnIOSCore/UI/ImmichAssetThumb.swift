import SwiftUI
import CairnCore

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Environment plumbing

/// Environment key that carries the (optional) live `ImmichThumbnailLoader`
/// into any `ImmichAssetThumb` subtree. Screens never construct the loader
/// themselves — `AppDependencies` wires it to the root via
/// `.environment(\.immichThumbnailLoader, ...)` once credentials are
/// available. When the value is `nil` (pre-onboarding, or when running
/// under SwiftUI previews without a host), every `ImmichAssetThumb`
/// silently falls back to the gradient placeholder.
private struct ImmichThumbnailLoaderKey: EnvironmentKey {
    static let defaultValue: ImmichThumbnailLoader? = nil
}

private struct ThumbnailStoreKey: EnvironmentKey {
    static let defaultValue: SwiftDataThumbnailStore? = nil
}

public extension EnvironmentValues {
    var immichThumbnailLoader: ImmichThumbnailLoader? {
        get { self[ImmichThumbnailLoaderKey.self] }
        set { self[ImmichThumbnailLoaderKey.self] = newValue }
    }

    var thumbnailStore: SwiftDataThumbnailStore? {
        get { self[ThumbnailStoreKey.self] }
        set { self[ThumbnailStoreKey.self] = newValue }
    }
}

// MARK: - View

/// Drop-in replacement for `MockAssetThumb` that renders the real Immich
/// thumbnail when both (a) a non-nil `assetId` is available and (b) a
/// live `ImmichThumbnailLoader` is in the environment. Otherwise (loading,
/// error, or missing plumbing) it falls back to the deterministic gradient
/// tile — same algorithm as `MockAssetThumb` so the UI never flashes
/// blank and cold-start perception stays identical.
///
/// Live-pair badge sits on top regardless of loading state — that's
/// metadata about the asset, not the image itself.
public struct ImmichAssetThumb: View {
    public let assetId: String?
    public let filename: String
    public let size: CGFloat
    public let isLivePair: Bool

    @State private var imageData: Data?
    @Environment(\.immichThumbnailLoader) private var loader
    @Environment(\.thumbnailStore) private var store
    @Environment(\.cairnTokens) private var t

    public init(
        assetId: String?,
        filename: String,
        size: CGFloat = 76,
        isLivePair: Bool = false
    ) {
        self.assetId = assetId
        self.filename = filename
        self.size = size
        self.isLivePair = isLivePair
    }

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            content
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            if isLivePair {
                Image(systemName: "livephoto")
                    .font(.cairnScaled(size: max(10, size * 0.18), weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(.black.opacity(0.45), in: Circle())
                    .padding(4)
            }
        }
        .accessibilityHidden(true)
        // `.task(id:)` restarts when `assetId` changes — lets a single
        // view cell be reused across different assets (list virtualization)
        // without carrying stale bytes from the previous row's asset.
        .task(id: assetId) {
            guard let assetId else {
                imageData = nil
                return
            }
            // Fixture-prefixed assetIds resolve against bundled JPEGs in
            // `Resources/FixturePhotos`. Used by screenshot fixtures and
            // the App Store review-mode seed so the reviewer / pipeline
            // sees real photos rather than gradient placeholders. The
            // bundle lookup is synchronous and never hits the network,
            // so it short-circuits the loader/cache/thumbhash chain.
            if let data = Self.bundledFixtureData(for: assetId) {
                imageData = data
                return
            }
            if let loader {
                do {
                    let data = try await loader.load(assetId: assetId)
                    guard !Task.isCancelled else { return }
                    imageData = data
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                }
            }
            if let store, let cached = try? await store.thumbnail(for: assetId) {
                guard !Task.isCancelled else { return }
                imageData = cached
                return
            }
            if let store, let hash = try? await store.thumbhash(for: assetId), let decoded = ThumbHashDecoder.decode(hash) {
                guard !Task.isCancelled else { return }
                imageData = decoded
                return
            }
            imageData = nil
        }
    }

    @ViewBuilder
    private var content: some View {
        #if canImport(UIKit)
        if let data = imageData, let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            placeholder
        }
        #else
        placeholder
        #endif
    }

    // Gradient placeholder — identical to `MockAssetThumb`. Keep both
    // visually indistinguishable so a thumbnail that hasn't loaded yet
    // doesn't flash a different style than an asset that's missing an
    // `assetId` entirely.
    private var placeholder: some View {
        LinearGradient(
            colors: [color1, color2],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var hue: Double {
        var h: UInt64 = 1_469_598_103_934_665_603
        for byte in filename.utf8 {
            h ^= UInt64(byte)
            h &*= 1_099_511_628_211
        }
        return Double(h % 360) / 360.0
    }

    private var color1: Color { Color(hue: hue, saturation: 0.30, brightness: 0.85) }
    private var color2: Color { Color(hue: hue, saturation: 0.55, brightness: 0.55) }

    /// Look up a fixture-prefixed assetId against bundled JPEGs.
    /// `fixture-demo-photo-01` → `Bundle.module/demo-photo-01.jpg`.
    /// Returns `nil` for non-fixture ids or when the resource is
    /// missing (e.g., a fixture name was renamed without copying a
    /// matching JPEG into `Resources/FixturePhotos`).
    private static func bundledFixtureData(for assetId: String) -> Data? {
        let prefix = "fixture-"
        guard assetId.hasPrefix(prefix) else { return nil }
        let resource = String(assetId.dropFirst(prefix.count))
        guard let url = Bundle.module.url(forResource: resource, withExtension: "jpg") else {
            return nil
        }
        return try? Data(contentsOf: url)
    }
}

// MARK: - Preview

#if DEBUG
#Preview("ImmichAssetThumb — no loader (gradient fallback)") {
    HStack(spacing: 12) {
        ImmichAssetThumb(assetId: nil, filename: "IMG_4821.HEIC", size: 76, isLivePair: false)
        ImmichAssetThumb(assetId: nil, filename: "IMG_4819.HEIC", size: 76, isLivePair: true)
        ImmichAssetThumb(assetId: nil, filename: "IMG_4612.MP4", size: 76, isLivePair: false)
    }
    .padding()
    .cairnTheme()
}
#endif
