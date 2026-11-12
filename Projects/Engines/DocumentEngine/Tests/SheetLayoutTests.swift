import AppKit
import Foundation
import Testing
import ZIPFoundation
@testable import DocumentEngine

/// Workbooks written part by part, for what the CSV path can't make: drawings, charts and print settings.
enum TestWorkbook {
    static let main = SpreadsheetNamespace.main
    static let relationship = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    /// One sheet with `sheetData`, extra worksheet elements, and optional drawing and chart parts.
    static func write(
        to url: URL,
        sheetData: String,
        worksheetExtras: String = "",
        workbookExtras: String = "",
        drawing: String? = nil,
        chart: String? = nil,
        media: Data? = nil
    ) throws -> URL {
        var parts: [String: Data] = [
            "[Content_Types].xml": Data("""
                <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
                <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
                <Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/></Types>
                """.utf8),
            "_rels/.rels": Data("""
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
                <Relationship Id="rId1" Type="\(relationship)/officeDocument" Target="xl/workbook.xml"/></Relationships>
                """.utf8),
            "xl/workbook.xml": Data("""
                <workbook xmlns="\(main)" xmlns:r="\(relationship)"><sheets><sheet name="표" sheetId="1" r:id="rId1"/></sheets>\(workbookExtras)</workbook>
                """.utf8),
            "xl/_rels/workbook.xml.rels": Data("""
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
                <Relationship Id="rId1" Type="\(relationship)/worksheet" Target="worksheets/sheet1.xml"/></Relationships>
                """.utf8),
            "xl/worksheets/sheet1.xml": Data("""
                <worksheet xmlns="\(main)" xmlns:r="\(relationship)"><sheetData>\(sheetData)</sheetData>\(worksheetExtras)\
                \(drawing == nil ? "" : "<drawing r:id=\"rId1\"/>")</worksheet>
                """.utf8),
        ]
        if let drawing {
            parts["xl/worksheets/_rels/sheet1.xml.rels"] = Data("""
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
                <Relationship Id="rId1" Type="\(relationship)/drawing" Target="../drawings/drawing1.xml"/></Relationships>
                """.utf8)
            parts["xl/drawings/drawing1.xml"] = Data(drawing.utf8)
            parts["xl/drawings/_rels/drawing1.xml.rels"] = Data("""
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
                <Relationship Id="rId1" Type="\(relationship)/image" Target="../media/image1.png"/>\
                <Relationship Id="rId2" Type="\(relationship)/chart" Target="../charts/chart1.xml"/></Relationships>
                """.utf8)
        }
        if let chart {
            parts["xl/charts/chart1.xml"] = Data(chart.utf8)
        }
        if let media {
            parts["xl/media/image1.png"] = media
        }

        let archive = try Archive(
            url: url,
            accessMode: .create
        )
        for (path, data) in parts {
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                compressionMethod: .deflate
            ) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        }
        return url
    }

    /// `count` rows of a number in column A, 15 points tall.
    static func rows(_ count: Int, from start: Int = 1) -> String {
        (start..<(start + count))
            .map { "<row r=\"\($0)\"><c r=\"A\($0)\"><v>\($0)</v></c></row>" }
            .joined()
    }

    /// A drawing part with one anchor holding `object`.
    static func drawing(from: (row: Int, column: Int), to: (row: Int, column: Int), object: String) -> String {
        """
        <xdr:wsDr xmlns:xdr="\(SpreadsheetDrawingNamespace.xdr)" xmlns:a="\(OOXMLNamespace.a)" xmlns:r="\(relationship)" xmlns:c="\(ChartNamespace.c)">\
        <xdr:twoCellAnchor><xdr:from><xdr:col>\(from.column)</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>\(from.row)</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:from>\
        <xdr:to><xdr:col>\(to.column)</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>\(to.row)</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:to>\
        \(object)<xdr:clientData/></xdr:twoCellAnchor></xdr:wsDr>
        """
    }

    static let picture = """
        <xdr:pic><xdr:nvPicPr><xdr:cNvPr id="2" name="Picture 1"/><xdr:cNvPicPr/></xdr:nvPicPr>\
        <xdr:blipFill><a:blip r:embed="rId1"/><a:srcRect l="25000"/><a:stretch><a:fillRect/></a:stretch></xdr:blipFill>\
        <xdr:spPr><a:prstGeom prst="rect"/></xdr:spPr></xdr:pic>
        """

    static let chartFrame = """
        <xdr:graphicFrame><xdr:nvGraphicFramePr><xdr:cNvPr id="3" name="Chart 1"/><xdr:cNvGraphicFramePr/></xdr:nvGraphicFramePr>\
        <xdr:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/></xdr:xfrm>\
        <a:graphic><a:graphicData uri="\(ChartNamespace.c)"><c:chart r:id="rId2"/></a:graphicData></a:graphic></xdr:graphicFrame>
        """

    /// A chart part: `plot` inside the plot area, with a title and a legend on the right.
    static func chart(_ plot: String, title: String? = "판매") -> String {
        let titleXML = title.map { "<c:title><c:tx><c:rich><a:p><a:r><a:t>\($0)</a:t></a:r></a:p></c:rich></c:tx></c:title>" } ?? ""
        return """
            <c:chartSpace xmlns:c="\(ChartNamespace.c)" xmlns:a="\(OOXMLNamespace.a)" xmlns:r="\(relationship)"><c:chart>\(titleXML)\
            <c:plotArea>\(plot)\
            <c:catAx><c:axId val="1"/><c:axPos val="b"/><c:crossAx val="2"/></c:catAx>\
            <c:valAx><c:axId val="2"/><c:axPos val="l"/><c:majorGridlines/><c:crossAx val="1"/><c:crossBetween val="between"/></c:valAx>\
            </c:plotArea><c:legend><c:legendPos val="r"/></c:legend></c:chart></c:chartSpace>
            """
    }

    /// A series with cached categories and values.
    static func series(_ index: Int, name: String, categories: [String], values: [Double], color: String? = nil) -> String {
        let categoryPoints = categories.enumerated()
            .map { "<c:pt idx=\"\($0.offset)\"><c:v>\($0.element)</c:v></c:pt>" }
            .joined()
        let valuePoints = values.enumerated()
            .map { "<c:pt idx=\"\($0.offset)\"><c:v>\($0.element)</c:v></c:pt>" }
            .joined()
        let fill = color.map { "<c:spPr><a:solidFill><a:srgbClr val=\"\($0)\"/></a:solidFill></c:spPr>" } ?? ""
        return """
            <c:ser><c:idx val="\(index)"/><c:order val="\(index)"/><c:tx><c:v>\(name)</c:v></c:tx>\(fill)\
            <c:cat><c:strRef><c:f>표!$A$1:$A$\(categories.count)</c:f><c:strCache><c:ptCount val="\(categories.count)"/>\(categoryPoints)</c:strCache></c:strRef></c:cat>\
            <c:val><c:numRef><c:f>표!$B$1:$B$\(values.count)</c:f><c:numCache><c:formatCode>General</c:formatCode><c:ptCount val="\(values.count)"/>\(valuePoints)</c:numCache></c:numRef></c:val></c:ser>
            """
    }

    /// A small opaque PNG.
    static func png() -> Data {
        let image = NSImage(size: NSSize(width: 40, height: 20))
        image.lockFocus()
        NSColor.systemRed.setFill()
        NSRect(x: 0, y: 0, width: 40, height: 20).fill()
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return bitmap.representation(using: .png, properties: [:])!
    }
}

