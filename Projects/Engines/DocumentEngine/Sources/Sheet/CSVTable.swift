import Foundation

/// A CSV file's rows, read in whatever encoding and separator it was saved with, and written the
/// way Excel opens it without breaking Hangul: UTF-8 with a byte order mark.
struct CSVTable: Equatable {
    enum ReadError: Error {
        case unreadable
    }

    var rows: [[String]]

    init(rows: [[String]]) {
        self.rows = rows
    }

    init(contentsOf url: URL) throws {
        guard let data = try? Data(contentsOf: url) else {
            throw ReadError.unreadable
        }
        var text = Self.decode(data)
        // Excel's "sep=;" first line.
        if let hint = Self.separatorHint(in: text) {
            text = String(text.drop { !$0.isNewline }.dropFirst())
            rows = Self.parse(text, separator: hint)
            return
        }
        rows = Self.parse(
            text,
            separator: Self.separator(in: text)
        )
    }

    private static func separatorHint(in text: String) -> Character? {
        let first = text.prefix { !$0.isNewline }
        guard first.count == 5, first.lowercased().hasPrefix("sep="), let separator = first.last else {
            return nil
        }
        return separator
    }

    /// UTF-8 with a BOM and CRLF line ends, fields quoted only where they must be.
    func data(separator: Character = ",") -> Data {
        var text = "\u{FEFF}"
        for row in rows {
            text += row
                .map { Self.quoted($0, separator: separator) }
                .joined(separator: String(separator))
            text += "\r\n"
        }
        return Data(text.utf8)
    }

    /// Windows' Korean code page, a superset of EUC-KR: what Excel on a Korean PC saves CSV in.
    static let windowsKorean = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.dosKorean.rawValue)
        )
    )

    /// UTF-8 or UTF-16 when the bytes say so, then Korean, then Western Windows text.
    static func decode(_ data: Data) -> String {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(
                decoding: data.dropFirst(3),
                as: UTF8.self
            )
        }
        var candidates: [String.Encoding] = [.utf8, windowsKorean, .windowsCP1252]
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            candidates.insert(.utf16, at: 0)
        } else if let encoding = utf16WithoutBOM(data) {
            candidates.insert(encoding, at: 0)
        }
        for encoding in candidates {
            if let text = String(data: data, encoding: encoding) {
                return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
            }
        }
        return String(
            decoding: data,
            as: UTF8.self
        )
    }

    /// UTF-16 without a byte order mark, told by the zero bytes padding its ASCII.
    private static func utf16WithoutBOM(_ data: Data) -> String.Encoding? {
        let sample = data.prefix(4096)
        guard sample.count >= 4, sample.count % 2 == 0 else {
            return nil
        }
        let pairs = sample.count / 2
        let start = sample.startIndex
        let evenZeros = stride(from: 0, to: sample.count, by: 2).filter { sample[start + $0] == 0 }.count
        let oddZeros = stride(from: 1, to: sample.count, by: 2).filter { sample[start + $0] == 0 }.count
        if oddZeros * 2 > pairs, evenZeros * 10 < pairs {
            return .utf16LittleEndian
        }
        if evenZeros * 2 > pairs, oddZeros * 10 < pairs {
            return .utf16BigEndian
        }
        return nil
    }

    /// The separator that splits the first lines most evenly: comma, tab or semicolon.
    static func separator(in text: String) -> Character {
        let lines = text
            .prefix(65_536)
            .split(whereSeparator: \.isNewline)
            .prefix(10)
        let candidates: [Character] = [",", "\t", ";"]
        guard !lines.isEmpty else {
            return ","
        }
        // A separator on every line counts by its fewest uses; one missing from a line counts zero.
        let scores = candidates.map { candidate in
            lines
                .map { count(candidate, outsideQuotesIn: $0) }
                .min() ?? 0
        }
        guard let best = scores.indices.max(by: { scores[$0] < scores[$1] }), scores[best] > 0 else {
            return ","
        }
        return candidates[best]
    }

    /// RFC 4180, leniently: quotes only open a field at its start, and any line end ends a row.
    static func parse(_ text: String, separator: Character) -> [[String]] {
        let scalars = text.unicodeScalars
        let separator = separator.unicodeScalars.first ?? ","
        var rows: [[String]] = []
        var row: [String] = []
        var field = String.UnicodeScalarView()
        var fieldStarted = false
        var inQuotes = false
        var index = scalars.startIndex

        func endField() {
            row.append(String(field))
            field = String.UnicodeScalarView()
            fieldStarted = false
        }

        func endRow() {
            endField()
            rows.append(row)
            row = []
        }

        while index < scalars.endIndex {
            let scalar = scalars[index]
            let next = scalars.index(after: index)
            if inQuotes {
                if scalar == "\"" {
                    if next < scalars.endIndex, scalars[next] == "\"" {
                        field.append("\"")
                        index = scalars.index(after: next)
                        continue
                    }
                    inQuotes = false
                } else {
                    field.append(scalar)
                }
            } else {
                switch scalar {
                case "\"" where !fieldStarted:
                    inQuotes = true
                    fieldStarted = true
                case separator:
                    endField()
                case "\r":
                    endRow()
                    if next < scalars.endIndex, scalars[next] == "\n" {
                        index = scalars.index(after: next)
                        continue
                    }
                case "\n":
                    endRow()
                default:
                    field.append(scalar)
                    fieldStarted = true
                }
            }
            index = next
        }
        if fieldStarted || !row.isEmpty {
            endRow()
        }
        return rows
    }

    private static func count(_ separator: Character, outsideQuotesIn line: Substring) -> Int {
        var count = 0
        var inQuotes = false
        for character in line {
            if character == "\"" {
                inQuotes.toggle()
            } else if character == separator, !inQuotes {
                count += 1
            }
        }
        return count
    }

    private static func quoted(_ field: String, separator: Character) -> String {
        let needsQuotes = field.contains { character in
            character == separator || character == "\"" || character.isNewline
        }
        guard needsQuotes else {
            return field
        }
        let escaped = field.replacingOccurrences(
            of: "\"",
            with: "\"\""
        )
        return "\"\(escaped)\""
    }
}
