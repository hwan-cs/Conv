import Foundation
import PDFKit

/// .docx → paginated PDF: OOXML is read directly into HTML, then laid out by `PagedPDFRenderer`.
///
/// Cocoa's own OOXML reader was tried first and drops images, page breaks, heading styles,
/// numbered lists, and table merges and shading.
@MainActor
public struct DocxPDFConverter {
    public enum ConversionError: Error {
        case unreadableIntermediate
    }

    public init() {}

    public func convert(_ input: URL, to output: URL) async throws {
        let document = try DocxHTMLWriter.convert(input)
        let renderer = PagedPDFRenderer()
        guard !document.headerFooter.isEmpty else {
            try await renderer.render(html: document.html, baseURL: nil, to: output, page: document.page)
            return
        }

        // Headers depend on where pages fall, so the body is laid out first and they are stamped on after.
        let work = FileManager.default.temporaryDirectory.appending(path: "conv-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let body = work.appending(path: "body.pdf")
        let overlay = work.appending(path: "overlay.pdf")

        try await renderer.render(html: document.html, baseURL: nil, to: body, page: document.page)
        guard let rendered = PDFDocument(url: body) else { throw ConversionError.unreadableIntermediate }
        let starts = Self.sectionStarts(document.headerFooter.sections, in: rendered)
        let overlayHTML = document.headerFooter.overlayHTML(pageCount: rendered.pageCount, sectionStarts: starts)
        try await renderer.render(html: overlayHTML, baseURL: nil, to: overlay, page: document.headerFooter.overlayPage)
        try PDFStamp.stamp(overlay, onto: body, to: output)
    }

    /// The intermediate HTML, for inspecting what the converter produced.
    public func html(for input: URL) throws -> String {
        try DocxHTMLWriter.convert(input).html
    }

    /// The page size and margins taken from the document's last section.
    public func pageSetup(for input: URL) throws -> PagedPDFRenderer.PageSetup {
        try DocxHTMLWriter.convert(input).page
    }

    /// The zero-based page each section starts on, found by its first words. Whitespace is ignored
    /// because line breaks and justification change it in the PDF's text.
    static func sectionStarts(_ sections: [DocxHeaderFooter.Section], in document: PDFDocument) -> [Int] {
        var starts: [Int] = []
        var page = 0
        let pageTexts = (0..<document.pageCount).map { document.page(at: $0)?.string?.filter { !$0.isWhitespace } ?? "" }
        for section in sections {
            if !starts.isEmpty, let text = section.firstText?.filter({ !$0.isWhitespace }), !text.isEmpty {
                page = (page..<pageTexts.count).first { pageTexts[$0].contains(text) } ?? page
            }
            starts.append(page)
        }
        return starts
    }
}
