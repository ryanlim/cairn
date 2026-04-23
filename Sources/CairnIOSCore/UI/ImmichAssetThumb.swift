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

public extension EnvironmentValues {
    var immichThumbnailLoader: ImmichThumbnailLoader? {
        get { self[ImmichThumbnailLoaderKey.self] }
        set { self[ImmichThumbnailLoaderKey.self] = newValue }
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
                    .font(.system(size: max(10, size * 0.18), weight: .semibold))
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
            guard let assetId, let loader else {
                imageData = nil
                return
            }
            do {
                let data = try await loader.load(assetId: assetId)
                // Silent no-op if the view has been reassigned to a
                // different asset while the request was in flight —
                // `.task(id:)` has already cancelled this task and will
                // relaunch for the new id, but we also guard to avoid
                // rendering stale bytes.
                guard !Task.isCancelled else { return }
                imageData = data
            } catch {
                // Silent fallback to gradient. We deliberately don't
                // surface a broken-image indicator — the gradient reads
                // as "unknown content" which is accurate pre-auth or
                // during transient failures. Real monitoring should live
                // in logs, not the UI.
                imageData = nil
            }
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
