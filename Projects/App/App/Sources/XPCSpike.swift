#if DEBUG
import AppKit
import ConversionKit

/// P1 spike: `Conv.app/Contents/MacOS/Conv --spike-xpc-pdf` renders HTML to PDF through the
/// sandboxed XPC service, writes `conv-spike/xpc.pdf` and `xpc.log` into the app's temporary
/// directory, then quits.
enum XPCSpike {
    static var isRequested: Bool { CommandLine.arguments.contains("--spike-xpc-pdf") }

    @MainActor
    static func run() {
        let directory = FileManager.default.temporaryDirectory.appending(path: "conv-spike", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let log = directory.appending(path: "xpc.log")
        let pdf = directory.appending(path: "xpc.pdf")
        try? FileManager.default.removeItem(at: pdf)

        let connection = NSXPCConnection(serviceName: ConversionService.serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: ConversionServiceProtocol.self)
        connection.resume()

        let started = Date()
        let finish: @Sendable (String) -> Void = { message in
            let line = "\(message) after \(String(format: "%.2f", Date().timeIntervalSince(started)))s\n"
            try? Data(line.utf8).write(to: log)
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        let service = connection.remoteObjectProxyWithErrorHandler { @Sendable error in
            finish("xpc error: \(error)")
        } as? ConversionServiceProtocol
        service?.renderPDF(fromHTML: html) { @Sendable data, error in
            guard let data else { return finish("render error: \(error ?? "unknown")") }
            do {
                try data.write(to: pdf)
                finish("ok \(data.count) bytes")
            } catch {
                finish("write error: \(error)")
            }
        }
    }

    private static let html: String = {
        let paragraphs = (1...120).map { "<p>문단 \($0). 샌드박스 XPC 안에서 렌더링한 페이지.</p>" }
        return """
        <html><head><meta charset="utf-8">
        <style>body { font-family: -apple-system; font-size: 12pt; }</style>
        </head><body>\(paragraphs.joined())
        <h1 style="break-before: page">BREAK-MARKER</h1><p>마지막 문단</p></body></html>
        """
    }()
}
#endif
