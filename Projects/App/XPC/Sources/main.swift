import ConversionKit
import DocumentEngine
import ImageEngine
import MediaEngine
import PDFEngine
import Foundation

final class ConversionServiceImpl: NSObject, ConversionServiceProtocol, @unchecked Sendable {
    /// Back to the app, for progress. Unowned by convention: the connection owns this object.
    private weak var connection: NSXPCConnection?

    init(connection: NSXPCConnection) {
        self.connection = connection
    }

    /// Reports progress for a job, at most once per whole percent.
    func reporter(for job: String) -> @Sendable (Double) -> Void {
        let app = AppProxy(connection?.remoteObjectProxy as? ConversionProgressProtocol)
        let last = LastPercent()
        return { fraction in
            guard last.advance(to: Int(fraction * 100)) else { return }
            app.proxy?.report(job: job, fraction: fraction)
        }
    }

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
        _ input: FileHandle,
        named name: String,
        to format: String,
        job: String,
        withReply reply: @escaping @Sendable (FileHandle?, String?) -> Void
    ) {
        let progress = reporter(for: job)
        Task { @MainActor in
            let work = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            // The reply's handle keeps the output readable after its directory is gone.
            defer { try? FileManager.default.removeItem(at: work) }
            do {
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                // Only the extension matters; the name is never trusted as a path.
                let ext = (name as NSString).pathExtension.lowercased()
                let source = work.appending(path: "input.\(ext)")
                let output = work.appending(path: "output.\(format)")
                try Self.copy(input, to: source)
                try? input.close()
                switch (ext, format) {
                case _ where Formats.imageInputs.contains(ext):
                    try ImageConverter().convert(source, to: output)
                case _ where Formats.sheetInputs.contains(ext):
                    let title = ((name as NSString).lastPathComponent as NSString).deletingPathExtension
                    try await SheetConverter().convert(
                        source,
                        to: output,
                        title: title,
                        progress: progress
                    )
                case _ where Formats.mediaInputs.contains(ext):
                    try await MediaConverter().convert(source, to: output, progress: progress)
                case _ where Formats.markdownInputs.contains(ext):
                    try await MarkdownConverter().convert(source, to: output)
                case ("docx", "pdf"):
                    try await DocxPDFConverter().convert(source, to: output)
                case ("hwp", "pdf"), ("hwpx", "pdf"):
                    try await HwpPDFConverter().convert(source, to: output)
                case ("hwp", "docx"), ("hwpx", "docx"):
                    try HwpDocxConverter().convert(source, to: output)
                default:
                    return reply(nil, "\(ext.uppercased()) → \(format.uppercased()) 변환은 아직 못 해요")
                }
                progress(1)
                reply(try FileHandle(forReadingFrom: output), nil)
            } catch PagedPDFRenderer.RenderError.timedOut {
                reply(nil, "시간이 너무 오래 걸려서 멈췄어요")
                // The print operation can't be cancelled; exiting stops it. launchd relaunches us on the next call.
                exit(1)
            } catch {
                reply(nil, Self.message(for: error))
            }
        }
    }

    func combine(
        _ inputs: [FileHandle],
        named names: [String],
        to format: String,
        job: String,
        withReply reply: @escaping @Sendable (FileHandle?, String?) -> Void
    ) {
        let progress = reporter(for: job)
        Task { @MainActor in
            let work = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: work) }
            do {
                guard format == "pdf", inputs.count == names.count else {
                    return reply(nil, "\(format.uppercased())로는 합칠 수 없어요")
                }
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                var pdfs: [URL] = []
                for (index, (handle, name)) in zip(inputs, names).enumerated() {
                    let ext = (name as NSString).pathExtension.lowercased()
                    let source = work.appending(path: "input-\(index).\(ext)")
                    try Self.copy(handle, to: source)
                    try? handle.close()
                    switch ext {
                    case "pdf":
                        pdfs.append(source)
                    case _ where Formats.imageInputs.contains(ext):
                        // An image becomes its own pages first, as it does alone.
                        let pdf = work.appending(path: "input-\(index).pdf")
                        try ImageConverter().convert(source, to: pdf)
                        pdfs.append(pdf)
                    default:
                        return reply(nil, "\(ext.uppercased()) 파일은 PDF에 합칠 수 없어요")
                    }
                    progress(Double(index + 1) / Double(names.count) * 0.5)
                }
                let output = work.appending(path: "output.pdf")
                try PDFCombiner().combine(pdfs, to: output) { progress(0.5 + $0 * 0.5) }
                reply(try FileHandle(forReadingFrom: output), nil)
            } catch {
                reply(nil, Self.message(for: error))
            }
        }
    }

    func convertPages(
        _ input: FileHandle,
        named name: String,
        to format: String,
        job: String,
        withReply reply: @escaping @Sendable (FileHandle?, String?) -> Void
    ) {
        let progress = reporter(for: job)
        Task { @MainActor in
            let work = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: work) }
            do {
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                let source = work.appending(path: "input.pdf")
                try Self.copy(input, to: source)
                try? input.close()
                let output = work.appending(path: "pages")
                try PDFPageRenderer().render(source, as: format, to: output, progress: progress)
                reply(try FileHandle(forReadingFrom: output), nil)
            } catch {
                reply(nil, Self.message(for: error))
            }
        }
    }

    /// Streams a handle into a file, a few megabytes at a time.
    private static func copy(_ handle: FileHandle, to url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
    }

    private static func message(for error: Error) -> String {
        switch error {
        case HwpPDFConverter.ConversionError.passwordProtected:
            "암호가 걸린 HWP는 바꿀 수 없어요"
        case HwpPDFConverter.ConversionError.unsupportedVersion(let version):
            "HWP \(version) 형식은 아직 못 읽어요"
        case HwpPDFConverter.ConversionError.unreadableDocument:
            "HWP 파일이 아니거나 손상됐어요"
        case PDFEngine.ConversionError.passwordProtected:
            "암호가 걸린 PDF는 바꿀 수 없어요"
        case PDFEngine.ConversionError.unreadable:
            "PDF 파일이 아니거나 손상됐어요"
        case PDFEngine.ConversionError.unsupportedOutput(let ext):
            "PDF를 \(ext.uppercased())로는 아직 못 바꿔요"
        case ImageConverter.ConversionError.unreadable:
            "이미지를 읽을 수 없어요"
        case ImageConverter.ConversionError.unsupportedOutput(let ext):
            "\(ext.uppercased())로는 아직 저장할 수 없어요"
        case SheetConverter.ConversionError.unreadable:
            "표 파일이 아니거나 손상됐어요"
        case SheetConverter.ConversionError.empty:
            "시트가 비어 있어서 바꿀 게 없어요"
        case SheetConverter.ConversionError.tooLarge:
            "엑셀 한 시트에 담기에는 너무 커요"
        case MediaConverter.ConversionError.unreadable:
            "영상이나 소리를 읽을 수 없어요"
        case MediaConverter.ConversionError.noAudio:
            "소리가 없는 파일이에요"
        case MediaConverter.ConversionError.exportFailed(let reason):
            "변환하지 못했어요 (\(reason))"
        default:
            "변환하지 못했어요 (\(error))"
        }
    }
}

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = ConversionService.interface()
        newConnection.remoteObjectInterface = NSXPCInterface(with: ConversionProgressProtocol.self)
        newConnection.exportedObject = ConversionServiceImpl(connection: newConnection)
        newConnection.resume()
        return true
    }
}

let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()

/// The last percent reported, so a stream of tiny steps becomes at most a hundred messages.
private final class LastPercent: @unchecked Sendable {
    private let lock = NSLock()
    private var percent = -1

    func advance(to value: Int) -> Bool {
        lock.withLock {
            guard value > percent else { return false }
            percent = value
            return true
        }
    }
}

/// XPC proxies may be messaged from any thread.
private struct AppProxy: @unchecked Sendable {
    let proxy: ConversionProgressProtocol?
    init(_ proxy: ConversionProgressProtocol?) { self.proxy = proxy }
}
