import Cocoa
import FinderSync

/// Adds "conv.로 바꾸기" to Finder's context menu.
///
/// The extension converts nothing itself: its sandbox can neither write beside the files nor pass
/// access to them on. It posts the selection's paths and the picked format to the app, launching
/// it first if needed; the app converts them in the background through folders the user allowed.
final class FinderSync: FIFinderSync {
    override init() {
        super.init()
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let menu = NSMenu(title: "")
        guard menuKind == .contextualMenuForItems, let files = selectedFiles(), !files.isEmpty else { return menu }

        let outputs = Self.outputs(for: files)
        guard !outputs.isEmpty else { return menu }
        let submenu = NSMenu(title: "conv.로 바꾸기")
        for (index, output) in outputs.enumerated() {
            let title = ".\(output.ext.uppercased())" + (index == 0 ? "  (추천)" : "")
            let item = NSMenuItem(title: title, action: #selector(convert(_:)), keyEquivalent: "")
            item.target = self
            // Finder copies the menu, so the format travels in the tag, not the item itself.
            item.tag = Self.formats.firstIndex(of: output.ext) ?? -1
            submenu.addItem(item)
        }
        // No separator: Finder draws one from an extension as an empty row.
        let more = NSMenuItem(title: "conv.에서 더 보기…", action: #selector(openInConv(_:)), keyEquivalent: "")
        more.target = self
        submenu.addItem(more)

        let root = NSMenuItem(title: "conv.로 바꾸기", action: nil, keyEquivalent: "")
        root.submenu = submenu
        menu.addItem(root)
        return menu
    }

    @objc private func convert(_ sender: NSMenuItem) {
        guard Self.formats.indices.contains(sender.tag), let files = selectedFiles() else { return }
        Self.send(files, format: Self.formats[sender.tag])
    }

    @objc private func openInConv(_ sender: NSMenuItem) {
        guard let files = selectedFiles() else { return }
        Self.send(files, format: nil)
    }

    private func selectedFiles() -> [URL]? {
        FIFinderSyncController.default().selectedItemURLs()?.filter { !$0.hasDirectoryPath }
    }

    /// Every output any input can have, for numbering menu items.
    private static let formats = ["jpg", "png", "pdf", "heic", "tiff", "gif", "bmp", "avif", "mp4", "mov", "m4a", "mp3", "wav", "aiff", "html"]

    /// Formats every selected file can become, best first.
    private static func outputs(for files: [URL]) -> [Formats.Output] {
        guard let first = files.first else { return [] }
        return Formats.outputs(for: first).filter { output in
            files.allSatisfy { Formats.outputs(for: $0).contains(output) }
        }
    }

    private static func send(_ files: [URL], format: String?) {
        guard let message = FinderRequest(paths: files.map(\.path), format: format).encoded else { return }
        let post = {
            DistributedNotificationCenter.default().postNotificationName(
                FinderRequest.notification, object: message, userInfo: nil, deliverImmediately: true
            )
        }
        if !NSRunningApplication.runningApplications(withBundleIdentifier: "com.conv.Conv").isEmpty {
            post()
            return
        }
        // Not running: launch it, then post once it has had time to start listening. The app
        // ignores a request it has already taken.
        // Conv.app/Contents/PlugIns/ConvFinderSync.appex
        let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let configuration = NSWorkspace.OpenConfiguration()
        // With a format picked, the app converts in the background and shows no window.
        configuration.activates = format == nil
        if format != nil { configuration.arguments = [FinderRequest.quietLaunchArgument] }
        NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, _ in
            for delay in [0.5, 1.5, 3.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: post)
            }
        }
    }
}
