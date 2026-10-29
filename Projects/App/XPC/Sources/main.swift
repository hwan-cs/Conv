import ConversionKit
import DocumentEngine
import ImageEngine
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

extension ConversionServiceImpl {
    func convert(
        _ data: Data,
        named name: String,
        to format: String,
        withReply reply: @escaping @Sendable (Data?, String?) -> Void
    ) {
        Task { @MainActor in
            let work = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: work) }
            do {
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                // Only the extension matters; the name is never trusted as a path.
                let ext = (name as NSString).pathExtension.lowercased()
                let input = work.appending(path: "input.\(ext)")
                let output = work.appending(path: "output.\(format)")
                try data.write(to: input)
                switch (ext, format) {
                case _ where Formats.imageInputs.contains(ext):
                    try ImageConverter().convert(input, to: output)
                case ("docx", "pdf"):
                    try await DocxPDFConverter().convert(input, to: output)
                case ("hwp", "pdf"), ("hwpx", "pdf"):
                    try await HwpPDFConverter().convert(input, to: output)
                default:
                    return reply(nil, "\(ext.uppercased()) → \(format.uppercased()) 변환은 아직 못 해요")
                }
                reply(try Data(contentsOf: output), nil)
            } catch PagedPDFRenderer.RenderError.timedOut {
                reply(nil, "시간이 너무 오래 걸려서 멈췄어요")
                // The print operation can't be cancelled; exiting stops it. launchd relaunches us on the next call.
                exit(1)
            } catch {
                reply(nil, Self.message(for: error))
            }
        }
    }

    private static func message(for error: Error) -> String {
        switch error {
        case HwpPDFConverter.ConversionError.passwordProtected: "암호가 걸린 HWP는 바꿀 수 없어요"
        case HwpPDFConverter.ConversionError.unsupportedVersion(let version): "HWP \(version) 형식은 아직 못 읽어요"
        case HwpPDFConverter.ConversionError.unreadableDocument: "HWP 파일이 아니거나 손상됐어요"
        case ImageConverter.ConversionError.unreadable: "이미지를 읽을 수 없어요"
        case ImageConverter.ConversionError.unsupportedOutput(let ext): "\(ext.uppercased())로는 아직 저장할 수 없어요"
        default: "변환하지 못했어요 (\(error))"
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
