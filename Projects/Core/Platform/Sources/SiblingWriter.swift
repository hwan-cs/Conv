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
        let target = sibling(of: original, extension: ext)
        let presenter = RelatedItemPresenter(primary: original, item: target)
        NSFileCoordinator.addFilePresenter(presenter)
        defer { NSFileCoordinator.removeFilePresenter(presenter) }

        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: presenter).coordinate(writingItemAt: target, options: [], error: &coordinationError) { url in
            do {
                try data.write(to: url, options: .withoutOverwriting)
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
