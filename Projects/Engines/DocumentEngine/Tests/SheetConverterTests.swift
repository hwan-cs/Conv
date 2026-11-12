import Foundation
import PDFKit
import Testing
import ZIPFoundation
@testable import DocumentEngine

@Suite struct CSVTableTests {
    @Test func quotedFieldsKeepSeparatorsQuotesAndLineBreaks() {
        let text = "이름,메모\r\n\"홍, 길동\",\"말하길 \"\"안녕\"\"\"\n김철수,\"두 줄\n메모\"\n"
        let rows = CSVTable.parse(
            text,
            separator: ","
        )
        #expect(rows == [
            ["이름", "메모"],
            ["홍, 길동", "말하길 \"안녕\""],
            ["김철수", "두 줄\n메모"],
        ])
    }

    @Test func koreanWindowsEncodingIsRead() throws {
        let data = try #require("이름,나이\n홍길동,30\n".data(using: CSVTable.windowsKorean))
        #expect(String(data: data, encoding: .utf8) == nil)
        #expect(CSVTable.decode(data) == "이름,나이\n홍길동,30\n")
    }

    @Test func byteOrderMarkIsDropped() {
        let data = Data([0xEF, 0xBB, 0xBF]) + Data("a,b".utf8)
        #expect(CSVTable.decode(data) == "a,b")
    }

    @Test(arguments: [
        ("a;b;c\n1;2;3", ";" as Character),
        ("a\tb\tc\n1\t2\t3", "\t"),
        ("a,b\n\"1;2\",3", ","),
        ("한 줄짜리", ","),
    ])
    func separatorIsDetected(text: String, expected: Character) {
        #expect(CSVTable.separator(in: text) == expected)
    }

    @Test func writtenWithByteOrderMarkAndQuotesOnlyWhereNeeded() {
        let table = CSVTable(rows: [
            ["이름", "메모"],
            ["홍길동", "쉼표, 있음"],
        ])
        let text = String(
            decoding: table.data(),
            as: UTF8.self
        )
        #expect(text == "\u{FEFF}이름,메모\r\n홍길동,\"쉼표, 있음\"\r\n")
    }
}

@Suite struct XLSXWriterTests {
    @Test(arguments: [
        ("42", true),
        ("-3.5", true),
        ("0.25", true),
        ("007", false),
        ("010-1234-5678", false),
        ("1e5", false),
        ("+1", false),
        ("1234567890123456", false),
        ("", false),
    ])
    func onlyNumbersExcelKeepsExactlyBecomeNumbers(text: String, isNumber: Bool) {
        #expect(XLSXWriter.isNumber(text) == isNumber)
    }

    @Test(arguments: [
        (0, "A"),
        (25, "Z"),
        (26, "AA"),
        (701, "ZZ"),
        (702, "AAA"),
    ])
    func columnsAreNamedLikeExcel(index: Int, name: String) {
        #expect(XLSXWriter.columnName(index) == name)
        #expect(XLSXWorkbook.position("\(name)1")?.column == index)
    }

    @Test func sheetNamesLoseForbiddenCharacters() {
        #expect(XLSXWriter.validSheetName("매출[2024]/상반기") == "매출2024상반기")
        #expect(XLSXWriter.validSheetName("   ") == "Sheet1")
        #expect(XLSXWriter.validSheetName(String(repeating: "가", count: 40)).count == 31)
    }
}

@Suite struct NumberFormatsTests {
    let formats: NumberFormats

    init() throws {
        let stylesheet = try XMLDocument(xmlString: """
            <styleSheet xmlns="\(SpreadsheetNamespace.main)"><numFmts>\
            <numFmt numFmtId="164" formatCode="yyyy&quot;년&quot; m&quot;월&quot; d&quot;일&quot;"/>\
            <numFmt numFmtId="165" formatCode="[$₩-412]#,##0"/>\
            <numFmt numFmtId="166" formatCode="#,##0.00_);[Red]\\(#,##0.00\\)"/>\
            <numFmt numFmtId="167" formatCode="00000"/>\
            <numFmt numFmtId="168" formatCode="yyyy.mm.dd"/>\
            <numFmt numFmtId="169" formatCode="#,##0&quot; 원&quot;"/>\
            <numFmt numFmtId="170" formatCode="[$-412]yyyy-mm-dd ddd AM/PM h:mm"/>\
            </numFmts></styleSheet>
            """
        ).rootElement()
        formats = NumberFormats(
            stylesheet,
            date1904: false
        )
    }

