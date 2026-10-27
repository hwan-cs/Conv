import Testing
@testable import Platform

@Suite struct PlatformTests {
    @Test func moduleLinks() {
        #expect(Bool(true))
    }
}
