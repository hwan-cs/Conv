import AppKit

/// An `XLSXChart` drawn as SVG in Excel's default look: gray text, light gridlines, the title on
/// top and the legend where the chart puts it. Columns, bars, lines and areas (clustered,
/// stacked or 100%), pies, doughnuts, scatter and radar charts, with a second value axis.
struct ChartSVGWriter {
    let chart: XLSXChart
    /// In points; the SVG scales to whatever box it is placed in.
    let size: CGSize
    let fontName: String
    let formats: NumberFormats

    private static let textColor = "#595959"
    private static let gridColor = "#D9D9D9"
    private static let axisColor = "#BFBFBF"
    private static let labelSize = 9.0

    private var titleSize: Double {
        min(14, max(9, size.height / 14))
    }

    func svg() -> String {
        var body = ""
        var area = CGRect(origin: .zero, size: size).insetBy(dx: 7, dy: 7)

        if let title = chart.title, !title.isEmpty {
            let fontSize = fitted(
                title,
                size: titleSize,
                width: area.width
            )
            body += text(
                title,
                x: area.midX,
                y: area.minY + fontSize,
                size: fontSize,
                anchor: "middle"
            )
            area.origin.y += fontSize * 1.6
            area.size.height -= fontSize * 1.6
        }

        let entries = legendEntries()
        if let position = chart.legend, !entries.isEmpty {
            body += legend(
                entries,
                position: position,
                area: &area
            )
        }

        if area.width > 10, area.height > 10 {
            switch chart.groups.first?.kind {
            case .pie, .doughnut:
                body += pie(in: area)
            case .scatter:
                body += scatter(in: area)
            case .radar:
                body += radar(in: area)
            default:
                body += categoryChart(in: area)
            }
        }

        let family = SheetHTMLWriter.fontFamily(fontName).replacingOccurrences(of: "\"", with: "'")
        return """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(Self.number(size.width)) \(Self.number(size.height))" \
            width="100%" height="100%" preserveAspectRatio="none" font-family="\(family)">\
            <rect x="0.5" y="0.5" width="\(Self.number(size.width - 1))" height="\(Self.number(size.height - 1))" \
            fill="#FFFFFF" stroke="\(Self.gridColor)" stroke-width="0.75"/>\
            \(body)</svg>
            """
    }

    // MARK: Legend

    private struct Entry {
        var name: String
        var color: String
        var isLine: Bool
    }

    private func legendEntries() -> [Entry] {
        guard let first = chart.groups.first else {
            return []
        }
        if first.kind == .pie || first.kind == .doughnut, let series = first.series.first {
            return series.values.indices.map { index in
                Entry(
                    name: series.categories.indices.contains(index) ? series.categories[index] : String(index + 1),
                    color: series.pointColors[index] ?? series.color,
                    isLine: false
                )
            }
        }
        return chart.groups.flatMap { group in
            group.series.map { series in
                Entry(
                    name: series.name,
                    color: series.color,
                    isLine: [.line, .scatter, .radar].contains(group.kind)
                )
            }
        }
    }

    private func legend(
        _ entries: [Entry],
        position: String,
        area: inout CGRect
    ) -> String {
        let size = Self.labelSize
        let swatch = 7.0
        let rowHeight = size * 1.7
        let widths = entries.map { swatch + 4 + width($0.name, size: size) }
        var svg = ""

        func draw(
            _ entry: Entry,
            x: Double,
            y: Double
        ) {
            if entry.isLine {
                svg += "<line x1=\"\(Self.number(x))\" y1=\"\(Self.number(y))\" x2=\"\(Self.number(x + swatch + 4))\" y2=\"\(Self.number(y))\" stroke=\"\(entry.color)\" stroke-width=\"2\"/>"
            } else {
                svg += "<rect x=\"\(Self.number(x))\" y=\"\(Self.number(y - swatch / 2))\" width=\"\(Self.number(swatch))\" height=\"\(Self.number(swatch))\" fill=\"\(entry.color)\"/>"
            }
            svg += text(
                entry.name,
                x: x + swatch + (entry.isLine ? 8 : 4),
                y: y + size * 0.35,
                size: size
            )
        }

        switch position {
        case "b", "t":
            // Rows of entries, centered, as many to a row as fit.
            var rows: [[Int]] = [[]]
            var rowWidth = 0.0
            for (index, width) in widths.enumerated() {
                let needed = width + 12
                if rowWidth + needed > area.width, !(rows.last?.isEmpty ?? true) {
                    rows.append([])
                    rowWidth = 0
                }
                rows[rows.count - 1].append(index)
                rowWidth += needed
            }
            let height = Double(rows.count) * rowHeight
            let top = position == "b" ? area.maxY - height : area.minY
            for (rowIndex, row) in rows.enumerated() {
                let total = row.reduce(0) { $0 + widths[$1] + 12 } - 12
                var x = area.midX - total / 2
                let y = top + Double(rowIndex) * rowHeight + rowHeight / 2
                for index in row {
                    draw(
                        entries[index],
                        x: x,
                        y: y
                    )
                    x += widths[index] + 12
                }
            }
            if position == "t" {
                area.origin.y += height + 4
            }
            area.size.height -= height + 4
        default:
            let columnWidth = min(widths.max() ?? 0, area.width * 0.4)
            let height = Double(entries.count) * rowHeight
            let x = position == "l" ? area.minX : area.maxX - columnWidth
            var y = position == "tr" ? area.minY + rowHeight / 2 : area.midY - height / 2 + rowHeight / 2
            for entry in entries {
                draw(
                    entry,
                    x: x,
                    y: y
                )
                y += rowHeight
            }
            if position == "l" {
                area.origin.x += columnWidth + 8
            }
            area.size.width -= columnWidth + 8
        }
        return svg
    }

