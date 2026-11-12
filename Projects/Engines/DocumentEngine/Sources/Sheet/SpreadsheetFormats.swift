import Foundation

/// Excel's number formats, applied the way a cell shows its value: dates and times, elapsed
/// time, percentages, thousands separators, fixed decimals, leading zeros and currency signs.
/// Colors and conditions in brackets, fractions and fill characters are left out.
struct NumberFormats {
    private enum Token: Equatable {
        case literal(String)
        /// A run of `0 # ? . , % E+` characters.
        case number(String)
        /// A run of one date letter, lowercased, or "am/pm" and "a/p".
        case date(String)
        /// `[h]`, `[mm]` or `[ss]`: time counted past a day.
        case elapsed(String)
        case general
        case text
    }

    private let codes: [Int: String]
    private let date1904: Bool
    private let cache = FormatterCache()

    init(_ stylesheet: XMLElement?, date1904: Bool) {
        var codes = Self.builtIn
        for format in stylesheet?.sml("numFmts")?.smlChildren("numFmt") ?? [] {
            if let id = format.attributeValue("numFmtId").flatMap(Int.init),
               let code = format.attributeValue("formatCode") {
                codes[id] = code
            }
        }
        self.codes = codes
        self.date1904 = date1904
    }

    /// The codes Excel doesn't write into the file. Short dates follow the Korean locale's order.
    static let builtIn: [Int: String] = {
        var codes: [Int: String] = [
            1: "0",
            2: "0.00",
            3: "#,##0",
            4: "#,##0.00",
            9: "0%",
            10: "0.00%",
            11: "0.00E+00",
            14: "yyyy-mm-dd",
            15: "d-mmm-yy",
            16: "d-mmm",
            17: "mmm-yy",
            18: "h:mm AM/PM",
            19: "h:mm:ss AM/PM",
            20: "h:mm",
            21: "h:mm:ss",
            22: "yyyy-mm-dd h:mm",
            37: "#,##0 ;(#,##0)",
            38: "#,##0 ;(#,##0)",
            39: "#,##0.00;(#,##0.00)",
            40: "#,##0.00;(#,##0.00)",
            45: "mm:ss",
            46: "[h]:mm:ss",
            47: "mm:ss.0",
            48: "##0.0E+0",
            49: "@",
        ]
        // East Asian built-in dates.
        for id in Array(27...36) + Array(50...58) {
            codes[id] = "yyyy-mm-dd"
        }
        return codes
    }()

    func text(for value: Double, format: Int) -> String {
        guard let code = codes[format] else {
            return Self.general(value)
        }
        return text(
            for: value,
            code: code
        )
    }

    /// The value shown with a format code, as a chart's axis or data labels give one.
    func text(for value: Double, code: String) -> String {
        let sections = Self.sections(code)
        var section = sections[0]
        var number = value
        var sign = ""
        if value < 0 {
            // A negative section writes its own sign or parentheses.
            if sections.count > 1 {
                section = sections[1]
            } else {
                sign = "-"
            }
            number = -value
        } else if value == 0, sections.count > 2 {
            section = sections[2]
        }

        let tokens = Self.tokens(section)
        let isDate = tokens.contains { token in
            switch token {
            case .date, .elapsed:
                true
            default:
                false
            }
        }
        if isDate {
            let korean = code.contains("[$-412]") || code.lowercased().contains("[$-ko")
            return date(
                value,
                tokens: tokens,
                korean: korean
            ) ?? Self.general(value)
        }
        let placeholders = tokens.compactMap { token -> String? in
            if case .number(let run) = token {
                return run
            }
            return nil
        }.joined()
        guard !placeholders.isEmpty, !tokens.contains(.general), !tokens.contains(.text) else {
            let literal = tokens.compactMap { token -> String? in
                if case .literal(let text) = token {
                    return text
                }
                return nil
            }.joined()
            if tokens.contains(.general) || tokens.contains(.text) || literal.isEmpty {
                return Self.general(value)
            }
            return literal
        }

        let first = tokens.firstIndex { if case .number = $0 { true } else { false } } ?? 0
        let last = tokens.lastIndex { if case .number = $0 { true } else { false } } ?? 0
        let prefix = Self.literals(tokens[..<first])
        let suffix = Self.literals(tokens[(last + 1)...])
        return sign + prefix + formatted(number, placeholders: placeholders) + suffix
    }

