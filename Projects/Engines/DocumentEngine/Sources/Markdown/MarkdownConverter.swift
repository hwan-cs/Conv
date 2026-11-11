import Foundation
import Markdown

/// Markdown (CommonMark with GitHub's tables, strikethrough and task lists) → a styled HTML page,
/// or that page paginated to PDF.
@MainActor
public struct MarkdownConverter {
    public enum ConversionError: Error {
        case unreadable
        case unsupportedOutput(String)
    }

    public static let inputs: Set<String> = ["md", "markdown"]

    public init() {}

    public func convert(_ input: URL, to output: URL) async throws {
        guard let data = try? Data(contentsOf: input) else {
            throw ConversionError.unreadable
        }
        let source = String(decoding: data, as: UTF8.self)
        let title = input.deletingPathExtension().lastPathComponent
        let html = Self.page(for: source, title: title)
        switch output.pathExtension.lowercased() {
        case "html", "htm":
            try Data(html.utf8).write(to: output)
        case "pdf":
            let margin = 56.69
            let page = PagedPDFRenderer.PageSetup(
                paperSize: PagedPDFRenderer.PageSetup.a4.paperSize,
                margins: .init(top: margin, left: margin, bottom: margin, right: margin)
            )
            try await PagedPDFRenderer().render(html: html, baseURL: nil, to: output, page: page)
        case let ext:
            throw ConversionError.unsupportedOutput(ext)
        }
    }

    /// A complete page: the document's first heading (or the file name) as its title, GitHub-like
    /// styling, a dark scheme on screen and always light in print.
    static func page(for markdown: String, title fallback: String) -> String {
        let document = Document(parsing: withoutFrontMatter(markdown))
        let title = document.children.lazy.compactMap { ($0 as? Heading).flatMap { $0.level == 1 ? $0.plainText : nil } }.first ?? fallback
        var writer = MarkdownHTML()
        writer.visit(document)
        return """
        <!doctype html>
        <html lang="ko">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(MarkdownHTML.escape(title))</title>
        <style>\(style)</style>
        </head>
        <body>
        <main>
        \(writer.result)</main>
        </body>
        </html>

        """
    }

    /// YAML front matter (`---` … `---` at the very top) is metadata, not text.
    static func withoutFrontMatter(_ markdown: String) -> String {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" || $0 == "..." })
        else {
            return markdown
        }
        return lines[(end + 1)...].joined(separator: "\n")
    }

    static let style = """
    :root {
        color-scheme: light dark;
        --text: #1f2328; --muted: #59636e; --line: #d1d9e0; --soft: #f6f8fa; --link: #0969da; --mark: #fff8c5;
    }
    @media screen and (prefers-color-scheme: dark) {
        :root { --text: #e6edf3; --muted: #9198a1; --line: #3d444d; --soft: #151b23; --link: #4493f8; --mark: #4d4300; }
        body { background: #0d1117; }
    }
    @media print { :root { color-scheme: light; } }
    * { box-sizing: border-box; -webkit-print-color-adjust: exact; print-color-adjust: exact; }
    body {
        margin: 0; color: var(--text);
        font: 16px/1.6 -apple-system, BlinkMacSystemFont, "Apple SD Gothic Neo", "Helvetica Neue", sans-serif;
        word-break: keep-all; overflow-wrap: break-word;
    }
    main { max-width: 780px; margin: 0 auto; padding: 48px 24px; }
    @media print { main { max-width: none; padding: 0; } body { font-size: 11pt; } }
    h1, h2, h3, h4, h5, h6 { margin: 1.6em 0 0.6em; line-height: 1.3; break-after: avoid; }
    h1 { font-size: 2em; padding-bottom: 0.3em; border-bottom: 1px solid var(--line); }
    h2 { font-size: 1.5em; padding-bottom: 0.3em; border-bottom: 1px solid var(--line); }
    h3 { font-size: 1.25em; } h4 { font-size: 1em; } h5 { font-size: 0.875em; } h6 { font-size: 0.85em; color: var(--muted); }
    main > :first-child { margin-top: 0; }
    p, ul, ol, blockquote, pre, table { margin: 0 0 1em; }
    a { color: var(--link); text-decoration: none; }
    a:hover { text-decoration: underline; }
    ul, ol { padding-left: 2em; }
    li + li { margin-top: 0.25em; }
    li.task { list-style: none; }
    li.task > input { margin: 0 0.4em 0 -1.4em; vertical-align: middle; }
    blockquote { padding: 0 1em; color: var(--muted); border-left: 0.25em solid var(--line); }
    code, pre { font-family: "SF Mono", Menlo, Consolas, monospace; font-size: 0.875em; }
    code { padding: 0.15em 0.35em; border-radius: 6px; background: var(--soft); }
    pre { padding: 16px; border-radius: 6px; background: var(--soft); line-height: 1.45; white-space: pre-wrap; break-inside: avoid; }
    pre code { padding: 0; background: none; font-size: 1em; }
    table { border-collapse: collapse; display: block; overflow-x: auto; max-width: 100%; }
    @media print { table { display: table; } }
    th, td { padding: 6px 13px; border: 1px solid var(--line); }
    th { font-weight: 600; background: var(--soft); }
    tr { break-inside: avoid; }
    img { max-width: 100%; }
    hr { height: 0.25em; margin: 24px 0; border: 0; background: var(--line); }
    del { color: var(--muted); }
    """
}

