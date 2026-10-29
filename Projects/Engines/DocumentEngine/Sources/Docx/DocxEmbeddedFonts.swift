import Foundation

/// Fonts embedded in the .docx (word/fonts/*.odttf), turned into `@font-face` rules so the
/// document renders in the faces it was written with.
struct DocxEmbeddedFonts {
    private struct Face {
        var family: String
        var bold: Bool
        var italic: Bool
        var data: Data
    }

    private var faces: [Face] = []
    /// Family → Word's "single" line height in em, from the font's OS/2 win metrics.
    private(set) var singleLineHeights: [String: Double] = [:]

    init(package: DocxPackage) {
        guard let path = try? package.partPath(ofType: "fontTable"),
              let table = try? package.xml(at: path),
              let relationships = try? package.relationships(forPart: path) else { return }
        for font in table.children("font") {
            guard let family = font.value("name") else { continue }
            for (element, bold, italic) in [("embedRegular", false, false), ("embedBold", true, false),
                                             ("embedItalic", false, true), ("embedBoldItalic", true, true)] {
                guard let embed = font.child(element),
                      let id = embed.value("id", in: OOXMLNamespace.r),
                      let target = relationships[id],
                      let obfuscated = try? package.data(at: target) else { continue }
                let data = Self.deobfuscate(obfuscated, key: embed.value("fontKey"))
                faces.append(Face(family: family, bold: bold, italic: italic, data: data))
                if singleLineHeights[family] == nil {
                    singleLineHeights[family] = Self.winLineHeight(data)
                }
            }
        }
    }

    var css: String {
        faces.map { face in
            let family = face.family.replacingOccurrences(of: "'", with: "")
            return "@font-face { font-family: '\(family)'; src: url(data:font/ttf;base64,\(face.data.base64EncodedString()));"
                + " font-weight: \(face.bold ? "bold" : "normal"); font-style: \(face.italic ? "italic" : "normal"); }"
        }.joined(separator: "\n")
    }

    /// ECMA-376 obfuscation: the first 32 bytes are XORed with the GUID font key, bytes reversed.
    static func deobfuscate(_ data: Data, key: String?) -> Data {
        let hex = (key ?? "").filter(\.isHexDigit)
        guard hex.count == 32, data.count >= 32 else { return data }
        let keyBytes = stride(from: 0, to: 32, by: 2).map { offset -> UInt8 in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16) ?? 0
        }.reversed() as [UInt8]
        var bytes = [UInt8](data)
        for index in 0..<32 {
            bytes[index] ^= keyBytes[index % 16]
        }
        return Data(bytes)
    }

    /// (usWinAscent + usWinDescent) / unitsPerEm, which is what Word uses for single spacing.
    static func winLineHeight(_ data: Data) -> Double? {
        let bytes = [UInt8](data)
        func uint16(_ offset: Int) -> Int? {
            offset + 2 <= bytes.count ? Int(bytes[offset]) << 8 | Int(bytes[offset + 1]) : nil
        }
        func uint32(_ offset: Int) -> Int? {
            guard let high = uint16(offset), let low = uint16(offset + 2) else { return nil }
            return high << 16 | low
        }
        guard let tableCount = uint16(4) else { return nil }
        var tables: [String: Int] = [:]
        for index in 0..<tableCount {
            let record = 12 + index * 16
            guard record + 16 <= bytes.count, let offset = uint32(record + 8) else { return nil }
            tables[String(decoding: bytes[record..<record + 4], as: UTF8.self)] = offset
        }
        guard let head = tables["head"], let os2 = tables["OS/2"],
              let unitsPerEm = uint16(head + 18), unitsPerEm > 0,
              let ascent = uint16(os2 + 74), let descent = uint16(os2 + 76) else { return nil }
        return Double(ascent + descent) / Double(unitsPerEm)
    }
}