    // MARK: Category charts

    /// Columns, bars, lines and areas sharing one category axis.
    private func categoryChart(in area: CGRect) -> String {
        let groups = chart.groups.filter { [.column, .bar, .line, .area].contains($0.kind) }
        guard !groups.isEmpty else {
            return ""
        }
        let horizontal = groups.contains { $0.kind == .bar }
        let count = groups.flatMap(\.series).map { max($0.values.count, $0.categories.count) }.max() ?? 0
        guard count > 0 else {
            return ""
        }
        let categories = (0..<count).map { index in
            let named = groups.flatMap(\.series).first { $0.categories.indices.contains(index) && !$0.categories[index].isEmpty }
            return named?.categories[index] ?? String(index + 1)
        }
        let primaryGroups = groups.filter { !$0.isSecondary }
        let secondaryGroups = groups.filter(\.isSecondary)
        let primary = scale(
            for: primaryGroups.isEmpty ? groups : primaryGroups,
            axis: chart.valueAxis
        )
        let secondary = secondaryGroups.isEmpty ? nil : scale(
            for: secondaryGroups,
            axis: chart.secondaryAxis ?? XLSXChart.Axis()
        )
        let primaryLabels = primary.ticks.map { tick in
            label(
                for: tick,
                axis: chart.valueAxis,
                groups: primaryGroups
            )
        }
        let secondaryLabels = secondary?.ticks.map { tick in
            label(
                for: tick,
                axis: chart.secondaryAxis ?? XLSXChart.Axis(),
                groups: secondaryGroups
            )
        } ?? []
        let size = Self.labelSize
        var svg = ""

        // Room for the axes' labels and titles.
        var plot = area
        let valueTitle = chart.valueAxis.isDeleted ? nil : chart.valueAxis.title
        let categoryTitle = chart.categoryAxis.isDeleted ? nil : chart.categoryAxis.title
        if horizontal {
            let widest = categories.map { width($0, size: size) }.max() ?? 0
            let categoryWidth = chart.categoryAxis.isDeleted ? 0 : min(widest + 6, area.width * 0.35)
            plot.origin.x += categoryWidth + (categoryTitle == nil ? 0 : size * 1.6)
            plot.size.width -= categoryWidth + (categoryTitle == nil ? 0 : size * 1.6)
            let valueHeight = chart.valueAxis.isDeleted ? 0 : size * 1.6
            plot.size.height -= valueHeight + (valueTitle == nil ? 0 : size * 1.6)
            // The last value label is centered on the plot's right edge.
            plot.size.width -= (primaryLabels.last.map { width($0, size: size) } ?? 0) / 2
        } else {
            let valueWidth = chart.valueAxis.isDeleted ? 0 : (primaryLabels.map { width($0, size: size) }.max() ?? 0) + 6
            plot.origin.x += valueWidth + (valueTitle == nil ? 0 : size * 1.6)
            plot.size.width -= valueWidth + (valueTitle == nil ? 0 : size * 1.6)
            if secondary != nil {
                plot.size.width -= (secondaryLabels.map { width($0, size: size) }.max() ?? 0) + 6
            }
            plot.origin.y += size / 2
            plot.size.height -= size / 2
        }

        var labelStep = 1
        var rotated = false
        if !horizontal {
            let band = plot.width / Double(count)
            let widest = categories.map { width($0, size: size) }.max() ?? 0
            var height = size * 1.6
            if !chart.categoryAxis.isDeleted, widest > band - 2 {
                rotated = true
                height = min(widest, plot.height * 0.4) * 0.72 + size * 1.2
                labelStep = max(1, Int((size * 1.3 / band).rounded(.up)))
                // The first label leans left past the plot's edge.
                let firstReach = width(categories[0], size: size) * 0.72 - band / 2
                let shortfall = firstReach - (plot.minX - area.minX)
                if shortfall > 0 {
                    plot.origin.x += shortfall
                    plot.size.width -= shortfall
                }
            }
            if chart.categoryAxis.isDeleted {
                height = 0
            }
            plot.size.height -= height + (categoryTitle == nil ? 0 : size * 1.6)
        } else {
            // Labels stacked closer than a line apart take turns.
            let band = plot.height / Double(count)
            labelStep = max(1, Int((size * 1.2 / band).rounded(.up)))
        }
        guard plot.width > 4, plot.height > 4 else {
            return ""
        }

        // Value position along the value direction, and category bands across it.
        func valuePosition(_ value: Double, _ scale: Scale) -> Double {
            let fraction = (value - scale.minimum) / (scale.maximum - scale.minimum)
            return horizontal ? plot.minX + fraction * plot.width : plot.maxY - fraction * plot.height
        }
        let bandLength = (horizontal ? plot.height : plot.width) / Double(count)
        func bandStart(_ index: Int) -> Double {
            let order = chart.categoryAxis.isReversed != horizontal ? count - 1 - index : index
            return horizontal ? plot.minY + Double(order) * bandLength : plot.minX + Double(order) * bandLength
        }

        // Gridlines and value labels.
        for (index, tick) in primary.ticks.enumerated() {
            let position = valuePosition(tick, primary)
            if chart.valueAxis.hasGridlines {
                svg += horizontal
                    ? line(
                        position,
                        plot.minY,
                        position,
                        plot.maxY,
                        color: Self.gridColor
                    )
                    : line(
                        plot.minX,
                        position,
                        plot.maxX,
                        position,
                        color: Self.gridColor
                    )
            }
            if !chart.valueAxis.isDeleted {
                svg += horizontal
                    ? text(
                        primaryLabels[index],
                        x: position,
                        y: plot.maxY + size * 1.3,
                        size: size,
                        anchor: "middle"
                    )
                    : text(
                        primaryLabels[index],
                        x: plot.minX - 4,
                        y: position + size * 0.35,
                        size: size,
                        anchor: "end"
                    )
            }
        }
        if let secondary, !horizontal {
            for (index, tick) in secondary.ticks.enumerated() {
                svg += text(
                    secondaryLabels[index],
                    x: plot.maxX + 4,
                    y: valuePosition(tick, secondary) + size * 0.35,
                    size: size
                )
            }
        }

        // Category labels and the axis line at zero.
        if !chart.categoryAxis.isDeleted {
            for (index, category) in categories.enumerated() where index % labelStep == 0 {
                let center = bandStart(index) + bandLength / 2
                if horizontal {
                    svg += text(
                        category,
                        x: plot.minX - 4,
                        y: center + size * 0.35,
                        size: size,
                        anchor: "end"
                    )
                } else if rotated {
                    svg += "<text x=\"\(Self.number(center))\" y=\"\(Self.number(plot.maxY + size))\" font-size=\"\(Self.number(size))\" fill=\"\(Self.textColor)\" text-anchor=\"end\" transform=\"rotate(-45 \(Self.number(center)) \(Self.number(plot.maxY + size)))\">\(Self.escape(category))</text>"
                } else {
                    svg += text(
                        category,
                        x: center,
                        y: plot.maxY + size * 1.3,
                        size: size,
                        anchor: "middle"
                    )
                }
            }
        }
        let zero = valuePosition(min(max(0, primary.minimum), primary.maximum), primary)
        svg += horizontal
            ? line(
                zero,
                plot.minY,
                zero,
                plot.maxY,
                color: Self.axisColor
            )
            : line(
                plot.minX,
                zero,
                plot.maxX,
                zero,
                color: Self.axisColor
            )

        // Axis titles.
        if let valueTitle {
            svg += horizontal
                ? text(
                    valueTitle,
                    x: plot.midX,
                    y: area.maxY - 2,
                    size: size,
                    anchor: "middle",
                    bold: true
                )
                : rotatedText(
                    valueTitle,
                    x: area.minX + size,
                    y: plot.midY,
                    size: size
                )
        }
        if let categoryTitle {
            svg += horizontal
                ? rotatedText(
                    categoryTitle,
                    x: area.minX + size,
                    y: plot.midY,
                    size: size
                )
                : text(
                    categoryTitle,
                    x: plot.midX,
                    y: area.maxY - 2,
                    size: size,
                    anchor: "middle",
                    bold: true
                )
        }

        // Series: areas at the back, then bars, then lines on top.
        let order: [XLSXChart.Kind] = [.area, .column, .bar, .line]
        for kind in order {
            for group in groups where group.kind == kind {
                let scale = group.isSecondary ? (secondary ?? primary) : primary
                let stacks = Self.stacks(group, count: count)
                switch kind {
                case .column, .bar:
                    svg += bars(
                        group,
                        stacks: stacks,
                        count: count,
                        bandStart: bandStart,
                        bandLength: bandLength,
                        horizontal: horizontal
                    ) {
                        valuePosition($0, scale)
                    }
                default:
                    svg += lines(
                        group,
                        stacks: stacks,
                        count: count,
                        plot: plot,
                        bandStart: bandStart,
                        bandLength: bandLength
                    ) {
                        valuePosition($0, scale)
                    }
                }
            }
        }
        return svg
    }

