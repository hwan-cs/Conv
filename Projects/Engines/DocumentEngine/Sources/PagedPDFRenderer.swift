import AppKit
import WebKit

/// Renders HTML into a paginated PDF.
///
/// `WKWebView.createPDF` returns one tall page, so pagination goes through the print system,
/// which also honors CSS `break-before: page`.
@MainActor
public final class PagedPDFRenderer {
    public struct PageSetup: Sendable {
        public var paperSize: CGSize
        public var margin: CGFloat

        public init(paperSize: CGSize, margin: CGFloat) {
            self.paperSize = paperSize
            self.margin = margin
        }

        /// A4 with 2cm margins, in points.
        public static let a4 = PageSetup(paperSize: CGSize(width: 595.28, height: 841.89), margin: 56.69)
    }

    public enum RenderError: Error {
        case printFailed
    }

    public init() {}

    public func render(html: String, baseURL: URL?, to output: URL, page: PageSetup = .a4) async throws {
        // Unhosted processes (tests, the XPC service) have no NSApplication until asked for one.
        _ = NSApplication.shared

        let contentWidth = page.paperSize.width - page.margin * 2
        let frame = CGRect(x: 0, y: 0, width: contentWidth, height: page.paperSize.height)
        let webView = WKWebView(frame: frame)
        // The print system needs the web view in a window; this one is never shown.
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView

        try await NavigationWaiter(webView: webView).load(html: html, baseURL: baseURL)

        let info = NSPrintInfo()
        info.paperSize = page.paperSize
        info.topMargin = page.margin
        info.bottomMargin = page.margin
        info.leftMargin = page.margin
        info.rightMargin = page.margin
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = output

        let operation = webView.printOperation(with: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        // Without a real frame the print view lays out at zero size and prints blank pages.
        operation.view?.frame = webView.bounds

        guard operation.run() else { throw RenderError.printFailed }
    }
}

@MainActor
private final class NavigationWaiter: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private var continuation: CheckedContinuation<Void, any Error>?

    init(webView: WKWebView) {
        self.webView = webView
    }

    func load(html: String, baseURL: URL?) async throws {
        webView.navigationDelegate = self
        defer { webView.navigationDelegate = nil }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
