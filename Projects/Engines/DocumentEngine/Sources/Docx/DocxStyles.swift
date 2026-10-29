import Foundation

/// Character formatting. `nil` means "inherit", so layers merge with `overlaid(by:)`.
struct RunFormat: Equatable {
    var bold: Bool?
    var italic: Bool?
    var underline: Bool?
    var strike: Bool?
    var color: String?
    var sizePt: Double?
    var latinFont: String?
    var eastAsiaFont: String?
    var highlight: String?
    var verticalAlign: String?

    init() {}

    init(_ rPr: XMLElement?) {
        guard let rPr else { return }
        bold = rPr.child("b")?.isOn
        italic = rPr.child("i")?.isOn
        underline = rPr.child("u").map { $0.value() != "none" }
        strike = (rPr.child("strike") ?? rPr.child("dstrike"))?.isOn
        color = rPr.child("color")?.value().flatMap { $0 == "auto" ? nil : "#\($0)" }
        sizePt = rPr.child("sz")?.number().map { $0 / 2 }
        if let fonts = rPr.child("rFonts") {
            // Theme attributes win over explicit names; `DocxTheme.font` resolves the "+" tokens.
            latinFont = fonts.value("asciiTheme").map { "+\($0)" } ?? fonts.value("ascii") ?? fonts.value("hAnsi")
            eastAsiaFont = fonts.value("eastAsiaTheme").map { "+\($0)" } ?? fonts.value("eastAsia")
        }
        highlight = rPr.child("highlight")?.value().flatMap { Self.highlightColors[$0] }
            ?? rPr.child("shd")?.value("fill").flatMap { $0 == "auto" ? nil : "#\($0)" }
        verticalAlign = rPr.child("vertAlign")?.value()
    }

    func overlaid(by top: RunFormat) -> RunFormat {
        var result = self
        result.bold = top.bold ?? bold
        result.italic = top.italic ?? italic
        result.underline = top.underline ?? underline
        result.strike = top.strike ?? strike
        result.color = top.color ?? color
        result.sizePt = top.sizePt ?? sizePt
        result.latinFont = top.latinFont ?? latinFont
        result.eastAsiaFont = top.eastAsiaFont ?? eastAsiaFont
        result.highlight = top.highlight ?? highlight
        result.verticalAlign = top.verticalAlign ?? verticalAlign
        return result
    }

    private static let highlightColors: [String: String] = [
        "yellow": "#FFFF00", "green": "#00FF00", "cyan": "#00FFFF", "magenta": "#FF00FF",
        "blue": "#0000FF", "red": "#FF0000", "darkBlue": "#000080", "darkCyan": "#008080",
        "darkGreen": "#008000", "darkMagenta": "#800080", "darkRed": "#800000",
        "darkYellow": "#808000", "darkGray": "#808080", "lightGray": "#C0C0C0",
        "black": "#000000", "white": "#FFFFFF",
    ]
}

/// Paragraph formatting, in points. `nil` means "inherit".
struct ParagraphFormat: Equatable {
    var alignment: String?
    var indentLeft: Double?
    var indentRight: Double?
    /// Positive is a first-line indent, negative a hanging indent.
    var firstLine: Double?
    var spaceBefore: Double?
    var spaceAfter: Double?
    /// `.multiple(1.0)` is Word's single spacing.
    var lineSpacing: LineSpacing?
    var pageBreakBefore: Bool?
    /// Spacing before/after is dropped between paragraphs of the same style.
    var contextualSpacing: Bool?
    var shading: String?
    var numbering: NumberingReference?
    /// Custom tab stops by position; `clear` entries remove an inherited stop when overlaid.
    var tabs: [TabStop]?

    enum LineSpacing: Equatable {
        case multiple(Double)
        case exactly(Double)
        case atLeast(Double)
    }

    struct TabStop: Equatable {
        /// left, center, right, decimal, bar, or clear.
        var kind: String
        var position: Double
    }

