import Cocoa
import FinderSync

/// Adds "conv.로 바꾸기" to Finder's context menu. Conversion actions arrive in P3.
final class FinderSync: FIFinderSync {
    override init() {
        super.init()
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let menu = NSMenu(title: "")
        menu.addItem(withTitle: "conv.로 바꾸기", action: nil, keyEquivalent: "")
        return menu
    }
}