    /// A General cell: whole numbers in full, others to 15 significant digits.
    static func general(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(format: "%.15G", value)
    }

    // MARK: Numbers

    private func formatted(_ value: Double, placeholders: String) -> String {
        var value = value
        let percents = placeholders.filter { $0 == "%" }.count
        value *= pow(100, Double(percents))

        if let exponent = placeholders.firstIndex(where: { $0 == "E" || $0 == "e" }) {
            let mantissa = placeholders[..<exponent]
            let decimals = mantissa
                .split(separator: ".", maxSplits: 1)
                .dropFirst()
                .first?
                .filter { "0#?".contains($0) }
                .count ?? 0
            return String(format: "%.\(decimals)E", value)
        }

        let parts = placeholders
            .filter { $0 != "%" }
            .split(
                separator: ".",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
        var integer = String(parts.first ?? "")
        let fraction = parts.count > 1 ? String(parts[1]) : ""
        // Each comma after the last digit divides by a thousand.
        var scaled = 0
        while integer.hasSuffix(",") && fraction.isEmpty {
            integer.removeLast()
            scaled += 1
        }
        value /= pow(1000, Double(scaled))

        let formatter = cache.formatter(
            minimumIntegerDigits: integer.filter { $0 == "0" }.count,
            minimumFractionDigits: fraction.filter { $0 == "0" }.count,
            maximumFractionDigits: fraction.filter { "0#?".contains($0) }.count,
            grouping: integer.contains(",")
        )
        let digits = formatter.string(from: NSNumber(value: value)) ?? Self.general(value)
        return digits + String(repeating: "%", count: percents)
    }

    // MARK: Dates

    private func date(
        _ value: Double,
        tokens: [Token],
        korean: Bool
    ) -> String? {
        guard value >= 0, value < 2_958_466 else {
            return nil
        }
        let showsFraction = tokens.contains { token in
            if case .number(let run) = token {
                return run.contains("0")
            }
            return false
        }
        let totalSeconds = showsFraction ? value * 86_400 : (value * 86_400).rounded()
        let day = Int(floor(totalSeconds / 86_400))
        let secondOfDay = totalSeconds - Double(day) * 86_400

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let base: DateComponents
        if date1904 {
            base = DateComponents(
                year: 1904,
                month: 1,
                day: 1
            )
        } else if day >= 61 {
            // Excel counts a February 29, 1900 that never was.
            base = DateComponents(
                year: 1899,
                month: 12,
                day: 30
            )
        } else {
            base = DateComponents(
                year: 1899,
                month: 12,
                day: 31
            )
        }
        guard let start = calendar.date(from: base),
              let date = calendar.date(byAdding: .day, value: day, to: start)
        else {
            return nil
        }
        let parts = calendar.dateComponents(
            [.year, .month, .day, .weekday],
            from: date
        )
        let hour = Int(secondOfDay) / 3600
        let minute = Int(secondOfDay) / 60 % 60
        let second = Int(secondOfDay) % 60
        let symbols = cache.symbols(korean: korean)
        let twelveHour = tokens.contains(.date("am/pm")) || tokens.contains(.date("a/p"))

        func padded(_ number: Int, _ width: Int) -> String {
            let text = String(number)
            return String(repeating: "0", count: max(0, width - text.count)) + text
        }

        var result = ""
        for (index, token) in tokens.enumerated() {
            switch token {
            case .literal(let text):
                result += text
            case .number(let run):
                // Fractions of a second, as in "ss.00"; otherwise separators, as in "yyyy.mm.dd".
                let digits = run.filter { $0 == "0" }.count
                guard digits > 0 else {
                    result += run
                    continue
                }
                let fraction = secondOfDay - floor(secondOfDay)
                let scaled = min(
                    Int((fraction * pow(10, Double(digits))).rounded()),
                    Int(pow(10, Double(digits))) - 1
                )
                result += (run.hasPrefix(".") ? "." : "") + padded(scaled, digits)
            case .elapsed(let unit):
                let total = Int(totalSeconds)
                switch unit.first {
                case "h":
                    result += padded(total / 3600, unit.count)
                case "m":
                    result += padded(total / 60, unit.count)
                default:
                    result += padded(total, unit.count)
                }
            case .date(let run):
                switch run.first {
                case "y":
                    let year = parts.year ?? 1900
                    result += run.count > 2 ? String(year) : padded(year % 100, 2)
                case "m":
                    if Self.isMinute(at: index, in: tokens) {
                        result += padded(minute, min(run.count, 2))
                    } else {
                        let month = (parts.month ?? 1) - 1
                        switch run.count {
                        case 1, 2:
                            result += padded(month + 1, run.count)
                        case 3:
                            result += symbols.shortMonths[month]
                        case 4:
                            result += symbols.months[month]
                        default:
                            result += String(symbols.months[month].prefix(1))
                        }
                    }
                case "d":
                    let weekday = (parts.weekday ?? 1) - 1
                    switch run.count {
                    case 1, 2:
                        result += padded(parts.day ?? 1, run.count)
                    case 3:
                        result += symbols.shortWeekdays[weekday]
                    default:
                        result += symbols.weekdays[weekday]
                    }
                case "h":
                    let shown = twelveHour ? (hour % 12 == 0 ? 12 : hour % 12) : hour
                    result += padded(shown, min(run.count, 2))
                case "s":
                    result += padded(second, min(run.count, 2))
                case "a":
                    if run == "a/p" {
                        result += hour < 12 ? "A" : "P"
                    } else {
                        result += hour < 12 ? symbols.am : symbols.pm
                    }
                default:
                    break
                }
            case .general, .text:
                break
            }
        }
        return result
    }

    /// "m" is minutes right after hours or right before seconds, and months everywhere else.
    private static func isMinute(at index: Int, in tokens: [Token]) -> Bool {
        let before = tokens[..<index].last { token in
            if case .date = token { true } else if case .elapsed = token { true } else { false }
        }
        let after = tokens[(index + 1)...].first { token in
            if case .date = token { true } else if case .elapsed = token { true } else { false }
        }
        switch before {
        case .date(let run) where run.hasPrefix("h"):
            return true
        case .elapsed(let unit) where unit.hasPrefix("h"):
            return true
        default:
            break
        }
        switch after {
        case .date(let run) where run.hasPrefix("s"):
            return true
        case .elapsed(let unit) where unit.hasPrefix("s"):
            return true
        default:
            return false
        }
    }

    // MARK: Parsing

    /// Splits at semicolons outside quotes and brackets.
    private static func sections(_ code: String) -> [String] {
        var sections: [String] = []
        var current = ""
        var inQuotes = false
        var inBrackets = false
        var escaped = false
        for character in code {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            switch character {
            case "\\":
                escaped = true
            case "\"":
                inQuotes.toggle()
            case "[" where !inQuotes:
                inBrackets = true
            case "]" where !inQuotes:
                inBrackets = false
            case ";" where !inQuotes && !inBrackets:
                sections.append(current)
                current = ""
                continue
            default:
                break
            }
            current.append(character)
        }
        sections.append(current)
        return sections
    }

    private static func tokens(_ section: String) -> [Token] {
        let characters = Array(section)
        var tokens: [Token] = []
        var index = 0

        func append(_ token: Token) {
            switch (tokens.last, token) {
            case (.literal(let previous), .literal(let next)):
                tokens[tokens.count - 1] = .literal(previous + next)
            case (.number(let previous), .number(let next)):
                tokens[tokens.count - 1] = .number(previous + next)
            default:
                tokens.append(token)
            }
        }

        func startsWith(_ word: String) -> Bool {
            let end = index + word.count
            guard end <= characters.count else {
                return false
            }
            return String(characters[index..<end]).lowercased() == word.lowercased()
        }

        while index < characters.count {
            let character = characters[index]
            switch character {
            case "\"":
                let close = characters[(index + 1)...].firstIndex(of: "\"") ?? characters.count
                append(.literal(String(characters[(index + 1)..<close])))
                index = close + 1
            case "\\":
                if index + 1 < characters.count {
                    append(.literal(String(characters[index + 1])))
                }
                index += 2
            case "_":
                append(.literal(" "))
                index += 2
            case "*":
                index += 2
            case "[":
                let close = characters[index...].firstIndex(of: "]") ?? characters.count - 1
                let content = String(characters[(index + 1)..<max(index + 1, close)])
                if content.hasPrefix("$") {
                    let symbol = content
                        .dropFirst()
                        .prefix { $0 != "-" }
                    append(.literal(String(symbol)))
                } else if !content.isEmpty, content.lowercased().allSatisfy({ "hms".contains($0) }) {
                    append(.elapsed(content.lowercased()))
                }
                index = close + 1
            case "@":
                append(.text)
                index += 1
            case "0", "#", "?", ".", ",", "%":
                append(.number(String(character)))
                index += 1
            case _ where "Ee".contains(character) && index + 1 < characters.count && "+-".contains(characters[index + 1]):
                append(.number("E" + String(characters[index + 1])))
                index += 2
            case _ where startsWith("General"):
                append(.general)
                index += 7
            case _ where startsWith("AM/PM"):
                append(.date("am/pm"))
                index += 5
            case _ where startsWith("A/P"):
                append(.date("a/p"))
                index += 3
            case _ where "ymdhs".contains(character.lowercased()):
                let letter = character.lowercased()
                var end = index
                while end < characters.count, characters[end].lowercased() == letter {
                    end += 1
                }
                tokens.append(.date(String(repeating: letter, count: end - index)))
                index = end
            default:
                append(.literal(String(character)))
                index += 1
            }
        }
        return tokens
    }

    private static func literals(_ tokens: ArraySlice<Token>) -> String {
        tokens.compactMap { token -> String? in
            if case .literal(let text) = token {
                return text
            }
            return nil
        }.joined()
    }
}

/// Number formatters and month names are slow to make, and a sheet asks for the same few often.
private final class FormatterCache {
    struct Symbols {
        var months: [String]
        var shortMonths: [String]
        var weekdays: [String]
        var shortWeekdays: [String]
        var am: String
        var pm: String
    }

