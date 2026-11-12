import Foundation

enum ChartNamespace {
    static let c = "http://schemas.openxmlformats.org/drawingml/2006/chart"
}

/// A chart part (`xl/charts/chartN.xml`) read for drawing: its kind, series with their values,
/// colors and labels, axes, title and legend. Values come from the chart's own cache, or from
/// the cells it points at when the cache is missing.
struct XLSXChart {
    enum Kind: Equatable {
        case column
        case bar
        case line
        case area
        case pie
        case doughnut
        case scatter
        case radar
    }

    enum Grouping: Equatable {
        case clustered
        case stacked
        case percentStacked
    }

    struct Labels: Equatable {
        var value = false
        var percent = false
        var category = false

        var isEmpty: Bool {
            !value && !percent && !category
        }
    }

    struct Series {
        var name: String
        var categories: [String]
        var values: [Double?]
        var xValues: [Double?]
        var formatCode: String?
        var color: String
        /// Slice or bar colors set one by one.
        var pointColors: [Int: String] = [:]
        var showsMarkers = false
        var showsLine = true
        var isSmooth = false
        var labels = Labels()
    }

    struct Group {
        var kind: Kind
        var grouping = Grouping.clustered
        var series: [Series]
        var isSecondary = false
        var gapWidth = 150.0
        var overlap = 0.0
        var holeSize = 50.0
        /// Points sit in the middle of each category rather than on its edges.
        var isBetweenCategories = true
    }

    struct Axis {
        var isDeleted = false
        var minimum: Double?
        var maximum: Double?
        var formatCode: String?
        var hasGridlines = false
        var title: String?
        var isReversed = false
    }

    var title: String?
    var groups: [Group] = []
    /// Where the legend sits: "r", "l", "t", "b" or "tr"; nil without one.
    var legend: String?
    /// The category axis, or a scatter chart's horizontal value axis.
    var categoryAxis = Axis()
    var valueAxis = Axis()
    var secondaryAxis: Axis?

