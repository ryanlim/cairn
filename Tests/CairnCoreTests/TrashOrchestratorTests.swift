import Foundation
import Testing
@testable import CairnCore

@Suite("TrashOrchestrator")
struct TrashOrchestratorTests {

    private func tempJournal() -> (DeletionJournal, URL) {
        let path = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "orch-\(UUID().uuidString).jsonl")
        return (DeletionJournal(path: path), path)
    }

    private func asset(_ id: String, _ checksum: String, livePhotoVideoId: String? = nil) -> ServerAsset {
        ServerAsset(id: id, checksum: Checksum(base64: checksum), livePhotoVideoId: livePhotoVideoId)
    }

    @Test("happy path: tag → trash, journal records every step in order")
    func happyPath() async throws {
        let writer = FakeWriter()
        let (journal, path) = tempJournal()
        defer { try? FileManager.default.removeItem(at: path) }

        let orch = TrashOrchestrator(writer: writer, journal: journal)
        let summary = try await orch.run(
            runId: "RUN-1",
            candidates: [asset("a1", "ck1"), asset("a2", "ck2")],
            assetsInPurview: 100,
            dryRun: false
        )

        #expect(summary.trashedAssetIds == ["a1", "a2"])
        #expect(summary.breadcrumbTag?.value == "cairn/v1/run/RUN-1")
        #expect(await writer.upsertedTagValues == ["cairn/v1/run/RUN-1"])
        #expect(await writer.trashedBatches == [["a1", "a2"]])

        let entries = try await journal.readAll()
        let kinds = entries.map { String(describing: $0.event).prefix(20) }
        #expect(kinds.contains(where: { $0.hasPrefix("runStarted") }))
        #expect(kinds.contains(where: { $0.hasPrefix("planningTrash") }))
        #expect(kinds.contains(where: { $0.hasPrefix("tagApplied") }))
        #expect(kinds.contains(where: { $0.hasPrefix("trashSucceeded") }))
        #expect(kinds.contains(where: { $0.hasPrefix("runCompleted") }))
    }

    @Test("Live Photo: linked motion video UUID is included in the trash batch")
    func livePhotoVideoIncluded() async throws {
        let writer = FakeWriter()
        let (journal, path) = tempJournal()
        defer { try? FileManager.default.removeItem(at: path) }

        let orch = TrashOrchestrator(writer: writer, journal: journal)
        _ = try await orch.run(
            runId: "RUN-LIVE",
            candidates: [asset("still-1", "ck1", livePhotoVideoId: "video-1")],
            assetsInPurview: 50,
            dryRun: false
        )

        let trashed = await writer.trashedBatches[0]
        #expect(trashed.sorted() == ["still-1", "video-1"])
    }

    @Test("dry-run journals plan but never calls writer")
    func dryRunIsInert() async throws {
        let writer = FakeWriter()
        let (journal, path) = tempJournal()
        defer { try? FileManager.default.removeItem(at: path) }

        let orch = TrashOrchestrator(writer: writer, journal: journal)
        let summary = try await orch.run(
            runId: "DRY",
            candidates: [asset("a1", "ck1")],
            assetsInPurview: 10,
            dryRun: true
        )

        #expect(summary.trashedAssetIds.isEmpty)
        #expect(await writer.trashedBatches.isEmpty)
        #expect(await writer.taggedBatches.isEmpty)
        #expect(await writer.upsertedTagValues.isEmpty)

        let entries = try await journal.readAll()
        #expect(entries.contains { if case .planningTrash = $0.event { return true } else { return false } })
        #expect(!entries.contains { if case .tagApplied = $0.event { return true } else { return false } })
    }

    @Test("empty candidates: short-circuits with runStarted + runCompleted, no tag/trash calls")
    func emptyCandidatesShortCircuits() async throws {
        let writer = FakeWriter()
        let (journal, path) = tempJournal()
        defer { try? FileManager.default.removeItem(at: path) }

        let orch = TrashOrchestrator(writer: writer, journal: journal)
        let summary = try await orch.run(runId: "EMPTY", candidates: [], assetsInPurview: 100, dryRun: false)

        #expect(summary.trashedAssetIds.isEmpty)
        #expect(await writer.upsertedTagValues.isEmpty)
        #expect(await writer.trashedBatches.isEmpty)
    }

    @Test("trash failure is journaled and rethrown — tag is still applied first")
    func trashFailureJournaledAndRethrown() async throws {
        let writer = FakeWriter()
        await writer.setFailTrash(FakeError(message: "boom"))
        let (journal, path) = tempJournal()
        defer { try? FileManager.default.removeItem(at: path) }

        let orch = TrashOrchestrator(writer: writer, journal: journal)
        await #expect(throws: FakeError.self) {
            _ = try await orch.run(
                runId: "FAIL",
                candidates: [asset("a1", "ck1")],
                assetsInPurview: 10,
                dryRun: false
            )
        }

        #expect(await writer.upsertedTagValues.count == 1) // tag was created before delete attempt
        let entries = try await journal.readAll()
        #expect(entries.contains { if case .trashFailed = $0.event { return true } else { return false } })
        #expect(!entries.contains { if case .trashSucceeded = $0.event { return true } else { return false } })
    }

    /// Pins the "breadcrumb stays on server after a partial-failure run"
    /// semantic. Tag is upserted + applied *before* the DELETE call,
    /// so if the DELETE throws, the server has:
    ///   - the `cairn/v1/run/<id>` tag committed
    ///   - the tag applied to the candidate asset IDs
    ///   - the assets themselves still live (not trashed)
    ///
    /// That's the intended shape — the tag is a breadcrumb, not a state
    /// flag. `cairn history` will find the tag on live, non-trashed
    /// assets; that tells the user "this run attempted to trash these
    /// and the server rejected it," which is the whole point of the
    /// breadcrumb. The journal's `trashFailed` event is the local-side
    /// mirror of the same fact.
    @Test("trash failure after tag: cairn/v1 tag and tagApplied remain, trashFailed is the terminal")
    func trashFailureLeavesBreadcrumbOnServer() async throws {
        let writer = FakeWriter()
        await writer.setFailTrash(FakeError(message: "server-500"))
        let (journal, path) = tempJournal()
        defer { try? FileManager.default.removeItem(at: path) }

        let candidates = [asset("a1", "ck1"), asset("a2", "ck2")]
        let orch = TrashOrchestrator(writer: writer, journal: journal)
        await #expect(throws: FakeError.self) {
            _ = try await orch.run(
                runId: "PARTIAL",
                candidates: candidates,
                assetsInPurview: 100,
                dryRun: false
            )
        }

        // Tag was created AND applied on the server before trash threw.
        #expect(await writer.upsertedTagValues == ["cairn/v1/run/PARTIAL"])
        let tagged = await writer.taggedBatches
        #expect(tagged.count == 1)
        #expect(tagged[0].assetIds.sorted() == ["a1", "a2"])
        // DELETE never committed.
        #expect(await writer.trashedBatches.isEmpty)

        // Journal: tagApplied + trashFailed, NO trashSucceeded.
        // `trashFailed` is the terminal — the orchestrator's
        // `emittedTerminal` flag prevents an extra `runAborted` or
        // `runCompleted` from landing on top of it.
        let entries = try await journal.readAll()
        let events = entries.map { String(describing: $0.event) }
        #expect(events.contains { $0.hasPrefix("tagApplied") })
        #expect(events.contains { $0.hasPrefix("trashFailed") })
        #expect(!events.contains { $0.hasPrefix("trashSucceeded") })
        #expect(!events.contains { $0.hasPrefix("runCompleted") })
    }
}
