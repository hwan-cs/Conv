import Foundation

/// Headers and footers per section, laid out once the body's page count is known.
///
/// They are written as a second, transparent document with one page per body page, then stamped
/// onto the body: Word decides which header a page gets only after pagination, which HTML cannot see.
struct DocxHeaderFooter {
    struct Section {
        var page: PagedPDFRenderer.PageSetup
        var headerDistance: Double
        var footerDistance: Double
        var startsNewPage: Bool
        /// The first words of the section, used to find the page it starts on.
        var firstText: String?
        var hasTitlePage: Bool
        var pageNumberStart: Int?
        /// "default", "first", "even" → HTML, already inherited from earlier sections.
        var headers: [String: String]
        var footers: [String: String]
    }

    static let pageToken = "\u{E001}PAGE\u{E001}"
    static let pageCountToken = "\u{E001}NUMPAGES\u{E001}"

    var sections: [Section]
    var evenAndOddHeaders: Bool
    /// The body's print setup; the overlay matches its paper and column.
    var page: PagedPDFRenderer.PageSetup
    var fontFaces: String

    var isEmpty: Bool {
        sections.allSatisfy { $0.headers.isEmpty && $0.footers.isEmpty }
    }

    /// The overlay's print setup: full-bleed vertically so headers and footers can sit in the margins.
    var overlayPage: PagedPDFRenderer.PageSetup {
        var overlay = page
        overlay.margins.top = 0
        overlay.margins.bottom = 0
        return overlay
    }

    /// One overlay page per body page. `sectionStarts[i]` is the zero-based page section `i` starts on.
    func overlayHTML(pageCount: Int, sectionStarts: [Int]) -> String {
        var pages: [String] = []
        var pageNumber = 0
        for index in 0..<pageCount {
            // A page belongs to the first section on it: a continuous section starting mid-page doesn't own it.
            let owner = sections.indices.last { section in
                let start = sectionStarts[section]
                return start < index || (start == index && (section == 0 || sections[section].startsNewPage))
            } ?? 0
            let section = sections[owner]
            let isFirstPage = sectionStarts[owner] == index
            if isFirstPage, let start = section.pageNumberStart {
                pageNumber = start
            } else {
                pageNumber += 1
            }

            let kind = section.hasTitlePage && isFirstPage ? "first"
                : evenAndOddHeaders && pageNumber % 2 == 0 ? "even" : "default"
            let fill = { (html: String) in
                html.replacingOccurrences(of: Self.pageToken, with: String(pageNumber))
                    .replacingOccurrences(of: Self.pageCountToken, with: String(pageCount))
            }
            let left = decimal(section.page.margins.left - page.margins.left)
            let right = decimal(section.page.margins.right - page.margins.right)
            // The footer hangs below the shortened block to reach its true distance from the paper's edge.
            let footerBottom = section.footerDistance - (page.paperSize.height - blockHeight)
            var css = ["position:relative", "height:\(decimal(blockHeight))pt"]
            if index > 0 { css.append("break-before:page") }
            pages.append("""
            <div style="\(css.joined(separator: ";"))">\
            <div style="position:absolute;left:\(left)pt;right:\(right)pt;top:\(decimal(section.headerDistance))pt">\(fill(section.headers[kind] ?? ""))</div>\
            <div style="position:absolute;left:\(left)pt;right:\(right)pt;bottom:\(decimal(footerBottom))pt">\(fill(section.footers[kind] ?? ""))</div>\
            </div>
            """)
        }
        return DocxHTMLWriter.document(pages.joined(separator: "\n"), fontFaces: fontFaces)
    }

    /// WebKit fits about 1.5% less than the paper's height on a printed page (measured on A4 and Letter),
    /// so a block as tall as the paper would spill onto a second page.
    private var blockHeight: Double {
        (page.paperSize.height * 0.98).rounded(.down)
    }
}
