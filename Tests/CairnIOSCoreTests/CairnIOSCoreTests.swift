import Testing
@testable import CairnIOSCore

@Suite("CairnIOSCore module sanity")
struct CairnIOSCoreSanityTests {
    @Test("module is reachable and the umbrella enum compiles")
    func sanity() {
        _ = CairnIOSCore.self
    }
}
