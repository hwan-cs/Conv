import CoreGraphics
import Foundation

enum SpreadsheetDrawingNamespace {
    static let xdr = "http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing"
    static let markup = "http://schemas.openxmlformats.org/markup-compatibility/2006"
}

/// One object floating over a sheet (`xl/drawings/drawingN.xml`): where it is anchored to the
/// cells, and what it holds. Pictures, charts, text boxes and lines are read; a group keeps
/// its members, each placed within the group's box.
struct XLSXDrawing {
    /// A cell corner plus an offset into the cell, in points.
    struct Marker: Equatable {
        var row: Int
        var column: Int
        var rowOffset = 0.0
        var columnOffset = 0.0
    }

    enum Placement {
        /// From one cell corner to another, stretching with the cells.
        case between(Marker, Marker)
        /// From a cell corner, at a fixed size in points.
        case sized(Marker, CGSize)
    }

    struct Picture {
        var data: Data
        var type: String
        /// The fraction cut off each edge: left, top, right, bottom.
        var crop = (left: 0.0, top: 0.0, right: 0.0, bottom: 0.0)
    }

    struct Run {
        var text: String
        var size: Double?
        var bold = false
        var italic = false
        var underline = false
        var color: String?
    }

    struct Paragraph {
        /// "l", "ctr", "r" or "just".
        var alignment = "l"
        var runs: [Run] = []
    }

    struct Shape {
        var geometry = "rect"
        var fill: String?
        var outline: (color: String, width: Double)?
        var paragraphs: [Paragraph] = []
        /// "t", "ctr" or "b".
        var verticalAlignment = "t"
        var insets = (top: 3.6, left: 7.2, bottom: 3.6, right: 7.2)
        var textColor: String?
    }

    enum Content {
        case picture(Picture)
        /// A chart part's path, read once every sheet's cells are known.
        case chartPart(String)
        case chart(XLSXChart)
        case shape(Shape)
        case line(color: String, width: Double)
    }

    struct Item {
        /// Within the drawing's box, from 0 to 1.
        var frame = CGRect(
            x: 0,
            y: 0,
            width: 1,
            height: 1
        )
        /// Degrees clockwise.
        var rotation = 0.0
        var flipsHorizontally = false
        var flipsVertically = false
        var content: Content
    }

    var placement: Placement
    /// The object's own size before rotation, in points, when it says.
    var size: CGSize?
    var items: [Item]

    /// The drawings in a drawing part, with their pictures read from the package.
    static func drawings(
        in root: XMLElement,
        path: String,
        package: XLSXPackage,
        colors: DrawingColors
    ) throws -> [XLSXDrawing] {
        let relationships = Dictionary(
            try package.relationships(of: path).map { ($0.id, $0.path) },
            uniquingKeysWith: { first, _ in first }
        )
        let reader = Reader(
            package: package,
            relationships: relationships,
            colors: colors
        )
        return root.elements.compactMap(reader.drawing)
    }

    private struct Reader {
        let package: XLSXPackage
        let relationships: [String: String]
        let colors: DrawingColors

