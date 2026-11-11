import Foundation

/// Hangul's equations, already turned into MathML by `HwpEquation`, as Office math (OMML) that
/// Word edits as its own equations.
enum HwpOfficeMath {
    /// An inline `<m:oMath>`; plain text in a run when the MathML can't be read.
    /// - Parameter size: The equation's font size in HWPUNIT.
    static func omml(_ mathML: String, size: Int) -> String {
        let halfPoints = max(size / 50, 2)
        guard let root = try? XMLDocument(xmlString: mathML, options: []).rootElement() else {
            return "<w:r><w:t xml:space=\"preserve\">\(HwpDocxWriter.escape(mathML))</w:t></w:r>"
        }
        var converter = Converter(size: halfPoints)
        return "<m:oMath>\(converter.children(of: root, top: true))</m:oMath>"
    }

    private struct Converter {
        let size: Int

        mutating func children(of element: XMLElement, top: Bool = false) -> String {
            let elements = (element.children ?? []).compactMap { $0 as? XMLElement }
            if top, elements.count == 1, elements[0].localName == "mtable", elements[0].attribute(forName: "columnalign") != nil {
                let rows = rows(of: elements[0]).map { "<m:e>\($0.joined())</m:e>" }
                return "<m:eqArr>\(rows.joined())</m:eqArr>"
            }
            return elements.map { convert($0) }.joined()
        }

        mutating func convert(_ element: XMLElement) -> String {
            let parts = (element.children ?? []).compactMap { $0 as? XMLElement }
            func part(_ index: Int) -> String { parts.indices.contains(index) ? convert(parts[index]) : "" }
            switch element.localName ?? "" {
            case "mi":
                let text = element.stringValue ?? ""
                let isNormal = element.attribute(forName: "mathvariant")?.stringValue == "normal" || text.count > 1
                return run(text, upright: isNormal)
            case "mn", "mo":
                return run(element.stringValue ?? "", upright: true)
            case "mtext":
                return run(element.stringValue ?? "", upright: true, literal: true)
            case "mspace":
                return run(" ", upright: true, literal: true)
            case "mfrac":
                let noBar = element.attribute(forName: "linethickness")?.stringValue == "0"
                return "<m:f>\(noBar ? "<m:fPr><m:type m:val=\"noBar\"/></m:fPr>" : "")<m:num>\(part(0))</m:num><m:den>\(part(1))</m:den></m:f>"
            case "msqrt":
                return "<m:rad><m:radPr><m:degHide m:val=\"1\"/></m:radPr><m:deg/><m:e>\(children(of: element))</m:e></m:rad>"
            case "mroot":
                return "<m:rad><m:deg>\(part(1))</m:deg><m:e>\(part(0))</m:e></m:rad>"
            case "msub":
                return "<m:sSub><m:e>\(part(0))</m:e><m:sub>\(part(1))</m:sub></m:sSub>"
            case "msup":
                return "<m:sSup><m:e>\(part(0))</m:e><m:sup>\(part(1))</m:sup></m:sSup>"
            case "msubsup":
                return "<m:sSubSup><m:e>\(part(0))</m:e><m:sub>\(part(1))</m:sub><m:sup>\(part(2))</m:sup></m:sSubSup>"
            case "munder":
                if element.attribute(forName: "accentunder") != nil {
                    return "<m:groupChr><m:groupChrPr><m:chr m:val=\"\(attribute(parts[safe: 1]?.stringValue))\"/><m:pos m:val=\"bot\"/></m:groupChrPr><m:e>\(part(0))</m:e></m:groupChr>"
                }
                return "<m:limLow><m:e>\(part(0))</m:e><m:lim>\(part(1))</m:lim></m:limLow>"
            case "mover":
                if element.attribute(forName: "accent") != nil {
                    return "<m:acc><m:accPr><m:chr m:val=\"\(attribute(parts[safe: 1]?.stringValue))\"/></m:accPr><m:e>\(part(0))</m:e></m:acc>"
                }
                return "<m:limUpp><m:e>\(part(0))</m:e><m:lim>\(part(1))</m:lim></m:limUpp>"
            case "munderover":
                let base = parts.first?.stringValue ?? ""
                if parts.first?.localName == "mo", base.count == 1 {
                    return "<m:nary><m:naryPr><m:chr m:val=\"\(attribute(base))\"/><m:limLoc m:val=\"undOvr\"/></m:naryPr><m:sub>\(part(1))</m:sub><m:sup>\(part(2))</m:sup><m:e/></m:nary>"
                }
                return "<m:limUpp><m:e><m:limLow><m:e>\(part(0))</m:e><m:lim>\(part(1))</m:lim></m:limLow></m:e><m:lim>\(part(2))</m:lim></m:limUpp>"
            case "mtable":
                let rows = rows(of: element).map { row in "<m:mr>" + row.map { "<m:e>\($0)</m:e>" }.joined() + "</m:mr>" }
                return "<m:m>\(rows.joined())</m:m>"
            case "menclose":
                return "<m:borderBox><m:e>\(children(of: element))</m:e></m:borderBox>"
            default:
                return children(of: element)
            }
        }

        /// Cells of a table's rows.
        mutating func rows(of table: XMLElement) -> [[String]] {
            (table.children ?? []).compactMap { $0 as? XMLElement }.filter { $0.localName == "mtr" }.map { row in
                (row.children ?? []).compactMap { $0 as? XMLElement }.filter { $0.localName == "mtd" }.map { children(of: $0) }
            }
        }

        func run(_ text: String, upright: Bool, literal: Bool = false) -> String {
            guard !text.isEmpty else {
                return ""
            }
            var properties = ""
            if literal {
                properties += "<m:lit/>"
            }
            if upright {
                properties += "<m:sty m:val=\"p\"/>"
            }
            let math = properties.isEmpty ? "" : "<m:rPr>\(properties)</m:rPr>"
            return "<m:r>\(math)<w:rPr><w:rFonts w:ascii=\"Cambria Math\" w:hAnsi=\"Cambria Math\"/><w:sz w:val=\"\(size)\"/><w:szCs w:val=\"\(size)\"/></w:rPr>"
                + "<m:t xml:space=\"preserve\">\(HwpDocxWriter.escape(text))</m:t></m:r>"
        }

        func attribute(_ text: String?) -> String {
            HwpDocxWriter.escape(text ?? "")
        }
    }
}
