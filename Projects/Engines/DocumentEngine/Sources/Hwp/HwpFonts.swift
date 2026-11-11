import CoreText
import Foundation

/// Chooses a macOS face for each HWP face name, and the spacing that makes it advance like
/// the face Hangul would have used, so lines break where Hangul breaks them.
///
/// Hangul (and its Mac viewer) draws missing faces with its own 함초롬 faces; Korean system
/// faces like 굴림 and 바탕 are full-width. macOS has neither, and its Korean faces are narrower.
enum HwpFonts {
    struct Advances {
        var hangul: Double
        var latin: Double
        var space: Double
    }

    struct Choice {
        var family: String
        var target: Advances
        var actual: Advances
        var bundled: Bundled?
    }

    /// Nanum Gothic and Myeongjo (SIL OFL), shipped in the engine's resources. They are named
    /// "Conv …" in pages so a different installed version can't take their place.
    enum Bundled: String, CaseIterable, Sendable {
        case gothic = "NanumGothic"
        case myeongjo = "NanumMyeongjo"

        var cssFamily: String { self == .gothic ? "Conv Nanum Gothic" : "Conv Nanum Myeongjo" }

        func url(bold: Bool) -> URL? {
            Bundle.module.url(forResource: "\(rawValue)-\(bold ? "Bold" : "Regular")", withExtension: "ttf", subdirectory: "Fonts")
                ?? Bundle.module.url(forResource: "\(rawValue)-\(bold ? "Bold" : "Regular")", withExtension: "ttf")
        }

        /// `@font-face` rules with the faces inline: WebKit lays pages out in another process, which doesn't see fonts registered in this one.
        var fontFaces: String {
            [false, true].compactMap { bold -> String? in
                guard let url = url(bold: bold), let data = try? Data(contentsOf: url) else {
                    return nil
                }
                return "@font-face { font-family: '\(cssFamily)'; font-weight: \(bold ? 700 : 400); src: url(data:font/ttf;base64,\(data.base64EncodedString())) format('truetype'); }"
            }.joined(separator: "\n")
        }
    }

    /// Makes the bundled faces available to CoreText here, for measuring. Safe to call repeatedly.
    static func registerBundled() {
        _ = registration
    }

    private static let registration: Void = {
        for face in Bundled.allCases {
            for bold in [false, true] {
                if let url = face.url(bold: bold) {
                    CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
                }
            }
        }
    }()

    // Measured with CoreText at 100pt.
    static let hamchoromDotum = Advances(hangul: 0.97, latin: 0.494, space: 0.3)
    static let hamchoromBatang = Advances(hangul: 0.97, latin: 0.508, space: 0.3)
    static let fullWidth = Advances(hangul: 1.0, latin: 0.5, space: 0.333)

    static let systemSerif = "AppleMyungjo"
    static let systemSans = "Apple SD Gothic Neo"

    private static let serifHints = ["바탕", "명조", "Batang", "Myeongjo", "Myungjo", "신명", "궁서", "Gungsuh", "Times", "Serif", "serif", "필기", "펜"]
    private static let fullWidthHints = ["굴림", "돋움", "바탕", "궁서", "Gulim", "Dotum", "Batang", "Gungsuh"]

    private static let cache = Cache()

    static func choice(for font: HwpDocument.Font?) -> Choice {
        registerBundled()
        let names = [font?.name, font?.fallback].compactMap { $0 }
        let key = names.joined(separator: "|")
        if let cached = cache.value(for: key) {
            return cached
        }
        let result = resolve(names)
        cache.store(result, for: key)
        return result
    }

    private static func resolve(_ names: [String]) -> Choice {
        let matches = { (hints: [String]) in names.contains { name in hints.contains { name.localizedCaseInsensitiveContains($0) } } }
        let serif = matches(serifHints)
        let quoted = names.map { "'\($0.replacingOccurrences(of: "'", with: ""))'" }

        // A face that is installed is the real thing and needs no correction.
        if let installed = names.first(where: isInstalled) {
            let advances = measure(installed)
            return Choice(family: (quoted + [serif ? "serif" : "sans-serif"]).joined(separator: ","), target: advances, actual: advances)
        }
        let target = matches(fullWidthHints) ? fullWidth : serif ? hamchoromBatang : hamchoromDotum
        let bundled: Bundled = serif ? .myeongjo : .gothic
        let system = serif ? systemSerif : systemSans
        if bundled.url(bold: false) != nil, isRegistered(postScriptName: bundled.rawValue) {
            return Choice(
                family: "'\(bundled.cssFamily)','\(system)',\(serif ? "serif" : "sans-serif")",
                target: target,
                actual: measure(bundled.rawValue),
                bundled: bundled
            )
        }
        return Choice(family: "'\(system)',\(serif ? "serif" : "sans-serif")", target: target, actual: measure(system))
    }

    private static func isRegistered(postScriptName name: String) -> Bool {
        CTFontCopyPostScriptName(CTFontCreateWithName(name as CFString, 12, nil)) as String == name
    }

    private static func isInstalled(_ name: String) -> Bool {
        let font = CTFontCreateWithName(name as CFString, 12, nil)
        let family = CTFontCopyFamilyName(font) as String
        let localized = CTFontCopyLocalizedName(font, kCTFontFamilyNameKey, nil).map { $0 as String }
        return family.caseInsensitiveCompare(name) == .orderedSame
            || localized?.caseInsensitiveCompare(name) == .orderedSame
    }

    private static func measure(_ name: String) -> Advances {
        let font = CTFontCreateWithName(name as CFString, 100, nil)
        func average(_ text: String) -> Double {
            let units = Array(text.utf16)
            var glyphs = [CGGlyph](repeating: 0, count: units.count)
            CTFontGetGlyphsForCharacters(font, units, &glyphs, units.count)
            var advances = [CGSize](repeating: .zero, count: units.count)
            return CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, units.count) / Double(units.count) / 100
        }
        return Advances(hangul: average("가나다라마바사"), latin: average("The quick brown fox jumps over the lazy dog 0123456789"), space: average(" "))
    }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var choices: [String: Choice] = [:]

        func value(for key: String) -> Choice? {
            lock.withLock { choices[key] }
        }
        func store(_ choice: Choice, for key: String) {
            lock.withLock { choices[key] = choice }
        }
    }
}