        func drawing(_ anchor: XMLElement) -> XLSXDrawing? {
            let placement: Placement
            switch anchor.localName {
            case "twoCellAnchor":
                guard let from = marker(anchor.xdr("from")),
                      let to = marker(anchor.xdr("to"))
                else {
                    return nil
                }
                placement = .between(from, to)
            case "oneCellAnchor":
                guard let from = marker(anchor.xdr("from")),
                      let size = Self.size(anchor.xdr("ext"))
                else {
                    return nil
                }
                placement = .sized(from, size)
            case "absoluteAnchor":
                guard let size = Self.size(anchor.xdr("ext")) else {
                    return nil
                }
                let position = anchor.xdr("pos")
                let from = Marker(
                    row: 0,
                    column: 0,
                    rowOffset: Self.emu(position?.attributeValue("y")),
                    columnOffset: Self.emu(position?.attributeValue("x"))
                )
                placement = .sized(from, size)
            default:
                return nil
            }

            guard let object = Self.object(in: anchor) else {
                return nil
            }
            let transform = Self.transform(of: object)
            var items: [Item]
            if object.localName == "grpSp" {
                items = group(
                    object,
                    into: { $0 }
                )
                let box = transform?.bounds ?? .zero
                // Members are placed in the group's own coordinates; the drawing's box is the group.
                items = items.map { item in
                    var item = item
                    item.frame = CGRect(
                        x: box.width > 0 ? (item.frame.minX - box.minX) / box.width : 0,
                        y: box.height > 0 ? (item.frame.minY - box.minY) / box.height : 0,
                        width: box.width > 0 ? item.frame.width / box.width : 1,
                        height: box.height > 0 ? item.frame.height / box.height : 1
                    )
                    return item
                }
            } else {
                guard var item = self.item(object) else {
                    return nil
                }
                item.rotation = transform?.rotation ?? 0
                item.flipsHorizontally = transform?.flipsHorizontally ?? false
                item.flipsVertically = transform?.flipsVertically ?? false
                items = [item]
            }
            guard !items.isEmpty else {
                return nil
            }
            return XLSXDrawing(
                placement: placement,
                size: transform?.bounds.size,
                items: items
            )
        }

        /// A group's members, their frames in the coordinates `map` takes them to.
        private func group(_ group: XMLElement, into map: @escaping (CGRect) -> CGRect) -> [Item] {
            let properties = group.xdr("grpSpPr")?.child("xfrm", in: OOXMLNamespace.a)
            let box = Self.rect(properties)
            let childOffset = properties?.child("chOff", in: OOXMLNamespace.a)
            let childSize = properties?.child("chExt", in: OOXMLNamespace.a)
            let childBox = CGRect(
                x: Self.emu(childOffset?.attributeValue("x")),
                y: Self.emu(childOffset?.attributeValue("y")),
                width: Self.emu(childSize?.attributeValue("cx")),
                height: Self.emu(childSize?.attributeValue("cy"))
            )
            // Child coordinates → the group's place in its parent → wherever the parent maps to.
            let toParent = { (rect: CGRect) -> CGRect in
                guard let box, childBox.width > 0, childBox.height > 0 else {
                    return rect
                }
                let scaleX = box.width / childBox.width
                let scaleY = box.height / childBox.height
                return map(
                    CGRect(
                        x: box.minX + (rect.minX - childBox.minX) * scaleX,
                        y: box.minY + (rect.minY - childBox.minY) * scaleY,
                        width: rect.width * scaleX,
                        height: rect.height * scaleY
                    )
                )
            }

            var items: [Item] = []
            for member in group.elements {
                guard let object = member.localName == "AlternateContent" ? Self.chosen(member) : member else {
                    continue
                }
                if object.localName == "grpSp" {
                    items += self.group(
                        object,
                        into: toParent
                    )
                    continue
                }
                guard var item = item(object),
                      let transform = Self.transform(of: object)
                else {
                    continue
                }
                item.frame = toParent(transform.bounds)
                item.rotation = transform.rotation
                item.flipsHorizontally = transform.flipsHorizontally
                item.flipsVertically = transform.flipsVertically
                items.append(item)
            }
            return items
        }

        private func item(_ object: XMLElement) -> Item? {
            switch object.localName {
            case "pic":
                return picture(object).map { Item(content: .picture($0)) }
            case "graphicFrame":
                let data = object
                    .child("graphic", in: OOXMLNamespace.a)?
                    .child("graphicData", in: OOXMLNamespace.a)
                guard let id = data?.chart("chart")?.attribute(forLocalName: "id", uri: OOXMLNamespace.r)?.stringValue,
                      let path = relationships[id]
                else {
                    return nil
                }
                return Item(content: .chartPart(path))
            case "sp", "cxnSp":
                return shape(object)
            default:
                return nil
            }
        }

