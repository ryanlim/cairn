import Foundation
#if canImport(Network)
import Network
#endif

/// Three-state classification of network failures: distinguishes
/// "device has no internet at all" from "device is connected but
/// the network upstream is broken" from "internet is fine, the
/// specific Immich server isn't responding." Used by the sync-error
/// path to produce a more actionable user-facing message than the
/// generic URLError fallback.
public enum NetworkDiagnosis: Sendable, Equatable {

    /// `NWPathMonitor` reports no usable interface — Wi-Fi off,
    /// Airplane Mode, etc. No network call possible.
    case noConnection

    /// `NWPathMonitor` reports a satisfied path (Wi-Fi associated /
    /// cellular up) but a HEAD probe to a known-good public host
    /// failed. Typical real-world cause: connected to a Wi-Fi
    /// network whose router is broken or has no upstream (DHCP
    /// quirks, captive portal blocking egress, ISP outage). cairn
    /// can't reach Immich because nothing else can either.
    case internetDown

    /// `NWPathMonitor` and the public canary both report a healthy
    /// internet — the failure is specifically reaching the user's
    /// Immich instance. URL wrong, server down, key revoked,
    /// reverse-proxy misconfigured, LAN-only server while user is
    /// off-LAN.
    case serverUnreachable
}

/// Background reachability probe. Owns an `NWPathMonitor` so the
/// current connection status is always cheap to read, and a
/// `runCanaryCheck()` method that issues an HTTP HEAD to a stable
/// public endpoint for the "is the internet itself broken" case.
///
/// Run for the lifetime of `AppDependencies` (i.e. the app
/// process). Cheap — `NWPathMonitor` is a system primitive with
/// negligible overhead, and the canary only fires on error paths.
///
/// The canary host is Apple's captive-portal detection endpoint —
/// the same URL iOS itself hits when a device first joins a Wi-Fi
/// network to figure out whether it landed in a captive portal.
/// Picked over a third-party (Cloudflare, Google, etc.) because the
/// device is already trusting Apple infrastructure as part of OS
/// operation; no new privacy surface, no new dependency.
@MainActor
public final class ReachabilityProbe {

    /// URL hit when the caller asks for an external connectivity
    /// check. A 200 response means the public internet is reachable
    /// from this device; anything else (timeout, DNS, non-200) is
    /// treated as "internet down."
    public static let canaryURL = URL(string: "https://captive.apple.com/hotspot-detect.html")!

    #if canImport(Network)
    private let monitor: NWPathMonitor
    private let monitorQueue = DispatchQueue(label: "cairn.reachability", qos: .utility)
    #endif

    /// Last-known status from `NWPathMonitor`. Starts optimistic
    /// (`.satisfied`) so the very first sync attempt — which runs
    /// before the monitor has reported once — doesn't get
    /// mis-classified as offline. The monitor's `pathUpdateHandler`
    /// fires within a few milliseconds of `start(queue:)`, so the
    /// optimistic seed is only relevant for that boot-time race.
    private var lastStatus: PathStatus = .satisfied

    /// Mirror enum so the public API doesn't leak `NWPath.Status`
    /// to callers (and so unit tests on hosts without `Network`
    /// can still construct values).
    public enum PathStatus: Sendable, Equatable {
        case satisfied
        case unsatisfied
        case requiresConnection
    }

    public init() {
        #if canImport(Network)
        self.monitor = NWPathMonitor()
        self.monitor.pathUpdateHandler = { [weak self] path in
            let mapped: PathStatus
            switch path.status {
            case .satisfied: mapped = .satisfied
            case .unsatisfied: mapped = .unsatisfied
            case .requiresConnection: mapped = .requiresConnection
            @unknown default: mapped = .satisfied
            }
            Task { @MainActor [weak self] in
                self?.lastStatus = mapped
            }
        }
        self.monitor.start(queue: monitorQueue)
        #endif
    }

    /// Current connection status from `NWPathMonitor`. Read-only;
    /// updated asynchronously by the monitor's update handler.
    public var currentStatus: PathStatus { lastStatus }

    /// Issue a HEAD request to the canary URL. Returns `true` on
    /// 200, `false` on any other outcome (timeout, DNS, non-200).
    /// `timeoutSeconds` defaults to 4 — short enough that error
    /// reporting still feels responsive, long enough to ride out
    /// transient latency spikes on slow LTE.
    public func runCanaryCheck(timeoutSeconds: Double = 4.0) async -> Bool {
        var request = URLRequest(url: Self.canaryURL)
        request.httpMethod = "HEAD"
        request.timeoutInterval = timeoutSeconds
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return http.statusCode == 200
        } catch {
            return false
        }
    }

    /// Combine `currentStatus` and the canary check into a single
    /// three-state diagnosis. Order is significant:
    ///
    ///   1. If the path is unsatisfied / requires-connection, skip
    ///      the canary — there's no network to canary over.
    ///   2. Otherwise run the canary. Success → server-specific
    ///      failure. Failure → internet is down despite the satisfied
    ///      path (the broken-upstream case).
    ///
    /// Called from the sync error path; tolerates being called on
    /// any thread because the underlying state is `MainActor`-bound
    /// already.
    public func classify() async -> NetworkDiagnosis {
        switch currentStatus {
        case .unsatisfied, .requiresConnection:
            return .noConnection
        case .satisfied:
            let canaryOK = await runCanaryCheck()
            return canaryOK ? .serverUnreachable : .internetDown
        }
    }
}
