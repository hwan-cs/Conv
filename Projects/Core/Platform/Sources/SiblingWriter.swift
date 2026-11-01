import Foundation

/// Writes a converted file next to its original: "보고서.docx" → "보고서.pdf".
///
/// The sandbox only grants the file the user picked. The app declares its output types as related
/// items (`NSIsRelatedItemType`), which lets a file presenter for the original create a file with
/// the same name and another extension beside it, through file coordination.
public enum SiblingWriter {
    public enum WriteError: Error {
        /// A file of that name is already there; it is never replaced.
        case exists(URL)
        /// The sandbox refused, e.g. for a type the app doesn't declare as related.
        case denied(URL, underlying: Error)
    }

    public static func sibling(of original: URL, extension ext: String) -> URL {
        original.deletingPathExtension().appendingPathExtension(ext)
    }

    public static func write(_ data: Data, nextTo original: URL, extension ext: String) throws -> URL {
        try write(nextTo: original, extension: ext) { try data.write(to: $0, options: .withoutOverwriting) }
    }

    /// Streams the rest of `handle` beside the original: converted videos don't fit in memory.
    public static func copy(_ handle: FileHandle, nextTo original: URL, extension ext: String) throws -> URL {
        try write(nextTo: original, extension: ext) { try copy(handle, to: $0, overwriting: false) }
    }

    /// Like `copy(_:nextTo:extension:)`, but when the name is taken it writes "보고서 2.pdf",
    /// "보고서 3.pdf"… instead of failing, for conversions with no window to ask in. Only names
    /// other than the related item's need the folder to be granted.
    public static func copyKeepingBoth(_ handle: FileHandle, nextTo original: URL, extension ext: String) throws -> URL {
        for number in 1...99 {
            let target = numbered(sibling(of: original, extension: ext), number)
            do {
                return try write(to: target, primary: original) { try copy(handle, to: $0, overwriting: false) }
            } catch WriteError.exists {
                continue
            }
        }
        throw WriteError.exists(sibling(of: original, extension: ext))
    }

    /// "보고서.pdf" for 1, "보고서 2.pdf" for 2, as Finder numbers copies.
    public static func numbered(_ url: URL, _ number: Int) -> URL {
        guard number > 1 else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent().appending(path: "\(base) \(number)").appendingPathExtension(url.pathExtension)
    }

    /// Streams into a place the user chose in a save panel; its URL is already granted.
    public static func copy(_ handle: FileHandle, to url: URL) throws {
        try copy(handle, to: url, overwriting: true)
    }

    static func copy(_ handle: FileHandle, to url: URL, overwriting: Bool) throws {
        if !overwriting, FileManager.default.fileExists(atPath: url.path) {
            throw CocoaError(.fileWriteFileExists)
        }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteNoPermission) }
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        try handle.seek(toOffset: 0)
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
    }

    private static func write(nextTo original: URL, extension ext: String, _ body: (URL) throws -> Void) throws -> URL {
        try write(to: sibling(of: original, extension: ext), primary: original, body)
    }

    static func write(to target: URL, primary original: URL, _ body: (URL) throws -> Void) throws -> URL {
        let presenter = RelatedItemPresenter(primary: original, item: target)
        NSFileCoordinator.addFilePresenter(presenter)
        defer { NSFileCoordinator.removeFilePresenter(presenter) }

        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: presenter).coordinate(writingItemAt: target, options: [], error: &coordinationError) { url in
            do {
                try body(url)
            } catch {
                writeError = error
            }
        }
        if let error = writeError ?? coordinationError {
            if (error as NSError).code == NSFileWriteFileExistsError { throw WriteError.exists(target) }
            throw WriteError.denied(target, underlying: error)
        }
        return target
    }

    /// Writes where the user chose in a save panel; its URL is already granted.
    public static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }
}

private final class RelatedItemPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let primaryPresentedItemURL: URL?
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue()

    init(primary: URL, item: URL) {
        primaryPresentedItemURL = primary
        presentedItemURL = item
    }
}
