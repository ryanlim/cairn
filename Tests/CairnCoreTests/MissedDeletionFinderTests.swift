import Foundation
import Testing
@testable import CairnCore

@Suite("MissedDeletionFinder")
struct MissedDeletionFinderTests {

    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    private func server(
        _ id: String,
        checksum: String = "AAA",
        filename: String? = "IMG_4391.HEIC",
        createdDaysAgo: Double = 30,
        isTrashed: Bool = false
    ) -> ServerAsset {
        ServerAsset(
            id: id,
            checksum: Checksum(base64: checksum),
            isTrashed: isTrashed,
            originalFileName: filename,
            fileCreatedAt: now.addingTimeInterval(-createdDaysAgo * 86_400)
        )
    }

    @Test("empty inputs → no candidates")
    func emptyInputs() {
        let result = MissedDeletionFinder.find(
            serverAssets: [],
            observed: [],
            excluded: [],
            liveLocalFilenames: [],
            now: now
        )
        #expect(result.isEmpty)
    }

    @Test("unobserved iPhone-pattern asset → candidate")
    func basicMatch() {
        let result = MissedDeletionFinder.find(
            serverAssets: [server("s1")],
            observed: [],
            excluded: [],
            liveLocalFilenames: [],
            now: now
        )
        #expect(result.map(\.id) == ["s1"])
    }

    @Test("observed checksum → not a candidate")
    func observedSuppression() {
        let asset = server("s1", checksum: "OBS")
        let result = MissedDeletionFinder.find(
            serverAssets: [asset],
            observed: [Checksum(base64: "OBS")],
            excluded: [],
            liveLocalFilenames: [],
            now: now
        )
        #expect(result.isEmpty)
    }

    @Test("excluded checksum → not a candidate")
    func excludedSuppression() {
        let asset = server("s1", checksum: "EX")
        let result = MissedDeletionFinder.find(
            serverAssets: [asset],
            observed: [],
            excluded: [Checksum(base64: "EX")],
            liveLocalFilenames: [],
            now: now
        )
        #expect(result.isEmpty)
    }

    @Test("trashed server asset → not a candidate")
    func trashedSuppression() {
        let result = MissedDeletionFinder.find(
            serverAssets: [server("s1", isTrashed: true)],
            observed: [],
            excluded: [],
            liveLocalFilenames: [],
            now: now
        )
        #expect(result.isEmpty)
    }

    @Test("filename still alive locally → not a candidate")
    func liveFilenameSuppression() {
        let result = MissedDeletionFinder.find(
            serverAssets: [server("s1", filename: "IMG_4391.HEIC")],
            observed: [],
            excluded: [],
            liveLocalFilenames: ["IMG_4391.HEIC"],
            now: now
        )
        #expect(result.isEmpty)
    }

    @Test("live-filename match is case-insensitive")
    func liveFilenameCaseInsensitive() {
        let result = MissedDeletionFinder.find(
            serverAssets: [server("s1", filename: "img_4391.heic")],
            observed: [],
            excluded: [],
            liveLocalFilenames: ["IMG_4391.HEIC"],
            now: now
        )
        #expect(result.isEmpty)
    }

    @Test("non-iPhone filename → not a candidate")
    func filenameGrammar() {
        let assets = [
            server("ok", filename: "IMG_4391.HEIC"),
            server("ok2", filename: "IMG_E4391.JPG"),
            server("ok3", filename: "IMG_4391_1.MOV"),
            server("no1", filename: "PXL_20251215_142233.jpg"),
            server("no2", filename: "vacation.jpg"),
            server("no3", filename: "screenshot.png"),
            server("no4", filename: "IMG_4391.gif"),
            server("no5", filename: nil)
        ]
        let result = MissedDeletionFinder.find(
            serverAssets: assets,
            observed: [],
            excluded: [],
            liveLocalFilenames: [],
            now: now
        )
        #expect(Set(result.map(\.id)) == ["ok", "ok2", "ok3"])
    }

    @Test("outside lookback window → not a candidate")
    func windowSuppression() {
        let asset = server("s1", createdDaysAgo: 500)
        let result = MissedDeletionFinder.find(
            serverAssets: [asset],
            observed: [],
            excluded: [],
            liveLocalFilenames: [],
            now: now,
            daysWindow: 365
        )
        #expect(result.isEmpty)
    }

    @Test("missing fileCreatedAt → not a candidate")
    func missingCreatedAt() {
        var asset = server("s1")
        asset = ServerAsset(
            id: asset.id,
            checksum: asset.checksum,
            isTrashed: false,
            originalFileName: asset.originalFileName,
            fileCreatedAt: nil
        )
        let result = MissedDeletionFinder.find(
            serverAssets: [asset],
            observed: [],
            excluded: [],
            liveLocalFilenames: [],
            now: now
        )
        #expect(result.isEmpty)
    }

