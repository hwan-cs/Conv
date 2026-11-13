import AppKit
import Observation
import SwiftUI

/// The menu bar item. A click opens the popover with paste, recent conversions and a way to the main window.
@MainActor
public final class MenuBarController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()

    public override init() {
        super.init()
        guard let button = item.button else {
            return
        }
        button.image = Self.glyph
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
            Task { @MainActor [weak self] in
                self?.observeQuietConversions()
            }
        }
        guard let button = item.button else {
            return
        }
        if let progress {
            button.image = Self.ring(progress)
            button.toolTip = "바꾸는 중 \(Int(progress * 100))%"
        } else {
            button.image = Self.glyph
            button.toolTip = nil
        }
    }

    /// The app icon in outline: a file behind, and the one it becomes in front with an arrow.
    private static let glyph: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let front = NSRect(x: 5, y: 2.5, width: 12, height: 9)
            NSColor.black.set()

            // The back file's outline stops short of the front one, leaving a gap.
            NSGraphicsContext.saveGraphicsState()
            let clip = NSBezierPath(rect: rect)
            clip.append(
                NSBezierPath(
                    roundedRect: front.insetBy(dx: -1.5, dy: -1.5),
                    xRadius: 3.5,
                    yRadius: 3.5
                )
            )
            clip.windingRule = .evenOdd
            clip.addClip()
            let back = NSBezierPath(
                roundedRect: NSRect(x: 1.5, y: 7.5, width: 10.5, height: 8),
                xRadius: 2.2,
                yRadius: 2.2
            )
            back.lineWidth = 1.5
            back.stroke()
            NSGraphicsContext.restoreGraphicsState()

            NSBezierPath(
                roundedRect: front,
                xRadius: 2.5,
                yRadius: 2.5
            ).fill()

            // The arrow is cut out of the front file.
            NSGraphicsContext.current?.compositingOperation = .clear
            let arrow = NSBezierPath()
            arrow.move(to: NSPoint(x: front.minX + 3, y: front.midY))
            arrow.line(to: NSPoint(x: front.maxX - 3, y: front.midY))
            arrow.move(to: NSPoint(x: front.maxX - 5.6, y: front.midY + 2.6))
            arrow.line(to: NSPoint(x: front.maxX - 3, y: front.midY))
            arrow.line(to: NSPoint(x: front.maxX - 5.6, y: front.midY - 2.6))
            arrow.lineWidth = 1.6
            arrow.lineCapStyle = .round
            arrow.lineJoinStyle = .round
            arrow.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Conv"
        return image
    }()

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
        guard let button = item.button else {
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