    /// Each series' segment per category: where it starts and ends, after stacking.
    private static func stacks(_ group: XLSXChart.Group, count: Int) -> [[(start: Double, end: Double)?]] {
        var positive = [Double](repeating: 0, count: count)
        var negative = [Double](repeating: 0, count: count)
        var totals = [Double](repeating: 0, count: count)
        if group.grouping == .percentStacked {
            for series in group.series {
                for (index, value) in series.values.enumerated() where index < count {
                    totals[index] += abs(value ?? 0)
                }
            }
        }
        return group.series.map { series in
            (0..<count).map { index -> (start: Double, end: Double)? in
                guard index < series.values.count, var value = series.values[index] else {
                    return nil
                }
                if group.grouping == .percentStacked {
                    value = totals[index] > 0 ? value / totals[index] : 0
                }
                guard group.grouping != .clustered else {
                    return (0, value)
                }
                if value >= 0 {
                    defer {
                        positive[index] += value
                    }
                    return (positive[index], positive[index] + value)
                }
                defer {
                    negative[index] += value
                }
                return (negative[index], negative[index] + value)
            }
        }
    }

    private func bars(
        _ group: XLSXChart.Group,
        stacks: [[(start: Double, end: Double)?]],
        count: Int,
        bandStart: (Int) -> Double,
        bandLength: Double,
        horizontal: Bool,
        position: (Double) -> Double
    ) -> String {
        let seriesCount = group.grouping == .clustered ? group.series.count : 1
        let overlap = min(max(group.overlap, -100), 100) / 100
        // Bars, the gaps between them (negative overlap) and the gap around the cluster fill the band.
        let barLength = bandLength / (1 + Double(seriesCount - 1) * (1 - overlap) + group.gapWidth / 100)
        var svg = ""
        for (seriesIndex, series) in group.series.enumerated() {
            let slot = group.grouping == .clustered ? Double(seriesIndex) : 0
            for index in 0..<count {
                guard let segment = stacks[seriesIndex][index] else {
                    continue
                }
                let across = bandStart(index) + barLength * group.gapWidth / 200 + slot * barLength * (1 - overlap)
                let from = position(segment.start)
                let to = position(segment.end)
                let color = series.pointColors[index] ?? series.color
                let rect = horizontal
                    ? CGRect(
                        x: min(from, to),
                        y: across,
                        width: abs(to - from),
                        height: barLength
                    )
                    : CGRect(
                        x: across,
                        y: min(from, to),
                        width: barLength,
                        height: abs(to - from)
                    )
                svg += "<rect x=\"\(Self.number(rect.minX))\" y=\"\(Self.number(rect.minY))\" width=\"\(Self.number(rect.width))\" height=\"\(Self.number(rect.height))\" fill=\"\(color)\"/>"
                if series.labels.value, let value = series.values[index] {
                    let label = formatted(value, series: series)
                    let inside = group.grouping != .clustered
                    if horizontal {
                        let x = inside ? rect.midX : rect.maxX + 3
                        svg += text(
                            label,
                            x: x,
                            y: rect.midY + Self.labelSize * 0.35,
                            size: Self.labelSize,
                            anchor: inside ? "middle" : "start"
                        )
                    } else {
                        // Above a bar going up, below one going down, or in the middle of a stack.
                        let outside = segment.end >= segment.start ? rect.minY - 3 : rect.maxY + Self.labelSize
                        let y = inside ? rect.midY + Self.labelSize * 0.35 : outside
                        svg += text(
                            label,
                            x: rect.midX,
                            y: y,
                            size: Self.labelSize,
                            anchor: "middle"
                        )
                    }
                }
            }
        }
        return svg
    }

