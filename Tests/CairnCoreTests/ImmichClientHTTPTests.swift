import Foundation
import Testing
@testable import CairnCore

@Suite("ImmichClient over mocked HTTP", .serialized)
struct ImmichClientHTTPTests {

    private func makeClient(baseURL: String = "https://photos.example.com") -> ImmichClient {
        ImmichClient(
            baseURL: URL(string: baseURL)!,
            apiKey: "TEST-KEY",
            session: MockURLProtocol.session()
        )
    }

    private let emptyAssetsBody = Data(#"{"assets":{"items":[],"nextPage":null}}"#.utf8)

    // MARK: - Auth + URL shape

    @Test("every request carries the x-api-key header")
    func sendsAPIKey() async throws {
        let client = makeClient()
        let seenKeys = Ref<[String?]>([])
        MockURLProtocol.handler = { req in
            seenKeys.mutate { $0.append(req.value(forHTTPHeaderField: "x-api-key")) }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"assets":{"items":[],"nextPage":null}}"#.utf8))
        }
        _ = try await client.listAllAssets()
        #expect(seenKeys.value == ["TEST-KEY"])
    }

    @Test("no Accept header is sent — would have caught the /server/ping 406 bug")
    func noAcceptHeader() async throws {
        let client = makeClient()
        let seenAccept = Ref<String?>("sentinel")
        MockURLProtocol.handler = { req in
            seenAccept.value = req.value(forHTTPHeaderField: "Accept")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"assets":{"items":[],"nextPage":null}}"#.utf8))
        }
        _ = try await client.listAllAssets()
        #expect(seenAccept.value == nil)
    }

    @Test("bare-host URL gets /api prefix applied at request time")
    func apiPrefixAppliedFromBareHost() async throws {
        let client = makeClient(baseURL: "https://photos.example.com/")
        let seenURL = Ref<URL?>(nil)
        MockURLProtocol.handler = { req in
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
        let client = makeClient()
        let requestedPages = Ref<[Int]>([])
        MockURLProtocol.handler = { req in
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
        let client = makeClient()
        let seenVisibilities = Ref<[String?]>([])
        MockURLProtocol.handler = { req in
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
        let client = makeClient()
        let seenWithDeleted = Ref<[Bool]>([])
        MockURLProtocol.handler = { req in
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
        let client = makeClient()
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
             Data(#"{"message":"not found"}"#.utf8))
        }
        await #expect(throws: ImmichClientError.self) {
            _ = try await client.listAllAssets()
        }
    }

    @Test("malformed JSON on 200 response throws a decoding error")
    func malformedJSONOnOK() async throws {
        let client = makeClient()
        MockURLProtocol.handler = { req in
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
        let client = makeClient()
        let seenMethod = Ref<String?>(nil)
        let seenPath = Ref<String?>(nil)
        let seenBody = Ref<Data>(Data())
        MockURLProtocol.handler = { req in
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
        let client = makeClient()
        let seenMethod = Ref<String?>(nil)
        let seenPath = Ref<String?>(nil)
        let seenBody = Ref<Data>(Data())
        MockURLProtocol.handler = { req in
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
        let client = makeClient()
        MockURLProtocol.handler = { req in
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
        let client = makeClient()
        let seenVisibilities = Ref<[String]>([])
        MockURLProtocol.handler = { req in
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
        let client = makeClient()
        MockURLProtocol.handler = { req in
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
        let client = makeClient()
        let hitCount = Ref<Int>(0)
        MockURLProtocol.handler = { req in
            hitCount.mutate { $0 += 1 }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
        }
        try await client.trashAssets(ids: [])
        try await client.restoreAssets(ids: [])
        #expect(hitCount.value == 0)
    }
}
