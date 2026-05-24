import Foundation
import Testing
@testable import CairnCore

@Suite("ImmichClient sync/stream + ack", .serialized)
struct ImmichClientSyncStreamTests {

    private func makeClient(baseURL: String = "https://photos.example.com") -> ImmichClient {
        ImmichClient(
            baseURL: URL(string: baseURL)!,
            apiKey: "TEST-KEY",
            session: MockURLProtocol.session()
        )
    }

    /// Build the response body for `sync/stream` from a list of JSONL
    /// lines. Joining with `\n` and trailing newline matches what the
    /// server emits — `URLSession.AsyncBytes.lines` splits on `\n` and
    /// yields the final line whether or not it has a trailing newline.
    private func jsonl(_ lines: [String]) -> Data {
        Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    // MARK: - Streaming

    @Test("syncStream yields decoded events for a multi-event batch")
    func streamsMultipleEvents() async throws {
        let client = makeClient()
        let body = jsonl([
            #"{"type":"AssetV1","data":{"id":"a1","ownerId":"u1","originalFileName":"IMG_1.HEIC","thumbhash":null,"checksum":"AAAA","fileCreatedAt":null,"fileModifiedAt":null,"localDateTime":null,"duration":null,"type":"image","deletedAt":null,"isFavorite":false,"visibility":"timeline","livePhotoVideoId":null,"stackId":null,"libraryId":null,"width":null,"height":null,"isEdited":false},"ack":"a1-ack"}"#,
            #"{"type":"AssetV1","data":{"id":"a2","ownerId":"u1","originalFileName":"IMG_2.HEIC","thumbhash":null,"checksum":"BBBB","fileCreatedAt":null,"fileModifiedAt":null,"localDateTime":null,"duration":null,"type":"image","deletedAt":null,"isFavorite":false,"visibility":"timeline","livePhotoVideoId":null,"stackId":null,"libraryId":null,"width":null,"height":null,"isEdited":false},"ack":"a2-ack"}"#,
            #"{"type":"AssetDeleteV1","data":{"assetId":"a99"},"ack":"d99-ack"}"#,
            #"{"type":"SyncCompleteV1","data":{},"ack":"complete-ack"}"#,
        ])

        MockURLProtocol.handler = { req in
            #expect(req.url?.path == "/api/sync/stream")
            #expect(req.httpMethod == "POST")
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: [
                    "Content-Type": "application/jsonlines+json",
                ])!,
                body
            )
        }

        var events: [SyncEvent] = []
        for try await event in client.syncStream(types: [.assetsV1]) {
            events.append(event)
        }
        #expect(events.count == 4)
        guard case .asset(let a1, let ack1) = events[0] else {
            Issue.record("expected .asset for events[0]")
            return
        }
        #expect(a1.id == "a1")
        #expect(a1.checksum == "AAAA")
        #expect(ack1 == "a1-ack")

        guard case .assetDeleted(let del, _) = events[2] else {
            Issue.record("expected .assetDeleted for events[2]")
            return
        }
        #expect(del.assetId == "a99")

