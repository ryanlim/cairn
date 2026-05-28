import Foundation
import Testing
@testable import CairnCore

@Suite("ImmichClient over mocked HTTP", .serialized)
struct ImmichClientHTTPTests {

    private func makeClient(baseURL: String = "https://photos.example.com") -> (client: ImmichClient, mock: MockSession) {
        let mock = MockURLProtocol.session()
        let client = ImmichClient(
            baseURL: URL(string: baseURL)!,
            apiKey: "TEST-KEY",
            session: mock.session
        )
        return (client, mock)
    }

    private let emptyAssetsBody = Data(#"{"assets":{"items":[],"nextPage":null}}"#.utf8)

    // MARK: - Auth + URL shape

    @Test("every request carries the x-api-key header")
    func sendsAPIKey() async throws {
        let (client, mock) = makeClient()
        let seenKeys = Ref<[String?]>([])
        mock.handler = { req in
            seenKeys.mutate { $0.append(req.value(forHTTPHeaderField: "x-api-key")) }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"assets":{"items":[],"nextPage":null}}"#.utf8))
        }
        _ = try await client.listAllAssets()
        #expect(seenKeys.value == ["TEST-KEY"])
    }

    @Test("no Accept header is sent — would have caught the /server/ping 406 bug")
    func noAcceptHeader() async throws {
        let (client, mock) = makeClient()
        let seenAccept = Ref<String?>("sentinel")
        mock.handler = { req in
            seenAccept.value = req.value(forHTTPHeaderField: "Accept")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"assets":{"items":[],"nextPage":null}}"#.utf8))
        }
        _ = try await client.listAllAssets()
        #expect(seenAccept.value == nil)
    }

    @Test("bare-host URL gets /api prefix applied at request time")
    func apiPrefixAppliedFromBareHost() async throws {
        let (client, mock) = makeClient(baseURL: "https://photos.example.com/")
        let seenURL = Ref<URL?>(nil)
        mock.handler = { req in
            seenURL.value = req.url
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"assets":{"items":[],"nextPage":null}}"#.utf8))
        }
        _ = try await client.listAllAssets()
        #expect(seenURL.value?.absoluteString == "https://photos.example.com/api/search/metadata")
    }

    // MARK: - Pagination

    @Test("listAllAssets iterates nextPage and terminates when null")
    func paginationWalksPages() async throws {
        let (client, mock) = makeClient()
        let requestedPages = Ref<[Int]>([])
        mock.handler = { req in
            let body = req.readBody()
            let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
            let page = json["page"] as! Int
            requestedPages.mutate { $0.append(page) }

            let (items, nextPage): (String, String) = switch page {
                case 1: ("""
                    [{"id":"a1","checksum":"c1","livePhotoVideoId":null,"isTrashed":false},
                     {"id":"a2","checksum":"c2","livePhotoVideoId":null,"isTrashed":false}]
                    """, #""2""#)
                case 2: ("""
                    [{"id":"a3","checksum":"c3","livePhotoVideoId":"v1","isTrashed":false}]
                    """, "null")
                default: ("[]", "null")
            }
            let body2 = #"{"assets":{"items":\#(items),"nextPage":\#(nextPage)}}"#
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(body2.utf8))
        }

        let assets = try await client.listAllAssets()
        #expect(requestedPages.value == [1, 2])
        #expect(assets.map(\.id) == ["a1", "a2", "a3"])
        #expect(assets.last?.livePhotoVideoId == "v1")
    }

    @Test("listAllAssets omits visibility filter by default and sets it when provided")
    func visibilityFilterPropagates() async throws {
        let (client, mock) = makeClient()
        let seenVisibilities = Ref<[String?]>([])
        mock.handler = { req in
            let body = req.readBody()
            let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
            seenVisibilities.mutate { $0.append(json["visibility"] as? String) }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"assets":{"items":[],"nextPage":null}}"#.utf8))
        }
        _ = try await client.listAllAssets()
        _ = try await client.listAllAssets(visibility: .hidden)
        _ = try await client.listAllAssets(visibility: .timeline)
        #expect(seenVisibilities.value == [nil, "hidden", "timeline"])
    }

    @Test("listAllAssets requests `withDeleted: false` by default and `true` when asked")
    func withDeletedFlagPropagates() async throws {
        let (client, mock) = makeClient()
        let seenWithDeleted = Ref<[Bool]>([])
        mock.handler = { req in
            let body = req.readBody()
            let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
            seenWithDeleted.mutate { $0.append(json["withDeleted"] as! Bool) }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"assets":{"items":[],"nextPage":null}}"#.utf8))
        }
        _ = try await client.listAllAssets()
        _ = try await client.listAllAssets(includeTrashed: true)
        #expect(seenWithDeleted.value == [false, true])
    }

    // MARK: - Error paths

    @Test("HTTP 4xx surfaces as ImmichClientError.httpStatus with status and body")
    func fourHundredSurfaces() async throws {
        let (client, mock) = makeClient()
        mock.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
             Data(#"{"message":"not found"}"#.utf8))
        }
        await #expect(throws: ImmichClientError.self) {
            _ = try await client.listAllAssets()
        }
    }

    @Test("HTTP 401 surfaces with code and body — drives 'rejected the API key' copy")
    func unauthorizedSurfaces() async throws {
        let (client, mock) = makeClient()
        let body = #"{"message":"Invalid API key"}"#
        mock.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
             Data(body.utf8))
        }
        await #expect {
            _ = try await client.listAllAssets(maxRetries: 0)
        } throws: { error in
            guard case let ImmichClientError.httpStatus(code, returnedBody) = error else { return false }
            return code == 401 && returnedBody == body
        }
    }

    @Test("HTTP 403 surfaces with code and body — drives 'missing scopes' copy")
    func forbiddenSurfaces() async throws {
        let (client, mock) = makeClient()
        let body = #"{"message":"Missing required permission: asset.delete"}"#
        mock.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!,
             Data(body.utf8))
        }
        await #expect {
            _ = try await client.listAllAssets(maxRetries: 0)
        } throws: { error in
            guard case let ImmichClientError.httpStatus(code, returnedBody) = error else { return false }
            return code == 403 && returnedBody == body
        }
    }

    @Test("HTTP 500 surfaces with code and body — drives 'server error, try again' copy")
    func internalServerErrorSurfaces() async throws {
        let (client, mock) = makeClient()
        let body = "Internal Server Error"
        mock.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
             Data(body.utf8))
        }
        await #expect {
            _ = try await client.listAllAssets(maxRetries: 0)
        } throws: { error in
            guard case let ImmichClientError.httpStatus(code, returnedBody) = error else { return false }
            return code == 500 && returnedBody == body
        }
    }

    @Test("HTTP 503 surfaces with code and body — also routes to 'server error' copy (>=500)")
    func serviceUnavailableSurfaces() async throws {
        let (client, mock) = makeClient()
        let body = "Service Unavailable"
        mock.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!,
             Data(body.utf8))
        }
        await #expect {
            _ = try await client.listAllAssets(maxRetries: 0)
        } throws: { error in
            guard case let ImmichClientError.httpStatus(code, returnedBody) = error else { return false }
            return code == 503 && returnedBody == body
        }
    }

    // MARK: - Pagination retry

    @Test("listAllAssets retries after a transient failure and returns the success result")
    func paginationRetrySucceeds() async throws {
        let (client, mock) = makeClient()
        let attemptCount = Ref<Int>(0)
        mock.handler = { req in
            let n = attemptCount.value
            attemptCount.mutate { $0 += 1 }
            if n == 0 {
                // First attempt — transient 500.
                return (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                        Data("upstream blip".utf8))
            }
            // Subsequent attempt — succeed with one asset and terminate pagination.
            let body = #"{"assets":{"items":[{"id":"a1","checksum":"c1","livePhotoVideoId":null,"isTrashed":false}],"nextPage":null}}"#
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(body.utf8))
        }
        let assets = try await client.listAllAssets(maxRetries: 1)
        #expect(attemptCount.value == 2)
        #expect(assets.map(\.id) == ["a1"])
    }

    @Test("listAllAssets surfaces the final error after exhausting maxRetries")
    func paginationRetryExhausts() async throws {
        let (client, mock) = makeClient()
        let attemptCount = Ref<Int>(0)
        mock.handler = { req in
            attemptCount.mutate { $0 += 1 }
            return (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                    Data("still broken".utf8))
        }
        await #expect {
            _ = try await client.listAllAssets(maxRetries: 1)
        } throws: { error in
            guard case let ImmichClientError.httpStatus(code, body) = error else { return false }
            return code == 500 && body == "still broken"
        }
        // maxRetries: 1 → 2 total attempts (the initial + one retry).
        #expect(attemptCount.value == 2)
    }

    @Test("malformed JSON on 200 response throws a decoding error")
    func malformedJSONOnOK() async throws {
        let (client, mock) = makeClient()
        mock.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data("this is not json".utf8))
        }
        await #expect(throws: (any Error).self) {
            _ = try await client.listAllAssets()
        }
    }

    // MARK: - Destructive calls

    @Test("trashAssets sends DELETE /api/assets with force:false")
    func trashSendsCorrectBody() async throws {
        let (client, mock) = makeClient()
        let seenMethod = Ref<String?>(nil)
        let seenPath = Ref<String?>(nil)
        let seenBody = Ref<Data>(Data())
        mock.handler = { req in
            seenMethod.value = req.httpMethod
            seenPath.value = req.url?.path
            seenBody.value = req.readBody()
            return (HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
        }
        try await client.trashAssets(ids: ["a1", "a2"])
        #expect(seenMethod.value == "DELETE")
        #expect(seenPath.value == "/api/assets")

        let json = try JSONSerialization.jsonObject(with: seenBody.value) as! [String: Any]
        #expect(json["force"] as? Bool == false)
        #expect(json["ids"] as? [String] == ["a1", "a2"])
    }

    @Test("restoreAssets POSTs to /api/trash/restore/assets with ids only")
    func restoreSendsCorrectRequest() async throws {
        let (client, mock) = makeClient()
        let seenMethod = Ref<String?>(nil)
        let seenPath = Ref<String?>(nil)
        let seenBody = Ref<Data>(Data())
        mock.handler = { req in
            seenMethod.value = req.httpMethod
            seenPath.value = req.url?.path
            seenBody.value = req.readBody()
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
        }
        try await client.restoreAssets(ids: ["a1"])
        #expect(seenMethod.value == "POST")
        #expect(seenPath.value == "/api/trash/restore/assets")
        let json = try JSONSerialization.jsonObject(with: seenBody.value) as! [String: Any]
        #expect(json["ids"] as? [String] == ["a1"])
        #expect(json["force"] == nil)
    }

    @Test("listTags GETs /api/tags and parses the response array")
    func listTagsParsesArray() async throws {
        let (client, mock) = makeClient()
        mock.handler = { req in
            #expect(req.httpMethod == "GET")
            #expect(req.url?.path == "/api/tags")
            let json = """
            [
              {"id":"t1","value":"cairn/v1/run/abc","color":"#FF0000","createdAt":"2026-04-21T00:00:00.000Z"},
              {"id":"t2","value":"cairn/v1/run/def"}
            ]
            """
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(json.utf8))
        }
        let tags = try await client.listTags()
        #expect(tags.count == 2)
        #expect(tags[0].value == "cairn/v1/run/abc")
        #expect(tags[0].color == "#FF0000")
        #expect(tags[0].createdAt != nil)
        #expect(tags[1].color == nil)
    }

    @Test("assetsForTag iterates timeline/archive/hidden and merges, passing tagIds and withDeleted:true in each request")
    func assetsForTagIteratesVisibilities() async throws {
        let (client, mock) = makeClient()
        let seenVisibilities = Ref<[String]>([])
        mock.handler = { req in
            let body = req.readBody()
            let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
            #expect(json["tagIds"] as? [String] == ["T-123"])
            #expect(json["withDeleted"] as? Bool == true)
            seenVisibilities.mutate { $0.append(json["visibility"] as! String) }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"assets":{"items":[],"nextPage":null}}"#.utf8))
        }
        _ = try await client.assetsForTag(tagId: "T-123")
        #expect(seenVisibilities.value == ["timeline", "archive", "hidden"])
    }

    @Test("assetsForTag dedupes assets that appear under multiple visibility queries")
    func assetsForTagDedupes() async throws {
        let (client, mock) = makeClient()
        mock.handler = { req in
            // Pretend the same asset shows up for every visibility class.
            let body = #"{"assets":{"items":[{"id":"dup","checksum":"ck","livePhotoVideoId":null,"isTrashed":false}],"nextPage":null}}"#
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(body.utf8))
        }
        let assets = try await client.assetsForTag(tagId: "T")
        #expect(assets.count == 1)
    }

    @Test("trashAssets and restoreAssets on empty id lists are no-ops (no network)")
    func emptyIdListsSkipNetwork() async throws {
        let (client, mock) = makeClient()
        let hitCount = Ref<Int>(0)
        mock.handler = { req in
            hitCount.mutate { $0 += 1 }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
        }
        try await client.trashAssets(ids: [])
        try await client.restoreAssets(ids: [])
        #expect(hitCount.value == 0)
    }

    // MARK: - apiKeyInfo

    @Test("apiKeyInfo GETs /api/api-keys/me and parses id, name, permissions")
    func apiKeyInfoSuccess() async throws {
        let (client, mock) = makeClient()
        let seenMethod = Ref<String?>(nil)
        let seenPath = Ref<String?>(nil)
        mock.handler = { req in
            seenMethod.value = req.httpMethod
            seenPath.value = req.url?.path
            let json = """
            {
              "id": "key-abc-123",
              "name": "cairn iPhone",
              "permissions": ["asset.read", "asset.delete", "tag.create", "tag.asset"]
            }
            """
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(json.utf8))
        }
        let info = try await client.apiKeyInfo()
        #expect(seenMethod.value == "GET")
        #expect(seenPath.value == "/api/api-keys/me")
        #expect(info.id == "key-abc-123")
        #expect(info.name == "cairn iPhone")
        #expect(info.permissions == ["asset.read", "asset.delete", "tag.create", "tag.asset"])
    }

    @Test("apiKeyInfo accepts an empty permissions array")
    func apiKeyInfoEmptyPermissions() async throws {
        let (client, mock) = makeClient()
        mock.handler = { req in
            let json = #"{"id":"k","name":"unscoped","permissions":[]}"#
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(json.utf8))
        }
        let info = try await client.apiKeyInfo()
        #expect(info.permissions.isEmpty)
    }

    @Test("apiKeyInfo on HTTP 401 throws ImmichClientError.httpStatus(401, body:)")
    func apiKeyInfoUnauthorized() async throws {
        let (client, mock) = makeClient()
        mock.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
             Data(#"{"message":"unauthorized"}"#.utf8))
        }
        await #expect {
            _ = try await client.apiKeyInfo()
        } throws: { err in
            guard case ImmichClientError.httpStatus(let code, let body) = err else { return false }
            return code == 401 && body.contains("unauthorized")
        }
    }

    @Test("apiKeyInfo on HTTP 403 throws ImmichClientError.httpStatus(403, body:)")
    func apiKeyInfoForbidden() async throws {
        let (client, mock) = makeClient()
        mock.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!,
             Data(#"{"message":"forbidden"}"#.utf8))
        }
        await #expect {
            _ = try await client.apiKeyInfo()
        } throws: { err in
            guard case ImmichClientError.httpStatus(let code, _) = err else { return false }
            return code == 403
        }
    }

    @Test("apiKeyInfo on HTTP 500 throws ImmichClientError.httpStatus(500, body:)")
    func apiKeyInfoServerError() async throws {
        let (client, mock) = makeClient()
        mock.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
             Data("internal server error".utf8))
        }
        await #expect {
            _ = try await client.apiKeyInfo()
        } throws: { err in
            guard case ImmichClientError.httpStatus(let code, _) = err else { return false }
            return code == 500
        }
    }

    @Test("apiKeyInfo on malformed JSON throws a decoding error")
    func apiKeyInfoMalformedJSON() async throws {
        let (client, mock) = makeClient()
        mock.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data("<html>not json</html>".utf8))
        }
        await #expect(throws: DecodingError.self) {
            _ = try await client.apiKeyInfo()
        }
    }

    // MARK: - assetStatistics

    @Test("assetStatistics GETs /api/assets/statistics with isTrashed query and parses counts")
    func assetStatisticsSuccess() async throws {
        let (client, mock) = makeClient()
        let seenMethod = Ref<String?>(nil)
        let seenPath = Ref<String?>(nil)
        let seenQuery = Ref<String?>(nil)
        mock.handler = { req in
            seenMethod.value = req.httpMethod
            seenPath.value = req.url?.path
            seenQuery.value = req.url?.query
            let json = #"{"images":1234,"videos":56,"total":1290}"#
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(json.utf8))
        }
        let stats = try await client.assetStatistics()
        #expect(seenMethod.value == "GET")
        #expect(seenPath.value == "/api/assets/statistics")
        #expect(seenQuery.value == "isTrashed=false")
        #expect(stats.images == 1234)
        #expect(stats.videos == 56)
        #expect(stats.total == 1290)
    }

    @Test("assetStatistics(includeTrashed: true) sends isTrashed=true")
    func assetStatisticsIncludeTrashed() async throws {
        let (client, mock) = makeClient()
        let seenQuery = Ref<String?>(nil)
        mock.handler = { req in
            seenQuery.value = req.url?.query
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"images":0,"videos":0,"total":0}"#.utf8))
        }
        _ = try await client.assetStatistics(includeTrashed: true)
        #expect(seenQuery.value == "isTrashed=true")
    }

    @Test("assetStatistics carries x-api-key header")
    func assetStatisticsSendsAPIKey() async throws {
        let (client, mock) = makeClient()
        let seenKey = Ref<String?>(nil)
        mock.handler = { req in
            seenKey.value = req.value(forHTTPHeaderField: "x-api-key")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"images":0,"videos":0,"total":0}"#.utf8))
        }
        _ = try await client.assetStatistics()
        #expect(seenKey.value == "TEST-KEY")
    }

    @Test("assetStatistics on HTTP 401 throws ImmichClientError.httpStatus(401, body:)")
    func assetStatisticsUnauthorized() async throws {
        let (client, mock) = makeClient()
        mock.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
             Data(#"{"message":"unauthorized"}"#.utf8))
        }
        await #expect {
            _ = try await client.assetStatistics()
        } throws: { err in
            guard case ImmichClientError.httpStatus(let code, let body) = err else { return false }
            return code == 401 && body.contains("unauthorized")
        }
    }

    @Test("assetStatistics on HTTP 403 (missing asset.statistics scope) throws httpStatus(403)")
    func assetStatisticsForbidden() async throws {
        let (client, mock) = makeClient()
        mock.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!,
             Data(#"{"message":"missing scope: asset.statistics"}"#.utf8))
        }
        await #expect {
            _ = try await client.assetStatistics()
        } throws: { err in
            guard case ImmichClientError.httpStatus(let code, _) = err else { return false }
            return code == 403
        }
    }

    @Test("assetStatistics on HTTP 500 throws ImmichClientError.httpStatus(500, body:)")
    func assetStatisticsServerError() async throws {
        let (client, mock) = makeClient()
        mock.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
             Data("boom".utf8))
        }
        await #expect {
            _ = try await client.assetStatistics()
        } throws: { err in
            guard case ImmichClientError.httpStatus(let code, _) = err else { return false }
            return code == 500
        }
    }

    @Test("assetStatistics on malformed JSON throws a decoding error")
    func assetStatisticsMalformedJSON() async throws {
        let (client, mock) = makeClient()
        mock.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data("not json at all".utf8))
        }
        await #expect(throws: DecodingError.self) {
            _ = try await client.assetStatistics()
        }
    }
}
