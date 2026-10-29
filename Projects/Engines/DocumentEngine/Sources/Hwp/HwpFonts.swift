import CoreText
import Foundation

/// Chooses a macOS face for each HWP face name, and the spacing that makes it advance like
/// the face Hangul would have used, so lines break where Hangul breaks them.
///
/// Hangul (and its Mac viewer) draws missing faces with its own 함초롬 faces; Korean system
/// faces like 굴림 and 바탕 are full-width. macOS has neither, and its Korean faces are narrower.
enum HwpFonts {
    /// Average advances in em: Hangul syllables, Latin text, and the space.
    struct Advances {
        var hangul: Double
        var latin: Double
        var space: Double
    }

    struct Choice {
        var family: String
        /// How the face Hangul would use advances, and how the chosen face does.
        var target: Advances
        var actual: Advances
    }

    // Measured with CoreText at 100pt.
    static let hamchoromDotum = Advances(hangul: 0.97, latin: 0.494, space: 0.3)
    static let hamchoromBatang = Advances(hangul: 0.97, latin: 0.508, space: 0.3)
    static let fullWidth = Advances(hangul: 1.0, latin: 0.5, space: 0.333)

    /// Stand-ins, best first. Nanum's widths are closest to 함초롬's, and its serif has a bold;
    /// WebKit fakes AppleMyungjo's bold by drawing text several times, which repeats it in the PDF's text.
    static let serifStandIns = ["Nanum Myeongjo", "AppleMyungjo"]
    static let sansStandIns = ["Nanum Gothic", "Apple SD Gothic Neo"]

    private static let serifHints = ["바탕", "명조", "Batang", "Myeongjo", "Myungjo", "신명", "궁서", "Gungsuh", "Times", "Serif", "serif", "필기", "펜"]
    /// Windows' classic Korean faces, whose Hangul is a full em wide.
    private static let fullWidthHints = ["굴림", "돋움", "바탕", "궁서", "Gulim", "Dotum", "Batang", "Gungsuh"]

    private static let cache = Cache()

    static func choice(for font: HwpDocument.Font?) -> Choice {
        let names = [font?.name, font?.fallback].compactMap { $0 }
        let key = names.joined(separator: "|")
        if let cached = cache.value(for: key) { return cached }
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
        let candidates = serif ? serifStandIns : sansStandIns
        let standIn = candidates.first(where: isInstalled) ?? candidates[candidates.count - 1]
        return Choice(
            family: "'\(standIn)',\(serif ? "serif" : "sans-serif")",
            target: matches(fullWidthHints) ? fullWidth : serif ? hamchoromBatang : hamchoromDotum,
            actual: measure(standIn)
        )
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

        func value(for key: String) -> Choice? { lock.withLock { choices[key] } }
        func store(_ choice: Choice, for key: String) { lock.withLock { choices[key] = choice } }
    }
}