    private func lines(
        _ group: XLSXChart.Group,
        stacks: [[(start: Double, end: Double)?]],
        count: Int,
        plot: CGRect,
        bandStart: (Int) -> Double,
        bandLength: Double,
        position: (Double) -> Double
    ) -> String {
        func across(_ index: Int) -> Double {
            if group.isBetweenCategories || count < 2 {
                return bandStart(index) + bandLength / 2
            }
            // On the category edges: the first and last points sit at the plot's sides.
            let step = (plot.width) / Double(count - 1)
            let order = chart.categoryAxis.isReversed ? count - 1 - index : index
            return plot.minX + Double(order) * step
        }
        var svg = ""
        for (seriesIndex, series) in group.series.enumerated() {
            let points = (0..<count).map { index -> CGPoint? in
                stacks[seriesIndex][index].map { CGPoint(x: across(index), y: position($0.end)) }
            }
            if group.kind == .area {
                // Down to the previous series' top when stacked, else to zero.
                let bases = (0..<count).map { index -> CGPoint? in
                    stacks[seriesIndex][index].map { CGPoint(x: across(index), y: position($0.start)) }
                }
                let top = points.compactMap { $0 }
                let bottom = bases.compactMap { $0 }.reversed()
                guard top.count > 1 else {
                    continue
                }
                let outline = (top + bottom).map { "\(Self.number($0.x)),\(Self.number($0.y))" }.joined(separator: " ")
                svg += "<polygon points=\"\(outline)\" fill=\"\(series.color)\"/>"
                continue
            }
            // A missing value breaks the line.
            var run: [CGPoint] = []
            for point in points + [nil] {
                if let point {
                    run.append(point)
                    continue
                }
                if run.count > 1 {
                    svg += "<path d=\"\(Self.path(run, smooth: series.isSmooth))\" fill=\"none\" stroke=\"\(series.color)\" stroke-width=\"2.25\" stroke-linejoin=\"round\" stroke-linecap=\"round\"/>"
                }
                run = []
            }
            for (index, point) in points.enumerated() {
                guard let point else {
                    continue
                }
                if series.showsMarkers {
                    svg += marker(at: point, color: series.color)
                }
                if series.labels.value, let value = series.values[index] {
                    svg += text(
                        formatted(value, series: series),
                        x: point.x,
                        y: point.y - 5,
                        size: Self.labelSize,
                        anchor: "middle"
                    )
                }
            }
        }
        return svg
    }

