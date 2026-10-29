import Foundation

/// numbering.xml, plus the running counters. Word draws list labels itself rather than
/// using HTML-like lists, so labels are computed here and written as text.
struct DocxNumbering {
    struct Level {
        var format = "decimal"
        var text = "%1."
        var start = 1
        var paragraph = ParagraphFormat()
        var run = RunFormat()
    }

    private var levelsByNumID: [String: [Int: Level]] = [:]
    private var counters: [String: [Int: Int]] = [:]

    init(_ root: XMLElement?) {
        guard let root else { return }
        var abstract: [String: [Int: Level]] = [:]
        for element in root.children("abstractNum") {
            guard let id = element.value("abstractNumId") else { continue }
            abstract[id] = Self.levels(element)
        }
        for num in root.children("num") {
            guard let id = num.value("numId"),
                  let abstractID = num.child("abstractNumId")?.value(),
                  var levels = abstract[abstractID] else { continue }
            for override in num.children("lvlOverride") {
                guard let index = override.value("ilvl").flatMap(Int.init) else { continue }
                if let start = override.child("startOverride")?.number() {
                    levels[index, default: Level()].start = Int(start)
                }
                if let level = override.child("lvl") {
                    levels[index] = Self.level(level)
                }
            }
            levelsByNumID[id] = levels
        }
    }

    func level(_ reference: ParagraphFormat.NumberingReference) -> Level? {
        levelsByNumID[reference.numID]?[reference.level]
    }

    /// Advances the counter for this list item and returns its label, e.g. "2.3." or "•".
    mutating func nextLabel(_ reference: ParagraphFormat.NumberingReference) -> String? {
        // numId 0 means "numbering removed".
        guard reference.numID != "0", let levels = levelsByNumID[reference.numID],
              let level = levels[reference.level] else { return nil }
        var counts = counters[reference.numID, default: [:]]
        counts[reference.level] = (counts[reference.level] ?? (level.start - 1)) + 1
        for deeper in counts.keys where deeper > reference.level {
            counts[deeper] = nil
        }
        counters[reference.numID] = counts

        if level.format == "bullet" {
            return Self.bullet(level.text)
        }
        var label = level.text
        for index in (0...reference.level).reversed() {
            let value = counts[index] ?? levels[index]?.start ?? 1
            let format = levels[index]?.format ?? "decimal"
            label = label.replacingOccurrences(of: "%\(index + 1)", with: Self.render(value, as: format))
        }
        return label
    }

    private static func levels(_ abstractNum: XMLElement) -> [Int: Level] {
        var result: [Int: Level] = [:]
        for element in abstractNum.children("lvl") {
            guard let index = element.value("ilvl").flatMap(Int.init) else { continue }
            result[index] = level(element)
        }
        return result
    }

    private static func level(_ element: XMLElement) -> Level {
        var level = Level()
        level.format = element.child("numFmt")?.value() ?? level.format
        level.text = element.child("lvlText")?.value() ?? ""
        level.start = element.child("start")?.number().map(Int.init) ?? 1
        level.paragraph = ParagraphFormat(element.child("pPr"))
        level.run = RunFormat(element.child("rPr"))
        return level
    }

    /// Word bullets are often private-use glyphs from the Symbol and Wingdings fonts.
    private static func bullet(_ text: String) -> String {
        guard let scalar = text.unicodeScalars.first else { return "•" }
        switch scalar.value {
        case 0xF0A7, 0xF06E: return "▪"
        case 0xF0D8: return "➢"
        case 0xF0FC: return "✓"
        case 0xF000...0xF0FF: return "•"
        default: return text == "o" ? "◦" : text
        }
    }

    static func render(_ value: Int, as format: String) -> String {
        switch format {
        case "lowerLetter": letters(value).lowercased()
        case "upperLetter": letters(value)
        case "lowerRoman": roman(value).lowercased()
        case "upperRoman": roman(value)
        case "ganada": korean(value, from: ["가", "나", "다", "라", "마", "바", "사", "아", "자", "차", "카", "타", "파", "하"])
        case "chosung": korean(value, from: ["ㄱ", "ㄴ", "ㄷ", "ㄹ", "ㅁ", "ㅂ", "ㅅ", "ㅇ", "ㅈ", "ㅊ", "ㅋ", "ㅌ", "ㅍ", "ㅎ"])
        case "decimalEnclosedCircle", "decimalEnclosedCircleChinese":
            (1...20).contains(value) ? String(UnicodeScalar(0x2460 + value - 1)!) : String(value)
        case "decimalZero": value < 10 ? "0\(value)" : String(value)
        case "none": ""
        default: String(value)
        }
    }

    private static func letters(_ value: Int) -> String {
        // Word repeats the letter: 27 → AA, 28 → BB.
        let letter = Character(UnicodeScalar(65 + (value - 1) % 26)!)
        return String(repeating: letter, count: (value - 1) / 26 + 1)
    }

    private static func roman(_ value: Int) -> String {
        let table = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
                     (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var remaining = value
        var result = ""
        for (amount, numeral) in table {
            while remaining >= amount {
                result += numeral
                remaining -= amount
            }
        }
        return result
    }

    private static func korean(_ value: Int, from symbols: [String]) -> String {
        symbols[(value - 1) % symbols.count]
    }
}
