import Foundation
import Testing
@testable import CairnCore

@Suite("OrphanReconciler")
struct OrphanReconcilerTests {

    private func server(
        _ id: String,
        checksum: String,
        filename: String? = "photo.heic",
        createdAt: Date? = Date(timeIntervalSince1970: 1_700_000_000),
        isTrashed: Bool = false
    ) -> ServerAsset {
        ServerAsset(
            id: id,
            checksum: Checksum(base64: checksum),
            isTrashed: isTrashed,
            originalFileName: filename,
            fileCreatedAt: createdAt
        )
    }

    private func meta(
        _ localId: String,
        filename: String? = "photo.heic",
        creationDate: Date? = Date(timeIntervalSince1970: 1_700_000_000),
        observedAt: Date = Date()
    ) -> LocalAssetMetadata {
        LocalAssetMetadata(
            localIdentifier: localId,
            originalFileName: filename,
            creationDate: creationDate,
            modificationDate: nil,
            fileSize: nil,
            observedAt: observedAt
        )
    }

    @Test("no metadata → no orphans")
    func noMetadata() {
        let orphans = OrphanReconciler.match(
            serverAssets: [server("s1", checksum: "AAA")],
            observed: [],
            metadata: [],
            presentLocalIdentifiers: []
        )
        #expect(orphans.isEmpty)
    }

    @Test("matching filename and date but localId still present → no orphan")
    func matchedButLocalIdStillPresent() {
        let orphans = OrphanReconciler.match(
            serverAssets: [server("s1", checksum: "AAA")],
            observed: [],
            metadata: [meta("local-1")],
            presentLocalIdentifiers: ["local-1"]
        )
        // Asset is still in the photo library; even if it never got
        // hashed, the next sync's normal hash path will catch it.
        #expect(orphans.isEmpty)
    }

    @Test("matching filename and date with localId absent → orphan surfaces")
    func matchedWithLocalIdAbsent() {
        let orphans = OrphanReconciler.match(
            serverAssets: [server("s1", checksum: "AAA")],
            observed: [],
            metadata: [meta("local-1")],
            presentLocalIdentifiers: []
        )
        #expect(orphans.count == 1)
        #expect(orphans.first?.serverAsset.id == "s1")
        #expect(orphans.first?.matchedMetadata.localIdentifier == "local-1")
    }

    @Test("checksum already in observed → no orphan (already known)")
    func observedSkipsOrphan() {
        let orphans = OrphanReconciler.match(
            serverAssets: [server("s1", checksum: "AAA")],
            observed: [Checksum(base64: "AAA")],
            metadata: [meta("local-1")],
            presentLocalIdentifiers: []
        )
        #expect(orphans.isEmpty)
    }

    @Test("trashed server assets are skipped")
    func trashedSkipped() {
        let orphans = OrphanReconciler.match(
            serverAssets: [server("s1", checksum: "AAA", isTrashed: true)],
            observed: [],
            metadata: [meta("local-1")],
            presentLocalIdentifiers: []
        )
        #expect(orphans.isEmpty)
    }

    @Test("multiple metadata rows match same server asset → closest creationDate wins")
    func closestDateWins() {
        let serverDate = Date(timeIntervalSince1970: 1_700_000_000)
        let assets = [server("s1", checksum: "AAA", createdAt: serverDate)]
        let orphans = OrphanReconciler.match(
            serverAssets: assets,
            observed: [],
            metadata: [
                meta("local-far", creationDate: serverDate.addingTimeInterval(1.5)),
                meta("local-near", creationDate: serverDate.addingTimeInterval(0.2))
            ],
            presentLocalIdentifiers: []
        )
        #expect(orphans.count == 1)
        #expect(orphans.first?.matchedMetadata.localIdentifier == "local-near")
    }

    @Test("filename match is case-insensitive")
    func filenameCaseInsensitive() {
        let orphans = OrphanReconciler.match(
            serverAssets: [server("s1", checksum: "AAA", filename: "IMG_0001.HEIC")],
            observed: [],
            metadata: [meta("local-1", filename: "img_0001.heic")],
            presentLocalIdentifiers: []
        )
        #expect(orphans.count == 1)
    }

    @Test("date outside tolerance → no orphan")
    func dateOutsideTolerance() {
        let serverDate = Date(timeIntervalSince1970: 1_700_000_000)
        let orphans = OrphanReconciler.match(
            serverAssets: [server("s1", checksum: "AAA", createdAt: serverDate)],
            observed: [],
            metadata: [meta("local-1", creationDate: serverDate.addingTimeInterval(60))],
            presentLocalIdentifiers: [],
            dateTolerance: 2
        )
        #expect(orphans.isEmpty)
    }

    @Test("date exactly on tolerance edge → orphan surfaces")
    func dateOnToleranceEdge() {
        let serverDate = Date(timeIntervalSince1970: 1_700_000_000)
        let orphans = OrphanReconciler.match(
            serverAssets: [server("s1", checksum: "AAA", createdAt: serverDate)],
            observed: [],
            metadata: [meta("local-1", creationDate: serverDate.addingTimeInterval(2))],
            presentLocalIdentifiers: [],
            dateTolerance: 2
        )
        #expect(orphans.count == 1)
    }

    @Test("server asset missing fileCreatedAt → no orphan")
    func serverMissingDate() {
        let orphans = OrphanReconciler.match(
            serverAssets: [server("s1", checksum: "AAA", createdAt: nil)],
            observed: [],
            metadata: [meta("local-1")],
            presentLocalIdentifiers: []
        )
        #expect(orphans.isEmpty)
    }

    @Test("server asset missing originalFileName → no orphan")
    func serverMissingFilename() {
        let orphans = OrphanReconciler.match(
            serverAssets: [server("s1", checksum: "AAA", filename: nil)],
            observed: [],
            metadata: [meta("local-1")],
            presentLocalIdentifiers: []
        )
        #expect(orphans.isEmpty)
    }
}
