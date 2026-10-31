import Foundation
import AppKit
import PDFKit
import Testing
@testable import DocumentEngine

@MainActor
@Suite(.timeLimit(.minutes(1))) struct PagedPDFRendererTests {
    /// ~120 Korean paragraphs, then a heading forced onto a new page.
    static let longHTML: String = {
        let paragraphs = (1...120).map { index in
            "<p>문단 \(index). 파일을 끌어다 놓으면 원하는 포맷으로 바뀌는 맥 변환기를 만들고 있다.</p>"
        }
        return """
        <html><head><meta charset="utf-8">
        <style>body { font-family: -apple-system; font-size: 12pt; }</style>
        </head><body>
        \(paragraphs.joined())
        <h1 style="break-before: page">BREAK-MARKER</h1><p>마지막 문단</p>
        </body></html>
        """
    }()

    @Test func longHTMLSplitsIntoA4PagesWithoutLosingText() async throws {
        let output = try Self.outputURL("paged.pdf")
        try await PagedPDFRenderer().render(html: Self.longHTML, baseURL: nil, to: output)

        let document = try #require(PDFDocument(url: output))
        #expect(document.pageCount >= 3)

        let firstPage = try #require(document.page(at: 0)).bounds(for: .mediaBox)
        #expect(abs(firstPage.width - 595.28) < 1)
        #expect(abs(firstPage.height - 841.89) < 1)

        let text = document.string ?? ""
        #expect(text.contains("문단 1."))
        #expect(text.contains("문단 120."))
        #expect(text.contains("마지막 문단"))
    }

    @Test func cssPageBreakStartsANewPage() async throws {
        let output = try Self.outputURL("page-break.pdf")
        try await PagedPDFRenderer().render(html: Self.longHTML, baseURL: nil, to: output)

        let document = try #require(PDFDocument(url: output))
        let markerPage = (0..<document.pageCount).first { index in
            document.page(at: index)?.string?.contains("BREAK-MARKER") == true
        }
        let pageText = try #require(markerPage.flatMap { document.page(at: $0)?.string })
        #expect(pageText.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("BREAK-MARKER"))
    }

    /// CSS units must come out at their physical size, so 72pt of CSS type is 72pt in the PDF.
    @Test(arguments: [
        PagedPDFRenderer.PageSetup.a4,
        PagedPDFRenderer.PageSetup(
            paperSize: CGSize(width: 612, height: 792),
            margins: .init(top: 72, left: 90, bottom: 72, right: 30)
        ),
    ])
    func cssUnitsKeepTheirPhysicalSize(page: PagedPDFRenderer.PageSetup) async throws {
        let output = try Self.outputURL("units-\(Int(page.paperSize.width)).pdf")
        let html = #"<p style="margin:0;font:72pt/1 Helvetica">MEASURE</p>"#
        try await PagedPDFRenderer().render(html: html, baseURL: nil, to: output, page: page)

        let document = try #require(PDFDocument(url: output))
        let pdfPage = try #require(document.page(at: 0))
        let selection = try #require(document.findString("MEASURE", withOptions: []).first)
        let font = try #require(selection.attributedString?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(abs(font.pointSize - 72) < 0.5, "72pt CSS printed at \(font.pointSize)pt")
        // Text starts at the left margin.
        #expect(abs(selection.bounds(for: pdfPage).minX - page.margins.left) < 8)
    }

    @Test func printThatOutlivesTheTimeoutThrowsAndLeavesNoFile() async throws {
        let output = try Self.outputURL("timeout.pdf")
        await #expect(throws: PagedPDFRenderer.RenderError.timedOut) {
            try await PagedPDFRenderer().render(html: Self.longHTML, baseURL: nil, to: output, timeout: .milliseconds(1))
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    private static func outputURL(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "conv-spike", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name)
        try? FileManager.default.removeItem(at: url)
        return url
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct DocxPDFConverterTests {
    @Test(arguments: [
        ("formatting", ["주간 회의록", "굵게", "20pt 글자", "가운데 정렬된 문단", "※ → ①", "int buffer[100];"]),
        ("table", ["TABLE-BEFORE", "항목", "엔진 스파이크", "병합된 셀", "TABLE-AFTER"]),
        ("lists", ["첫째 항목", "들여쓴 하위 항목", "정리"]),
        ("image", ["IMAGE-BEFORE", "IMAGE-AFTER"]),
        ("pagebreak", ["PAGE-ONE", "PAGE-TWO"]),
        ("long", ["문단 1.", "문단 200."]),
    ])
    func convertsWithoutLosingText(fixture: String, expected: [String]) async throws {
        let input = Self.fixture(fixture)
        let directory = try Self.outputDirectory()
        // Kept for eyeballing which step loses formatting.
        try DocxPDFConverter().html(for: input).write(to: directory.appending(path: "\(fixture).html"), atomically: true, encoding: .utf8)
        let output = directory.appending(path: "\(fixture).pdf")
        try await DocxPDFConverter().convert(input, to: output)

        let document = try #require(PDFDocument(url: output))
        let text = document.string ?? ""
        for snippet in expected {
            #expect(text.contains(snippet), "\(fixture).pdf is missing \"\(snippet)\"")
        }
    }

    @Test func longDocumentSpansSeveralPages() async throws {
        let output = try Self.outputDirectory().appending(path: "long-pages.pdf")
        try await DocxPDFConverter().convert(Self.fixture("long"), to: output)
        #expect(try #require(PDFDocument(url: output)).pageCount >= 5)
    }

    @Test func wordPageBreakStartsANewPage() async throws {
        let output = try Self.outputDirectory().appending(path: "pagebreak-check.pdf")
        try await DocxPDFConverter().convert(Self.fixture("pagebreak"), to: output)
        let document = try #require(PDFDocument(url: output))
        let page = (0..<document.pageCount).first { document.page(at: $0)?.string?.contains("PAGE-TWO") == true }
        #expect(page == 1)
    }

    @Test func headingStyleAndRunFormattingSurvive() throws {
        let html = try DocxPDFConverter().html(for: Self.fixture("formatting"))
        // Heading 1 in the fixture's styles.xml: bold, sz 36 half-points.
        #expect(html.contains("font-weight:bold;font-size:18pt"))
        #expect(html.contains("color:#FF5A1F"))
        #expect(html.contains("font-size:20pt"))
        #expect(html.contains("text-align:center"))
        #expect(html.contains("'Apple SD Gothic Neo'"))
    }

    @Test func numberedAndBulletedListsGetWordLabels() async throws {
        let output = try Self.outputDirectory().appending(path: "lists-labels.pdf")
        try await DocxPDFConverter().convert(Self.fixture("lists"), to: output)
        let text = try #require(PDFDocument(url: output)?.string)
        for label in ["•", "◦", "1.", "2.", "3."] {
            #expect(text.contains(label), "missing list label \(label)")
        }
    }

    @Test func tableKeepsMergesAndShading() throws {
        let html = try DocxPDFConverter().html(for: Self.fixture("table"))
        #expect(html.contains(#"colspan="3""#))
        #expect(html.contains("background:#D9D9D9"))
        #expect(html.contains("0.5pt solid #000000"))
        #expect(html.contains("<col style=\"width:150pt\">"))
    }

    @Test func imageIsEmbeddedAtItsSize() throws {
        let html = try DocxPDFConverter().html(for: Self.fixture("image"))
        #expect(html.contains("data:image/png;base64,"))
        #expect(html.contains("width:216pt"))
    }

    @Test func pageSizeAndMarginsComeFromTheSection() throws {
        let page = try DocxPDFConverter().pageSetup(for: Self.fixture("formatting"))
        #expect(abs(page.paperSize.width - 595.3) < 0.1)
        #expect(abs(page.paperSize.height - 841.9) < 0.1)
        #expect(abs(page.margins.left - 56.7) < 0.1)
    }

    @Test func headersAndLivePageNumbersAreStampedOnEveryPage() async throws {
        let output = try Self.outputDirectory().appending(path: "header-footer.pdf")
        try await DocxPDFConverter().convert(Self.fixture("header-footer"), to: output)
        let document = try #require(PDFDocument(url: output))
        try #require(document.pageCount == 2)
        for (index, body) in ["BODY-ONE", "BODY-TWO"].enumerated() {
            let text = document.page(at: index)?.string ?? ""
            #expect(text.contains(body))
            #expect(text.contains("HEADER-TEXT"), "page \(index + 1) has no header")
            #expect(text.contains("Page \(index + 1)"), "page \(index + 1) has no live page number")
            #expect(!text.contains("99"), "the stale cached page number leaked through")
            #expect(!text.contains("right"), "the absolute tab's alignment leaked into the text")
        }
        // The absolute tab pins the header to the right margin.
        let header = try #require(document.findString("HEADER-TEXT", withOptions: []).first)
        let pageOne = try #require(document.page(at: 0))
        #expect(abs(header.bounds(for: pageOne).maxX - (595.28 - 56.7)) < 3)
        // Text extraction can't see an opaque overlay covering the body; pixels can.
        let page = try #require(document.page(at: 1))
        let body = try #require(document.findString("BODY-TWO", withOptions: []).first { $0.pages.first == page })
        #expect(Self.inkCoverage(of: body.bounds(for: page), on: page) > 0.05, "BODY-TWO is covered by the overlay")
    }

    /// Fraction of dark pixels in `rect` when the page is drawn.
    private static func inkCoverage(of rect: CGRect, on page: PDFPage) -> Double {
        let image = page.thumbnail(of: page.bounds(for: .mediaBox).size, for: .mediaBox)
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return 0 }
        let scale = Double(bitmap.pixelsWide) / page.bounds(for: .mediaBox).width
        var dark = 0
        var total = 0
        for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
            for y in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
                // Bitmap rows run top-down; PDF y runs bottom-up.
                guard let color = bitmap.colorAt(x: x, y: bitmap.pixelsHigh - 1 - y) else { continue }
                total += 1
                if color.brightnessComponent < 0.5 { dark += 1 }
            }
        }
        return total == 0 ? 0 : Double(dark) / Double(total)
    }

    @Test func embeddedFontKeyUndoesItsOwnObfuscation() {
        let font = Data((0..<64).map { UInt8($0) })
        let key = "{23EAE097-B649-4736-A073-9DB14CE96906}"
        let obfuscated = DocxEmbeddedFonts.deobfuscate(font, key: key)
        #expect(obfuscated != font)
        #expect(obfuscated[32...] == font[32...])
        #expect(DocxEmbeddedFonts.deobfuscate(obfuscated, key: key) == font)
    }

    private static func fixture(_ name: String) -> URL {
        URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/\(name).docx")
    }

    private static func outputDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "conv-spike/docx", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

