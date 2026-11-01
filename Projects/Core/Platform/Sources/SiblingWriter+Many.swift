import ConversionKit
import Foundation

/// Results that aren't one file beside one original: a PDF's pages, and files combined into one.
/// Both need the folder granted (in Settings) or picked in a save panel, except a one-page PDF,
/// whose image is a related item like any other conversion.
extension SiblingWriter {
    /// One page becomes "보고서.jpg" beside "보고서.pdf"; more go into a folder "보고서" beside it,
    /// as "보고서-1.jpg", "보고서-2.jpg"… Returns the image or the folder.
    /// - Parameter keepingBoth: When the name is taken, number it ("보고서 2") instead of failing.
    public static func writePages(_ pages: PackedFiles.Reader, nextTo original: URL, extension ext: String, keepingBoth: Bool) throws -> URL {
        if pages.count == 1 {
            var image = Data()
            try pages.forEach { _, data in image = data }
            guard keepingBoth else { return try write(image, nextTo: original, extension: ext) }
            return try firstFree(sibling(of: original, extension: ext)) { target in
                try write(to: target, primary: original) { try image.write(to: $0, options: .withoutOverwriting) }
            }
        }
        let base = original.deletingPathExtension().lastPathComponent
        let folder = original.deletingPathExtension()
        let created = try firstFree(folder, numbers: keepingBoth ? 1...99 : 1...1, isFolder: true) { target in
            try createFolder(at: target)
            return target
        }
        return try writePages(pages, into: created, named: base, extension: ext)
    }

    /// Into a folder picked in a save panel, made if it isn't there. Pages already there are kept.
    public static func writePages(_ pages: PackedFiles.Reader, into folder: URL, named base: String, extension ext: String) throws -> URL {
        if !FileManager.default.fileExists(atPath: folder.path) { try createFolder(at: folder) }
        let digits = String(pages.count).count
        try pages.forEach { index, data in
            let number = String(repeating: "0", count: max(digits - String(index + 1).count, 0)) + String(index + 1)
            let page = folder.appending(path: "\(base)-\(number)").appendingPathExtension(ext)
            _ = try firstFree(page) { target in
                try data.write(to: target, options: .withoutOverwriting)
                return target
            }
        }
        return folder
    }

    /// A one-page PDF's image, where the user chose in a save panel.
    public static func writeOnlyPage(_ pages: PackedFiles.Reader, to url: URL) throws -> URL {
        try pages.forEach { index, data in
            if index == 0 { try data.write(to: url, options: .atomic) }
        }
        return url
    }

    /// "IMG_0001 외 4개.pdf", beside the first file.
    public static func combinedName(of files: [URL], extension ext: String) -> URL {
        guard let first = files.first else { return URL(filePath: "합친 파일").appendingPathExtension(ext) }
        let base = first.deletingPathExtension().lastPathComponent
        let name = files.count > 1 ? "\(base) 외 \(files.count - 1)개" : base
        return first.deletingLastPathComponent().appending(path: name).appendingPathExtension(ext)
    }

    /// Writes the combined file under `combinedName(of:extension:)`.
    public static func copyCombined(_ handle: FileHandle, of files: [URL], extension ext: String, keepingBoth: Bool) throws -> URL {
        try firstFree(combinedName(of: files, extension: ext), numbers: keepingBoth ? 1...99 : 1...1) { target in
            do {
                try copy(handle, to: target, overwriting: false)
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                throw WriteError.exists(target)
            } catch {
                throw WriteError.denied(target, underlying: error)
            }
            return target
        }
    }

    /// Tries "name", then "name 2", "name 3"… while the name is taken.
    private static func firstFree(
        _ url: URL,
        numbers: ClosedRange<Int> = 1...99,
        isFolder: Bool = false,
        _ attempt: (URL) throws -> URL
    ) throws -> URL {
        for number in numbers {
            // A folder's name is all name: "v1.2 자료" has no extension to keep last.
            let target = isFolder
                ? url.deletingLastPathComponent().appending(path: number > 1 ? "\(url.lastPathComponent) \(number)" : url.lastPathComponent)
                : numbered(url, number)
            do {
                return try attempt(target)
            } catch WriteError.exists {
                continue
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
        }
        throw WriteError.exists(url)
    }

    private static func createFolder(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { throw WriteError.exists(url) }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        } catch {
            throw WriteError.denied(url, underlying: error)
        }
    }
}