    struct NumberingReference: Equatable {
        var numID: String
        var level: Int
    }

    init() {}

    init(_ pPr: XMLElement?) {
        guard let pPr else { return }
        alignment = pPr.child("jc")?.value()
        if let ind = pPr.child("ind") {
            indentLeft = (ind.number("left") ?? ind.number("start")).map(twips)
            indentRight = (ind.number("right") ?? ind.number("end")).map(twips)
            if let hanging = ind.number("hanging") {
                firstLine = -twips(hanging)
            } else if let first = ind.number("firstLine") {
                firstLine = twips(first)
            }
        }
        if let spacing = pPr.child("spacing") {
            spaceBefore = spacing.number("before").map(twips)
            spaceAfter = spacing.number("after").map(twips)
            if let line = spacing.number("line") {
                switch spacing.value("lineRule") {
                case "exact": lineSpacing = .exactly(twips(line))
                case "atLeast": lineSpacing = .atLeast(twips(line))
                default: lineSpacing = .multiple(line / 240)
                }
            }
        }
        pageBreakBefore = pPr.child("pageBreakBefore")?.isOn
        contextualSpacing = pPr.child("contextualSpacing")?.isOn
        shading = pPr.child("shd")?.value("fill").flatMap { $0 == "auto" ? nil : "#\($0)" }
        tabs = pPr.child("tabs")?.children("tab").compactMap { tab in
            tab.number("pos").map { TabStop(kind: tab.value() ?? "left", position: twips($0)) }
        }
        if let numPr = pPr.child("numPr") {
            let numID = numPr.child("numId")?.value() ?? "0"
            numbering = NumberingReference(numID: numID, level: Int(numPr.child("ilvl")?.value() ?? "0") ?? 0)
        }
    }

    func overlaid(by top: ParagraphFormat) -> ParagraphFormat {
        var result = self
        result.alignment = top.alignment ?? alignment
        result.indentLeft = top.indentLeft ?? indentLeft
        result.indentRight = top.indentRight ?? indentRight
        result.firstLine = top.firstLine ?? firstLine
        result.spaceBefore = top.spaceBefore ?? spaceBefore
        result.spaceAfter = top.spaceAfter ?? spaceAfter
        result.lineSpacing = top.lineSpacing ?? lineSpacing
        result.pageBreakBefore = top.pageBreakBefore ?? pageBreakBefore
        result.contextualSpacing = top.contextualSpacing ?? contextualSpacing
        result.shading = top.shading ?? shading
        result.numbering = top.numbering ?? numbering
        if let added = top.tabs {
            var merged = tabs ?? []
            for stop in added {
                merged.removeAll { $0.position == stop.position }
                if stop.kind != "clear" { merged.append(stop) }
            }
            result.tabs = merged.sorted { $0.position < $1.position }
        }
        return result
    }
}

/// One side of a table or cell border.
struct BorderSide: Equatable {
    var css: String

    /// `nil` for `w:val="nil"`/`none`, which removes an inherited border.
    init?(_ element: XMLElement) {
        let style = element.value() ?? "single"
        guard !["nil", "none"].contains(style) else { return nil }
        let width = max((element.number("sz") ?? 4) / 8, 0.25)
        let color = element.value("color").flatMap { $0 == "auto" ? nil : "#\($0)" } ?? "#000000"
        let cssStyle = switch style {
        case "double": "double"
        case "dashed", "dashSmallGap", "dotDash", "dotDotDash": "dashed"
        case "dotted": "dotted"
        default: "solid"
        }
        css = "\(decimal(style == "double" ? max(width, 2.25) : width))pt \(cssStyle) \(color)"
    }
}

/// Explicit borders by side; a missing key inherits, a `nil` value removes.
typealias Borders = [String: BorderSide?]