    @Test(arguments: [
        (45296.0, 0, "45296"),
        (0.1 + 0.2, 0, "0.3"),
        (1234.5, 3, "1,235"),
        (1234.5, 4, "1,234.50"),
        (0.256, 9, "26%"),
        (0.25, 10, "25.00%"),
        (123456.0, 11, "1.23E+05"),
        (45296.0, 14, "2024-01-05"),
        (45296.75, 22, "2024-01-05 18:00"),
        (0.5, 18, "12:00 PM"),
        (1.25, 46, "30:00:00"),
        (45296.0, 164, "2024년 1월 5일"),
        (1500000.0, 165, "₩1,500,000"),
        (-1234.5, 166, "(1,234.50)"),
        (1234.5, 166, "1,234.50 "),
        (1234.0, 167, "01234"),
        (45296.0, 168, "2024.01.05"),
        (30000.0, 169, "30,000 원"),
        (45296.25, 170, "2024-01-05 금 오전 6:00"),
        (-5.0, 3, "-5"),
    ])
    func valuesShowAsExcelShowsThem(value: Double, format: Int, expected: String) {
        #expect(formats.text(for: value, format: format) == expected)
    }

    @Test func dates1904CountFromThen() {
        let formats = NumberFormats(
            nil,
            date1904: true
        )
        #expect(formats.text(for: 0, format: 14) == "1904-01-01")
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct SheetConverterTests {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(
            path: "sheet-tests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    @Test func csvSurvivesARoundTripThroughExcel() async throws {
        let rows = [
            ["이름", "전화", "코드", "금액", "메모"],
            ["홍길동", "010-1234-5678", "007", "1234.5", "쉼표, \"따옴표\""],
            ["김철수", "", "42", "-3", "두 줄\n메모"],
        ]
        let csv = directory.appending(path: "명단.csv")
        try Data(CSVTable(rows: rows).data()).write(to: csv)

        let xlsx = directory.appending(path: "명단.xlsx")
        try await SheetConverter().convert(
            csv,
            to: xlsx
        )
        let workbook = try XLSXWorkbook(url: xlsx)
        let sheet = try #require(workbook.sheets.first)
        #expect(sheet.name == "명단")
        #expect(sheet.cells[1]?[3]?.kind == .number)
        #expect(sheet.cells[1]?[2]?.kind == .text)

        let back = directory.appending(path: "back.csv")
        try await SheetConverter().convert(
            xlsx,
            to: back
        )
        #expect(try CSVTable(contentsOf: back).rows == rows)
    }

    @Test func koreanCSVBecomesReadableExcel() async throws {
        let csv = directory.appending(path: "euc-kr.csv")
        try #require("품목,수량\n사과,3\n".data(using: CSVTable.windowsKorean)).write(to: csv)
        let xlsx = directory.appending(path: "euc-kr.xlsx")
        try await SheetConverter().convert(
            csv,
            to: xlsx
        )
        let sheet = try #require(XLSXWorkbook(url: xlsx).sheets.first)
        #expect(sheet.rows() == [["품목", "수량"], ["사과", "3"]])
    }

    @Test func csvTakesTheSheetThatWasOpenAndSkipsHiddenOnes() async throws {
        let xlsx = try Self.workbook(
            at: directory.appending(path: "multi.xlsx"),
            activeTab: 1
        )
        let csv = directory.appending(path: "multi.csv")
        try await SheetConverter().convert(
            xlsx,
            to: csv
        )
        #expect(try CSVTable(contentsOf: csv).rows == [["둘째 시트", "2"]])
    }

    @Test func everyVisibleSheetIsPrinted() async throws {
        let xlsx = try Self.workbook(
            at: directory.appending(path: "print.xlsx"),
            activeTab: 0
        )
        let pdf = directory.appending(path: "print.pdf")
        try await SheetConverter().convert(
            xlsx,
            to: pdf
        )
        let document = try #require(PDFDocument(url: pdf))
        let text = document.string ?? ""
        #expect(document.pageCount == 2)
        #expect(text.contains("2024-01-05"))
        #expect(text.contains("합계"))
        #expect(text.contains("둘째 시트"))
        #expect(!text.contains("숨긴 시트"))
    }

    @Test func aLittleTooWideShrinksOntoOnePage() async throws {
        let document = try await Self.pdf(
            columns: 14,
            in: directory
        )
        #expect(document.pageCount == 1)
        #expect((document.string ?? "").contains("열14"))
    }

    @Test func farTooWideSplitsAcrossPagesTurnedSideways() async throws {
        let document = try await Self.pdf(
            columns: 40,
            in: directory
        )
        let page = try #require(document.page(at: 0)).bounds(for: .mediaBox)
        let text = document.string ?? ""
        #expect(page.width > page.height)
        #expect(document.pageCount > 1)
        #expect(text.contains("열1"))
        #expect(text.contains("열40"))
    }

    @Test func longSheetPrintsInRunsWithEveryPageKept() async throws {
        let rows = [["번호", "값"]] + (1...11_000).map { ["\($0)", "\($0 * 2)"] }
        let csv = directory.appending(path: "long.csv")
        try CSVTable(rows: rows).data().write(to: csv)
        let xlsx = directory.appending(path: "long.xlsx")
        try await SheetConverter().convert(
            csv,
            to: xlsx
        )
        let workbook = try XLSXWorkbook(url: xlsx)
        let writer = SheetHTMLWriter(workbook: workbook)
        let layout = try #require(writer.layout(for: workbook.sheets[0]))
        #expect(writer.chunks(layout).count > 1)

        var reported: [Double] = []
        let pdf = directory.appending(path: "long.pdf")
        try await SheetConverter().convert(
            xlsx,
            to: pdf
        ) { fraction in
            reported.append(fraction)
        }
        let document = try #require(PDFDocument(url: pdf))
        let text = document.string ?? ""
        #expect(document.pageCount == layout.pageCount)
        #expect(reported.last == 1)
        #expect(text.contains("22000"))
    }

    @Test func emptyWorkbookHasNothingToPrint() async throws {
        let csv = directory.appending(path: "empty.csv")
        try Data().write(to: csv)
        let xlsx = directory.appending(path: "empty.xlsx")
        try await SheetConverter().convert(
            csv,
            to: xlsx
        )
        await #expect(throws: SheetConverter.ConversionError.empty) {
            try await SheetConverter().convert(
                xlsx,
                to: directory.appending(path: "empty.pdf")
            )
        }
    }

    @Test func notASpreadsheetIsReported() async throws {
        let xlsx = directory.appending(path: "broken.xlsx")
        try Data("not a zip".utf8).write(to: xlsx)
        await #expect(throws: SheetConverter.ConversionError.unreadable) {
            try await SheetConverter().convert(
                xlsx,
                to: directory.appending(path: "broken.csv")
            )
        }
    }

