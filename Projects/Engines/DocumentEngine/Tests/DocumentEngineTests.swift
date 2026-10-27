import Foundation
import PDFKit
import Testing
@testable import DocumentEngine

@MainActor
@Suite struct PagedPDFRendererTests {
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

    private static func outputURL(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "conv-spike", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name)
        try? FileManager.default.removeItem(at: url)
        return url
    }
}