func borders(_ element: XMLElement?) -> Borders {
    var result: Borders = [:]
    for side in element?.elements ?? [] {
        let name = side.localName ?? ""
        // Word writes start/end for left/right in newer files.
        let key = ["start": "left", "end": "right"][name] ?? name
        result[key] = .some(BorderSide(side))
    }
    return result
}

/// styles.xml: defaults plus named paragraph, character, and table styles.
struct DocxStyles {
    private struct Style {
        var basedOn: String?
        var paragraph = ParagraphFormat()
        var run = RunFormat()
        var tableBorders: Borders = [:]
    }

    private var styles: [String: Style] = [:]
    private var defaultParagraphStyle: String?
    private var defaultTableStyle: String?
    private(set) var defaultRun = RunFormat()
    private(set) var defaultParagraph = ParagraphFormat()

    init(_ root: XMLElement?) {
        // Word's built-in defaults when styles.xml says nothing.
        defaultRun.sizePt = 10
        defaultRun.latinFont = "Times New Roman"
        guard let root else { return }
        if let defaults = root.child("docDefaults") {
            defaultRun = defaultRun.overlaid(by: RunFormat(defaults.child("rPrDefault")?.child("rPr")))
            defaultParagraph = ParagraphFormat(defaults.child("pPrDefault")?.child("pPr"))
        }
        for element in root.children("style") {
            guard let id = element.value("styleId") else { continue }
            var style = Style()
            style.basedOn = element.child("basedOn")?.value()
            style.paragraph = ParagraphFormat(element.child("pPr"))
            style.run = RunFormat(element.child("rPr"))
            style.tableBorders = borders(element.child("tblPr")?.child("tblBorders"))
            styles[id] = style
            if element.value("default").map({ $0 == "1" || $0 == "true" }) == true {
                switch element.value("type") {
                case "paragraph": defaultParagraphStyle = id
                case "table": defaultTableStyle = id
                default: break
                }
            }
        }
    }

    /// The style and everything it is based on, base first.
    private func chain(_ id: String?) -> [Style] {
        var result: [Style] = []
        var seen: Set<String> = []
        var next = id
        while let current = next, !seen.contains(current), let style = styles[current] {
            seen.insert(current)
            result.insert(style, at: 0)
            next = style.basedOn
        }
        return result
    }

    /// Inside a table, the table style's formatting sits between the document defaults and the paragraph style.
    func paragraph(
        styleID: String?,
        table: (paragraph: ParagraphFormat, run: RunFormat)? = nil
    ) -> (paragraph: ParagraphFormat, run: RunFormat) {
        let base = (defaultParagraph.overlaid(by: table?.paragraph ?? ParagraphFormat()), defaultRun.overlaid(by: table?.run ?? RunFormat()))
        return chain(styleID ?? defaultParagraphStyle).reduce(base) { result, style in
            (result.0.overlaid(by: style.paragraph), result.1.overlaid(by: style.run))
        }
    }

    func run(styleID: String?) -> RunFormat {
        chain(styleID).reduce(RunFormat()) { $0.overlaid(by: $1.run) }
    }

    /// Paragraph and run formatting a table style gives the paragraphs in its cells.
    func tableCellFormat(styleID: String?) -> (paragraph: ParagraphFormat, run: RunFormat) {
        chain(styleID ?? defaultTableStyle).reduce((ParagraphFormat(), RunFormat())) { result, style in
            (result.0.overlaid(by: style.paragraph), result.1.overlaid(by: style.run))
        }
    }

    func tableBorders(styleID: String?) -> Borders {
        chain(styleID ?? defaultTableStyle).reduce(into: Borders()) { result, style in
            result.merge(style.tableBorders) { $1 }
        }
    }
}

func twips(_ value: Double) -> Double { value / 20 }

/// Points for CSS: at most two decimals, no trailing zeros.
func decimal(_ value: Double) -> String {
    let rounded = (value * 100).rounded() / 100
    return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
}
