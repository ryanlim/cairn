import Foundation

/// URLProtocol subclass that intercepts HTTP requests for tests.
///
/// **Per-session dispatch.** Each call to `MockURLProtocol.session()`
/// returns a `MockSession` bound to a unique session id and injects
/// that id into every outgoing request via the
/// `X-Mock-Session-Id` header. `startLoading` looks the handler up by
/// id from a process-wide registry. Multiple `MockSession`s can
/// coexist without colliding — the global static handler we used
/// previously turned into a cross-suite race when swift-testing ran
/// `@Suite(.serialized)` suites in parallel with each other, and the
/// fix was to scope the handler to the session that owns the
/// request.
///
/// **Usage**:
/// ```
/// let mock = MockURLProtocol.session()
/// mock.handler = { req in (HTTPURLResponse(...), Data(...)) }
/// let client = ImmichClient(..., session: mock.session)
/// // mock.handler can be reassigned between phases of the same test
/// ```
///
/// The handler is automatically removed from the registry when
/// `MockSession` deinits — tests don't need to clean up manually.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    /// HTTP header used to dispatch a request to its owning session's
    /// handler. Cheap to read off `URLRequest` and survives the
    /// URLSession pipeline intact.
    static let sessionHeader = "X-Mock-Session-Id"

    nonisolated(unsafe) private static var handlers: [String: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)] = [:]
    nonisolated(unsafe) private static let handlersLock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool {
        // Only intercept requests that carry our session header.
        // Anything else falls through to the default URLSession path,
        // which keeps stray system calls (e.g. App Transport Security
        // pre-flights on first launch) out of our handlers.
        request.value(forHTTPHeaderField: sessionHeader) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let sessionId = request.value(forHTTPHeaderField: Self.sessionHeader),
              let handler = Self.lookup(sessionId) else {
            client?.urlProtocol(self, didFailWithError: NSError(
                domain: "MockURLProtocol",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "no handler configured for this session"]
            ))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    // MARK: - Registry

    static func register(_ handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data), for sessionId: String) {
        handlersLock.lock(); defer { handlersLock.unlock() }
        handlers[sessionId] = handler
    }

    static func unregister(_ sessionId: String) {
        handlersLock.lock(); defer { handlersLock.unlock() }
        handlers.removeValue(forKey: sessionId)
    }

    private static func lookup(_ sessionId: String) -> (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))? {
        handlersLock.lock(); defer { handlersLock.unlock() }
        return handlers[sessionId]
    }

    // MARK: - Factory

    /// Create a fresh `MockSession` with a unique id. The returned
    /// session's `URLSession` is wired to route its requests through
    /// `MockURLProtocol` and only this session's handler will be
    /// invoked for them.
    static func session() -> MockSession {
        let id = UUID().uuidString
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        // Inject the session-id header so requests carry their
        // routing key all the way to `startLoading`.
        config.httpAdditionalHeaders = [sessionHeader: id]
        return MockSession(session: URLSession(configuration: config), sessionId: id)
    }
}

/// Test-side handle that bundles a URLSession with its handler.
/// Setting `handler` updates `MockURLProtocol`'s registry under this
/// session's id; nil-ing it (or letting the `MockSession` deinit)
/// removes the entry.
final class MockSession: @unchecked Sendable {
    let session: URLSession
    let sessionId: String

    init(session: URLSession, sessionId: String) {
        self.session = session
        self.sessionId = sessionId
    }

    var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { nil }
        set {
            if let newValue {
                MockURLProtocol.register(newValue, for: sessionId)
            } else {
                MockURLProtocol.unregister(sessionId)
            }
        }
    }

    deinit {
        MockURLProtocol.unregister(sessionId)
    }
}

/// Thread-safe mutable box for test observations captured by `@Sendable` closures.
final class Ref<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
    func mutate(_ body: (inout T) -> Void) {
        lock.lock(); defer { lock.unlock() }; body(&_value)
    }
}

extension URLRequest {
    /// URLSession frequently delivers POST/DELETE bodies as `httpBodyStream`
    /// rather than `httpBody`, so we have to drain the stream to inspect them.
    func readBody() -> Data {
        if let body = httpBody, !body.isEmpty { return body }
        guard let stream = httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let n = stream.read(buffer, maxLength: bufferSize)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}
