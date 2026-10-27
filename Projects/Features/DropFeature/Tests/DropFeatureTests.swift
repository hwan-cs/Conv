import Testing
@testable import DropFeature

@Suite struct DropFeatureTests {
    @Test func moduleLinks() {
        #expect(Bool(true))
    }
}