    // MARK: Pie

    private func pie(in area: CGRect) -> String {
        guard let group = chart.groups.first,
              let series = group.series.first
        else {
            return ""
        }
        let values = series.values.map { max($0 ?? 0, 0) }
        let total = values.reduce(0, +)
        guard total > 0 else {
            return ""
        }
        let radius = min(area.width, area.height) / 2 * 0.92
        let center = CGPoint(x: area.midX, y: area.midY)
        let hole = group.kind == .doughnut ? radius * min(max(group.holeSize, 10), 90) / 100 : 0
        var svg = ""
        var angle = -Double.pi / 2
        var labels = ""
        for (index, value) in values.enumerated() where value > 0 {
            let sweep = value / total * 2 * .pi
            let color = series.pointColors[index] ?? series.color
            if sweep >= 2 * .pi - 0.0001 {
                svg += "<circle cx=\"\(Self.number(center.x))\" cy=\"\(Self.number(center.y))\" r=\"\(Self.number(radius))\" fill=\"\(color)\"/>"
                if hole > 0 {
                    svg += "<circle cx=\"\(Self.number(center.x))\" cy=\"\(Self.number(center.y))\" r=\"\(Self.number(hole))\" fill=\"#FFFFFF\"/>"
                }
            } else {
                let end = angle + sweep
                let large = sweep > .pi ? 1 : 0
                func point(_ angle: Double, _ length: Double) -> String {
                    "\(Self.number(center.x + cos(angle) * length)),\(Self.number(center.y + sin(angle) * length))"
                }
                var path = "M\(point(angle, radius)) A\(Self.number(radius)),\(Self.number(radius)) 0 \(large) 1 \(point(end, radius))"
                if hole > 0 {
                    path += " L\(point(end, hole)) A\(Self.number(hole)),\(Self.number(hole)) 0 \(large) 0 \(point(angle, hole)) Z"
                } else {
                    path += " L\(Self.number(center.x)),\(Self.number(center.y)) Z"
                }
                svg += "<path d=\"\(path)\" fill=\"\(color)\" stroke=\"#FFFFFF\" stroke-width=\"1\"/>"
            }

            if !series.labels.isEmpty {
                var parts: [String] = []
                if series.labels.category, series.categories.indices.contains(index) {
                    parts.append(series.categories[index])
                }
                if series.labels.value {
                    parts.append(formatted(value, series: series))
                }
                if series.labels.percent {
                    parts.append("\(Int((value / total * 100).rounded()))%")
                }
                let middle = angle + sweep / 2
                let distance = hole > 0 ? (radius + hole) / 2 : radius * 0.65
                let rgb = Int(color.dropFirst(), radix: 16) ?? 0
                labels += text(
                    parts.joined(separator: ", "),
                    x: center.x + cos(middle) * distance,
                    y: center.y + sin(middle) * distance + Self.labelSize * 0.35,
                    size: Self.labelSize,
                    anchor: "middle",
                    color: ColorMath.luminance(rgb) < 0.5 ? "#FFFFFF" : "#404040"
                )
            }
            angle += sweep
        }
        return svg + labels
    }

    // MARK: Scatter

