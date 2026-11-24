import Foundation
import PDFKit

/// Spreadsheets: .csv → .xlsx so Excel opens Hangul unbroken, the open sheet of an .xlsx →
/// .csv, and every visible sheet of an .xlsx → PDF, laid out as Excel prints it.
@MainActor
public struct SheetConverter {
    public enum ConversionError: Error, Equatable {
        case unreadable
        case passwordProtected
        case empty
        case tooLarge
        case unsupportedOutput(String)
    }

    public init() {}

    /// - Parameters:
    ///   - title: The original file's name without its extension, for the sheet's name.
    ///   - progress: Called with 0…1 as a PDF's pages are printed.
    public func convert(
        _ input: URL,
        to output: URL,
        title: String? = nil,
        progress: @escaping (Double) -> Void = { _ in }
    ) async throws {
        let ext = output.pathExtension.lowercased()
        switch (input.pathExtension.lowercased(), ext) {
        case ("csv", "xlsx"):
            guard let table = try? CSVTable(contentsOf: input) else {
                throw ConversionError.unreadable
            }
            let writer = XLSXWriter(
                rows: table.rows,
                sheetName: title ?? input.deletingPathExtension().lastPathComponent
            )
            do {
                try writer.write(to: output)
            } catch XLSXWriter.WriteError.tooLarge {
                throw ConversionError.tooLarge
            }
        case ("xlsx", "csv"):
            let workbook = try Self.workbook(input)
            guard workbook.sheets.indices.contains(workbook.activeSheet) else {
                throw ConversionError.empty
            }
            let rows = workbook.sheets[workbook.activeSheet].rows()
            try CSVTable(rows: rows)
                .data()
                .write(to: output)
        case ("xlsx", "pdf"):
            try await pdf(
                Self.workbook(input),
                to: output,
                progress: progress
            )
        default:
            throw ConversionError.unsupportedOutput(ext)
        }
    }

    private static func workbook(_ input: URL) throws -> XLSXWorkbook {
        do {
            return try XLSXWorkbook(url: input)
        } catch {
            throw DocxPackage.isEncrypted(input) ? ConversionError.passwordProtected : ConversionError.unreadable
        }
    }

    /// Every visible sheet, a few pages at a time: WebKit prints a long document in time that
    /// grows with the square of its length, and sheets can differ in paper and orientation.
    private func pdf(
        _ workbook: XLSXWorkbook,
        to output: URL,
        progress: (Double) -> Void
    ) async throws {
        let writer = SheetHTMLWriter(workbook: workbook)
        var jobs: [(sheet: XLSXWorkbook.Sheet, layout: SheetHTMLWriter.Layout, pages: Range<Int>)] = []
        for sheet in workbook.sheets where !sheet.isHidden {
            guard let layout = writer.layout(for: sheet) else {
                continue
            }
            for pages in writer.chunks(layout) {
                jobs.append((sheet, layout, pages))
            }
        }
        guard !jobs.isEmpty else {
            throw ConversionError.empty
        }

        let work = FileManager.default.temporaryDirectory.appending(
            path: "conv-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: work,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: work)
        }
        let renderer = PagedPDFRenderer()
        var parts: [URL] = []
        for (index, job) in jobs.enumerated() {
            let url = jobs.count == 1 ? output : work.appending(path: "part-\(index).pdf")
            let cells = job.pages.reduce(0) { total, page in
                total + job.layout.rows(onPage: page).count * job.layout.columns(onPage: page).count
            }
            try await renderer.render(
                html: writer.html(
                    for: job.sheet,
                    layout: job.layout,
                    pages: job.pages
                ),
                baseURL: nil,
                to: url,
                page: job.layout.page,
                script: SheetHTMLWriter.fitNumbersScript,
                // A minute, and more for a big run: about a second per thousand cells.
                timeout: .seconds(60 + cells / 1000)
            )
            parts.append(url)
            progress(Double(index + 1) / Double(jobs.count))
        }
        guard parts.count > 1 else {
            return
        }

        // Kept alive until the combined document is written: their pages belong to them.
        var documents: [PDFDocument] = []
        let combined = PDFDocument()
        for part in parts {
            guard let document = PDFDocument(url: part) else {
                throw ConversionError.unreadable
            }
            documents.append(document)
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else {
                    continue
                }
                combined.insert(
                    page,
                    at: combined.pageCount
                )
            }
        }
        guard combined.write(to: output) else {
            throw ConversionError.unreadable
        }
    }
}