/// HTML for a Markdown tree, escaping text where swift-markdown's own formatter doesn't.
struct MarkdownHTML: MarkupWalker {
    private(set) var result = ""
    private var tableAlignments: [Table.ColumnAlignment?] = []
    private var inTableHead = false
    private var column = 0

    static func escape(_ text: String, quotes: Bool = false) -> String {
        var escaped = ""
        for character in text {
            switch character {
            case "&": 
                escaped += "&amp;"
            case "<": 
                escaped += "&lt;"
            case ">": 
                escaped += "&gt;"
            case "\"" where quotes: 
                escaped += "&quot;"
            default:
                escaped.append(character)
            }
        }
        return escaped
    }

    private static func attribute(_ value: String) -> String { escape(value, quotes: true) }

    mutating func visitHeading(_ heading: Heading) {
        let id = heading.plainText.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : $0 == " " || $0 == "-" ? "-" : "" }
            .joined()
        result += "<h\(heading.level) id=\"\(Self.attribute(id))\">"
        descendInto(heading)
        result += "</h\(heading.level)>\n"
    }

    mutating func visitParagraph(_ paragraph: Paragraph) {
        result += "<p>"
        descendInto(paragraph)
        result += "</p>\n"
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        result += "<blockquote>\n"
        descendInto(blockQuote)
        result += "</blockquote>\n"
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        let language = codeBlock.language.map { " class=\"language-\(Self.attribute($0))\"" } ?? ""
        result += "<pre><code\(language)>\(Self.escape(codeBlock.code))</code></pre>\n"
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) {
        result += html.rawHTML
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
        result += "<hr>\n"
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) {
        let start = orderedList.startIndex == 1 ? "" : " start=\"\(orderedList.startIndex)\""
        result += "<ol\(start)>\n"
        descendInto(orderedList)
        result += "</ol>\n"
    }

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) {
        result += "<ul>\n"
        descendInto(unorderedList)
        result += "</ul>\n"
    }

    mutating func visitListItem(_ listItem: ListItem) {
        if let checkbox = listItem.checkbox {
            result += "<li class=\"task\"><input type=\"checkbox\" disabled\(checkbox == .checked ? " checked" : "")>"
        } else {
            result += "<li>"
        }
        // An item of a single paragraph reads as a plain line, as in a tight list.
        let paragraphs = listItem.children.filter { $0 is Paragraph }.count
        for child in listItem.children {
            if let paragraph = child as? Paragraph, paragraphs == 1 {
                descendInto(paragraph)
            } else {
                visit(child)
            }
        }
        result += "</li>\n"
    }

    mutating func visitTable(_ table: Table) {
        tableAlignments = table.columnAlignments
        result += "<table>\n"
        descendInto(table)
        result += "</table>\n"
    }

    mutating func visitTableHead(_ head: Table.Head) {
        inTableHead = true
        column = 0
        result += "<thead>\n<tr>\n"
        descendInto(head)
        result += "</tr>\n</thead>\n"
        inTableHead = false
    }

    mutating func visitTableBody(_ body: Table.Body) {
        guard body.childCount > 0 else {
            return
        }
        result += "<tbody>\n"
        descendInto(body)
        result += "</tbody>\n"
    }

    mutating func visitTableRow(_ row: Table.Row) {
        column = 0
        result += "<tr>\n"
        descendInto(row)
        result += "</tr>\n"
    }

    mutating func visitTableCell(_ cell: Table.Cell) {
        let tag = inTableHead ? "th" : "td"
        let alignment = column < tableAlignments.count ? tableAlignments[column] : nil
        let align = switch alignment {
        case .left: 
            " style=\"text-align:left\""
        case .center: 
            " style=\"text-align:center\""
        case .right: 
            " style=\"text-align:right\""
        case nil: 
            ""
        }
        let spans = (cell.colspan > 1 ? " colspan=\"\(cell.colspan)\"" : "") + (cell.rowspan > 1 ? " rowspan=\"\(cell.rowspan)\"" : "")
        result += "<\(tag)\(align)\(spans)>"
        descendInto(cell)
        result += "</\(tag)>\n"
        column += 1
    }

    // Inlines
    mutating func visitText(_ text: Text) {
        result += Self.escape(text.string)
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        result += "<code>\(Self.escape(inlineCode.code))</code>"
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) {
        result += "<em>"
        descendInto(emphasis)
        result += "</em>"
    }

    mutating func visitStrong(_ strong: Strong) {
        result += "<strong>"
        descendInto(strong)
        result += "</strong>"
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) {
        result += "<del>"
        descendInto(strikethrough)
        result += "</del>"
    }

    mutating func visitLink(_ link: Link) {
        let title = link.title.map { " title=\"\(Self.attribute($0))\"" } ?? ""
        result += "<a href=\"\(Self.attribute(link.destination ?? ""))\"\(title)>"
        descendInto(link)
        result += "</a>"
    }

    mutating func visitImage(_ image: Image) {
        let title = image.title.map { " title=\"\(Self.attribute($0))\"" } ?? ""
        result += "<img src=\"\(Self.attribute(image.source ?? ""))\" alt=\"\(Self.attribute(image.plainText))\"\(title)>"
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) {
        result += inlineHTML.rawHTML
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) {
        result += "<br>\n"
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) {
        result += "\n"
    }
}
