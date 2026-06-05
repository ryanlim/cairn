#if canImport(OSLog) && canImport(UIKit)
import Foundation
import OSLog
import UIKit

/// On-device extraction of cairn's own log lines into a shareable
/// `.txt` file. Powers the "Export diagnostic logs" affordance in
/// Settings → Advanced.
///
/// **Scope.** `OSLogStore.scope(.currentProcessIdentifier)` is what
/// the iOS sandbox grants third-party apps: only log entries emitted
/// by *this* process since launch are visible. Prior-session logs are
/// not reachable from inside the app — testers who reproduce a bug,
/// then quit cairn, then come back to export, will get an empty
/// export. The Settings affordance documents this so the support
/// flow is "reproduce → export immediately without quitting."
///
/// **Subsystem filter.** Restricts to cairn's two `Logger(subsystem:)`
/// roots — `app.cairn` (shared core) and `app.cairn.ios` (iOS-only
/// callsites). Other apps' logs and system noise are excluded.
///
/// **Output.** A `.txt` written to `URL.temporaryDirectory` named
/// `cairn-diag-<ISO8601 timestamp>.txt`. Header carries the marketing
/// version, build number, device model, and iOS version so the
/// receiver doesn't have to ask. Body is one line per entry:
/// `HH:mm:ss.fff [<category>] <message>`, sorted oldest-first.
public enum LogExporter {

    public enum Error: Swift.Error, LocalizedError {
        case storeUnavailable(Swift.Error)
        case writeFailed(Swift.Error)
        case unauthorized

        public var errorDescription: String? {
            switch self {
            case .storeUnavailable(let inner):
                return "Couldn't open the system log store. (\(inner.localizedDescription))"
            case .writeFailed(let inner):
                return "Couldn't write the export file. (\(inner.localizedDescription))"
            case .unauthorized:
                return "The system blocked log access. Try again after relaunching cairn."
            }
        }
    }

    /// Snapshot of the version/device fields that get embedded in the
    /// export header. Resolved at call time from the running process,
    /// not at compile time, so the header reflects the live build.
    /// `@MainActor` because `UIDevice.current.systemVersion` is
    /// MainActor-isolated under Swift 6 strict concurrency.
    public struct Header: Sendable {
        public let appVersion: String       // CFBundleShortVersionString
        public let buildNumber: String      // CFBundleVersion
        public let iosVersion: String       // UIDevice.systemVersion
        public let deviceModel: String      // e.g. "iPhone15,2"

        @MainActor
        public init() {
            let info = Bundle.main.infoDictionary
            self.appVersion = (info?["CFBundleShortVersionString"] as? String) ?? "?"
            self.buildNumber = (info?["CFBundleVersion"] as? String) ?? "?"
            self.iosVersion = UIDevice.current.systemVersion
            self.deviceModel = Self.hardwareIdentifier() ?? "?"
        }

