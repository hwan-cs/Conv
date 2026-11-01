import Foundation
import PDFKit

/// .hwp and .hwpx → paginated PDF: the binary records or XML parts are read into `HwpDocument`,
/// written as HTML per section, laid out by `PagedPDFRenderer`, and the sections' PDFs joined.
///
/// Headers, footers and page numbers depend on how many pages a section takes, so they are laid
/// out afterwards and stamped over the body, as for .docx.
@MainActor
public struct HwpPDFConverter {
    public enum ConversionError: Error {
        case unreadableIntermediate
        case unwritableOutput
        /// Not an .hwp or .hwpx, or damaged.
        case unreadableDocument
        case passwordProtected
        /// HWP 3 and older, a different format altogether.
        case unsupportedVersion(String)
    }

    public init() {}

    public func convert(_ input: URL, to output: URL) async throws {
        var writer = try Self.writer(for: input)
        let sections = writer.sections()
        let renderer = PagedPDFRenderer()

        let work = FileManager.default.temporaryDirectory.appending(path: "conv-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let joined = PDFDocument()
        var nextPageNumber = 1
        for (index, section) in sections.enumerated() {
            var part = work.appending(path: "section\(index).pdf")
            try await renderer.render(html: section.html, baseURL: nil, to: part, page: section.page, script: HwpHTMLWriter.fitLines)
            guard let body = PDFDocument(url: part) else { throw ConversionError.unreadableIntermediate }

            let start = writer.pageNumberStart(section: index) ?? nextPageNumber
            nextPageNumber = start + body.pageCount
            if let overlay = writer.overlay(section: index, pageCount: body.pageCount, firstPageNumber: start) {
                let overlayPDF = work.appending(path: "overlay\(index).pdf")
                try await renderer.render(html: overlay.html, baseURL: nil, to: overlayPDF, page: overlay.page)
                let stamped = work.appending(path: "stamped\(index).pdf")
                try PDFStamp.stamp(overlayPDF, onto: part, to: stamped)
                part = stamped
            }

            guard let rendered = PDFDocument(url: part) else { throw ConversionError.unreadableIntermediate }
            for number in 0..<rendered.pageCount {
                if let page = rendered.page(at: number) { joined.insert(page, at: joined.pageCount) }
            }
        }
        guard joined.write(to: output) else { throw ConversionError.unwritableOutput }
    }

    /// The intermediate HTML of every section, for inspecting what the converter produced.
    public func html(for input: URL) throws -> [String] {
        var writer = try Self.writer(for: input)
        return writer.sections().map(\.html)
    }

    private static func writer(for input: URL) throws -> HwpHTMLWriter {
        HwpHTMLWriter(document: try document(at: input))
    }

    /// .hwpx (ZIP) or .hwp (compound file), told apart by content: Hangul also saves .hwpx under a .hwp name.
    nonisolated static func document(at input: URL) throws -> HwpDocument {
        do {
            if HwpxReader.isPackage(input) {
                var reader = try HwpxReader(url: input)
                return try reader.read()
            }
            return try HwpBinaryReader(file: HwpFile(url: input)).read()
        } catch HwpFile.HwpError.passwordProtected {
            throw ConversionError.passwordProtected
        } catch HwpFile.HwpError.unsupportedVersion(let version) {
            throw ConversionError.unsupportedVersion(version)
        } catch {
            throw ConversionError.unreadableDocument
        }
    }
}