    private func scatter(in area: CGRect) -> String {
        let series = chart.groups.filter { $0.kind == .scatter }.flatMap(\.series)
        let xValues = series.flatMap { item in
            item.xValues.isEmpty ? item.values.indices.map { Double($0 + 1) } : item.xValues.compactMap { $0 }
        }
        let yValues = series.flatMap { $0.values.compactMap { $0 } }
        guard let xRange = Self.range(xValues), let yRange = Self.range(yValues) else {
            return ""
        }
        let xScale = Self.niceScale(
            xRange,
            axis: chart.categoryAxis,
            startsAtZero: false
        )
        let yScale = Self.niceScale(
            yRange,
            axis: chart.valueAxis,
            startsAtZero: false
        )
        let size = Self.labelSize
        let xLabels = xScale.ticks.map { tick in
            label(
                for: tick,
                axis: chart.categoryAxis,
                groups: []
            )
        }
        let yLabels = yScale.ticks.map { tick in
            label(
                for: tick,
                axis: chart.valueAxis,
                groups: chart.groups
            )
        }

        var plot = area
        let yTitle = chart.valueAxis.isDeleted ? nil : chart.valueAxis.title
        let xTitle = chart.categoryAxis.isDeleted ? nil : chart.categoryAxis.title
        let labelWidth = chart.valueAxis.isDeleted ? 0 : (yLabels.map { width($0, size: size) }.max() ?? 0) + 6
        plot.origin.x += labelWidth + (yTitle == nil ? 0 : size * 1.6)
        plot.size.width -= labelWidth + (yTitle == nil ? 0 : size * 1.6) + (xLabels.last.map { width($0, size: size) } ?? 0) / 2
        plot.origin.y += size / 2
        plot.size.height -= size / 2 + (chart.categoryAxis.isDeleted ? 0 : size * 1.6) + (xTitle == nil ? 0 : size * 1.6)
        guard plot.width > 4, plot.height > 4 else {
            return ""
        }
        func x(_ value: Double) -> Double {
            plot.minX + (value - xScale.minimum) / (xScale.maximum - xScale.minimum) * plot.width
        }
        func y(_ value: Double) -> Double {
            plot.maxY - (value - yScale.minimum) / (yScale.maximum - yScale.minimum) * plot.height
        }

        var svg = ""
        for (index, tick) in yScale.ticks.enumerated() {
            if chart.valueAxis.hasGridlines {
                svg += line(
                    plot.minX,
                    y(tick),
                    plot.maxX,
                    y(tick),
                    color: Self.gridColor
                )
            }
            if !chart.valueAxis.isDeleted {
                svg += text(
                    yLabels[index],
                    x: plot.minX - 4,
                    y: y(tick) + size * 0.35,
                    size: size,
                    anchor: "end"
                )
            }
        }
        for (index, tick) in xScale.ticks.enumerated() {
            if chart.categoryAxis.hasGridlines {
                svg += line(
                    x(tick),
                    plot.minY,
                    x(tick),
                    plot.maxY,
                    color: Self.gridColor
                )
            }
            if !chart.categoryAxis.isDeleted {
                svg += text(
                    xLabels[index],
                    x: x(tick),
                    y: plot.maxY + size * 1.3,
                    size: size,
                    anchor: "middle"
                )
            }
        }
        let xAxis = y(min(max(0, yScale.minimum), yScale.maximum))
        let yAxis = x(min(max(0, xScale.minimum), xScale.maximum))
        svg += line(
            plot.minX,
            xAxis,
            plot.maxX,
            xAxis,
            color: Self.axisColor
        )
        svg += line(
            yAxis,
            plot.minY,
            yAxis,
            plot.maxY,
            color: Self.axisColor
        )
        if let yTitle {
            svg += rotatedText(
                yTitle,
                x: area.minX + size,
                y: plot.midY,
                size: size
            )
        }
        if let xTitle {
            svg += text(
                xTitle,
                x: plot.midX,
                y: area.maxY - 2,
                size: size,
                anchor: "middle",
                bold: true
            )
        }

        for item in series {
            let points = item.values.indices.compactMap { index -> CGPoint? in
                guard let value = item.values[index] else {
                    return nil
                }
                let xValue = item.xValues.isEmpty ? Double(index + 1) : (index < item.xValues.count ? item.xValues[index] : nil)
                return xValue.map { CGPoint(x: x($0), y: y(value)) }
            }
            if item.showsLine, points.count > 1 {
                svg += "<path d=\"\(Self.path(points, smooth: item.isSmooth))\" fill=\"none\" stroke=\"\(item.color)\" stroke-width=\"2.25\" stroke-linejoin=\"round\"/>"
            }
            if item.showsMarkers {
                for point in points {
                    svg += marker(at: point, color: item.color)
                }
            }
        }
        return svg
    }

    // MARK: Radar

