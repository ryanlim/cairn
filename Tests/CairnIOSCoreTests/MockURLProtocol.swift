import Foundation

/// iOS-test-target copy of the URL-intercept helper. Same shape as
/// `Tests/CairnCoreTests/MockURLProtocol.swift`, but the
/// `URLProtocol` subclass is renamed so the two test targets don't
/// register a class with the same Objective-C name in the linked
/// test bundle — which the Swift 6.x ObjC runtime treats as a fatal
/// trap at process init (the symptom we hit was a SIGTRAP ~200ms
/// after `swift test` started, with no per-test failure). Keeping
/// the file local to each target (rather than promoting to a shared
/// test-helper module) is the minimum change to fix the collision;
/// reach for a shared module if a third test target needs the same
/// helper later.
///
/// Set `IOSMockURLProtocol.handler` to a closure that inspects the
/// inbound `URLRequest` and returns the canned `(HTTPURLResponse,
/// Data)` pair. Global state means the suite using this must run
/// serialized — see `@Suite("…", .serialized)` on the consumers.
final class IOSMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: NSError(
                domain: "IOSMockURLProtocol",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "no handler configured"]
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

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [IOSMockURLProtocol.self]
        return URLSession(configuration: config)
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