    // MARK: Helpers

    /// A two-row sheet `columns` wide, as PDF.
    static func pdf(columns: Int, in directory: URL) async throws -> PDFDocument {
        let header = (1...columns).map { "열\($0)" }
        let csv = directory.appending(path: "wide-\(columns).csv")
        try CSVTable(rows: [header, header.map { _ in "12345" }]).data().write(to: csv)
        let xlsx = directory.appending(path: "wide-\(columns).xlsx")
        try await SheetConverter().convert(
            csv,
            to: xlsx
        )
        let pdf = directory.appending(path: "wide-\(columns).pdf")
        try await SheetConverter().convert(
            xlsx,
            to: pdf
        )
        return try #require(PDFDocument(url: pdf))
    }

    /// Three sheets, the last hidden: a styled one with a date, a merged title and a bold total;
    /// a plain one; and one that should never show.
    static func workbook(at url: URL, activeTab: Int) throws -> URL {
        let main = SpreadsheetNamespace.main
        let relationship = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let parts = [
            "[Content_Types].xml": """
                <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
                <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
                <Default Extension="xml" ContentType="application/xml"/></Types>
                """,
            "_rels/.rels": """
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
                <Relationship Id="rId1" Type="\(relationship)/officeDocument" Target="xl/workbook.xml"/></Relationships>
                """,
            "xl/workbook.xml": """
                <workbook xmlns="\(main)" xmlns:r="\(relationship)">\
                <bookViews><workbookView activeTab="\(activeTab)"/></bookViews><sheets>\
                <sheet name="매출" sheetId="1" r:id="rId1"/>\
                <sheet name="둘째" sheetId="2" r:id="rId2"/>\
                <sheet name="숨김" sheetId="3" state="hidden" r:id="rId3"/></sheets></workbook>
                """,
            "xl/_rels/workbook.xml.rels": """
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
                <Relationship Id="rId1" Type="\(relationship)/worksheet" Target="worksheets/sheet1.xml"/>\
                <Relationship Id="rId2" Type="\(relationship)/worksheet" Target="worksheets/sheet2.xml"/>\
                <Relationship Id="rId3" Type="\(relationship)/worksheet" Target="worksheets/sheet3.xml"/>\
                <Relationship Id="rId4" Type="\(relationship)/styles" Target="styles.xml"/>\
                <Relationship Id="rId5" Type="\(relationship)/sharedStrings" Target="sharedStrings.xml"/></Relationships>
                """,
            "xl/sharedStrings.xml": """
                <sst xmlns="\(main)"><si><t>월별 매출</t></si><si><r><t>합</t></r><r><rPr><b/></rPr><t>계</t></r></si>\
                <si><t>둘째 시트</t></si><si><t>숨긴 시트</t></si></sst>
                """,
            "xl/styles.xml": """
                <styleSheet xmlns="\(main)">\
                <fonts count="2"><font><sz val="11"/><name val="맑은 고딕"/></font><font><b/><sz val="14"/><color theme="4"/><name val="맑은 고딕"/></font></fonts>\
                <fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill>\
                <fill><patternFill patternType="solid"><fgColor rgb="FFFFFF00"/></patternFill></fill></fills>\
                <borders count="2"><border/><border><top style="thin"><color auto="1"/></top><bottom style="double"/></border></borders>\
                <cellXfs count="4"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/>\
                <xf numFmtId="0" fontId="1" fillId="2" borderId="0"><alignment horizontal="center"/></xf>\
                <xf numFmtId="14" fontId="0" fillId="0" borderId="0"/>\
                <xf numFmtId="3" fontId="1" fillId="0" borderId="1"/></cellXfs></styleSheet>
                """,
            "xl/worksheets/sheet1.xml": """
                <worksheet xmlns="\(main)"><cols><col min="1" max="1" width="14" customWidth="1"/></cols><sheetData>\
                <row r="1"><c r="A1" t="s" s="1"><v>0</v></c><c r="B1" s="1"/></row>\
                <row r="2"><c r="A2" s="2"><v>45296</v></c><c r="B2"><v>1200</v></c></row>\
                <row r="3"><c r="A3" t="s"><v>1</v></c><c r="B3" s="3"><f>SUM(B2)</f><v>1200</v></c></row>\
                </sheetData><mergeCells count="1"><mergeCell ref="A1:B1"/></mergeCells></worksheet>
                """,
            "xl/worksheets/sheet2.xml": """
                <worksheet xmlns="\(main)"><sheetData><row r="1"><c r="A1" t="s"><v>2</v></c><c r="B1"><v>2</v></c></row></sheetData></worksheet>
                """,
            "xl/worksheets/sheet3.xml": """
                <worksheet xmlns="\(main)"><sheetData><row r="1"><c r="A1" t="s"><v>3</v></c></row></sheetData></worksheet>
                """,
        ]
        let archive = try Archive(
            url: url,
            accessMode: .create
        )
        for (path, xml) in parts {
            let data = Data(xml.utf8)
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
}