    /// - Parameter cells: The cells a reference such as `Sheet1!$B$2:$B$9` points at, in order.
    init?(
        _ root: XMLElement,
        colors: DrawingColors,
        formats: NumberFormats,
        cells: (String) -> [XLSXWorkbook.Cell?]
    ) {
        guard let chart = root.chart("chart"),
              let plot = chart.chart("plotArea")
        else {
            return nil
        }

        var axes: [String: XMLElement] = [:]
        for element in plot.elements where ["catAx", "valAx", "dateAx", "serAx"].contains(element.localName ?? "") {
            if let id = element.chart("axId")?.attributeValue("val") {
                axes[id] = element
            }
        }

        var seriesIndex = 0
        var primaryValueAxis: String?
        for element in plot.elements {
            guard let kind = Self.kind(element) else {
                continue
            }
            let axisIDs = element.charts("axId").compactMap { $0.attributeValue("val") }
            let groupAxes = axisIDs.compactMap { id in axes[id].map { (id, $0) } }
            let valueAxis: (String, XMLElement)?
            let categoryAxis: (String, XMLElement)?
            if kind == .scatter {
                // Both are value axes: the horizontal one is the x axis.
                let isHorizontal = { (axis: XMLElement) in ["b", "t"].contains(axis.chart("axPos")?.attributeValue("val") ?? "") }
                categoryAxis = groupAxes.first { isHorizontal($0.1) } ?? groupAxes.first
                valueAxis = groupAxes.first { !isHorizontal($0.1) } ?? groupAxes.last
            } else {
                categoryAxis = groupAxes.first { $0.1.localName != "valAx" }
                valueAxis = groupAxes.first { $0.1.localName == "valAx" }
            }

            var group = Group(
                kind: kind,
                series: []
            )
            group.grouping = switch element.chart("grouping")?.attributeValue("val") {
            case "stacked":
                .stacked
            case "percentStacked":
                .percentStacked
            default:
                .clustered
            }
            if let gap = element.chart("gapWidth")?.attributeValue("val").flatMap(Double.init) {
                group.gapWidth = gap
            }
            let defaultOverlap = group.grouping == .clustered ? 0.0 : 100.0
            group.overlap = element.chart("overlap")?.attributeValue("val").flatMap(Double.init) ?? defaultOverlap
            if let hole = element.chart("holeSize")?.attributeValue("val").flatMap(Double.init) {
                group.holeSize = hole
            }
            let crossBetween = valueAxis?.1.chart("crossBetween")?.attributeValue("val")
            group.isBetweenCategories = crossBetween.map { $0 == "between" } ?? (kind != .area)

            if kind != .pie, kind != .doughnut, let valueAxis {
                if primaryValueAxis == nil {
                    primaryValueAxis = valueAxis.0
                    self.valueAxis = Self.axis(valueAxis.1)
                    if let categoryAxis {
                        self.categoryAxis = Self.axis(categoryAxis.1)
                    }
                } else if valueAxis.0 != primaryValueAxis {
                    group.isSecondary = true
                    if secondaryAxis == nil {
                        secondaryAxis = Self.axis(valueAxis.1)
                    }
                }
            }

            let varyColors = element.chart("varyColors")?.attributeValue("val").map { $0 == "1" || $0 == "true" }
                ?? (kind == .pie || kind == .doughnut)
            let groupLabels = element.chart("dLbls").map(Self.labels) ?? Labels()
            let groupMarkers = element.chart("marker")?.attributeValue("val").map { $0 == "1" || $0 == "true" } ?? false
            let scatterStyle = element.chart("scatterStyle")?.attributeValue("val") ?? "lineMarker"

            for series in element.charts("ser") {
                let index = series.chart("idx")?.attributeValue("val").flatMap(Int.init) ?? seriesIndex
                seriesIndex += 1
                let values = Self.numbers(
                    series.chart("val") ?? series.chart("yVal"),
                    cells: cells
                )
                let xValues = kind == .scatter
                    ? Self.numbers(series.chart("xVal"), cells: cells).values
                    : []
                let categories = Self.strings(
                    series.chart("cat") ?? series.chart("xVal"),
                    formats: formats,
                    cells: cells
                )
                let properties = series.chart("spPr")
                let outline = properties?.child("ln", in: OOXMLNamespace.a)
                let usesLine = [.line, .scatter, .radar].contains(kind)
                let lineColor = colors.css(in: outline?.child("solidFill", in: OOXMLNamespace.a))
                let fillColor = colors.css(in: properties?.child("solidFill", in: OOXMLNamespace.a))
                let ownColor = usesLine ? lineColor ?? fillColor : fillColor ?? lineColor

                var item = Series(
                    name: Self.text(series.chart("tx"), cells: cells) ?? "계열\(index + 1)",
                    categories: categories,
                    values: values.values,
                    xValues: xValues,
                    formatCode: values.formatCode,
                    color: ownColor ?? colors.accent(index).css
                )
                if varyColors {
                    for point in values.values.indices {
                        item.pointColors[point] = colors.accent(point).css
                    }
                }
                for point in series.charts("dPt") {
                    guard let pointIndex = point.chart("idx")?.attributeValue("val").flatMap(Int.init),
                          let color = colors.css(in: point.chart("spPr")?.child("solidFill", in: OOXMLNamespace.a))
                    else {
                        continue
                    }
                    item.pointColors[pointIndex] = color
                }
                let symbol = series.chart("marker")?.chart("symbol")?.attributeValue("val")
                if kind == .scatter || kind == .radar {
                    item.showsMarkers = symbol != "none" && scatterStyle != "line" && scatterStyle != "smooth"
                } else if kind == .line {
                    item.showsMarkers = symbol.map { $0 != "none" } ?? groupMarkers
                }
                if kind == .scatter {
                    item.showsLine = outline?.child("noFill", in: OOXMLNamespace.a) == nil && scatterStyle != "marker"
                }
                item.isSmooth = series.chart("smooth")?.attributeValue("val").map { $0 == "1" || $0 == "true" }
                    ?? scatterStyle.hasPrefix("smooth")
                item.labels = series.chart("dLbls").map(Self.labels) ?? groupLabels
                group.series.append(item)
            }
            if !group.series.isEmpty {
                groups.append(group)
            }
        }
        guard !groups.isEmpty else {
            return nil
        }

        let allSeries = groups.flatMap(\.series)
        let autoTitleDeleted = chart.chart("autoTitleDeleted")?.attributeValue("val").map { $0 == "1" || $0 == "true" } ?? false
        if let title = chart.chart("title") {
            self.title = Self.text(
                title.chart("tx"),
                cells: cells
            )
            if self.title == nil, allSeries.count == 1 {
                self.title = allSeries[0].name
            }
        } else if !autoTitleDeleted, allSeries.count == 1 {
            // Excel names a chart of one series after it.
            title = allSeries[0].name
        }
        if let legend = chart.chart("legend") {
            self.legend = legend.chart("legendPos")?.attributeValue("val") ?? "r"
        }
    }