    private func radar(in area: CGRect) -> String {
        let series = chart.groups.filter { $0.kind == .radar }.flatMap(\.series)
        let count = series.map(\.values.count).max() ?? 0
        guard count > 2, let range = Self.range(series.flatMap { $0.values.compactMap { $0 } }) else {
            return ""
        }
        let scale = Self.niceScale(
            range,
            axis: chart.valueAxis,
            startsAtZero: true
        )
        let size = Self.labelSize
        let categories = (0..<count).map { index in
            series.first { $0.categories.indices.contains(index) }?.categories[index] ?? String(index + 1)
        }
        let labelRoom = (categories.map { width($0, size: size) }.max() ?? 0) + 6
        let radius = max(10, min(area.width / 2 - labelRoom, area.height / 2 - size * 1.5))
        let center = CGPoint(x: area.midX, y: area.midY)
        func point(_ index: Int, _ value: Double) -> CGPoint {
            let angle = -Double.pi / 2 + Double(index) / Double(count) * 2 * .pi
            let length = (value - scale.minimum) / (scale.maximum - scale.minimum) * radius
            return CGPoint(x: center.x + cos(angle) * length, y: center.y + sin(angle) * length)
        }

        var svg = ""
        for tick in scale.ticks {
            let ring = (0..<count).map { point($0, tick) }
            svg += "<polygon points=\"\(ring.map { "\(Self.number($0.x)),\(Self.number($0.y))" }.joined(separator: " "))\" fill=\"none\" stroke=\"\(Self.gridColor)\" stroke-width=\"0.75\"/>"
            let tickLabel = label(
                for: tick,
                axis: chart.valueAxis,
                groups: chart.groups
            )
            svg += text(
                tickLabel,
                x: center.x - 3,
                y: point(0, tick).y + size * 0.35,
                size: size * 0.9,
                anchor: "end"
            )
        }
        for index in 0..<count {
            let end = point(index, scale.maximum)
            svg += line(
                center.x,
                center.y,
                end.x,
                end.y,
                color: Self.gridColor
            )
            let outside = point(index, scale.maximum + (scale.maximum - scale.minimum) * 0.08)
            let anchor = abs(outside.x - center.x) < 2 ? "middle" : (outside.x > center.x ? "start" : "end")
            svg += text(
                categories[index],
                x: outside.x,
                y: outside.y + size * 0.35,
                size: size,
                anchor: anchor
            )
        }
        for item in series {
            let points = (0..<count).map { point($0, item.values.indices.contains($0) ? item.values[$0] ?? 0 : 0) }
            svg += "<polygon points=\"\(points.map { "\(Self.number($0.x)),\(Self.number($0.y))" }.joined(separator: " "))\" fill=\"none\" stroke=\"\(item.color)\" stroke-width=\"2.25\" stroke-linejoin=\"round\"/>"
            if item.showsMarkers {
                for point in points {
                    svg += marker(at: point, color: item.color)
                }
            }
        }
        return svg
    }

    // MARK: Scales

    struct Scale {
        var minimum: Double
        var maximum: Double
        var step: Double

        var ticks: [Double] {
            guard step > 0 else {
                return [minimum, maximum]
            }
            let count = Int(((maximum - minimum) / step).rounded())
            return (0...max(count, 1)).map { minimum + Double($0) * step }
        }
    }

    private func scale(for groups: [XLSXChart.Group], axis: XLSXChart.Axis) -> Scale {
        if groups.contains(where: { $0.grouping == .percentStacked }) {
            let hasNegative = groups.flatMap(\.series).contains { $0.values.contains { ($0 ?? 0) < 0 } }
            return Scale(
                minimum: axis.minimum ?? (hasNegative ? -1 : 0),
                maximum: axis.maximum ?? 1,
                step: 0.2
            )
        }
        var values: [Double] = []
        for group in groups {
            let count = group.series.map(\.values.count).max() ?? 0
            for stack in Self.stacks(group, count: count) {
                for segment in stack.compactMap({ $0 }) {
                    values.append(segment.end)
                }
            }
        }
        let startsAtZero = groups.contains { $0.kind != .line }
        return Self.niceScale(
            Self.range(values) ?? (0, 1),
            axis: axis,
            startsAtZero: startsAtZero
        )
    }

    private static func range(_ values: [Double]) -> (Double, Double)? {
        guard let low = values.min(), let high = values.max() else {
            return nil
        }
        return (low, high)
    }

    /// Excel's automatic axis: from zero when the data sits well above it, five percent of
    /// headroom past the extremes, then up to the next of about eight round steps of 1, 2 or 5.
    static func niceScale(
        _ range: (Double, Double),
        axis: XLSXChart.Axis,
        startsAtZero: Bool
    ) -> Scale {
        var low = range.0
        var high = range.1
        if axis.minimum == nil, low >= 0, startsAtZero || low < high * 5 / 6 {
            low = 0
        }
        if axis.maximum == nil, high <= 0, startsAtZero || high > low * 5 / 6 {
            high = 0
        }
        let span = high - low
        if axis.maximum == nil, high > 0 {
            high += span * 0.05
        }
        if axis.minimum == nil, low < 0 {
            low -= span * 0.05
        }
        low = axis.minimum ?? low
        high = axis.maximum ?? high
        if high <= low {
            high = low + (low == 0 ? 1 : abs(low) * 0.1)
        }
        let rough = (high - low) / 8
        let magnitude = pow(10, floor(log10(rough)))
        let step = [1.0, 2, 5, 10]
            .map { $0 * magnitude }
            .first { $0 >= rough } ?? magnitude * 10
        return Scale(
            minimum: axis.minimum ?? floor(low / step) * step,
            maximum: axis.maximum ?? ceil(high / step) * step,
            step: step
        )
    }

