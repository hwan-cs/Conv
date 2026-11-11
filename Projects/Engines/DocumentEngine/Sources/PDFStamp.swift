import CoreGraphics
import Foundation

/// Draws one PDF's pages over another's, page for page, keeping both as vector text.
enum PDFStamp {
    enum StampError: Error {
        case unreadable
        case unwritable
    }

    static func stamp(_ overlay: URL, onto base: URL, to output: URL) throws {
        guard let baseDocument = CGPDFDocument(base as CFURL),
              let overlayDocument = CGPDFDocument(overlay as CFURL) else {
            throw StampError.unreadable
        }
        guard let context = CGContext(output as CFURL, mediaBox: nil, nil) else {
            throw StampError.unwritable
        }
        for number in 1...max(baseDocument.numberOfPages, 1) {
            guard let page = baseDocument.page(at: number) else {
                continue
            }
            var box = page.getBoxRect(.mediaBox)
            context.beginPage(mediaBox: &box)
            context.drawPDFPage(page)
            if let stamp = overlayDocument.page(at: number) {
                context.saveGState()
                context.setBlendMode(.multiply)
                context.drawPDFPage(stamp)
                context.restoreGState()
            }
            context.endPage()
        }
        context.closePDF()
    }
}
