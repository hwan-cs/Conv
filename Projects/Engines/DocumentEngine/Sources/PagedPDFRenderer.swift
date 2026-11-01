import AppKit
import WebKit

/// Renders HTML into a paginated PDF.
///
/// `WKWebView.createPDF` returns one tall page, so pagination goes through the print system,
/// which also honors CSS `break-before: page`.
@MainActor
public final class PagedPDFRenderer {
    public struct PageSetup: Sendable, Equatable {
        public struct Margins: Sendable, Equatable {
            public var top: CGFloat
            public var left: CGFloat
            public var bottom: CGFloat
            public var right: CGFloat

            public init(top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) {
                self.top = top
                self.left = left
                self.bottom = bottom
                self.right = right
            }
        }

        public var paperSize: CGSize
        public var margins: Margins

        public init(paperSize: CGSize, margins: Margins) {
            self.paperSize = paperSize
            self.margins = margins
        }

        /// A4 with 2cm margins, in points.
        public static let a4 = PageSetup(
            paperSize: CGSize(width: 595.28, height: 841.89),
            margins: Margins(top: 56.69, left: 56.69, bottom: 56.69, right: 56.69)
        )
    }

    public enum RenderError: Error {
        /// WebKit's content process crashed or could not be launched.
        case webContentTerminated
        case printFailed
        /// The print operation cannot be cancelled and may still be writing; the caller should
        /// tear down the process it runs in (the XPC service exits).
        case timedOut
    }

    public init() {}

    static let physicalZoom = 15.0 / 16.0

    public func render(
        html: String,
        baseURL: URL?,
        to output: URL,
        page: PageSetup = .a4,
        script: String? = nil,
        timeout: Duration = .seconds(60)
    ) async throws {
        // Unhosted processes (tests, the XPC service) have no NSApplication until asked for one.
        _ = NSApplication.shared

        let contentWidth = page.paperSize.width - page.margins.left - page.margins.right
        let frame = CGRect(x: 0, y: 0, width: contentWidth, height: page.paperSize.height)
        let configuration = WKWebViewConfiguration()
        // Pages are documents, never apps: scripts in them (a <script> in Markdown) don't run.
        // The renderer's own evaluateJavaScript calls are unaffected.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: frame, configuration: configuration)
        // The print system needs the web view in a window; this one is never shown.
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView

        let deadline = ContinuousClock.now + timeout
        try await NavigationWaiter(webView: webView).load(html: html, baseURL: baseURL, timeout: timeout)
        // WebKit prints CSS at 16/15 of its size (96/72 px-to-pt times its 1.25 minimum shrink),
        // so a 10pt font would print at 10.67pt. Zooming by the inverse keeps CSS units physical.
        _ = try? await webView.evaluateJavaScript("document.documentElement.style.zoom = '\(Self.physicalZoom)'")
        // Adjustments that need the laid-out page, run before it is printed. Pictures they move
        // are decoded again, and the print would otherwise catch some still blank.
        if let script {
            _ = try? await webView.callAsyncJavaScript(
                script + "\nawait Promise.all([...document.images].map(image => image.decode().catch(() => {})));",
                contentWorld: .page
            )
        }

        let info = NSPrintInfo()
        info.paperSize = page.paperSize
        info.topMargin = page.margins.top
        info.bottomMargin = page.margins.bottom
        info.leftMargin = page.margins.left
        info.rightMargin = page.margins.right
        // Clip rather than fit: one over-wide image must not shrink every page.
        info.horizontalPagination = .clip
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

        // WebKit supplies pages asynchronously; the blocking `run()` never finishes and keeps emitting pages.
        switch await PrintCompletion().run(operation, for: window, timeout: deadline - .now) {
        case .finished(true): return
        case .finished(false): throw RenderError.printFailed
        case .timedOut:
            try? FileManager.default.removeItem(at: output)
            throw RenderError.timedOut
        }
    }
}

/// Resumed exactly once: by AppKit's print thread when the operation ends, or by the timeout.
private final class PrintCompletion: NSObject, @unchecked Sendable {
    enum Outcome {
        case finished(Bool)
        case timedOut
    }

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Outcome, Never>?

    @MainActor
    func run(_ operation: NSPrintOperation, for window: NSWindow, timeout: Duration) async -> Outcome {
        await withCheckedContinuation { continuation in
            lock.withLock { self.continuation = continuation }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout.timeInterval) {
                self.finish(.timedOut)
            }
            operation.runModal(
                for: window,
                delegate: self,
                didRun: #selector(printOperationDidRun(_:success:contextInfo:)),
                contextInfo: nil
            )
        }
    }

    private func finish(_ outcome: Outcome) {
        let continuation = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: outcome)
    }

    // Called on AppKit's print thread, not the main thread.
    @objc private func printOperationDidRun(
        _ operation: NSPrintOperation,
        success: Bool,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        finish(.finished(success))
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}

@MainActor
private final class NavigationWaiter: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private var continuation: CheckedContinuation<Void, any Error>?

    init(webView: WKWebView) {
        self.webView = webView
    }

    func load(html: String, baseURL: URL?, timeout: Duration) async throws {
        webView.navigationDelegate = self
        defer { webView.navigationDelegate = nil }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout.timeInterval) {
                self.finish(.failure(PagedPDFRenderer.RenderError.timedOut))
            }
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }

    private func finish(_ result: Result<Void, any Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        finish(.failure(error))
    }

    // Not a navigation failure, so without this a dead content process leaves the load waiting forever.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(.failure(PagedPDFRenderer.RenderError.webContentTerminated))
    }
}
