import AppKit
import ImageIO
import UniformTypeIdentifiers
import WebKit

/// .svg → PNG, JPEG or PDF. AppKit draws the SVG into pixels at twice its size, larger for small
/// icons, so the image is crisp. WebKit draws it into a PDF as vectors, so it stays sharp at any
/// zoom: AppKit's PDFs lose fills under gradients that fade to transparent.
public struct SVGConverter: Sendable {
    public enum ConversionError: Error, Equatable {
        case unreadable
        case unsupportedOutput(String)
        case encodingFailed
        case timedOut
    }

    public static let outputs: [String: UTType] = [
        "png": .png,
        "jpg": .jpeg,
        "pdf": .pdf,
    ]

    /// Small SVGs grow until their longest side reaches this many pixels.
    static let minimumSide = 1024.0
    /// No side grows past this many pixels.
    static let maximumSide = 8192.0

    public init() {}

    public func convert(_ input: URL, to output: URL) async throws {
        let ext = output.pathExtension.lowercased()
        guard let type = Self.outputs[ext] else {
            throw ConversionError.unsupportedOutput(ext)
        }
        guard let image = NSImage(contentsOf: input),
              image.isValid,
              image.size.width > 0,
              image.size.height > 0
        else {
            throw ConversionError.unreadable
        }
        if type == .pdf {
            try await writePDF(
                input,
                size: image.size,
                to: output
            )
        } else {
            try writeImage(
                image,
                as: type,
                to: output
            )
        }
    }

    /// One page the SVG's size, in points.
    @MainActor
    private func writePDF(
        _ input: URL,
        size: CGSize,
        to output: URL
    ) async throws {
        _ = NSApplication.shared
        let svg = try Data(contentsOf: input).base64EncodedString()
        let html = """
            <!doctype html>
            <html><body style="margin:0">
            <img src="data:image/svg+xml;base64,\(svg)" style="display:block;width:\(size.width)px;height:\(size.height)px">
            </body></html>
            """
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(
            frame: CGRect(origin: .zero, size: size),
            configuration: configuration
        )
        webView.setValue(false, forKey: "drawsBackground")
        try await SVGPageLoader(webView: webView).load(html)
        let pdf = WKPDFConfiguration()
        pdf.rect = webView.bounds
        let data: Data
        do {
            data = try await webView.pdf(configuration: pdf)
        } catch {
            throw ConversionError.encodingFailed
        }
        try data.write(to: output)
    }

    private func writeImage(
        _ image: NSImage,
        as type: UTType,
        to output: URL
    ) throws {
        let longest = max(image.size.width, image.size.height)
        let scale = min(
            max(2, Self.minimumSide / longest),
            Self.maximumSide / longest
        )
        let width = max(1, Int((image.size.width * scale).rounded()))
        let height = max(1, Int((image.size.height * scale).rounded()))
        let opaque = type == .jpeg
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            throw ConversionError.encodingFailed
        }
        // JPEG has no transparency, so what's clear becomes white.
        if opaque {
            context.setFillColor(
                CGColor(
                    red: 1,
                    green: 1,
                    blue: 1,
                    alpha: 1
                )
            )
            context.fill(
                CGRect(
                    x: 0,
                    y: 0,
                    width: width,
                    height: height
                )
            )
        }
        draw(
            image,
            in: context,
            size: CGSize(width: width, height: height)
        )
        guard let rendered = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, 1, nil)
        else {
            throw ConversionError.encodingFailed
        }
        // The resolution keeps the image the SVG's size when placed in a document.
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.9,
            kCGImagePropertyDPIWidth: 72 * scale,
            kCGImagePropertyDPIHeight: 72 * scale,
        ]
        CGImageDestinationAddImage(
            destination,
            rendered,
            properties as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw ConversionError.encodingFailed
        }
    }

    private func draw(
        _ image: NSImage,
        in context: CGContext,
        size: CGSize
    ) {
        NSGraphicsContext.saveGraphicsState()
        defer {
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.current = NSGraphicsContext(
            cgContext: context,
            flipped: false
        )
        image.draw(in: CGRect(origin: .zero, size: size))
    }
}

/// Waits once for a page to load, or gives up after 30 seconds.
@MainActor
private final class SVGPageLoader: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private var continuation: CheckedContinuation<Void, any Error>?

    init(webView: WKWebView) {
        self.webView = webView
    }

    func load(_ html: String) async throws {
        webView.navigationDelegate = self
        defer {
            webView.navigationDelegate = nil
        }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                self.finish(.failure(SVGConverter.ConversionError.timedOut))
            }
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    private func finish(_ result: Result<Void, any Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(.success(()))
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: any Error
    ) {
        finish(.failure(SVGConverter.ConversionError.encodingFailed))
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        finish(.failure(SVGConverter.ConversionError.encodingFailed))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(.failure(SVGConverter.ConversionError.encodingFailed))
    }
}