    private var formatters: [String: NumberFormatter] = [:]
    private var symbolsByLocale: [Bool: Symbols] = [:]

    func formatter(
        minimumIntegerDigits: Int,
        minimumFractionDigits: Int,
        maximumFractionDigits: Int,
        grouping: Bool
    ) -> NumberFormatter {
        let key = "\(minimumIntegerDigits),\(minimumFractionDigits),\(maximumFractionDigits),\(grouping)"
        if let formatter = formatters[key] {
            return formatter
        }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = grouping
        formatter.groupingSize = 3
        formatter.minimumIntegerDigits = minimumIntegerDigits
        formatter.minimumFractionDigits = minimumFractionDigits
        formatter.maximumFractionDigits = maximumFractionDigits
        // Excel rounds halves away from zero.
        formatter.roundingMode = .halfUp
        formatters[key] = formatter
        return formatter
    }

    func symbols(korean: Bool) -> Symbols {
        if let symbols = symbolsByLocale[korean] {
            return symbols
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: korean ? "ko_KR" : "en_US")
        let symbols = Symbols(
            months: formatter.monthSymbols,
            shortMonths: formatter.shortMonthSymbols,
            weekdays: formatter.weekdaySymbols,
            shortWeekdays: formatter.shortWeekdaySymbols,
            am: korean ? "오전" : "AM",
            pm: korean ? "오후" : "PM"
        )
        symbolsByLocale[korean] = symbols
        return symbols
    }
}

/// Spreadsheet colors as CSS: `rgb`, a theme color with its tint, or the legacy palette.
struct SpreadsheetColors {
    let theme: DocxTheme