    // MARK: Text

    private func label(
        for value: Double,
        axis: XLSXChart.Axis,
        groups: [XLSXChart.Group]
    ) -> String {
        if groups.contains(where: { $0.grouping == .percentStacked }) {
            return formats.text(for: value, code: axis.formatCode ?? "0%")
        }
        let code = axis.formatCode ?? groups.flatMap(\.series).first?.formatCode ?? "General"
        // Floating-point noise such as 0.30000000000000004 would show as such in General.
        let rounded = (value * 1e9).rounded() / 1e9
        return formats.text(for: rounded, code: code)
    }

    private func formatted(_ value: Double, series: XLSXChart.Series) -> String {
        formats.text(for: value, code: series.formatCode ?? "General")
    }

    private func width(_ text: String, size: Double) -> Double {
        let font = NSFont(name: fontName, size: size)
            ?? NSFont(name: "Apple SD Gothic Neo", size: size)
            ?? NSFont.systemFont(ofSize: size)
        return (text as NSString).size(withAttributes: [.font: font]).width
    }

    /// A size at most `size` that fits `text` in `width`.
    private func fitted(
        _ text: String,
        size: Double,
        width available: Double
    ) -> Double {
        let needed = width(text, size: size)
        guard needed > available, needed > 0 else {
            return size
        }
        return max(7, size * available / needed)
    }

    private func text(
        _ string: String,
        x: Double,
        y: Double,
        size: Double,
        anchor: String = "start",
        color: String = ChartSVGWriter.textColor,
        bold: Bool = false
    ) -> String {
        let weight = bold ? " font-weight=\"bold\"" : ""
        return "<text x=\"\(Self.number(x))\" y=\"\(Self.number(y))\" font-size=\"\(Self.number(size))\" fill=\"\(color)\" text-anchor=\"\(anchor)\"\(weight)>\(Self.escape(string))</text>"
    }

    private func rotatedText(
        _ string: String,
        x: Double,
        y: Double,
        size: Double
    ) -> String {
        "<text x=\"\(Self.number(x))\" y=\"\(Self.number(y))\" font-size=\"\(Self.number(size))\" fill=\"\(Self.textColor)\" text-anchor=\"middle\" font-weight=\"bold\" transform=\"rotate(-90 \(Self.number(x)) \(Self.number(y)))\">\(Self.escape(string))</text>"
    }

    private func line(
        _ x1: Double,
        _ y1: Double,
        _ x2: Double,
        _ y2: Double,
        color: String
    ) -> String {
        "<line x1=\"\(Self.number(x1))\" y1=\"\(Self.number(y1))\" x2=\"\(Self.number(x2))\" y2=\"\(Self.number(y2))\" stroke=\"\(color)\" stroke-width=\"0.75\"/>"
    }

    private func marker(at point: CGPoint, color: String) -> String {
        "<circle cx=\"\(Self.number(point.x))\" cy=\"\(Self.number(point.y))\" r=\"2.5\" fill=\"\(color)\" stroke=\"\(color)\" stroke-width=\"0.75\"/>"
    }

    /// Straight segments, or a Catmull-Rom curve through the points when smoothed.
    private static func path(_ points: [CGPoint], smooth: Bool) -> String {
        guard let first = points.first else {
            return ""
        }
        var path = "M\(number(first.x)),\(number(first.y))"
        guard smooth, points.count > 2 else {
            for point in points.dropFirst() {
                path += " L\(number(point.x)),\(number(point.y))"
            }
            return path
        }
        for index in 1..<points.count {
            let previous = points[max(index - 2, 0)]
            let start = points[index - 1]
            let end = points[index]
            let next = points[min(index + 1, points.count - 1)]
            let control1 = CGPoint(x: start.x + (end.x - previous.x) / 6, y: start.y + (end.y - previous.y) / 6)
            let control2 = CGPoint(x: end.x - (next.x - start.x) / 6, y: end.y - (next.y - start.y) / 6)
            path += " C\(number(control1.x)),\(number(control1.y)) \(number(control2.x)),\(number(control2.y)) \(number(end.x)),\(number(end.y))"
        }
        return path
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private static func escape(_ text: String) -> String {
        HwpDocxWriter.escape(text)
    }
}