        /// Reads `hw.machine` from `sysctl` for the raw model string
        /// (`iPhone15,2`, `iPad14,1`, …). The user-facing model name
        /// requires a lookup table that drifts every fall; the raw
        /// identifier is exact and self-evident to anyone with a
        /// browser, which is fine for a maintainer-facing diagnostic.
        private static func hardwareIdentifier() -> String? {
            var size = 0
            sysctlbyname("hw.machine", nil, &size, nil, 0)
            guard size > 0 else { return nil }
            var bytes = [CChar](repeating: 0, count: size)
            sysctlbyname("hw.machine", &bytes, &size, nil, 0)
            return String(decoding: bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }

    /// Query, format, and persist a recent slice of cairn's logs to
    /// a temp file. Returns the URL of the written file.
    ///
    /// - `hours`: how far back to walk. The OSLogStore call honors
    ///   this against the in-process log buffer, which iOS sizes
    ///   dynamically based on free memory — on a quiet device you'll
    ///   typically see the last several hours; on a chatty one
    ///   (active sync, lots of log noise) the window narrows.
    ///   Defaults to 48h for triage.
    ///
    /// **Cross-process history.** The OSLog buffer scope cap means
    /// "current process only" — prior cairn launches are invisible.
    /// `PersistentLogStore` (fed by `DiagnosticLogFlusher`) keeps a
    /// rolling on-disk capture that survives relaunches; this
    /// function prepends the persistent file's contents (rolled
    /// then live, already chronological) to the current-buffer
    /// formatted block. Result: an export taken after a crash or
    /// memory-pressure kill still shows everything cairn logged in
    /// the last hours, not just whatever happened in the current
    /// process's launch window.
    @MainActor
    public static func export(hours: Int = 48) async throws -> URL {
        // Header has to run on the main actor (UIDevice access). The
        // OSLogStore query and file write don't, but the operation
        // overall completes in ~hundreds of ms on a typical capture
        // so we keep the whole thing on main for simplicity rather
        // than hopping actors mid-pipeline.
        let cutoff = Date(timeIntervalSinceNow: -Double(hours) * 3600)
        let store: OSLogStore
        do {
            store = try OSLogStore(scope: .currentProcessIdentifier)
        } catch {
            // OSLogStore opens fail with a privacy-class error on a
            // sandboxed app if the entitlement isn't honored or if a
            // sysdiagnose is in progress. Surface as `unauthorized`
            // so the UI can offer the "try again after relaunch"
            // hint instead of a raw NSError.
            if (error as NSError).code == 9 || (error as NSError).code == 13 {
                throw Error.unauthorized
            }
            throw Error.storeUnavailable(error)
        }

        // `position(date:)` clamps to the earliest available entry if
        // the requested cutoff is older than the buffer holds.
        let position = store.position(date: cutoff)
        let predicate = NSPredicate(format: "subsystem BEGINSWITH 'app.cairn'")

        let entries: [OSLogEntryLog]
        do {
            // `.reversed()` walks newest→oldest internally; we want
            // chronological order in the export, so collect and then
            // sort by date. Most production captures are ≤10k entries
            // even on a multi-hour sync, so the in-memory sort is fine.
            let raw = try store.getEntries(at: position, matching: predicate)
            var collected: [OSLogEntryLog] = []
            for entry in raw {
                if let logEntry = entry as? OSLogEntryLog {
                    collected.append(logEntry)
                }
            }
            collected.sort { $0.date < $1.date }
            entries = collected
        } catch {
            throw Error.storeUnavailable(error)
        }

        // Flush any in-flight OSLog entries into the persistent store
        // before we read it back, so the export captures the latest
        // cairn activity even when the next periodic flush would
        // otherwise be ~tens of seconds away.
        await DiagnosticLogFlusher.shared.flushNow()
        let persistedBody = await PersistentLogStore.shared.readAll()

        let header = Header()
        let body = formatExport(
            header: header,
            entries: entries,
            cutoff: cutoff,
            persistedPrefix: persistedBody
        )

        let filename = "cairn-diag-\(timestampForFilename(Date())).txt"
        let url = URL.temporaryDirectory.appendingPathComponent(filename)
        do {
            try body.data(using: .utf8)?.write(to: url, options: .atomic)
        } catch {
            throw Error.writeFailed(error)
        }
        return url
    }

    // MARK: - Formatting

    /// Header + body composer factored out for testability and so a
    /// future "preview the export" UI can reuse the same renderer.
    /// `persistedPrefix` is the contents of `PersistentLogStore`
    /// (rolled then live, already in chronological order); it's
    /// emitted before the current-buffer block so chronology is
    /// preserved across the process boundary.
    static func formatExport(
        header: Header,
        entries: [OSLogEntryLog],
        cutoff: Date,
        persistedPrefix: String = "",
        now: Date = Date()
    ) -> String {
        var lines: [String] = []
        lines.reserveCapacity(entries.count + 24)
        lines.append("=== cairn diagnostic export ===")
        lines.append("Generated: \(iso8601(now))")
        lines.append("Window: \(iso8601(cutoff)) → \(iso8601(now))")
        lines.append("Build: \(header.appVersion) (\(header.buildNumber))")
        lines.append("Device: \(header.deviceModel)")
        lines.append("iOS: \(header.iosVersion)")
        lines.append("Current-process entry count: \(entries.count)")
        lines.append("Persistent capture: \(persistedPrefix.isEmpty ? "empty" : "\(persistedPrefix.utf8.count) bytes")")
        lines.append("")
        if !persistedPrefix.isEmpty {
            lines.append("--- persistent capture (prior + current launches) ---")
            // The persisted body already terminates each entry with
            // a newline, so we don't append our own here — joining
            // would otherwise produce blank lines between entries.
            lines.append(persistedPrefix.trimmingCharacters(in: CharacterSet.newlines))
            lines.append("")
            lines.append("--- current-process buffer (newest, may overlap persistent) ---")
        }
        if entries.isEmpty {
            if persistedPrefix.isEmpty {
                lines.append("(no log entries in window — possible causes: app was relaunched after the time of interest [in-process log scope only sees logs from this launch], or the device's log buffer rotated out the window)")
            } else {
                lines.append("(no new current-process entries since the most recent persistent flush)")
            }
        } else {
            for entry in entries {
                let ts = clockTimestamp(entry.date)
                let cat = entry.category.isEmpty ? "-" : entry.category
                lines.append("\(ts) [\(cat)] \(entry.composedMessage)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // Formatters are documented thread-safe for reads since iOS 7,
    // but `ISO8601DateFormatter` / `DateFormatter` aren't `Sendable`
    // under strict concurrency. `nonisolated(unsafe)` opts these out
    // of the check — safe because nothing mutates them after the
    // closure-init configures them.
    nonisolated(unsafe) private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func iso8601(_ date: Date) -> String {
        iso8601Formatter.string(from: date)
    }

    /// `HH:mm:ss.fff` (24-hour, fractional seconds) for body lines.
    /// Date portion lives in the header; per-line dates would just be
    /// duplicated noise.
    nonisolated(unsafe) private static let bodyTimestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    private static func clockTimestamp(_ date: Date) -> String {
        bodyTimestampFormatter.string(from: date)
    }

    nonisolated(unsafe) private static let filenameTimestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    private static func timestampForFilename(_ date: Date) -> String {
        filenameTimestampFormatter.string(from: date)
    }
}

#endif