    @Test("results are newest-first")
    func newestFirst() {
        let assets = [
            server("old", filename: "IMG_1001.HEIC", createdDaysAgo: 100),
            server("new", filename: "IMG_2001.HEIC", createdDaysAgo: 1),
            server("mid", filename: "IMG_3001.HEIC", createdDaysAgo: 30)
        ]
        let result = MissedDeletionFinder.find(
            serverAssets: assets,
            observed: [],
            excluded: [],
            liveLocalFilenames: [],
            now: now
        )
        #expect(result.map(\.id) == ["new", "mid", "old"])
    }

    @Test("daysWindow <= 0 → no candidates")
    func windowZeroDisables() {
        let result = MissedDeletionFinder.find(
            serverAssets: [server("s1")],
            observed: [],
            excluded: [],
            liveLocalFilenames: [],
            now: now,
            daysWindow: 0
        )
        #expect(result.isEmpty)
    }

    @Test("minCreatedAt bound excludes older assets")
    func minBoundExclusion() {
        let assets = [
            server("recent", filename: "IMG_1001.HEIC", createdDaysAgo: 5),
            server("old", filename: "IMG_1002.HEIC", createdDaysAgo: 60)
        ]
        let result = MissedDeletionFinder.find(
            serverAssets: assets,
            observed: [],
            excluded: [],
            liveLocalFilenames: [],
            minCreatedAt: now.addingTimeInterval(-30 * 86_400),
            now: now
        )
        #expect(result.map(\.id) == ["recent"])
    }

    @Test("maxCreatedAt bound excludes newer assets")
    func maxBoundExclusion() {
        let assets = [
            server("recent", filename: "IMG_1001.HEIC", createdDaysAgo: 5),
            server("old", filename: "IMG_1002.HEIC", createdDaysAgo: 60)
        ]
        let result = MissedDeletionFinder.find(
            serverAssets: assets,
            observed: [],
            excluded: [],
            liveLocalFilenames: [],
            maxCreatedAt: now.addingTimeInterval(-30 * 86_400),
            now: now
        )
        #expect(result.map(\.id) == ["old"])
    }

    @Test("min and max bounds narrow to a window")
    func bothBoundsNarrowing() {
        let assets = [
            server("today", filename: "IMG_1001.HEIC", createdDaysAgo: 0.5),
            server("midweek", filename: "IMG_1002.HEIC", createdDaysAgo: 4),
            server("lastmonth", filename: "IMG_1003.HEIC", createdDaysAgo: 35)
        ]
        let result = MissedDeletionFinder.find(
            serverAssets: assets,
            observed: [],
            excluded: [],
            liveLocalFilenames: [],
            minCreatedAt: now.addingTimeInterval(-7 * 86_400),
            maxCreatedAt: now.addingTimeInterval(-2 * 86_400),
            now: now
        )
        #expect(result.map(\.id) == ["midweek"])
    }

    @Test("confirmedDeletedFilenames: only assets in the set become candidates")
    func confirmedMode_filterByName() {
        let assets = [
            server("a", filename: "IMG_4391.HEIC"),
            server("b", filename: "IMG_4392.HEIC"),
            server("c", filename: "IMG_4393.HEIC")
        ]
        let result = MissedDeletionFinder.find(
            serverAssets: assets,
            observed: [],
            excluded: [],
            liveLocalFilenames: [],
            confirmedDeletedFilenames: ["IMG_4391.HEIC", "IMG_4393.HEIC"],
            now: now
        )
        #expect(Set(result.map(\.id)) == ["a", "c"])
    }

    @Test("confirmedDeletedFilenames: bypasses iPhone filename grammar")
    func confirmedMode_bypassesGrammar() {
        // Screenshots, scans, etc. are valid evidence when the user
        // picked them from Recently Deleted, even though they don't
        // match the IMG_NNNN form.
        let assets = [
            server("a", filename: "Screenshot.PNG"),
            server("b", filename: "weird-scan-file.jpg")
        ]
        let result = MissedDeletionFinder.find(
            serverAssets: assets,
            observed: [],
            excluded: [],
            liveLocalFilenames: [],
            confirmedDeletedFilenames: ["Screenshot.PNG", "weird-scan-file.jpg"],
            now: now
        )
        #expect(Set(result.map(\.id)) == ["a", "b"])
    }

