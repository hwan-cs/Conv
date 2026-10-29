import AppKit
import ConversionKit
import Observation
import Platform
import UniformTypeIdentifiers

/// The main window's flow: files arrive, the user picks a format, each file is converted in the
/// XPC service and written beside its original.
@MainActor
@Observable
public final class DropModel {
    public enum Phase: Equatable {
        case empty
        case picking
        case converting
        case done
    }

    public struct Item: Identifiable, Equatable {
        public enum Status: Equatable {
            case waiting
            case converting
            case done(URL)
            case failed(String)
        }

        public let id = UUID()
        public let url: URL
        public let size: Int64?
        public var status: Status = .waiting

        public var name: String { url.lastPathComponent }
        public var ext: String { url.pathExtension.lowercased() }
    }

    public private(set) var phase: Phase = .empty
    public private(set) var items: [Item] = []
    public private(set) var output: Formats.Output?
    /// Why the last drop couldn't be used, shown on the empty screen.
    public private(set) var notice: String?

    private let client: ConversionClient

    public init(client: ConversionClient = ConversionClient()) {
        self.client = client
    }

    /// Formats every dropped file can become.
    public var outputs: [Formats.Output] {
        guard let first = items.first else { return [] }
        return Formats.outputs(for: first.url).filter { output in
            items.allSatisfy { Formats.outputs(for: $0.url).contains(output) }
        }
    }

    public var finishedCount: Int {
        items.filter { if case .done = $0.status { true } else { false } }.count
    }

    public var failedItems: [Item] {
        items.filter { if case .failed = $0.status { true } else { false } }
    }

    public var settledCount: Int {
        items.filter { $0.status != .waiting && $0.status != .converting }.count
    }

    public func accept(_ urls: [URL]) {
        let files = urls.filter { !$0.hasDirectoryPath }
        guard !files.isEmpty else { return }
        items = files.map { url in
            let size = withAccess(url) { (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) }
            return Item(url: url, size: size ?? nil)
        }
        if outputs.isEmpty {
            let kinds = Set(items.map { "." + $0.ext.uppercased() }).sorted().joined(separator: ", ")
            notice = "\(kinds) 파일은 아직 바꿀 수 없어요. 지금은 DOCX, HWP, HWPX → PDF를 지원해요."
            items = []
            phase = .empty
            return
        }
        notice = nil
        phase = .picking
    }

    public func choose(_ output: Formats.Output) {
        self.output = output
        phase = .converting
        Task { await convertAll(to: output) }
    }

    public func reset() {
        items = []
        output = nil
        notice = nil
        phase = .empty
    }

    public func revealOutputs() {
        let urls = items.compactMap { if case .done(let url) = $0.status { url } else { nil } }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    private func convertAll(to output: Formats.Output) async {
        for index in items.indices {
            items[index].status = .converting
            items[index].status = await convert(items[index], to: output)
        }
        phase = .done
    }

    private func convert(_ item: Item, to output: Formats.Output) async -> Item.Status {
        guard let data = withAccess(item.url, { try? Data(contentsOf: item.url) }) ?? nil else {
            return .failed("파일을 읽을 수 없어요")
        }
        let converted: Data
        do {
            converted = try await client.convert(data, named: item.name, to: output.ext)
        } catch {
            return .failed(String(describing: error))
        }
        do {
            let written = try withAccess(item.url) {
                try SiblingWriter.write(converted, nextTo: item.url, extension: output.ext)
            }
            return .done(written)
        } catch {
            // A same-named file is already there, or the folder is off limits: ask where to put it.
            guard let chosen = askWhereToSave(item, output: output) else { return .failed("저장하지 않았어요") }
            do {
                try SiblingWriter.write(converted, to: chosen)
                return .done(chosen)
            } catch {
                return .failed("저장하지 못했어요")
            }
        }
    }

    private func askWhereToSave(_ item: Item, output: Formats.Output) -> URL? {
        let panel = NSSavePanel()
        panel.directoryURL = item.url.deletingLastPathComponent()
        panel.nameFieldStringValue = SiblingWriter.sibling(of: item.url, extension: output.ext).lastPathComponent
        panel.message = "같은 이름의 파일이 있어요. 어디에 저장할까요?"
        if let type = UTType(filenameExtension: output.ext) { panel.allowedContentTypes = [type] }
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Files from the open panel are security-scoped; dropped files are granted as they arrive.
    private func withAccess<T>(_ url: URL, _ body: () throws -> T) rethrows -> T {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try body()
    }
}
