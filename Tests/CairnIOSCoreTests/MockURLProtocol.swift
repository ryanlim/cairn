import Foundation

/// iOS-test-target twin of `Tests/CairnCoreTests/MockURLProtocol.swift`.
/// Same per-session-dispatch design (see that file's docs); the
/// `URLProtocol` subclass is named `IOSMockURLProtocol` so the two
/// test targets don't register a class with the same Objective-C
/// runtime name in the linked test bundle.
final class IOSMockURLProtocol: URLProtocol, @unchecked Sendable {
    /// HTTP header used to dispatch a request to its owning session's
    /// handler. Cheap to read off `URLRequest` and survives the
    /// URLSession pipeline intact.
    static let sessionHeader = "X-Mock-Session-Id"

    nonisolated(unsafe) private static var handlers: [String: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)] = [:]
    nonisolated(unsafe) private static let handlersLock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool {
        request.value(forHTTPHeaderField: sessionHeader) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let sessionId = request.value(forHTTPHeaderField: Self.sessionHeader),
              let handler = Self.lookup(sessionId) else {
            client?.urlProtocol(self, didFailWithError: NSError(
                domain: "IOSMockURLProtocol",
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

    static func session() -> IOSMockSession {
        let id = UUID().uuidString
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [IOSMockURLProtocol.self]
        config.httpAdditionalHeaders = [sessionHeader: id]
        return IOSMockSession(session: URLSession(configuration: config), sessionId: id)
    }
}

/// Test-side handle that bundles a URLSession with its handler.
final class IOSMockSession: @unchecked Sendable {
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
                IOSMockURLProtocol.register(newValue, for: sessionId)
            } else {
                IOSMockURLProtocol.unregister(sessionId)
            }
        }
    }

    deinit {
        IOSMockURLProtocol.unregister(sessionId)
    }
}

/// Thread-safe mutable box for test observations captured by
/// `@Sendable` closures. Pure Swift — no ObjC bridging — so the
/// duplicate-class-name concern that drove the `IOSMockURLProtocol`
/// rename doesn't apply here; this stays identical to the
/// CairnCoreTests copy.
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