    @Test("confirmedDeletedFilenames: bypasses date window")
    func confirmedMode_bypassesDateWindow() {
        // User-confirmed deletions take precedence — server asset
        // might predate the daysWindow lookback but still be valid.
        let asset = server("old", filename: "IMG_4391.HEIC", createdDaysAgo: 1000)
        let result = MissedDeletionFinder.find(
            serverAssets: [asset],
            observed: [],
            excluded: [],
            liveLocalFilenames: [],
            confirmedDeletedFilenames: ["IMG_4391.HEIC"],
            now: now,
            daysWindow: 30
        )
        #expect(result.map(\.id) == ["old"])
    }

    @Test("confirmedDeletedFilenames: observed checksum still suppresses")
    func confirmedMode_observedStillSuppresses() {
        let asset = server("a", checksum: "OBS", filename: "IMG_4391.HEIC")
        let result = MissedDeletionFinder.find(
            serverAssets: [asset],
            observed: [Checksum(base64: "OBS")],
            excluded: [],
            liveLocalFilenames: [],
            confirmedDeletedFilenames: ["IMG_4391.HEIC"],
            now: now
        )
        #expect(result.isEmpty)
    }

    @Test("confirmedDeletedFilenames: live filename still suppresses")
    func confirmedMode_liveStillSuppresses() {
        // Sequence rollover defense: if a photo with this name is
        // alive on the phone right now, don't include it even if a
        // (different) photo with the same name is in Recently Deleted.
        let asset = server("a", filename: "IMG_4391.HEIC")
        let result = MissedDeletionFinder.find(
            serverAssets: [asset],
            observed: [],
            excluded: [],
            liveLocalFilenames: ["IMG_4391.HEIC"],
            confirmedDeletedFilenames: ["IMG_4391.HEIC"],
            now: now
        )
        #expect(result.isEmpty)
    }

    @Test("confirmedDeletedFilenames: empty set produces no candidates")
    func confirmedMode_emptySetNoCandidates() {
        let result = MissedDeletionFinder.find(
            serverAssets: [server("a")],
            observed: [],
            excluded: [],
            liveLocalFilenames: [],
            confirmedDeletedFilenames: [],
            now: now
        )
        #expect(result.isEmpty)
    }

    @Test("confirmedDeletedFilenames + explicit min/max: bounds apply")
    func confirmedMode_explicitBoundsApply() {
        // Regression test: previously, confirmed mode dropped explicit
        // bounds silently. With LocalAssetMetadataStore as the source
        // (years of history possible), the user's date range must
        // still constrain the result.
        let assets = [
            server("recent", filename: "IMG_4391.HEIC", createdDaysAgo: 5),
            server("old", filename: "IMG_4392.HEIC", createdDaysAgo: 60)
        ]
        let result = MissedDeletionFinder.find(
            serverAssets: assets,
            observed: [],
            excluded: [],
            liveLocalFilenames: [],
            minCreatedAt: now.addingTimeInterval(-30 * 86_400),
            confirmedDeletedFilenames: ["IMG_4391.HEIC", "IMG_4392.HEIC"],
            now: now
        )
        #expect(result.map(\.id) == ["recent"])
    }

    @Test("confirmedDeletedFilenames + bounds: missing createdAt skipped")
    func confirmedMode_boundsRequireCreatedAt() {
        let asset = ServerAsset(
            id: "no-date",
            checksum: Checksum(base64: "X"),
            isTrashed: false,
            originalFileName: "IMG_4391.HEIC",
            fileCreatedAt: nil
        )
        let result = MissedDeletionFinder.find(
            serverAssets: [asset],
            observed: [],
            excluded: [],
            liveLocalFilenames: [],
            minCreatedAt: now.addingTimeInterval(-30 * 86_400),
            confirmedDeletedFilenames: ["IMG_4391.HEIC"],
            now: now
        )
        #expect(result.isEmpty)
    }

    @Test("confirmedDeletedFilenames: case-insensitive match")
    func confirmedMode_caseInsensitive() {
        let result = MissedDeletionFinder.find(
            serverAssets: [server("a", filename: "img_4391.heic")],
            observed: [],
            excluded: [],
            liveLocalFilenames: [],
            confirmedDeletedFilenames: ["IMG_4391.HEIC"],
            now: now
        )
        #expect(result.map(\.id) == ["a"])
    }

    @Test("explicit min/max override daysWindow")
    func explicitBoundsOverrideWindow() {
        // daysWindow=7 would normally exclude the 60-day-old asset,
        // but an explicit minCreatedAt 100 days back keeps it in scope.
        let assets = [
            server("old", filename: "IMG_1001.HEIC", createdDaysAgo: 60)
        ]
        let result = MissedDeletionFinder.find(
            serverAssets: assets,
            observed: [],
            excluded: [],
            liveLocalFilenames: [],
            minCreatedAt: now.addingTimeInterval(-100 * 86_400),
            now: now,
            daysWindow: 7
        )
        #expect(result.map(\.id) == ["old"])
    }
}