/// Converts every .docx in `$CONV_SAMPLES` into `$CONV_SAMPLES_OUT` for side-by-side review.
/// Run with `TEST_RUNNER_CONV_SAMPLES=… TEST_RUNNER_CONV_SAMPLES_OUT=… xcodebuild test`.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CONV_SAMPLES"] != nil))
struct DocxSampleTests {
    @Test func convertSamples() async throws {
        let environment = ProcessInfo.processInfo.environment
        let input = URL(filePath: try #require(environment["CONV_SAMPLES"]), directoryHint: .isDirectory)
        let output = URL(filePath: try #require(environment["CONV_SAMPLES_OUT"]), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let samples = try FileManager.default.contentsOfDirectory(at: input, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "docx" }
        for sample in samples {
            let name = sample.deletingPathExtension().lastPathComponent
            let started = ContinuousClock.now
            do {
                try DocxPDFConverter().html(for: sample)
                    .write(to: output.appending(path: "\(name).html"), atomically: true, encoding: .utf8)
                try await DocxPDFConverter().convert(sample, to: output.appending(path: "\(name).pdf"))
                print("SAMPLE \(name): ok in \(ContinuousClock.now - started)")
            } catch {
                Issue.record("\(name): \(error)")
            }
        }
    }
}

/// Run with `TEST_RUNNER_CONV_SAMPLES=… TEST_RUNNER_CONV_SAMPLES_OUT=… xcodebuild test`.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CONV_SAMPLES"] != nil))
struct HwpSampleTests {
    @Test func convertSamples() async throws {
        let environment = ProcessInfo.processInfo.environment
        let input = URL(filePath: try #require(environment["CONV_SAMPLES"]), directoryHint: .isDirectory)
        let output = URL(filePath: try #require(environment["CONV_SAMPLES_OUT"]), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let samples = try FileManager.default.contentsOfDirectory(at: input, includingPropertiesForKeys: nil)
            .filter { ["hwp", "hwpx"].contains($0.pathExtension) }
        for sample in samples {
            let name = sample.deletingPathExtension().lastPathComponent
            let started = ContinuousClock.now
            do {
                for (index, html) in try HwpPDFConverter().html(for: sample).enumerated() {
                    try html.write(to: output.appending(path: "\(name)-\(index).html"), atomically: true, encoding: .utf8)
                }
                try await HwpPDFConverter().convert(sample, to: output.appending(path: "\(name).pdf"))
                print("SAMPLE \(name): ok in \(ContinuousClock.now - started)")
            } catch {
                Issue.record("\(name): \(error)")
            }
        }
    }
}

@Suite struct HwpEquationTests {
    @Test func overDividesTheChunksAroundIt() {
        #expect(HwpEquation.mathML("x+y over x-y") == "<math><mfrac><mrow><mi>x</mi><mo>+</mo><mi>y</mi></mrow><mrow><mi>x</mi><mo>−</mo><mi>y</mi></mrow></mfrac></math>")
        #expect(HwpEquation.mathML("{x} over {k} = 1").hasPrefix("<math><mrow><mfrac><mrow><mi>x</mi></mrow><mrow><mi>k</mi></mrow></mfrac>"))
    }

    @Test func rootsTakeTheChunkAfterThem() {
        #expect(HwpEquation.mathML("sqrt x+y").contains("<msqrt><mrow><mi>x</mi><mo>+</mo><mi>y</mi></mrow></msqrt>"))
        #expect(HwpEquation.mathML("root 3 of x").contains("<mroot><mi>x</mi><mn>3</mn></mroot>"))
    }

    @Test func unbracedLimitRunsToTheNextSpace() {
        let math = HwpEquation.mathML("lim_x->0 f(x)")
        #expect(math.contains("<munder><mi mathvariant=\"normal\">lim</mi><mrow><mi>x</mi><mo>→</mo><mn>0</mn></mrow></munder>"))
    }

    @Test func keywordsAndRunTogetherWords() {
        let math = HwpEquation.mathML("rmP + alpha CDOTS cosA")
        #expect(math.contains("<mi mathvariant=\"normal\">P</mi>"))
        #expect(math.contains("α") && math.contains("⋯"))
        #expect(math.contains("<mi mathvariant=\"normal\">cos</mi>"))
    }

    @Test func matricesSplitOnAmpersandAndHash() {
        let math = HwpEquation.mathML("pmatrix{1&&2#3&&4}")
        #expect(math.contains("<mtr><mtd><mrow><mn>1</mn></mrow></mtd><mtd><mrow><mn>2</mn></mrow></mtd></mtr>"))
        #expect(math.contains("<mtr><mtd><mrow><mn>3</mn></mrow></mtd><mtd><mrow><mn>4</mn></mrow></mtd></mtr>"))
    }
}

extension HwpEquationTests {
    @Test func capitalizedKeywordsInsideWords() {
        let math = HwpEquation.mathML("ACUPB")
        #expect(math == "<math><mrow><mi>A</mi><mo>∪</mo><mi>B</mi></mrow></math>")
    }
}

@Suite struct HwpPictureTests {
    private func picture(box: (Int, Int), crop: (Int, Int, Int, Int), extent: (Int, Int) = (0, 0)) -> HwpDocument.Picture {
        var picture = HwpDocument.Picture()
        picture.layout.width = box.0
        picture.layout.height = box.1
        picture.crop = crop
        picture.extent = extent
        return picture
    }

    @Test func cropShowsOnlyItsPartScaledToTheBox() throws {
        // A 1366×768 screenshot (75 units a pixel) cropped to a title in its corner.
        let cropped = picture(box: (20385, 6176), crop: (868, 2250, 31532, 11537))
        let frame = try #require(HwpHTMLWriter.cropFrame(cropped, pixels: CGSize(width: 1366, height: 768)))
        let scale = 20385.0 / 30664
        #expect(frame.x == Int((-868 * scale).rounded()))
        #expect(frame.width == Int((102450 * scale).rounded()))
        #expect(frame.y < 0 && frame.height > 6176)
    }

    @Test func aResizedPictureIsDrawnWhole() {
        // The crop covers the image, give or take a pixel; only the box is smaller.
        let resized = picture(box: (16902, 7623), crop: (0, 0, 29880, 15300), extent: (15254, 7793))
        #expect(HwpHTMLWriter.cropFrame(resized, pixels: CGSize(width: 398, height: 204)) == nil)
    }

    @Test func withoutPixelsTheImageRectangleGivesTheFullSize() throws {
        let cropped = picture(box: (1000, 500), crop: (0, 0, 50000, 25000), extent: (100000, 50000))
        let frame = try #require(HwpHTMLWriter.cropFrame(cropped, pixels: nil))
        #expect(frame.x == 0 && frame.y == 0 && frame.width == 2000 && frame.height == 1000)
    }

    @Test func grayEffectDropsColor() throws {
        let context = try #require(CGContext(data: nil, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 8, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 1))
        let red = try #require(Self.pngData(context.makeImage()))
        let png = try #require(HwpHTMLWriter.png(from: red))
        let gray = try #require(HwpHTMLWriter.grayPNG(from: png, blackAndWhite: false))
        let image = try #require(CGImageSourceCreateWithData(gray as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        let pixel = try #require(image.dataProvider?.data as Data?)
        #expect(pixel[0] == pixel[1] && pixel[1] == pixel[2])
    }

    private static func pngData(_ image: CGImage?) -> Data? {
        guard let image else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct MarkdownConverterTests {
    static let sample = """
    ---
    title: 메모
    draft: true
    ---
    # 회의록 <초안>

    **굵게**, *기울임*, ~~취소~~, `<div>` 코드와 [링크](https://example.com "설명").

    - [x] 완료한 일
    - [ ] 남은 일

    | 이름 | 점수 |
    |:---|---:|
    | 가 | 10 |

    ```swift
    let tag = "<b>" && true
    ```

    > 인용
    """

    @Test func htmlEscapesTextAndKeepsStructure() {
        let html = MarkdownConverter.page(for: Self.sample, title: "file")
        #expect(html.contains("<title>회의록 &lt;초안&gt;</title>"))
        #expect(html.contains("<h1 id=\"회의록-초안\">회의록 &lt;초안&gt;</h1>"))
        #expect(html.contains("<code>&lt;div&gt;</code>"))
        #expect(html.contains("<pre><code class=\"language-swift\">let tag = \"&lt;b&gt;\" &amp;&amp; true\n</code></pre>"))
        #expect(html.contains("<del>취소</del>"))
        #expect(html.contains("<a href=\"https://example.com\" title=\"설명\">링크</a>"))
        #expect(html.contains("<li class=\"task\"><input type=\"checkbox\" disabled checked>완료한 일</li>"))
        #expect(html.contains("<td style=\"text-align:right\">10</td>"))
        #expect(html.contains("<blockquote>"))
        // Front matter is metadata, not text.
        #expect(!html.contains("draft"))
    }

    @Test func pdfIsPaginatedA4WithTheText() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "md-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let input = directory.appending(path: "notes.md")
        let long = Self.sample + "\n\n" + (1...120).map { "문단 \($0)입니다." }.joined(separator: "\n\n")
        try long.write(to: input, atomically: true, encoding: .utf8)
        let output = directory.appending(path: "notes.pdf")
        try await MarkdownConverter().convert(input, to: output)
        let pdf = try #require(PDFDocument(url: output))
        #expect(pdf.pageCount > 1)
        let box = try #require(pdf.page(at: 0)?.bounds(for: .mediaBox))
        #expect(abs(box.width - 595.28) < 1 && abs(box.height - 841.89) < 1)
        let text = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined()
        #expect(text.contains("회의록") && text.contains("문단 120입니다"))
    }

    @Test func scriptsInMarkdownDoNotRun() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "md-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let input = directory.appending(path: "script.md")
        try "본문\n\n<script>document.body.innerHTML = 'REPLACED'</script>\n".write(to: input, atomically: true, encoding: .utf8)
        let output = directory.appending(path: "script.pdf")
        try await MarkdownConverter().convert(input, to: output)
        let text = PDFDocument(url: output)?.page(at: 0)?.string ?? ""
        #expect(text.contains("본문"))
        #expect(!text.contains("REPLACED"))
    }
}