@MainActor
@Suite struct SheetLayoutTests {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(
            path: "sheet-layout-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    private func layout(_ url: URL) throws -> (XLSXWorkbook, SheetHTMLWriter, SheetHTMLWriter.Layout) {
        let workbook = try XLSXWorkbook(url: url)
        let writer = SheetHTMLWriter(workbook: workbook)
        let layout = try #require(writer.layout(for: workbook.sheets[0]))
        return (workbook, writer, layout)
    }

    @Test func pagesBreakByRowHeightAndRepeatTitleRows() throws {
        let url = try TestWorkbook.write(
            to: directory.appending(path: "titles.xlsx"),
            sheetData: "<row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>머리글</t></is></c></row>" + TestWorkbook.rows(120, from: 2),
            workbookExtras: "<definedNames><definedName name=\"_xlnm.Print_Titles\" localSheetId=\"0\">표!$1:$1</definedName></definedNames>"
        )
        let (workbook, writer, layout) = try layout(url)
        #expect(layout.pageCount == 3)
        let second = writer.html(
            for: workbook.sheets[0],
            layout: layout,
            pages: 1..<2
        )
        #expect(second.contains("머리글"))
    }

    @Test func manualBreakStartsAPage() throws {
        let url = try TestWorkbook.write(
            to: directory.appending(path: "break.xlsx"),
            sheetData: TestWorkbook.rows(10),
            worksheetExtras: "<rowBreaks count=\"1\" manualBreakCount=\"1\"><brk id=\"4\" max=\"16383\" man=\"1\"/></rowBreaks>"
        )
        let (_, _, layout) = try layout(url)
        #expect(layout.pageCount == 2)
        #expect(layout.rows(onPage: 1).first == 4)
    }

