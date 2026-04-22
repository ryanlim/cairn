import Foundation

/// Append-only forensic log of every destructive action the app takes (or attempts).
/// One JSON object per line (JSONL). Never mutated after write.
///
/// The journal is written *before* each destructive call and *after* its outcome,
/// so a partial failure can always be reconstructed from disk. Pair with
/// the per-run breadcrumb tag on the server side: the journal answers
/// "what did we do?" and the tag answers "where did it land?".
public actor DeletionJournal {
    public let path: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(path: URL) {
        self.path = path
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        self.encoder = enc
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    public func append(_ entry: JournalEntry) throws {
        let data = try encoder.encode(entry)
        var line = data
        line.append(0x0A) // '\n'

        let fm = FileManager.default
        if !fm.fileExists(atPath: path.path) {
            fm.createFile(atPath: path.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: path)
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try handle.close()
    }

    public func readAll() throws -> [JournalEntry] {
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        let raw = try Data(contentsOf: path)
        guard let text = String(data: raw, encoding: .utf8) else { return [] }
        var out: [JournalEntry] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let entry = try decoder.decode(JournalEntry.self, from: Data(trimmed.utf8))
            out.append(entry)
        }
        return out
    }
}

public struct JournalEntry: Codable, Sendable, Equatable {
    public let timestamp: Date
    public let runId: String
    public let event: Event

    public init(timestamp: Date = Date(), runId: String, event: Event) {
        self.timestamp = timestamp
        self.runId = runId
        self.event = event
    }

    public enum Event: Codable, Sendable, Equatable {
        case runStarted(dryRun: Bool, candidateCount: Int, assetsInPurview: Int)
        case planningTrash(targets: [TrashTarget])
        case tagApplied(tagId: String, tagValue: String, assetIds: [String])
        case trashSucceeded(assetIds: [String])
        case trashFailed(assetIds: [String], message: String)
        case runCompleted(deletedCount: Int)
        case runAborted(reason: String)
        case restoreStarted(fromRunId: String, assetIds: [String])
        case restoreSucceeded(fromRunId: String, assetIds: [String])
        case restoreFailed(fromRunId: String, assetIds: [String], message: String)
        /// User added these checksums to the exclusion list. `fromRunId` is set when
        /// the exclusion happened from a run-detail view; nil for ad-hoc additions.
        case assetsExcluded(checksums: [String], fromRunId: String?)
    }

    public struct TrashTarget: Codable, Sendable, Equatable {
        public let assetId: String
        public let checksum: String
        public let livePhotoVideoId: String?

        public init(assetId: String, checksum: String, livePhotoVideoId: String?) {
            self.assetId = assetId
            self.checksum = checksum
            self.livePhotoVideoId = livePhotoVideoId
        }
    }
}