        guard case .complete(let type, _) = events[3] else {
            Issue.record("expected .complete for events[3]")
            return
        }
        #expect(type == .syncCompleteV1)
    }

    @Test("syncStream POSTs the SyncStreamRequest body with the requested types")
    func sendsExpectedRequestBody() async throws {
        let client = makeClient()
        let bodySink = Ref<Data?>(nil)

        MockURLProtocol.handler = { req in
            bodySink.value = req.readBody()
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }

        var seen = 0
        for try await _ in client.syncStream(types: [.assetsV1]) {
            seen += 1
        }
        #expect(seen == 0)

        let captured = try #require(bodySink.value)
        let json = try JSONSerialization.jsonObject(with: captured) as? [String: Any]
        #expect((json?["types"] as? [String]) == ["AssetsV1"])
        // reset is omitted when false (default) — keeps the body
        // minimal and matches what the server expects.
        #expect(json?["reset"] == nil)
    }

    @Test("syncStream includes reset:true when explicitly requested")
    func sendsResetTrue() async throws {
        let client = makeClient()
        let bodySink = Ref<Data?>(nil)

        MockURLProtocol.handler = { req in
            bodySink.value = req.readBody()
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }

        for try await _ in client.syncStream(types: [.assetsV1], reset: true) { }

        let captured = try #require(bodySink.value)
        let json = try JSONSerialization.jsonObject(with: captured) as? [String: Any]
        #expect((json?["reset"] as? Bool) == true)
    }

    @Test("syncStream surfaces 403 as .missingScope([sync.stream])")
    func surfaces403AsMissingScope() async {
        let client = makeClient()
        MockURLProtocol.handler = { req in
            return (
                HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }

        await #expect(throws: ImmichClientError.self) {
            for try await _ in client.syncStream(types: [.assetsV1]) { }
        }

        // Double-check the exact error variant.
        do {
            for try await _ in client.syncStream(types: [.assetsV1]) { }
            Issue.record("expected throw")
        } catch let err as ImmichClientError {
            guard case .missingScope(let scopes) = err else {
                Issue.record("expected .missingScope, got \(err)")
                return
            }
            #expect(scopes == ["sync.stream"])
        } catch {
            Issue.record("expected ImmichClientError, got \(error)")
        }
    }

    @Test("syncStream surfaces 500 with body as .httpStatus")
    func surfaces500AsHttpStatus() async {
        let client = makeClient()
        MockURLProtocol.handler = { req in
            return (
                HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                Data(#"{"error":"broken"}"#.utf8)
            )
        }

        do {
            for try await _ in client.syncStream(types: [.assetsV1]) { }
            Issue.record("expected throw")
        } catch let err as ImmichClientError {
            guard case .httpStatus(let code, _) = err else {
                Issue.record("expected .httpStatus, got \(err)")
                return
            }
            #expect(code == 500)
        } catch {
            Issue.record("expected ImmichClientError, got \(error)")
        }
    }

    @Test("malformed JSONL line mid-stream throws")
    func malformedLineMidStreamThrows() async {
        // Decoder failure is fail-loud — we'd rather abort the batch
        // than silently skip events the cache should have applied.
        // Caller's ack only happens after a successful apply, so the
        // cache stays consistent.
        let client = makeClient()
        let body = jsonl([
            #"{"type":"AssetV1","data":{"id":"a1","ownerId":"u1","originalFileName":"x","thumbhash":null,"checksum":"AAAA","fileCreatedAt":null,"fileModifiedAt":null,"localDateTime":null,"duration":null,"type":"image","deletedAt":null,"isFavorite":false,"visibility":"timeline","livePhotoVideoId":null,"stackId":null,"libraryId":null,"width":null,"height":null,"isEdited":false},"ack":"a1"}"#,
            #"{not valid json"#,
        ])
        MockURLProtocol.handler = { req in
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                body
            )
        }

        var seenBeforeError = 0
        do {
            for try await _ in client.syncStream(types: [.assetsV1]) {
                seenBeforeError += 1
            }
            Issue.record("expected stream to throw on bad line")
        } catch {
            // First (valid) event should have been yielded already.
            #expect(seenBeforeError == 1)
        }
    }

    @Test("empty stream (no events, just close) finishes cleanly")
    func emptyStream() async throws {
        let client = makeClient()
        MockURLProtocol.handler = { req in
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }
        var seen = 0
        for try await _ in client.syncStream(types: [.assetsV1]) {
            seen += 1
        }
        #expect(seen == 0)
    }

    @Test("blank lines between events are skipped, valid events still yield")
    func blankLinesAreSkipped() async throws {
        let client = makeClient()
        let body = jsonl([
            #"{"type":"AssetV1","data":{"id":"a1","ownerId":"u1","originalFileName":"x","thumbhash":null,"checksum":"AAAA","fileCreatedAt":null,"fileModifiedAt":null,"localDateTime":null,"duration":null,"type":"image","deletedAt":null,"isFavorite":false,"visibility":"timeline","livePhotoVideoId":null,"stackId":null,"libraryId":null,"width":null,"height":null,"isEdited":false},"ack":"a1"}"#,
            "",
            "   ",
            #"{"type":"AssetDeleteV1","data":{"assetId":"a99"},"ack":"d99"}"#,
        ])
        MockURLProtocol.handler = { req in
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                body
            )
        }
        var events: [SyncEvent] = []
        for try await event in client.syncStream(types: [.assetsV1]) {
            events.append(event)
        }
        #expect(events.count == 2)
    }

    // MARK: - Ack endpoints

    @Test("ackSync POSTs the ack array")
    func ackSyncPostsAcks() async throws {
        let client = makeClient()
        let bodySink = Ref<Data?>(nil)
        MockURLProtocol.handler = { req in
            #expect(req.url?.path == "/api/sync/ack")
            #expect(req.httpMethod == "POST")
            bodySink.value = req.readBody()
            return (
                HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }
        try await client.ackSync(["a1", "a2", "a3"])
        let captured = try #require(bodySink.value)
        let json = try JSONSerialization.jsonObject(with: captured) as? [String: Any]
        #expect((json?["acks"] as? [String]) == ["a1", "a2", "a3"])
    }

    @Test("ackSync with empty input is a no-op (no request)")
    func ackSyncEmptyIsNoOp() async throws {
        let client = makeClient()
        let sawRequest = Ref(false)
        MockURLProtocol.handler = { req in
            sawRequest.value = true
            return (
                HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }
        try await client.ackSync([])
        #expect(sawRequest.value == false)
    }

    @Test("ackSync 403 surfaces as .missingScope([sync.checkpoint.update])")
    func ackSyncMissingScope() async {
        let client = makeClient()
        MockURLProtocol.handler = { req in
            return (
                HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }
        do {
            try await client.ackSync(["a"])
            Issue.record("expected throw")
        } catch let err as ImmichClientError {
            guard case .missingScope(let scopes) = err else {
                Issue.record("expected .missingScope, got \(err)")
                return
            }
            #expect(scopes == ["sync.checkpoint.update"])
        } catch {
            Issue.record("expected ImmichClientError, got \(error)")
        }
    }

    @Test("currentSyncAcks decodes the GET /sync/ack response")
    func currentSyncAcksDecodes() async throws {
        let client = makeClient()
        MockURLProtocol.handler = { req in
            #expect(req.url?.path == "/api/sync/ack")
            #expect(req.httpMethod == "GET")
            let body = Data(#"[{"type":"AssetV1","ack":"a-cursor"},{"type":"AssetDeleteV1","ack":"d-cursor"}]"#.utf8)
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                body
            )
        }
        let acks = try await client.currentSyncAcks()
        #expect(acks.count == 2)
        #expect(acks.contains(SyncAckRecord(type: .assetV1, ack: "a-cursor")))
        #expect(acks.contains(SyncAckRecord(type: .assetDeleteV1, ack: "d-cursor")))
    }

    @Test("currentSyncAcks 403 surfaces as .missingScope([sync.checkpoint.read])")
    func currentSyncAcks403() async {
        let client = makeClient()
        MockURLProtocol.handler = { req in
            return (
                HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }
        do {
            _ = try await client.currentSyncAcks()
            Issue.record("expected throw")
        } catch let err as ImmichClientError {
            guard case .missingScope(let scopes) = err else {
                Issue.record("expected .missingScope, got \(err)")
                return
            }
            #expect(scopes == ["sync.checkpoint.read"])
        } catch {
            Issue.record("expected ImmichClientError, got \(error)")
        }
    }

    @Test("clearSyncAcks sends DELETE without body when types is nil")
    func clearSyncAcksWithoutTypes() async throws {
        let client = makeClient()
        let bodySink = Ref<Data?>(nil)
        let methodSink = Ref<String?>(nil)
        MockURLProtocol.handler = { req in
            methodSink.value = req.httpMethod
            bodySink.value = req.readBody()
            return (
                HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }
        try await client.clearSyncAcks(types: nil)
        #expect(methodSink.value == "DELETE")
        #expect(bodySink.value?.isEmpty == true)
    }

    @Test("clearSyncAcks(types:) includes the types in the body")
    func clearSyncAcksWithTypes() async throws {
        let client = makeClient()
        let bodySink = Ref<Data?>(nil)
        MockURLProtocol.handler = { req in
            bodySink.value = req.readBody()
            return (
                HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }
        try await client.clearSyncAcks(types: [.assetV1, .assetDeleteV1])
        let captured = try #require(bodySink.value)
        let json = try JSONSerialization.jsonObject(with: captured) as? [String: Any]
        let types = json?["types"] as? [String]
        #expect(types == ["AssetV1", "AssetDeleteV1"])
    }

    // MARK: - Authentication header carries through

    @Test("syncStream sends the x-api-key header")
    func streamSendsAPIKey() async throws {
        let client = makeClient()
        let keySink = Ref<String?>(nil)
        MockURLProtocol.handler = { req in
            keySink.value = req.value(forHTTPHeaderField: "x-api-key")
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }
        for try await _ in client.syncStream(types: [.assetsV1]) { }
        #expect(keySink.value == "TEST-KEY")
    }

    @Test("ackSync sends the x-api-key header")
    func ackSendsAPIKey() async throws {
        let client = makeClient()
        let keySink = Ref<String?>(nil)
        MockURLProtocol.handler = { req in
            keySink.value = req.value(forHTTPHeaderField: "x-api-key")
            return (
                HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }
        try await client.ackSync(["a"])
        #expect(keySink.value == "TEST-KEY")
    }

    // MARK: - Session-token (Bearer) routing

    @Test("syncStream sends Authorization: Bearer when sessionToken is set, no x-api-key")
    func syncStreamUsesBearerWhenSessionPresent() async throws {
        let baseClient = makeClient()
        let client = baseClient.withSessionToken("session-XYZ")
        let authSink = Ref<String?>(nil)
        let apiKeySink = Ref<String?>(nil)
        MockURLProtocol.handler = { req in
            if req.url?.path == "/api/sync/stream" {
                authSink.value = req.value(forHTTPHeaderField: "Authorization")
                apiKeySink.value = req.value(forHTTPHeaderField: "x-api-key")
            }
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }
        for try await _ in client.syncStream(types: [.assetsV1]) { }
        #expect(authSink.value == "Bearer session-XYZ")
        // Critical: with a session token, x-api-key is NOT sent —
        // otherwise the server's auth pipeline could short-circuit
        // on the API-key path before honoring the session token, and
        // the session-required endpoints would still reject.
        #expect(apiKeySink.value == nil)
    }

    @Test("ackSync sends Authorization: Bearer when sessionToken is set")
    func ackSyncUsesBearerWhenSessionPresent() async throws {
        let baseClient = makeClient()
        let client = baseClient.withSessionToken("session-XYZ")
        let authSink = Ref<String?>(nil)
        MockURLProtocol.handler = { req in
            authSink.value = req.value(forHTTPHeaderField: "Authorization")
            return (
                HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }
        try await client.ackSync(["a"])
        #expect(authSink.value == "Bearer session-XYZ")
    }

    @Test("login POSTs credentials to /api/auth/login and decodes the access token")
    func loginRoundTrip() async throws {
        let client = makeClient()
        let bodySink = Ref<Data?>(nil)
        MockURLProtocol.handler = { req in
            #expect(req.url?.path == "/api/auth/login")
            #expect(req.httpMethod == "POST")
            bodySink.value = req.readBody()
            let body = Data(#"{"accessToken":"abc-123","userId":"u1","userEmail":"a@b.co","name":"Alice","isAdmin":false,"profileImagePath":"","shouldChangePassword":false,"isOnboarded":true}"#.utf8)
            return (
                HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                body
            )
        }
        let resp = try await client.login(email: "a@b.co", password: "pw")
        #expect(resp.accessToken == "abc-123")
        #expect(resp.userId == "u1")
        #expect(resp.userEmail == "a@b.co")
        #expect(resp.name == "Alice")

        let captured = try #require(bodySink.value)
        let json = try JSONSerialization.jsonObject(with: captured) as? [String: Any]
        #expect((json?["email"] as? String) == "a@b.co")
        #expect((json?["password"] as? String) == "pw")
    }

    @Test("login surfaces 401 from wrong-credentials as ImmichClientError.httpStatus(401)")
    func loginRejectsBadCredentials() async {
        let client = makeClient()
        MockURLProtocol.handler = { req in
            return (
                HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
                Data(#"{"message":"Invalid credentials","statusCode":401}"#.utf8)
            )
        }
        do {
            _ = try await client.login(email: "a@b.co", password: "wrong")
            Issue.record("expected throw")
        } catch let err as ImmichClientError {
            guard case .httpStatus(let code, _) = err else {
                Issue.record("expected .httpStatus, got \(err)")
                return
            }
            #expect(code == 401)
        } catch {
            Issue.record("expected ImmichClientError, got \(error)")
        }
    }

    @Test("withSessionToken produces a fresh client with the token; original is unchanged")
    func withSessionTokenIsImmutable() {
        let original = ImmichClient(
            baseURL: URL(string: "https://photos.example.com")!,
            apiKey: "TEST-KEY",
            session: MockURLProtocol.session()
        )
        #expect(original.sessionToken == nil)
        let session = original.withSessionToken("xyz")
        #expect(session.sessionToken == "xyz")
        #expect(original.sessionToken == nil)
        let cleared = session.withSessionToken(nil)
        #expect(cleared.sessionToken == nil)
    }

    @Test("non-sync endpoints continue to use x-api-key even when sessionToken is set")
    func nonSyncEndpointsKeepApiKey() async throws {
        // The session token only applies to /sync/*. listAllAssets and
        // friends should keep using the API key — otherwise turning on
        // session auth would accidentally break every other endpoint.
        let baseClient = makeClient()
        let client = baseClient.withSessionToken("session-XYZ")
        let apiKeySink = Ref<String?>(nil)
        let authSink = Ref<String?>(nil)
        MockURLProtocol.handler = { req in
            apiKeySink.value = req.value(forHTTPHeaderField: "x-api-key")
            authSink.value = req.value(forHTTPHeaderField: "Authorization")
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"assets":{"items":[],"nextPage":null}}"#.utf8)
            )
        }
        _ = try await client.listAllAssets()
        #expect(apiKeySink.value == "TEST-KEY")
        #expect(authSink.value == nil)
    }
}
