import AppKit
import Observation

/// Folders the user let Conv read and write without picking each file, for converting from Finder's menu.
@MainActor
@Observable
public final class FolderAccess {
    public static let shared = FolderAccess()

    public private(set) var folders: [URL] = []

    private static let key = "FolderAccess.bookmarks"
    private let defaults: UserDefaults
    private var opened: Set<URL> = []

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        folders = (defaults.array(forKey: Self.key) as? [Data] ?? []).compactMap(Self.resolve)
        for folder in folders where folder.startAccessingSecurityScopedResource() {
            opened.insert(folder)
        }
    }

    /// Asks for a folder, the home folder suggested.
    public func grant() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.message = "Finder에서 바로 바꿀 폴더를 고르세요. 그 안의 파일은 다시 묻지 않고 바꿔요."
        panel.prompt = "허용"
        guard panel.runModal() == .OK, let folder = panel.url else {
            return
        }
        add(folder)
    }

    public func add(_ folder: URL) {
        guard !folders.contains(folder) else {
            return
        }
        if folder.startAccessingSecurityScopedResource() {
            opened.insert(folder)
        }
        folders.append(folder)
        save()
    }

    public func remove(_ folder: URL) {
        if opened.remove(folder) != nil {
            folder.stopAccessingSecurityScopedResource()
        }
        folders.removeAll { $0 == folder }
        save()
    }

    /// Whether every path lies inside an allowed folder.
    public func covers(_ files: [URL]) -> Bool {
        files.allSatisfy { file in
            let path = file.standardizedFileURL.path
            return folders.contains { folder in
                let root = folder.standardizedFileURL.path
                return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
            }
        }
    }

    private func save() {
        let bookmarks = folders.compactMap { try? $0.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) }
        defaults.set(bookmarks, forKey: Self.key)
    }

    private static func resolve(_ bookmark: Data) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
    }
}
