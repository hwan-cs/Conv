import ConversionKit
import DocumentEngine
import Foundation

final class ConversionServiceImpl: NSObject, ConversionServiceProtocol {
    func ping(withReply reply: @escaping @Sendable (String) -> Void) {
        reply("pong")
    }

    func renderPDF(fromHTML html: String, withReply reply: @escaping @Sendable (Data?, String?) -> Void) {
        Task { @MainActor in
            let output = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at: output) }
            do {
                try await PagedPDFRenderer().render(html: html, baseURL: nil, to: output)
                reply(try Data(contentsOf: output), nil)
            } catch PagedPDFRenderer.RenderError.timedOut {
                reply(nil, "timed out")
                // The print operation can't be cancelled; exiting stops it. launchd relaunches us on the next call.
                exit(1)
            } catch {
                reply(nil, String(describing: error))
            }
        }
    }
}

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: ConversionServiceProtocol.self)
        newConnection.exportedObject = ConversionServiceImpl()
        newConnection.resume()
        return true
    }
}

let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
