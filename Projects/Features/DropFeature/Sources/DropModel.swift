import AppKit
import ConversionKit
import Observation
import Platform
import QuickLookThumbnailing
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
            /// With how far along it is, once the service has said.
            case converting(Double?)
            case done(URL)
            case failed(String)
        }

        public let id = UUID()
        public let url: URL
        public let size: Int64?
        /// Made from the clipboard in the app's own folder, so there is no "beside the original".
        public var isPasted = false
        /// Quick Look's preview, once it has made one.
        public var thumbnail: CGImage?
        public var status: Status = .waiting

        public var name: String { url.lastPathComponent }
        public var ext: String { url.pathExtension.lowercased() }
    }

    public private(set) var phase: Phase = .empty
    public private(set) var items: [Item] = []
    public private(set) var output: Formats.Output?
    /// Selected on the pick screen when it opens; still converted only once confirmed.
    public private(set) var suggested: Formats.Output?
    /// Why the last drop couldn't be used, shown on the empty screen.
    public private(set) var notice: String?
    /// The notice is about Finder's menu needing a folder allowed in Settings.
    public private(set) var noticeNeedsFolderAccess = false

    private let client: ConversionClient

    public init(client: ConversionClient = ConversionClient()) {
        self.client = client
    }

    /// Formats every dropped file can become.
    public var outputs: [Formats.Output] {
        Formats.outputs(for: items.map(\.url))
    }

    public var finishedCount: Int {
        items.filter { if case .done = $0.status { true } else { false } }.count
    }

    public var failedItems: [Item] {
        items.filter { if case .failed = $0.status { true } else { false } }
    }

    public var settledCount: Int {
        items.filter {
            switch $0.status {
            case .waiting, .converting: false
            case .done, .failed: true
            }
        }.count
    }

    /// Finished files plus how far the current one is, over all of them.
    public var overallProgress: Double {
        // Combined files move together.
        if output?.combines == true {
            if settledCount == items.count { return 1 }
            return items.lazy.compactMap { if case .converting(let fraction) = $0.status { fraction ?? 0 } else { nil } }.first ?? 0
        }
        let current = items.lazy.compactMap { if case .converting(let fraction) = $0.status { fraction ?? 0 } else { nil } }.first ?? 0
        return (Double(settledCount) + current) / Double(max(items.count, 1))
    }

    /// - Parameter format: A format picked elsewhere (Finder's menu), shown selected.
    public func accept(_ urls: [URL], isPasted: Bool = false, format: String? = nil) {
        // Files arriving mid-conversion would be dropped from the list being converted.
        guard phase != .converting else { return }
        let files = urls.filter { !$0.hasDirectoryPath }
        guard !files.isEmpty else { return }
        items = files.map { url in
            withAccess(url) {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
                return Item(url: url, size: size, isPasted: isPasted)
            }
        }
        for item in items { loadThumbnail(for: item) }
        if outputs.isEmpty {
            let kinds = Set(items.map { "." + $0.ext.uppercased() }).sorted().joined(separator: ", ")
            notice = items.count > 1 && items.allSatisfy({ !Formats.outputs(for: [$0.url]).isEmpty })
                ? "\(kinds) 파일은 함께 바꿀 수 없어요. 같은 종류끼리 넣어 주세요."
                : "\(kinds) 파일은 아직 바꿀 수 없어요. 지금은 문서(PDF, DOCX, HWP, HWPX), 이미지(HEIC, JPG, PNG 등), 영상(MOV, MP4), 소리(MP3, M4A, WAV 등)를 바꿀 수 있어요."
            items = []
            phase = .empty
            return
        }
        notice = nil
        noticeNeedsFolderAccess = false
        suggested = outputs.first { $0.ext == format }
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
        noticeNeedsFolderAccess = false
        phase = .empty
    }

    /// Finder sent files from a folder Conv may not read yet.
    public func explainFolderAccess(for files: [URL]) {
        guard phase != .converting else { return }
        reset()
        let folder = files.first?.deletingLastPathComponent().path(percentEncoded: false) ?? ""
        notice = "Finder에서 바로 바꾸려면 설정에서 이 폴더(또는 그 위 폴더)를 허용해 주세요: \(folder)"
        noticeNeedsFolderAccess = true
    }

    public func revealOutputs() {
        var urls: [URL] = []
        for case .done(let url) in items.map(\.status) where !urls.contains(url) { urls.append(url) }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    private func convertAll(to output: Formats.Output) async {
        if output.combines {
            await combineAll(to: output)
            phase = .done
            return
        }
        for index in items.indices {
            items[index].status = .converting(nil)
            items[index].status = await convert(items[index], to: output)
            if case .done(let written) = items[index].status {
                ConversionHistory.shared.record(input: items[index].url, output: written, format: output.ext)
            }
        }
        phase = .done
    }

    /// Every file into one, its status shared by all of them.
    private func combineAll(to output: Formats.Output) async {
        let urls = items.map(\.url)
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { for url in scoped { url.stopAccessingSecurityScopedResource() } }
        for index in items.indices { items[index].status = .converting(nil) }
        let status: Item.Status
        do {
            let combined = try await client.combine(urls, to: output.ext) { fraction in
                Task { @MainActor [weak self] in self?.updateAll(progress: fraction) }
            }
            defer { try? combined.close() }
            status = save {
                try SiblingWriter.copyCombined(combined, of: urls, extension: output.ext, keepingBoth: false)
            } orAsk: {
                askWhereToSave(
                    name: SiblingWriter.combinedName(of: urls, extension: output.ext).lastPathComponent,
                    in: urls[0].deletingLastPathComponent(), ext: output.ext,
                    message: "합친 PDF를 어디에 저장할까요?"
                )
            } then: { chosen in
                try SiblingWriter.copy(combined, to: chosen)
                return chosen
            }
        } catch let error as ConversionClient.Failure {
            status = .failed(error.description)
        } catch {
            status = .failed("파일을 읽을 수 없어요")
        }
        for index in items.indices { items[index].status = status }
        if case .done(let written) = status, let first = urls.first {
            ConversionHistory.shared.record(input: first, output: written)
        }
    }

    /// A PDF's pages as images: one beside it, or a folder of them.
    private func convertPages(_ item: Item, to output: Formats.Output) async -> Item.Status {
        let scoped = item.url.startAccessingSecurityScopedResource()
        defer { if scoped { item.url.stopAccessingSecurityScopedResource() } }
        let pages: PackedFiles.Reader
        do {
            let id = item.id
            pages = try await client.convertPages(item.url, to: output.ext) { fraction in
                Task { @MainActor [weak self] in self?.update(id, progress: fraction) }
            }
        } catch let error as ConversionClient.Failure {
            return .failed(error.description)
        } catch {
            return .failed("파일을 읽을 수 없어요")
        }
        let base = item.url.deletingPathExtension().lastPathComponent
        return save {
            try SiblingWriter.writePages(pages, nextTo: item.url, extension: output.ext, keepingBoth: false)
        } orAsk: {
            pages.count == 1
                ? askWhereToSave(item, output: output)
                : askWhereToSave(
                    name: base, in: item.url.deletingLastPathComponent(), ext: nil,
                    message: "\(pages.count)쪽을 한 장씩 담을 폴더예요. 어디에 만들까요?"
                )
        } then: { chosen in
            pages.count == 1
                ? try SiblingWriter.writeOnlyPage(pages, to: chosen)
                : try SiblingWriter.writePages(pages, into: chosen, named: base, extension: output.ext)
        }
    }

    /// Writes beside the original; when that fails (the name is taken, or the folder isn't
    /// granted) asks where instead.
    private func save(_ beside: () throws -> URL, orAsk ask: () -> URL?, then write: (URL) throws -> URL) -> Item.Status {
        do {
            return .done(try beside())
        } catch {
            guard let chosen = ask() else { return .failed("저장하지 않았어요") }
            do {
                return .done(try write(chosen))
            } catch {
                return .failed("저장하지 못했어요")
            }
        }
    }

    private func convert(_ item: Item, to output: Formats.Output) async -> Item.Status {
        if Formats.splitsPages(item.url) { return await convertPages(item, to: output) }
        let scoped = item.url.startAccessingSecurityScopedResource()
        defer { if scoped { item.url.stopAccessingSecurityScopedResource() } }
        let converted: FileHandle
        do {
            let id = item.id
            converted = try await client.convert(item.url, to: output.ext) { fraction in
                Task { @MainActor [weak self] in self?.update(id, progress: fraction) }
            }
        } catch let error as ConversionClient.Failure {
            return .failed(error.description)
        } catch {
            return .failed("파일을 읽을 수 없어요")
        }
        defer { try? converted.close() }
        do {
            guard !item.isPasted else { throw CocoaError(.fileWriteNoPermission) }
            return .done(try SiblingWriter.copy(converted, nextTo: item.url, extension: output.ext))
        } catch {
            // A same-named file is already there, or the folder is off limits: ask where to put it.
            guard let chosen = askWhereToSave(item, output: output) else { return .failed("저장하지 않았어요") }
            do {
                try SiblingWriter.copy(converted, to: chosen)
                return .done(chosen)
            } catch {
                return .failed("저장하지 못했어요")
            }
        }
    }

    private func askWhereToSave(_ item: Item, output: Formats.Output) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = SiblingWriter.sibling(of: item.url, extension: output.ext).lastPathComponent
        if item.isPasted {
            panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            panel.message = "클립보드에서 가져온 이미지예요. 어디에 저장할까요?"
        } else {
            panel.directoryURL = item.url.deletingLastPathComponent()
            panel.message = "같은 이름의 파일이 있어요. 어디에 저장할까요?"
        }
        if let type = UTType(filenameExtension: output.ext) { panel.allowedContentTypes = [type] }
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// A save panel for a new name: a combined file, or a folder of pages when `ext` is nil.
    private func askWhereToSave(name: String, in folder: URL, ext: String?, message: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.directoryURL = folder
        panel.message = message
        if let ext, let type = UTType(filenameExtension: ext) { panel.allowedContentTypes = [type] }
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func updateAll(progress fraction: Double) {
        for index in items.indices {
            guard case .converting = items[index].status else { continue }
            items[index].status = .converting(fraction)
        }
    }

    private func update(_ id: Item.ID, progress fraction: Double) {
        guard let index = items.firstIndex(where: { $0.id == id }), case .converting = items[index].status else { return }
        items[index].status = .converting(fraction)
    }

    /// Asks Quick Look for a preview: a video's first frame, a document's first page, a photo.
    /// Files it doesn't know, such as .hwp, keep their icon.
    private func loadThumbnail(for item: Item) {
        let (id, url) = (item.id, item.url)
        let scoped = url.startAccessingSecurityScopedResource()
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 200, height: 150),
            scale: 2,
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { thumbnail, _ in
            if scoped { url.stopAccessingSecurityScopedResource() }
            guard let image = thumbnail?.cgImage else { return }
            let preview = UncheckedImage(image)
            Task { @MainActor [weak self] in
                guard let self, let index = items.firstIndex(where: { $0.id == id }) else { return }
                items[index].thumbnail = preview.image
            }
        }
    }

    /// Files from the open panel are security-scoped; dropped files are granted as they arrive.
    private func withAccess<T>(_ url: URL, _ body: () throws -> T) rethrows -> T {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try body()
    }
}

/// CGImage is immutable; this carries one across the Quick Look callback.
private struct UncheckedImage: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