    // MARK: Parsing

    private static func kind(_ element: XMLElement) -> Kind? {
        switch element.localName {
        case "barChart", "bar3DChart":
            element.chart("barDir")?.attributeValue("val") == "bar" ? .bar : .column
        case "lineChart", "line3DChart", "stockChart":
            .line
        case "areaChart", "area3DChart":
            .area
        case "pieChart", "pie3DChart", "ofPieChart":
            .pie
        case "doughnutChart":
            .doughnut
        case "scatterChart", "bubbleChart":
            .scatter
        case "radarChart":
            .radar
        default:
            nil
        }
    }

    private static func axis(_ element: XMLElement) -> Axis {
        var axis = Axis()
        axis.isDeleted = element.chart("delete")?.attributeValue("val").map { $0 == "1" || $0 == "true" } ?? false
        if let scaling = element.chart("scaling") {
            axis.minimum = scaling.chart("min")?.attributeValue("val").flatMap(Double.init)
            axis.maximum = scaling.chart("max")?.attributeValue("val").flatMap(Double.init)
            axis.isReversed = scaling.chart("orientation")?.attributeValue("val") == "maxMin"
        }
        if let format = element.chart("numFmt"), format.attributeValue("sourceLinked") != "1" {
            axis.formatCode = format.attributeValue("formatCode")
        }
        axis.hasGridlines = element.chart("majorGridlines") != nil
        if let title = element.chart("title") {
            axis.title = title.chart("tx").flatMap { text($0, cells: { _ in [] }) } ?? "축 제목"
        }
        return axis
    }

    private static func labels(_ element: XMLElement) -> Labels {
        guard element.chart("delete")?.attributeValue("val") != "1" else {
            return Labels()
        }
        func isOn(_ name: String) -> Bool {
            element.chart(name)?.attributeValue("val").map { $0 == "1" || $0 == "true" } ?? false
        }
        return Labels(
            value: isOn("showVal"),
            percent: isOn("showPercent"),
            category: isOn("showCatName")
        )
    }

    /// A title or series name: rich text, a cell reference's cached text, or a literal.
    private static func text(_ element: XMLElement?, cells: (String) -> [XLSXWorkbook.Cell?]) -> String? {
        guard let element else {
            return nil
        }
        if let rich = element.chart("rich") {
            let paragraphs = rich.children("p", in: OOXMLNamespace.a).map { paragraph in
                paragraph.elements
                    .filter { $0.localName == "r" || $0.localName == "fld" }
                    .compactMap { $0.child("t", in: OOXMLNamespace.a)?.stringValue }
                    .joined()
            }
            let text = paragraphs
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return text.isEmpty ? nil : text
        }
        if let reference = element.chart("strRef") {
            let cached = reference.chart("strCache")?.charts("pt").compactMap { $0.chart("v")?.stringValue } ?? []
            if !cached.isEmpty {
                return cached.joined(separator: " ")
            }
            let fromCells = reference.chart("f")?.stringValue
                .map(cells)?
                .compactMap { $0?.text }
                .joined(separator: " ")
            return fromCells?.isEmpty == false ? fromCells : nil
        }
        return element.chart("v")?.stringValue
    }

