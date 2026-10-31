import AppKit
import Observation
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

        observeQuietConversions()

        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MenuBarView { [weak self] in
            self?.popover.performClose(nil)
        })
    }

    /// While Finder's conversions run, the icon becomes a ring filling up.
    private func observeQuietConversions() {
        let conversions = QuietConversions.shared
        let progress = withObservationTracking {
            conversions.current.map { _ in conversions.progress }
        } onChange: {
            Task { @MainActor [weak self] in self?.observeQuietConversions() }
        }
        guard let button = item.button else { return }
        if let progress {
            button.image = Self.ring(progress)
            button.toolTip = "바꾸는 중 \(Int(progress * 100))%"
        } else {
            button.image = NSImage(systemSymbolName: "arrow.down.to.line", accessibilityDescription: "Conv")
            button.toolTip = nil
        }
    }

    private static func ring(_ progress: Double) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let track = NSBezierPath(ovalIn: rect.insetBy(dx: 2.5, dy: 2.5))
            track.lineWidth = 2
            NSColor.black.withAlphaComponent(0.3).setStroke()
            track.stroke()
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: rect.width / 2 - 2.5, startAngle: 90, endAngle: 90 - 360 * max(progress, 0.03), clockwise: true)
            arc.lineWidth = 2
            arc.lineCapStyle = .round
            NSColor.black.setStroke()
            arc.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Conv: 바꾸는 중"
        return image
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
