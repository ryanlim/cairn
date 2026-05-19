import Foundation

/// Finds server assets that look like prior iPhone uploads cairn never
/// observed locally and that aren't currently alive on the device.
///
/// This is the third deletion-detection layer, sibling to
/// `OrphanReconciler`. The split:
///
///   - Standard reconciliation: SHA1 was observed; asset is gone from
///     PhotoKit; trust the diff.
///   - `OrphanReconciler`: SHA1 was never hashed but the localIdentifier
///     was observed (filename + creationDate cached in
///     `LocalAssetMetadataStore`); match by metadata.
///   - `MissedDeletionFinder` (this type): cairn never observed the
///     asset at all (no SHA1, no metadata) because cairn wasn't running
///     between upload and delete. Filename + creationDate matched
///     against the server, then suppressed against the live local
///     library so we don't flag legitimately-kept photos.
///
/// The third layer is a manual "Find missed deletions" action surfaced
/// in Settings → Recovery rather than auto-running, because it's the
/// least precise signal: filename collisions across phone resets,
/// restored libraries, etc. could match against a real keep. The user
/// reviews candidates one at a time before trashing.
public enum MissedDeletionFinder {

    /// Identify server assets that:
    ///   - are not trashed
    ///   - have timeline visibility (implied by caller's query — we don't
    ///     re-check, we just trust the input)
    ///   - have a `fileCreatedAt` within the configured window
    ///   - have an `originalFileName` matching the iPhone-photo pattern
    ///     (camera-roll `IMG_NNNN`, edited `IMG_ENNNN`, optional burst
    ///     suffix, HEIC/HEIF/JPG/JPEG/PNG/MOV/MP4)
    ///   - whose checksum is NOT in `observed` (cairn never hashed it)
    ///   - whose checksum is NOT in `excluded` (user already said keep)
    ///   - whose filename is NOT present in `liveLocalFilenames`
    ///     (something with this name still lives on the phone — could be
    ///     the same photo via a stale cache, could be a sequence reroll;
    ///     either way, too ambiguous to auto-flag)
    ///
    /// **Known false-positive class**: server assets uploaded from a
    /// non-iPhone source (Immich web upload, scanner, another phone)
    /// that happen to carry iPhone-style filenames will pass this
    /// filter. Without a public iOS API for "Recently Deleted"
    /// metadata, there's no way to confirm a candidate was ever on
    /// this device. The `minCreatedAt` / `maxCreatedAt` parameters let
    /// the user manually constrain the window to a deletion-event
    /// timeframe they know about, which is the practical mitigation
    /// for this flow.
    ///
    /// `minCreatedAt` and `maxCreatedAt` bound `fileCreatedAt` — both
    /// inclusive. `nil` for either side disables that bound; if both
    /// are nil the legacy `daysWindow` lookback applies. UI surfaces
    /// these as date pickers above the result list.
    ///
    /// Returns matches ordered newest-first by `fileCreatedAt` so the UI
    /// can surface the most recent missed deletions first.
    public static func find(
        serverAssets: [ServerAsset],
        observed: Set<Checksum>,
        excluded: Set<Checksum>,
        liveLocalFilenames: Set<String>,
        minCreatedAt: Date? = nil,
        maxCreatedAt: Date? = nil,
        confirmedDeletedFilenames: Set<String>? = nil,
        now: Date = Date(),
        daysWindow: Int = 365
    ) -> [ServerAsset] {
        let liveNamesLower = Set(liveLocalFilenames.map { $0.lowercased() })
        // Confirmed-deleted set: compare on basename (extension
        // stripped) because PHPickerResult.suggestedName isn't
        // guaranteed to include the extension across iOS versions,
        // while Immich's `originalFileName` does. Comparing
        // basenames sidesteps the variance and also catches Live
        // Photo pairs (IMG_4391.HEIC + IMG_4391.MOV) when the user
        // picked one — both share basename "img_4391".
        let confirmedBases = confirmedDeletedFilenames.map {
            Set($0.map { Self.basename($0).lowercased() })
        }

        // High-confidence mode: caller supplies a positive-evidence
        // set of filenames. The iPhone filename grammar gets skipped
        // (a screenshot in the set is valid evidence). The user-set
        // date bounds still apply — they're independent filters.
        let useConfirmedMode = confirmedBases != nil
        let explicitBoundsSet = (minCreatedAt != nil) || (maxCreatedAt != nil)

        // Resolve date bounds. Explicit min/max always apply. The
        // daysWindow fallback only kicks in when no explicit bound
        // was set AND we're in auto-scan mode (confirmed mode trusts
        // the user's evidence as the natural bound).
        let lowerBound: Date?
        let upperBound: Date?
        if explicitBoundsSet {
            lowerBound = minCreatedAt
            upperBound = maxCreatedAt
        } else if !useConfirmedMode && daysWindow > 0 {
            lowerBound = now.addingTimeInterval(-Double(daysWindow) * 86_400)
            upperBound = nil
        } else if !useConfirmedMode {
            // Auto-scan mode with no bounds and daysWindow disabled
            // — paranoid default, return nothing rather than scanning
            // the whole server history.
            return []
        } else {
            lowerBound = nil
            upperBound = nil
        }

        var out: [ServerAsset] = []
        out.reserveCapacity(min(serverAssets.count, 32))

        for asset in serverAssets {
            guard !asset.isTrashed,
                  !observed.contains(asset.checksum),
                  !excluded.contains(asset.checksum),
                  let name = asset.originalFileName
            else { continue }
            let nameLower = name.lowercased()
            guard !liveNamesLower.contains(nameLower) else { continue }

            if let confirmedBases {
                // Precise mode: server asset's basename must appear
                // in the user's picked set. Skip the filename-pattern
                // grammar entirely (a PNG screenshot in cairn's
                // historical metadata is valid evidence even though
                // it doesn't match the iPhone IMG_NNNN form).
                guard confirmedBases.contains(Self.basename(nameLower)) else { continue }
            } else {
                // Auto-scan mode: enforce filename grammar.
                guard isIPhonePhotoFilename(name) else { continue }
            }

            // Date bounds apply uniformly. When any bound is set
            // (explicit min/max or daysWindow fallback), the asset
            // must have a valid fileCreatedAt within the window.
            // Missing date → can't evaluate → skip. Confirmed mode
            // with NO bounds skips this entirely (user's evidence is
            // the bound).
            if lowerBound != nil || upperBound != nil {
                guard let createdAt = asset.fileCreatedAt else { continue }
                if let lowerBound, createdAt < lowerBound { continue }
                if let upperBound, createdAt > upperBound { continue }
            }
            out.append(asset)
        }

        out.sort { ($0.fileCreatedAt ?? .distantPast) > ($1.fileCreatedAt ?? .distantPast) }
        return out
    }

    /// Strip the last `.ext` segment from a filename. Used to match
    /// across PHPickerResult.suggestedName (often extensionless) and
    /// Immich's `originalFileName` (always with extension), and to
    /// collapse Live Photo pairs into a single basename match.
    /// `"IMG_4391.HEIC"` → `"IMG_4391"`, `"IMG_4391"` → `"IMG_4391"`,
    /// `"my.long.name.JPG"` → `"my.long.name"`.
    static func basename(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
        return String(name[..<dot])
    }

    /// Case-insensitive match against the camera-roll filename grammar.
    /// Accepted: `IMG_4391.HEIC`, `IMG_E4391.JPG`, `IMG_4391_1.MOV`
    /// (burst). Rejected: anything else (`PXL_*.jpg` from a Pixel,
    /// renamed `vacation.jpg`, scanned PDFs, etc.).
    static func isIPhonePhotoFilename(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        return name.range(
            of: #"^IMG_E?\d+(_\d+)?\.(HEIC|HEIF|JPG|JPEG|PNG|MOV|MP4)$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }
}
