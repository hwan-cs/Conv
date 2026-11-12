import Foundation
import ZIPFoundation

/// Rows of text → a one-sheet .xlsx. Plain numbers become numbers so they add up; anything a
/// number would change, such as leading zeros, phone numbers or long IDs, stays text as written.
struct XLSXWriter {
    enum WriteError: Error {
        case tooLarge
    }

    static let maxRows = 1_048_576
    static let maxColumns = 16_384

    let rows: [[String]]
    let sheetName: String

    func write(to url: URL) throws {
        let tooLarge = rows.count > Self.maxRows || rows.contains { $0.count > Self.maxColumns }
        guard !tooLarge else {
            throw WriteError.tooLarge
        }

        var strings: [String] = []
        var stringIndex: [String: Int] = [:]
        var widths: [Int] = []
        var sheetData = ""
        for (rowIndex, row) in rows.enumerated() {
            var cells = ""
            for (column, value) in row.enumerated() where !value.isEmpty {
                let reference = Self.columnName(column) + String(rowIndex + 1)
                if Self.isNumber(value) {
                    cells += "<c r=\"\(reference)\"><v>\(value)</v></c>"
                } else {
                    let index: Int
                    if let known = stringIndex[value] {
                        index = known
                    } else {
                        index = strings.count
                        strings.append(value)
                        stringIndex[value] = index
                    }
                    // Line breaks only show in a cell that wraps.
                    let style = value.contains(where: \.isNewline) ? " s=\"1\"" : ""
                    cells += "<c r=\"\(reference)\" t=\"s\"\(style)><v>\(index)</v></c>"
                }
                if widths.count <= column {
                    widths += Array(
                        repeating: 0,
                        count: column + 1 - widths.count
                    )
                }
                widths[column] = max(
                    widths[column],
                    Self.displayWidth(value)
                )
            }
            if !cells.isEmpty {
                sheetData += "<row r=\"\(rowIndex + 1)\">\(cells)</row>"
            }
        }

        let columns = widths.enumerated().map { column, width in
            let characters = min(max(Double(width) + 2, 8.43), 60)
            return "<col min=\"\(column + 1)\" max=\"\(column + 1)\" width=\"\(characters)\" customWidth=\"1\"/>"
        }
        let cols = columns.isEmpty ? "" : "<cols>\(columns.joined())</cols>"
        let sharedStrings = strings
            .map { "<si><t xml:space=\"preserve\">\(HwpDocxWriter.escape($0))</t></si>" }
            .joined()

        let parts: [(path: String, xml: String)] = [
            (
                "[Content_Types].xml",
                """
                <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
                <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
                <Default Extension="xml" ContentType="application/xml"/>\
                <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
                <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>\
                <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\
                <Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>\
                </Types>
                """
            ),
            (
                "_rels/.rels",
                """
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
                <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>\
                </Relationships>
                """
            ),
            (
                "xl/workbook.xml",
                """
                <workbook xmlns="\(SpreadsheetNamespace.main)" xmlns:r="\(OOXMLNamespace.r)">\
                <sheets><sheet name="\(HwpDocxWriter.escape(Self.validSheetName(sheetName)))" sheetId="1" r:id="rId1"/></sheets>\
                </workbook>
                """
            ),
            (
                "xl/_rels/workbook.xml.rels",
                """
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
                <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>\
                <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\
                <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>\
                </Relationships>
                """
            ),
            (
                "xl/worksheets/sheet1.xml",
                "<worksheet xmlns=\"\(SpreadsheetNamespace.main)\">\(cols)<sheetData>\(sheetData)</sheetData></worksheet>"
            ),
            (
                "xl/styles.xml",
                Self.styles
            ),
            (
                "xl/sharedStrings.xml",
                "<sst xmlns=\"\(SpreadsheetNamespace.main)\" count=\"\(strings.count)\" uniqueCount=\"\(strings.count)\">\(sharedStrings)</sst>"
            ),
        ]

        try? FileManager.default.removeItem(at: url)
        let archive = try Archive(
            url: url,
            accessMode: .create
        )
        for part in parts {
            let data = Data("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\(part.xml)".utf8)
            try archive.addEntry(
                with: part.path,
                type: .file,
                uncompressedSize: Int64(data.count),
                compressionMethod: .deflate
            ) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        }
    }

    /// The default style, and one that wraps for cells with line breaks.
    private static let styles = """
        <styleSheet xmlns="\(SpreadsheetNamespace.main)">\
        <fonts count="1"><font><sz val="11"/><name val="맑은 고딕"/><family val="2"/><charset val="129"/></font></fonts>\
        <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>\
        <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>\
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
        <cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>\
        <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyAlignment="1"><alignment wrapText="1" vertical="top"/></xf></cellXfs>\
        <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>\
        </styleSheet>
        """

    /// A number Excel would store exactly and show the same way: no leading zeros, signs other
    /// than minus, exponents or more than 15 significant digits.
    static func isNumber(_ text: String) -> Bool {
        guard text.wholeMatch(of: /-?(0|[1-9][0-9]*)(\.[0-9]+)?/) != nil else {
            return false
        }
        let significant = text
            .filter(\.isNumber)
            .drop { $0 == "0" }
        return significant.count <= 15
    }

    /// 0 → "A", 25 → "Z", 26 → "AA".
    static func columnName(_ index: Int) -> String {
        var name = ""
        var remaining = index + 1
        while remaining > 0 {
            let letter = (remaining - 1) % 26
            name = String(UnicodeScalar(UInt8(65 + letter))) + name
            remaining = (remaining - 1) / 26
        }
        return name
    }

    /// Sheet names are at most 31 characters, without `[ ] : * ? / \`.
    static func validSheetName(_ name: String) -> String {
        let cleaned = name
            .filter { !"[]:*?/\\".contains($0) }
            .trimmingCharacters(in: .whitespaces)
        let short = String(cleaned.prefix(31))
        return short.isEmpty ? "Sheet1" : short
    }

    /// The longest line in character widths, where Hangul and other wide characters count two.
    private static func displayWidth(_ text: String) -> Int {
        text
            .split(whereSeparator: \.isNewline)
            .map { line in
                line.unicodeScalars.reduce(0) { width, scalar in
                    width + (isWide(scalar) ? 2 : 1)
                }
            }
            .max() ?? 0
    }

    private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6:
            true
        default:
            false
        }
    }
}

enum SpreadsheetNamespace {
    static let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
}
