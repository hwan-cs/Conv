import AppKit
import SwiftUI

/// The menu bar item. A click opens the popover with paste, recent conversions and a way to the
/// main window.
@MainActor
public final class MenuBarController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()

    public override init() {
        super.init()
        guard let button = item.button else { return }
        button.image = NSImage(systemSymbolName: "arrow.down.to.line", accessibilityDescription: "Conv")
        button.target = self
        button.action = #selector(togglePopover)

        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MenuBarView { [weak self] in
            self?.popover.performClose(nil)
        })
    }

    @objc private func togglePopover() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // Active, so the popover takes ⌘V and ⌘O.
            NSApp.activate()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
