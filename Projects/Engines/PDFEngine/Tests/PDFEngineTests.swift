import ConversionKit
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
@testable import PDFEngine

@Suite struct PDFEngineTests {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "pdf-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    @Test(arguments: ["jpg", "png"])
    func pagesBecomeImagesAt150DPI(format: String) throws {
        let input = try writePDF(named: "letter.pdf", pages: [CGSize(width: 612, height: 792), CGSize(width: 792, height: 612)])
        let output = directory.appending(path: "pages")
        var fractions: [Double] = []
        try PDFPageRenderer().render(input, as: format, to: output) { fractions.append($0) }
        let pages = try PackedFiles.Reader(FileHandle(forReadingFrom: output))
        #expect(pages.count == 2)
        var sizes: [CGSize] = []
        try pages.forEach { _, data in
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            sizes.append(CGSize(width: image.width, height: image.height))
        }
        // 8.5 × 11 inches at 150 dpi, then the landscape page.
        #expect(sizes == [CGSize(width: 1275, height: 1650), CGSize(width: 1650, height: 1275)])
        #expect(fractions.last == 1)
    }

    @Test func rotatedPagesComeOutUpright() throws {
        let input = try writePDF(named: "turned.pdf", pages: [CGSize(width: 612, height: 792)], rotation: 90)
        let page = try #require(PDFEngine.document(at: input).page(at: 1))
        let image = try #require(PDFPageRenderer().image(of: page))
        #expect(image.width > image.height)
    }

    @Test func pdfsAndTheirPagesCombineInOrder() throws {
        let first = try writePDF(named: "a.pdf", pages: [CGSize(width: 100, height: 100), CGSize(width: 200, height: 200)])
        let second = try writePDF(named: "b.pdf", pages: [CGSize(width: 300, height: 300)])
        let output = directory.appending(path: "combined.pdf")
        try PDFCombiner().combine([first, second], to: output)
        let combined = try #require(PDFDocument(url: output))
        #expect(combined.pageCount == 3)
        #expect((0..<3).map { combined.page(at: $0)?.bounds(for: .mediaBox).width } == [100, 200, 300])
    }

    @Test func combiningSaysWhichInputFailed() throws {
        let good = try writePDF(named: "good.pdf", pages: [CGSize(width: 100, height: 100)])
        let bad = directory.appending(path: "bad.pdf")
        try Data("not a pdf".utf8).write(to: bad)
        do {
            try PDFCombiner().combine([good, bad], to: directory.appending(path: "combined.pdf"))
            Issue.record("expected the second input to fail")
        } catch PDFCombiner.InputError.failed(let index, let error) {
            #expect(index == 1)
            #expect(error == .unreadable)
        }
    }

    @Test func somethingElseIsUnreadable() throws {
        let input = directory.appending(path: "fake.pdf")
        try Data("not a pdf".utf8).write(to: input)
        #expect(throws: PDFEngine.ConversionError.unreadable) {
            try PDFPageRenderer().render(input, as: "jpg", to: directory.appending(path: "out"))
        }
    }

    /// Pages of the given sizes, each filled so they aren't blank.
    private func writePDF(named name: String, pages: [CGSize], rotation: Int = 0) throws -> URL {
        let url = directory.appending(path: name)
        let context = try #require(CGContext(url as CFURL, mediaBox: nil, nil))
        for size in pages {
            var box = CGRect(origin: .zero, size: size)
            let info: [CFString: Any] = [kCGPDFContextMediaBox: Data(bytes: &box, count: MemoryLayout<CGRect>.size)]
            context.beginPDFPage(info as CFDictionary)
            context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
            context.fill(box.insetBy(dx: 10, dy: 10))
            context.endPDFPage()
        }
        context.closePDF()
        guard rotation != 0 else { return url }
        // CoreGraphics can't write /Rotate; PDFKit can.
        let document = try #require(PDFDocument(url: url))
        for index in 0..<document.pageCount { document.page(at: index)?.rotation = rotation }
        #expect(document.write(to: url))
        return url
    }
}