        private func picture(_ object: XMLElement) -> Picture? {
            guard let fill = object.xdr("blipFill"),
                  let id = fill.child("blip", in: OOXMLNamespace.a)?.attribute(forLocalName: "embed", uri: OOXMLNamespace.r)?.stringValue,
                  let path = relationships[id],
                  let type = SheetHTMLWriter.imageTypes[URL(filePath: path).pathExtension.lowercased()],
                  let data = try? package.data(at: path)
            else {
                return nil
            }
            var picture = Picture(
                data: data,
                type: type
            )
            if let crop = fill.child("srcRect", in: OOXMLNamespace.a) {
                func edge(_ name: String) -> Double {
                    (crop.attributeValue(name).flatMap(Double.init) ?? 0) / 100_000
                }
                picture.crop = (edge("l"), edge("t"), edge("r"), edge("b"))
            }
            return picture
        }

        private func shape(_ object: XMLElement) -> Item? {
            let properties = object.xdr("spPr")
            let style = object.xdr("style")
            let geometry = properties?.child("prstGeom", in: OOXMLNamespace.a)?.attributeValue("prst") ?? "rect"
            let line = properties?.child("ln", in: OOXMLNamespace.a)
            let lineWidth = line?.attributeValue("w").map { Self.emu($0) } ?? 0.75
            let lineColor: String? = line?.child("noFill", in: OOXMLNamespace.a) != nil
                ? nil
                : colors.css(in: line?.child("solidFill", in: OOXMLNamespace.a))
                    ?? Self.reference(style?.child("lnRef", in: OOXMLNamespace.a), colors: colors)

            if object.localName == "cxnSp" || geometry == "line" || geometry.hasPrefix("straightConnector") {
                return Item(content: .line(color: lineColor ?? "#000000", width: lineWidth))
            }

            var shape = Shape(geometry: geometry)
            if properties?.child("noFill", in: OOXMLNamespace.a) == nil {
                shape.fill = colors.css(in: properties?.child("solidFill", in: OOXMLNamespace.a))
                    ?? Self.reference(style?.child("fillRef", in: OOXMLNamespace.a), colors: colors)
            }
            if let lineColor {
                shape.outline = (lineColor, lineWidth)
            }
            shape.textColor = colors.css(in: style?.child("fontRef", in: OOXMLNamespace.a))
            if let body = object.xdr("txBody") {
                let properties = body.child("bodyPr", in: OOXMLNamespace.a)
                shape.verticalAlignment = properties?.attributeValue("anchor") ?? "t"
                func inset(_ name: String, _ fallback: Double) -> Double {
                    properties?.attributeValue(name).map { Self.emu($0) } ?? fallback
                }
                shape.insets = (
                    top: inset("tIns", 3.6),
                    left: inset("lIns", 7.2),
                    bottom: inset("bIns", 3.6),
                    right: inset("rIns", 7.2)
                )
                shape.paragraphs = body.children("p", in: OOXMLNamespace.a).map(paragraph)
            }
            return Item(content: .shape(shape))
        }

        private func paragraph(_ element: XMLElement) -> Paragraph {
            var paragraph = Paragraph()
            paragraph.alignment = element.child("pPr", in: OOXMLNamespace.a)?.attributeValue("algn") ?? "l"
            for run in element.elements {
                switch run.localName {
                case "r", "fld":
                    let properties = run.child("rPr", in: OOXMLNamespace.a)
                    paragraph.runs.append(
                        Run(
                            text: run.child("t", in: OOXMLNamespace.a)?.stringValue ?? "",
                            size: properties?.attributeValue("sz").flatMap(Double.init).map { $0 / 100 },
                            bold: properties?.attributeValue("b") == "1",
                            italic: properties?.attributeValue("i") == "1",
                            underline: (properties?.attributeValue("u")).map { $0 != "none" } ?? false,
                            color: colors.css(in: properties?.child("solidFill", in: OOXMLNamespace.a))
                        )
                    )
                case "br":
                    paragraph.runs.append(Run(text: "\n"))
                default:
                    break
                }
            }
            return paragraph
        }