    private static func numbers(
        _ element: XMLElement?,
        cells: (String) -> [XLSXWorkbook.Cell?]
    ) -> (values: [Double?], formatCode: String?) {
        guard let element else {
            return ([], nil)
        }
        let source = element.chart("numRef") ?? element.chart("numLit")
        if let cache = source?.chart("numCache") ?? element.chart("numLit") {
            let count = cache.chart("ptCount")?.attributeValue("val").flatMap(Int.init) ?? 0
            var values = [Double?](repeating: nil, count: count)
            for point in cache.charts("pt") {
                guard let index = point.attributeValue("idx").flatMap(Int.init),
                      let value = point.chart("v")?.stringValue.flatMap(Double.init)
                else {
                    continue
                }
                if index >= values.count {
                    values += [Double?](repeating: nil, count: index + 1 - values.count)
                }
                values[index] = value
            }
            return (values, cache.chart("formatCode")?.stringValue)
        }
        if let formula = source?.chart("f")?.stringValue {
            return (cells(formula).map { $0?.number }, nil)
        }
        return ([], nil)
    }

    private static func strings(
        _ element: XMLElement?,
        formats: NumberFormats,
        cells: (String) -> [XLSXWorkbook.Cell?]
    ) -> [String] {
        guard let element else {
            return []
        }
        if let reference = element.chart("multiLvlStrRef") {
            // The innermost level labels each point.
            let level = reference.chart("multiLvlStrCache")?.chart("lvl")
            return points(level, count: reference.chart("multiLvlStrCache")?.chart("ptCount")) { $0 }
        }
        if let reference = element.chart("strRef") ?? element.chart("strLit") {
            let cache = reference.chart("strCache") ?? (reference.localName == "strLit" ? reference : nil)
            if let cache {
                return points(cache, count: cache.chart("ptCount")) { $0 }
            }
            return reference.chart("f")?.stringValue.map(cells)?.map { $0?.text ?? "" } ?? []
        }
        if let reference = element.chart("numRef") ?? element.chart("numLit") {
            let cache = reference.chart("numCache") ?? (reference.localName == "numLit" ? reference : nil)
            if let cache {
                let code = cache.chart("formatCode")?.stringValue ?? "General"
                return points(cache, count: cache.chart("ptCount")) { text in
                    Double(text).map { formats.text(for: $0, code: code) } ?? text
                }
            }
            return reference.chart("f")?.stringValue.map(cells)?.map { $0?.text ?? "" } ?? []
        }
        return []
    }

    private static func points(
        _ cache: XMLElement?,
        count: XMLElement?,
        transform: (String) -> String
    ) -> [String] {
        guard let cache else {
            return []
        }
        var texts = [String](
            repeating: "",
            count: count?.attributeValue("val").flatMap(Int.init) ?? 0
        )
        for point in cache.charts("pt") {
            guard let index = point.attributeValue("idx").flatMap(Int.init) else {
                continue
            }
            if index >= texts.count {
                texts += [String](repeating: "", count: index + 1 - texts.count)
            }
            texts[index] = transform(point.chart("v")?.stringValue ?? "")
        }
        return texts
    }
}

extension XMLElement {
    func chart(_ name: String) -> XMLElement? {
        child(name, in: ChartNamespace.c)
    }

    func charts(_ name: String) -> [XMLElement] {
        children(name, in: ChartNamespace.c)
    }
}