    @Test func printAreaLimitsWhatPrints() throws {
        let url = try TestWorkbook.write(
            to: directory.appending(path: "area.xlsx"),
            sheetData: TestWorkbook.rows(30),
            workbookExtras: "<definedNames><definedName name=\"_xlnm.Print_Area\" localSheetId=\"0\">표!$A$5:$A$9</definedName></definedNames>"
        )
        let (_, _, layout) = try layout(url)
        #expect(layout.rows == Array(4...8))
    }

    @Test func fitToOnePageShrinksEverything() throws {
        let url = try TestWorkbook.write(
            to: directory.appending(path: "fit.xlsx"),
            sheetData: TestWorkbook.rows(200),
            worksheetExtras: "<pageSetup paperSize=\"9\" fitToWidth=\"1\" fitToHeight=\"1\"/>",
            workbookExtras: ""
        )
        // fitToPage lives in sheetPr, which comes first in a worksheet.
        let workbook = try XLSXWorkbook(url: url)
        var sheet = workbook.sheets[0]
        sheet.page.fitsToPages = true
        let layout = try #require(SheetHTMLWriter(workbook: workbook).layout(for: sheet))
        #expect(layout.pageCount == 1)
        #expect(layout.zoom < 0.5)
    }

    @Test func mergedCellsStayOnOnePage() throws {
        let url = try TestWorkbook.write(
            to: directory.appending(path: "merge.xlsx"),
            sheetData: TestWorkbook.rows(80),
            worksheetExtras: "<mergeCells count=\"1\"><mergeCell ref=\"A44:A50\"/></mergeCells>"
        )
        let (_, _, layout) = try layout(url)
        let starts = (0..<layout.pageCount).compactMap { layout.rows(onPage: $0).first }
        #expect(starts.allSatisfy { $0 <= 43 || $0 > 49 })
    }

    @Test func pictureSitsOnItsCellsCropped() throws {
        let url = try TestWorkbook.write(
            to: directory.appending(path: "picture.xlsx"),
            sheetData: TestWorkbook.rows(10),
            drawing: TestWorkbook.drawing(
                from: (row: 2, column: 1),
                to: (row: 6, column: 3),
                object: TestWorkbook.picture
            ),
            media: TestWorkbook.png()
        )
        let (workbook, writer, layout) = try layout(url)
        let placed = try #require(layout.drawings.first)
        #expect(placed.frame.minY == 30)
        #expect(placed.frame.height == 60)
        guard case .picture(let picture) = placed.drawing.items.first?.content else {
            Issue.record("expected a picture")
            return
        }
        #expect(picture.crop.left == 0.25)
        let html = writer.html(
            for: workbook.sheets[0],
            layout: layout,
            pages: 0..<1
        )
        #expect(html.contains("<img src=\"data:image/png;base64,"))
    }

    @Test func drawingAcrossAPageBreakShowsOnBothPages() throws {
        let url = try TestWorkbook.write(
            to: directory.appending(path: "across.xlsx"),
            sheetData: TestWorkbook.rows(100),
            drawing: TestWorkbook.drawing(
                from: (row: 40, column: 0),
                to: (row: 60, column: 2),
                object: TestWorkbook.picture
            ),
            media: TestWorkbook.png()
        )
        let (_, _, layout) = try layout(url)
        let pages = layout.drawings.map(\.page)
        #expect(pages == [0, 1])
        // The second page shows it from where the first left off.
        #expect(layout.drawings[1].frame.minY < 0)
    }