    /// Theme indexes put light before dark, unlike the theme part's order.
    private static let themeOrder = [
        "lt1",
        "dk1",
        "lt2",
        "dk2",
        "accent1",
        "accent2",
        "accent3",
        "accent4",
        "accent5",
        "accent6",
        "hlink",
        "folHlink",
    ]

    /// Office's default theme, for files without a theme part.
    static let officeTheme = [
        "lt1": "FFFFFF",
        "dk1": "000000",
        "lt2": "E7E6E6",
        "dk2": "44546A",
        "accent1": "4472C4",
        "accent2": "ED7D31",
        "accent3": "A5A5A5",
        "accent4": "FFC000",
        "accent5": "5B9BD5",
        "accent6": "70AD47",
        "hlink": "0563C1",
        "folHlink": "954F72",
    ]

    private static let palette = [
        "000000", "FFFFFF", "FF0000", "00FF00", "0000FF", "FFFF00", "FF00FF", "00FFFF",
        "000000", "FFFFFF", "FF0000", "00FF00", "0000FF", "FFFF00", "FF00FF", "00FFFF",
        "800000", "008000", "000080", "808000", "800080", "008080", "C0C0C0", "808080",
        "9999FF", "993366", "FFFFCC", "CCFFFF", "660066", "FF8080", "0066CC", "CCCCFF",
        "000080", "FF00FF", "FFFF00", "00FFFF", "800080", "800000", "008080", "0000FF",
        "00CCFF", "CCFFFF", "CCFFCC", "FFFF99", "99CCFF", "FF99CC", "CC99FF", "FFCC99",
        "3366FF", "33CCCC", "99CC00", "FFCC00", "FF9900", "FF6600", "666699", "969696",
        "003366", "339966", "003300", "333300", "993300", "993366", "333399", "333333",
        // System foreground and background.
        "000000", "FFFFFF",
    ]

