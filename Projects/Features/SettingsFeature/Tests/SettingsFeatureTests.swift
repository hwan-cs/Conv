import Testing
@testable import SettingsFeature

@Suite struct OpenSourceLicenseTests {
    @Test(arguments: OpenSourceLicense.all)
    func textShipsWithTheApp(license: OpenSourceLicense) {
        #expect(license.text.count > 500, "\(license.name)'s license text is missing")
    }

    @Test func lameIsUnderTheLGPLWithReplacementTerms() throws {
        let lame = try #require(OpenSourceLicense.all.first { $0.name.hasPrefix("LAME") })
        #expect(lame.text.contains("GNU LIBRARY GENERAL PUBLIC LICENSE"))
        #expect(lame.note?.contains("libmp3lame.dylib") == true)
    }
}