        private func marker(_ element: XMLElement?) -> Marker? {
            guard let element,
                  let row = element.xdr("row")?.stringValue.flatMap(Int.init),
                  let column = element.xdr("col")?.stringValue.flatMap(Int.init)
            else {
                return nil
            }
            return Marker(
                row: row,
                column: column,
                rowOffset: Self.emu(element.xdr("rowOff")?.stringValue),
                columnOffset: Self.emu(element.xdr("colOff")?.stringValue)
            )
        }

        /// The object an anchor holds, choosing within markup-compatibility alternatives.
        private static func object(in anchor: XMLElement) -> XMLElement? {
            for element in anchor.elements {
                if element.localName == "AlternateContent" {
                    if let chosen = chosen(element) {
                        return chosen
                    }
                    continue
                }
                if ["sp", "grpSp", "graphicFrame", "cxnSp", "pic"].contains(element.localName ?? "") {
                    return element
                }
            }
            return nil
        }

        /// The first alternative holding an object this reader knows, else the fallback's.
        private static func chosen(_ alternatives: XMLElement) -> XMLElement? {
            let known = ["sp", "grpSp", "graphicFrame", "cxnSp", "pic"]
            for choice in alternatives.elements {
                let object = choice.elements.first { known.contains($0.localName ?? "") }
                guard let object else {
                    continue
                }
                // A chart Excel 2016 added (waterfall, treemap…) isn't a chart part; its fallback says so.
                let isNewChart = object.firstDescendant("chart", in: "http://schemas.microsoft.com/office/drawing/2014/chartex") != nil
                if !isNewChart {
                    return object
                }
            }
            return nil
        }

        private static func transform(
            of object: XMLElement
        ) -> (bounds: CGRect, rotation: Double, flipsHorizontally: Bool, flipsVertically: Bool)? {
            let xfrm: XMLElement?
            switch object.localName {
            case "graphicFrame":
                xfrm = object.xdr("xfrm")
            case "grpSp":
                xfrm = object.xdr("grpSpPr")?.child("xfrm", in: OOXMLNamespace.a)
            default:
                xfrm = object.xdr("spPr")?.child("xfrm", in: OOXMLNamespace.a)
            }
            guard let bounds = rect(xfrm) else {
                return nil
            }
            return (
                bounds,
                (xfrm?.attributeValue("rot").flatMap(Double.init) ?? 0) / 60_000,
                xfrm?.attributeValue("flipH") == "1",
                xfrm?.attributeValue("flipV") == "1"
            )
        }

        private static func rect(_ xfrm: XMLElement?) -> CGRect? {
            guard let size = Self.size(xfrm?.child("ext", in: OOXMLNamespace.a)) else {
                return nil
            }
            let offset = xfrm?.child("off", in: OOXMLNamespace.a)
            return CGRect(
                origin: CGPoint(
                    x: emu(offset?.attributeValue("x")),
                    y: emu(offset?.attributeValue("y"))
                ),
                size: size
            )
        }

        private static func size(_ element: XMLElement?) -> CGSize? {
            guard let width = element?.attributeValue("cx").flatMap(Double.init),
                  let height = element?.attributeValue("cy").flatMap(Double.init)
            else {
                return nil
            }
            return CGSize(
                width: width / 12_700,
                height: height / 12_700
            )
        }

        /// A style's fill or line reference: its color, unless the index says none.
        private static func reference(_ element: XMLElement?, colors: DrawingColors) -> String? {
            guard let element, element.attributeValue("idx") != "0" else {
                return nil
            }
            return colors.css(in: element)
        }

        static func emu(_ text: String?) -> Double {
            (text.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) } ?? 0) / 12_700
        }
    }
}

extension XMLElement {
    func xdr(_ name: String) -> XMLElement? {
        child(name, in: SpreadsheetDrawingNamespace.xdr)
    }
}
