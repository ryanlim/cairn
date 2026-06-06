#if canImport(OSLog) && canImport(UIKit)
import Foundation
import OSLog

/// Rolling on-disk capture of cairn's OSLog stream so the diagnostic
/// export can show events from *prior* app process lifetimes, not
/// just the current one.
///
/// **Why this exists.** `OSLogStore.scope(.currentProcessIdentifier)`
/// is what iOS grants third-party apps. Every time cairn relaunches
/// (user reopen after a crash, iOS memory-pressure kill, normal
/// background → terminate cycle), the prior process's OSLog buffer is
/// gone from the export's POV. That means the most common failure
/// mode — "sync starts, gets interrupted, restarts, exports give us
/// nothing" — is invisible to us. Persisting a copy of recent entries
/// to a file under the app sandbox survives process death and gives
/// us cross-launch continuity.
///
/// **Capture model.** A `DiagnosticLogFlusher` (registered at app
/// launch in `CairnApp.init` and triggered on scene-phase background)
/// polls `OSLogStore` every ~20s and on every backgrounding event,
/// extracts entries newer than its watermark, and appends them via
/// `append(formatted:)`. Frequent enough that even a sudden kill only
/// loses ~20s of recent entries; quiet enough that the buffer write
/// isn't a sync-loop hotspot.
///
/// **Rotation.** Single primary file (`cairn-persistent.log`) capped
/// at `maxBytes` (5 MB). When primary exceeds the cap on an append,
/// it's renamed to `cairn-persistent.log.1` (replacing any existing
/// rolled file) and the next append starts a fresh primary. Two-file
/// max means worst-case disk usage is ~10 MB. The export concatenates
/// rolled then primary so the chronological order survives rotation.
///
/// **Format.** Each appended block already has trailing newlines from
/// the formatter; this actor doesn't insert separators of its own.
public actor PersistentLogStore {

    public static let shared = PersistentLogStore()

    /// Roll the primary file off once it exceeds this many bytes.
    /// 5 MB is enough to hold ~30k log lines at typical lengths,
    /// which covers a multi-hour sync's worth of cairn entries with
    /// margin. Bump if real captures keep losing too much history.
    public let maxBytes: Int

    private let liveURL: URL
    private let rolledURL: URL
    private let fileManager: FileManager

    /// Initializer is internal so `shared` is the only meaningful
    /// access path in production. Tests construct their own instances
    /// pointing at a temp directory to keep the singleton untouched.
    init(
        directory: URL = PersistentLogStore.defaultDirectory(),
        primaryFilename: String = "cairn-persistent.log",
        rolledFilename: String = "cairn-persistent.log.1",
        maxBytes: Int = 5 * 1024 * 1024,
        fileManager: FileManager = .default
    ) {
        self.liveURL = directory.appendingPathComponent(primaryFilename)
        self.rolledURL = directory.appendingPathComponent(rolledFilename)
        self.maxBytes = maxBytes
        self.fileManager = fileManager
        // Best-effort directory creation. Inability to write here
        // makes the store a no-op rather than a crash; the diagnostic
        // export still works against the OSLog buffer.
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Append a pre-formatted block to the live file. Caller is
    /// responsible for line termination — the typical block looks
    /// like multiple `HH:mm:ss.fff [category] message\n` lines
    /// concatenated by `LogExporter.formatExport`.
    public func append(formatted block: String) {
        guard !block.isEmpty, let data = block.data(using: .utf8) else { return }
        rotateIfNeeded(additional: data.count)
        do {
            if fileManager.fileExists(atPath: liveURL.path) {
                let handle = try FileHandle(forWritingTo: liveURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: liveURL, options: .atomic)
            }
        } catch {
            // Best-effort. A write failure (no disk space, sandbox
            // hiccup) shouldn't crash the diagnostic flusher; future
            // appends will retry from scratch.
        }
    }

    /// Whole concatenated body, rolled first then live. Returns an
    /// empty string when no persistent capture exists yet. The
    /// caller (`LogExporter.export`) prepends a header and merges
    /// this with current-buffer entries.
    public func readAll() -> String {
        var combined = ""
        if let data = try? Data(contentsOf: rolledURL),
           let str = String(data: data, encoding: .utf8)
        {
            combined.append(str)
        }
        if let data = try? Data(contentsOf: liveURL),
           let str = String(data: data, encoding: .utf8)
        {
            combined.append(str)
        }
        return combined
    }

    /// Wipe both files. Used by the optional "Clear diagnostic log"
    /// UI affordance and by tests.
    public func clear() {
        try? fileManager.removeItem(at: liveURL)
        try? fileManager.removeItem(at: rolledURL)
    }

    /// Read-only metadata for the existing capture. Used to render a
    /// "persistent log: N lines, X KB" hint in Settings so a tester
    /// can see whether the file has anything before they bother
    /// exporting. Returns `(byteCount, lineCount)` — zero when no
    /// files exist.
    public func stats() -> (bytes: Int, lines: Int) {
        let live = sizeOf(liveURL)
        let rolled = sizeOf(rolledURL)
        let bytes = live + rolled
        guard bytes > 0 else { return (0, 0) }
        let body = readAll()
        let lines = body.isEmpty ? 0 : body.split(separator: "\n", omittingEmptySubsequences: false).count
        return (bytes, lines)
    }

    // MARK: - Private

    private func sizeOf(_ url: URL) -> Int {
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber
        else { return 0 }
        return size.intValue
    }

    /// Roll live → rolled when the post-append size would exceed
    /// `maxBytes`. Cheap: a `[.size]` attribute read + one `moveItem`.
    /// The previous rolled file (if any) is removed first so we cap
    /// total disk usage at ~2 × maxBytes.
    private func rotateIfNeeded(additional: Int) {
        let liveSize = sizeOf(liveURL)
        guard liveSize + additional > maxBytes else { return }
        try? fileManager.removeItem(at: rolledURL)
        try? fileManager.moveItem(at: liveURL, to: rolledURL)
    }

    /// Default home for the capture: the app's Documents directory.
    /// Excluded from iCloud backup because (a) it's diagnostic noise,
    /// not user data, and (b) the file is recreated on each launch
    /// from the live OSLog buffer anyway, so backup adds nothing.
    nonisolated static func defaultDirectory() -> URL {
        let docs = (try? FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL.temporaryDirectory
        let dir = docs.appendingPathComponent("Diagnostics", isDirectory: true)
        // Mark the directory `excludedFromBackup` so iCloud backup
        // skips it. Best-effort — failure is harmless (the file just
        // gets backed up as ordinary user data).
        var url = dir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return dir
    }
}

/// Polls `OSLogStore` for cairn's subsystems on a cadence and
/// streams new entries into `PersistentLogStore`. Owned by
/// `CairnApp` (one per app launch); the periodic Task survives the
/// app's normal foreground→background→foreground cycles. Explicit
/// flush via `flushNow()` is wired to scene-phase background
/// transitions so we capture the tail of recent activity before
/// iOS suspends the process.
///
/// **Isolation.** Implemented as a Swift `actor` so its work runs
/// on its own executor — emphatically NOT MainActor. An earlier
/// `@MainActor` annotation here meant the periodic poll's
/// `OSLogStore.getEntries` call (which can take dozens of ms during
/// heavy sync-time logging) and the loop+format pass over collected
/// entries all ran on the main thread, producing visible UI stutter
/// every 20s. Moving to an actor unblocks main and keeps cairn's
/// scrolling smooth during long syncs.
public actor DiagnosticLogFlusher {

    public static let shared = DiagnosticLogFlusher()

    /// Cadence for the periodic poll. 20s balances "lose ~no more
    /// than this on a sudden kill" against "don't burn cycles
    /// polling an empty buffer when the app is idle."
    public let pollInterval: TimeInterval

    private let store: PersistentLogStore
    private var periodicTask: Task<Void, Never>?
    private var lastFlushed: Date

    init(
        store: PersistentLogStore = .shared,
        pollInterval: TimeInterval = 20
    ) {
        self.store = store
        self.pollInterval = pollInterval
        // Start the watermark at process launch — anything earlier
        // is either from a prior process (already persisted, if
        // anything) or system noise we don't care about.
        self.lastFlushed = Date()
    }

    /// Begin periodic polling. Idempotent — calling twice keeps a
    /// single Task running.
    public func start() {
        guard periodicTask == nil else { return }
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval: TimeInterval = (await self?.pollInterval) ?? 20
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self else { return }
                await self.flushNow()
            }
        }
    }

    /// Stop the periodic Task. Used by sign-out and tests.
    public func stop() {
        periodicTask?.cancel()
        periodicTask = nil
    }

    /// Synchronous flush trigger. Queries OSLog for entries since
    /// the last watermark, appends to the persistent store, advances
    /// the watermark. Safe to call from any context that can `await`
    /// the actor hop into the flusher.
    public func flushNow() async {
        let cutoff = lastFlushed
        let now = Date()
        // Advance the watermark before doing the work so concurrent
        // calls don't double-capture overlapping windows.
        lastFlushed = now

        let entries: [OSLogEntryLog]
        do {
            let osStore = try OSLogStore(scope: .currentProcessIdentifier)
            let position = osStore.position(date: cutoff)
            let predicate = NSPredicate(format: "subsystem BEGINSWITH 'app.cairn'")
            var collected: [OSLogEntryLog] = []
            let raw = try osStore.getEntries(at: position, matching: predicate)
            for entry in raw {
                if let log = entry as? OSLogEntryLog, log.date >= cutoff {
                    collected.append(log)
                }
            }
            collected.sort { $0.date < $1.date }
            entries = collected
        } catch {
            // OSLogStore can briefly fail (e.g. during sysdiagnose).
            // Don't roll the watermark back — next flush will retry
            // from the new `now`, accepting the small window loss.
            return
        }

        guard !entries.isEmpty else { return }

        var lines: [String] = []
        lines.reserveCapacity(entries.count)
        for entry in entries {
            let ts = Self.timestampFormatter.string(from: entry.date)
            let cat = entry.category.isEmpty ? "-" : entry.category
            lines.append("\(ts) [\(cat)] \(entry.composedMessage)")
        }
        let block = lines.joined(separator: "\n") + "\n"
        await store.append(formatted: block)
    }

    nonisolated(unsafe) private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()
}

#endif
