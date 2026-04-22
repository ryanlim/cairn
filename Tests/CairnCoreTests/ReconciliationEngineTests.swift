import Testing
@testable import CairnCore

@Suite("ReconciliationEngine")
struct ReconciliationEngineTests {

    private func asset(_ id: String, _ checksum: String, livePhotoVideoId: String? = nil, isTrashed: Bool = false) -> ServerAsset {
        ServerAsset(id: id, checksum: Checksum(base64: checksum), livePhotoVideoId: livePhotoVideoId, isTrashed: isTrashed)
    }

    private func checksums(_ values: String...) -> Set<Checksum> {
        Set(values.map { Checksum(base64: $0) })
    }

    @Test("deletes a server asset whose checksum is in ever-seen but not in current-local")
    func deletesSimpleCase() {
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [asset("s1", "A"), asset("s2", "B")],
            currentLocalChecksums: checksums("A"),
            everSeenChecksums: checksums("A", "B")
        ))
        #expect(output.deleteCandidates.map(\.id) == ["s2"])
    }

    @Test("never deletes a server asset whose checksum was never on the iPhone — Mac-only uploads are safe")
    func spareServerAssetNeverSeenLocally() {
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [asset("s1", "A"), asset("s2", "MAC_ONLY")],
            currentLocalChecksums: checksums("A"),
            everSeenChecksums: checksums("A")
        ))
        #expect(output.deleteCandidates.isEmpty)
    }

    @Test("first run with empty ever-seen set produces no deletions and seeds ever-seen with all current checksums")
    func firstRunSeedsOnly() {
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [asset("s1", "A"), asset("s2", "B"), asset("s3", "C")],
            currentLocalChecksums: checksums("A", "B"),
            everSeenChecksums: []
        ))
        #expect(output.deleteCandidates.isEmpty)
        #expect(output.newlyObservedChecksums == checksums("A", "B"))
    }

    @Test("empty local library with populated ever-seen would flag everything — engine emits it; safety rails must catch")
    func emptyLocalFlagsEverything() {
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [asset("s1", "A"), asset("s2", "B")],
            currentLocalChecksums: [],
            everSeenChecksums: checksums("A", "B")
        ))
        #expect(Set(output.deleteCandidates.map(\.id)) == ["s1", "s2"])
    }

    @Test("assets already trashed on server are excluded from candidates and from the ever-seen denominator")
    func ignoresTrashedServerAssets() {
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [asset("s1", "A", isTrashed: true), asset("s2", "B")],
            currentLocalChecksums: checksums("B"),
            everSeenChecksums: checksums("A", "B")
        ))
        #expect(output.deleteCandidates.isEmpty)
        #expect(output.assetsInEverSeen == 1)
    }

    @Test("newly observed checksums reflect additions since last ever-seen snapshot")
    func newlyObservedReflectsAdditions() {
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [],
            currentLocalChecksums: checksums("A", "B", "C"),
            everSeenChecksums: checksums("A")
        ))
        #expect(output.newlyObservedChecksums == checksums("B", "C"))
    }

    @Test("a server asset re-appearing locally (e.g. photo restored from iOS Recently Deleted) is not a delete candidate")
    func restoredLocalNotCandidate() {
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [asset("s1", "A")],
            currentLocalChecksums: checksums("A"),
            everSeenChecksums: checksums("A")
        ))
        #expect(output.deleteCandidates.isEmpty)
    }

    @Test("duplicate server entries for the same checksum are all flagged if the content is gone locally")
    func duplicateServerEntriesAllFlagged() {
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [asset("s1", "A"), asset("s2", "A")],
            currentLocalChecksums: [],
            everSeenChecksums: checksums("A")
        ))
        #expect(Set(output.deleteCandidates.map(\.id)) == ["s1", "s2"])
    }

    @Test("excluded checksums are filtered out of candidates and reported in excludedCandidateCount")
    func exclusionFiltersOutCandidates() {
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [asset("s1", "A"), asset("s2", "B"), asset("s3", "C")],
            currentLocalChecksums: [],
            everSeenChecksums: checksums("A", "B", "C"),
            excludedChecksums: checksums("B")
        ))
        #expect(Set(output.deleteCandidates.map(\.id)) == ["s1", "s3"])
        #expect(output.excludedCandidateCount == 1)
    }

    @Test("exclusion has no effect on assets that wouldn't have been candidates anyway")
    func exclusionDoesNotInflateExcludedCount() {
        // X is excluded but not in ever-seen, so it was never a candidate. Excluding
        // it should not bump excludedCandidateCount; that count is for would-be
        // deletions actually saved by the exclusion list.
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [asset("s1", "A"), asset("s2", "X")],
            currentLocalChecksums: [],
            everSeenChecksums: checksums("A"),
            excludedChecksums: checksums("X")
        ))
        #expect(Set(output.deleteCandidates.map(\.id)) == ["s1"])
        #expect(output.excludedCandidateCount == 0)
    }

    @Test("default excludedChecksums is empty — old call sites continue to work")
    func defaultExclusionEmpty() {
        let output = ReconciliationEngine.compute(.init(
            serverAssets: [asset("s1", "A")],
            currentLocalChecksums: [],
            everSeenChecksums: checksums("A")
        ))
        #expect(output.deleteCandidates.map(\.id) == ["s1"])
        #expect(output.excludedCandidateCount == 0)
    }
}
