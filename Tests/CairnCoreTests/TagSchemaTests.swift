import Testing
@testable import CairnCore

@Suite("TagSchema")
struct TagSchemaTests {
    @Test("runTagValue produces the canonical v1 shape")
    func runTagValueShape() {
        #expect(TagSchema.runTagValue(runId: "abc") == "cairn/v1/run/abc")
    }

    @Test("runId round-trips through runTagValue → runId")
    func roundTrip() {
        let rid = "2026-04-21T00:30:52Z-18A5327F"
        let value = TagSchema.runTagValue(runId: rid)
        #expect(TagSchema.runId(fromTagValue: value) == rid)
    }

    @Test("runId returns nil for non-v1 tag values")
    func nonV1Rejected() {
        #expect(TagSchema.runId(fromTagValue: "cairn/run/abc") == nil)
        #expect(TagSchema.runId(fromTagValue: "cairn/v2/run/abc") == nil)
        #expect(TagSchema.runId(fromTagValue: "other-tag") == nil)
        #expect(TagSchema.runId(fromTagValue: "cairn/v1/run/") == nil)
        #expect(TagSchema.runId(fromTagValue: "") == nil)
    }

    @Test("trailing slash is tolerated")
    func trailingSlashTolerated() {
        #expect(TagSchema.runId(fromTagValue: "cairn/v1/run/abc/") == "abc")
    }
}