    func css(_ element: XMLElement?) -> String? {
        guard let element, element.attributeValue("auto") != "1" else {
            return nil
        }
        var hex: String?
        if let rgb = element.attributeValue("rgb"), rgb.count >= 6 {
            hex = String(rgb.suffix(6))
        } else if let index = element.attributeValue("theme").flatMap(Int.init), Self.themeOrder.indices.contains(index) {
            let name = Self.themeOrder[index]
            hex = theme.color(name).map { String($0.dropFirst()) } ?? Self.officeTheme[name]
        } else if let index = element.attributeValue("indexed").flatMap(Int.init), Self.palette.indices.contains(index) {
            hex = Self.palette[index]
        }
        guard let hex, let value = Int(hex, radix: 16) else {
            return nil
        }
        let tint = element.attributeValue("tint").flatMap(Double.init) ?? 0
        let tinted = tint == 0 ? value : Self.applying(tint, to: value)
        return String(format: "#%06X", tinted)
    }

    /// Lightens toward white for a positive tint and darkens toward black for a negative one, in HSL.
    private static func applying(_ tint: Double, to rgb: Int) -> Int {
        var hsl = ColorMath.hsl(rgb)
        hsl.lightness = tint < 0 ? hsl.lightness * (1 + tint) : hsl.lightness * (1 - tint) + tint
        return ColorMath.rgb(
            hue: hsl.hue,
            saturation: hsl.saturation,
            lightness: hsl.lightness
        )
    }
}
