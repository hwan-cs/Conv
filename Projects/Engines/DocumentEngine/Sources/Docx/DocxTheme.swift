import Foundation

/// theme1.xml: the fonts behind `w:asciiTheme="minorHAnsi"` and the colors behind `schemeClr`.
struct DocxTheme {
    private struct FontPair {
        var latin: String?
        var eastAsia: String?
    }

    private var minor = FontPair()
    private var major = FontPair()
    private var colors: [String: String] = [:]

    init(_ root: XMLElement?) {
        guard let themeElements = root?.child("themeElements", in: OOXMLNamespace.a) else { return }
        if let fonts = themeElements.child("fontScheme", in: OOXMLNamespace.a) {
            minor = Self.fonts(fonts.child("minorFont", in: OOXMLNamespace.a))
            major = Self.fonts(fonts.child("majorFont", in: OOXMLNamespace.a))
        }
        for color in themeElements.child("clrScheme", in: OOXMLNamespace.a)?.elements ?? [] {
            let value = color.child("srgbClr", in: OOXMLNamespace.a)?.attribute(forName: "val")?.stringValue
                ?? color.child("sysClr", in: OOXMLNamespace.a)?.attribute(forName: "lastClr")?.stringValue
            if let name = color.localName, let value {
                colors[name] = "#\(value)"
            }
        }
    }

    /// Resolves a `+minorHAnsi`-style token written by `RunFormat`; other names pass through.
    func font(_ name: String?) -> String? {
        guard let name, name.hasPrefix("+") else { return name }
        let pair = name.dropFirst().hasPrefix("major") ? major : minor
        return name.hasSuffix("EastAsia") ? (pair.eastAsia ?? pair.latin) : (pair.latin ?? pair.eastAsia)
    }

    /// `schemeClr` values, including the tx/bg aliases for dk/lt.
    func color(_ scheme: String) -> String? {
        let aliases = ["tx1": "dk1", "bg1": "lt1", "tx2": "dk2", "bg2": "lt2"]
        return colors[aliases[scheme] ?? scheme]
    }

    private static func fonts(_ element: XMLElement?) -> FontPair {
        func typeface(_ child: XMLElement?) -> String? {
            child?.attribute(forName: "typeface")?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        }
        let hangul = element?.children("font", in: OOXMLNamespace.a)
            .first { $0.attribute(forName: "script")?.stringValue == "Hang" }
        return FontPair(
            latin: typeface(element?.child("latin", in: OOXMLNamespace.a)),
            // Korean documents leave <a:ea> empty and name the Hangul face per script.
            eastAsia: typeface(element?.child("ea", in: OOXMLNamespace.a)) ?? typeface(hangul)
        )
    }
}