    @Test func chartIsReadFromItsCacheAndDrawn() throws {
        let plot = """
            <c:barChart><c:barDir val="col"/><c:grouping val="clustered"/><c:varyColors val="0"/>\
            \(TestWorkbook.series(0, name: "서울", categories: ["1월", "2월", "3월"], values: [10, 20, 15], color: "FF0000"))\
            \(TestWorkbook.series(1, name: "부산", categories: ["1월", "2월", "3월"], values: [5, 25, 30]))\
            <c:gapWidth val="150"/><c:axId val="1"/><c:axId val="2"/></c:barChart>
            """
        let url = try TestWorkbook.write(
            to: directory.appending(path: "chart.xlsx"),
            sheetData: TestWorkbook.rows(20),
            drawing: TestWorkbook.drawing(
                from: (row: 1, column: 2),
                to: (row: 15, column: 8),
                object: TestWorkbook.chartFrame
            ),
            chart: TestWorkbook.chart(plot)
        )
        let (workbook, _, layout) = try layout(url)
        guard case .chart(let chart) = layout.drawings.first?.drawing.items.first?.content else {
            Issue.record("expected a chart")
            return
        }
        #expect(chart.title == "판매")
        #expect(chart.legend == "r")
        #expect(chart.groups.first?.kind == .column)
        #expect(chart.groups.first?.series.map(\.name) == ["서울", "부산"])
        #expect(chart.groups.first?.series[1].values == [5, 25, 30])
        #expect(chart.groups.first?.series[0].color == "#FF0000")

        let svg = ChartSVGWriter(
            chart: chart,
            size: CGSize(width: 360, height: 220),
            fontName: workbook.defaultFont.name,
            formats: workbook.formats
        ).svg()
        // Six bars and two legend swatches.
        #expect(svg.components(separatedBy: "<rect").count - 1 == 1 + 6 + 2)
        for label in ["1월", "3월", "서울", "부산", "판매", ">35<"] {
            #expect(svg.contains(label), "missing \(label)")
        }
    }

    @Test func pieSlicesTakeTheirShares() throws {
        let plot = """
            <c:pieChart><c:varyColors val="1"/>\
            \(TestWorkbook.series(0, name: "비율", categories: ["가", "나"], values: [3, 1]))\
            <c:dLbls><c:showPercent val="1"/></c:dLbls><c:firstSliceAng val="0"/></c:pieChart>
            """
        let root = try #require(try XMLDocument(xmlString: TestWorkbook.chart(plot, title: nil)).rootElement())
        let chart = try #require(
            XLSXChart(
                root,
                colors: DrawingColors(theme: DocxTheme(nil)),
                formats: NumberFormats(nil, date1904: false),
                cells: { _ in [] }
            )
        )
        #expect(chart.title == "비율")
        let svg = ChartSVGWriter(
            chart: chart,
            size: CGSize(width: 300, height: 200),
            fontName: "Calibri",
            formats: NumberFormats(nil, date1904: false)
        ).svg()
        #expect(svg.contains(">75%<"))
        #expect(svg.contains(">25%<"))
        // Slices in the first two accents.
        #expect(svg.contains("#4472C4"))
        #expect(svg.contains("#ED7D31"))
    }

    @Test func niceScaleStartsAtZeroWithHeadroom() {
        let scale = ChartSVGWriter.niceScale(
            (12, 100),
            axis: XLSXChart.Axis(),
            startsAtZero: true
        )
        #expect(scale.minimum == 0)
        #expect(scale.maximum == 120)
        #expect(scale.step == 20)
    }

    @Test func themeColorsTakeTheirShadeAndTint() throws {
        let colors = DrawingColors(theme: DocxTheme(nil))
        let fill = try XMLDocument(xmlString: """
            <a:solidFill xmlns:a="\(OOXMLNamespace.a)"><a:schemeClr val="accent1"><a:lumMod val="50000"/></a:schemeClr></a:solidFill>
            """).rootElement()
        let color = try #require(colors.color(in: fill))
        #expect(color.rgb < 0x4472C4)
        #expect(ColorMath.luminance(color.rgb) < ColorMath.luminance(0x4472C4))
    }
}
